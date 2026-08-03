// tamaclaude — จอแสดงสถานะ Claude Code บนบอร์ด CYD
//
// เส้นทางข้อมูล: BLE write -> staging (mutex) -> ลูปหลัก -> LVGL -> SPI -> จอ
// LVGL ไม่ปลอดภัยกับหลายเธรด ทุกการแตะ UI จึงเกิดในลูปหลักที่เดียว
#include <string.h>

#include "cJSON.h"
#include "ct_ble.h"
#include "ct_lan.h"
#include "ct_lcd.h"
#include "ct_dim.h"
#include "ct_led.h"
#include "ct_touch.h"
#include "ct_mascot.h"
#include "ct_model.h"
#include "ct_ui.h"
#include "ct_wifi.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "layout.h"
#include "lvgl.h"
#include "nvs_flash.h"

static const char *TAG = "main";

// บัฟเฟอร์วาดของ LVGL: 1/10 ของจอสองก้อน (~15KB) ไม่ใช่ framebuffer เต็ม 150KB
// บอร์ดนี้ไม่มี PSRAM จึงไม่มีทางเลือกอื่นอยู่แล้ว
#define DRAW_LINES 24
#define DRAW_BUF_PX (CT_SCREEN_WIDTH * DRAW_LINES)

static lv_color_t *s_buf1, *s_buf2;
static SemaphoreHandle_t s_lock;

// ของที่ BLE ฝากไว้ให้ลูปหลักหยิบไปใช้
static ct_snapshot_t s_pending;
static bool s_has_pending;
static bool s_link;
static bool s_link_changed = true;
static bool s_wifi_up;
static char s_ip[16];
static int s_pending_backlight = -1;

static uint32_t millis_cb(void) { return (uint32_t)(esp_timer_get_time() / 1000); }

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    size_t px = (size_t)(area->x2 - area->x1 + 1) * (area->y2 - area->y1 + 1);
    // LVGL เก็บ RGB565 แบบ little-endian ส่วนจอกินแบบ big-endian
    lv_draw_sw_rgb565_swap(px_map, px);
    ct_lcd_blit(area->x1, area->y1, area->x2, area->y2, px_map, px * 2);
    lv_display_flush_ready(disp);
}

// --- callback จาก NimBLE (คนละเธรดกับ LVGL) ---------------------------------
static void on_state(const char *json, int len)
{
    ct_snapshot_t parsed;
    if (!ct_model_parse(json, len, &parsed)) {
        ESP_LOGW(TAG, "snapshot was not valid json");
        return;
    }
    ESP_LOGI(TAG, "snapshot %s: %d sessions, %d cards", parsed.clock, parsed.session_count,
             parsed.card_count);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_pending = parsed;
    s_has_pending = true;
    xSemaphoreGive(s_lock);
}

// กุญแจของทาง LAN เดินมาช่องเดียวกับรหัส WiFi ด้วยเหตุผลเดียวกัน (ต้องเข้ารหัส) แต่
// เจ้าของคนละโมดูล — แยกออกมาที่นี่แทนที่จะยัดเข้า `ct_wifi_command` เพื่อไม่ให้โมดูล
// WiFi ต้องรู้จักเรื่องการปิดผนึกเฟรม ซึ่งเป็นคนละชั้นกัน
static bool lan_command(const char *json, int len)
{
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) return false;
    const cJSON *cmd = cJSON_GetObjectItem(root, "c");
    const cJSON *key = cJSON_GetObjectItem(root, "k");
    bool mine = cJSON_IsString(cmd) && strcmp(cmd->valuestring, "key") == 0;
    if (mine && !ct_lan_set_key(cJSON_IsString(key) ? key->valuestring : NULL)) {
        ESP_LOGW(TAG, "lan key rejected");
    }
    cJSON_Delete(root);
    // ตอบกลับด้วยสถานะเต็มใบ ไม่ใช่ ack เปล่า — Mac ต้องเห็นลายนิ้วมือใหม่เพื่อรู้ว่า
    // กุญแจที่มันเพิ่งส่งไปคือกุญแจที่บอร์ดถืออยู่จริง
    if (mine) ct_wifi_report();
    return mine;
}

static void on_config(const char *json, int len)
{
    // คำสั่ง WiFi มาทางเดียวกับความสว่าง แยกด้วยคีย์ "c" — ช่องนี้บังคับเข้ารหัสอยู่แล้ว
    // เพราะรหัส WiFi ต้องผ่านมันไป (ct_ble.h)
    if (lan_command(json, len)) return;
    if (ct_wifi_command(json, len)) return;

    // คอนฟิกที่เหลือมีค่าเดียว: {"b":0..100}
    const char *p = strstr(json, "\"b\"");
    if (!p) return;
    p = strchr(p, ':');
    if (!p) return;
    int value = atoi(p + 1);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_pending_backlight = value;
    xSemaphoreGive(s_lock);
}

static void on_link(bool connected)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_link = connected;
    s_link_changed = true;
    xSemaphoreGive(s_lock);
}

// --- callback จาก esp_wifi (คนละเธรดอีกใบ) -----------------------------------
// ประกอบ JSON ด้วย cJSON ไม่ใช่ snprintf: ชื่อเครือข่ายเป็นข้อความที่ผู้อื่นตั้ง และ
// SSID ที่มีเครื่องหมายคำพูดอยู่ข้างในจะทำให้ฝั่ง Mac แปลงไม่ผ่านทั้งรายการ
static void notify_json(cJSON *root)
{
    char *text = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!text) return;
    ct_ble_notify(text, (int)strlen(text));
    cJSON_free(text);
}

static void on_ap(const char *ssid, int8_t rssi, bool secured)
{
    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "ap");
    cJSON_AddStringToObject(root, "s", ssid);
    cJSON_AddNumberToObject(root, "r", rssi);
    cJSON_AddNumberToObject(root, "e", secured ? 1 : 0);
    notify_json(root);
}

static void on_ap_end(void)
{
    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "ap_end");
    notify_json(root);
}

static const char *wifi_state_name(ct_wifi_state_t st)
{
    switch (st) {
        case CT_WIFI_CONNECTING: return "connecting";
        case CT_WIFI_CONNECTED: return "connected";
        case CT_WIFI_FAILED: return "failed";
        default: return "off";
    }
}

static void on_wifi_status(ct_wifi_state_t st, const char *ssid, const char *ip,
                           const char *err)
{
    bool up = (st == CT_WIFI_CONNECTED);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_wifi_up = up;
    snprintf(s_ip, sizeof(s_ip), "%s", up && ip ? ip : "");
    s_link_changed = true;
    xSemaphoreGive(s_lock);

    // server ขึ้นตามการมี IP ไม่ใช่ตามการมีกุญแจ — บอร์ดที่รับสายแล้วปฏิเสธทุกเฟรม
    // บอกฝั่ง Mac ได้ว่า "กุญแจไม่ตรง" ส่วนบอร์ดที่ไม่รับสายเลยแยกไม่ออกจากบอร์ดที่ตาย
    ct_lan_set_up(up, ip);

    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "wifi");
    cJSON_AddStringToObject(root, "st", wifi_state_name(st));
    cJSON_AddStringToObject(root, "s", ssid ? ssid : "");
    cJSON_AddStringToObject(root, "ip", ip ? ip : "");
    // ลายนิ้วมือกุญแจ LAN — ว่างแปลว่ายังไม่เคยตั้ง Mac จะได้รู้ว่าต้องส่งไปให้
    cJSON_AddStringToObject(root, "kf", ct_lan_key_fingerprint());
    if (err && err[0]) cJSON_AddStringToObject(root, "er", err);

    // รายชื่อที่จำไว้เดินทางมากับสถานะ ไม่ใช่คำสั่งแยก — หน้าตั้งค่าต้องการทั้งคู่พร้อมกัน
    // เสมอ และสองข้อความที่มาไม่พร้อมกันแปลว่ามีจังหวะที่หน้าจอแสดงของครึ่งเดียว
    char saved[CT_WIFI_MAX_NETS][CT_WIFI_SSID_CAP];
    int n = ct_wifi_saved(saved, CT_WIFI_MAX_NETS);
    cJSON *list = cJSON_AddArrayToObject(root, "nets");
    for (int i = 0; list && i < n; i++) {
        cJSON_AddItemToArray(list, cJSON_CreateString(saved[i]));
    }
    notify_json(root);
}

// --- ลูปหลัก -----------------------------------------------------------------

static void apply_pending(void)
{
    ct_snapshot_t snap;
    char ip[sizeof(s_ip)];
    bool got_snapshot = false, link = false, link_changed = false, wifi = false;
    int backlight = -1;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_has_pending) {
        snap = s_pending;
        s_has_pending = false;
        got_snapshot = true;
    }
    link = s_link;
    wifi = s_wifi_up;
    memcpy(ip, s_ip, sizeof(ip));
    link_changed = s_link_changed;
    s_link_changed = false;
    backlight = s_pending_backlight;
    s_pending_backlight = -1;
    xSemaphoreGive(s_lock);

    // ทาง LAN ไม่มี callback บอกว่ามีใครต่อเข้ามา — ถามเอาตรงนี้ ลูปนี้เดินทุก 10 ms
    // อยู่แล้วและคำตอบคือการอ่านตัวแปรตัวเดียว ถูกกว่าการลากสัญญาณข้ามสองเธรด
    static bool last_lan = false;
    bool lan = ct_lan_client_connected();
    if (lan != last_lan) {
        last_lan = lan;
        link_changed = true;
    }

    if (link_changed) {
        // "สด" คือมีใครสักคนป้อน snapshot อยู่ ไม่ว่าจะทางไหน — จอที่ซ่อนการ์ดทิ้งทั้งที่
        // ข้อมูลกำลังไหลเข้ามาทาง LAN คือจอที่โกหกในทางกลับกัน
        ct_ui_set_connected(link || lan);
        ct_ui_set_link(link, wifi, ip);
    }
    if (got_snapshot) {
        // ไฟอ่านสถานะรวมจาก snapshot เดียวกับที่จอวาด — ไม่ใช่แค่กะพริบตอนมีการเตือนใหม่
        // เพราะคำถามที่ไฟตอบคือ "ตอนนี้ต้องลุกไปทำอะไรไหม" ซึ่งเป็นสภาพต่อเนื่อง
        // ไม่ใช่เหตุการณ์ที่เกิดแล้วผ่านไป
        ct_led_apply(&snap, link || lan);
        ct_ui_set_snapshot(&snap);

        // เกณฑ์เดียวกับที่ไฟใช้ตัดสินว่าต้องเต้น — จอกับไฟต้องไม่เถียงกันเรื่องว่า
        // อะไรคือ "เรื่องที่ต้องมีคน" แค่ตอบคนละคำถามเกี่ยวกับมัน
        bool needs_person = false;
        if (link || lan) {
            for (int i = 0; i < snap.session_count; i++) {
                ct_state_t st = snap.sessions[i].state;
                if (st == CT_STATE_WAITING || st == CT_STATE_ERROR) needs_person = true;
            }
        }
        ct_dim_attention(needs_person);
    }
    if (backlight >= 0) ct_dim_set_user(backlight);
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_lock = xSemaphoreCreateMutex();
    ct_mascot_init();
    ct_lcd_init();
    ct_led_init();
    ct_touch_init();
    ct_dim_init();

    lv_init();
    lv_tick_set_cb(millis_cb);

    s_buf1 = heap_caps_malloc(DRAW_BUF_PX * sizeof(lv_color_t), MALLOC_CAP_DMA);
    s_buf2 = heap_caps_malloc(DRAW_BUF_PX * sizeof(lv_color_t), MALLOC_CAP_DMA);
    assert(s_buf1 && s_buf2);

    lv_display_t *disp = lv_display_create(CT_SCREEN_WIDTH, CT_SCREEN_HEIGHT);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_flush_cb(disp, flush_cb);
    lv_display_set_buffers(disp, s_buf1, s_buf2, DRAW_BUF_PX * sizeof(lv_color_t),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);

    ct_ui_init();
    ct_ui_set_connected(false);
    ct_ui_set_link(false, false, NULL);

    ct_ble_cbs_t cbs = {
        .on_state = on_state,
        .on_config = on_config,
        .on_link = on_link,
    };
    ct_ble_init(&cbs);

    // WiFi ตามหลัง BLE เสมอ: ทางหลักต้องขึ้นก่อน และผลสแกนต้องมีปลายทางให้ส่งไปแล้ว
    ct_wifi_cbs_t wifi_cbs = {
        .on_ap = on_ap,
        .on_ap_end = on_ap_end,
        .on_status = on_wifi_status,
    };
    ct_wifi_init(&wifi_cbs);
    // snapshot ที่มาทาง LAN เข้าประตูเดียวกับที่มาทาง BLE — สองทางเดิน ปลายทางเดียว
    ct_lan_init(on_state);
    ESP_LOGI(TAG, "ready");

    const int step_ms = 10;
    int since_frame = 0;
    int since_heap = 0;
    while (1) {
        apply_pending();
        // อ่านการแตะทุกรอบ ไม่ใช่ทุกเฟรม — นิ้วที่แตะแล้วยกภายในเฟรมเดียวจะหายไป
        // ถ้ารอถึงจังหวะวาด และการอ่านขาหนึ่งขาถูกกว่าการวาดจอมาก
        if (ct_touch_tapped(step_ms)) ct_dim_wake();
        ct_dim_tick(step_ms);
        since_frame += step_ms;
        if (since_frame >= 60) {  // ~16 เฟรมต่อวินาที พอสำหรับอนิเมชันบล็อกสี่เหลี่ยม
            ct_ui_tick();
            ct_led_tick(since_frame);
            since_frame = 0;
        }
        // DRAM static เหลือ ~24KB เท่านั้น (idf.py size) ทาง LAN กับ mDNS เป็นสองตัวที่กิน
        // เพิ่มล่าสุด — ที่รั่วช้าๆ จะไม่โผล่จนกว่าจะพังจริง นาทีละบรรทัดพอให้เห็นเทรนด์
        // จาก monitor ธรรมดาโดยไม่ต้องต่อเครื่องมืออะไร · min คือก้นที่เคยลงไปถึง
        since_heap += step_ms;
        if (since_heap >= 60000) {
            since_heap = 0;
            ESP_LOGI(TAG, "heap %u min %u", (unsigned)esp_get_free_heap_size(),
                     (unsigned)esp_get_minimum_free_heap_size());
        }
        lv_timer_handler();
        vTaskDelay(pdMS_TO_TICKS(step_ms));
    }
}

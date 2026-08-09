// perch — จอแสดงสถานะ Claude Code บนบอร์ด CYD
//
// เส้นทางข้อมูล: BLE write -> staging (mutex) -> ลูปหลัก -> LVGL -> SPI -> จอ
// LVGL ไม่ปลอดภัยกับหลายเธรด ทุกการแตะ UI จึงเกิดในลูปหลักที่เดียว
#include <string.h>

#include "cJSON.h"
#include "pch_ble.h"
#include "pch_lan.h"
#include "pch_lcd.h"
#include "pch_dim.h"
#include "pch_led.h"
#include "pch_night.h"
#include "pch_touch.h"
#include "pch_mascot.h"
#include "pch_model.h"
#include "pch_ui.h"
#include "pch_face.h"
#include "pch_wifi.h"
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

// โหมดทดลองใบหน้า — บิลด์ด้วย `idf.py -DPCH_FACE=1 build` ค่าปกติคือปิด
// ตั้งใจให้เป็นธงคอมไพล์ ไม่ใช่ค่ารันไทม์ เพราะโหมดนี้ไม่คืนค่าและกินจอทั้งใบ
#ifndef PCH_FACE
#define PCH_FACE 0
#endif
#ifndef PCH_RELAYTEST
#define PCH_RELAYTEST 0
#endif
// ตั้งที่อยู่ relay ตอนบูตครั้งเดียวสำหรับการพัฒนา ค่าจะถูกจดลง NVS จึงอยู่ต่อแม้ flash
// ตัวที่ไม่มีธงนี้ทับ — ของจริงมาทาง BLE
//
//   idf.py -DPCH_RELAY_BOOTSTRAP=1 -DPCH_RELAY_HOST=\"1.2.3.4\" -DPCH_RELAY_PORT=7333
//
// **ไม่มีที่อยู่จริงเป็นค่าเริ่มต้น** — relay คือเซิร์ฟเวอร์ของใครสักคน การฝังไว้ใน repo
// แปลว่าบอร์ดของทุกคนที่โหลดไปจะวิ่งไปหาเครื่องนั้นโดยเจ้าของไม่ได้เลือก
#ifndef PCH_RELAY_BOOTSTRAP
#define PCH_RELAY_BOOTSTRAP 0
#endif
#ifndef PCH_RELAY_HOST
#define PCH_RELAY_HOST "192.0.2.1"     // TEST-NET-1 — ต่อไม่ติดโดยตั้งใจ
#endif
#ifndef PCH_RELAY_PORT
#define PCH_RELAY_PORT 7333
#endif

// บัฟเฟอร์วาดของ LVGL: 1/10 ของจอสองก้อน (~15KB) ไม่ใช่ framebuffer เต็ม 150KB
// บอร์ดนี้ไม่มี PSRAM จึงไม่มีทางเลือกอื่นอยู่แล้ว
#define DRAW_LINES 24
#define DRAW_BUF_PX (PCH_SCREEN_WIDTH * DRAW_LINES)

static lv_color_t *s_buf1, *s_buf2;
static SemaphoreHandle_t s_lock;

// ของที่ BLE ฝากไว้ให้ลูปหลักหยิบไปใช้
static pch_snapshot_t s_pending;
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
    pch_lcd_blit(area->x1, area->y1, area->x2, area->y2, px_map, px * 2);
    lv_display_flush_ready(disp);
}

// --- callback จาก NimBLE (คนละเธรดกับ LVGL) ---------------------------------
static void on_state(const char *json, int len)
{
    pch_snapshot_t parsed;
    if (!pch_model_parse(json, len, &parsed)) {
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
// เจ้าของคนละโมดูล — แยกออกมาที่นี่แทนที่จะยัดเข้า `pch_wifi_command` เพื่อไม่ให้โมดูล
// WiFi ต้องรู้จักเรื่องการปิดผนึกเฟรม ซึ่งเป็นคนละชั้นกัน
static bool lan_command(const char *json, int len)
{
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) return false;
    const cJSON *cmd = cJSON_GetObjectItem(root, "c");
    const cJSON *key = cJSON_GetObjectItem(root, "k");
    bool mine = cJSON_IsString(cmd) && strcmp(cmd->valuestring, "key") == 0;
    if (mine && !pch_lan_set_key(cJSON_IsString(key) ? key->valuestring : NULL)) {
        ESP_LOGW(TAG, "lan key rejected");
    }
    // ที่อยู่ relay มาช่องเดียวกับกุญแจ ด้วยเหตุผลเดียวกัน: ช่องนี้บังคับเข้ารหัส BLE
    // อยู่แล้ว และทั้งสองอย่างเป็นการตั้งค่าของทางเดินเดียวกัน
    if (!mine && cJSON_IsString(cmd) && strcmp(cmd->valuestring, "relay") == 0) {
        const cJSON *host = cJSON_GetObjectItem(root, "h");
        const cJSON *port = cJSON_GetObjectItem(root, "p");
        pch_lan_set_relay(cJSON_IsString(host) ? host->valuestring : NULL,
                          cJSON_IsNumber(port) ? (uint16_t)port->valuedouble : 0);
        mine = true;
    }
    cJSON_Delete(root);
    // ตอบกลับด้วยสถานะเต็มใบ ไม่ใช่ ack เปล่า — Mac ต้องเห็นลายนิ้วมือใหม่เพื่อรู้ว่า
    // กุญแจที่มันเพิ่งส่งไปคือกุญแจที่บอร์ดถืออยู่จริง
    if (mine) pch_wifi_report();
    return mine;
}

static void on_config(const char *json, int len)
{
    // คำสั่ง WiFi มาทางเดียวกับความสว่าง แยกด้วยคีย์ "c" — ช่องนี้บังคับเข้ารหัสอยู่แล้ว
    // เพราะรหัส WiFi ต้องผ่านมันไป (pch_ble.h)
    if (lan_command(json, len)) return;
    if (pch_wifi_command(json, len)) return;

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
    pch_ble_notify(text, (int)strlen(text));
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

static const char *wifi_state_name(pch_wifi_state_t st)
{
    switch (st) {
        case PCH_WIFI_CONNECTING: return "connecting";
        case PCH_WIFI_CONNECTED: return "connected";
        case PCH_WIFI_FAILED: return "failed";
        default: return "off";
    }
}

static void on_wifi_status(pch_wifi_state_t st, const char *ssid, const char *ip,
                           const char *err)
{
    bool up = (st == PCH_WIFI_CONNECTED);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_wifi_up = up;
    snprintf(s_ip, sizeof(s_ip), "%s", up && ip ? ip : "");
    s_link_changed = true;
    xSemaphoreGive(s_lock);

    // server ขึ้นตามการมี IP ไม่ใช่ตามการมีกุญแจ — บอร์ดที่รับสายแล้วปฏิเสธทุกเฟรม
    // บอกฝั่ง Mac ได้ว่า "กุญแจไม่ตรง" ส่วนบอร์ดที่ไม่รับสายเลยแยกไม่ออกจากบอร์ดที่ตาย
    pch_lan_set_up(up, ip);

    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "wifi");
    cJSON_AddStringToObject(root, "st", wifi_state_name(st));
    cJSON_AddStringToObject(root, "s", ssid ? ssid : "");
    cJSON_AddStringToObject(root, "ip", ip ? ip : "");
    // ลายนิ้วมือกุญแจ LAN — ว่างแปลว่ายังไม่เคยตั้ง Mac จะได้รู้ว่าต้องส่งไปให้
    cJSON_AddStringToObject(root, "kf", pch_lan_key_fingerprint());
    // Mac ต้องรู้ id นี้เพื่อบอก relay ว่าจะคุยกับบอร์ดตัวไหน — บอร์ดเป็นคนสร้างเอง
    // ไม่ให้ Mac ตั้ง เพราะมันคือความลับที่กันคนอื่นมาเตะบอร์ดหลุด
    cJSON_AddStringToObject(root, "did", pch_lan_device_id());
    if (err && err[0]) cJSON_AddStringToObject(root, "er", err);

    // รายชื่อที่จำไว้เดินทางมากับสถานะ ไม่ใช่คำสั่งแยก — หน้าตั้งค่าต้องการทั้งคู่พร้อมกัน
    // เสมอ และสองข้อความที่มาไม่พร้อมกันแปลว่ามีจังหวะที่หน้าจอแสดงของครึ่งเดียว
    char saved[PCH_WIFI_MAX_NETS][PCH_WIFI_SSID_CAP];
    int n = pch_wifi_saved(saved, PCH_WIFI_MAX_NETS);
    cJSON *list = cJSON_AddArrayToObject(root, "nets");
    for (int i = 0; list && i < n; i++) {
        cJSON_AddItemToArray(list, cJSON_CreateString(saved[i]));
    }
    notify_json(root);
}

// --- ลูปหลัก -----------------------------------------------------------------

static void apply_pending(void)
{
    pch_snapshot_t snap;
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
    bool lan = pch_lan_client_connected();
    if (lan != last_lan) {
        last_lan = lan;
        link_changed = true;
    }

    if (link_changed) {
        // "สด" คือมีใครสักคนป้อน snapshot อยู่ ไม่ว่าจะทางไหน — จอที่ซ่อนการ์ดทิ้งทั้งที่
        // ข้อมูลกำลังไหลเข้ามาทาง LAN คือจอที่โกหกในทางกลับกัน
        pch_ui_set_connected(link || lan);
        pch_ui_set_link(link, wifi, ip);
    }
    if (got_snapshot) {
        // เวลาบนบอร์ดมาจาก snapshot ที่เดียว — บอร์ดไม่มีนาฬิกาจริงของตัวเอง
        // ต้องตั้งก่อนเรียกอย่างอื่น เพราะโหมดกลางคืนตัดสินจากมัน
        pch_night_set_clock(snap.clock);
        // ไฟอ่านสถานะรวมจาก snapshot เดียวกับที่จอวาด — ไม่ใช่แค่กะพริบตอนมีการเตือนใหม่
        // เพราะคำถามที่ไฟตอบคือ "ตอนนี้ต้องลุกไปทำอะไรไหม" ซึ่งเป็นสภาพต่อเนื่อง
        // ไม่ใช่เหตุการณ์ที่เกิดแล้วผ่านไป
        pch_led_apply(&snap, link || lan);
        pch_ui_set_snapshot(&snap);
    }
    if (backlight >= 0) pch_dim_set_user(backlight);
}

// กระจายสถานะกลางคืนไปให้ทุกคนที่ต้องรู้ — เรียกทุกรอบ แต่ละตัวกันซ้ำเอง
//
// อยู่ตรงนี้ไม่ใช่ใน pch_night เพราะ pch_night ตอบคำถามเดียวคือ "ตอนนี้กลางคืนไหม"
// ส่วนใครต้องทำอะไรกับคำตอบนั้นเป็นเรื่องของการต่อสาย ซึ่งเป็นงานของไฟล์นี้
static void apply_night(void)
{
    bool night = pch_night_active();
    pch_ui_set_night(night);
    pch_led_set_night(night);
    pch_dim_set_night(night);
}

// เปลี่ยนเป็น 1 แล้วแฟลช = จอกลายเป็นสีทึบเต็มพื้นที่ ไม่ทำอย่างอื่นเลย
//
// มีไว้วัดขอบจอเพื่อออกแบบกรอบกล่อง — ปัญหาคือ UI ปกติมีแถบบนสีเข้มซึ่งกลืนไปกับขอบดำ
// ของกระจก ทำให้แยกไม่ออกจากรูปถ่ายว่า "ขอบจอจบตรงไหน ภาพเริ่มตรงไหน" สีทึบสว่างเต็มจอ
// ทำให้เส้นแบ่งนั้นคมจนวัดจากรูปได้ตรงๆ
//
// วัดเสร็จเปลี่ยนกลับเป็น 0 แล้วแฟลชใหม่
#ifndef PCH_CALIBRATION
#define PCH_CALIBRATION 0
#endif

#if PCH_CALIBRATION
// ม่วงบานเย็น ไม่ใช่ขาว — ขาวล้นกล้องง่ายจนขอบฟุ้ง และสีนี้ไม่ไปซ้ำกับอะไรในฉากเลย
// (กล่องส้ม โต๊ะไม้ มือ) การคัดสีจากรูปจึงเหลือเป็นการเลือกช่วงสีเดียว
#define CAL_FILL 0xF81F
// แถบเขียวขอบบน 4 พิกเซล — บอกว่าด้านไหนคือด้านบน รูปที่ถ่ายมาเอียงหรือกลับหัวจะได้รู้
#define CAL_MARK 0x07E0
#define CAL_MARK_H 4

static void calibration_screen(void)
{
    // ไล่ทีละแถว ไม่ได้ทำทั้งจอทีเดียว — เต็มจอคือ 320*240*2 = 150 KB ซึ่งเกินแรมที่มี
    static uint8_t row[PCH_SCREEN_WIDTH * 2];
    for (int y = 0; y < PCH_SCREEN_HEIGHT; y++) {
        uint16_t c = (y < CAL_MARK_H) ? CAL_MARK : CAL_FILL;
        for (int x = 0; x < PCH_SCREEN_WIDTH; x++) {
            // สลับไบต์เอง เพราะทางปกติผ่าน lv_draw_sw_rgb565_swap() ก่อน blit
            // ตรงนี้ไม่ได้ผ่าน LVGL เลย ถ้าไม่สลับจะได้สีคนละสีโดยไม่มีอะไรฟ้อง
            row[x * 2] = (uint8_t)(c >> 8);
            row[x * 2 + 1] = (uint8_t)(c & 0xFF);
        }
        pch_lcd_blit(0, y, PCH_SCREEN_WIDTH - 1, y, row, sizeof(row));
    }
    pch_lcd_set_backlight(100);
    ESP_LOGW("cal", "โหมดสอบเทียบ: จอค้างเป็นสีทึบ แถบเขียวคือด้านบน");
}
#endif

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_lock = xSemaphoreCreateMutex();
    pch_mascot_init();
    pch_lcd_init();
#if PCH_CALIBRATION
    // ออกก่อนทุกอย่าง — ไม่เปิด BLE ไม่เปิด WiFi ไม่มีอะไรมาวาดทับ
    calibration_screen();
    return;
#endif
    pch_led_init();
    pch_touch_init();
    pch_dim_init();

    lv_init();
    lv_tick_set_cb(millis_cb);

    s_buf1 = heap_caps_malloc(DRAW_BUF_PX * sizeof(lv_color_t), MALLOC_CAP_DMA);
    s_buf2 = heap_caps_malloc(DRAW_BUF_PX * sizeof(lv_color_t), MALLOC_CAP_DMA);
    assert(s_buf1 && s_buf2);

    lv_display_t *disp = lv_display_create(PCH_SCREEN_WIDTH, PCH_SCREEN_HEIGHT);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_flush_cb(disp, flush_cb);
    lv_display_set_buffers(disp, s_buf1, s_buf2, DRAW_BUF_PX * sizeof(lv_color_t),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);

#if PCH_FACE
    // โหมดทดลองใบหน้า — ออกก่อนจะไปแตะ BLE/WiFi/LED ทั้งหมด เหมือนโหมด calibration
    // ไม่คืนค่า จอจะค้างอยู่ที่หน้าที่ขยับปากอย่างเดียว
    pch_lcd_set_backlight(100);
    pch_face_run();
#endif

    pch_ui_init();
    pch_ui_set_connected(false);
    pch_ui_set_link(false, false, NULL);

    pch_ble_cbs_t cbs = {
        .on_state = on_state,
        .on_config = on_config,
        .on_link = on_link,
    };
    pch_ble_init(&cbs);

    // WiFi ตามหลัง BLE เสมอ: ทางหลักต้องขึ้นก่อน และผลสแกนต้องมีปลายทางให้ส่งไปแล้ว
    pch_wifi_cbs_t wifi_cbs = {
        .on_ap = on_ap,
        .on_ap_end = on_ap_end,
        .on_status = on_wifi_status,
    };
    pch_wifi_init(&wifi_cbs);
    // snapshot ที่มาทาง LAN เข้าประตูเดียวกับที่มาทาง BLE — สองทางเดิน ปลายทางเดียว
    pch_lan_init(on_state);
#if PCH_RELAY_BOOTSTRAP
    pch_lan_set_relay(PCH_RELAY_HOST, PCH_RELAY_PORT);
#endif
#if PCH_RELAYTEST
    // วัด heap ตอนถือ outbound TCP — เริ่มหลังทุกอย่างขึ้นครบ เพื่อให้ตัวเลขสะท้อนของจริง
    void pch_relaytest_start(void);
    pch_relaytest_start();
#endif
    ESP_LOGI(TAG, "ready");

    const int step_ms = 10;
    int since_frame = 0;
    int since_heap = 0;
    while (1) {
        apply_pending();
        // อ่านการแตะทุกรอบ ไม่ใช่ทุกเฟรม — นิ้วที่แตะแล้วยกภายในเฟรมเดียวจะหายไป
        // ถ้ารอถึงจังหวะวาด และการอ่านขาหนึ่งขาถูกกว่าการวาดจอมาก
        if (pch_touch_tapped(step_ms)) {
            // นิ้วเดียวตอบทุกอย่างที่คนที่เพิ่งเดินมาถึงอยากได้พร้อมกัน:
            // เห็นจอชัด ออกจากโหมดกลางคืน และเห็นว่าโควตาเหลือเท่าไร
            pch_night_wake();
            pch_dim_wake();
            pch_ui_peek_usage();
        }
        pch_night_tick(step_ms);
        apply_night();
        pch_dim_tick(step_ms);
        since_frame += step_ms;
        if (since_frame >= 60) {  // ~16 เฟรมต่อวินาที พอสำหรับอนิเมชันบล็อกสี่เหลี่ยม
            pch_ui_tick();
            pch_led_tick(since_frame);
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

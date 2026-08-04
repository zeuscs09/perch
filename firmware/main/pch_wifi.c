#include "pch_wifi.h"

#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"

static const char *TAG = "wifi";

// เก็บทีละก้อนต่อเครือข่าย ไม่ใช่ key แยก ssid/psk — การเขียนสองครั้งเปิดช่องให้
// ไฟดับคาแล้วเหลือ ssid ที่ไม่มีรหัส ซึ่งลูปต่อไม่ติดตลอดโดยไม่มีใครบอกว่าทำไม
typedef struct {
    char ssid[PCH_WIFI_SSID_CAP];
    char psk[PCH_WIFI_PSK_CAP];
} net_t;

#define NVS_NS "tamawifi"

// ตัดให้พอดีปลายทางแบบเงียบๆ — ปลายทางบางที่ (`wifi_config_t`) สั้นกว่าที่เราเก็บอยู่
// หนึ่งไบต์เพราะไม่ได้เผื่อ NUL และ `snprintf` จะเตือนเป็น error ทุกครั้งที่เห็นแบบนั้น
static void copy_str(char *dst, size_t cap, const char *src)
{
    if (cap == 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    // คัดลอกทีละไบต์ ไม่ใช่ strnlen+memcpy — ต้นทางบางตัวเป็นสตริงคงที่ที่สั้นกว่า cap
    // แล้ว GCC จะฟ้อง stringop-overread ทั้งที่โค้ดถูก
    size_t i = 0;
    while (i + 1 < cap && src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

static pch_wifi_cbs_t s_cbs;
static net_t s_nets[PCH_WIFI_MAX_NETS];
static int s_net_count;

static pch_wifi_state_t s_state = PCH_WIFI_OFF;
static char s_ssid[PCH_WIFI_SSID_CAP];
static char s_ip[16];
static char s_err[24];

// สแกนมีสองความหมายและผลลัพธ์ไปคนละที่ ตัวแปรเดียวจึงต้องบอกว่ารอบนี้ใครสั่ง
typedef enum { SCAN_NONE, SCAN_REPORT, SCAN_PICK } scan_mode_t;
static scan_mode_t s_scan = SCAN_NONE;
static bool s_started;

static esp_timer_handle_t s_retry;
static int s_backoff_ms = 1000;

static void report(void)
{
    if (s_cbs.on_status) s_cbs.on_status(s_state, s_ssid, s_ip, s_err);
}

static void set_state(pch_wifi_state_t st, const char *err)
{
    s_state = st;
    copy_str(s_err, sizeof(s_err), err);
    if (st != PCH_WIFI_CONNECTED) s_ip[0] = '\0';
    report();
}

// --- เครือข่ายที่จำไว้ ---------------------------------------------------------
static void nets_load(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return;
    for (int i = 0; i < PCH_WIFI_MAX_NETS; i++) {
        char key[8];
        snprintf(key, sizeof(key), "n%d", i);
        size_t len = sizeof(net_t);
        net_t n;
        if (nvs_get_blob(h, key, &n, &len) != ESP_OK || len != sizeof(net_t)) continue;
        if (n.ssid[0] == '\0') continue;
        s_nets[s_net_count++] = n;
    }
    nvs_close(h);
    ESP_LOGI(TAG, "%d saved network(s)", s_net_count);
}

static void nets_store(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    for (int i = 0; i < PCH_WIFI_MAX_NETS; i++) {
        char key[8];
        snprintf(key, sizeof(key), "n%d", i);
        if (i < s_net_count) {
            nvs_set_blob(h, key, &s_nets[i], sizeof(net_t));
        } else {
            nvs_erase_key(h, key);
        }
    }
    nvs_commit(h);
    nvs_close(h);
}

static net_t *net_find(const char *ssid)
{
    for (int i = 0; i < s_net_count; i++) {
        if (strcmp(s_nets[i].ssid, ssid) == 0) return &s_nets[i];
    }
    return NULL;
}

static void net_remember(const char *ssid, const char *psk)
{
    net_t *existing = net_find(ssid);
    if (existing) {
        copy_str(existing->psk, sizeof(existing->psk), psk);
    } else {
        // เต็มแล้วให้ตัวเก่าสุดหลุดออก ไม่ใช่ปฏิเสธตัวใหม่ — ผู้ใช้ที่กำลังยืนอยู่หน้า
        // เครือข่ายใหม่ต้องการตัวนี้ ส่วนตัวที่จำไว้ตั้งแต่ปีที่แล้วไม่มีใครคิดถึง
        if (s_net_count == PCH_WIFI_MAX_NETS) {
            memmove(&s_nets[0], &s_nets[1], sizeof(net_t) * (PCH_WIFI_MAX_NETS - 1));
            s_net_count--;
        }
        net_t *n = &s_nets[s_net_count++];
        copy_str(n->ssid, sizeof(n->ssid), ssid);
        copy_str(n->psk, sizeof(n->psk), psk);
    }
    nets_store();
}

// --- การต่อ --------------------------------------------------------------------
static void connect_to(const net_t *n)
{
    wifi_config_t cfg = {0};
    copy_str((char *)cfg.sta.ssid, sizeof(cfg.sta.ssid), n->ssid);
    copy_str((char *)cfg.sta.password, sizeof(cfg.sta.password), n->psk);
    cfg.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    esp_wifi_set_config(WIFI_IF_STA, &cfg);
    copy_str(s_ssid, sizeof(s_ssid), n->ssid);
    set_state(PCH_WIFI_CONNECTING, NULL);
    esp_wifi_connect();
}

static void search(void)
{
    if (s_net_count == 0) {
        set_state(PCH_WIFI_OFF, NULL);
        return;
    }
    // สแกนก่อนต่อเสมอ แม้จะจำเครือข่ายเดียว — เลือกตัวที่แรงที่สุดในบรรดาที่จำไว้
    // ได้ และรู้ได้ว่า "ไม่เจอเลย" ต่างจาก "รหัสผิด" ซึ่งผู้ใช้ต้องแก้คนละอย่าง
    s_scan = SCAN_PICK;
    if (esp_wifi_scan_start(NULL, false) != ESP_OK) {
        s_scan = SCAN_NONE;
        set_state(PCH_WIFI_FAILED, "scan busy");
    }
}

static void retry_cb(void *arg) { search(); }

static void schedule_retry(void)
{
    // เพดาน 60 วิ ไม่ใช่การเลิกล้ม: บอร์ดอยู่บนโต๊ะทั้งวัน เครือข่ายที่หายไปตอนเช้า
    // กลับมาตอนบ่ายได้ และไม่มีใครมากดปุ่มให้ลองใหม่
    if (s_backoff_ms < 60000) s_backoff_ms *= 2;
    esp_timer_stop(s_retry);
    esp_timer_start_once(s_retry, (uint64_t)s_backoff_ms * 1000);
}

// --- เหตุการณ์จาก esp_wifi -----------------------------------------------------
static void emit_scan_results(void)
{
    uint16_t num = 0;
    esp_wifi_scan_get_ap_num(&num);
    if (num > 20) num = 20;  // จอเดียวไม่มีใครไล่อ่านเกินยี่สิบ และ RAM ไม่ได้มีเหลือ
    wifi_ap_record_t *recs = calloc(num, sizeof(wifi_ap_record_t));
    if (!recs) {
        esp_wifi_clear_ap_list();
        if (s_cbs.on_ap_end) s_cbs.on_ap_end();
        return;
    }
    esp_wifi_scan_get_ap_records(&num, recs);

    for (int i = 0; i < num; i++) {
        const char *ssid = (const char *)recs[i].ssid;
        if (ssid[0] == '\0') continue;
        // AP เดียวกันโผล่หลายช่อง/หลายย่าน — รายการที่มีชื่อซ้ำอ่านเหมือนบอร์ดพัง
        bool dup = false;
        for (int j = 0; j < i && !dup; j++) {
            dup = strcmp(ssid, (const char *)recs[j].ssid) == 0;
        }
        if (dup) continue;
        if (s_cbs.on_ap) {
            s_cbs.on_ap(ssid, recs[i].rssi, recs[i].authmode != WIFI_AUTH_OPEN);
        }
        // notification ไม่มี flow control ฝั่งเรา ปล่อยรัวจนคิวของ NimBLE ล้นแล้ว
        // รายการจะขาดหายเป็นช่วงๆ ซึ่งดูเหมือนสัญญาณอ่อน ไม่ใช่บั๊ก
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    free(recs);
    if (s_cbs.on_ap_end) s_cbs.on_ap_end();
}

static void pick_from_scan(void)
{
    uint16_t num = 0;
    esp_wifi_scan_get_ap_num(&num);
    if (num > 30) num = 30;
    wifi_ap_record_t *recs = calloc(num, sizeof(wifi_ap_record_t));
    if (!recs) {
        esp_wifi_clear_ap_list();
        schedule_retry();
        return;
    }
    esp_wifi_scan_get_ap_records(&num, recs);

    const net_t *best = NULL;
    int8_t best_rssi = -127;
    for (int i = 0; i < num; i++) {
        net_t *n = net_find((const char *)recs[i].ssid);
        if (n && recs[i].rssi > best_rssi) {
            best = n;
            best_rssi = recs[i].rssi;
        }
    }
    free(recs);

    if (!best) {
        set_state(PCH_WIFI_FAILED, "not in range");
        schedule_retry();
        return;
    }
    connect_to(best);
}

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        s_started = true;
        search();
        return;
    }
    if (base == WIFI_EVENT && id == WIFI_EVENT_SCAN_DONE) {
        scan_mode_t mode = s_scan;
        s_scan = SCAN_NONE;
        if (mode == SCAN_REPORT) {
            emit_scan_results();
        } else if (mode == SCAN_PICK) {
            pick_from_scan();
        } else {
            esp_wifi_clear_ap_list();
        }
        return;
    }
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *d = data;
        // เหตุผลของการหลุดคือสิ่งเดียวที่แยก "รหัสผิด" (ผู้ใช้ต้องพิมพ์ใหม่) ออกจาก
        // "สัญญาณหลุด" (รอเดี๋ยวก็กลับ) ได้ ข้อความบนหน้าตั้งค่าจึงต้องมาจากตรงนี้
        const char *err = "disconnected";
        if (d->reason == WIFI_REASON_NO_AP_FOUND) err = "not in range";
        if (d->reason == WIFI_REASON_AUTH_FAIL || d->reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT
            || d->reason == WIFI_REASON_HANDSHAKE_TIMEOUT) {
            err = "wrong password";
        }
        set_state(PCH_WIFI_FAILED, err);
        schedule_retry();
        return;
    }
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *e = data;
        snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&e->ip_info.ip));
        s_backoff_ms = 1000;
        set_state(PCH_WIFI_CONNECTED, NULL);
        ESP_LOGI(TAG, "connected to %s as %s", s_ssid, s_ip);
        return;
    }
}

// --- API ----------------------------------------------------------------------
void pch_wifi_init(const pch_wifi_cbs_t *cbs)
{
    s_cbs = *cbs;
    nets_load();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                        wifi_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                        wifi_event, NULL, NULL));
    // เก็บ credential เองใน NVS namespace ของเรา ไม่ให้ esp_wifi เขียนทับซ้อน —
    // ต้นทางเดียวเท่านั้นที่รู้ว่าเราจำอะไรไว้ ไม่งั้น "ลืมเครือข่าย" จะลืมไม่หมด
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    // วิทยุตัวเดียวกันแบ่งกับ BLE อยู่ — โหมดประหยัดไฟทำให้ค่าหน่วงพุ่งเป็นวินาที
    // ซึ่งกินเวลาที่เราตั้งใจประหยัดตอน BLE หลุดไปทั้งหมด
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    const esp_timer_create_args_t args = {.callback = retry_cb, .name = "wifi_retry"};
    ESP_ERROR_CHECK(esp_timer_create(&args, &s_retry));

    ESP_ERROR_CHECK(esp_wifi_start());
}

void pch_wifi_scan(void)
{
    if (!s_started || s_scan != SCAN_NONE) return;
    s_scan = SCAN_REPORT;
    if (esp_wifi_scan_start(NULL, false) != ESP_OK) {
        s_scan = SCAN_NONE;
        if (s_cbs.on_ap_end) s_cbs.on_ap_end();
    }
}

void pch_wifi_join(const char *ssid, const char *psk)
{
    if (!ssid || ssid[0] == '\0') return;
    net_remember(ssid, psk);
    s_backoff_ms = 1000;
    esp_timer_stop(s_retry);
    net_t *n = net_find(ssid);
    if (!n) return;
    // ตัดของเดิมก่อน ไม่งั้น esp_wifi_connect ตัวที่สองคืน ESP_ERR_WIFI_CONN เงียบๆ
    // แล้วผู้ใช้เห็นหน้าจอค้างที่ชื่อเครือข่ายเก่า
    esp_wifi_disconnect();
    connect_to(n);
}

void pch_wifi_forget(const char *ssid)
{
    net_t *n = net_find(ssid);
    if (!n) return;
    int idx = (int)(n - s_nets);
    memmove(&s_nets[idx], &s_nets[idx + 1], sizeof(net_t) * (s_net_count - idx - 1));
    s_net_count--;
    nets_store();
    if (strcmp(s_ssid, ssid) == 0) {
        esp_wifi_disconnect();
        s_ssid[0] = '\0';
        s_backoff_ms = 1000;
        search();
    }
}

int pch_wifi_saved(char out[][PCH_WIFI_SSID_CAP], int cap)
{
    int n = s_net_count < cap ? s_net_count : cap;
    for (int i = 0; i < n; i++) copy_str(out[i], PCH_WIFI_SSID_CAP, s_nets[i].ssid);
    return n;
}

pch_wifi_state_t pch_wifi_state(void) { return s_state; }

const char *pch_wifi_ip(void) { return s_ip; }

void pch_wifi_report(void) { report(); }

bool pch_wifi_command(const char *json, int len)
{
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) return false;
    const cJSON *cmd = cJSON_GetObjectItem(root, "c");
    if (!cJSON_IsString(cmd) || !cmd->valuestring) {
        cJSON_Delete(root);
        return false;
    }
    const char *c = cmd->valuestring;
    const cJSON *ssid = cJSON_GetObjectItem(root, "ssid");
    const cJSON *psk = cJSON_GetObjectItem(root, "psk");

    if (strcmp(c, "scan") == 0) {
        pch_wifi_scan();
    } else if (strcmp(c, "join") == 0 && cJSON_IsString(ssid)) {
        pch_wifi_join(ssid->valuestring, cJSON_IsString(psk) ? psk->valuestring : NULL);
    } else if (strcmp(c, "forget") == 0 && cJSON_IsString(ssid)) {
        pch_wifi_forget(ssid->valuestring);
    } else if (strcmp(c, "status") == 0) {
        pch_wifi_report();
    }
    cJSON_Delete(root);
    return true;
}

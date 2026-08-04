#include "pch_ble.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
// ประกาศเอง: `store/config/ble_store_config.h` ไม่มีบรรทัดนี้ แม้ตัวฟังก์ชันจะอยู่ใน
// คอมโพเนนต์เดียวกัน (ตัวอย่างของ ESP-IDF ทุกตัวก็ประกาศเองแบบนี้)
void ble_store_config_init(void);
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "pch_lcd.h"

static const char *TAG = "ble";

// ชื่อต้องไม่ซ้ำกันเมื่อมีหลายบอร์ดในห้องเดียวกัน ไม่งั้นผู้ใช้เลือกไม่ถูกว่าตัวไหนคือตัวไหน
// ต่อท้ายด้วยสองไบต์สุดท้ายของ MAC ซึ่งพิมพ์อยู่บนตัวบอร์ดอยู่แล้ว
static char s_device_name[24] = "perch";

// BLE_UUID128_INIT รับไบต์เรียงกลับ (LSB ก่อน)
#define UUID128_TAMA(last)                                                                \
    BLE_UUID128_INIT(last, 0x00, 0x0A, 0x3F, 0x5C, 0x1D, 0x2A, 0x9E, 0x6D, 0x4B, 0x1E,    \
                     0x4C, last, 0x00, 0x9B, 0x7A)

static const ble_uuid128_t SVC_UUID = UUID128_TAMA(0x01);
static const ble_uuid128_t CHR_STATE = UUID128_TAMA(0x02);
static const ble_uuid128_t CHR_CONFIG = UUID128_TAMA(0x03);
static const ble_uuid128_t CHR_EVENT = UUID128_TAMA(0x04);

static pch_ble_cbs_t s_cbs;
static uint8_t s_addr_type;
static uint16_t s_event_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
// notify ที่ยังไม่มีใครสมัครรับคือการเผาแบตกับเวลาวิทยุเปล่าๆ และ NimBLE คืน error
// ทุกครั้ง ซึ่งจะกลบ log จริงตอนสแกน WiFi ที่ยิงยี่สิบข้อความรวด
static bool s_event_subscribed;

static void advertise(void);

static int chr_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                      void *arg)
{
    switch (ctxt->op) {
        case BLE_GATT_ACCESS_OP_WRITE_CHR: {
            // snapshot มาเป็นก้อนเดียวเสมอ (daemon ตัดให้พอดี 1 MTU แล้ว) ไม่มี chunking
            uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
            static char buf[600];
            if (len >= sizeof(buf)) {
                ESP_LOGW(TAG, "write of %u bytes is larger than one MTU, dropped", len);
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            uint16_t copied = 0;
            if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &copied) != 0) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            buf[copied] = '\0';
            if (ble_uuid_cmp(ctxt->chr->uuid, &CHR_STATE.u) == 0) {
                if (s_cbs.on_state) s_cbs.on_state(buf, copied);
            } else if (s_cbs.on_config) {
                s_cbs.on_config(buf, copied);
            }
            return 0;
        }
        case BLE_GATT_ACCESS_OP_READ_CHR: {
            char json[48];
            int n = snprintf(json, sizeof(json), "{\"b\":%d}", pch_lcd_backlight());
            return os_mbuf_append(ctxt->om, json, n) == 0 ? 0
                                                         : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        default:
            return BLE_ATT_ERR_UNLIKELY;
    }
}

static const struct ble_gatt_svc_def GATT_SVCS[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &SVC_UUID.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &CHR_STATE.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &CHR_CONFIG.u,
                .access_cb = chr_access,
                // รหัส WiFi ของผู้ใช้เดินผ่านตัวนี้ — เขียนได้เฉพาะเมื่อลิงก์เข้ารหัสแล้ว
                // อ่านไม่บังคับ (มีแค่ความสว่าง) เพื่อไม่ให้ macOS เด้งจับคู่ตอนแค่เปิดแอป
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE
                         | BLE_GATT_CHR_F_WRITE_ENC,
            },
            {
                .uuid = &CHR_EVENT.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_event_handle,
            },
            {0},
        },
    },
    {0},
};

static int gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            ESP_LOGI(TAG, "connect %s", event->connect.status == 0 ? "ok" : "failed");
            if (event->connect.status == 0) {
                s_conn_handle = event->connect.conn_handle;
            } else {
                advertise();
            }
            if (s_cbs.on_link) s_cbs.on_link(event->connect.status == 0);
            return 0;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "disconnect, advertising again");
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            s_event_subscribed = false;
            if (s_cbs.on_link) s_cbs.on_link(false);
            advertise();
            return 0;

        case BLE_GAP_EVENT_SUBSCRIBE:
            if (event->subscribe.attr_handle == s_event_handle) {
                s_event_subscribed = event->subscribe.cur_notify;
            }
            return 0;

        case BLE_GAP_EVENT_ENC_CHANGE:
            ESP_LOGI(TAG, "encryption change: %d", event->enc_change.status);
            return 0;

        case BLE_GAP_EVENT_REPEAT_PAIRING: {
            // ทุกครั้งที่แฟลชใหม่ bond เดิมฝั่งบอร์ดหายไปแต่ฝั่ง Mac ยังจำอยู่ ถ้าไม่ทิ้ง
            // ของเก่าทิ้งแล้วจับคู่ใหม่ ผู้ใช้จะต้องไปลบอุปกรณ์ใน System Settings เอง
            // ซึ่งบอร์ด GATT ล้วนไม่โผล่ให้ลบตรงนั้นด้วยซ้ำ
            struct ble_gap_conn_desc desc;
            if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
                ble_store_util_delete_peer(&desc.peer_id_addr);
            }
            return BLE_GAP_REPEAT_PAIRING_RETRY;
        }

        case BLE_GAP_EVENT_ADV_COMPLETE:
            advertise();
            return 0;

        case BLE_GAP_EVENT_MTU:
            ESP_LOGI(TAG, "mtu now %d", event->mtu.value);
            return 0;

        default:
            return 0;
    }
}

static void advertise(void)
{
    // adv 31 ไบต์ไม่พอใส่ทั้ง UUID 128 บิตและชื่อ — ชื่อจึงไปอยู่ใน scan response
    // ฝั่ง Mac สแกนด้วย service UUID จึงต้องเป็นตัวที่อยู่ใน adv
    struct ble_hs_adv_fields adv = {0};
    adv.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    adv.uuids128 = (ble_uuid128_t *)&SVC_UUID;
    adv.num_uuids128 = 1;
    adv.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&adv);
    if (rc != 0) ESP_LOGE(TAG, "adv fields failed: %d", rc);

    struct ble_hs_adv_fields rsp = {0};
    rsp.name = (uint8_t *)s_device_name;
    rsp.name_len = strlen(s_device_name);
    rsp.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) ESP_LOGE(TAG, "scan rsp failed: %d", rc);

    struct ble_gap_adv_params params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    rc = ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0) ESP_LOGE(TAG, "adv start failed: %d", rc);
}

static void on_sync(void)
{
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_addr_type);

    uint8_t addr[6] = {0};
    if (ble_hs_id_copy_addr(s_addr_type, addr, NULL) == 0) {
        // addr เรียงกลับ (LSB ก่อน) สองไบต์สุดท้ายของ MAC จึงอยู่ที่ index 1 กับ 0
        snprintf(s_device_name, sizeof(s_device_name), "perch-%02x%02x", addr[1],
                 addr[0]);
        ble_svc_gap_device_name_set(s_device_name);
    }
    ESP_LOGI(TAG, "advertising as %s", s_device_name);
    advertise();
}

static void on_reset(int reason) { ESP_LOGW(TAG, "host reset: %d", reason); }

void pch_ble_notify(const char *json, int len)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE || !s_event_subscribed) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(json, len);
    if (!om) return;
    int rc = ble_gatts_notify_custom(s_conn_handle, s_event_handle, om);
    if (rc != 0) ESP_LOGW(TAG, "notify failed: %d", rc);
}

const char *pch_ble_name(void) { return s_device_name; }

static void host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void pch_ble_init(const pch_ble_cbs_t *cbs)
{
    s_cbs = *cbs;
    ESP_ERROR_CHECK(nimble_port_init());

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    // จับคู่แบบไม่มีปุ่มไม่มีจอให้ยืนยัน (Just Works) — กันคนดักฟังผ่านๆ ได้ ไม่กัน
    // MITM ที่อยู่ตรงนั้นพอดีตอนกด Connect ซึ่งเป็นราคาที่ยอมจ่ายเพราะบอร์ดไม่มีทาง
    // ให้ผู้ใช้เทียบเลขหกหลักเลย
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_store_config_init();

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(GATT_SVCS));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(GATT_SVCS));
    ESP_ERROR_CHECK(ble_svc_gap_device_name_set(s_device_name));

    nimble_port_freertos_init(host_task);
}

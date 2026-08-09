#include "pch_lan.h"

#include <string.h>

#include "pch_ble.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "mbedtls/gcm.h"
#include "mbedtls/sha256.h"
#include "mdns.h"
#include "nvs.h"

static const char *TAG = "lan";

#define NVS_NS "tamalan"
#define KEY_BLOB "key"
#define KEY_FLOOR "floor"
#define KEY_RHOST "rhost"
#define KEY_RPORT "rport"
#define KEY_DEVID "devid"

// device-id ยาว 22 ตัวจากชุด 64 = 132 บิต — relay ไม่ถือกุญแจอะไรเลย มันจึงยืนยันตัวตน
// ใครไม่ได้ และกฎ "สายใหม่เตะสายเก่า" (ซึ่งจำเป็น ไม่งั้นบอร์ดที่เน็ตหลุดกลับเข้าไม่ได้)
// แปลว่าคนที่เดา id ถูกเตะบอร์ดหลุดได้ — id จึงต้องเป็นความลับ ไม่ใช่ชื่อเรียกสวยๆ
#define DEVID_LEN 22

// จดตัวนับลง NVS ทุก 256 เฟรม ไม่ใช่ทุกเฟรม — snapshot เดินทางทุกไม่กี่วินาที
// การเขียน flash ทุกครั้งจะกินอายุเซกเตอร์หมดภายในไม่กี่เดือน ราคาของช่วงห่างนี้คือ
// หลังไฟดับ ตัวนับกระโดดไปข้างหน้าอย่างมาก 256 ซึ่งไม่มีผลอะไรนอกจากเลขใหญ่ขึ้น
#define FLOOR_STRIDE 256

// snapshot ถูกบีบให้ไม่เกิน 500 ไบต์ตั้งแต่ฝั่ง daemon (Wire.maxPayload) — เผื่ออีกหน่อย
// แล้วปฏิเสธทุกอย่างที่ใหญ่กว่านั้น เฟรมยักษ์จากคนแปลกหน้าไม่ควรได้ RAM ของเราไปฟรีๆ
#define MAX_CIPHERTEXT 560
#define NONCE_LEN 12
#define TAG_LEN 16
#define MAX_BODY (NONCE_LEN + MAX_CIPHERTEXT + TAG_LEN)

// คำทักทายที่บอร์ดส่งทันทีที่มีคนต่อเข้ามา: มายิก + เวอร์ชัน + ตัวนับที่รับไปถึงแล้ว
//
// Mac ใช้เลขนี้ตั้งตัวนับของตัวเองต่อจากของบอร์ด จึงไม่ต้องเก็บไฟล์ตัวนับไว้ฝั่งตัวเอง
// (ไฟล์นั้นหายเมื่อไรก็แปลว่าต่อไม่ได้อีกเลยจนกว่าจะเปลี่ยนกุญแจ) การโกหกเลขนี้ทำได้แค่
// ดันตัวนับให้สูงขึ้น ซึ่งไม่เปิดทางให้เฟรมเก่าถูกรับ
#define GREETING_LEN 13
static const uint8_t GREETING_MAGIC[4] = {'T', 'A', 'M', 'A'};
#define GREETING_VERSION 1

static pch_lan_frame_cb_t s_cb;

// กุญแจถูกเปลี่ยนจากเธรด BLE ระหว่างที่เธรดนี้อาจกำลังถอดรหัสอยู่
static SemaphoreHandle_t s_key_lock;
static uint8_t s_key[PCH_LAN_KEY_BYTES];
static bool s_has_key;
static char s_fp[9];

static uint64_t s_seen;   // ตัวนับสูงสุดที่รับไปแล้ว
static uint64_t s_floor;  // ที่จดไว้ใน NVS — มากกว่าหรือเท่ากับ s_seen เสมอ

static volatile bool s_up;
static int s_listen = -1;
static int s_client = -1;
static bool s_mdns_up;

// --- ทางออกนอกบ้าน: บอร์ดวิ่งไปหา relay เอง (issue #1) -----------------------------
//
// เปิดพร้อม listener ได้เลย ไม่ต้องเลือกอย่างใดอย่างหนึ่ง — วัดแล้วซ็อกเก็ตขาออกกิน
// heap แค่ ~556 ไบต์ จาก 23.6KB ที่เหลือตอนต่ำสุด Mac เป็นคนเลือกว่าจะเข้าทางไหน
static char s_rhost[64];
static uint16_t s_rport;
static char s_devid[DEVID_LEN + 1];
static int s_relay = -1;
// ทักซ้ำจนกว่าจะได้เฟรมแรก: relay ไม่เก็บคิว บอร์ดต่อก่อน Mac เสมอ คำทักทายใบแรกจึง
// หายไปในความว่างเปล่า และ Mac ที่ต่อกลับรอบสองก็ต้องได้ยินใหม่ด้วย
static bool s_relay_paired;
static int64_t s_relay_greet_ms;

// --- NVS ----------------------------------------------------------------------
static void store_load(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return;
    size_t len = sizeof(s_key);
    if (nvs_get_blob(h, KEY_BLOB, s_key, &len) == ESP_OK && len == sizeof(s_key)) {
        s_has_key = true;
    }
    uint64_t floor = 0;
    if (nvs_get_u64(h, KEY_FLOOR, &floor) == ESP_OK) {
        s_floor = floor;
        s_seen = floor;
    }
    size_t n = sizeof(s_rhost);
    if (nvs_get_str(h, KEY_RHOST, s_rhost, &n) != ESP_OK) s_rhost[0] = '\0';
    uint16_t port = 0;
    if (nvs_get_u16(h, KEY_RPORT, &port) == ESP_OK) s_rport = port;
    n = sizeof(s_devid);
    if (nvs_get_str(h, KEY_DEVID, s_devid, &n) != ESP_OK) s_devid[0] = '\0';
    nvs_close(h);
}

/// สร้าง device-id ครั้งเดียวตลอดชีพของบอร์ด แล้วจดไว้
///
/// สร้างเองไม่ให้ Mac เป็นคนตั้ง เพราะมันคือความลับที่กันคนอื่นมาเตะบอร์ดหลุด และ
/// esp_random() หลัง WiFi เริ่มแล้วเป็น TRNG จริง ไม่ใช่ PRNG ที่เดาได้จากเวลาเปิดเครื่อง
static void ensure_devid(void)
{
    if (s_devid[0]) return;
    static const char AB[] =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
    for (int i = 0; i < DEVID_LEN; i++) s_devid[i] = AB[esp_random() % 64];
    s_devid[DEVID_LEN] = '\0';
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, KEY_DEVID, s_devid);
        nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "device id %s (สร้างใหม่)", s_devid);
}

static void store_floor(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_u64(h, KEY_FLOOR, s_floor);
    nvs_commit(h);
    nvs_close(h);
}

static void fingerprint(void)
{
    s_fp[0] = '\0';
    if (!s_has_key) return;
    uint8_t hash[32];
    if (mbedtls_sha256(s_key, sizeof(s_key), hash, 0) != 0) return;
    static const char HEX[] = "0123456789abcdef";
    for (int i = 0; i < 4; i++) {
        s_fp[i * 2] = HEX[hash[i] >> 4];
        s_fp[i * 2 + 1] = HEX[hash[i] & 0x0f];
    }
    s_fp[8] = '\0';
}

// --- เฟรม ----------------------------------------------------------------------
static bool read_all(int fd, uint8_t *buf, size_t want)
{
    size_t got = 0;
    while (got < want) {
        int n = recv(fd, buf + got, want - got, 0);
        if (n <= 0) return false;
        got += (size_t)n;
    }
    return true;
}

static uint64_t be64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
    return v;
}

// คืน false = ตัดสาย ไม่มีการ "ข้ามเฟรมนี้แล้วอ่านต่อ": ความยาวที่อ่านผิดไปหนึ่งไบต์
// ทำให้ทุกเฟรมหลังจากนั้นเพี้ยนหมด และเฟรมที่ยืนยันตัวไม่ผ่านคือสัญญาณว่าอีกฝั่งไม่ใช่ Mac
// ของเรา ไม่ใช่ความผิดพลาดชั่วคราวที่รอได้
static bool read_frame(int fd)
{
    uint8_t header[4];
    if (!read_all(fd, header, sizeof(header))) return false;
    uint32_t len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16)
                   | ((uint32_t)header[2] << 8) | header[3];
    if (len < NONCE_LEN + TAG_LEN || len > MAX_BODY) {
        ESP_LOGW(TAG, "frame length %u out of range", (unsigned)len);
        return false;
    }

    static uint8_t body[MAX_BODY];
    static char plain[MAX_CIPHERTEXT + 1];
    if (!read_all(fd, body, len)) return false;

    size_t clen = len - NONCE_LEN - TAG_LEN;
    const uint8_t *nonce = body;
    const uint8_t *cipher = body + NONCE_LEN;
    const uint8_t *tag = cipher + clen;

    bool ok = false;
    xSemaphoreTake(s_key_lock, portMAX_DELAY);
    if (s_has_key) {
        mbedtls_gcm_context gcm;
        mbedtls_gcm_init(&gcm);
        if (mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, s_key, 256) == 0) {
            ok = mbedtls_gcm_auth_decrypt(&gcm, clen, nonce, NONCE_LEN, NULL, 0, tag,
                                          TAG_LEN, cipher, (uint8_t *)plain)
                 == 0;
        }
        mbedtls_gcm_free(&gcm);
    }
    xSemaphoreGive(s_key_lock);

    if (!ok) {
        ESP_LOGW(TAG, "frame did not authenticate");
        return false;
    }

    // ตัวนับอยู่ใน nonce ไม่ใช่ใน plaintext — มันต้องถูกตรวจได้ *หลัง* ยืนยันตัวผ่านแล้ว
    // แต่ต้องเป็นค่าเดียวกับที่ใช้ถอดรหัส ไม่งั้นคนกลางสลับตัวเลขสองที่ให้ไม่ตรงกันได้
    uint64_t counter = be64(nonce + 4);
    if (counter <= s_seen) {
        ESP_LOGW(TAG, "replayed counter %llu (already at %llu)",
                 (unsigned long long)counter, (unsigned long long)s_seen);
        return false;
    }
    s_seen = counter;
    if (s_seen >= s_floor) {
        s_floor = s_seen + FLOOR_STRIDE;
        store_floor();
    }

    plain[clen] = '\0';
    if (s_cb) s_cb(plain, (int)clen);
    return true;
}

// --- socket --------------------------------------------------------------------
static void close_client(void)
{
    if (s_client < 0) return;
    close(s_client);
    s_client = -1;
}

static void close_listen(void)
{
    close_client();
    if (s_listen < 0) return;
    close(s_listen);
    s_listen = -1;
}

static bool open_listen(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return false;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(PCH_LAN_PORT),
        .sin_addr = {.s_addr = htonl(INADDR_ANY)},
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 1) != 0) {
        ESP_LOGE(TAG, "cannot listen on %d: errno %d", PCH_LAN_PORT, errno);
        close(fd);
        return false;
    }
    s_listen = fd;
    ESP_LOGI(TAG, "listening on port %d", PCH_LAN_PORT);
    return true;
}

static void greet(int fd)
{
    uint8_t hello[GREETING_LEN];
    memcpy(hello, GREETING_MAGIC, sizeof(GREETING_MAGIC));
    hello[4] = GREETING_VERSION;
    uint64_t floor = s_floor > s_seen ? s_floor : s_seen;
    for (int i = 0; i < 8; i++) hello[5 + i] = (uint8_t)(floor >> (56 - i * 8));
    send(fd, hello, sizeof(hello), 0);
}

static void take_client(int fd)
{
    // ตัวใหม่ชนะตัวเก่าเสมอ: Mac ที่เพิ่งกลับมาจากหลับมีซ็อกเก็ตค้างฝั่งบอร์ดอยู่ ซึ่ง
    // TCP ฝั่งนี้ยังไม่รู้ว่าตายจนกว่า keepalive จะครบ — ระหว่างนั้นจอจะค้างโดยไม่มีเหตุผล
    close_client();
    s_client = fd;

    int on = 1, idle = 10, intvl = 5, cnt = 3;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
    // เฟรมที่มาไม่ครบต้องไม่ค้างเธรดนี้ไว้ตลอดกาล — ครึ่งเฟรมคือสายที่ใช้ไม่ได้แล้ว
    struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    greet(fd);
    ESP_LOGI(TAG, "mac connected");
}

// --- ทางออกนอกบ้าน ---------------------------------------------------------------
static void close_relay(void)
{
    if (s_relay < 0) return;
    close(s_relay);
    s_relay = -1;
    s_relay_paired = false;
}

static bool open_relay(void)
{
    if (!s_rhost[0] || !s_rport) return false;
    ensure_devid();

    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return false;
    struct sockaddr_in dst = {.sin_family = AF_INET, .sin_port = htons(s_rport)};
    dst.sin_addr.s_addr = inet_addr(s_rhost);
    // ปลายทางข้ามทวีป จับมือช้ากว่าใน LAN มาก — 5 วินาทีตัดสายที่กำลังจะติดทิ้ง
    struct timeval tv = {.tv_sec = 15, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) != 0) {
        close(fd);
        return false;
    }
    char hello[80];
    int n = snprintf(hello, sizeof(hello), "B %s\n", s_devid);
    if (send(fd, hello, n, 0) != n) {
        close(fd);
        return false;
    }
    int on = 1, idle = 20, intvl = 10, cnt = 3;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
    tv.tv_sec = 5;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    s_relay = fd;
    s_relay_paired = false;
    s_relay_greet_ms = 0;
    ESP_LOGI(TAG, "ต่อ relay %s:%u แล้ว id %s", s_rhost, s_rport, s_devid);
    return true;
}

/// ทักซ้ำทุก 2 วินาทีจนกว่าจะได้เฟรมแรก
///
/// relay ไม่เก็บคิวโดยตั้งใจ (ไม่งั้นข้อมูลเก่าจะถูกเล่นซ้ำใส่ Mac ที่เพิ่งต่อเข้ามา)
/// คำทักทายที่ส่งตอนยังไม่มีใครอยู่ปลายทางจึงหายไปเฉยๆ — และ Mac *ต้อง* ได้ยินมัน
/// เพราะมันคือที่มาของเลขตัวนับที่ Mac ใช้ตั้งต้น การทักซ้ำจึงถูกกว่าการทำให้ relay ฉลาด
static void relay_tick(void)
{
    if (s_relay < 0 || s_relay_paired) return;
    int64_t now = esp_timer_get_time() / 1000;
    if (now - s_relay_greet_ms < 2000) return;
    s_relay_greet_ms = now;
    greet(s_relay);
}

static void serve(void)
{
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(s_listen, &fds);
    int high = s_listen;
    if (s_client >= 0) {
        FD_SET(s_client, &fds);
        if (s_client > high) high = s_client;
    }
    if (s_relay >= 0) {
        FD_SET(s_relay, &fds);
        if (s_relay > high) high = s_relay;
    }
    struct timeval tv = {.tv_sec = 0, .tv_usec = 500000};
    if (select(high + 1, &fds, NULL, NULL, &tv) <= 0) {
        relay_tick();
        return;
    }

    if (FD_ISSET(s_listen, &fds)) {
        int fd = accept(s_listen, NULL, NULL);
        if (fd >= 0) take_client(fd);
    }
    if (s_client >= 0 && FD_ISSET(s_client, &fds)) {
        if (!read_frame(s_client)) {
            ESP_LOGI(TAG, "mac disconnected");
            close_client();
        }
    }
    if (s_relay >= 0 && FD_ISSET(s_relay, &fds)) {
        if (read_frame(s_relay)) {
            // เฟรมแรกที่ถอดรหัสผ่าน = มี Mac จริงอยู่ปลายทางแล้ว เลิกทัก
            if (!s_relay_paired) {
                s_relay_paired = true;
                ESP_LOGI(TAG, "relay: จับคู่กับ Mac แล้ว");
            }
        } else {
            ESP_LOGI(TAG, "relay: สายขาด");
            close_relay();
        }
    }
    relay_tick();
}

static void lan_task(void *arg)
{
    while (1) {
        if (!s_up) {
            close_listen();
            close_relay();
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }
        if (s_listen < 0 && !open_listen()) {
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }
        // ลองต่อ relay ใหม่เป็นระยะ ไม่ใช่รัวๆ — เน็ตมือถือหลุดเป็นเรื่องปกติ และ
        // การ connect() ที่ล้มก็ยังกิน RAM ชั่วขณะ
        if (s_relay < 0 && s_rhost[0]) {
            static int64_t next_try;
            int64_t now = esp_timer_get_time() / 1000;
            if (now >= next_try) {
                if (!open_relay()) next_try = now + 10000;
            }
        }
        serve();
    }
}

// --- mDNS ----------------------------------------------------------------------
// ประกาศตอนได้ IP ครั้งแรกเท่านั้น — Mac ที่กลับมาหลังบอร์ดเปลี่ยน lease ต้องหาเจอเอง
// โดยไม่ต้องเข้ามาทาง BLE ก่อน ซึ่งเป็นสถานการณ์ที่ทางเดินนี้ทั้งเส้นมีไว้รองรับ
static void announce(void)
{
    if (s_mdns_up) return;
    if (mdns_init() != ESP_OK) {
        ESP_LOGW(TAG, "mdns init failed — the mac will need the address typed in");
        return;
    }
    const char *name = pch_ble_name();
    mdns_hostname_set(name);
    mdns_instance_name_set(name);
    if (mdns_service_add(NULL, "_perch", "_tcp", PCH_LAN_PORT, NULL, 0) != ESP_OK) {
        ESP_LOGW(TAG, "mdns service failed");
        return;
    }
    s_mdns_up = true;
    ESP_LOGI(TAG, "announced as %s.local", name);
}

// --- API -----------------------------------------------------------------------
void pch_lan_init(pch_lan_frame_cb_t on_frame)
{
    s_cb = on_frame;
    s_key_lock = xSemaphoreCreateMutex();
    store_load();
    fingerprint();
    ESP_LOGI(TAG, "key %s, counter starts at %llu", s_has_key ? s_fp : "not set",
             (unsigned long long)s_seen);
    xTaskCreate(lan_task, "pch_lan", 4096, NULL, 4, NULL);
}

static int hex_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool pch_lan_set_key(const char *hex)
{
    if (!hex || strlen(hex) != PCH_LAN_KEY_BYTES * 2) return false;
    uint8_t key[PCH_LAN_KEY_BYTES];
    for (int i = 0; i < PCH_LAN_KEY_BYTES; i++) {
        int hi = hex_nibble(hex[i * 2]), lo = hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        key[i] = (uint8_t)((hi << 4) | lo);
    }

    xSemaphoreTake(s_key_lock, portMAX_DELAY);
    memcpy(s_key, key, sizeof(key));
    s_has_key = true;
    // กุญแจใหม่ = nonce ชุดเดิมกลับมาใช้ได้อย่างปลอดภัย ตัวนับจึงเริ่มใหม่ได้ และ *ต้อง*
    // เริ่มใหม่ ไม่งั้น Mac ที่เพิ่งตั้งกุญแจแรกในชีวิตจะต้องไล่ตามเลขของยุคก่อนหน้า
    s_seen = 0;
    s_floor = FLOOR_STRIDE;
    fingerprint();
    xSemaphoreGive(s_key_lock);

    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_blob(h, KEY_BLOB, s_key, sizeof(s_key));
        nvs_set_u64(h, KEY_FLOOR, s_floor);
        nvs_commit(h);
        nvs_close(h);
    }
    // สายที่เปิดอยู่ยังใช้กุญแจเก่าคุยไม่ได้แล้ว ตัดทิ้งให้ Mac ต่อใหม่แทนที่จะให้มัน
    // เจอเฟรมที่ยืนยันไม่ผ่านแล้วสรุปเองว่ามีใครกำลังปลอมตัว
    close_client();
    ESP_LOGI(TAG, "key set (%s), counter reset", s_fp);
    return true;
}

const char *pch_lan_key_fingerprint(void) { return s_fp; }

void pch_lan_set_up(bool up, const char *ip)
{
    s_up = up;
    if (!up) return;
    ESP_LOGI(TAG, "reachable at %s:%d", ip ? ip : "?", PCH_LAN_PORT);
    announce();
}

bool pch_lan_client_connected(void) { return s_client >= 0 || s_relay_paired; }

void pch_lan_set_relay(const char *host, uint16_t port)
{
    // ค่าว่าง = ปิดทางนี้ทิ้ง ไม่ใช่ "ไม่เปลี่ยน" — ผู้ใช้ต้องถอนออกได้
    char h[sizeof(s_rhost)] = {0};
    if (host) snprintf(h, sizeof(h), "%s", host);
    if (strcmp(h, s_rhost) == 0 && port == s_rport) return;
    snprintf(s_rhost, sizeof(s_rhost), "%s", h);
    s_rport = port;
    close_relay();          // ปลายทางเปลี่ยน สายที่ค้างอยู่ไปผิดที่แล้ว

    nvs_handle_t nh;
    if (nvs_open(NVS_NS, NVS_READWRITE, &nh) == ESP_OK) {
        nvs_set_str(nh, KEY_RHOST, s_rhost);
        nvs_set_u16(nh, KEY_RPORT, s_rport);
        nvs_commit(nh);
        nvs_close(nh);
    }
    ESP_LOGI(TAG, "relay = %s:%u", s_rhost[0] ? s_rhost : "(ไม่ใช้)", s_rport);
}

const char *pch_lan_device_id(void)
{
    ensure_devid();
    return s_devid;
}

#include "ct_touch.h"

#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "touch";

// PENIRQ ของ XPT2046 (DESIGN.md: CLK 25 MOSI 32 MISO 39 CS 33 IRQ 36)
//
// GPIO 36 เป็นขา input อย่างเดียว และ **ไม่มี pull-up ในชิป** (GPIO 34-39 ของ ESP32
// ไม่มีทั้ง pull-up และ pull-down) จึงต้องพึ่ง pull-up บนบอร์ด ถ้าบอร์ดรุ่นไหนไม่มี
// ขานี้จะลอยและอ่านได้มั่ว — ตัวตรวจตอนบูตข้างล่างมีไว้บอกเรื่องนี้ ไม่ใช่เพื่อกันมัน
#define PIN_IRQ 36

// นิ้วแตะ = PENIRQ ลงต่ำ
#define TOUCHED 0

// ต้องนิ่งเท่านี้ถึงนับว่าเปลี่ยนสถานะจริง
//
// ขาที่ลอย (หรือสัญญาณรบกวนจากไฟหลัง PWM ที่อยู่ติดกัน) จะกระพริบเร็วกว่านี้มาก
// ส่วนนิ้วคนอยู่บนจอนานกว่านี้เสมอ ตัวเลขนี้จึงแยกสองอย่างนั้นออกจากกัน
#define STABLE_MS 40

static int s_level = 1;      // ระดับที่ยืนยันแล้ว
static int s_candidate = 1;  // ระดับที่กำลังรอให้นิ่ง
static int s_stable_ms = 0;

void ct_touch_init(void)
{
    gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << PIN_IRQ,
        .mode = GPIO_MODE_INPUT,
        // ตั้งไว้ให้ชัดว่าไม่ได้ขอ ไม่ใช่ลืมขอ — ขา 34-39 ไม่มีให้ขออยู่แล้ว
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&cfg);

    // ตอนบูตยังไม่มีใครแตะจอ ขาจึงควรอยู่สูงนิ่ง ถ้าไม่ใช่แปลว่าไม่มี pull-up บนบอร์ด
    // แล้วการแตะจะทำงานมั่ว — พูดออกมาให้เห็นดีกว่าปล่อยให้ไปเดาเอาตอนจอปลุกเอง
    int high = 0;
    for (int i = 0; i < 16; i++) high += gpio_get_level(PIN_IRQ);
    if (high < 16) {
        ESP_LOGW(TAG, "PENIRQ ไม่นิ่งตอนบูต (%d/16 สูง) — บอร์ดอาจไม่มี pull-up", high);
    }
    s_level = s_candidate = gpio_get_level(PIN_IRQ);
}

bool ct_touch_tapped(int elapsed_ms)
{
    int now = gpio_get_level(PIN_IRQ);
    if (now != s_candidate) {
        s_candidate = now;
        s_stable_ms = 0;
        return false;
    }
    if (s_candidate == s_level) return false;

    s_stable_ms += elapsed_ms;
    if (s_stable_ms < STABLE_MS) return false;

    s_level = s_candidate;
    return s_level == TOUCHED;
}

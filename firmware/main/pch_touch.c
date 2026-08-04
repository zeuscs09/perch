#include "pch_touch.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_log.h"

static const char *TAG = "touch";

// XPT2046 (DESIGN.md: CLK 25 MOSI 32 MISO 39 CS 33 IRQ 36) — คนละบัสกับจอที่ใช้ SPI2
#define PIN_CLK 25
#define PIN_MOSI 32
#define PIN_MISO 39
#define PIN_CS 33
#define PIN_IRQ 36
#define TOUCH_HOST SPI3_HOST

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
static bool s_seen = false;

// ปลุกตัวควบคุมให้เปิด PENIRQ
//
// **นี่คือขั้นที่ขาดไม่ได้ และเป็นเหตุผลเดียวที่ไฟล์นี้ต้องแตะ SPI เลย**
//
// XPT2046 ไม่ได้ปล่อยสัญญาณ PENIRQ มาตั้งแต่เปิดเครื่อง มันปล่อยเมื่ออยู่ในโหมด
// power-down ที่เปิด PENIRQ ไว้ ซึ่งเกิดขึ้นหลังจบการแปลงค่าที่สั่งด้วย PD1=PD0=0
// เท่านั้น ถ้าไม่เคยส่งคำสั่งอะไรเลย ขา PENIRQ จะค้างสูงตลอดกาลและการแตะจะเงียบสนิท
// (วัดมาแล้วบนบอร์ดจริง: low=0/50 ทุกรอบ ไม่ว่าจะแตะหรือไม่)
//
// ส่งครั้งเดียวตอนบูตพอ — โหมดนี้ค้างอยู่จนกว่าจะมีคำสั่งอื่นมาเปลี่ยน ซึ่งไม่มี
// หลังจากนี้เราอ่านแค่ขา GPIO ไม่คุย SPI อีกเลย พิกัดไม่ได้ตอบคำถามที่บอร์ดนี้ถาม
static void wake_controller(void)
{
    spi_bus_config_t bus = {
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = PIN_MISO,
        .sclk_io_num = PIN_CLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 8,
    };
    if (spi_bus_initialize(TOUCH_HOST, &bus, SPI_DMA_DISABLED) != ESP_OK) {
        ESP_LOGW(TAG, "spi bus init failed — การแตะจะไม่ทำงาน");
        return;
    }
    spi_device_interface_config_t dev = {
        .clock_speed_hz = 1 * 1000 * 1000,  // XPT2046 ช้า 2MHz คือเพดานที่ปลอดภัย
        .mode = 0,
        .spics_io_num = PIN_CS,
        .queue_size = 1,
    };
    spi_device_handle_t handle;
    if (spi_bus_add_device(TOUCH_HOST, &dev, &handle) != ESP_OK) {
        ESP_LOGW(TAG, "spi device add failed — การแตะจะไม่ทำงาน");
        return;
    }

    // 0x90 = START=1, A=001 (Y), MODE=0 (12 บิต), SER/DFR=0, PD1=0 PD0=0
    // สองไบต์หลังเป็นที่ว่างให้ผลลัพธ์เดินออกมา เราไม่ได้ใช้ค่า แต่การแปลงต้องจบ
    uint8_t tx[3] = {0x90, 0x00, 0x00};
    uint8_t rx[3] = {0};
    spi_transaction_t t = {.length = 8 * sizeof(tx), .tx_buffer = tx, .rx_buffer = rx};
    if (spi_device_polling_transmit(handle, &t) != ESP_OK) {
        ESP_LOGW(TAG, "spi transfer failed — การแตะจะไม่ทำงาน");
    }
}

void pch_touch_init(void)
{
    gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << PIN_IRQ,
        .mode = GPIO_MODE_INPUT,
        // GPIO 36 ไม่มี pull-up ในชิป (ขา 34-39 ของ ESP32 ไม่มีทั้ง pull-up/pull-down)
        // ตั้งไว้ให้ชัดว่าไม่ได้ขอ ไม่ใช่ลืมขอ — ต้องพึ่ง pull-up บนบอร์ด
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&cfg);

    wake_controller();

    // ตอนบูตยังไม่มีใครแตะจอ ขาจึงควรอยู่สูงนิ่ง ถ้าไม่ใช่แปลว่าไม่มี pull-up บนบอร์ด
    // แล้วการแตะจะทำงานมั่ว — พูดออกมาให้เห็นดีกว่าปล่อยให้ไปเดาเอาตอนจอปลุกเอง
    int high = 0;
    for (int i = 0; i < 16; i++) high += gpio_get_level(PIN_IRQ);
    if (high < 16) {
        ESP_LOGW(TAG, "PENIRQ ไม่นิ่งตอนบูต (%d/16 สูง) — บอร์ดอาจไม่มี pull-up", high);
    }
    s_level = s_candidate = gpio_get_level(PIN_IRQ);
}

bool pch_touch_seen(void) { return s_seen; }

bool pch_touch_tapped(int elapsed_ms)
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
    if (s_level != TOUCHED) return false;
    if (!s_seen) {
        s_seen = true;
        ESP_LOGI(TAG, "การแตะทำงานแล้ว — เปิดการหรี่จออัตโนมัติ");
    }
    return true;
}

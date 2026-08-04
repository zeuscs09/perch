#include "pch_lcd.h"

#include <string.h>

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "layout.h"

static const char *TAG = "lcd";

// ยืนยันแล้วจากบอร์ดจริง: จอตอบกลับผ่าน MISO ตามขาชุดนี้
#define PIN_MOSI 13
#define PIN_MISO 12
#define PIN_SCLK 14
#define PIN_CS 15
#define PIN_DC 2
#define PIN_BL 21

#define LCD_HOST SPI2_HOST
// 40MHz — ผ่านสายบนบอร์ด CYD ได้นิ่ง ส่วน 80MHz เจอภาพรบกวนในหลายล็อต
#define LCD_CLOCK_HZ (40 * 1000 * 1000)

#define BL_TIMER LEDC_TIMER_0
#define BL_CHANNEL LEDC_CHANNEL_0
#define BL_DUTY_BITS LEDC_TIMER_10_BIT

static spi_device_handle_t s_spi;
static int s_backlight = 100;

static void cs(int level) { gpio_set_level(PIN_CS, level); }
static void dc(int level) { gpio_set_level(PIN_DC, level); }

static void spi_write(const void *data, size_t len)
{
    if (len == 0) return;
    spi_transaction_t t = {.length = len * 8, .tx_buffer = data};
    ESP_ERROR_CHECK(spi_device_polling_transmit(s_spi, &t));
}

static void lcd_cmd(uint8_t c, const uint8_t *d, size_t n)
{
    cs(0);
    dc(0);
    spi_write(&c, 1);
    if (n) {
        dc(1);
        spi_write(d, n);
    }
    cs(1);
}

// ลำดับ init ของ ILI9341 ที่ตรงกับผลวัด: MADCTL 0x28 (MV|BGR), INVOFF, COLMOD 0x55
static void panel_init(void)
{
    lcd_cmd(0x01, NULL, 0);  // SWRESET
    vTaskDelay(pdMS_TO_TICKS(150));
    lcd_cmd(0x11, NULL, 0);  // SLPOUT
    vTaskDelay(pdMS_TO_TICKS(150));

    lcd_cmd(0xCF, (const uint8_t[]){0x00, 0xC1, 0x30}, 3);
    lcd_cmd(0xED, (const uint8_t[]){0x64, 0x03, 0x12, 0x81}, 4);
    lcd_cmd(0xE8, (const uint8_t[]){0x85, 0x00, 0x78}, 3);
    lcd_cmd(0xCB, (const uint8_t[]){0x39, 0x2C, 0x00, 0x34, 0x02}, 5);
    lcd_cmd(0xF7, (const uint8_t[]){0x20}, 1);
    lcd_cmd(0xEA, (const uint8_t[]){0x00, 0x00}, 2);
    lcd_cmd(0xC0, (const uint8_t[]){0x23}, 1);        // power control 1
    lcd_cmd(0xC1, (const uint8_t[]){0x10}, 1);        // power control 2
    lcd_cmd(0xC5, (const uint8_t[]){0x3E, 0x28}, 2);  // VCOM
    lcd_cmd(0xC7, (const uint8_t[]){0x86}, 1);

    lcd_cmd(0x36, (const uint8_t[]){0x28}, 1);  // MADCTL: MV | BGR -> แนวนอน 320x240
    lcd_cmd(0x3A, (const uint8_t[]){0x55}, 1);  // COLMOD: 16 bit/pixel
    lcd_cmd(0xB1, (const uint8_t[]){0x00, 0x18}, 2);
    lcd_cmd(0xB6, (const uint8_t[]){0x08, 0x82, 0x27}, 3);

    // ไม่ตั้ง gamma แล้วจอจะยกระดับดำ ภาพซีดทั้งจอ
    lcd_cmd(0xF2, (const uint8_t[]){0x00}, 1);  // 3Gamma off
    lcd_cmd(0x26, (const uint8_t[]){0x01}, 1);  // gamma curve 1
    lcd_cmd(0xE0,
            (const uint8_t[]){0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E, 0xF1, 0x37, 0x07, 0x10,
                              0x03, 0x0E, 0x09, 0x00},
            15);  // positive gamma
    lcd_cmd(0xE1,
            (const uint8_t[]){0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31, 0xC1, 0x48, 0x08, 0x0F,
                              0x0C, 0x31, 0x36, 0x0F},
            15);  // negative gamma
    lcd_cmd(0x20, NULL, 0);  // INVOFF — จอตัวนี้สีถูกเมื่อ inversion ปิด
    lcd_cmd(0x11, NULL, 0);
    vTaskDelay(pdMS_TO_TICKS(120));
    lcd_cmd(0x29, NULL, 0);  // DISPON
    vTaskDelay(pdMS_TO_TICKS(20));
}

static void backlight_init(void)
{
    ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = BL_DUTY_BITS,
        .timer_num = BL_TIMER,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    ledc_channel_config_t ch = {
        .gpio_num = PIN_BL,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = BL_CHANNEL,
        .timer_sel = BL_TIMER,
        .duty = 0,
        .hpoint = 0,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ch));
    pch_lcd_set_backlight(100);
}

void pch_lcd_set_backlight(int percent)
{
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    s_backlight = percent;
    uint32_t max_duty = (1u << BL_DUTY_BITS) - 1;
    uint32_t duty = (uint32_t)((max_duty * (uint32_t)percent) / 100u);
    ESP_ERROR_CHECK(ledc_set_duty(LEDC_LOW_SPEED_MODE, BL_CHANNEL, duty));
    ESP_ERROR_CHECK(ledc_update_duty(LEDC_LOW_SPEED_MODE, BL_CHANNEL));
}

int pch_lcd_backlight(void) { return s_backlight; }

void pch_lcd_init(void)
{
    gpio_config_t io = {
        .pin_bit_mask = (1ULL << PIN_CS) | (1ULL << PIN_DC),
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_ERROR_CHECK(gpio_config(&io));
    cs(1);
    dc(1);

    spi_bus_config_t bus = {
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = PIN_MISO,
        .sclk_io_num = PIN_SCLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        // ก้อนใหญ่สุดที่จะส่งคือบัฟเฟอร์วาดของ LVGL หนึ่งก้อน
        .max_transfer_sz = PCH_SCREEN_WIDTH * 24 * 2 + 64,
    };
    ESP_ERROR_CHECK(spi_bus_initialize(LCD_HOST, &bus, SPI_DMA_CH_AUTO));

    spi_device_interface_config_t dev = {
        .clock_speed_hz = LCD_CLOCK_HZ,
        .mode = 0,
        .spics_io_num = -1,  // ยก CS มาคุมเอง เพราะต้องค้าง low คร่อมหลาย transaction
        .queue_size = 4,
    };
    ESP_ERROR_CHECK(spi_bus_add_device(LCD_HOST, &dev, &s_spi));

    panel_init();
    backlight_init();
    ESP_LOGI(TAG, "panel ready %dx%d", PCH_SCREEN_WIDTH, PCH_SCREEN_HEIGHT);
}

void pch_lcd_blit(int x1, int y1, int x2, int y2, const void *pixels, size_t bytes)
{
    uint8_t col[4] = {(uint8_t)(x1 >> 8), (uint8_t)x1, (uint8_t)(x2 >> 8), (uint8_t)x2};
    uint8_t row[4] = {(uint8_t)(y1 >> 8), (uint8_t)y1, (uint8_t)(y2 >> 8), (uint8_t)y2};
    lcd_cmd(0x2A, col, 4);  // CASET
    lcd_cmd(0x2B, row, 4);  // RASET
    lcd_cmd(0x2C, NULL, 0); // RAMWR

    cs(0);
    dc(1);
    // แบ่งส่งเป็นก้อนตามขนาดที่ DMA รับได้ในครั้งเดียว
    const uint8_t *p = (const uint8_t *)pixels;
    const size_t chunk = PCH_SCREEN_WIDTH * 24 * 2;
    while (bytes) {
        size_t n = bytes > chunk ? chunk : bytes;
        spi_write(p, n);
        p += n;
        bytes -= n;
    }
    cs(1);
}

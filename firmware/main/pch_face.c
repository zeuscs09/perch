#include "pch_face.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "layout.h"
#include "pch_lcd.h"
#include "pch_face_env.h"

static const char *TAG = "face";

// ออกแบบที่ 160x120 แล้วขยายสองเท่า — ตรงกับที่ออกแบบไว้บน Mac (tools ในเครื่องพัฒนา)
//
// ไม่ใช้ LVGL object เลย: วงรีจริงทำด้วย object ไม่ได้ (radius ของ LVGL ให้รูปแคปซูล
// ไม่ใช่วงรี) และ canvas เต็มจอ RGB565 กิน 150KB ซึ่งบอร์ดนี้ไม่มี
//
// วิธีที่ใช้แทน: ฟังก์ชันบริสุทธิ์ pixel(x,y) -> สี แล้วไล่ทีละแถว บัฟเฟอร์แค่แถวเดียว
// (640 ไบต์) ทั้งหน้าวาดครั้งเดียวตอนบูต จากนั้นวาดซ้ำเฉพาะแถบปากซึ่งสูงแค่ 20 logical row
#define LW 160
#define LH 120
#define SC 2

#define RGB(r, g, b) ((uint16_t)(((r) >> 3) << 11 | ((g) >> 2) << 5 | ((b) >> 3)))

#define C_BLACK   RGB(10, 9, 11)
#define C_HOOD    RGB(168, 26, 32)
#define C_HOOD_DK RGB(108, 16, 21)
#define C_SKIN    RGB(232, 197, 152)
#define C_SKIN_SH RGB(206, 168, 122)
#define C_INK     RGB(18, 15, 17)
#define C_WHITE   RGB(245, 242, 236)

#define CX 80
#define FACE_CY 56
#define FACE_RX 33
#define FACE_RY 45

// แถบที่วาดซ้ำทุกเฟรม — ต้องครอบปากตอนอ้าสุดพอดี ไม่กว้างกว่านั้นเพราะทุกแถวคือเวลา
#define MOUTH_CY 88
#define MOUTH_RX 9
#define BAND_Y0 80
#define BAND_Y1 104

#define MOUTH_MIN 2
#define MOUTH_RANGE 12
#define SMOOTH 0.24f

// เส้นโค้งถูกแปลงเป็นตารางช่วง y ต่อคอลัมน์ตอนบูต — การหาระยะถึงเส้นโค้งต่อพิกเซล
// แพงเกินไปเมื่อต้องทำ 19,200 ครั้ง ส่วนตารางนี้ทำให้เหลือการเทียบสองครั้ง
static uint8_t s_mo_top[LW], s_mo_bot[LW];
static uint8_t s_br_top[LW], s_br_bot[LW];

static bool in_ell(int x, int y, int cx, int cy, int rx, int ry)
{
    int dx = x - cx, dy = y - cy;
    return (long)dx * dx * ry * ry + (long)dy * dy * rx * rx <= (long)rx * rx * ry * ry;
}

static void span(uint8_t *top, uint8_t *bot, int x, int y, int r)
{
    if (x < 0 || x >= LW) return;
    int a = y - r, b = y + r;
    if (a < 0) a = 0;
    if (b > LH - 1) b = LH - 1;
    if (top[x] == 255 || a < top[x]) top[x] = (uint8_t)a;
    if (bot[x] == 0 || b > bot[x]) bot[x] = (uint8_t)b;
}

static void build_curves(void)
{
    memset(s_mo_top, 255, sizeof(s_mo_top));
    memset(s_br_top, 255, sizeof(s_br_top));

    // หนวด: ทิ้งตัวนิดตรงกลาง สะบัดขึ้นสูงที่ปลาย — สมการเดียวกับที่ออกแบบบน Mac
    for (int s = -1; s <= 1; s += 2) {
        for (int i = 0; i <= 48; i++) {
            float u = i / 48.0f;
            int x = CX + (int)(s * u * 26.0f);
            int y = (int)(80 + 29 * u * u - 42 * u * u * u);
            for (int k = -2; k <= 2; k++) span(s_mo_top, s_mo_bot, x + k, y, 2);
        }
    }
    // คิ้ว: เชิดขึ้นทางหางตา ไม่ใช่โค้งสมมาตร
    for (int s = -1; s <= 1; s += 2) {
        for (int i = 0; i <= 20; i++) {
            float t = i / 20.0f;
            int x = CX + (int)(s * (7 + t * 16));
            int y = (int)(44 - t * 5 + 3 * (t - 0.4f) * (t - 0.4f) * 6);
            for (int k = -2; k <= 2; k++) span(s_br_top, s_br_bot, x + k, y, 2);
        }
    }
}

static inline bool on_curve(const uint8_t *top, const uint8_t *bot, int x, int y)
{
    return top[x] != 255 && y >= top[x] && y <= bot[x];
}

/// สีของพิกเซลตรรกะหนึ่งจุด — เรียงจากหน้าไปหลัง คืนทันทีที่เจอ
static uint16_t pixel(int x, int y, int mouth_h)
{
    int mr = mouth_h / 2;
    if (mr < 1) mr = 1;
    if (in_ell(x, y, CX, MOUTH_CY + mr, MOUTH_RX, mr)) return C_INK;

    if (on_curve(s_mo_top, s_mo_bot, x, y)) return C_INK;

    for (int s = -1; s <= 1; s += 2) {
        int ex = CX + s * 14;
        if (in_ell(x, y, ex - 1, 54, 1, 1)) return C_WHITE;
        if (in_ell(x, y, ex, 56, 4, 4)) return C_INK;
        if (in_ell(x, y, ex, 56, 8, 9)) return C_WHITE;
    }
    if (on_curve(s_br_top, s_br_bot, x, y)) return C_INK;

    if (in_ell(x, y, CX, 74, 5, 3)) return C_SKIN_SH;
    if ((x == CX - 3 || x == CX + 3) && y >= 60 && y <= 73) return C_SKIN_SH;

    if (in_ell(x, y, CX, FACE_CY, FACE_RX, FACE_RY)) {
        if (in_ell(x, y, CX, FACE_CY - FACE_RY + 6, FACE_RX, 12)) return C_SKIN_SH;
        if (in_ell(x, y, CX, FACE_CY + FACE_RY - 4, FACE_RX - 4, 14)) return C_SKIN_SH;
        return C_SKIN;
    }
    // ฮู้ด: วงรีที่ทิ้งชายลงพ้นจอ จึงต้องเช็ค "ใต้จุดศูนย์กลาง" แยกจากตัววงรี
    if (in_ell(x, y, CX, 57, 36, 48) || (y > 57 && x >= CX - 36 && x <= CX + 36))
        return C_HOOD_DK;
    if (in_ell(x, y, CX, 60, 52, 58) || (y > 60 && x >= CX - 52 && x <= CX + 52))
        return C_HOOD;
    return C_BLACK;
}

/// วาดแถวตรรกะ y0..y1 ลงจอ — แต่ละแถวถูกยืดเป็นสองแถวจริง
static void blit_band(int y0, int y1, int mouth_h)
{
    static uint16_t row[LW * SC];
    for (int ly = y0; ly <= y1; ly++) {
        for (int lx = 0; lx < LW; lx++) {
            // จอกิน RGB565 แบบ big-endian ส่วน ESP32 เป็น little-endian
            uint16_t c = __builtin_bswap16(pixel(lx, ly, mouth_h));
            row[lx * SC] = c;
            row[lx * SC + 1] = c;
        }
        for (int k = 0; k < SC; k++) {
            int py = ly * SC + k;
            pch_lcd_blit(0, py, LW * SC - 1, py, row, sizeof(row));
        }
    }
}

void pch_face_run(void)
{
    build_curves();
    pch_lcd_set_backlight(100);
    blit_band(0, LH - 1, MOUTH_MIN);
    ESP_LOGI(TAG, "Berlin ในฮู้ด · เส้นเสียง %d เฟรม @ %d fps", PCH_ENV_LEN, PCH_ENV_FPS);

    const int period = 1000 / PCH_ENV_FPS;
    float amp = 0;
    int i = 0, last = -1;

    for (;;) {
        amp += (PCH_ENV[i] / 255.0f - amp) * SMOOTH;
        int h = MOUTH_MIN + (int)(amp * MOUTH_RANGE);
        // วาดเฉพาะตอนความสูงเปลี่ยนจริง — เส้นเสียงมีช่วงเงียบยาว การวาดซ้ำภาพเดิม
        // คือการเผา SPI ทิ้งเปล่าๆ และทำให้เฟรมที่ต้องขยับจริงมาช้า
        if (h != last) {
            blit_band(BAND_Y0, BAND_Y1, h);
            last = h;
        }
        vTaskDelay(pdMS_TO_TICKS(period));
        if (++i >= PCH_ENV_LEN) {
            i = 0;
            vTaskDelay(pdMS_TO_TICKS(700));
        }
    }
}

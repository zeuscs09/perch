#include "ct_ui.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "ct_agent.h"
#include "ct_mascot.h"
#include "ct_rects.h"
#include "layout.h"
#include "lvgl.h"

// ความสูง/ระยะของการ์ด — ตรงกับ tools/gen/screen.py
#define CARD_H 36
#define CARD_GAP 4

// หนึ่งลูปอนิเมชันยาวเท่าไร (ms) — ตรงกับสมมติฐาน "ลูปหนึ่งราว 1 วินาที" ของ mascot.c
#define LOOP_MS 1000
#define FRAME_MS 60

typedef struct {
    lv_obj_t *canvas;  // ตัววาดมาสคอต (วาดเองใน LV_EVENT_DRAW_MAIN)
    lv_obj_t *label;   // ป้ายชื่อโปรเจกต์
    int index;
} slot_t;

typedef struct {
    lv_obj_t *box;
    lv_obj_t *accent;
    lv_obj_t *title;
    lv_obj_t *body;
} card_t;

typedef struct {
    lv_obj_t *percent;  // ตัวเลขใหญ่ — สิ่งเดียวที่ต้องอ่านออกจากอีกฝั่งห้อง
    // LVGL ไม่มี montserrat ตัวหนา — ซ้อนป้ายเดิมเยื้อง 1px แทน (เทียบเท่า
    // stroke_width=1 ของ Pillow ฝั่ง preview) ต้องอัปเดตข้อความ/สีคู่กันเสมอ
    lv_obj_t *percent_bold;
    lv_obj_t *pill;     // ป้ายบอกว่าเป็นหน้าต่างไหน สีคงที่ ไม่ตามระดับ
    lv_obj_t *pill_text;
    lv_obj_t *track;  // รางแถบ
    lv_obj_t *fill;   // เนื้อแถบ
    lv_obj_t *pace;   // ขีดบอกว่า "ควรใช้ถึงไหนแล้ว" ตามเวลาที่ผ่านไปในหน้าต่าง
    lv_obj_t *reset;  // countdown
} usage_row_t;

static ct_snapshot_t s_snap;
static bool s_connected = false;

// แถบโควตาย่อบน topbar — ตรงกับ tools/gen/screen.py:_topbar
#define USAGE_TOP_W 34
#define USAGE_TOP_H 6

// ทุกอย่างที่เกาะขอบขวาของแถบเริ่มนับจากตรงนี้ ไม่ใช่จากขอบจอ — ไอคอนลิงก์จองที่
// ขวาสุดไว้ถาวร ค่าคงที่ตัวเดียวจึงต้องเลื่อนนาฬิกา "+N" และแถบโควตาไปพร้อมกัน
#define TOPBAR_RIGHT (6 + CT_TOPBAR_LINK_ICON_W + CT_TOPBAR_LINK_ICON_GAP)

// ไอคอนลิงก์เป็นรายการสี่เหลี่ยมเหมือนของอื่นทั้งจอ ไม่ใช่ glyph จากฟอนต์ —
// ต้องตรงกับ tools/gen/screen.py:_link_icon เป๊ะทั้งพิกัดและสี
typedef struct {
    uint8_t x, y, w, h;
} icon_rect_t;

// BLE = แท่งไต่ขึ้น (ทางหลัก) · WiFi = คลื่นซ้อน (ทางสำรอง) · ขาด = ขีดเดียวจางๆ
// สามรูปทรงคนละวงศ์ ไม่ใช่รูปเดียวคนละสี — จอนี้ถูกมองจากอีกฝั่งห้องเป็นหลัก
static const icon_rect_t ICON_BLE[] = {{0, 6, 3, 3}, {4, 3, 3, 6}, {8, 0, 3, 9}};
static const icon_rect_t ICON_WIFI[] = {{0, 0, 11, 2}, {2, 3, 7, 2}, {4, 6, 3, 3}};
static const icon_rect_t ICON_NONE[] = {{1, 4, 9, 2}};
#define LINK_ICON_PARTS 3

// --- ฉากท้องฟ้า ---------------------------------------------------------------
// ฟ้า 22..93 แล้วพื้นดินลงไปถึงก้นจอ — วาดในผืนเดียวหลังทุกอย่าง
// ตรรกะทั้งหมดต้องตรงกับ tools/gen/sky.py
typedef enum {
    CT_SKY_NIGHT = 0,
    CT_SKY_DAWN,
    CT_SKY_DAY,
    CT_SKY_DUSK,
    CT_SKY_PHASE_COUNT,
    CT_SKY_NONE,  // ไม่ต่อลิงก์ หรือยังไม่รู้เวลา -> ไม่มีฉากเลย
} ct_sky_phase_t;

static const uint16_t SKY_BG[CT_SKY_PHASE_COUNT] = {CT_COL_SKY_NIGHT, CT_COL_SKY_DAWN,
                                                    CT_COL_SKY_DAY, CT_COL_SKY_DUSK};
static const uint16_t SKY_GROUND[CT_SKY_PHASE_COUNT] = {
    CT_COL_GROUND_NIGHT, CT_COL_GROUND_DAWN, CT_COL_GROUND_DAY, CT_COL_GROUND_DUSK};
static const uint16_t SKY_GRASS[CT_SKY_PHASE_COUNT] = {
    CT_COL_GRASS_NIGHT, CT_COL_GRASS_DAWN, CT_COL_GRASS_DAY, CT_COL_GRASS_DUSK};
static const uint16_t SKY_SHADOW[CT_SKY_PHASE_COUNT] = {
    CT_COL_SHADOW_NIGHT, CT_COL_SHADOW_DAWN, CT_COL_SHADOW_DAY, CT_COL_SHADOW_DUSK};
// กลางคืนไม่มีเมฆ ช่องแรกจึงไม่ถูกใช้
static const uint16_t SKY_CLOUD[CT_SKY_PHASE_COUNT] = {0, CT_COL_CLOUD_DAWN, CT_COL_CLOUD_DAY,
                                                       CT_COL_CLOUD_DUSK};

// เงาใต้เท้า — กว้าง 11 unit วางใต้เส้นขอบฟ้า ตรงกับ SHADOW_W ใน tools/gen/screen.py
#define SHADOW_W_UNIT 11.0f
#define SHADOW_H 5
// กึ่งกลางลำตัวในหน่วย unit (BODY = 1.0 กว้าง 14.0 ใน tools/gen/mascot.py)
#define BODY_CX 8.0f

static lv_obj_t *s_sky;
static ct_sky_phase_t s_sky_phase = CT_SKY_NONE;
static float s_sky_hours = -1.0f;  // เวลาที่ใช้หาตำแหน่งดวง — <0 คือไม่รู้
static int s_cloud_shift = -1;     // เมฆเลื่อนไปกี่พิกเซลแล้ว ใช้ตัดสินว่าต้องวาดใหม่ไหม

static lv_obj_t *s_stroll;  // มาสคอตเดินข้ามจอตอนไม่มี session — กินแถบ slot ทั้งแถบ
static lv_obj_t *s_dot, *s_link, *s_clock_small, *s_overflow, *s_usage_top;
static lv_obj_t *s_link_icon[LINK_ICON_PARTS];
static lv_obj_t *s_usage_track, *s_usage_fill;
static lv_obj_t *s_clock_big, *s_date;
static lv_obj_t *s_card_more;  // "+N more" ใต้การ์ดใบล่างสุด
static slot_t s_slots[CT_SLOTS_COUNT];
static card_t s_cards[CT_MAX_CARDS];
static usage_row_t s_usage[CT_USAGE_ROWS];

static float s_phase = 0.0f;
static int s_cycle = 0;

// RGB565 -> สีของ LVGL (ขยายกลับเป็น 8 บิตต่อช่องแบบเดียวกับ quantize565 ฝั่ง Python)
static lv_color_t ct_color(uint16_t c)
{
    uint8_t r5 = (c >> 11) & 0x1F, g6 = (c >> 5) & 0x3F, b5 = c & 0x1F;
    return lv_color_make((r5 * 255 + 15) / 31, (g6 * 255 + 31) / 63, (b5 * 255 + 15) / 31);
}

// ขอบซ้ายของ slot ที่ i เมื่อกำลังแสดง session อยู่ n ตัว
// ระยะห่างคงที่ 80px เสมอ แต่ยกทั้งกลุ่มมาไว้กึ่งกลางจอ — สิ่งที่ต้องนิ่งคือ *ลำดับ*
static int slot_x(int i, int n)
{
    return (int)lroundf((CT_SCREEN_WIDTH - n * CT_SLOTS_WIDTH) / 2.0f) + i * CT_SLOTS_WIDTH;
}

// "14:32" -> 14.533 · คืนค่าติดลบเมื่ออ่านไม่ได้
// ติดลบไม่ใช่เที่ยงคืน แต่คือ "ยังไม่รู้เวลา" — ตอนบูตก่อน sync ครั้งแรก clock เป็น "--:--"
// ต้องตกมาทางนี้ ไม่ใช่ไปโผล่เป็นฉากกลางดึก
static float ct_clock_hours(const char *c)
{
    for (int i = 0; i < 5; i++) {
        if (c[i] == '\0') return -1.0f;
    }
    if (c[2] != ':') return -1.0f;
    for (int i = 0; i < 5; i++) {
        if (i == 2) continue;
        if (c[i] < '0' || c[i] > '9') return -1.0f;
    }
    int h = (c[0] - '0') * 10 + (c[1] - '0');
    int m = (c[3] - '0') * 10 + (c[4] - '0');
    if (h > 23 || m > 59) return -1.0f;
    return (float)h + (float)m / 60.0f;
}

// ชั่วโมง -> ช่วง — กระโดดที่ขอบ ไม่ผสมสีระหว่างช่วง
static ct_sky_phase_t sky_phase_at(float t)
{
    if (t < CT_SKY_DAWN_HOUR || t >= CT_SKY_NIGHT_HOUR) return CT_SKY_NIGHT;
    if (t < CT_SKY_DAY_HOUR) return CT_SKY_DAWN;
    if (t < CT_SKY_DUSK_HOUR) return CT_SKY_DAY;
    return CT_SKY_DUSK;
}

// สัดส่วนของเส้นทาง (0..1) -> จุดกึ่งกลางดวงบนส่วนโค้ง
// ที่ u=0 และ u=1 ดวงอยู่บนเส้นขอบฟ้าพอดี (จมครึ่งดวง) ที่ขอบจอทั้งสองข้าง
static void sky_arc(float u, float *x, float *y)
{
    *x = -(float)CT_SKY_ARC_PAD + u * (float)(CT_SCREEN_WIDTH + 2 * CT_SKY_ARC_PAD);
    *y = (float)CT_SKY_HORIZON - sinf((float)M_PI * u) * (float)CT_SKY_ARC_PEAK;
}

// ดวงอาทิตย์ 05:00->19:00 · ดวงจันทร์ 19:00->05:00 — มีดวงใดดวงหนึ่งบนฟ้าเสมอ
static void sky_disc(float t, float *x, float *y, uint16_t *color)
{
    if (t >= CT_SKY_DAWN_HOUR && t < CT_SKY_NIGHT_HOUR) {
        sky_arc((t - CT_SKY_DAWN_HOUR) / (float)(CT_SKY_NIGHT_HOUR - CT_SKY_DAWN_HOUR), x, y);
        ct_sky_phase_t p = sky_phase_at(t);
        *color = (p == CT_SKY_DAWN || p == CT_SKY_DUSK) ? CT_COL_SUN_LOW : CT_COL_SUN;
        return;
    }
    float span = (float)(24 - CT_SKY_NIGHT_HOUR + CT_SKY_DAWN_HOUR);
    sky_arc(fmodf(t - CT_SKY_NIGHT_HOUR + 24.0f, 24.0f) / span, x, y);
    *color = CT_COL_MOON;
}

static void fill_rect(lv_layer_t *layer, int x0, int y0, int x1, int y1, uint16_t color,
                      int radius)
{
    if (x1 < x0 || y1 < y0) return;
    lv_draw_rect_dsc_t dsc;
    lv_draw_rect_dsc_init(&dsc);
    dsc.bg_opa = LV_OPA_COVER;
    dsc.border_width = 0;
    dsc.bg_color = ct_color(color);
    dsc.radius = radius;
    lv_area_t a = {.x1 = x0, .y1 = y0, .x2 = x1, .y2 = y1};
    lv_draw_rect(layer, &dsc, &a);
}

static void draw_stars(lv_layer_t *layer, ct_sky_phase_t phase)
{
    if (phase == CT_SKY_DAY) return;
    // ดาวเป็นสี่เหลี่ยมอย่างน้อย star_px x star_px ทุกดวง — จุด 1px หายไปเลยบนแผงจริง
    const int d = CT_SKY_STAR_PX - 1;
    if (phase != CT_SKY_NIGHT) {
        // ฟ้ายังสว่างเกินกว่าจะเห็นทั้งหมด — ดวงแรกๆ สีหรี่ ไม่กะพริบ
        for (int i = 0; i < CT_SKY_LOW_STAR_N; i++) {
            int x = ct_sky_stars[i][0], y = ct_sky_stars[i][1];
            fill_rect(layer, x, y, x + d, y + d, CT_COL_STAR_DIM, 0);
        }
        return;
    }
    // ดวงที่กะพริบไล่สว่างขึ้นแล้วหรี่ลง: dim -> mid -> star(โต) -> mid ขั้นละ 1 วินาที
    // ตั้งต้นที่หรี่แล้วสว่างขึ้น ไม่ใช่ตั้งต้นสว่างแล้วดับ — ดาวดับอ่านเป็นจอเสีย
    // ขั้นสว่างสุดโตเป็น star_peak_px ด้วย: บนแผงจริงต่างแค่สีจางเกินกว่าจะจับได้
    // i * 3 ทำให้สี่ดวงเริ่มคนละขั้น (0,3,2,1) ไม่กะพริบพร้อมกันเป็นจังหวะเดียว
    static const uint16_t ramp[4] = {CT_COL_STAR_DIM, CT_COL_STAR_MID, CT_COL_STAR,
                                     CT_COL_STAR_MID};
    static const int ramp_px[4] = {CT_SKY_STAR_PX, CT_SKY_STAR_PX, CT_SKY_STAR_PEAK_PX,
                                   CT_SKY_STAR_PX};
    for (int i = 0; i < CT_SKY_STARS_COUNT; i++) {
        int x = ct_sky_stars[i][0], y = ct_sky_stars[i][1];
        if (i >= CT_SKY_TWINKLE_N) {
            fill_rect(layer, x, y, x + d, y + d, CT_COL_STAR, 0);
            continue;
        }
        int step = (s_cycle + i * 3) % 4, s = ramp_px[step];
        // โตออกจากกึ่งกลาง ไม่ใช่ยืดลงขวา — ไม่งั้นดวงที่โตขึ้นอ่านเป็นดาวเลื่อนที่
        int off = (s - CT_SKY_STAR_PX) / 2;
        fill_rect(layer, x - off, y - off, x - off + s - 1, y - off + s - 1, ramp[step], 0);
    }
}

// ประกาศล่วงหน้า — draw_clouds ต้องรู้ว่าฟ้าปิดอยู่ไหม แต่บล็อกอากาศอยู่ใต้มัน
static bool weather_is_covered(void);

static void draw_clouds(lv_layer_t *layer, ct_sky_phase_t phase, float t)
{
    uint16_t color = SKY_CLOUD[phase];
    // กลางคืนปกติไม่มีเมฆ (มองไม่เห็น) แต่ตอนฟ้าปิดต้องเห็น ไม่งั้นฝนตกลงมาจากฟ้าโล่ง
    if (phase == CT_SKY_NIGHT) {
        if (!weather_is_covered()) return;
        color = CT_COL_SKY_OVERCAST;
    }
    // ฟ้าปิดใช้ก้อนเพิ่ม โดยหาตำแหน่งของก้อนที่เกินตารางเดิมจากดัชนีของมันเอง
    int count = weather_is_covered() ? CT_WEATHER_OVERCAST_CLOUDS : CT_SKY_CLOUDS_COUNT;
    float span = (float)(CT_SCREEN_WIDTH + 2 * CT_SKY_CLOUD_PAD);
    for (int i = 0; i < count; i++) {
        bool extra = i >= CT_SKY_CLOUDS_COUNT;
        float base_x = extra ? (float)((i * 83 + 29) % CT_SCREEN_WIDTH) : ct_sky_clouds[i][0];
        int y = extra ? (34 + (i * 17) % 46) : ct_sky_clouds[i][1];
        int w = extra ? (30 + (i * 11) % 26) : ct_sky_clouds[i][2];
        float x = fmodf(base_x + t * (float)CT_SKY_CLOUD_SPEED_PX_S, span) - CT_SKY_CLOUD_PAD;
        int xi = (int)lroundf(x);
        fill_rect(layer, xi, y, xi + w, y + 9, color, 4);
        // ก้อนบนทำให้อ่านเป็นเมฆ ไม่ใช่แถบ — เยื้องซ้ายของกึ่งกลาง ไม่ใช่สมมาตร
        int bx = (int)lroundf(x + w * 0.2f), bw = (int)lroundf(w * 0.45f);
        fill_rect(layer, bx, y - 5, bx + bw, y + 4, color, 4);
    }
}

// กอหญ้างอกขึ้นจากเส้นขอบฟ้าไปในฟ้า — ก้านกลางสูงสุด ขนาบด้วยก้านสั้นสองข้าง
// งอกขึ้น ไม่ใช่ห้อยลง: หญ้าที่ยื่นลงไปในพื้นอ่านเป็นรอยขีดบนดิน ไม่ใช่ต้นไม้
static void draw_grass(lv_layer_t *layer, ct_sky_phase_t phase)
{
    uint16_t color = SKY_GRASS[phase];
    int y = CT_SKY_HORIZON - 1;
    for (int i = 0; i < CT_SKY_GRASS_X_COUNT; i++) {
        int x = ct_sky_grass_x[i];
        int main = 3 + i % 4, side = 2 + i % 3;  // สูงเท่ากันหมดอ่านเป็นรั้ว ไม่ใช่หญ้า
        // ก้านหนา 2px เว้นช่อง 1px — ก้าน 1px หายไปเลยบนแผงจริง
        fill_rect(layer, x, y - main, x + 1, y, color, 0);
        fill_rect(layer, x - 3, y - side, x - 2, y, color, 0);
        fill_rect(layer, x + 3, y - (2 + (side + 1) % 3), x + 4, y, color, 0);
    }
}


// ---- สภาพอากาศ ----------------------------------------------------------
//
// อากาศเป็น "อีกแกน" ของท้องฟ้า ไม่ใช่ phase ใหม่: เวลาของวันยังคุมความสว่างพื้นฐาน
// ส่วนอากาศคุมว่ามีอะไรบังฟ้าอยู่ ทั้งสองแกนต้องอ่านออกพร้อมกัน (ฝนตอนกลางคืน
// ต้องยังดูเป็นกลางคืน ไม่ใช่กลายเป็นสีเดียวกับฝนตอนบ่าย)

static bool weather_is_wet(void)
{
    if (!s_snap.has_weather) return false;
    return s_snap.weather == CT_WEATHER_RAIN || s_snap.weather == CT_WEATHER_STORM;
}

// ฟ้าปิดพอที่จะไม่เห็นดวงอาทิตย์/ดวงจันทร์และดาว
static bool weather_is_covered(void)
{
    if (!s_snap.has_weather) return false;
    return s_snap.weather != CT_WEATHER_CLEAR;
}

// สีฟ้าหลังหักผลของอากาศ — กลางคืนไม่ถูกแทนที่ ฟ้าปิดตอนกลางคืนก็ยังมืดเหมือนเดิม
// (เมฆที่หนาขึ้นเป็นตัวบอกเองว่าปิด) ไม่งั้นฝนตอนตีสองจะสว่างกว่าฟ้าโปร่งตอนตีสอง
static uint16_t weather_sky_bg(ct_sky_phase_t phase)
{
    if (!s_snap.has_weather || phase == CT_SKY_NIGHT) return SKY_BG[phase];
    switch (s_snap.weather) {
    case CT_WEATHER_CLOUDY:
    case CT_WEATHER_RAIN: return CT_COL_SKY_OVERCAST;
    case CT_WEATHER_STORM: return CT_COL_SKY_STORM;
    case CT_WEATHER_FOG: return CT_COL_FOG;
    default: return SKY_BG[phase];
    }
}

// ฟ้าแลบ: กะพริบทั้งแผงสั้นๆ แล้วดับ — คำนวณจากเวลาล้วน ไม่เก็บสถานะ
static bool weather_flash_on(float t)
{
    if (!s_snap.has_weather || s_snap.weather != CT_WEATHER_STORM) return false;
    return fmodf(t, CT_WEATHER_FLASH_EVERY_S) < CT_WEATHER_FLASH_HOLD_S;
}

// ฝนเป็นขีดเฉียงที่วนรอบเอง ไม่ใช่ particle จริง — ตำแหน่งแนวนอนกระจายด้วย
// ตัวคูณเฉพาะกิจให้ดูสุ่ม แต่คงที่ทุกครั้งที่บูต (ภาพนิ่งเวลาหยุดเวลา = ดีบักง่าย)
static void draw_rain(lv_layer_t *layer, float t)
{
    const int top = CT_TOPBAR_HEIGHT;
    const int span = CT_SKY_HORIZON - top;
    if (span <= 0) return;

    for (int i = 0; i < CT_WEATHER_DROPS; i++) {
        int x0 = (i * 61 + 13) % CT_SCREEN_WIDTH;
        // เหลื่อมเวลาเริ่มของแต่ละหยด ไม่งั้นตกเป็นแถวเดียวกันทั้งจอ
        float off = fmodf(t * CT_WEATHER_DROP_SPEED_PX_S + (float)(i * 37 % span), (float)span);
        int y0 = top + (int)off;
        int y1 = y0 + CT_WEATHER_DROP_LEN;
        if (y1 >= CT_SKY_HORIZON) y1 = CT_SKY_HORIZON - 1;
        if (y1 <= y0) continue;
        // เอียงด้วยการวาดทีละส่วน — เส้นเฉียงจริงแพงกว่าและมองไม่ออกที่ความยาว 7px
        int x1 = x0 + CT_WEATHER_DROP_SLANT;
        fill_rect(layer, x0, y0, x0, (y0 + y1) / 2, CT_COL_RAIN, 0);
        fill_rect(layer, x1, (y0 + y1) / 2, x1, y1, CT_COL_RAIN, 0);
    }
}

static void sky_draw_cb(lv_event_t *e)
{
    if (s_sky_phase == CT_SKY_NONE) return;  // ไม่มีฉาก = ปล่อยให้เป็นพื้นจอเปล่า

    lv_layer_t *layer = lv_event_get_layer(e);
    ct_sky_phase_t phase = s_sky_phase;
    float t = (float)s_cycle + s_phase;
    bool covered = weather_is_covered();

    // ฟ้าเริ่มใต้แถบบน ไม่ใช่ที่ขอบบนของแถบมาสคอต — แถบมาสคอตนั่งต่ำกว่านั้นลงมามาก
    uint16_t bg = weather_flash_on(t) ? CT_COL_LIGHTNING : weather_sky_bg(phase);
    fill_rect(layer, 0, CT_TOPBAR_HEIGHT, CT_SCREEN_WIDTH - 1, CT_SKY_HORIZON - 1, bg, 0);

    // ฟ้าปิด = ไม่เห็นดาวและไม่เห็นดวง ต้องหายไปพร้อมกัน ไม่งั้นอ่านเป็นฟ้าโปร่งสีแปลก
    if (!covered) {
        draw_stars(layer, phase);
        float x, y;
        uint16_t color;
        sky_disc(s_sky_hours, &x, &y, &color);
        int cx = (int)lroundf(x), cy = (int)lroundf(y), r = CT_SKY_DISC_R;
        fill_rect(layer, cx - r, cy - r, cx + r, cy + r, color, LV_RADIUS_CIRCLE);
    }
    // หมอกคือฟ้าที่ไม่มีอะไรเลย — เมฆในหมอกมองไม่เห็นอยู่แล้ว
    if (!s_snap.has_weather || s_snap.weather != CT_WEATHER_FOG) {
        draw_clouds(layer, phase, t);
    }
    if (weather_is_wet()) draw_rain(layer, t);

    // พื้นดินวาดทับหลังสุด — ครึ่งล่างของดวงและเมฆที่ต่ำเกินไปถูกตัดที่เส้นขอบฟ้าเอง
    fill_rect(layer, 0, CT_SKY_HORIZON, CT_SCREEN_WIDTH - 1, CT_SCREEN_HEIGHT - 1,
              SKY_GROUND[phase], 0);
    draw_grass(layer, phase);
}

// เงาใต้เท้า — ปักหมุดว่าพื้นอยู่ตรงไหน ทำให้ท่ากระโดดอ่านเป็นกระโดด ไม่ใช่ลอย
// ขนาดคงที่ ไม่ยุบตามความสูงที่กระโดด
static void draw_shadow(lv_layer_t *layer, float body_cx)
{
    if (s_sky_phase == CT_SKY_NONE) return;  // ไม่มีพื้นก็ไม่มีเงา
    float half = SHADOW_W_UNIT * CT_SLOTS_UNIT_PX / 2.0f;
    fill_rect(layer, (int)lroundf(body_cx - half), CT_SKY_HORIZON,
              (int)lroundf(body_cx + half), CT_SKY_HORIZON + SHADOW_H - 1,
              SKY_SHADOW[s_sky_phase], LV_RADIUS_CIRCLE);
}

// --- การวาดมาสคอต ------------------------------------------------------------
static void draw_mascot_rects(lv_layer_t *layer, const ct_rects_t *rects, float ox, float oy)
{
    const float px = CT_SLOTS_UNIT_PX;
    lv_draw_rect_dsc_t dsc;
    lv_draw_rect_dsc_init(&dsc);
    dsc.bg_opa = LV_OPA_COVER;
    dsc.border_width = 0;

    for (int i = 0; i < rects->count; i++) {
        const ct_rect_t *r = &rects->items[i];
        int x0 = (int)lroundf(ox + r->x * px);
        int y0 = (int)lroundf(oy + r->y * px);
        int x1 = (int)lroundf(ox + (r->x + r->w) * px);
        int y1 = (int)lroundf(oy + (r->y + r->h) * px);
        if (x1 <= x0 || y1 <= y0) continue;  // ชิ้นที่บางกว่าหนึ่งพิกเซลหายไปเลย
        // clamp เองแทนที่จะปล่อยให้ LVGL ทำ — ฝั่ง preview ใช้ PIL ซึ่งไม่ clamp ให้
        // ถ้าปล่อยไปคนละทาง ขาที่ยุบจนเตี้ยจะออกมาคนละรูปบนจอกับบน preview
        int radius = (int)lroundf(r->r * px);
        int half = ((x1 - x0) < (y1 - y0) ? (x1 - x0) : (y1 - y0)) / 2;
        dsc.radius = radius < half ? radius : half;
        dsc.bg_color = ct_color(r->color);
        lv_area_t a = {.x1 = x0, .y1 = y0, .x2 = x1 - 1, .y2 = y1 - 1};
        lv_draw_rect(layer, &dsc, &a);
    }
}

static void slot_draw_cb(lv_event_t *e)
{
    lv_obj_t *obj = lv_event_get_target_obj(e);
    slot_t *slot = (slot_t *)lv_obj_get_user_data(obj);
    if (!slot || slot->index >= s_snap.session_count) return;

    lv_layer_t *layer = lv_event_get_layer(e);
    lv_area_t coords;
    lv_obj_get_coords(obj, &coords);

    const float px = CT_SLOTS_UNIT_PX;
    // ฝ่าเท้าอยู่เหนือขอบล่างของ slot เท่ากับ baseline_pad เสมอ ไม่ว่าท่าไหน
    float foot = coords.y1 + CT_SLOTS_HEIGHT - CT_SLOTS_BASELINE_PAD;
    float oy = foot - CT_BOX_Y1 * px;
    float ox = coords.x1 + CT_SLOTS_WIDTH / 2.0f - (CT_BOX_X0 + CT_BOX_X1) / 2.0f * px;

    // แต่ละตัวเดินคนละจังหวะเล็กน้อย ไม่งั้นดูเป็นหุ่นยนต์ชุดเดียวกัน
    float phase = fmodf(s_phase + slot->index * 0.17f, 1.0f);

    ct_state_t state = s_snap.sessions[slot->index].state;
    draw_shadow(layer, ox + (BODY_CX + ct_mascot_center_dx(state)) * px);

    ct_rects_t rects;
    ct_mascot_build_centered(&rects, state, phase, s_connected, s_cycle + slot->index);
    // ทาสีตามเอเจนต์หลัง build — ท่าและ prop เหมือนกันทุกเอเจนต์ ต่างแค่สีลำตัว
    ct_agent_recolor(&rects, s_snap.sessions[slot->index].agent);
    draw_mascot_rects(layer, &rects, ox, oy);
}

// ท่าที่หยุดทำกลางทาง วนไปตามรอบ — ต้องตรงกับ STROLL_ACTS ใน tools/gen/screen.py
static const ct_state_t STROLL_ACTS[] = {CT_STATE_CELEBRATE, CT_STATE_THINKING,
                                         CT_STATE_SEARCHING, CT_STATE_WAITING};
// ตำแหน่งหยุดเป็นสัดส่วนของเส้นทาง — วนคนละความยาวกับ ACTS เพื่อไม่ให้จับคู่ซ้ำ
static const float STROLL_PAUSE_AT[] = {0.34f, 0.5f, 0.66f};
#define STROLL_TRAVEL (CT_SCREEN_WIDTH + 2 * CT_STROLL_PAD_PX)

// เวลาสัมบูรณ์ (วินาที) -> ท่า + x ของขอบซ้ายกรอบวาด
// เที่ยวหนึ่ง = เดินจากนอกจอซ้ายไปนอกจอขวา โดยหยุดทำท่าหนึ่งครั้งกลางทาง
// ต้องตรงกับ stroll_pose ใน tools/gen/screen.py
static void stroll_pose(float t, ct_state_t *state, float *x)
{
    const float walk_s = (float)STROLL_TRAVEL / (float)CT_STROLL_SPEED_PX_S;
    const float trip_s = walk_s + CT_STROLL_PAUSE_S;
    int trip = (int)floorf(t / trip_s);
    float u = t - trip * trip_s;
    float hold_at = walk_s * STROLL_PAUSE_AT[trip % (int)(sizeof(STROLL_PAUSE_AT) /
                                                         sizeof(STROLL_PAUSE_AT[0]))];
    float walked;

    if (u < hold_at) {
        walked = u;
        *state = CT_STATE_ENTERING;
    } else if (u < hold_at + CT_STROLL_PAUSE_S) {
        walked = hold_at;
        *state = STROLL_ACTS[trip % (int)(sizeof(STROLL_ACTS) / sizeof(STROLL_ACTS[0]))];
    } else {
        walked = u - CT_STROLL_PAUSE_S;
        *state = CT_STATE_ENTERING;
    }
    *x = -(float)CT_STROLL_PAD_PX + walked * CT_STROLL_SPEED_PX_S;
}

static void stroll_draw_cb(lv_event_t *e)
{
    if (s_snap.session_count > 0) return;

    lv_obj_t *obj = lv_event_get_target_obj(e);
    lv_layer_t *layer = lv_event_get_layer(e);
    lv_area_t coords;
    lv_obj_get_coords(obj, &coords);

    ct_state_t state;
    float x;
    stroll_pose((float)s_cycle + s_phase, &state, &x);

    const float px = CT_SLOTS_UNIT_PX;
    float foot = coords.y1 + CT_SLOTS_HEIGHT - CT_SLOTS_BASELINE_PAD;
    float ox = coords.x1 + x - CT_BOX_X0 * px;

    // ตัวเดินเล่นใช้ build() ตรงๆ ไม่ผ่าน build_centered จึงไม่มี dx มาชดเชย
    draw_shadow(layer, ox + BODY_CX * px);

    ct_rects_t rects;
    ct_mascot_build(&rects, state, s_phase, s_connected, s_cycle);
    draw_mascot_rects(layer, &rects, ox, foot - CT_BOX_Y1 * px);
}

// --- ตัวช่วยสร้าง widget ------------------------------------------------------
static lv_obj_t *plain_obj(lv_obj_t *parent, int w, int h)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, w, h);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

static lv_obj_t *plain_label(lv_obj_t *parent, const lv_font_t *font, uint16_t color)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, ct_color(color), 0);
    lv_label_set_text(l, "");
    return l;
}

// ฉากอยู่หลังทุกอย่าง — ต้องสร้างก่อน widget อื่นทั้งหมด เพราะ LVGL เรียงชั้นตามลำดับสร้าง
// ผืนเดียวตั้งแต่ใต้แถบบนถึงก้นจอ: card วาดพื้นทึบของตัวเองทับอยู่แล้ว
static void build_sky(lv_obj_t *scr)
{
    s_sky = plain_obj(scr, CT_SCREEN_WIDTH, CT_SCREEN_HEIGHT - CT_TOPBAR_HEIGHT);
    lv_obj_set_pos(s_sky, 0, CT_TOPBAR_HEIGHT);
    lv_obj_add_event_cb(s_sky, sky_draw_cb, LV_EVENT_DRAW_MAIN, NULL);
}

// วาดฟ้าใหม่เฉพาะส่วนที่ขยับจริง — พื้นดินกับหญ้านิ่งตลอดช่วง ไม่ต้องแตะ
// แถบฟ้า 320x98 = 31360 px ซึ่งอยู่ในระดับเดียวกับที่แถบมาสคอตวาดใหม่ทุกเฟรม
// (28620 px) — วาดใหม่ไม่เกินวินาทีละครั้งหรือตอนเมฆขยับ (4 px/s) ไม่ใช่ทุกเฟรม
static void invalidate_sky_band(void)
{
    lv_area_t a = {.x1 = 0, .y1 = CT_TOPBAR_HEIGHT, .x2 = CT_SCREEN_WIDTH - 1,
                   .y2 = CT_SKY_HORIZON - 1};
    lv_obj_invalidate_area(s_sky, &a);
}

// ช่วงเวลาเปลี่ยนเมื่อ clock เปลี่ยน (นาทีละครั้ง) หรือสถานะลิงก์เปลี่ยน
// ต้องวาดใหม่ทั้งผืนตอนช่วงเปลี่ยน เพราะพื้นดินกับหญ้าเปลี่ยนสีด้วย
static void update_sky(void)
{
    ct_sky_phase_t was = s_sky_phase;
    float hours = s_connected ? ct_clock_hours(s_snap.clock) : -1.0f;
    s_sky_hours = hours;
    s_sky_phase = hours < 0.0f ? CT_SKY_NONE : sky_phase_at(hours);
    if (s_sky_phase != was) {
        lv_obj_invalidate(s_sky);
    } else if (s_sky_phase != CT_SKY_NONE) {
        invalidate_sky_band();  // ดวงเลื่อนไปตามนาทีที่เดิน
    }
}

static void build_topbar(lv_obj_t *scr)
{
    lv_obj_t *bar = plain_obj(scr, CT_SCREEN_WIDTH, CT_TOPBAR_HEIGHT);
    lv_obj_set_pos(bar, 0, 0);
    lv_obj_set_style_bg_color(bar, ct_color(CT_COL_BG_SLOT), 0);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);

    s_dot = plain_obj(bar, 6, 6);
    lv_obj_set_pos(s_dot, 6, CT_TOPBAR_HEIGHT / 2 - 3);
    lv_obj_set_style_bg_opa(s_dot, LV_OPA_COVER, 0);

    s_link = plain_label(bar, &lv_font_montserrat_12, CT_COL_TEXT);
    lv_obj_align(s_link, LV_ALIGN_LEFT_MID, 17, 0);

    // ไอคอนลิงก์: สามชิ้นพอสำหรับทุกรูปทรง ชิ้นที่เกินก็ซ่อนไป — สร้างครั้งเดียวแล้ว
    // ขยับ ไม่ใช่สร้าง/ลบทุกครั้งที่ลิงก์เปลี่ยน ซึ่งบนจอที่กะพริบอยู่แล้วจะเห็นเป็นสะดุด
    for (int i = 0; i < LINK_ICON_PARTS; i++) {
        s_link_icon[i] = plain_obj(bar, 1, 1);
        lv_obj_set_style_bg_opa(s_link_icon[i], LV_OPA_COVER, 0);
        lv_obj_add_flag(s_link_icon[i], LV_OBJ_FLAG_HIDDEN);
    }

    s_clock_small = plain_label(bar, &lv_font_montserrat_12, CT_COL_TEXT);
    lv_obj_align(s_clock_small, LV_ALIGN_RIGHT_MID, -TOPBAR_RIGHT, 0);

    s_overflow = plain_label(bar, &lv_font_montserrat_12, CT_COL_ACCENT);
    lv_obj_align(s_overflow, LV_ALIGN_RIGHT_MID, -(TOPBAR_RIGHT + 38), 0);

    // โควตาย่อบนแถบ — โผล่เฉพาะตอนการ์ดยึดพื้นที่ล่างไป
    // ไม่มีป้ายกำกับ ("5h") เพราะบนแถบมีค่าเดียว ไม่ต้องบอกว่าตัวไหน
    // เอาพื้นที่นั้นไปทำแถบสั้นแทน ซึ่งเหลือบแล้วรู้ทันทีโดยไม่ต้องอ่านตัวเลข
    s_usage_top = plain_label(bar, &lv_font_montserrat_12, CT_COL_GOOD);
    lv_obj_add_flag(s_usage_top, LV_OBJ_FLAG_HIDDEN);

    // กรอบขาวรอบราง — พื้นรางสีเดียวกับพื้นหลังจอ ทำให้ส่วนที่ยังไม่ถูกใช้กลืนหาย
    // เห็นแต่ "ใช้ไปเท่าไร" ไม่เห็น "เหลือเท่าไร" กรอบตีขอบให้รู้ความยาวเต็ม
    s_usage_track = plain_obj(bar, USAGE_TOP_W + 2, USAGE_TOP_H + 2);
    lv_obj_set_style_bg_color(s_usage_track, ct_color(CT_COL_BG), 0);
    lv_obj_set_style_bg_opa(s_usage_track, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_usage_track, 1, 0);
    lv_obj_set_style_border_color(s_usage_track, ct_color(CT_COL_OUTLINE), 0);
    lv_obj_set_style_border_opa(s_usage_track, LV_OPA_COVER, 0);
    lv_obj_add_flag(s_usage_track, LV_OBJ_FLAG_HIDDEN);

    s_usage_fill = plain_obj(s_usage_track, USAGE_TOP_W, USAGE_TOP_H);
    lv_obj_set_style_bg_opa(s_usage_fill, LV_OPA_COVER, 0);
    lv_obj_set_pos(s_usage_fill, 0, 0);
}

static void build_slots(lv_obj_t *scr)
{
    for (int i = 0; i < CT_SLOTS_COUNT; i++) {
        s_slots[i].index = i;
        lv_obj_t *o = plain_obj(scr, CT_SLOTS_WIDTH, CT_SLOTS_HEIGHT);
        lv_obj_set_pos(o, slot_x(i, CT_SLOTS_COUNT), CT_SLOTS_TOP);
        lv_obj_set_user_data(o, &s_slots[i]);
        lv_obj_add_event_cb(o, slot_draw_cb, LV_EVENT_DRAW_MAIN, NULL);
        s_slots[i].canvas = o;

        lv_obj_t *l = plain_label(scr, &lv_font_montserrat_12, CT_COL_TEXT);
        lv_obj_set_width(l, CT_SLOTS_WIDTH - 4);
        lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
        lv_label_set_long_mode(l, LV_LABEL_LONG_DOT);
        s_slots[i].label = l;
    }
}

// แถบ slot ที่ว่างเปล่าอ่านได้ว่า "อุปกรณ์ค้าง" — ให้มาสคอตเดินผ่านแทน
// ผืนเดียวเต็มความกว้างจอ ไม่ใช่ slot เพราะตัวนี้ข้ามขอบ slot ตลอดเวลา
static void build_stroll(lv_obj_t *scr)
{
    s_stroll = plain_obj(scr, CT_SCREEN_WIDTH, CT_SLOTS_HEIGHT);
    lv_obj_set_pos(s_stroll, 0, CT_SLOTS_TOP);
    lv_obj_add_event_cb(s_stroll, stroll_draw_cb, LV_EVENT_DRAW_MAIN, NULL);
    lv_obj_add_flag(s_stroll, LV_OBJ_FLAG_HIDDEN);
}

static void build_cards(lv_obj_t *scr)
{
    int w = CT_SCREEN_WIDTH - CT_CARD_PAD * 2;
    for (int i = 0; i < CT_MAX_CARDS; i++) {
        lv_obj_t *box = plain_obj(scr, w, CARD_H);
        lv_obj_set_pos(box, CT_CARD_PAD, CT_CARD_TOP + CT_CARD_PAD + i * (CARD_H + CARD_GAP));
        lv_obj_set_style_bg_color(box, ct_color(CT_COL_BG_SLOT), 0);
        lv_obj_set_style_bg_opa(box, LV_OPA_COVER, 0);

        lv_obj_t *accent = plain_obj(box, 3, CARD_H);
        lv_obj_set_pos(accent, 0, 0);
        lv_obj_set_style_bg_opa(accent, LV_OPA_COVER, 0);

        lv_obj_t *title = plain_label(box, &lv_font_montserrat_14, CT_COL_TEXT);
        lv_obj_set_width(title, w - 18);
        lv_label_set_long_mode(title, LV_LABEL_LONG_DOT);
        lv_obj_set_pos(title, 9, 4);

        lv_obj_t *body = plain_label(box, &lv_font_montserrat_12, CT_COL_TEXT_DIM);
        lv_obj_set_width(body, w - 18);
        lv_label_set_long_mode(body, LV_LABEL_LONG_DOT);
        lv_obj_set_pos(body, 9, 20);

        s_cards[i] = (card_t){box, accent, title, body};
        lv_obj_add_flag(box, LV_OBJ_FLAG_HIDDEN);
    }

    // ตำแหน่งแนวตั้งขึ้นกับจำนวนใบที่แสดงจริง — ตั้งตอน layout_cards ไม่ใช่ตรงนี้
    s_card_more = plain_label(scr, &lv_font_montserrat_12, CT_COL_TEXT_DIM);
    lv_obj_add_flag(s_card_more, LV_OBJ_FLAG_HIDDEN);
}

// ขอบซ้าย/ขวาของเนื้อหาในแถว usage — ตรงกับ tools/gen/screen.py:_usage_row
#define USAGE_X0 (CT_CARD_PAD + 8)
#define USAGE_X1 (CT_SCREEN_WIDTH - CT_CARD_PAD - 8)
#define USAGE_W (USAGE_X1 - USAGE_X0)

// ป้ายของแต่ละช่อง — สองช่องแรกเป็นของ Claude จึงไม่ต้องเขียนชื่อกำกับ
// ช่องที่ 4 สำรองไว้ ยังไม่มี daemon ตัวไหนส่งค่ามาให้ (ถูกซ่อนอยู่)
static const char *const USAGE_LABELS[CT_USAGE_ROWS] = {"Current", "Weekly", "Codex", "—"};
static const int USAGE_WINDOWS[CT_USAGE_ROWS] = {CT_USAGE_SESSION_WINDOW,
                                                 CT_USAGE_WEEKLY_WINDOW,
                                                 CT_USAGE_WEEKLY_WINDOW,
                                                 CT_USAGE_WEEKLY_WINDOW};
// สี pill — สองช่องแรกคงสีเดิมของ Claude ช่องของ Codex ใช้สีลำตัวมาสคอตตัวเดียวกัน
// เพื่อให้แถบกับมาสคอตบนจอเดียวกันอ่านเป็นของเจ้าเดียวกัน
static const uint16_t USAGE_PILL_COLORS[CT_USAGE_ROWS] = {CT_COL_CLAY, CT_COL_GOOD,
                                                          CT_COL_CODEX, CT_COL_ANTIGRAV};

// จำนวนแถวจริงของตาราง — ปัดขึ้นเผื่อช่องสุดท้ายไม่เต็มคอลัมน์
#define USAGE_GRID_ROWS ((CT_USAGE_ROWS + CT_USAGE_COLS - 1) / CT_USAGE_COLS)
// ความกว้างของหนึ่งช่อง หลังหักช่องไฟระหว่างคอลัมน์
#define USAGE_CELL_W ((USAGE_W - (CT_USAGE_COLS - 1) * CT_USAGE_GUTTER) / CT_USAGE_COLS)
// pill แคบลงจาก 62 เพราะช่องแคบลงครึ่งหนึ่ง — ยังพอใส่ "Current" ที่ฟอนต์ 12
#define USAGE_PILL_W 54

// ช่อง i เรียงตามแถวก่อน (0,1 = แถวบน / 2,3 = แถวล่าง) — คู่ของ Claude จึงอยู่บรรทัด
// เดียวกัน ซึ่งเป็นคู่ที่ต้องอ่านเทียบกันบ่อยที่สุด
// ต้องตรงกับ _usage ใน tools/gen/screen.py
static int usage_row_y(int i)
{
    int block = USAGE_GRID_ROWS * CT_USAGE_ROW_H + (USAGE_GRID_ROWS - 1) * CT_USAGE_GAP;
    int row = i / CT_USAGE_COLS;
    return CT_CARD_TOP + (CT_CARD_HEIGHT - block) / 2 + row * (CT_USAGE_ROW_H + CT_USAGE_GAP);
}

static int usage_cell_x(int i)
{
    return USAGE_X0 + (i % CT_USAGE_COLS) * (USAGE_CELL_W + CT_USAGE_GUTTER);
}

static void build_usage(lv_obj_t *scr)
{
    for (int i = 0; i < CT_USAGE_ROWS; i++) {
        int y = usage_row_y(i);
        int x = usage_cell_x(i);
        usage_row_t *u = &s_usage[i];

        u->percent_bold = plain_label(scr, &lv_font_montserrat_24, CT_COL_GOOD);
        lv_obj_set_pos(u->percent_bold, x + 1, y + 1);
        u->percent = plain_label(scr, &lv_font_montserrat_24, CT_COL_GOOD);
        lv_obj_set_pos(u->percent, x, y);

        // pill วาดด้วย obj โค้งมุม ไม่ใช่ label ที่มีพื้นหลัง เพราะต้องกำหนดความกว้าง
        // จากความยาวข้อความเองตอน build (ข้อความคงที่ ไม่เปลี่ยนตามข้อมูล)
        u->pill = plain_obj(scr, USAGE_PILL_W, 18);
        lv_obj_set_style_bg_color(u->pill, ct_color(USAGE_PILL_COLORS[i]), 0);
        lv_obj_set_style_bg_opa(u->pill, LV_OPA_COVER, 0);
        lv_obj_set_style_radius(u->pill, 9, 0);
        lv_obj_set_pos(u->pill, x + USAGE_CELL_W - USAGE_PILL_W, y + 5);

        // ตัวอักษรสีหมึกบนพื้น pill สว่าง — สีข้อความเดิมจมกับพื้นส้ม/เขียว
        u->pill_text = plain_label(u->pill, &lv_font_montserrat_12, CT_COL_INK);
        lv_label_set_text(u->pill_text, USAGE_LABELS[i]);
        lv_obj_center(u->pill_text);

        // รางต้องสว่างกว่าพื้นจอพอให้เห็นความยาวเต็มของแถบตอนใช้ไปน้อย
        u->track = plain_obj(scr, USAGE_CELL_W, CT_USAGE_BAR_H);
        lv_obj_set_style_bg_color(u->track, ct_color(CT_COL_GRAY_DARK), 0);
        lv_obj_set_style_bg_opa(u->track, LV_OPA_COVER, 0);
        lv_obj_set_style_radius(u->track, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_pos(u->track, x, y + 28);

        u->fill = plain_obj(u->track, USAGE_CELL_W, CT_USAGE_BAR_H);
        lv_obj_set_style_bg_opa(u->fill, LV_OPA_COVER, 0);
        lv_obj_set_style_radius(u->fill, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_pos(u->fill, 0, 0);

        u->pace = plain_obj(scr, 1, CT_USAGE_BAR_H + 4);
        lv_obj_set_style_bg_color(u->pace, ct_color(CT_COL_OUTLINE), 0);
        lv_obj_set_style_bg_opa(u->pace, LV_OPA_COVER, 0);
        lv_obj_set_pos(u->pace, x, y + 26);

        // เวลารีเซ็ตอยู่บรรทัดเดียวกับเลข % ไม่ใช่ชั้นใต้แถบ — ประหยัด 16px ต่อแถว
        // โดยไม่ต้องลดขนาดเลข %
        //
        // เกาะขอบขวาของป้ายเลข % ไม่ใช่พิกัดตายตัวที่กันที่ไว้ให้ "100%" ซึ่งทำให้
        // เลขสองหลักดูห่างจนไม่เป็นก้อนเดียวกัน ตำแหน่งจริงคำนวณใน layout_usage
        // หลังตั้งข้อความ — lv_obj_align_to คิดครั้งเดียวตอนเรียก ไม่ตามความกว้างใหม่เอง
        u->reset = plain_label(scr, &lv_font_montserrat_12, CT_COL_TEXT_DIM);

        lv_obj_add_flag(u->percent, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(u->percent_bold, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(u->pill, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(u->track, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(u->pace, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(u->reset, LV_OBJ_FLAG_HIDDEN);
    }
}

static void build_idle_clock(lv_obj_t *scr)
{
    // ไม่มีอะไรต้องเตือน = ให้พื้นที่นี้ทำหน้าที่นาฬิกาตั้งโต๊ะแทน
    // นี่คือสภาพที่จอเป็นอยู่เกือบตลอดเวลา ปล่อยว่างแล้วดูเหมือนอุปกรณ์พัง
    int cy = CT_CARD_TOP + CT_CARD_HEIGHT / 2;
    s_clock_big = plain_label(scr, &lv_font_montserrat_48, CT_COL_TEXT);
    lv_obj_align(s_clock_big, LV_ALIGN_TOP_MID, 0, cy - 8 - 24);
    s_date = plain_label(scr, &lv_font_montserrat_12, CT_COL_TEXT_DIM);
    lv_obj_align(s_date, LV_ALIGN_TOP_MID, 0, cy + 26 - 8);
}

void ct_ui_init(void)
{
    ct_model_clear(&s_snap);

    lv_obj_t *scr = lv_screen_active();
    lv_obj_remove_style_all(scr);
    lv_obj_set_style_bg_color(scr, ct_color(CT_COL_BG), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    build_sky(scr);
    build_topbar(scr);
    build_slots(scr);
    build_stroll(scr);
    build_cards(scr);
    build_usage(scr);
    build_idle_clock(scr);
    ct_ui_set_snapshot(&s_snap);
}

// --- ปรับหน้าจอตาม snapshot ---------------------------------------------------
static void layout_slots(void)
{
    int n = s_snap.session_count;
    if (n == 0) {
        lv_obj_remove_flag(s_stroll, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_stroll, LV_OBJ_FLAG_HIDDEN);
    }
    for (int i = 0; i < CT_SLOTS_COUNT; i++) {
        slot_t *s = &s_slots[i];
        if (i >= n) {
            lv_obj_add_flag(s->canvas, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(s->label, LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        int x = slot_x(i, n);
        lv_obj_remove_flag(s->canvas, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s->label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_pos(s->canvas, x, CT_SLOTS_TOP);

        lv_label_set_text(s->label, s_snap.sessions[i].project);
        lv_obj_set_style_text_color(
            s->label, ct_color(s_connected ? CT_COL_TEXT : CT_COL_TEXT_DIM), 0);
        int foot = CT_SLOTS_TOP + CT_SLOTS_HEIGHT - CT_SLOTS_BASELINE_PAD;
        lv_obj_set_pos(s->label, x + 2, foot + 4);
    }
}

static uint16_t card_accent(ct_card_kind_t kind)
{
    switch (kind) {
        case CT_CARD_ALERT: return CT_COL_ALERT;
        case CT_CARD_DONE: return CT_COL_GOOD;
        default: return CT_COL_ACCENT;
    }
}

// ทั้งการ์ดและโควตามาจาก host ทั้งคู่ ลิงก์หลุดแล้วไม่มีใครรับรองว่ายังจริง — พื้นที่ล่าง
// จึงว่างทั้งแถบและตกเป็นของนาฬิกา ตรงกับ Screen.shown_{cards,usage}() ใน gen/screen.py
static int shown_card_count(void)
{
    return s_connected ? s_snap.card_count : 0;
}

static bool usage_shown(void)
{
    return s_snap.has_usage && s_connected;
}

static void layout_cards(void)
{
    int n = shown_card_count();
    for (int i = 0; i < CT_MAX_CARDS; i++) {
        if (i >= n) {
            lv_obj_add_flag(s_cards[i].box, LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        const ct_card_t *c = &s_snap.cards[i];
        lv_obj_remove_flag(s_cards[i].box, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_bg_color(s_cards[i].accent, ct_color(card_accent(c->kind)), 0);
        lv_label_set_text(s_cards[i].title, c->title);
        lv_label_set_text(s_cards[i].body, c->body);
    }

    // การ์ดที่ไม่ได้วาดต้องเหลือร่องรอย ไม่ใช่หายเงียบ — "ไม่มีอะไรค้างแล้ว" กับ
    // "ยังค้างอีกสองเรื่องแต่จอไม่พอ" คือสองสถานะที่ต้องแยกออกได้ในเหลือบเดียว
    if (n > 0 && s_snap.card_overflow > 0) {
        // ตัดที่ 99 — เกินกว่านั้นตัวเลขที่แน่นอนไม่ได้บอกอะไรเพิ่มแล้ว มีแต่จะล้นบรรทัด
        int more = s_snap.card_overflow > 99 ? 99 : s_snap.card_overflow;
        char buf[16];
        snprintf(buf, sizeof(buf), "+%d more", more);
        lv_label_set_text(s_card_more, buf);
        int y = CT_CARD_TOP + CT_CARD_PAD + n * (CARD_H + CARD_GAP) + 1;
        lv_obj_align(s_card_more, LV_ALIGN_TOP_RIGHT, -(CT_CARD_PAD + 8), y);
        lv_obj_remove_flag(s_card_more, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_card_more, LV_OBJ_FLAG_HIDDEN);
    }

    // พื้นที่ล่างมีผู้ยึดสองราย (การ์ด, โควตา) — ถ้ามีรายใดรายหนึ่ง นาฬิกาใหญ่ต้องหลบ
    // ขึ้นไปอยู่บนแถบ ไม่งั้นนาฬิกาหายจากจอทั้งใบ หรือโผล่ซ้ำสองที่
    bool taken = n > 0 || usage_shown();
    if (taken) {
        lv_obj_add_flag(s_clock_big, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_date, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_clock_small, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(s_clock_big, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_date, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_clock_small, LV_OBJ_FLAG_HIDDEN);
    }
}

static uint16_t usage_color(int percent)
{
    if (percent < 0) return CT_COL_TEXT_DIM;
    if (percent >= CT_USAGE_CRIT_PCT) return CT_COL_ALERT;
    if (percent >= CT_USAGE_WARN_PCT) return CT_COL_ACCENT;
    return CT_COL_GOOD;
}

// สีของแถบ — แดงทันทีที่ใช้เร็วกว่าเวลาที่ผ่านไปในหน้าต่าง ไม่ต้องรอถึงเกณฑ์ %
// "60% ตอนเหลือเวลาอีกครึ่ง" เป็นปัญหาคนละแบบกับ "60% ตอนหมดเวลาพอดี"
// ต้องตรงกับ usage_bar_color ใน tools/gen/screen.py
// และ MenuBadge.alarming ใน host/Sources/TamaCore/MenuBadge.swift (แถบเมนูใช้สูตร pace เดียวกัน แต่ไม่มีเกณฑ์ %)
static uint16_t usage_bar_color(const ct_usage_t *u, int window)
{
    if (u->percent < 0) return CT_COL_TEXT_DIM;
    if (u->remaining > 0 && window > 0) {
        int elapsed = window - u->remaining;
        if (elapsed < 0) elapsed = 0;
        if (elapsed > window) elapsed = window;
        if ((int64_t)u->percent * window > (int64_t)elapsed * 100) return CT_COL_ALERT;
    }
    return usage_color(u->percent);
}

// วินาทีที่เหลือ -> ข้อความสั้นที่สุดที่ยังบอกได้ว่าควรรีบไหม
// ต้องตรงกับ fmt_remaining ใน tools/gen/screen.py
static void usage_reset_text(const ct_usage_t *u, char *out, size_t cap)
{
    if (u->remaining < 0) {
        snprintf(out, cap, "no data");
    } else if (u->remaining == 0) {
        snprintf(out, cap, "resetting");
    } else {
        int d = u->remaining / 86400;
        int h = (u->remaining % 86400) / 3600;
        int m = (u->remaining % 3600) / 60;
        if (d) {
            snprintf(out, cap, "Resets in %dd %dh", d, h);
        } else if (h) {
            snprintf(out, cap, "Resets in %dh %02dm", h, m);
        } else {
            snprintf(out, cap, "Resets in %dm", m);
        }
    }
}

// โควตาย่อบนแถบตอนการ์ดยึดพื้นที่ล่าง — แสดงเฉพาะหน้าต่าง 5 ชม. ซึ่งเป็นตัวที่ขยับ
// เร็วพอจะเปลี่ยนการตัดสินใจภายในวันเดียว ส่วน weekly รอดูตอนการ์ดหายไปได้
static void layout_usage_topbar(void)
{
    bool show = usage_shown() && shown_card_count() > 0;
    if (!show) {
        lv_obj_add_flag(s_usage_top, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_usage_track, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    const ct_usage_t *u = &s_snap.usage[0];
    uint16_t col = usage_color(u->percent);

    if (u->percent < 0) {
        lv_label_set_text(s_usage_top, "--%");
    } else {
        lv_label_set_text_fmt(s_usage_top, "%d%%", u->percent);
    }
    lv_obj_set_style_text_color(s_usage_top, ct_color(col), 0);

    // หลบ "+N" เมื่อมันโผล่ ไม่งั้นทับกัน
    int right = -(TOPBAR_RIGHT + 38 + (s_snap.overflow > 0 ? 26 : 0));
    lv_obj_align(s_usage_top, LV_ALIGN_RIGHT_MID, right, 0);
    // align จัดที่ *ขอบขวา* ของ track ให้เอง — ไม่ต้องหักความกว้างแถบออกอีก
    // (ฝั่ง Pillow ต้องหักเองเพราะวาดจากมุมซ้ายบน) ตรงกับ tools/gen/screen.py:_topbar
    lv_obj_align(s_usage_track, LV_ALIGN_RIGHT_MID, right - 30, 0);

    if (u->percent < 0) {
        lv_obj_add_flag(s_usage_fill, LV_OBJ_FLAG_HIDDEN);
    } else {
        int pct = u->percent > 100 ? 100 : (u->percent < 0 ? 0 : u->percent);
        int w = (USAGE_TOP_W * pct + 50) / 100;
        if (w <= 0) {
            lv_obj_add_flag(s_usage_fill, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_remove_flag(s_usage_fill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_width(s_usage_fill, w);
            lv_obj_set_style_bg_color(s_usage_fill, ct_color(col), 0);
        }
    }
    lv_obj_remove_flag(s_usage_top, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(s_usage_track, LV_OBJ_FLAG_HIDDEN);
}

static void layout_usage(void)
{
    // การ์ดชนะโควตาเสมอ — การ์ดคือสิ่งที่ต้องการการกระทำจากผู้ใช้
    bool show = usage_shown() && shown_card_count() == 0;
    for (int i = 0; i < CT_USAGE_ROWS; i++) {
        usage_row_t *row = &s_usage[i];
        if (!show) {
            lv_obj_add_flag(row->percent, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->percent_bold, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->pill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->track, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->pace, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->reset, LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        const ct_usage_t *u = &s_snap.usage[i];
        // ไม่มีทั้งเปอร์เซ็นต์และเวลา = daemon ไม่เคยส่งช่องนี้มาเลย (เช่นช่องสำรอง)
        // ต่างจาก "รู้ว่ามีหน้าต่างแต่ยังไม่รู้ค่า" ซึ่งต้องโชว์ -- ตามดีไซน์เดิม
        if (u->percent == CT_USAGE_UNKNOWN && u->remaining == CT_USAGE_UNKNOWN) {
            lv_obj_add_flag(row->percent, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->percent_bold, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->pill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->track, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->pace, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(row->reset, LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        uint16_t col = usage_bar_color(u, USAGE_WINDOWS[i]);

        lv_obj_remove_flag(row->percent, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(row->percent_bold, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(row->pill, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(row->track, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(row->reset, LV_OBJ_FLAG_HIDDEN);

        if (u->percent < 0) {
            lv_label_set_text(row->percent, "--%");
            lv_label_set_text(row->percent_bold, "--%");
        } else {
            lv_label_set_text_fmt(row->percent, "%d%%", u->percent);
            lv_label_set_text_fmt(row->percent_bold, "%d%%", u->percent);
        }
        lv_obj_set_style_text_color(row->percent, ct_color(col), 0);
        lv_obj_set_style_text_color(row->percent_bold, ct_color(col), 0);

        // เปอร์เซ็นต์ที่ไม่รู้ = แถบว่าง ไม่ใช่แถบศูนย์ที่ดูเหมือนข้อมูลจริง
        int pct = u->percent;
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        int w = (USAGE_CELL_W * pct + 50) / 100;
        if (u->percent < 0 || w <= 0) {
            lv_obj_add_flag(row->fill, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_remove_flag(row->fill, LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_width(row->fill, w);
            lv_obj_set_style_bg_color(row->fill, ct_color(col), 0);
        }

        // ขีด pace หาได้จากเวลาที่เหลือล้วนๆ — ความยาวหน้าต่างเป็นค่าคงที่
        // ไม่ต้องส่งอะไรเพิ่มบนสาย และเดินต่อได้เองตอน BLE หลุด
        if (u->remaining > 0) {
            int elapsed = USAGE_WINDOWS[i] - u->remaining;
            if (elapsed < 0) elapsed = 0;
            if (elapsed > USAGE_WINDOWS[i]) elapsed = USAGE_WINDOWS[i];
            int y = usage_row_y(i) + 26;
            lv_obj_set_pos(row->pace,
                           usage_cell_x(i)
                               + (int)((int64_t)USAGE_CELL_W * elapsed / USAGE_WINDOWS[i]),
                           y);
            lv_obj_remove_flag(row->pace, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(row->pace, LV_OBJ_FLAG_HIDDEN);
        }

        char text[24];
        usage_reset_text(u, text, sizeof(text));
        lv_label_set_text(row->reset, text);

        // ความกว้างของป้ายเลข % เพิ่งเปลี่ยนตามข้อความ ("100%" กว้างกว่า "35%" ~13px)
        // ต้องบังคับให้ LVGL คิดขนาดใหม่ก่อน ไม่งั้นจัดชิดกับความกว้างของเฟรมก่อนหน้า
        lv_obj_update_layout(row->percent);
        lv_obj_align_to(row->reset, row->percent, LV_ALIGN_OUT_RIGHT_MID, 12, 0);
    }
}

void ct_ui_set_snapshot(const ct_snapshot_t *snap)
{
    s_snap = *snap;

    lv_label_set_text(s_clock_big, s_snap.clock);
    lv_label_set_text(s_clock_small, s_snap.clock);
    // อุณหภูมิต่อท้ายวันที่ ไม่ใช่บรรทัดใหม่ — พื้นที่นี้แชร์กับแผงโควตาอยู่แล้ว
    if (s_snap.has_weather && s_snap.temperature != CT_TEMP_UNKNOWN) {
        char line[CT_DATE_LEN + 12];
        snprintf(line, sizeof(line), "%s  %d\u00b0", s_snap.date, s_snap.temperature);
        lv_label_set_text(s_date, line);
    } else {
        lv_label_set_text(s_date, s_snap.date);
    }
    lv_obj_align(s_clock_big, LV_ALIGN_TOP_MID, 0, CT_CARD_TOP + CT_CARD_HEIGHT / 2 - 32);
    lv_obj_align(s_date, LV_ALIGN_TOP_MID, 0, CT_CARD_TOP + CT_CARD_HEIGHT / 2 + 18);

    if (s_snap.overflow > 0) {
        lv_label_set_text_fmt(s_overflow, "+%d", s_snap.overflow);
        lv_obj_remove_flag(s_overflow, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_overflow, LV_OBJ_FLAG_HIDDEN);
    }

    update_sky();
    layout_slots();
    layout_cards();
    layout_usage();
    layout_usage_topbar();
}

void ct_ui_set_link(bool ble, bool wifi, const char *ip)
{
    const icon_rect_t *parts = ICON_NONE;
    int count = 1;
    uint16_t col = CT_COL_TEXT_DIM;
    if (ble) {
        parts = ICON_BLE;
        count = 3;
        col = CT_COL_GOOD;
    } else if (wifi) {
        parts = ICON_WIFI;
        count = 3;
        col = CT_COL_ACCENT;
    }

    // ป้ายข้างจุดพูดเรื่องเดียวกับไอคอน แต่ตอบคำถามที่ไอคอนตอบไม่ได้: "แล้วจะไปหามัน
    // ที่ไหน" — Mac ที่หาบอร์ดไม่เจอผ่าน mDNS ต้องการเลขนี้ และนั่นคือตอนที่ BLE ตายพอดี
    // (ตรงกับ _topbar ใน tools/gen/screen.py)
    const char *label = "no link";
    if (ble) {
        label = "tamaclaude";
    } else if (wifi && ip && ip[0]) {
        label = ip;
    }
    lv_label_set_text(s_link, label);

    const int x0 = CT_SCREEN_WIDTH - 6 - CT_TOPBAR_LINK_ICON_W;
    const int y0 = (CT_TOPBAR_HEIGHT - CT_TOPBAR_LINK_ICON_H) / 2;
    for (int i = 0; i < LINK_ICON_PARTS; i++) {
        if (i >= count) {
            lv_obj_add_flag(s_link_icon[i], LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        lv_obj_set_size(s_link_icon[i], parts[i].w, parts[i].h);
        lv_obj_set_pos(s_link_icon[i], x0 + parts[i].x, y0 + parts[i].y);
        lv_obj_set_style_bg_color(s_link_icon[i], ct_color(col), 0);
        lv_obj_remove_flag(s_link_icon[i], LV_OBJ_FLAG_HIDDEN);
    }
}

void ct_ui_set_connected(bool connected)
{
    if (connected == s_connected) return;
    s_connected = connected;
    lv_obj_set_style_bg_color(s_dot, ct_color(connected ? CT_COL_GOOD : CT_COL_GRAY), 0);
    // ข้อความของป้ายเป็นของ `ct_ui_set_link` (มันรู้ว่าทางไหนใช้อยู่และ IP คืออะไร)
    // ที่นี่เหลือแค่สี ซึ่งตอบคนละคำถาม: ตัวเลขบนจอยังสดอยู่ไหม
    lv_obj_set_style_text_color(s_link,
                                ct_color(connected ? CT_COL_TEXT : CT_COL_TEXT_DIM), 0);
    // นาฬิกาใหญ่หรี่เป็นเทาตอนหลุด — เวลาที่ค้างอยู่ยังอ่านได้ แต่ต้องไม่อ่านว่าเป็นตอนนี้
    // (ตรงกับ _idle_clock ใน tools/gen/screen.py)
    lv_obj_set_style_text_color(s_clock_big, ct_color(connected ? CT_COL_TEXT : CT_COL_GRAY), 0);
    update_sky();  // หลุดลิงก์ = ฉากหายทั้งผืน clock ที่ค้างอยู่ไม่ใช่เวลาจริงอีกต่อไป
    layout_slots();
    // แผงโควตาเข้า/ออกตามลิงก์ และนาฬิกาใหญ่ต้องกลับลงมายึดพื้นที่ที่มันปล่อยไว้
    layout_cards();
    layout_usage();
    layout_usage_topbar();
    for (int i = 0; i < CT_SLOTS_COUNT; i++) lv_obj_invalidate(s_slots[i].canvas);
    lv_obj_invalidate(s_stroll);
}

void ct_ui_tick(void)
{
    s_phase += (float)FRAME_MS / (float)LOOP_MS;
    bool second_passed = false;
    while (s_phase >= 1.0f) {
        s_phase -= 1.0f;
        s_cycle++;
        second_passed = true;
    }
    for (int i = 0; i < s_snap.session_count; i++) {
        lv_obj_invalidate(s_slots[i].canvas);
    }
    if (s_snap.session_count == 0) lv_obj_invalidate(s_stroll);

    // ฟ้าวาดใหม่ตอนเมฆขยับถึงพิกเซลถัดไป (~4 ครั้ง/วิ) หรือตอนวินาทีเดิน (ดาวกะพริบ)
    // ไม่ใช่ทุกเฟรม — ที่ 60ms ต่อเฟรมจะได้ 16 ครั้ง/วิ โดยที่ภาพเปลี่ยนแค่ 4 ครั้ง
    if (s_sky_phase != CT_SKY_NONE) {
        int shift = (int)(((float)s_cycle + s_phase) * (float)CT_SKY_CLOUD_SPEED_PX_S);
        // ฝนวิ่ง 150px/วิ ถ้าใช้เกตของเมฆ (4px/วิ) จะเห็นเป็นภาพนิ่งกระตุก
        // ฟ้าแลบก็สั้นกว่าคาบของเกตเดิม จึงต้องวาดทุกเฟรมตอนมีอากาศเคลื่อนไหว
        bool animated = weather_is_wet() || (s_snap.has_weather
                                             && s_snap.weather == CT_WEATHER_STORM);
        if (shift != s_cloud_shift || second_passed || animated) {
            s_cloud_shift = shift;
            invalidate_sky_band();
        }
    }

    // countdown เดินด้วยนาฬิกาของบอร์ดเอง ไม่ใช่ snapshot — เวลารีเซ็ตเป็นค่าสัมบูรณ์
    // BLE หลุดแล้วตัวเลขนี้ยังจริง ส่วนเปอร์เซ็นต์หยุดนิ่ง (ซึ่งถูก มันหยุดจริง)
    //
    // วาดใหม่เฉพาะตอนวินาทีเดิน และเฉพาะตอนแผงโผล่อยู่ — LVGL วาดเฉพาะสิ่งที่
    // invalidate เท่านั้น การเรียก layout_usage ทุกเฟรมจะกินเวลาไปเปล่าๆ
    // ตอนหลุดลิงก์ countdown ยังเดินในหน่วยความจำ (ค่าที่ถูกตอนกลับมาต่อ) แต่ไม่มีอะไรให้วาด
    if (second_passed && s_snap.has_usage) {
        ct_model_tick_usage(&s_snap, 1);
        if (usage_shown()) {
            if (shown_card_count() == 0) {
                layout_usage();
            } else {
                layout_usage_topbar();
            }
        }
    }
}

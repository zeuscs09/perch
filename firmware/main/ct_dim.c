#include "ct_dim.h"

#include "ct_lcd.h"
#include "ct_touch.h"
#include "esp_log.h"

// ไม่มีใครแตะนานเท่านี้ = ไม่มีใครอยู่
//
// สั้นกว่านี้จะหรี่ใส่หน้าคนที่กำลังอ่านอยู่ (คนมองจอโดยไม่แตะได้นานหลายสิบวินาที)
// ยาวกว่านี้แล้วการหรี่แทบไม่ได้อะไรกลับมาในช่วงพักสั้นๆ ซึ่งเป็นช่วงที่เกิดบ่อยที่สุด
#define IDLE_MS 60000

// ความสว่างตอนหรี่ คิดเป็นสัดส่วนของค่าที่ผู้ใช้ตั้ง ไม่ใช่ค่าคงที่ —
// คนที่ตั้ง 30% ไว้เพราะห้องมืด ไม่ได้อยากได้ 15% ตอนหรี่ เขาอยากได้ที่มืดกว่านั้นอีก
#define DIM_NUM 15
#define DIM_DEN 100
// ไม่ลงถึงศูนย์: จอที่ดับสนิทอ่านว่า "เครื่องพัง" ไม่ใช่ "เครื่องพัก" และมาสคอตที่ยัง
// ขยับอยู่จางๆ คือสิ่งที่บอกว่าทุกอย่างยังทำงาน โดยไม่ต้องแตะอะไรเลย
#define DIM_FLOOR 4

// เวลาไล่ลง — ตัดวูบเดียวสะดุดตาเท่ากับตอนสว่างขึ้น ทั้งที่ไม่มีอะไรเกิดขึ้นเลย
// การไล่ลงช้าๆ อ่านเป็น "มันกำลังพัก" ซึ่งตรงกับสิ่งที่เกิดขึ้นจริง
#define FADE_MS 800

// ความสว่างกลางคืน — ต่ำกว่าการหรี่ปกติมาก เพราะโจทย์คนละข้อ
//
// การหรี่ปกติแก้เรื่อง "ไม่มีใครดูอยู่" ซึ่งยังต้องอ่านออกถ้ามีคนเหลือบมา
// กลางคืนแก้เรื่อง "มีคนนอนอยู่ในห้องนี้" ซึ่งต้องไม่เป็นแหล่งกำเนิดแสงเลย
// 15% ในห้องมืดสนิทยังแยงตา — ตัวเลขนี้มาจากการที่ห้องมืดทำให้ตาไวขึ้นมาก
#define NIGHT_PCT 2

static int s_user = 100;      // เพดานที่ผู้ใช้ตั้ง
static int s_shown = 100;     // ค่าที่ส่งให้ไฟหลังไปแล้ว
static int s_idle_ms = 0;
static bool s_night = false;

static int dim_level(void)
{
    int v = s_user * DIM_NUM / DIM_DEN;
    if (v < DIM_FLOOR) v = DIM_FLOOR;
    if (v > s_user) v = s_user;  // ผู้ใช้ตั้งไว้ต่ำกว่าพื้นแล้ว อย่าหรี่ขึ้น
    return v;
}

static void apply(int percent)
{
    if (percent == s_shown) return;
    // พูดเฉพาะตอนถึงปลายทาง ไม่ใช่ทุกขั้นของการไล่ — ไม่งั้นการหรี่หนึ่งครั้งได้ 85 บรรทัด
    if (percent == s_user && s_shown < s_user) ESP_LOGI("dim", "สว่างเต็ม %d%%", percent);
    if (percent == dim_level() && s_shown > percent) ESP_LOGI("dim", "หรี่เหลือ %d%%", percent);
    s_shown = percent;
    ct_lcd_set_backlight(percent);
}

void ct_dim_init(void)
{
    s_shown = ct_lcd_backlight();
    s_user = s_shown;
    s_idle_ms = 0;
}

void ct_dim_set_user(int percent)
{
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    s_user = percent;
    // ผู้ใช้เพิ่งลากแถบความสว่าง = ผู้ใช้กำลังมองจออยู่แน่นอน
    ct_dim_wake();
}

void ct_dim_wake(void)
{
    s_idle_ms = 0;
    apply(s_user);  // ทันที ไม่ไล่ขึ้น — คนที่เพิ่งแตะจอกำลังรอดูอยู่
}

// ไล่ความสว่างลงหาเป้าหมายตามเวลาจริง ไม่ใช่ทีละขั้นต่อรอบ — จังหวะของลูปหลัก
// เปลี่ยนได้ตามงานที่ค้าง ถ้าผูกกับจำนวนรอบ ความเร็วการหรี่จะเปลี่ยนตามว่าบอร์ดยุ่งแค่ไหน
static void fade_to(int target, int elapsed_ms)
{
    if (s_shown <= target) return;
    int span = s_user - target;
    if (span <= 0) return;
    int step = span * elapsed_ms / FADE_MS;
    if (step < 1) step = 1;
    int next = s_shown - step;
    if (next < target) next = target;
    apply(next);
}

void ct_dim_set_night(bool on)
{
    if (on == s_night) return;
    s_night = on;
    if (!on) ct_dim_wake();  // เช้าแล้ว สว่างกลับทันที ไม่ต้องรอให้ใครมาแตะ
}

void ct_dim_tick(int elapsed_ms)
{
    // กลางคืนไม่ต้องรอให้เห็นการแตะก่อน ต่างจากการหรี่ปกติ เพราะมันมีทางออกที่ไม่ขึ้นกับ
    // ฮาร์ดแวร์อยู่แล้ว: เจ็ดโมงเช้าจอสว่างกลับเอง ต่อให้แตะไม่ติดเลยก็ไม่มีวันค้างมืด
    if (s_night) {
        fade_to(NIGHT_PCT, elapsed_ms);
        return;
    }
    // อย่าดับสิ่งที่ตัวเองเปิดคืนไม่ได้ — จนกว่าจะเห็นการแตะติดสักครั้ง จอสว่างเต็มไว้ก่อน
    if (!ct_touch_seen()) {
        apply(s_user);
        return;
    }
    if (s_idle_ms < IDLE_MS) {
        s_idle_ms += elapsed_ms;
        if (s_idle_ms < IDLE_MS) {
            apply(s_user);
            return;
        }
        // เพิ่งข้ามเส้น — เริ่มไล่ลงจากค่าปัจจุบัน
    }
    fade_to(dim_level(), elapsed_ms);
}

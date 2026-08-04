#include "pch_props.h"

#include <math.h>

#include "layout.h"

// สีหรี่ลงเป็นเทาเข้มเมื่อ BLE หลุด — สัญญาณเดียวกับที่ใช้กับลำตัว
static uint16_t c(bool connected, uint16_t color)
{
    return connected ? color : PCH_COL_GRAY_DARK;
}

// วงกลมกลวง หนา t — ตัดมุมทั้งสี่เป็นแนวทแยง จึงอ่านเป็นวงกลมไม่ใช่กรอบสี่เหลี่ยม
static void ring_round(pch_rects_t *o, float x, float y, float s, float t, uint16_t col)
{
    float k = s / 4.0f;  // ความยาวมุมที่ตัดออก
    pch_rects_add(o, x + k, y, s - 2 * k, t, col);          // บน
    pch_rects_add(o, x + k, y + s - t, s - 2 * k, t, col);  // ล่าง
    pch_rects_add(o, x, y + k, t, s - 2 * k, col);          // ซ้าย
    pch_rects_add(o, x + s - t, y + k, t, s - 2 * k, col);  // ขวา
    const float corner[4][2] = {{k - t, k - t}, {s - k, k - t}, {k - t, s - k}, {s - k, s - k}};
    for (int i = 0; i < 4; i++) {  // ชิ้นเชื่อมมุม
        pch_rects_add(o, x + corner[i][0], y + corner[i][1], t, t, col);
    }
}

// มุมบนซ้ายของเลนส์ในเฟรมนี้ — กระจกกับขอบต้องอ่านค่าเดียวกัน ไม่งั้นเลื่อนหลุดกัน
static void lens_box(float phase, float *ox, float *oy)
{
    // ขยับลงอย่างเดียว — เลนส์สูงกว่าหัวอยู่แล้ว ลอยขึ้นอีกจะฉีกซิลลูเอ็ตจนอ่านไม่ออก
    float lift = fabsf(sinf(phase * (float)M_PI * 2.0f)) * 0.4f;
    *ox = PCH_EYE_R + PCH_EYE_S / 2.0f - PCH_LENS_S / 2.0f;  // จัดวงให้ล้อมตาข้างขวาพอดี
    *oy = PCH_EYE_Y + PCH_EYE_S / 2.0f - PCH_LENS_S / 2.0f + lift;
}

// กระจกในเลนส์ — วาดก่อนตา (pch_mascot.c เรียก) ตาจึงทับกระจก ถ้าวาดพร้อมขอบเลนส์
// ซึ่งอยู่หน้าตา กระจกจะบังตาที่เป็นพระเอกของท่านี้
void pch_prop_magnifier_glass(pch_rects_t *o, float phase, bool connected)
{
    // ตอนหลุดใช้สีเดียวกับลำตัว = กระจกหายไปเลย เทาเข้มจะกลืนกับสีตาจนมองไม่เห็นตาในวง
    uint16_t col = connected ? PCH_COL_GLASS : PCH_COL_GRAY;
    float x, y;
    lens_box(phase, &x, &y);
    float s = PCH_LENS_S - 2 * PCH_LENS_T;  // เต็มรูในวงแหวนพอดี
    x += PCH_LENS_T;
    y += PCH_LENS_T;
    // มุมที่ตัดต้องพอดีบันไดด้านในของวงแหวน ไม่เหลือรูและไม่ล้น
    float k = PCH_LENS_S / 4.0f - PCH_LENS_T;
    pch_rects_add(o, x + k, y, s - 2 * k, k, col);
    pch_rects_add(o, x, y + k, s, s - 2 * k, col);
    pch_rects_add(o, x + k, y + s - k, s - 2 * k, k, col);
}

// แว่นขยาย — Read/Grep/Glob
// ยกมาส่องตาข้างขวาแทนถือห้อยข้างตัว: อ่านออกทันทีว่า "กำลังอ่าน"
// กรอบฟ้าเทา เข้มกว่ากระจกพอให้เห็นเป็นวงแหวน แต่ไม่ดังกว่าตา · วงใหญ่กว่าหัวและล้นขึ้นบน
// โดยตั้งใจ ให้อ่านออกแต่ไกลว่าเป็นแว่นขยาย ไม่ใช่แว่นตา
static void magnifier(pch_rects_t *o, float phase, bool connected)
{
    uint16_t col = c(connected, PCH_COL_STEEL);
    float s = PCH_LENS_S, t = PCH_LENS_T;
    float x, y;
    lens_box(phase, &x, &y);
    ring_round(o, x, y, s, t, col);
    // ด้ามลากลงขวาไปจบที่มือ — ต้องพ้นขอบแขน (16.25) ถึงจะอ่านออกว่าถืออยู่
    for (int i = 0; i < 3; i++) {
        pch_rects_add(o, x + s - 0.5f + i * 1.15f, y + s * 0.70f + i * 0.55f, 1.5f, 1.05f, col);
    }
    // แสงสะท้อนมุมบนซ้าย — วางในช่องว่างระหว่างตากับขอบ ไม่ทับตา
    uint16_t glint = c(connected, PCH_COL_OUTLINE);
    pch_rects_add(o, x + 0.75f, y + 2.0f, 0.75f, 1.25f, glint);
    pch_rects_add(o, x + 1.75f, y + 0.75f, 1.25f, 0.75f, glint);
}

// แว่นตาคร่อมตาสองข้าง — วาดหลังตา (pch_mascot.c เรียก) กรอบจึงทับขอบตา
// วงกลวงทั้งสองข้าง จึงยังเห็นสายตาที่กวาดอ่านอยู่ข้างใน ซึ่งเป็นสัญญาณหลักของท่านี้
// ใช้ steel ไม่ใช่สีหมึก: กรอบสีหมึกจะเชื่อมกับตาที่ 4 px/unit แล้วอ่านเป็นก้อนดำก้อนเดียว
void pch_prop_glasses(pch_rects_t *o, float eye_l, bool connected)
{
    uint16_t col = c(connected, PCH_COL_STEEL);
    float y = PCH_EYE_Y + PCH_EYE_S / 2.0f - PCH_GLS_S / 2.0f;
    float xs[2] = {eye_l + PCH_EYE_S / 2.0f - PCH_GLS_S / 2.0f,
                   PCH_EYE_R + PCH_EYE_S / 2.0f - PCH_GLS_S / 2.0f};
    for (int i = 0; i < 2; i++) ring_round(o, xs[i], y, PCH_GLS_S, PCH_GLS_T, col);
    // สะพานจมูกกับขาแว่นอยู่กลางความสูงของวง = ระดับเดียวกับตา จึงอ่านเป็นเส้นเดียวพาดหน้า
    // (เคยวางแถวบนของวงตามแว่นจริง แล้วอ่านเป็นสายคาดหัว)
    float by = y + PCH_GLS_S / 2.0f - PCH_GLS_T / 2.0f;
    pch_rects_add(o, xs[0] + PCH_GLS_S, by, xs[1] - xs[0] - PCH_GLS_S, PCH_GLS_T, col);
    pch_rects_add(o, xs[0] - PCH_GLS_TEMPLE, by, PCH_GLS_TEMPLE, PCH_GLS_T, col);
    pch_rects_add(o, xs[1] + PCH_GLS_S, by, PCH_GLS_TEMPLE, PCH_GLS_T, col);
}

// โลโก้แอปเปิลบนฝา — ช่องละ 0.25 unit = 1 พิกเซลพอดีที่ unit_px=4 จึงคมและไม่เพี้ยน
// ตั้งใจให้รายละเอียดน้อย: ที่ 12 px ต่อโลโก้ รอยหยักย่อยๆ กลายเป็นขอบเละ ไม่ใช่รูปทรง
#define APPLE_PX 0.25f
#define APPLE_W 10
#define APPLE_H 11
static const char *const APPLE_ART[APPLE_H] = {
    ".....##...",
    "....##....",
    "..######..",
    ".########.",
    "##########",
    "########..",
    "########..",
    "##########",
    ".########.",
    "..######..",
    "..##..##..",
};

// แปลง APPLE_ART เป็น rect ทีละช่วงพิกเซลติดกัน ไม่ใช่ทีละช่อง
static void apple(pch_rects_t *o, float x, float y, uint16_t color)
{
    for (int row = 0; row < APPLE_H; row++) {
        const char *line = APPLE_ART[row];
        for (int col = 0; col < APPLE_W;) {
            if (line[col] != '#') {
                col++;
                continue;
            }
            int run = 1;
            while (col + run < APPLE_W && line[col + run] == '#') run++;
            pch_rects_add(o, x + col * APPLE_PX, y + row * APPLE_PX, run * APPLE_PX, APPLE_PX,
                         color);
            col += run;
        }
    }
}

// แล็ปท็อป — Edit/Write (นั่งพิมพ์ โดยจอหันหลังให้เรา)
// วางทับลำตัวแทนถือข้างตัว: ท่า "พิมพ์โค้ดอยู่" อ่านออกจากการมีจอคั่นระหว่างเรากับตัวมัน
// จอหันหลัง = ฝาทึบล้วน สิ่งเดียวที่บอกว่าอีกด้านเปิดอยู่คือแสงที่รอดเลาะขอบบน
// (จุดสว่างกลางฝาจะอ่านกลับเป็นจอหันเข้าหาเราทันที จึงห้ามมี)
static void laptop(pch_rects_t *o, float phase, bool connected)
{
    // ฝาเป็นแผ่นเหล็ก ไม่ใช่สีดำ — สี่เหลี่ยมดำใหญ่ๆ อ่านเป็น "จอที่เปิดอยู่" เสมอ
    uint16_t shell = c(connected, PCH_COL_STEEL);
    uint16_t rim = c(connected, PCH_COL_INK);
    // แสงที่รอดขอบจอ — ตอนหลุดใช้เทาอ่อน ไม่ใช่เทาเข้ม ไม่งั้นกลืนไปกับฝา
    uint16_t spill = connected ? PCH_COL_GLASS : PCH_COL_GRAY;

    // ขอบฝา — ตัดฝากับลำตัวสีดินออกจากกัน
    pch_rects_add(o, PCH_LID_X, PCH_LID_Y, PCH_LID_W, PCH_LID_H, rim);
    pch_rects_add(o, PCH_LID_X + 0.5f, PCH_LID_Y + 0.5f, PCH_LID_W - 1.0f, PCH_LID_H - 1.0f,
                 shell);  // หลังฝา (ทึบล้วน)
    // ฐาน — เข้มกว่าฝา จึงไม่อ่านเป็นก้อนเดียวกัน
    pch_rects_add(o, PCH_LAP_X, PCH_LAP_Y, PCH_LAP_W, PCH_LAP_H, rim);
    // สันบนของฐาน = ระนาบคีย์บอร์ดที่รับแสง
    pch_rects_add(o, PCH_LAP_X, PCH_LAP_Y, PCH_LAP_W, 0.5f, shell);

    // แสงจอรอดขึ้นเหนือฝา หายใจช้าๆ — ต้องอยู่ *เหนือ* ขอบฝา ไม่ใช่บนฝา ไม่งั้นอ่านเป็นเนื้อจอ
    float w = PCH_LID_W - 4.0f + 0.8f * sinf(phase * (float)M_PI * 2.0f);
    pch_rects_add(o, PCH_LID_X + (PCH_LID_W - w) / 2.0f, PCH_LID_Y - 0.5f, w, 0.5f, spill);

    // โลโก้กลางฝา — รูปทรงชัดเจน ไม่ใช่ก้อนสว่างสี่เหลี่ยม จึงไม่พลิกกลับไปอ่านเป็นเนื้อจอ
    uint16_t mark = c(connected, PCH_COL_OUTLINE);
    apple(o, PCH_LID_X + (PCH_LID_W - APPLE_W * APPLE_PX) / 2.0f,
          PCH_LID_Y + (PCH_LID_H - APPLE_H * APPLE_PX) / 2.0f, mark);
}

// ท่าของการทุบในเฟรมนี้ — ค้อน ตัวมาสคอต ชิ้นงาน และประกาย ต้องอ่านค่าเดียวกัน
// ถ้าแต่ละชิ้นคิดจังหวะเอง จะได้ตัวยุบตอนค้อนยังลอย หรือประกายมาก่อนโดน
pch_ham_stage_t pch_prop_hammer_stage(float phase)
{
    if (phase < PCH_HAM_T_WINDUP) return PCH_HAM_READY;
    if (phase < PCH_HAM_T_STRIKE) return PCH_HAM_WINDUP;
    if (phase < PCH_HAM_T_RECOVER) return PCH_HAM_STRIKE;
    return PCH_HAM_RECOVER;
}

// แท่นเหล็กกับชิ้นงานร้อน — แยกจาก hammer() เพราะห้ามกระเด้งตามตัวมาสคอต
// ของที่วางกับพื้นต้องนิ่ง ถ้าเลื่อนตาม dy จะอ่านเป็นแท่นลอย (pch_mascot.c จึงเรียกแยก)
void pch_prop_hammer_anvil(pch_rects_t *o, float phase, bool connected)
{
    bool strike = pch_prop_hammer_stage(phase) == PCH_HAM_STRIKE;
    // แท่นเทาสองโทน ไม่ใช่สีหมึก — สีหมึกจมไปกับพื้นหลังช่อง เหลือชิ้นงานลอยเดี่ยว
    uint16_t block = c(connected, PCH_COL_STEEL);
    uint16_t base = c(connected, PCH_COL_TEXT_DIM);
    // ชิ้นงานวาบเหลืองในเฟรมที่โดนกระแทก แล้วคืนเป็นแดงร้อน
    uint16_t hot = c(connected, strike ? PCH_COL_ACCENT : PCH_COL_ALERT);
    float h = strike ? PCH_HOT_DOWN_H : PCH_HOT_UP_H;
    // ฐานกว้างกว่าบล็อก จึงอ่านเป็นของตั้งกับพื้น ไม่ใช่ก้อนลอย (จบที่ระดับฝ่าเท้า 12.0)
    pch_rects_add(o, PCH_ANVIL_CX - 2.6f, 11.2f, 5.2f, 0.8f, base);
    pch_rects_add(o, PCH_ANVIL_CX - 1.9f, PCH_ANVIL_TOP, 3.8f, 1.7f, block);  // บล็อกเหล็ก
    // ชิ้นงานร้อน — ยุบตอนโดนทุบ
    pch_rects_add(o, PCH_ANVIL_CX - 1.25f, PCH_ANVIL_TOP - h, 2.5f, h, hot);
}

// หมวกนิรภัย — พีระมิดขั้นบันได '#' คือด้านรับแสง '+' คือริ้วเงา
// ริ้วแนวตั้งสลับกันคือสิ่งที่ทำให้หมวกมีสัน ไม่ใช่โดมเรียบ
// ยอดบนสุดเว้าหนึ่งช่องตรงกลาง — ร่องบนสันหมวกจริง และกันไม่ให้ยอดอ่านเป็นจุกแหลม
#define HAT_ROWS 5
#define HAT_COLS 15
static const char *const HAT_ART[HAT_ROWS] = {
    ".....##.##.....",
    "....+##+##+....",
    "...+##+#+##+...",
    "..++#######++..",
    "+++++++++++++++",
};
#define HAT_W 14.0f  // ปีกยื่นพ้นลำตัว (2..14) ข้างละ 1 — กว้างกว่านี้อ่านเป็นหมวกชาวนา
#define HAT_X0 1.0f
#define HAT_ROW_H 0.96f  // ห้าแถวรวม 4.8 — สูงกว่านี้ยอดหมวกโผล่พ้นกรอบวาดตอนตัวเด้ง

// แปลง HAT_ART เป็น rect ทีละช่วงสีติดกัน ไม่ใช่ทีละช่อง
static void hat(pch_rects_t *o, uint16_t light, uint16_t dark)
{
    const float u = HAT_W / HAT_COLS;
    for (int row = 0; row < HAT_ROWS; row++) {
        const char *line = HAT_ART[row];
        float y = -HAT_ROWS * HAT_ROW_H + row * HAT_ROW_H;
        for (int col = 0; col < HAT_COLS;) {
            char ch = line[col];
            if (ch == '.') {
                col++;
                continue;
            }
            int run = 1;
            while (col + run < HAT_COLS && line[col + run] == ch) run++;
            pch_rects_add(o, HAT_X0 + col * u, y, run * u, HAT_ROW_H,
                         ch == '#' ? light : dark);
            col += run;
        }
    }
}

// ค้อนในท่าหนึ่ง — renderer วาดได้แต่สี่เหลี่ยมแกนตั้งฉาก การหมุนจริงจึงทำไม่ได้
// ท่าคีย์สามท่า (ตั้งพัก / เงื้อทแยงขึ้น / ฟาดทแยงลง) ให้สายตาเติมส่วนที่ขาดเองอยู่แล้ว
static void hammer_tool(pch_rects_t *o, pch_ham_stage_t stage, uint16_t grip, uint16_t head,
                        uint16_t face)
{
    float hx, hy;
    if (stage == PCH_HAM_READY || stage == PCH_HAM_RECOVER) {
        // ตั้งพักข้างตัว — ด้ามเอียงขวาสองขั้น ปลายล่างจบระดับมือ ไม่ลอยห่างจากแขน
        pch_rects_add(o, 16.7f, 2.8f, PCH_HAM_GRIP_W, 3.2f, grip);
        pch_rects_add(o, 17.6f, -0.6f, PCH_HAM_GRIP_W, 3.6f, grip);
        hx = 16.4f;
        hy = -3.0f;
    } else {
        // ด้ามทแยง 45 องศาจากมือ — ขึ้นตอนเงื้อ ลงตอนฟาด (สะท้อนรอบระดับมือเดียวกัน)
        bool up = stage == PCH_HAM_WINDUP;
        float y0 = up ? 4.2f : 3.2f;
        float step = up ? -PCH_HAM_STEP : PCH_HAM_STEP;
        for (int i = 0; i < PCH_HAM_N; i++) {
            pch_rects_add(o, 16.8f + i * PCH_HAM_STEP, y0 + i * step, PCH_HAM_BLK, PCH_HAM_BLK,
                         grip);
        }
        // หัวค้อนต้องคาบปลายด้ามเสมอ ไม่งั้นเห็นเป็นก้อนเทาลอยแยก · ตอนฟาด ก้นหัวจบที่
        // ผิวชิ้นงานที่ยุบแล้วพอดี = จุดที่แรงลงจริง
        hx = up ? 18.8f : PCH_ANVIL_CX - PCH_HAM_HEAD_W / 2.0f;
        hy = up ? -1.0f : PCH_ANVIL_TOP - PCH_HOT_DOWN_H - PCH_HAM_HEAD_H;
    }
    pch_rects_add(o, hx, hy, PCH_HAM_HEAD_W, PCH_HAM_HEAD_H, head);
    // ครึ่งล่างของหัวเข้ม = หน้าค้อนที่ฟาดลงไป ทำให้ก้อนเทาไม่แบนเป็นก้อนเดียว
    pch_rects_add(o, hx, hy + PCH_HAM_HEAD_H / 2.0f, PCH_HAM_HEAD_W, PCH_HAM_HEAD_H / 2.0f, face);
}

// ประกายกระเด็นจากจุดกระแทก — สามทิศที่ไม่สมมาตรกัน จึงอ่านเป็นเศษที่กระเด็นจริง
static const float SPARK_DIRS[3][2] = {{2.5f, -3.8f}, {3.1f, -0.6f}, {1.9f, 1.9f}};

// หมวกวิศวกร + ค้อน — Bash (เงื้อแล้วฟาดชิ้นงานบนแท่น หนึ่งครั้งต่อลูป)
// ค้อนแกว่งอย่างเดียวอ่านได้แค่ "ถือของ" — ต้องครบชุด: หมวกบอกว่าเป็นคนคุมงาน
// ค้อนคือเครื่องมือ แท่นคือสิ่งที่ถูกลงแรง · น้ำหนักมาจากจังหวะ ไม่ใช่จากขนาด
static void hammer(pch_rects_t *o, float phase, bool connected)
{
    pch_ham_stage_t stage = pch_prop_hammer_stage(phase);
    hat(o, c(connected, PCH_COL_ACCENT), c(connected, PCH_COL_ACCENT_WARM));
    // เงาของหัวค้อนต้องเป็นเทากลาง ไม่ใช่สีหมึก — สีหมึกเกือบเท่าพื้นหลังช่อง ครึ่งล่างจะหาย
    hammer_tool(o, stage, c(connected, PCH_COL_CLAY_DARK), c(connected, PCH_COL_TEXT_DIM),
                c(connected, PCH_COL_GRAY));

    // หยดเหงื่อกระเด็นข้างหมวก ตั้งแต่เงื้อจนฟาด — สัญญาณว่ากำลังออกแรง ไม่ใช่กำลังเล่น
    if (stage == PCH_HAM_WINDUP || stage == PCH_HAM_STRIKE) {
        uint16_t drop = c(connected, PCH_COL_GLASS);
        float fly = stage == PCH_HAM_STRIKE ? 1.2f : 0.0f;
        float x = 1.0f - fly, y = -1.2f - fly;
        pch_rects_add(o, x, y, 1.3f, 1.3f, drop);
        pch_rects_add(o, x + 0.3f, y - 0.8f, 0.7f, 0.8f, drop);
    }

    if (stage == PCH_HAM_STRIKE) {
        // กระเด็นออกครึ่งทางในเฟรมที่สองของการฟาด — เฟรมเดียวอ่านเป็นจุดค้าง ไม่ใช่ประกาย
        float t = phase < (PCH_HAM_T_STRIKE + PCH_HAM_T_RECOVER) / 2.0f ? 0.0f : 1.0f;
        uint16_t spark = c(connected, PCH_COL_ACCENT);
        for (int i = 0; i < 3; i++) {
            pch_rects_add(o, PCH_ANVIL_CX - 0.6f + SPARK_DIRS[i][0] * t,
                         PCH_ANVIL_TOP - 1.4f + SPARK_DIRS[i][1] * t, 1.2f, 1.2f, spark);
        }
    }
}

// ลูกโลกบนหัว — วัดจากระดับหัว (y = 0)
// ลูกโลกกับนาฬิกาคร่อมหัวเหมือนกัน จึงใช้ขนาดและตำแหน่งชุดเดียวกัน (CLK_S / CLK_Y)
// ถ้าไม่เท่ากัน การสลับสถานะจะอ่านเป็น "ของโตขึ้น/เล็กลง"
#define PCH_GLB_D 7.0f      // เส้นผ่านศูนย์กลาง — เท่า CLK_S
#define PCH_GLB_CY (-2.0f)  // ขอบบน -5.5 (ไม่ล้น BOX_Y0) ขอบล่าง 1.5 = ขอบบนของตา เท่า CLK_Y
#define PCH_GLB_PX 0.25f    // หนึ่งพิกเซลเป็นหน่วย unit ที่ unit_px = 4
// แถบละ 0.5 unit = 2 px คือจุดที่บันไดยังละเอียดพอให้อ่านเป็นวงกลม
// แถบละ 4 px (8 แถบ) ให้หัวท้ายเป็นแผ่นแบนกว้างจนอ่านเป็นโดม ไม่ใช่ลูกกลม
#define PCH_GLB_BANDS 14
// ขอบลูก 4 px — เท่ากับขอบนาฬิกา (CLK_T) โดยตั้งใจ: ถ้าน้ำหนักเส้นต่างกันจะอ่านเป็นของคนละชุด
#define PCH_GLB_RIM 1.0f

// ทวีป (dx จากขอบซ้าย, dy จากขอบบน, กว้าง, สูง) — ก้อนเดียวอ่านเป็นรอยเปื้อน
// สามก้อนที่ไม่เรียงกันอ่านเป็นแผ่นดินบนลูกกลม
static const float GLB_LAND[3][4] = {
    {0.5f, 1.5f, 2.0f, 1.5f},
    {3.5f, 3.0f, 2.5f, 1.5f},
    {1.5f, 4.5f, 1.5f, 1.0f},
};

// ลูกโลกบนหัว — WebSearch/WebFetch
// ทรงกลมตัน ไม่ใช่สี่เหลี่ยมกลวง เพราะจะซ้ำกับแว่นขยายจนแยกไม่ออกที่ 12px
// ประกอบจากแถบแนวนอนที่กว้างตามสมการวงกลม จึงกลมจริงแม้ที่ 4 px/unit
static void globe(pch_rects_t *o, float phase, bool connected)
{
    // ตอนหลุดยังต้องเหลือสองค่าความสว่าง ไม่งั้นทวีปจมหายกลายเป็นก้อนเทาตัน
    uint16_t ocean = connected ? PCH_COL_GLASS : PCH_COL_GRAY;
    uint16_t land = connected ? PCH_COL_GOOD : PCH_COL_GRAY_DARK;
    // ขอบรอบลูก — ฟ้ามีสี่ช่วงตั้งแต่เกือบดำถึงฟ้าอ่อน ไม่มีสีน้ำสีเดียวที่ตัดกับทั้งสี่
    // ขอบเข้ม + ไส้สว่างตัดกันคนละทาง อย่างน้อยหนึ่งอย่างจึงเห็นเสมอ
    // steel ไม่ใช่ ink — ขอบสีหมึกอ่านเป็นเส้นขีดดำ ไม่ใช่ขอบของทรงกลม
    uint16_t rim = connected ? PCH_COL_STEEL : PCH_COL_GRAY_DARK;

    // ครึ่งความกว้างวัดที่กึ่งกลางแถบ (ไม่ใช่ขอบ) แล้วปัดเป็นพิกเซลเต็ม ขอบซ้าย/ขวาจึงตกบน
    // เส้นพิกเซลพอดี · ไส้ต้องมาจาก *วงกลมที่เล็กลง* (r - PCH_GLB_RIM) ไม่ใช่หักขอบทางแนวนอน:
    // การหักแนวนอนกินแค่ซ้าย/ขวา แถบบน/ล่างยาวเท่าเดิม ไส้ออกมาเป็นวงรีตั้ง (18 x 22 px)
    float r = PCH_GLB_D / 2.0f, r_in = r - PCH_GLB_RIM, bh = PCH_GLB_D / PCH_GLB_BANDS;
    // bhw = ครึ่งความกว้างของ "ไส้" — ทวีปเกาะไส้ ไม่ใช่ขอบ จึงไม่ทับขอบมืด
    float by0[PCH_GLB_BANDS], by1[PCH_GLB_BANDS], bhw[PCH_GLB_BANDS];
    for (int i = 0; i < PCH_GLB_BANDS; i++) {
        by0[i] = PCH_GLB_CY - r + i * bh;
        by1[i] = by0[i] + bh;
        float yy = fabsf(by0[i] + bh / 2.0f - PCH_GLB_CY);
        float q = r * r - yy * yy;
        float hw = roundf(sqrtf(q > 0.0f ? q : 0.0f) / PCH_GLB_PX) * PCH_GLB_PX;
        pch_rects_add(o, PCH_HEAD_CX - hw, by0[i], 2 * hw, by1[i] - by0[i], rim);
        float qi = r_in * r_in - yy * yy;
        float ihw = roundf(sqrtf(qi > 0.0f ? qi : 0.0f) / PCH_GLB_PX) * PCH_GLB_PX;
        // แถบบนสุด/ล่างสุดเป็นขอบล้วน — ถ้าเจาะไส้ด้วย ขอบบน/ล่างจะหายทั้งเส้น
        if (i == 0 || i == PCH_GLB_BANDS - 1) ihw = 0.0f;
        if (ihw > 0.0f) {
            pch_rects_add(o, PCH_HEAD_CX - ihw, by0[i], 2 * ihw, by1[i] - by0[i], ocean);
        }
        bhw[i] = ihw;
    }

    float left = PCH_HEAD_CX - PCH_GLB_D / 2.0f, top = PCH_GLB_CY - PCH_GLB_D / 2.0f;
    float spin = fmodf(phase, 1.0f) * PCH_GLB_D;
    for (int i = 0; i < 3; i++) {
        float px = left + fmodf(GLB_LAND[i][0] + spin, PCH_GLB_D);
        float py = top + GLB_LAND[i][1], w = GLB_LAND[i][2], h = GLB_LAND[i][3];
        // ครึ่งความกว้างที่แคบที่สุดในช่วงที่ทวีปกินอยู่ — ทวีปจึงไม่ยื่นล้นขอบลูกโลก
        float hw = 0.0f;
        bool first = true;
        for (int k = 0; k < PCH_GLB_BANDS; k++) {
            if (by1[k] > py && by0[k] < py + h && (first || bhw[k] < hw)) {
                hw = bhw[k];
                first = false;
            }
        }
        // เล็มด้านที่ล้นทิ้ง แทนการซ่อนทั้งก้อน — ทวีปที่หายวับทั้งชิ้นอ่านเป็นกะพริบ
        // ส่วนที่ค่อยๆ โผล่จากขอบอ่านเป็นแผ่นดินที่หมุนอ้อมมาจากอีกด้าน
        float lo = PCH_HEAD_CX - hw, hi = PCH_HEAD_CX + hw;
        float x0 = px > lo ? px : lo, x1 = (px + w) < hi ? (px + w) : hi;
        if (x1 - x0 >= 0.6f) {  // เศษที่แคบกว่านี้อ่านเป็นจุด ไม่ใช่แผ่นดิน
            pch_rects_add(o, x0, py, x1 - x0, h, land);
        }
    }
}

// ฟองข้อความเหนือหัว — thinking (จุดในฟองไล่สว่างทีละจุด)
// ฟองทึบสีสว่าง จุดสีเข้ม — อ่านออกที่ 12px กว่าจุดลอยเปล่าๆ ซึ่งดูเหมือนเศษ noise
// หางฟองเป็นบันไดชี้ลงหาหัว บอกว่าความคิดนี้เป็นของมาสคอต ไม่ใช่ของ slot ข้างๆ
static void dots(pch_rects_t *o, float phase, bool connected)
{
    // ตอนหลุดฟองหรี่เป็นเทา แต่ยังต้องเข้มพอให้จุดข้างในไม่จม
    uint16_t skin = connected ? PCH_COL_TEXT : PCH_COL_GRAY;
    // ทั้งสามจุดใช้ steel ตัวเดียวกัน ต่างกันแค่ขนาด — จุดที่ยังไม่ติดถ้าเป็นฟ้าอ่อนจะจมหาย
    // ไปกับฟองสว่างเมื่อย่อลงเหลือ ~4px/unit
    uint16_t dot = connected ? PCH_COL_STEEL : PCH_COL_GRAY_DARK;

    float bob = 0.3f * (0.5f + 0.5f * sinf(phase * (float)M_PI * 2.0f));  // ลงอย่างเดียว กันล้นขอบบน
    float x = PCH_HEAD_CX - PCH_BUB_W / 2.0f, y = -5.4f + bob;
    float cut = 0.8f;  // มุมที่ตัดออก ทำให้ฟองมนไม่ใช่กล่อง
    pch_rects_add(o, x + cut, y, PCH_BUB_W - 2 * cut, cut, skin);
    pch_rects_add(o, x, y + cut, PCH_BUB_W, PCH_BUB_H - 2 * cut, skin);
    pch_rects_add(o, x + cut, y + PCH_BUB_H - cut, PCH_BUB_W - 2 * cut, cut, skin);

    // หางบันไดสองขั้น — เยื้องซ้ายของฟอง ชี้ลงหาหัวที่ y=0
    float ty = y + PCH_BUB_H;
    pch_rects_add(o, x + 2.4f, ty, 1.7f, 0.7f, skin);
    pch_rects_add(o, x + 2.4f, ty + 0.7f, 0.9f, 0.6f, skin);

    int lit = (int)(phase * 3.0f) % 3;
    for (int i = 0; i < 3; i++) {
        float s = (i == lit) ? 1.7f : 1.0f;
        float cx = PCH_HEAD_CX + (i - 1) * 2.6f;
        float cy = y + PCH_BUB_H / 2.0f;
        pch_rects_add(o, cx - s / 2, cy - s / 2, s, s, dot);
    }
}

// อัศเจรีย์แดง — alert (พัง/ต้องดูด่วน)
static void bang(pch_rects_t *o, float phase, bool connected)
{
    uint16_t col = c(connected, PCH_COL_ALERT);
    float pulse = 0.4f * (0.5f + 0.5f * sinf(phase * (float)M_PI * 4.0f));
    float x = PCH_HEAD_CX - 0.95f, y = -5.1f - pulse;
    pch_rects_add(o, x, y, 1.9f, 3.0f, col);
    pch_rects_add(o, x, y + 3.8f, 1.9f, 1.3f, col);
}

// เรือนใหญ่คร่อมหัวแบบเดียวกับลูกโลก — ที่ 5.0 unit ไส้เหลือ 3.5 unit เข็มสองเล่มอ่านเป็น
// รอยเปื้อน ต้องโตจนเข็มยาวกับเข็มสั้นต่างกันเห็นชัด แล้วยอมให้ล้นทับหน้าผากแทน
// 7.0 ไม่ใช่ 6.5 เพราะวงแหวนไล่บันไดที่ s/4: 6.5 ทำให้มุมตกที่ 1.625 unit = ครึ่งพิกเซล
// แล้วบันไดเหลื่อมกันจนเห็นเป็นร่อง (บทเรียนเดียวกับเลนส์แว่นขยาย)
#define CLK_S 7.0f  // เส้นผ่านศูนย์กลางหน้าปัด
#define CLK_T 1.0f  // ความหนาขอบ
#define CLK_Y (-5.5f)  // ขอบบนไม่ล้น BOX_Y0 (-5.6) ขอบล่างจบพอดีที่ 1.5 = ขอบบนของตา
#define CLK_HAND_PX 0.75f  // ขนาดก้อนของเข็มหนึ่งช่วง
#define CLK_TICKS 12  // จำนวนตำแหน่งที่เข็มยาวหยุดได้ = จำนวนขีดบนหน้าปัดจริง

// เข็มหนึ่งเล่ม — ทุกก้อนสแนปลงตาราง 0.25 unit (= 1 px) ก่อนวาด ถ้าตกครึ่งพิกเซล
// เข็มจะเบลอเป็นเงาสองชั้น และมุมที่ต่างกันจะหนาไม่เท่ากัน
static void clock_hand(pch_rects_t *o, float cx, float cy, float ang, float len, uint16_t col)
{
    int n = (int)(len / 0.4f + 0.5f);
    if (n < 1) n = 1;
    for (int k = 1; k <= n; k++) {
        float r = k * (len / n);
        float px = roundf((cx + sinf(ang) * r - CLK_HAND_PX / 2) * 4.0f) / 4.0f;
        float py = roundf((cy - cosf(ang) * r - CLK_HAND_PX / 2) * 4.0f) / 4.0f;
        pch_rects_add(o, px, py, CLK_HAND_PX, CLK_HAND_PX, col);
    }
}

// นาฬิกาเหลือง — waiting (รอคำตอบจากคุณ)
// เคยเป็น "?" แต่คำถามอ่านเป็น "งง/ไม่รู้" ปนกับ bang ที่แปลว่าพัง สารจริงคือ
// "เวลากำลังเดินอยู่ ถึงตาคุณแล้ว" · เข็มยาวเดินเป็นขั้น 12 ขั้น: ที่ ~28px การไหลอ่านเป็นภาพสั่น
// เรือนไม่เด้งเลย ขอบล่างจ่อขอบบนของตาอยู่แล้ว ขยับลงอีกนิดก็กินตา
static void clockface(pch_rects_t *o, float phase, bool connected)
{
    uint16_t rim = c(connected, PCH_COL_ACCENT);
    uint16_t face = connected ? PCH_COL_TEXT : PCH_COL_GRAY;
    uint16_t hand = c(connected, PCH_COL_INK);

    float x = PCH_HEAD_CX - CLK_S / 2.0f, y = CLK_Y;
    float s = CLK_S, t = CLK_T, k = CLK_S / 4.0f;

    pch_rects_add(o, x + t, y + k, s - 2 * t, s - 2 * k, face);  // แถบกลาง เต็มความกว้างในขอบ
    pch_rects_add(o, x + k, y + t, s - 2 * k, k - t, face);      // เติมช่องบนใต้ขอบ
    pch_rects_add(o, x + k, y + s - k, s - 2 * k, k - t, face);  // และช่องล่าง
    ring_round(o, x, y, s, t, rim);

    float cx = x + s / 2.0f, cy = y + s / 2.0f;
    int step = (int)(phase * CLK_TICKS) % CLK_TICKS;
    clock_hand(o, cx, cy, step * 2.0f * (float)M_PI / CLK_TICKS, 2.0f, hand);
    // เข็มสั้นค้างที่ 10 นาฬิกา — ตำแหน่งที่เข็มสองเล่มไม่ทับกันและไม่ตั้งฉากจนอ่านเป็นกากบาท
    clock_hand(o, cx, cy, -(float)M_PI / 3.0f, 1.2f, hand);
    pch_rects_add(o, cx - 0.375f, cy - 0.375f, 0.75f, 0.75f, hand);  // ดุมกลาง
}

// Zzz — sleeping (ลอยขึ้นทแยงจากมุมบนขวาของหัว)
static void zzz(pch_rects_t *o, float phase, bool connected)
{
    uint16_t col = c(connected, PCH_COL_TEXT_DIM);
    for (int i = 0; i < 3; i++) {
        float t = fmodf(phase + i / 3.0f, 1.0f);
        float s = 1.0f + i * 0.55f;
        pch_rects_add(o, 11.4f + i * 2.0f + t * 1.0f, -1.1f - i * 1.5f - t * 1.3f, s, s, col);
    }
}

// ประกาย — celebrate (กระพริบสลับรอบตัว)
static void sparkle(pch_rects_t *o, float phase, bool connected)
{
    uint16_t col = c(connected, PCH_COL_ACCENT);
    const float spots[5][2] = {
        {2.6f, -2.6f}, {13.4f, -2.0f}, {PCH_HEAD_CX, -4.0f}, {0.5f, 3.2f}, {18.6f, 5.6f}};
    for (int i = 0; i < 5; i++) {
        if (((int)(phase * 4.0f) + i) % 2) continue;
        float x = spots[i][0], y = spots[i][1];
        pch_rects_add(o, x - 0.45f, y - 1.5f, 0.9f, 3.0f, col);
        pch_rects_add(o, x - 1.5f, y - 0.45f, 3.0f, 0.9f, col);
    }
}

// มาสคอตจิ๋วสองตัวลอยเหนือหัว — conducting (มี subagent กำลังทำงานให้)
// เป็นรูปย่อของมาสคอตเอง ไม่ใช่สัญลักษณ์นามธรรม และกระเด้งคนละเฟส
static void crew(pch_rects_t *o, float phase, bool connected)
{
    uint16_t body = c(connected, PCH_COL_CLAY);
    uint16_t ink = c(connected, PCH_COL_INK);
    for (int i = 0; i < 2; i++) {
        float bob = sinf(phase * (float)M_PI * 2.0f + i * (float)M_PI) * 0.5f;
        float x = PCH_HEAD_CX + (i * 2 - 1) * 4.0f - 1.7f;
        float y = -4.8f + bob;
        pch_rects_add(o, x, y, 3.4f, 2.4f, body);                // ลำตัว
        pch_rects_add(o, x - 0.5f, y + 0.7f, 0.5f, 0.9f, body);  // แขนซ้าย
        pch_rects_add(o, x + 3.4f, y + 0.7f, 0.5f, 0.9f, body);  // แขนขวา
        pch_rects_add(o, x + 0.35f, y + 2.4f, 0.8f, 0.9f, body);  // ขาซ้าย
        pch_rects_add(o, x + 2.25f, y + 2.4f, 0.8f, 0.9f, body);  // ขาขวา
        pch_rects_add(o, x + 0.6f, y + 0.7f, 0.8f, 0.8f, ink);   // ตา
        pch_rects_add(o, x + 2.0f, y + 0.7f, 0.8f, 0.8f, ink);
    }
}

// เสาอากาศบนหัว — LSP/MCP (คลื่นสว่างไล่ออกด้านข้างทีละชั้น)
// "คุยกับบริการอื่นอยู่" ไม่ใช่ "ค้นหา" จึงไม่ใช้ลูกโลกซ้ำ · เสาอยู่บนหัวเพราะสัญญาณต้องออก
// จากตัวมาสคอตเอง · คลื่นแผ่ออกข้าง ไม่ใช่ขึ้นบน — เหนือหัวมีที่แค่ 5.6 unit แนวนอนมีเหลือเฟือ
#define PCH_BEA_TIP_Y (-2.6f)  // กึ่งกลางไฟยอดเสา — สูงกว่านี้ชั้นนอกสุดล้น PCH_BOX_Y0 ตอนตัวเด้ง
#define PCH_BEA_MAST_H 3.0f    // ความสูงเสา จากใต้ไฟยอดเสาลงมาจมในหัว
#define PCH_BEA_ARCS 3
#define PCH_BEA_ARC_D0 1.6f  // ระยะจากเสาของชั้นในสุด
#define PCH_BEA_ARC_DD 1.7f  // ไกลขึ้นต่อชั้น
#define PCH_BEA_ARC_H0 1.5f  // ความสูงสันของชั้นในสุด
#define PCH_BEA_ARC_DH 0.7f  // สูงขึ้นต่อชั้น
#define PCH_BEA_ARC_T 0.6f   // ความหนาของส่วนโค้ง
#define PCH_BEA_TIP_R 1.0f   // รัศมีไฟยอดเสา

// ไฟยอดเสาทรงกลม — สองแท่งไขว้กัน มุมทั้งสี่จึงหายไปและอ่านเป็นวงกลมที่ 3 px/unit
static void beacon_tip(pch_rects_t *o, uint16_t color)
{
    float r = PCH_BEA_TIP_R, cut = PCH_BEA_TIP_R * 0.34f;  // cut = มุมที่ตัดออกแต่ละด้าน
    float x = PCH_HEAD_CX - r, y = PCH_BEA_TIP_Y - r;
    pch_rects_add(o, x + cut, y, 2 * r - 2 * cut, 2 * r, color);  // แท่งตั้ง
    pch_rects_add(o, x, y + cut, 2 * r, 2 * r - 2 * cut, color);  // แท่งนอน
}

// ส่วนโค้งชั้นที่ k สองข้างของเสา (0 = ชั้นในสุด) — ยิ่งไกลสันยิ่งสูง จึงอ่านเป็นวงที่กว้างขึ้น
// ไม่ใช่ขีดสามขีดที่ยาวเท่ากัน
static void beacon_arc(pch_rects_t *o, int k, uint16_t color)
{
    float d = PCH_BEA_ARC_D0 + k * PCH_BEA_ARC_DD;
    float h = PCH_BEA_ARC_H0 + k * PCH_BEA_ARC_DH;
    float t = PCH_BEA_ARC_T;
    float y = PCH_BEA_TIP_Y - h / 2.0f;
    for (int i = 0; i < 2; i++) {
        float side = i == 0 ? -1.0f : 1.0f;  // ซ้าย/ขวา สมมาตรรอบเสา
        // ข้างซ้ายต้องถอยอีกหนึ่งความหนา สันสองข้างจึงห่างเสาเท่ากัน
        float x = PCH_HEAD_CX + side * d - (side < 0.0f ? t : 0.0f);
        float wing = x - side * t;  // ปีกร่นเข้าหาเสาหนึ่งช่วงความหนา
        pch_rects_add(o, x, y, t, h, color);          // สันตั้ง
        pch_rects_add(o, wing, y - t, t, t, color);   // ปีกบน
        pch_rects_add(o, wing, y + h, t, t, color);   // ปีกล่าง
    }
}

static void beacon(pch_rects_t *o, float phase, bool connected)
{
    // ชั้นโผล่สะสม 1 -> 2 -> 3 แล้ววนใหม่ = สัญญาณที่แผ่ออกไกลขึ้นเรื่อยๆ
    // ชั้นที่ยังไม่ถึงคิวคือไม่วาดเลย ไม่มีชั้นเทาค้าง จอจึงเหลือแต่คลื่นจริง
    int step = (int)(phase * PCH_BEA_ARCS) % PCH_BEA_ARCS;  // ชั้นนอกสุดที่โผล่แล้วในเฟรมนี้
    // สีเดียวทั้งชุด — หลายสีอ่านเป็นของหลายชิ้น ไม่ใช่คลื่นชุดเดียว
    uint16_t lit = c(connected, PCH_COL_ACCENT);
    // ไฟยอดเสาแดงคงที่ ไม่กะพริบ — จังหวะอยู่ที่คลื่นแล้ว ถ้ากะพริบด้วยจะแย่งกันเต้น
    uint16_t tip = c(connected, PCH_COL_ALERT);
    // เสาสีขาวเหมือนเส้นขอบตัว จึงอ่านเป็นชิ้นส่วนของมาสคอตเอง ไม่ใช่ของที่พิงอยู่
    uint16_t mast = connected ? PCH_COL_OUTLINE : PCH_COL_GRAY;

    for (int k = 0; k <= step; k++) beacon_arc(o, k, lit);  // สะสมจากชั้นในออกไปข้างนอก
    pch_rects_add(o, PCH_HEAD_CX - 0.5f, PCH_BEA_TIP_Y + 0.6f, 1.0f, PCH_BEA_MAST_H, mast);  // เสา
    beacon_tip(o, tip);
}

void pch_prop_build(pch_rects_t *out, pch_prop_t prop, float phase, bool connected)
{
    switch (prop) {
        case PCH_PROP_MAGNIFIER: magnifier(out, phase, connected); break;
        case PCH_PROP_LAPTOP: laptop(out, phase, connected); break;
        case PCH_PROP_HAMMER: hammer(out, phase, connected); break;
        case PCH_PROP_GLOBE: globe(out, phase, connected); break;
        case PCH_PROP_DOTS: dots(out, phase, connected); break;
        case PCH_PROP_BANG: bang(out, phase, connected); break;
        case PCH_PROP_CLOCK: clockface(out, phase, connected); break;
        case PCH_PROP_ZZZ: zzz(out, phase, connected); break;
        case PCH_PROP_SPARKLE: sparkle(out, phase, connected); break;
        case PCH_PROP_CREW: crew(out, phase, connected); break;
        case PCH_PROP_BEACON: beacon(out, phase, connected); break;
        case PCH_PROP_NONE:
        default: break;
    }
}

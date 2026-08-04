#include "pch_mascot.h"

#include <math.h>
#include <string.h>

#include "pch_props.h"

// --- โครงร่าง (พิกัด unit) --------------------------------------------------
// ทุกค่าวัดจากภาพอ้างอิงซึ่งลงตารางสี่เหลี่ยม 12 x 8 ช่องพอดี CELL คือหนึ่งช่องนั้น
// (ลำตัว 8x8 ช่อง · แขนข้างละ 2x2 · ตา 1x1 · ขากว้าง 1 สูง 2)
#define CELL 1.5f
#define BODY_X 2.0f
#define BODY_Y 0.0f
#define BODY_W (8 * CELL)
#define BODY_H (6 * CELL)  // บล็อกบน 6 ช่อง ที่เหลือเป็นขา
#define NUB_Y (2 * CELL)
#define NUB_H (2 * CELL)
// แขนยาว 1.5 ช่อง ไม่ใช่ 2 ช่องตามภาพอ้างอิง — จุดเดียวที่จงใจเบี่ยง: ที่ 4 px/unit
// แขนเต็มสองช่องยื่นออก 12 px ต่อข้าง อ่านเป็นแขนยาวเก้งก้าง ไม่ใช่ตอแขนแบบต้นฉบับ
#define NUB_W (1.5f * CELL)
// ขาสูงสองช่อง = หนึ่งในสี่ของตัว ตรงกับภาพอ้างอิง
#define LEG_TOP (6 * CELL)
#define LEG_H (2 * CELL)
#define FOOT_Y (LEG_TOP + LEG_H)  // 12 — ระดับที่มาสคอตยืน
#define EYE_L (BODY_X + CELL)
#define EYE_R PCH_EYE_R  // ตาข้างขวานิยามใน pch_props.h — แว่นขยายต้องเล็งไปที่นั่น
#define EYE_Y PCH_EYE_Y
#define EYE_S PCH_EYE_S

// มุมมนของชิ้นซิลลูเอ็ต — มนทุกมุมของทุกชิ้น เพราะ lv_draw_rect กำหนดรายมุมไม่ได้
#define CORNER PCH_MASCOT_CORNER
// ขายืดขึ้นไปซ้อนใต้ลำตัวเท่านี้ ก่อนถึงจะเริ่มวาด — สองเท่าของรัศมี ไม่ใช่หนึ่งเท่า:
// มุมล่างของลำตัวก็มนด้วย ถ้าซ้อนแค่รัศมีเดียว มุมมนของขากับของลำตัวจะเว้าตรงกัน
// แล้วเกิดรอยแหว่งกลางเส้นตรงที่ควรต่อเนื่อง (ขอบนอกของขาต่อกับขอบนอกของลำตัวพอดี)
#define LEG_OVERLAP (CORNER * 2.0f)
// แขนซ้อนเข้าไปในลำตัวเท่ารัศมี — พอให้มุมมนด้านในตกอยู่ใต้เนื้อลำตัวซึ่งทาสีเดียวกัน
// ตรงนั้นเป็นกลางลำตัว ไม่ใช่มุม จึงไม่ต้องเผื่อสองเท่าแบบขา
#define ARM_OVERLAP CORNER

// --- รูปทรงต่อเอเจนต์ --------------------------------------------------------
// ต้องตรงกับ SHAPES ใน tools/gen/mascot.py ทุกตัวเลข
//
// ทุกค่าในนี้อยู่ *ข้างใน* ซิลลูเอ็ตเท่านั้น กรอบนอกของทุกเอเจนต์ต้องเท่ากันเป๊ะ:
// กว้าง 16.5 unit ยอดหัวที่ y = 0 ฝ่าเท้าที่ y = 12 — เพราะ s_center_dx มีชุดเดียว
// และ prop ทุกชิ้นวัดจากกรอบนั้น ถ้าเอเจนต์ไหนล้นออกด้านข้าง ค้อนกับหมวกจะเกาะผิดที่ทั้งชุด
// (ฝั่ง Python มี agents_share_one_box() คอยยืนยันข้อตกลงนี้)
#define MAX_LEGS 4

typedef struct {
    float body_h;
    int leg_count;
    float legs[MAX_LEGS][2];  // (x, w) ต่อขาหนึ่งข้าง
    float arm_y;
    float arm_h;
    bool has_screen;
    float screen[4];  // x, y, w, h ของจอจมสีเข้มที่ตาไปอยู่บนนั้น
} shape_t;

static const shape_t SHAPES[PCH_AGENT_COUNT] = {
    // Claude — ขาทั้งสี่กว้างช่องละหนึ่ง อยู่ที่ช่อง 0/2/5/7 ของลำตัว ช่องกลางจึงกว้างสองช่อง
    // ส่วนช่องข้างกว้างช่องเดียว และขาคู่นอกชิดขอบลำตัวพอดี (ทั้งหมดตามภาพอ้างอิง)
    [PCH_AGENT_CLAUDE] = {.body_h = LEG_TOP,
                          .leg_count = 4,
                          .legs = {{BODY_X + 0 * CELL, CELL},
                                   {BODY_X + 2 * CELL, CELL},
                                   {BODY_X + 5 * CELL, CELL},
                                   {BODY_X + 7 * CELL, CELL}},
                          .arm_y = NUB_Y,
                          .arm_h = NUB_H,
                          .has_screen = false},
    // Codex — จอบนสองขา ไม่ใช่ตัวสี่ขาทาสีใหม่
    //
    // ตัวแยกที่อ่านออกจากอีกฝั่งห้องคือ *ซิลลูเอ็ต* ไม่ใช่สี: จำนวนขาต่างกัน (2 ไม่ใช่ 4)
    // และมีจอจมสีเข้มแทนหน้าเรียบ — สองอย่างนี้เห็นได้ก่อนที่สายตาจะแยกสีฟ้าออกจากสีดิน
    //
    // ขายาวกว่าของ Claude (3.6 เทียบกับ 3.0) เพราะลำตัวเตี้ยลงมาให้จอได้สัดส่วน
    // ฝ่าเท้ายังอยู่ที่ 12 เท่าเดิม — ที่เปลี่ยนคือเส้นแบ่งระหว่างตัวกับขา ไม่ใช่ความสูงรวม
    [PCH_AGENT_CODEX] = {.body_h = 8.4f,
                         .leg_count = 2,
                         .legs = {{3.6f, 3.4f}, {9.0f, 3.4f}},
                         .arm_y = 2.6f,
                         .arm_h = 2.8f,
                         .has_screen = true,
                         .screen = {3.1f, 0.7f, 9.8f, 6.0f}},
    // Antigravity ยังใช้รูปทรงของ Claude — เปลี่ยนแค่สี จนกว่าจะมีคนวาดตัวให้มัน
    [PCH_AGENT_ANTIGRAVITY] = {.body_h = LEG_TOP,
                               .leg_count = 4,
                               .legs = {{BODY_X + 0 * CELL, CELL},
                                        {BODY_X + 2 * CELL, CELL},
                                        {BODY_X + 5 * CELL, CELL},
                                        {BODY_X + 7 * CELL, CELL}},
                               .arm_y = NUB_Y,
                               .arm_h = NUB_H,
                               .has_screen = false},
};

static const shape_t *shape_of(pch_agent_t agent)
{
    if (agent < 0 || agent >= PCH_AGENT_COUNT) agent = PCH_AGENT_CLAUDE;
    return &SHAPES[agent];
}

// ช่วง phase ที่ตากะพริบ — สั้นมากโดยตั้งใจ กะพริบนานกว่านี้จะดูเหมือนง่วง
#define BLINK_FROM 0.88f
#define BLINK_TO 0.94f
// กะพริบทุกกี่รอบลูป — ลูปเดียวยาวราว 1 วินาที กะพริบทุกวินาทีจะดูกระวนกระวาย
#define BLINK_EVERY 4

typedef enum { EYE_OPEN, EYE_SLEEP, EYE_SQUINT, EYE_FOCUS, EYE_WIDE, EYE_BLINK, EYE_HAPPY, EYE_DEAD } eye_t;
typedef enum { GAIT_STAND, GAIT_WALK, GAIT_SIT } gait_t;

typedef struct {
    eye_t eye;
    gait_t gait;
    float squash;
    float bob;     // ระยะแกว่งขึ้นลง (unit)
    float bob_hz;
    float shake;
    float look;
    float scan;    // กวาดสายตาซ้าย->ขวาแล้ววกกลับ (unit) — ท่าอ่านโค้ด
    float arm;     // ระยะที่แขนขยับสลับข้าง (unit) — ท่าพิมพ์
    bool blink;    // ตาลืมเท่านั้นที่กะพริบได้
    bool strike;   // ใช้จังหวะทุบของ pch_prop_hammer_stage() แทนการกระเด้งเป็นคลื่น
    float sink;    // >0 = จมลงดินตามความคืบหน้าของ phase (ท่ามุดหาย)
    float arm_up;  // ระยะที่แขนยกค้างพร้อมกันสองข้าง (unit) — ท่าเพ่งพลัง
    float arm_out; // ระยะที่ท่อนนอกของแขนเยื้องออกนอกตัว (unit) — ใช้คู่กับ arm_up
} mood_t;

typedef enum {
    MOOD_IDLE, MOOD_WORKING, MOOD_TYPING, MOOD_HAMMERING, MOOD_WALKING, MOOD_WAITING,
    MOOD_SLEEPING, MOOD_ALERT, MOOD_CELEBRATE, MOOD_ERROR, MOOD_SIGNALLING,
    MOOD_ENTERING, MOOD_LEAVING,
    MOOD_COUNT,
} mood_id_t;

// bob วัดเป็น unit — 1 unit = PCH_SLOTS_UNIT_PX พิกเซล ต่ำกว่า 0.5 unit จะมองแทบไม่เห็นบนจอ
// ลำดับฟิลด์: eye, gait, squash, bob, bob_hz, shake, look, scan, arm, blink, strike, sink,
// arm_up, arm_out (ท่าที่ไม่ยกแขนไม่ต้องเขียนสองค่าสุดท้าย — C เติม 0 ให้เอง)
static const mood_t MOODS[MOOD_COUNT] = {
    [MOOD_IDLE]      = {EYE_OPEN,   GAIT_STAND, 0.00f, 0.75f, 1.0f, 0.00f, 0.00f, 0.00f, 0.00f, true,  false, 0.0f, 0.0f, 0.0f},
    [MOOD_WORKING]   = {EYE_FOCUS,  GAIT_STAND, 0.03f, 0.50f, 2.4f, 0.00f, 0.00f, 0.00f, 0.00f, true,  false, 0.0f, 0.0f, 0.0f},
    // ท่านั่งพิมพ์ — ตัวแทบไม่กระเด้ง เพราะสัญญาณอยู่ที่สายตาที่กวาดอ่านกับแขนที่พิมพ์
    [MOOD_TYPING]    = {EYE_FOCUS,  GAIT_STAND, 0.03f, 0.30f, 2.0f, 0.00f, 0.00f, 1.00f, 0.70f, true,  false, 0.0f, 0.0f, 0.0f},
    // ท่าทุบ — ไม่กระเด้งเป็นคลื่น แต่ยืดตัวตอนเงื้อและยุบตัวตอนกระแทกตามจังหวะค้อน
    [MOOD_HAMMERING] = {EYE_FOCUS,  GAIT_STAND, 0.00f, 0.35f, 2.0f, 0.00f, 0.00f, 0.00f, 0.00f, true,  true,  0.0f, 0.0f, 0.0f},
    [MOOD_WALKING]   = {EYE_OPEN,   GAIT_WALK,  0.00f, 0.75f, 2.0f, 0.00f, 0.00f, 0.00f, 0.00f, true,  false, 0.0f, 0.0f, 0.0f},
    [MOOD_WAITING]   = {EYE_OPEN,   GAIT_STAND, 0.00f, 1.00f, 0.7f, 0.00f, 0.40f, 0.00f, 0.00f, true,  false, 0.0f, 0.0f, 0.0f},
    [MOOD_SLEEPING]  = {EYE_SLEEP,  GAIT_SIT,   0.10f, 0.50f, 0.35f, 0.00f, 0.00f, 0.00f, 0.00f, false, false, 0.0f, 0.0f, 0.0f},
    [MOOD_ALERT]     = {EYE_WIDE,   GAIT_STAND, 0.00f, 0.90f, 3.2f, 0.20f, 0.00f, 0.00f, 0.00f, false, false, 0.0f, 0.0f, 0.0f},
    [MOOD_CELEBRATE] = {EYE_HAPPY,  GAIT_STAND, -0.05f, 1.25f, 2.6f, 0.00f, 0.00f, 0.00f, 0.00f, false, false, 0.0f, 0.0f, 0.0f},
    [MOOD_ERROR]     = {EYE_DEAD,   GAIT_SIT,   0.12f, 0.00f, 1.0f, 0.08f, 0.00f, 0.00f, 0.00f, false, false, 0.0f, 0.0f, 0.0f},
    // ท่าส่งสัญญาณ — ตาปกติ ไม่เบิกกว้าง (ตาโตอ่านเป็นตกใจ ซึ่งเป็นสารของ alert)
    // สารของท่านี้อยู่ที่เสาอากาศกับมือที่ยกค้าง ไม่ใช่ที่หน้า
    // แขนยกค้างนิ่งพร้อมกันสองข้างแบบเพ่งพลัง — ไม่โยก เพราะการโยกอ่านเป็นโบกมือ
    // ท่อนนอกเยื้องออกนอกตัว จึงเห็นเป็นมือที่ยกขึ้นจริง ไม่ใช่ไหล่ที่สูงขึ้นเฉยๆ
    [MOOD_SIGNALLING] = {EYE_OPEN,  GAIT_STAND, 0.00f, 0.45f, 1.3f, 0.00f, 0.00f, 0.00f, 0.00f, true,  false, 0.0f, 1.9f, 0.9f},
    // ท่าเปลี่ยนผ่าน — phase ทำหน้าที่เป็นความคืบหน้า 0->1 ไม่ใช่ลูปวน
    [MOOD_ENTERING]  = {EYE_OPEN,   GAIT_WALK,  0.00f, 1.00f, 4.0f, 0.00f, 0.00f, 0.00f, 0.00f, true,  false, 0.0f, 0.0f, 0.0f},
    [MOOD_LEAVING]   = {EYE_SQUINT, GAIT_SIT,   0.30f, 0.00f, 1.0f, 0.00f, 0.00f, 0.00f, 0.00f, false, false, 1.0f, 0.0f, 0.0f},
};

// visual state = mood + prop — ต้องตรงกับ STATES ใน tools/gen/mascot.py
static const struct {
    mood_id_t mood;
    pch_prop_t prop;
} STATES[PCH_STATE_COUNT] = {
    [PCH_STATE_IDLE]      = {MOOD_IDLE,      PCH_PROP_NONE},
    [PCH_STATE_READING]   = {MOOD_WORKING,   PCH_PROP_MAGNIFIER},
    [PCH_STATE_WRITING]   = {MOOD_TYPING,    PCH_PROP_LAPTOP},
    [PCH_STATE_BUILDING]  = {MOOD_HAMMERING, PCH_PROP_HAMMER},
    [PCH_STATE_SEARCHING] = {MOOD_WORKING,   PCH_PROP_GLOBE},
    [PCH_STATE_THINKING]  = {MOOD_IDLE,      PCH_PROP_DOTS},
    [PCH_STATE_WAITING]   = {MOOD_WAITING,   PCH_PROP_CLOCK},
    [PCH_STATE_SLEEPING]  = {MOOD_SLEEPING,  PCH_PROP_ZZZ},
    [PCH_STATE_ALERT]     = {MOOD_ALERT,     PCH_PROP_BANG},
    [PCH_STATE_CELEBRATE] = {MOOD_CELEBRATE, PCH_PROP_SPARKLE},
    [PCH_STATE_ERROR]     = {MOOD_ERROR,     PCH_PROP_NONE},
    [PCH_STATE_ENTERING]  = {MOOD_ENTERING,  PCH_PROP_NONE},
    [PCH_STATE_LEAVING]   = {MOOD_LEAVING,   PCH_PROP_NONE},
    [PCH_STATE_CONDUCTING] = {MOOD_WORKING,  PCH_PROP_CREW},
    [PCH_STATE_BEACON]    = {MOOD_SIGNALLING, PCH_PROP_BEACON},
};

// ท่าที่มีของประกอบเยอะจนแน่นช่อง ย่อลงเล็กน้อยเพื่อให้ยังมีที่หายใจรอบตัว
// ต้องตรงกับ STATE_SCALE ใน tools/gen/mascot.py
static float state_scale(pch_state_t state)
{
    return state == PCH_STATE_BUILDING ? 0.875f : 1.0f;
}

// --- ตา ---------------------------------------------------------------------
// ตาหนึ่งข้าง กล่องฐาน EYE_S x EYE_S ที่ (x, EYE_Y) — ทุกค่าอิงสัดส่วน ไม่ฝังตัวเลขดิบ
// scale > 1 = ตาโตขึ้นโดยยึดจุดกึ่งกลางเดิม (ใช้กับตาที่อยู่หลังเลนส์แว่นขยาย)
static void eye(pch_rects_t *o, float x, eye_t kind, float look, uint16_t ink, float scale)
{
    const float s = EYE_S * scale;
    const float grow = (s - EYE_S) / 2.0f;
    const float y = EYE_Y - grow;
    x -= grow;
    switch (kind) {
        case EYE_SLEEP:
            pch_rects_add(o, x, y + s * 0.62f, s, s * 0.3f, ink);
            return;
        case EYE_SQUINT:
            pch_rects_add(o, x, y + s * 0.34f, s, s * 0.42f, ink);
            return;
        case EYE_FOCUS: {
            float m = s * 0.22f;
            pch_rects_add(o, x + m + look, y + m, s - 2 * m, s - 2 * m, ink);
            return;
        }
        case EYE_WIDE: {
            float m = s * 0.24f;
            pch_rects_add(o, x - m + look, y - m, s + 2 * m, s + 2 * m, ink);
            return;
        }
        case EYE_BLINK:
            pch_rects_add(o, x, y + s * 0.42f, s, s * 0.28f, ink);
            return;
        case EYE_HAPPY: {  // ^ ^ — ต้องไม่ใช่ขีดแบน ไม่งั้นซ้ำกับตาหลับ
            float u = s / 3.0f;
            const int cells[3][2] = {{0, 1}, {1, 0}, {2, 1}};
            for (int i = 0; i < 3; i++) {
                pch_rects_add(o, x + cells[i][0] * u, y + cells[i][1] * u, u, u, ink);
            }
            return;
        }
        case EYE_DEAD: {  // x_x — บันไดขั้นละ 1 บล็อกทำเป็นกากบาท
            float u = s / 3.0f;
            const int cells[5][2] = {{0, 0}, {1, 1}, {2, 2}, {2, 0}, {0, 2}};
            for (int i = 0; i < 5; i++) {
                pch_rects_add(o, x + cells[i][0] * u, y + cells[i][1] * u, u, u, ink);
            }
            return;
        }
        case EYE_OPEN:
        default:
            pch_rects_add(o, x + look, y, s, s, ink);
            return;
    }
}

// --- ขา ---------------------------------------------------------------------
static void legs(pch_rects_t *o, const shape_t *sh, gait_t gait, float phase, uint16_t color,
                 float extra_lift)
{
    float leg_h = FOOT_Y - sh->body_h;
    for (int i = 0; i < sh->leg_count; i++) {
        float lift = extra_lift;
        if (gait == GAIT_WALK) {
            // สลับข้างกันยกตามดัชนีคู่/คี่ — สี่ขาได้คู่ทแยง (0,2) กับ (1,3)
            // สองขาได้ซ้ายสลับขวา ซึ่งเป็นการเดินที่ถูกของทั้งสองแบบโดยไม่ต้องแยกโค้ด
            bool up = (phase < 0.5f) == (i % 2 == 0);
            lift += up ? leg_h * 0.34f : 0.0f;
        } else if (gait == GAIT_SIT) {
            lift += leg_h * 0.66f;
        }
        float h = leg_h - lift;
        if (h < 0.6f) h = 0.6f;
        // ยืดขึ้นไปซ้อนใต้ลำตัว — ความสูงที่ *เห็น* ยังเป็น leg_h - lift เท่าเดิม
        pch_rects_add_round(o, sh->legs[i][0], sh->body_h - LEG_OVERLAP, sh->legs[i][1],
                           h + LEG_OVERLAP, color, CORNER);
    }
}

// --- ลำตัว ------------------------------------------------------------------
// ลำตัวกับแขนสองข้างในสัดส่วนปกติ — การยุบตัวทำทีหลังด้วย squashed()
// arm_l/arm_r เลื่อนแขน (nub) ทีละข้าง — ท่าพิมพ์ใช้ค่าคนละเครื่องหมายจึงอ่านเป็นสลับมือ
// arm_out > 0 = แขนเป็นสองท่อนลดหลั่นออกนอกตัว (ท่ายกมือค้าง) แทนที่จะเป็นก้อนเดียว
// ก้อนเดียวที่เลื่อนขึ้นเฉยๆ อ่านเป็น "ไหล่สูงขึ้น" ไม่ใช่ "ยกมือ" — ต้องมีท่อนที่เยื้อง
// ออกไปนอกซิลลูเอ็ต สายตาถึงจะเห็นเป็นแขนที่กางขึ้น
// ท่อนแขนหนึ่งท่อน กว้าง NUB_W โดยขอบด้านที่หันเข้าตัวยืดเข้าไปซ้อนอีก ARM_OVERLAP
// side -1 = แขนซ้าย (ตัวอยู่ทางขวาของท่อน) / +1 = แขนขวา
// ท่อนนอกของท่ายกมือก็ใช้ตัวเดียวกัน มันจึงซ้อนกับท่อนในแทนที่จะแค่ชนกัน
static void arm(pch_rects_t *o, float x0, float y, float h, float side, uint16_t color)
{
    float x = side < 0.0f ? x0 : x0 - ARM_OVERLAP;
    pch_rects_add_round(o, x, y, NUB_W + ARM_OVERLAP, h, color, CORNER);
}

static void body(pch_rects_t *o, const shape_t *sh, uint16_t color, uint16_t screen_c,
                 float arm_l, float arm_r, float arm_out)
{
    pch_rects_add_round(o, BODY_X, BODY_Y, BODY_W, sh->body_h, color, CORNER);
    // จอจมวาดทับลำตัวทันที ก่อนแขน — ตาจะมาทับอีกทีตอนท้าย pch_mascot_build()
    if (sh->has_screen) {
        pch_rects_add_round(o, sh->screen[0], sh->screen[1], sh->screen[2], sh->screen[3],
                           screen_c, CORNER * 0.6f);
    }
    if (arm_out == 0.0f) {
        arm(o, BODY_X - NUB_W, sh->arm_y + arm_l, sh->arm_h, -1.0f, color);
        arm(o, BODY_X + BODY_W, sh->arm_y + arm_r, sh->arm_h, 1.0f, color);
        return;
    }
    // แต่ละท่อนเตี้ยกว่าแขนปกติ สองท่อนรวมกันจึงไม่ยาวเกินสัดส่วนเดิม
    float h = sh->arm_h * 0.8f;
    const float SIDE[2] = {-1.0f, 1.0f};
    const float X0[2] = {BODY_X - NUB_W, BODY_X + BODY_W};
    const float DY[2] = {arm_l, arm_r};
    for (int i = 0; i < 2; i++) {
        // ท่อนใน — ติดลำตัว ยกขึ้นครึ่งทางของท่อนนอก จึงอ่านเป็นแขนที่เอียงขึ้น
        arm(o, X0[i], sh->arm_y + DY[i] + h * 0.5f, h, SIDE[i], color);
        arm(o, X0[i] + SIDE[i] * arm_out, sh->arm_y + DY[i], h, SIDE[i], color);
    }
}

// ยุบทั้งตัวรอบฝ่าเท้า — ลำตัว ขา และตา ต้องยุบเป็นก้อนเดียวกัน
// ถ้ายุบเฉพาะลำตัว ก้นลำตัวจะค้างอยู่ที่เดิมและขายาวเท่าเดิม อ่านเป็นกล่องเตี้ยลง
// บนขาชุดเดิม ไม่ใช่ตัวที่โดนกระแทก ฝ่าเท้าไม่ขยับเพราะระดับที่ยืนต้องคงที่
static void squashed(pch_rects_t *rs, int from, float squash)
{
    if (squash == 0.0f) return;
    pch_rects_scale_from(rs, from, 1.0f + squash * 0.45f, 1.0f - squash, PCH_HEAD_CX, FOOT_Y);
}

// (ลำตัว, ลำตัวตอนหลับ, จอจม, ตา) — ต้องตรงกับ AGENT_SKIN ใน tools/gen/mascot.py
//
// สีตาอยู่ในตารางนี้เพราะมันขึ้นกับว่าตาไปวางอยู่บนอะไร ไม่ใช่รสนิยม: ตาของ Claude อยู่บน
// เนื้อตัวสีสว่างจึงต้องเป็นหมึก ส่วนตาของ Codex อยู่บนจอสีเข้มจึงต้องเรืองแสง
typedef struct {
    uint16_t base;
    uint16_t dark;
    uint16_t sleep;
    uint16_t eye;
} palette_t;

static const palette_t PALETTES[PCH_AGENT_COUNT] = {
    [PCH_AGENT_CLAUDE] = {PCH_COL_CLAY, PCH_COL_CLAY_DARK, PCH_COL_CLAY_SLEEP, PCH_COL_INK},
    [PCH_AGENT_CODEX] = {PCH_COL_CODEX, PCH_COL_CODEX_DARK, PCH_COL_CODEX_SLEEP,
                         PCH_COL_CODEX_EYE},
    [PCH_AGENT_ANTIGRAVITY] = {PCH_COL_ANTIGRAV, PCH_COL_ANTIGRAV_DARK, PCH_COL_ANTIGRAV_SLEEP,
                               PCH_COL_INK},
};

// คืน (สีตัว, สีตา, สีจอจม)
//
// สีจอถูกคืนมาเสมอแม้เอเจนต์นั้นจะไม่มีจอ — body() จะไม่ใช้มันเองถ้า has_screen เป็น false
static void skin(bool connected, pch_state_t state, pch_agent_t agent, uint16_t *body_c,
                 uint16_t *ink, uint16_t *screen_c)
{
    if (agent < 0 || agent >= PCH_AGENT_COUNT) agent = PCH_AGENT_CLAUDE;
    const palette_t *p = &PALETTES[agent];
    if (!connected) {
        // จอดับสนิท ไม่ใช่แค่เทาลง — ถ้าจอเป็น GRAY_DARK เท่ากับสีตา ตาจะหายไปทั้งดวง
        *body_c = PCH_COL_GRAY;
        *ink = PCH_COL_GRAY_DARK;
        *screen_c = PCH_COL_INK;
        return;
    }
    if (state == PCH_STATE_SLEEPING) {
        // หรี่ลงเล็กน้อยเท่านั้น — ถ้าเปลี่ยนสีแรงจะไปชนกับสัญญาณ "หลุดการเชื่อมต่อ"
        // ตัวที่มีจอได้ภาษาของตัวเองมาฟรี: ลำตัวหรี่ลงจนเกือบเท่าจอ = จอที่กำลังจะดับ
        *body_c = p->dark;
        *ink = p->eye;
        *screen_c = p->sleep;
        return;
    }
    *body_c = p->base;
    *ink = p->eye;
    *screen_c = p->sleep;
}

void pch_mascot_build(pch_rects_t *out, pch_state_t state, float phase, bool connected,
                     int cycle, pch_agent_t agent)
{
    if (state < 0 || state >= PCH_STATE_COUNT) state = PCH_STATE_IDLE;
    const mood_t *m = &MOODS[STATES[state].mood];
    const shape_t *sh = shape_of(agent);
    uint16_t body_c, ink, screen_c;
    skin(connected, state, agent, &body_c, &ink, &screen_c);

    // ปัด dy ลงตารางพิกเซลก่อน ไม่งั้นแต่ละ rect ปัดคนละทางแล้วเห็นแค่เส้นขอบกระพริบ
    // แทนที่จะเห็นทั้งตัวเลื่อนขึ้นลงพร้อมกัน
    float dy = -fabsf(sinf(phase * (float)M_PI * m->bob_hz)) * m->bob;
    // ท่าทุบเดินตาม timeline ของค้อน ไม่ใช่คลื่น: ยืดตัวตอนเงื้อ ยุบตัวตอนกระแทก
    // (ยุบด้วย squash ซึ่งยึดฝ่าเท้าไว้ ไม่ใช่ dy บวก ที่จะดันขาจมลงใต้พื้น)
    pch_ham_stage_t stage = m->strike ? pch_prop_hammer_stage(phase) : PCH_HAM_READY;
    if (m->strike && stage == PCH_HAM_WINDUP) {
        dy = -0.5f;  // เงื้อค้าง — ตัวยกลอยขึ้นทั้งตัว
    } else if (m->strike && stage == PCH_HAM_STRIKE) {
        dy = 0.0f;  // แรงลง — ตัวหยุดนิ่งที่พื้น ที่ยุบคือ squash ไม่ใช่ dy
    }
    dy = roundf(dy * PCH_SLOTS_UNIT_PX) / (float)PCH_SLOTS_UNIT_PX;
    float dx = sinf(phase * (float)M_PI * 12.0f) * m->shake;

    // ท่ามุดหาย: ยิ่ง phase เดินหน้า ยิ่งแบนลงติดพื้นและขาหด
    float squash = m->squash + m->sink * phase * 0.60f;
    if (m->strike) {
        squash += stage == PCH_HAM_WINDUP ? -0.04f : (stage == PCH_HAM_STRIKE ? 0.15f : 0.03f);
    }

    pch_rects_t silhouette;
    pch_rects_reset(&silhouette);
    // แขนพิมพ์ — แขนข้างลำตัวสลับขึ้นลงสองรอบต่อลูป ไม่มีแขนพาดหน้าแล็ปท็อป
    // (แขนที่เอื้อมมาข้างหน้าอ่านเป็น "กดจอ" ไม่ใช่ "พิมพ์อยู่หลังจอ")
    float arm = m->arm * sinf(phase * (float)M_PI * 4.0f);
    // ยกค้างนิ่ง — ถ้าขยับขึ้นลงจะอ่านเป็นโบกมือ ไม่ใช่ยกค้างเพ่งพลัง
    float arm_lift = m->arm_up;
    body(&silhouette, sh, body_c, screen_c, arm - arm_lift, -arm - arm_lift, m->arm_out);
    legs(&silhouette, sh, m->gait, phase, body_c, m->sink * phase * (FOOT_Y - sh->body_h) * 0.9f);
    squashed(&silhouette, 0, squash);
    pch_rects_move_from(&silhouette, 0, dx, dy);

    eye_t eye_kind = m->eye;
    // หลับตาเบ่งตอนแรงลง — เฟรมสั้นๆ นี้คือที่ที่น้ำหนักอยู่
    if (m->strike && stage == PCH_HAM_STRIKE) eye_kind = EYE_SQUINT;
    if (m->blink && cycle % BLINK_EVERY == BLINK_EVERY - 1 && phase >= BLINK_FROM &&
        phase < BLINK_TO) {
        eye_kind = EYE_BLINK;
    }

    pch_rects_reset(out);
    for (int i = 0; i < silhouette.count; i++) {
        pch_rect_t r = silhouette.items[i];
        pch_rects_add_round(out, r.x, r.y, r.w, r.h, r.color, r.r);
    }

    // แท่นวางอยู่กับพื้น จึงไม่เลื่อนตาม dy ที่ลำตัวขยับ
    if (STATES[state].prop == PCH_PROP_HAMMER) {
        pch_prop_hammer_anvil(out, phase, connected);
    }

    // กระจกอยู่ใต้ตา ขอบเลนส์อยู่บนตา — แต่ทั้งคู่คือของชิ้นเดียวกัน จึงห้ามยุบตามลำตัว
    // เคยยุบตาม (ตอนนั้นดูเหมือนถูก เพราะกระจกเกาะหน้ามาสคอต) แล้วท่าที่มี squash > 0
    // ดันกระจกลงราว 1.5px ในขณะที่วงแหวนอยู่ที่เดิม เห็นเป็นเนื้อลำตัวโผล่ใต้ขอบบนของวง
    if (STATES[state].prop == PCH_PROP_MAGNIFIER) {
        int glass_from = out->count;
        pch_prop_magnifier_glass(out, phase, connected);
        pch_rects_move_from(out, glass_from, dx, dy);
    }

    int eyes_from = out->count;
    float look = m->look * sinf(phase * (float)M_PI * 2.0f);
    // กวาดสายตา: ไล่จากซ้ายไปขวาแล้ววกกลับทันที = อ่านทีละบรรทัด ไม่ใช่ส่ายไปมา
    // สองบรรทัดต่อลูป — ช้ากว่านี้จะอ่านเป็นเหม่อ ไม่ใช่กำลังไล่โค้ด
    look += m->scan * (fmodf(phase * 2.0f, 1.0f) - 0.5f) * 2.0f;
    // ตาข้างที่อยู่หลังเลนส์แว่นขยายต้องโตกว่าอีกข้าง
    float mag = STATES[state].prop == PCH_PROP_MAGNIFIER ? PCH_EYE_MAG : 1.0f;
    eye(out, EYE_L, eye_kind, look, ink, 1.0f);
    eye(out, EYE_R, eye_kind, look, ink, mag);
    // แว่นวาดหลังตา กรอบจึงทับขอบตา และยุบไปกับตาชุดเดียวกัน
    // ต้องตรงกับ GLASSES_STATES ใน tools/gen/mascot.py
    if (state == PCH_STATE_WRITING) pch_prop_glasses(out, EYE_L, connected);
    // ตายุบไปกับลำตัว ไม่ใช่ค้างอยู่บนหน้าที่เตี้ยลง
    squashed(out, eyes_from, squash);
    pch_rects_move_from(out, eyes_from, dx, dy);

    if (STATES[state].prop != PCH_PROP_NONE) {
        int prop_from = out->count;
        pch_prop_build(out, STATES[state].prop, phase, connected);
        // หมวกกับค้อนอยู่ติดตัว จึงต้องต่ำลงพร้อมหัวที่ยุบ ไม่ใช่ค้างอยู่ที่เดิม
        // เลื่อนอย่างเดียวไม่ยุบตาม: หมวกแข็งและค้อนเป็นเหล็ก จะแบนไปกับตัวไม่ได้
        float prop_dy = dy + (m->strike ? FOOT_Y * squash : 0.0f);
        // ลูกโลกกับนาฬิกาลอยนิ่งอยู่กับที่ ตัวเด้งผ่านมันไป — ใหญ่และคร่อมหัวอยู่แล้ว
        // ถ้าเด้งตามตัวด้วยจะอ่านเป็นก้อนที่ติดหัว ไม่ใช่ของที่ลอยอยู่
        // ทั้งคู่ยังมีขอบล่างจ่อตาอยู่แล้ว การเด้งลงอีกจะกินตาด้วย
        if (STATES[state].prop == PCH_PROP_GLOBE || STATES[state].prop == PCH_PROP_CLOCK) {
            prop_dy = 0.0f;
        }
        pch_rects_move_from(out, prop_from, dx, prop_dy);
    }

    // ท่าที่มีของประกอบเยอะจนแน่นช่อง — ย่อทั้งฉากโดยยึดฝ่าเท้าและกึ่งกลางลำตัว
    // ย่อพร้อมกันทั้งชุด สัดส่วนภายในจึงไม่เพี้ยน
    float k = state_scale(state);
    if (k != 1.0f) pch_rects_scale_from(out, 0, k, k, PCH_HEAD_CX, FOOT_Y);
}

// --- จัดกึ่งกลาง ------------------------------------------------------------
// กรอบจริงของแต่ละสถานะ รวมทุกเฟรมของอนิเมชัน
// ท่าที่ไม่มี prop ถือจะแคบกว่าท่าที่มี ถ้าใช้กรอบรวมชุดเดียวตัวละครจะเอียงไปทางซ้าย
static float s_center_dx[PCH_STATE_COUNT];

void pch_mascot_init(void)
{
    pch_rects_t frame;
    for (int s = 0; s < PCH_STATE_COUNT; s++) {
        float x0 = 1e9f, x1 = -1e9f;
        for (int i = 0; i < 12; i++) {
            // วัดจาก Claude ตัวเดียวพอ — ทุกเอเจนต์ต้องกินพื้นที่แนวนอนเท่ากันตามข้อตกลง
            // ที่ shape_t อธิบายไว้ ตารางนี้จึงมีชุดเดียวและใช้ได้กับทุกตัว
            pch_mascot_build(&frame, (pch_state_t)s, i / 12.0f, true, 0, PCH_AGENT_CLAUDE);
            float fx0, fy0, fx1, fy1;
            pch_rects_bounds(&frame, &fx0, &fy0, &fx1, &fy1);
            if (fx0 < x0) x0 = fx0;
            if (fx1 > x1) x1 = fx1;
        }
        s_center_dx[s] = (PCH_BOX_X0 + PCH_BOX_X1) / 2.0f - (x0 + x1) / 2.0f;
    }
}

void pch_mascot_build_centered(pch_rects_t *out, pch_state_t state, float phase, bool connected,
                              int cycle, pch_agent_t agent)
{
    if (state < 0 || state >= PCH_STATE_COUNT) state = PCH_STATE_IDLE;
    pch_mascot_build(out, state, phase, connected, cycle, agent);
    pch_rects_move_from(out, 0, s_center_dx[state], 0.0f);
}

float pch_mascot_center_dx(pch_state_t state)
{
    if (state < 0 || state >= PCH_STATE_COUNT) state = PCH_STATE_IDLE;
    return s_center_dx[state];
}

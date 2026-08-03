// snapshot ที่ daemon ส่งมา — firmware ไม่เก็บสถานะเอง วาดจากก้อนนี้อย่างเดียว
//
// รูปแบบบนสาย (คีย์สั้นเพราะต้องพอดี 1 MTU):
//   {"c":"14:32","d":"Mon 27 Jul","o":0,
//    "s":[{"p":"tamaclaude","s":"building"}],
//    "n":[{"t":"tamaclaude","b":"allow Bash?","k":"alert"}],"m":0,
//    "u":[[35,10800],[48,111600]]}
#pragma once

#include <stdbool.h>

#include "layout.h"

#define CT_MAX_CARDS CT_CARD_MAX
#define CT_PROJECT_LEN 20
#define CT_TITLE_LEN 40
#define CT_BODY_LEN 52
#define CT_CLOCK_LEN 8
#define CT_DATE_LEN 16
#define CT_PLACE_LEN 20

typedef enum {
    CT_CARD_INFO = 0,
    CT_CARD_ALERT,
    CT_CARD_DONE,
} ct_card_kind_t;

// เอเจนต์เจ้าของ session — คนละแกนกับ state (ท่า) และคนละแกนกับ project (ชื่อโฟลเดอร์)
//
// Claude กับ Codex ทำงานในโฟลเดอร์เดียวกันได้ ชื่อโปรเจกต์จึงบอกไม่ได้ว่าใครเป็นใคร
// ใช้เลือกจานสีลำตัวมาสคอตเท่านั้น ไม่กระทบท่าทางหรือ prop
typedef enum {
    CT_AGENT_CLAUDE = 0,
    CT_AGENT_CODEX,
    CT_AGENT_ANTIGRAVITY,
    CT_AGENT_COUNT,
} ct_agent_t;

typedef struct {
    char project[CT_PROJECT_LEN];
    ct_state_t state;
    ct_agent_t agent;
} ct_session_t;

typedef struct {
    char title[CT_TITLE_LEN];
    char body[CT_BODY_LEN];
    ct_card_kind_t kind;
} ct_card_t;

// โควตาหนึ่งหน้าต่าง — คู่ [percent, วินาทีที่เหลือ] ที่ daemon ส่งมาใน "u"
//
// -1 แปลว่า "ไม่รู้" ไม่ใช่ศูนย์ — ศูนย์เป็นค่าจริง เปอร์เซ็นต์ที่ไม่รู้ต้องวาดเป็น "--"
// ห้ามเดาจากอะไรทั้งสิ้น
#define CT_USAGE_UNKNOWN (-1)
// สี่ช่อง เรียง 2x2: [Claude 5h, Claude weekly, Codex, สำรอง]
// ช่องที่ daemon ไม่ส่งค่ามาให้ถูกซ่อน ไม่ใช่ถูกอัดขึ้นมาแทนที่ — ตำแหน่งของแต่ละช่อง
// ต้องคงที่ ไม่งั้นแถบของ Codex จะย้ายไปนั่งที่ของ Claude ตอน Claude ยังไม่มีค่า
#define CT_USAGE_ROWS 4

typedef struct {
    int percent;
    int remaining;  // วินาที — บอร์ดนับถอยลงเอง ระหว่างที่ยังไม่มี snapshot ใหม่
} ct_usage_t;

// สภาพอากาศ — อีกแกนของท้องฟ้า คนละแกนกับ phase (เวลาของวัน)
// ต้องตรงกับ Weather.Condition ฝั่ง host ห้ามเรียงใหม่
typedef enum {
    CT_WEATHER_CLEAR = 0,
    CT_WEATHER_CLOUDY,
    CT_WEATHER_RAIN,
    CT_WEATHER_STORM,
    CT_WEATHER_FOG,
    CT_WEATHER_COUNT,
} ct_weather_t;

// อุณหภูมิที่ไม่รู้ — ติดลบได้จริง จึงใช้ค่าที่พ้นช่วงจริงไปมาก
#define CT_TEMP_UNKNOWN (-999)

typedef struct {
    char clock[CT_CLOCK_LEN];
    char date[CT_DATE_LEN];
    int overflow;
    int session_count;
    ct_session_t sessions[CT_SLOTS_COUNT];
    int card_count;
    ct_card_t cards[CT_MAX_CARDS];
    // การ์ดที่มีอยู่จริงแต่ไม่ได้ส่งมา — จอบอกเป็น "+N" ใต้ใบล่างสุด
    // การเตือนที่หายไปเงียบๆ แย่กว่าการเตือนที่อ่านไม่ครบ
    int card_overflow;
    // false = ไม่เคยได้ข้อมูลโควตาเลย -> จอถอยไปเป็นนาฬิกาตั้งโต๊ะ ไม่ใช่วาดโครงเปล่า
    bool has_usage;
    ct_usage_t usage[CT_USAGE_ROWS];
    // false = ไม่เคยได้ข้อมูลอากาศ -> ฟ้าใสตามเดิม ไม่ใช่วาดฝนเปล่าๆ
    bool has_weather;
    ct_weather_t weather;
    int temperature;
    // ชื่อสถานที่สำหรับป้ายบนแถบบน — ว่าง = daemon ไม่ได้ตั้ง บอร์ดใช้ชื่อตัวเองแทน
    char place[CT_PLACE_LEN];
    // ภาระเครื่อง Mac — คนละชนิดกับโควตา (ค่า ณ วินาทีนี้ ไม่มีเส้นตายรีเซ็ต)
    // จอจึงวาดคนละแบบ: สองบรรทัดเล็ก ไม่มี pill ไม่มีเวลานับถอยหลัง
    bool has_machine;
    int cpu_pct;
    int mem_pct;
} ct_snapshot_t;

// เดินนาฬิกาถอยหลังไป `secs` วินาที — เรียกจากลูปหลัก ไม่ใช่ตอนรับ snapshot
//
// countdown เดินบนบอร์ดเพราะเวลารีเซ็ตเป็นค่าสัมบูรณ์: BLE หลุดแล้วเวลายังจริงอยู่
// ส่วนเปอร์เซ็นต์หยุดนิ่ง (ซึ่งถูก — มันหยุดจริง) และกลายเป็น "ไม่รู้" เมื่อถึง 0
void ct_model_tick_usage(ct_snapshot_t *s, int secs);

// แปลง JSON หนึ่งก้อนเป็น snapshot — คืน false เมื่อ JSON ใช้ไม่ได้ (ของเดิมต้องไม่ถูกแตะ)
bool ct_model_parse(const char *json, int len, ct_snapshot_t *out);

// snapshot ว่าง: ไม่มี session ไม่มีการ์ด นาฬิกาเป็นขีด
void ct_model_clear(ct_snapshot_t *s);

#include "ct_led.h"

#include <math.h>

#include "driver/ledc.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "layout.h"

// ยืนยันกับบอร์ดจริงแล้ว (ESP32-2432S028R) ด้วยโหมด probe ด้านล่าง
//
// LED อยู่ *ด้านหลัง* บอร์ดและสว่างน้อยกว่าไฟหลังจอมาก จึงใช้เป็นไฟบอกสถานะ
// ที่มองจากด้านหน้าไม่ได้จริง — โค้ดนี้ยังถูกและใช้ได้ แต่ปลายทางที่ใช้งานได้จริง
// คือ LED ภายนอกที่ต่อผ่านช่อง JST (ตรรกะสถานะ->สี ด้านล่างใช้ซ้ำได้ทั้งชุด)
// โหมดหาขา — ตั้งเป็น 1 เมื่อต้องพิสูจน์ว่าไฟไม่ติดเพราะขาผิดหรือเพราะตรรกะ
// วนสีค้างไปเรื่อยๆ โดยไม่สนใจสถานะใดๆ จึงไม่มีหน้าต่างเวลาให้พลาด
#define CT_LED_PIN_PROBE 0

#define PIN_R 4
#define PIN_G 16
#define PIN_B 17

#define LED_TIMER LEDC_TIMER_0
#define LED_MODE LEDC_LOW_SPEED_MODE
#define LED_MAX 255

// เพดานความสว่างของทุกสถานะ — LED บนบอร์ดสว่างเกินกว่าจะอยู่ในสายตาได้ทั้งวัน
// ถ้าเปิดเต็ม นี่คือไฟที่นั่งอยู่ข้างคีย์บอร์ด ไม่ใช่ไฟฉาย
#define LED_CEIL 90
// พื้นของการหายใจ — ไม่ลงถึงศูนย์ เพราะ "หายใจ" กับ "กะพริบ" ต่างกันตรงนี้พอดี
#define LED_FLOOR 12

typedef struct {
    uint8_t r, g, b;
} rgb_t;

typedef enum {
    MODE_OFF = 0,
    MODE_STEADY,   // นิ่ง
    MODE_BREATHE,  // หายใจช้า — กำลังทำงาน อยู่ร่วมกับคนได้
    MODE_PULSE,    // เต้นเร็ว — ต้องการสายตา
} led_mode_t;

static led_mode_t s_mode = MODE_OFF;
static rgb_t s_color;
static float s_phase;     // 0..1 ในหนึ่งรอบ
static float s_period_s;  // ความยาวหนึ่งรอบ

// สีลำตัวมาสคอตของแต่ละเอเจนต์ในหน่วย RGB 8 บิต — ไฟกับจอต้องพูดภาษาเดียวกัน
// เห็นไฟฟ้าแล้วต้องรู้ว่า Codex โดยไม่ต้องหันไปดูจอ (ตรงกับ [palette] ใน layout.toml)
static const rgb_t AGENT_RGB[CT_AGENT_COUNT] = {
    [CT_AGENT_CLAUDE] = {217, 119, 87},        // #D97757
    [CT_AGENT_CODEX] = {79, 168, 199},         // #4FA8C7
    [CT_AGENT_ANTIGRAVITY] = {139, 127, 217},  // #8B7FD9
};

// สถานะที่ไม่ได้เป็นของเอเจนต์ใดเอเจนต์หนึ่ง — ใช้สีของความหมาย ไม่ใช่ของเจ้าของ
static const rgb_t RGB_WAITING = {230, 150, 30};  // อำพัน = "ตาอยู่ที่คุณ"
static const rgb_t RGB_ERROR = {217, 86, 79};
static const rgb_t RGB_DONE = {95, 168, 95};

static void write_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    // active low: duty สูง = หรี่ จึงกลับค่าก่อนเขียน
    const uint8_t v[3] = {r, g, b};
    for (int i = 0; i < 3; i++) {
        ledc_channel_t ch = (ledc_channel_t)(LEDC_CHANNEL_0 + i);
        ledc_set_duty(LED_MODE, ch, LED_MAX - v[i]);
        ledc_update_duty(LED_MODE, ch);
    }
}

#if CT_LED_PIN_PROBE
static void led_probe_task(void *arg)
{
    (void)arg;
    const char *names[4] = {"R only", "G only", "B only", "all three"};
    const uint8_t vals[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}};
    for (int i = 0;; i = (i + 1) % 4) {
        ESP_LOGW("led", "probe: %s", names[i]);
        write_rgb(vals[i][0], vals[i][1], vals[i][2]);
        vTaskDelay(pdMS_TO_TICKS(3000));
    }
}
#endif

void ct_led_init(void)
{
    ledc_timer_config_t timer = {
        .speed_mode = LED_MODE,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .timer_num = LED_TIMER,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&timer);

    const int pins[3] = {PIN_R, PIN_G, PIN_B};
    for (int i = 0; i < 3; i++) {
        ledc_channel_config_t ch = {
            .gpio_num = pins[i],
            .speed_mode = LED_MODE,
            .channel = (ledc_channel_t)(LEDC_CHANNEL_0 + i),
            .timer_sel = LED_TIMER,
            .duty = LED_MAX,  // active low -> ดับ
            .hpoint = 0,
        };
        ledc_channel_config(&ch);
    }
    write_rgb(0, 0, 0);

    // โหมดหาขา: วนสีทีละดวงค้างไปเรื่อยๆ จนกว่าจะปิด
    // ขาของ LED ไม่เคยถูกตรวจสอบ (DESIGN.md เขียนว่า "ยังไม่ได้ตรวจ") การจะรู้ว่า
    // "ไฟไม่ติด" เป็นเรื่องขาหรือเรื่องตรรกะ ต้องมีสัญญาณที่ไม่ขึ้นกับสถานะและ
    // ไม่มีหน้าต่างเวลาให้พลาด
#if CT_LED_PIN_PROBE
    xTaskCreate(led_probe_task, "led_probe", 2048, NULL, 1, NULL);
    return;
#endif
    write_rgb(0, 0, 0);
}

// สถานะที่ "ดังที่สุด" ในบรรดา session ทั้งหมดชนะ — ไฟมีดวงเดียวจึงต้องเลือก ไม่ใช่ผสม
// การผสมสีของสามสถานะได้สีที่ไม่ได้แปลว่าอะไรเลย
//
// ลำดับตรงกับ VisualState.priority ฝั่ง host โดยตั้งใจ: จอกับไฟต้องไม่ขัดกัน
static int state_rank(ct_state_t s)
{
    switch (s) {
        case CT_STATE_ERROR: return 40;
        case CT_STATE_WAITING: return 30;
        case CT_STATE_CELEBRATE: return 15;
        case CT_STATE_IDLE: return 5;
        case CT_STATE_SLEEPING: return 0;
        default: return 20;  // กำลังทำงาน (reading/writing/building/...)
    }
}

void ct_led_apply(const ct_snapshot_t *snap, bool connected)
{
    int best = -1, best_rank = -1;
    if (connected) {
        for (int i = 0; i < snap->session_count; i++) {
            int rank = state_rank(snap->sessions[i].state);
            if (rank > best_rank) {
                best_rank = rank;
                best = i;
            }
        }
    }
    if (best < 0) {
        s_mode = MODE_OFF;
        write_rgb(0, 0, 0);
        return;
    }

    const ct_session_t *win = &snap->sessions[best];
    ct_agent_t agent = win->agent;
    if (agent < 0 || agent >= CT_AGENT_COUNT) agent = CT_AGENT_CLAUDE;

    led_mode_t mode;
    rgb_t color;
    float period;
    switch (win->state) {
        case CT_STATE_ERROR:
            // เร็วและแดง — อย่างเดียวที่ควรทำให้คนหันมาทันที
            mode = MODE_PULSE, color = RGB_ERROR, period = 0.7f;
            break;
        case CT_STATE_WAITING:
            // เหตุผลหลักที่ไฟดวงนี้มีอยู่: บอกว่ามีคนรอเราตอบ
            mode = MODE_PULSE, color = RGB_WAITING, period = 1.4f;
            break;
        case CT_STATE_CELEBRATE:
            mode = MODE_STEADY, color = RGB_DONE, period = 1.0f;
            break;
        case CT_STATE_IDLE:
        case CT_STATE_SLEEPING:
            // ว่างแล้วดับ ไม่ใช่หรี่ — ไฟที่ติดตลอดเวลาเลิกเป็นสัญญาณ
            // กลายเป็นเฟอร์นิเจอร์ แล้วตอนที่มันสำคัญจริงก็ไม่มีใครเห็น
            mode = MODE_OFF, color = (rgb_t){0, 0, 0}, period = 1.0f;
            break;
        default:
            // กำลังทำงาน: สีของเอเจนต์ หายใจช้าพอที่จะไม่ดึงสายตา
            mode = MODE_BREATHE, color = AGENT_RGB[agent], period = 3.2f;
            break;
    }

    // เปลี่ยนสถานะ = เริ่มรอบใหม่ ไม่ให้กระโดดกลางจังหวะหายใจ
    if (mode != s_mode || color.r != s_color.r || color.g != s_color.g
        || color.b != s_color.b) {
        s_phase = 0.0f;
    }
    s_mode = mode;
    s_color = color;
    s_period_s = period;
    if (mode == MODE_OFF) write_rgb(0, 0, 0);
}

void ct_led_tick(int elapsed_ms)
{
    if (s_mode == MODE_OFF) return;

    float level;  // 0..1
    if (s_mode == MODE_STEADY) {
        level = 1.0f;
    } else {
        s_phase += (float)elapsed_ms / 1000.0f / s_period_s;
        s_phase -= floorf(s_phase);
        // โคไซน์ ไม่ใช่สามเหลี่ยม — สายตาจับ "หัวมุม" ของสามเหลี่ยมได้ แล้วมันอ่านเป็น
        // การกะพริบช้าๆ แทนที่จะเป็นการหายใจ
        float wave = 0.5f - 0.5f * cosf(s_phase * 2.0f * (float)M_PI);
        float floor_frac = (float)LED_FLOOR / (float)LED_CEIL;
        level = floor_frac + (1.0f - floor_frac) * wave;
    }

    float k = level * (float)LED_CEIL / 255.0f;
    write_rgb((uint8_t)(s_color.r * k), (uint8_t)(s_color.g * k), (uint8_t)(s_color.b * k));
}

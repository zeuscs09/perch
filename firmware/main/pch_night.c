#include "pch_night.h"

#include <stdio.h>

// ช่วงกลางคืน — เริ่มสามทุ่ม จบเจ็ดโมงเช้า
//
// คร่อมเที่ยงคืน การเทียบจึงเป็น "หรือ" ไม่ใช่ "และ" ซึ่งเป็นจุดที่พลาดกันบ่อย
#define NIGHT_FROM_H 21
#define NIGHT_TO_H 7

// แตะแล้วได้จอปกตินานเท่านี้
//
// สั้นกว่านี้อ่านไม่ทันว่ามีอะไรค้างบ้าง ยาวกว่านี้แล้วการเผลอไปโดนตอนกลางดึกจะทำให้
// จอสว่างค้างนานเกินกว่าที่การเผลอครั้งเดียวควรได้
#define WAKE_MS 15000

static int s_hour = -1;  // ยังไม่เคยรู้เวลา
static int s_wake_ms = 0;

void pch_night_set_clock(const char *hhmm)
{
    // "HH:MM" — ที่มาเดียวของเวลาบนบอร์ดนี้ ผิดรูปแบบแปลว่าไม่รู้ ไม่ใช่เที่ยงคืน
    if (!hhmm) return;
    int h = 0, m = 0;
    if (sscanf(hhmm, "%d:%d", &h, &m) != 2) return;
    if (h < 0 || h > 23) return;
    s_hour = h;
}

void pch_night_wake(void) { s_wake_ms = WAKE_MS; }

void pch_night_tick(int elapsed_ms)
{
    if (s_wake_ms <= 0) return;
    s_wake_ms -= elapsed_ms;
    if (s_wake_ms < 0) s_wake_ms = 0;
}

bool pch_night_active(void)
{
    // ยังไม่เคยได้เวลา = ไม่เข้าโหมด จอมืดตั้งแต่บูตโดยที่ยังไม่รู้ว่ากี่โมง
    // แยกไม่ออกจากบอร์ดที่ต่อไม่ติด
    if (s_hour < 0) return false;
    if (s_wake_ms > 0) return false;
    return s_hour >= NIGHT_FROM_H || s_hour < NIGHT_TO_H;
}

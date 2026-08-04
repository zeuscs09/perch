// มาสคอต Claude — พอร์ตจาก tools/gen/mascot.py
//
// สองมิติที่แยกจากกัน: mood (ตา/ลำตัว/ขา = รู้สึกยังไง) กับ prop (ถืออะไร = ทำอะไรอยู่)
#pragma once

#include "pch_rects.h"
#include "layout.h"

// ต้องเรียกครั้งเดียวตอนบูต — คำนวณกรอบของแต่ละสถานะไว้ใช้จัดกึ่งกลาง
void pch_mascot_init(void);

// สร้าง rect list ของมาสคอตหนึ่งตัว เรียงจากหลังไปหน้า
//   phase  ความคืบหน้าในลูปอนิเมชัน 0..1 (ลูปหนึ่งราว 1 วินาที)
//   cycle  ลูปที่เท่าไรแล้ว — ใช้กับจังหวะที่ช้ากว่าหนึ่งลูป เช่นการกะพริบตา
// พิกัดอยู่ในตาราง 16.5 x 12 unit ฝ่าเท้าอยู่ที่ y = 12
void pch_mascot_build(pch_rects_t *out, pch_state_t state, float phase, bool connected,
                     int cycle);

// เหมือน build แต่เลื่อนแนวนอนให้กรอบของสถานะนั้นอยู่กึ่งกลางกรอบวาดมาตรฐาน
// ระดับฝ่าเท้าไม่ขยับ — จัดกึ่งกลางเฉพาะแกน x
void pch_mascot_build_centered(pch_rects_t *out, pch_state_t state, float phase, bool connected,
                              int cycle);

// ระยะที่ build_centered เลื่อนสถานะนั้นไป (unit) — ต้องเรียกหลัง pch_mascot_init
//
// เงาใต้เท้าต้องเกาะกึ่งกลาง *ลำตัว* ไม่ใช่กึ่งกลาง slot: build_centered จัดกึ่งกลาง
// กรอบที่รวม prop ด้วย ท่าที่ถือของชิ้นใหญ่จึงมีลำตัวเยื้องออกจากกึ่งกลาง slot
float pch_mascot_center_dx(pch_state_t state);

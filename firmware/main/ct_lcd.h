// จอ ILI9341 บน SPI2 + ไฟหลังแบบหรี่ได้
//
// ค่าคอนฟิกทั้งหมดมาจากการวัดบอร์ดจริงด้วย firmware/probe (ดู DESIGN.md)
// ไม่ได้มาจากเลขรุ่นชิป เพราะจอตัวนี้ล็อกการอ่าน ID ไว้
#pragma once

#include <stdint.h>
#include <stddef.h>

// LEDC ที่ไฟหลังจองไว้ — โมดูลอื่นที่ใช้ LEDC ต้องเลี่ยงสองตัวนี้
//
// ประกาศไว้ตรงนี้เพราะการชนกันของ LEDC ไม่ส่งเสียงร้อง: `ledc_channel_config` ตัวหลัง
// แค่ re-route ช่องไปขาใหม่โดยไม่ถอนขาเดิม ทั้งสองขาจึงวิ่งตามค่า duty เดียวกันเงียบๆ
// และ `ledc_timer_config` ตัวหลังเปลี่ยนความละเอียดของ timer ใต้เท้าคนที่จองไว้ก่อน
// เคยเกิดจริง: ไฟ RGB จองทับ แล้วความสว่างจอไปผูกกับดวงแดงของมาสคอต
//
// เป็นตัวเลขล้วนเพื่อให้ `_Static_assert` ในไฟล์อื่นตรวจได้โดยไม่ต้องดึง driver/ledc.h
#define CT_LCD_BL_TIMER_NUM 0
#define CT_LCD_BL_CHANNEL_NUM 0

void ct_lcd_init(void);

// ส่งพิกเซลลงจอ พิกัดรวมปลายทั้งสองข้าง ข้อมูลเป็น RGB565 เรียงไบต์แบบ big-endian
void ct_lcd_blit(int x1, int y1, int x2, int y2, const void *pixels, size_t bytes);

// ความสว่าง 0..100 — 15% คือค่าที่ใช้ตอนจอว่าง (DESIGN.md)
void ct_lcd_set_backlight(int percent);
int ct_lcd_backlight(void);

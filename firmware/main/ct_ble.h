// GATT peripheral — daemon ฝั่ง Mac เป็น central
//
// UUID ต้องตรงกับ host/Sources/PerchCore/BLETransport.swift ทุกตัว
//   service  7A9B0001-4C1E-4B6D-9E2A-1D5C3F0A0001
//   state    ...0002  daemon เขียน snapshot ลงตัวนี้
//   config   ...0003  ความสว่าง + คำสั่ง WiFi — **บังคับเข้ารหัส** เพราะรหัส WiFi
//                     เดินผ่านตัวนี้ (ตัวอื่นไม่บังคับ ไม่งั้นจอค้างตอน bond หาย)
//   event    ...0004  บอร์ดแจ้งกลับ — ผลสแกน WiFi และสถานะการต่อ
#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    // ทั้งสามตัวถูกเรียกจาก NimBLE host task ห้ามแตะ LVGL ตรงนั้น
    void (*on_state)(const char *json, int len);
    void (*on_config)(const char *json, int len);
    void (*on_link)(bool connected);
} ct_ble_cbs_t;

void ct_ble_init(const ct_ble_cbs_t *cbs);

// ส่ง JSON หนึ่งบรรทัดออก event characteristic — เงียบเมื่อยังไม่มีใครสมัครรับ
// เรียกจากเธรดไหนก็ได้ (NimBLE ล็อกเอง) แต่ข้อความต้องพอดี MTU เดียว ไม่มีการต่อชิ้น
void ct_ble_notify(const char *json, int len);

// ชื่อที่บอร์ดโฆษณา (`perch-ab12`) — mDNS ใช้ชื่อเดียวกันนี้ ไม่ใช่ชื่อของตัวเอง
// เพราะผู้ใช้ที่มีสองบอร์ดต้องแยกออกด้วยชื่อชุดเดียว ไม่ใช่สองชุดที่ไม่เกี่ยวกัน
// ก่อน `ct_ble_init` จะซิงก์เสร็จจะได้ชื่อสั้นที่ยังไม่มีเลข MAC ต่อท้าย
const char *ct_ble_name(void);

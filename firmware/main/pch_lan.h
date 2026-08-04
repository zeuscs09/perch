// ทางเดินที่สองของ snapshot — TCP บน LAN เมื่อ BLE ไกลเกินไป (DESIGN.md "WiFi")
//
// ปลายทางคือ Mac เครื่องเดิม ไม่ใช่ claude.ai: บอร์ดไม่เคยถือ `sessionKey` เลย
// สิ่งที่วิ่งบนสายนี้คือ snapshot ก้อนเดียวกับที่เคยวิ่งบน BLE ไม่มีอะไรมากกว่านั้น
//
// LAN ไม่มีการเข้ารหัสของตัวเองแบบ BLE — WPA2 ป้องกันแค่ช่วงอากาศ ส่วนคนอื่นบนวงเดียวกัน
// อ่านได้หมด ทุกเฟรมจึงถูกปิดผนึกด้วย AES-256-GCM ด้วยกุญแจที่ Mac ส่งมาทาง config
// characteristic (ซึ่งบังคับ BLE encryption อยู่แล้ว) และมีตัวนับกันเล่นซ้ำ
//
//   [4B len BE][12B nonce][ciphertext][16B tag]
//
// len คือจำนวนไบต์ที่ตามหลังมัน · nonce = ศูนย์ 4 ไบต์ + ตัวนับ 8 ไบต์ BE ·
// ตัวนับต้องมากกว่าตัวที่รับไปแล้วเสมอ ไม่งั้นทิ้งทั้งเฟรมและตัดสาย
#pragma once

#include <stdbool.h>
#include <stdint.h>

#define PCH_LAN_PORT 7333
#define PCH_LAN_KEY_BYTES 32

// snapshot ก้อนเดียวจบเหมือนบน BLE — ไม่มีการต่อชิ้น
typedef void (*pch_lan_frame_cb_t)(const char *json, int len);

// ต้องเรียกหลัง nvs_flash_init และหลัง esp_netif_init
void pch_lan_init(pch_lan_frame_cb_t on_frame);

// ตั้งกุญแจใหม่จาก hex 64 ตัว — ตัวนับกันเล่นซ้ำถูกล้างพร้อมกันเสมอ เพราะกุญแจใหม่
// แปลว่า nonce ชุดเดิมใช้ซ้ำได้แล้วโดยไม่เป็นอันตราย คืน false เมื่อ hex ไม่ถูกต้อง
bool pch_lan_set_key(const char *hex);

// 8 hex ตัวแรกของ SHA-256(key) — Mac เอาไปเทียบว่าสองฝั่งถือกุญแจเดียวกันไหม
// สตริงว่างเมื่อยังไม่เคยตั้ง · ไม่ใช่ความลับ: มันคือแฮชของกุญแจ ไม่ใช่กุญแจ
const char *pch_lan_key_fingerprint(void);

// เปิด/ปิด server ตาม IP ที่ได้จาก DHCP — mDNS ถูกประกาศตอนขึ้นด้วย
void pch_lan_set_up(bool up, const char *ip);

// มี Mac ต่ออยู่จริงไหม — ต่างจาก "WiFi ติด" ตรงที่อันนี้แปลว่า snapshot ยังไหลอยู่
bool pch_lan_client_connected(void);

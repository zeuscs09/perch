// วัดว่า outbound TCP ที่ค้างไว้กิน heap เท่าไร — งานข้อแรกของ issue #1
//
// ทำไมต้องวัดบนเฟิร์มแวร์เต็ม ไม่ใช่ build เปล่า: คำถามไม่ใช่ "ซ็อกเก็ตกินเท่าไร" แต่คือ
// "ยังเหลือให้ซ็อกเก็ตไหม *หลังจาก* BLE + LVGL + WiFi + LAN listener + mDNS กินไปแล้ว"
// build เปล่าจะตอบว่าเหลือเยอะซึ่งไม่มีความหมาย
//
// ยิงไปที่พอร์ต 22 ของเครื่องอะไรก็ได้ที่มี SSH — มันตอบ banner แล้วค้างสายไว้ราวสองนาที
// นานพอให้ heap นิ่งพอจะวัด และไม่ต้องไปตั้งอะไรบนเซิร์ฟเวอร์เลย
#include <stdbool.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/netdb.h"
#include "lwip/sockets.h"

static const char *TAG = "relaytest";

// ไม่ฝังที่อยู่จริงไว้ในซอร์ส — ที่อยู่เซิร์ฟเวอร์ของใครสักคนไม่ควรอยู่ใน repo สาธารณะ
//   idf.py -DPCH_RELAYTEST=1 -DPCH_RELAYTEST_IP=\"1.2.3.4\" build
#ifndef PCH_RELAYTEST_IP
#define PCH_RELAYTEST_IP "192.0.2.1"   // TEST-NET-1 — ต่อไม่ติดโดยตั้งใจ ถ้าลืมส่งค่าจะรู้ทันที
#endif
#define RELAY_IP PCH_RELAYTEST_IP
#define RELAY_PORT 22

static void report(const char *when)
{
    // largest free block ต่างหากที่ทำให้ malloc ล้ม ไม่ใช่ยอดรวม — heap ที่แตกเป็นเสี่ยง
    // มีที่ว่างรวมเยอะแต่ขอก้อนต่อเนื่อง 5KB ไม่ได้ ยอดรวมอย่างเดียวจึงหลอกตา
    ESP_LOGI(TAG, "%-16s free %6u  min %6u  largest %6u", when,
             (unsigned)esp_get_free_heap_size(),
             (unsigned)esp_get_minimum_free_heap_size(),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
}

static void task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(35000));      // รอ WiFi เกาะและ LAN listener ขึ้นให้ครบก่อน
    report("ก่อนต่อ");

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port = htons(RELAY_PORT),
    };
    dst.sin_addr.s_addr = inet_addr(RELAY_IP);

    int s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s < 0) {
        ESP_LOGE(TAG, "socket() ล้มเหลว errno %d", errno);
        vTaskDelete(NULL);
    }
    report("มีซ็อกเก็ต");

    if (connect(s, (struct sockaddr *)&dst, sizeof(dst)) != 0) {
        ESP_LOGE(TAG, "connect() ล้มเหลว errno %d", errno);
        close(s);
        vTaskDelete(NULL);
    }
    ESP_LOGI(TAG, "ต่อ %s:%d สำเร็จ", RELAY_IP, RELAY_PORT);
    report("ต่อแล้ว");

    // อ่าน banner ของ SSH — ทำให้ pbuf ฝั่งรับถูกจัดสรรจริง ไม่ใช่แค่เปิดสายเปล่า
    char buf[128];
    int n = recv(s, buf, sizeof(buf) - 1, 0);
    if (n > 0) {
        buf[n] = 0;
        for (int i = 0; i < n; i++) if (buf[i] < 32) buf[i] = ' ';
        ESP_LOGI(TAG, "ได้ข้อมูลกลับ %d ไบต์: %.40s", n, buf);
    }
    report("รับข้อมูลแล้ว");

    for (int i = 1; i <= 6; i++) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        char label[48];   // ไทยเป็น UTF-8 กินไบต์กว่าที่ตาเห็น 24 ไม่พอและ -Werror จับได้
        snprintf(label, sizeof(label), "ค้างไว้ %ds", i * 10);
        report(label);
    }
    close(s);
    vTaskDelay(pdMS_TO_TICKS(2000));
    report("ปิดแล้ว");
    vTaskDelete(NULL);
}

void pch_relaytest_start(void)
{
    xTaskCreate(task, "relaytest", 4096, NULL, 4, NULL);
}

idf_component_register(
    SRCS
        "main.c"
        "pch_lcd.c"
        "pch_rects.c"
        "pch_props.c"
        "pch_mascot.c"
        "pch_model.c"
        "pch_agent.c"
        "pch_ui.c"
        "pch_ble.c"
        "pch_wifi.c"
        "pch_lan.c"
        "pch_led.c"
        "pch_touch.c"
        "pch_dim.c"
        "pch_night.c"
        "pch_face.c"
        "pch_relaytest.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_timer nvs_flash bt json esp_wifi esp_netif esp_event
             lwip mbedtls espressif__mdns
)

# โหมดทดลองใบหน้า — `idf.py -DPCH_FACE=1 build`
# ต้องส่งต่อเป็น compile definition เอง: -D ของ idf.py ตั้งตัวแปร CMake ไม่ใช่ #define ของ C
if(PCH_FACE)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PCH_FACE=1)
    message(STATUS "PCH_FACE=1 — บิลด์โหมดใบหน้า ไม่ใช่ perch ปกติ")
endif()

if(PCH_RELAYTEST)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PCH_RELAYTEST=1)
endif()

if(PCH_RELAY_BOOTSTRAP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PCH_RELAY_BOOTSTRAP=1)
    if(PCH_RELAY_HOST)
        target_compile_definitions(${COMPONENT_LIB} PRIVATE PCH_RELAY_HOST="${PCH_RELAY_HOST}")
    endif()
    if(PCH_RELAY_PORT)
        target_compile_definitions(${COMPONENT_LIB} PRIVATE PCH_RELAY_PORT=${PCH_RELAY_PORT})
    endif()
endif()
if(PCH_RELAYTEST_IP)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PCH_RELAYTEST_IP="${PCH_RELAYTEST_IP}")
endif()

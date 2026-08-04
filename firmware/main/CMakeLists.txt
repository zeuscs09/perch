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
    INCLUDE_DIRS "."
    REQUIRES driver esp_timer nvs_flash bt json esp_wifi esp_netif esp_event
             lwip mbedtls espressif__mdns
)

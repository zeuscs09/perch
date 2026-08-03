idf_component_register(
    SRCS
        "main.c"
        "ct_lcd.c"
        "ct_rects.c"
        "ct_props.c"
        "ct_mascot.c"
        "ct_model.c"
        "ct_agent.c"
        "ct_ui.c"
        "ct_ble.c"
        "ct_wifi.c"
        "ct_lan.c"
        "ct_led.c"
        "ct_touch.c"
        "ct_dim.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_timer nvs_flash bt json esp_wifi esp_netif esp_event
             lwip mbedtls espressif__mdns
)

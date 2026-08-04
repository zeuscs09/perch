// สร้างอัตโนมัติจาก tools/layout.toml — ห้ามแก้ไฟล์นี้ด้วยมือ
// แก้ที่ layout.toml แล้วรัน: python3 tools/export_layout.py
#pragma once

#include <stdint.h>

#define PCH_SCREEN_WIDTH             320
#define PCH_SCREEN_HEIGHT            240

#define PCH_TOPBAR_HEIGHT            22
#define PCH_TOPBAR_LINK_ICON_W       11
#define PCH_TOPBAR_LINK_ICON_H       9
#define PCH_TOPBAR_LINK_ICON_GAP     6

#define PCH_SLOTS_COUNT              3
#define PCH_SLOTS_WIDTH              106
#define PCH_SLOTS_TOP                49
#define PCH_SLOTS_HEIGHT             90
#define PCH_SLOTS_UNIT_PX            4
#define PCH_SLOTS_BASELINE_PAD       19

#define PCH_CARD_TOP                 142
#define PCH_CARD_HEIGHT              98
#define PCH_CARD_PAD                 6
#define PCH_CARD_MAX                 2

#define PCH_USAGE_ROW_H              40
#define PCH_USAGE_GAP                4
#define PCH_USAGE_BAR_H              7
#define PCH_USAGE_COLS               2
#define PCH_USAGE_GUTTER             14
#define PCH_USAGE_ROWS               4
#define PCH_USAGE_SESSION_WINDOW     18000
#define PCH_USAGE_WEEKLY_WINDOW      604800
#define PCH_USAGE_WARN_PCT           60
#define PCH_USAGE_CRIT_PCT           85

#define PCH_WEATHER_DROPS            26
#define PCH_WEATHER_DROP_LEN         7
#define PCH_WEATHER_DROP_SLANT       2
#define PCH_WEATHER_DROP_SPEED_PX_S  150
#define PCH_WEATHER_OVERCAST_CLOUDS  7
#define PCH_WEATHER_FLASH_EVERY_S    9.0f
#define PCH_WEATHER_FLASH_HOLD_S     0.12f

#define PCH_STROLL_SPEED_PX_S        34
#define PCH_STROLL_PAUSE_S           2.5f
#define PCH_STROLL_PAD_PX            96

#define PCH_SKY_HORIZON              120
#define PCH_SKY_DAWN_HOUR            5
#define PCH_SKY_DAY_HOUR             7
#define PCH_SKY_DUSK_HOUR            17
#define PCH_SKY_NIGHT_HOUR           19
#define PCH_SKY_DISC_R               7
#define PCH_SKY_ARC_PEAK             82
#define PCH_SKY_ARC_PAD              0
#define PCH_SKY_TWINKLE_N            4
#define PCH_SKY_STAR_PX              1
#define PCH_SKY_STAR_PEAK_PX         3
#define PCH_SKY_LOW_STAR_N           6
#define PCH_SKY_CLOUD_SPEED_PX_S     4
#define PCH_SKY_CLOUD_PAD            60

#define PCH_SKY_STARS_COUNT          16
static const int16_t pch_sky_stars[PCH_SKY_STARS_COUNT][2] = {
    { 33,  63},
    {128,  67},
    {205,  88},
    {289,  48},
    { 76,  27},
    {247,  71},
    { 14,  33},
    { 58,  82},
    {103,  44},
    {171,  90},
    { 92,  99},
    {149,  37},
    {186,  52},
    {229,  30},
    {268, 101},
    {307,  80},
};

#define PCH_SKY_CLOUDS_COUNT         3
static const int16_t pch_sky_clouds[PCH_SKY_CLOUDS_COUNT][3] = {
    { 40,  44,  44},
    {150,  74,  36},
    {250,  32,  52},
};

#define PCH_SKY_GRASS_X_COUNT        24
static const int16_t pch_sky_grass_x[PCH_SKY_GRASS_X_COUNT] = {
      4,  13,  35,  41,  55,  62,  88,  99, 104, 123, 131, 155,
    168, 174, 191, 200, 228, 235, 247, 268, 273, 288, 298, 310,
};

#define PCH_MASCOT_GRID_W            16.5f
#define PCH_MASCOT_GRID_H            12
#define PCH_MASCOT_CORNER            0.25f

// กรอบวาดมาสคอตรวม prop (หน่วย unit) — มาจาก tools/gen/props.py
#define PCH_BOX_X0                    -0.5f
#define PCH_BOX_X1                    23.4f
#define PCH_BOX_Y0                    -5.6f
#define PCH_BOX_Y1                    12.0f

// จานสีเป็น RGB565 ตามที่แผงจอกินจริง
#define PCH_COL_BG                    0x1081
#define PCH_COL_BG_SLOT               0x18A2
#define PCH_COL_CLAY                  0xDBAA
#define PCH_COL_CLAY_DARK             0xAAA7
#define PCH_COL_CLAY_SLEEP            0x7A26
#define PCH_COL_GRAY                  0x5AEB
#define PCH_COL_GRAY_DARK             0x39E7
#define PCH_COL_INK                   0x10A1
#define PCH_COL_OUTLINE               0xFFFF
#define PCH_COL_TEXT                  0xEF1B
#define PCH_COL_TEXT_DIM              0x8C0F
#define PCH_COL_ACCENT                0xEDC9
#define PCH_COL_ACCENT_WARM           0xDCA4
#define PCH_COL_GLASS                 0xAEDD
#define PCH_COL_STEEL                 0x53B1
#define PCH_COL_ALERT                 0xDAA9
#define PCH_COL_GOOD                  0x5D4B
#define PCH_COL_SKY_OVERCAST          0x6BD0
#define PCH_COL_SKY_STORM             0x3A29
#define PCH_COL_RAIN                  0x9E3B
#define PCH_COL_LIGHTNING             0xFFBB
#define PCH_COL_FOG                   0x9D15
#define PCH_COL_CODEX                 0x4D58
#define PCH_COL_CODEX_DARK            0x33B1
#define PCH_COL_CODEX_SLEEP           0x2A6B
#define PCH_COL_CODEX_EYE             0xAF5E
#define PCH_COL_ANTIGRAV              0x8BFB
#define PCH_COL_ANTIGRAV_DARK         0x62B5
#define PCH_COL_ANTIGRAV_SLEEP        0x41CD
#define PCH_COL_SKY_NIGHT             0x0863
#define PCH_COL_SKY_DAWN              0x3A4F
#define PCH_COL_SKY_DAY               0xBEFE
#define PCH_COL_SKY_DUSK              0x696F
#define PCH_COL_GROUND_NIGHT          0x10C3
#define PCH_COL_GROUND_DAWN           0x1926
#define PCH_COL_GROUND_DAY            0x29C5
#define PCH_COL_GROUND_DUSK           0x20C5
#define PCH_COL_SUN                   0xF525
#define PCH_COL_SUN_LOW               0xEC09
#define PCH_COL_MOON                  0xCE7B
#define PCH_COL_STAR                  0xEF1B
#define PCH_COL_STAR_MID              0xA577
#define PCH_COL_STAR_DIM              0x6BD1
#define PCH_COL_CLOUD_DAY             0xF7DF
#define PCH_COL_CLOUD_DAWN            0x5B73
#define PCH_COL_CLOUD_DUSK            0xC352
#define PCH_COL_GRASS_NIGHT           0x2A07
#define PCH_COL_GRASS_DAWN            0x3287
#define PCH_COL_GRASS_DAY             0x6D4B
#define PCH_COL_GRASS_DUSK            0x5A87
#define PCH_COL_SHADOW_NIGHT          0x0862
#define PCH_COL_SHADOW_DAWN           0x10A3
#define PCH_COL_SHADOW_DAY            0x1923
#define PCH_COL_SHADOW_DUSK           0x1884

// visual state — daemon ส่งค่าพวกนี้มาบน BLE ห้ามเรียงใหม่
typedef enum {
    PCH_STATE_IDLE         = 0,
    PCH_STATE_READING      = 1,
    PCH_STATE_WRITING      = 2,
    PCH_STATE_BUILDING     = 3,
    PCH_STATE_SEARCHING    = 4,
    PCH_STATE_THINKING     = 5,
    PCH_STATE_WAITING      = 6,
    PCH_STATE_SLEEPING     = 7,
    PCH_STATE_ALERT        = 8,
    PCH_STATE_CELEBRATE    = 9,
    PCH_STATE_ERROR        = 10,
    PCH_STATE_ENTERING     = 11,
    PCH_STATE_LEAVING      = 12,
    PCH_STATE_CONDUCTING   = 13,
    PCH_STATE_BEACON       = 14,
    PCH_STATE_COUNT             = 15,
} pch_state_t;

static const char *const pch_state_names[PCH_STATE_COUNT] = {
    "idle",
    "reading",
    "writing",
    "building",
    "searching",
    "thinking",
    "waiting",
    "sleeping",
    "alert",
    "celebrate",
    "error",
    "entering",
    "leaving",
    "conducting",
    "beacon",
};

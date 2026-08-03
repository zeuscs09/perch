// สร้างอัตโนมัติจาก tools/layout.toml — ห้ามแก้ไฟล์นี้ด้วยมือ
// แก้ที่ layout.toml แล้วรัน: python3 tools/export_layout.py
#pragma once

#include <stdint.h>

#define CT_SCREEN_WIDTH              320
#define CT_SCREEN_HEIGHT             240

#define CT_TOPBAR_HEIGHT             22
#define CT_TOPBAR_LINK_ICON_W        11
#define CT_TOPBAR_LINK_ICON_H        9
#define CT_TOPBAR_LINK_ICON_GAP      6

#define CT_SLOTS_COUNT               3
#define CT_SLOTS_WIDTH               106
#define CT_SLOTS_TOP                 49
#define CT_SLOTS_HEIGHT              90
#define CT_SLOTS_UNIT_PX             4
#define CT_SLOTS_BASELINE_PAD        19

#define CT_CARD_TOP                  142
#define CT_CARD_HEIGHT               98
#define CT_CARD_PAD                  6
#define CT_CARD_MAX                  2

#define CT_USAGE_ROW_H               40
#define CT_USAGE_GAP                 4
#define CT_USAGE_BAR_H               7
#define CT_USAGE_COLS                2
#define CT_USAGE_GUTTER              14
#define CT_USAGE_SESSION_WINDOW      18000
#define CT_USAGE_WEEKLY_WINDOW       604800
#define CT_USAGE_WARN_PCT            60
#define CT_USAGE_CRIT_PCT            85

#define CT_STROLL_SPEED_PX_S         34
#define CT_STROLL_PAUSE_S            2.5f
#define CT_STROLL_PAD_PX             96

#define CT_SKY_HORIZON               120
#define CT_SKY_DAWN_HOUR             5
#define CT_SKY_DAY_HOUR              7
#define CT_SKY_DUSK_HOUR             17
#define CT_SKY_NIGHT_HOUR            19
#define CT_SKY_DISC_R                7
#define CT_SKY_ARC_PEAK              82
#define CT_SKY_ARC_PAD               0
#define CT_SKY_TWINKLE_N             4
#define CT_SKY_STAR_PX               1
#define CT_SKY_STAR_PEAK_PX          3
#define CT_SKY_LOW_STAR_N            6
#define CT_SKY_CLOUD_SPEED_PX_S      4
#define CT_SKY_CLOUD_PAD             60

#define CT_SKY_STARS_COUNT           16
static const int16_t ct_sky_stars[CT_SKY_STARS_COUNT][2] = {
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

#define CT_SKY_CLOUDS_COUNT          3
static const int16_t ct_sky_clouds[CT_SKY_CLOUDS_COUNT][3] = {
    { 40,  44,  44},
    {150,  74,  36},
    {250,  32,  52},
};

#define CT_SKY_GRASS_X_COUNT         24
static const int16_t ct_sky_grass_x[CT_SKY_GRASS_X_COUNT] = {
      4,  13,  35,  41,  55,  62,  88,  99, 104, 123, 131, 155,
    168, 174, 191, 200, 228, 235, 247, 268, 273, 288, 298, 310,
};

#define CT_MASCOT_GRID_W             16.5f
#define CT_MASCOT_GRID_H             12
#define CT_MASCOT_CORNER             0.25f

// กรอบวาดมาสคอตรวม prop (หน่วย unit) — มาจาก tools/gen/props.py
#define CT_BOX_X0                    -0.5f
#define CT_BOX_X1                    23.4f
#define CT_BOX_Y0                    -5.6f
#define CT_BOX_Y1                    12.0f

// จานสีเป็น RGB565 ตามที่แผงจอกินจริง
#define CT_COL_BG                    0x1081
#define CT_COL_BG_SLOT               0x18A2
#define CT_COL_CLAY                  0xDBAA
#define CT_COL_CLAY_DARK             0xAAA7
#define CT_COL_CLAY_SLEEP            0x7A26
#define CT_COL_GRAY                  0x5AEB
#define CT_COL_GRAY_DARK             0x39E7
#define CT_COL_INK                   0x10A1
#define CT_COL_OUTLINE               0xFFFF
#define CT_COL_TEXT                  0xEF1B
#define CT_COL_TEXT_DIM              0x8C0F
#define CT_COL_ACCENT                0xEDC9
#define CT_COL_ACCENT_WARM           0xDCA4
#define CT_COL_GLASS                 0xAEDD
#define CT_COL_STEEL                 0x53B1
#define CT_COL_ALERT                 0xDAA9
#define CT_COL_GOOD                  0x5D4B
#define CT_COL_CODEX                 0x4D58
#define CT_COL_CODEX_DARK            0x33B1
#define CT_COL_CODEX_SLEEP           0x2A6B
#define CT_COL_ANTIGRAV              0x8BFB
#define CT_COL_ANTIGRAV_DARK         0x62B5
#define CT_COL_ANTIGRAV_SLEEP        0x41CD
#define CT_COL_SKY_NIGHT             0x0863
#define CT_COL_SKY_DAWN              0x3A4F
#define CT_COL_SKY_DAY               0xBEFE
#define CT_COL_SKY_DUSK              0x696F
#define CT_COL_GROUND_NIGHT          0x10C3
#define CT_COL_GROUND_DAWN           0x1926
#define CT_COL_GROUND_DAY            0x29C5
#define CT_COL_GROUND_DUSK           0x20C5
#define CT_COL_SUN                   0xF525
#define CT_COL_SUN_LOW               0xEC09
#define CT_COL_MOON                  0xCE7B
#define CT_COL_STAR                  0xEF1B
#define CT_COL_STAR_MID              0xA577
#define CT_COL_STAR_DIM              0x6BD1
#define CT_COL_CLOUD_DAY             0xF7DF
#define CT_COL_CLOUD_DAWN            0x5B73
#define CT_COL_CLOUD_DUSK            0xC352
#define CT_COL_GRASS_NIGHT           0x2A07
#define CT_COL_GRASS_DAWN            0x3287
#define CT_COL_GRASS_DAY             0x6D4B
#define CT_COL_GRASS_DUSK            0x5A87
#define CT_COL_SHADOW_NIGHT          0x0862
#define CT_COL_SHADOW_DAWN           0x10A3
#define CT_COL_SHADOW_DAY            0x1923
#define CT_COL_SHADOW_DUSK           0x1884

// visual state — daemon ส่งค่าพวกนี้มาบน BLE ห้ามเรียงใหม่
typedef enum {
    CT_STATE_IDLE         = 0,
    CT_STATE_READING      = 1,
    CT_STATE_WRITING      = 2,
    CT_STATE_BUILDING     = 3,
    CT_STATE_SEARCHING    = 4,
    CT_STATE_THINKING     = 5,
    CT_STATE_WAITING      = 6,
    CT_STATE_SLEEPING     = 7,
    CT_STATE_ALERT        = 8,
    CT_STATE_CELEBRATE    = 9,
    CT_STATE_ERROR        = 10,
    CT_STATE_ENTERING     = 11,
    CT_STATE_LEAVING      = 12,
    CT_STATE_CONDUCTING   = 13,
    CT_STATE_BEACON       = 14,
    CT_STATE_COUNT             = 15,
} ct_state_t;

static const char *const ct_state_names[CT_STATE_COUNT] = {
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

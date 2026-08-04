"""ท้องฟ้าตามช่วงเวลา — ฉากเต็มจอใต้แถบบน

ฟ้าอยู่ 22..119 แล้วพื้นดินยาวลงไปถึงก้นจอ: card วาดพื้นทึบของตัวเองอยู่แล้ว
ส่วนแผงโควตากับนาฬิกาใหญ่วางตัวอักษรลงบนพื้นดินตรงๆ สีพื้นดินทุกช่วงจึงต้องเข้ม
(luminance ~0.04) ไม่ใช่สีหญ้าจริง ความเขียวไปอยู่ที่กอหญ้าเล็กๆ บนเส้นขอบฟ้าแทน

เส้นขอบฟ้าอยู่ที่เส้นฝ่าเท้าพอดี — มาสคอตยืนบนพื้น ไม่ลอย ไม่จม ป้ายชื่อโปรเจกต์
ตกลงไปอยู่บนพื้นดินใต้เท้า

เวลามาจาก `snapshot.clock` ที่มีอยู่แล้ว ไม่มีอะไรเพิ่มบนสาย BLE — ต้องตรงกับ
ฝั่ง firmware ใน `firmware/main/pch_ui.c`
"""

from __future__ import annotations

import math

from PIL import ImageDraw

from .config import L, PAL
from .render import quantize565

# ฟ้าเริ่มใต้แถบบน ไม่ใช่ที่ขอบบนของแถบมาสคอต — แถบมาสคอตนั่งต่ำกว่านั้นลงมามาก
# ที่ว่างเหนือหัวคือท้องฟ้าที่ดวงอาทิตย์เดินผ่าน
SKY_TOP = L.topbar.height
HORIZON = L.sky.horizon
GROUND_BOTTOM = L.screen.height

SKY_COLOR = {
    "night": PAL.sky_night,
    "dawn": PAL.sky_dawn,
    "day": PAL.sky_day,
    "dusk": PAL.sky_dusk,
}
GROUND_COLOR = {
    "night": PAL.ground_night,
    "dawn": PAL.ground_dawn,
    "day": PAL.ground_day,
    "dusk": PAL.ground_dusk,
}
CLOUD_COLOR = {
    "dawn": PAL.cloud_dawn,
    "day": PAL.cloud_day,
    "dusk": PAL.cloud_dusk,
}
GRASS_COLOR = {
    "night": PAL.grass_night,
    "dawn": PAL.grass_dawn,
    "day": PAL.grass_day,
    "dusk": PAL.grass_dusk,
}
SHADOW_COLOR = {
    "night": PAL.shadow_night,
    "dawn": PAL.shadow_dawn,
    "day": PAL.shadow_day,
    "dusk": PAL.shadow_dusk,
}


def shadow_color(clock: str, connected: bool) -> str | None:
    """สีเงาใต้เท้าของช่วงเวลานี้ — None เมื่อไม่มีฉาก (ไม่ต่อลิงก์ / ยังไม่รู้เวลา)

    ไม่มีพื้นก็ไม่มีเงา: เงาบนพื้นจอเปล่าอ่านเป็นคราบ ไม่ใช่เงา
    """
    if not connected:
        return None
    h = hours(clock)
    return None if h is None else SHADOW_COLOR[phase_at(h)]


def hours(clock: str) -> float | None:
    """"14:32" -> 14.533 · คืน None เมื่ออ่านไม่ได้

    None ไม่ใช่เที่ยงคืน — มันคือ "ยังไม่รู้เวลา" ซึ่งต้องไม่มีท้องฟ้าเลย
    ตอนบูตก่อน sync ครั้งแรก clock เป็น "--:--" และต้องตกมาทางนี้
    """
    if len(clock) < 5 or clock[2] != ":":
        return None
    if not (clock[0:2].isdigit() and clock[3:5].isdigit()):
        return None
    h, m = int(clock[0:2]), int(clock[3:5])
    if h > 23 or m > 59:
        return None
    return h + m / 60.0


def phase_at(t: float) -> str:
    """ชั่วโมง -> ชื่อช่วง — กระโดดที่ขอบ ไม่ผสมสีระหว่างช่วง"""
    if t < L.sky.dawn_hour or t >= L.sky.night_hour:
        return "night"
    if t < L.sky.day_hour:
        return "dawn"
    if t < L.sky.dusk_hour:
        return "day"
    return "dusk"


def _arc(u: float) -> tuple[float, float]:
    """สัดส่วนของเส้นทาง (0..1) -> จุดกึ่งกลางดวงบนส่วนโค้ง

    ที่ u=0 และ u=1 ดวงอยู่บนเส้นขอบฟ้าพอดี (จมครึ่งดวง) และอยู่นอกจอทั้งสองข้าง
    """
    x = -L.sky.arc_pad + u * (L.screen.width + 2 * L.sky.arc_pad)
    y = HORIZON - math.sin(math.pi * u) * L.sky.arc_peak
    return x, y


def disc(t: float) -> tuple[float, float, str]:
    """ชั่วโมง -> (x, y, สี) ของดวงที่อยู่บนฟ้าตอนนั้น

    ดวงอาทิตย์ 05:00->19:00 · ดวงจันทร์ 19:00->05:00 — มีดวงใดดวงหนึ่งเสมอ
    """
    dawn, night = L.sky.dawn_hour, L.sky.night_hour
    if dawn <= t < night:
        x, y = _arc((t - dawn) / (night - dawn))
        low = phase_at(t) in ("dawn", "dusk")
        return x, y, PAL.sun_low if low else PAL.sun
    span = 24 - night + dawn
    u = ((t - night) % 24) / span
    x, y = _arc(u)
    return x, y, PAL.moon


def _draw_disc(draw: ImageDraw.ImageDraw, x: float, y: float, color: str) -> None:
    r = L.sky.disc_r
    x0, y0 = round(x) - r, round(y) - r
    # ตัดที่เส้นขอบฟ้า — ครึ่งล่างของดวงต้องหายไปใต้พื้น ไม่ใช่วาดทับพื้นดิน
    draw.ellipse([x0, y0, x0 + 2 * r, y0 + 2 * r], fill=quantize565(color))


def _draw_stars(draw: ImageDraw.ImageDraw, phase: str, cycle: int) -> None:
    if phase == "day":
        return
    stars = L.sky.stars
    base = L.sky.star_px

    def dot(x: int, y: int, color: str, size: int = 0) -> None:
        s = size or base
        # โตออกจากกึ่งกลาง ไม่ใช่ยืดลงขวา — ไม่งั้นดวงที่โตขึ้นอ่านเป็นดาวเลื่อนที่
        off = (s - base) // 2
        draw.rectangle([x - off, y - off, x - off + s - 1, y - off + s - 1],
                       fill=quantize565(color))

    if phase != "night":
        # ฟ้ายังสว่างเกินกว่าจะเห็นทั้งหมด — ดวงแรกๆ สีหรี่ ไม่กะพริบ
        for x, y in stars[: L.sky.low_star_n]:
            dot(x, y, PAL.star_dim)
        return
    # ดวงที่กะพริบไล่สว่างขึ้นแล้วหรี่ลง: dim -> mid -> star(โต) -> mid ขั้นละ 1 วินาที
    # ตั้งต้นที่หรี่แล้วสว่างขึ้น ไม่ใช่ตั้งต้นสว่างแล้วดับ — ดาวดับอ่านเป็นจอเสีย
    # ขั้นสว่างสุดโตเป็น star_peak_px ด้วย: บนแผงจริงความต่างของสีอย่างเดียวจางเกินกว่าจะจับได้
    # i * 3 ทำให้สี่ดวงเริ่มคนละขั้น (0,3,2,1) ไม่กะพริบพร้อมกันเป็นจังหวะเดียว
    peak = L.sky.star_peak_px
    ramp = ((PAL.star_dim, base), (PAL.star_mid, base),
            (PAL.star, peak), (PAL.star_mid, base))
    for i, (x, y) in enumerate(stars):
        if i < L.sky.twinkle_n:
            dot(x, y, *ramp[(cycle + i * 3) % 4])
        else:
            dot(x, y, PAL.star)


def _draw_clouds(draw: ImageDraw.ImageDraw, phase: str, t: float,
                 covered: bool = False) -> None:
    # กลางคืนปกติไม่มีเมฆ (มองไม่เห็น) แต่ตอนฟ้าปิดต้องเห็น
    # ไม่งั้นฝนตกลงมาจากฟ้าโล่ง
    if phase == "night":
        if not covered:
            return
        color = quantize565(PAL.sky_overcast)
    else:
        color = quantize565(CLOUD_COLOR[phase])
    pad, span = L.sky.cloud_pad, L.screen.width + 2 * L.sky.cloud_pad
    clouds = list(L.sky.clouds)
    if covered:
        # ก้อนเดิม 3 ก้อนดูโล่งเกินกว่าจะอ่านว่าฟ้าปิด — เติมให้ครบตาม overcast_clouds
        # หาตำแหน่งจากดัชนีเอง (ตรงกับ draw_clouds ใน pch_ui.c)
        for i in range(len(L.sky.clouds), L.weather.overcast_clouds):
            clouds.append([(i * 83 + 29) % L.screen.width,
                           34 + (i * 17) % 46,
                           30 + (i * 11) % 26])
    for base_x, y, w in clouds:
        x = (base_x + t * L.sky.cloud_speed_px_s) % span - pad
        # ปัดเป็นพิกเซลเต็มตรงนี้ ไม่ปล่อยให้ backend ตัดสิน — ฝั่ง LVGL รับ int เท่านั้น
        # ถ้า preview วาดที่ x เศษส่วน ตำแหน่งเมฆจะเลื่อนจากบนบอร์ดได้ถึงหนึ่งพิกเซล
        xi = round(x)
        draw.rounded_rectangle([xi, y, xi + w, y + 9], radius=4, fill=color)
        # ก้อนบนทำให้อ่านเป็นเมฆ ไม่ใช่แถบ — เยื้องซ้ายของกึ่งกลาง ไม่ใช่สมมาตร
        bx, bw = round(x + w * 0.2), round(w * 0.45)
        draw.rounded_rectangle([bx, y - 5, bx + bw, y + 4], radius=4, fill=color)


def _draw_grass(draw_ctx: ImageDraw.ImageDraw, phase: str) -> None:
    """กอหญ้างอกขึ้นจากเส้นขอบฟ้าไปในฟ้า — ก้านกลางสูงสุด ขนาบด้วยก้านสั้นสองข้าง

    งอกขึ้น ไม่ใช่ห้อยลง: หญ้าที่ยื่นลงไปในพื้นอ่านเป็นรอยขีดบนดิน ไม่ใช่ต้นไม้
    และอยู่แค่แถวเดียวบนเส้นขอบฟ้า ไม่ปูลงมาทั้งพื้น เพราะพื้นล่างมีตัวอักษรของ
    แผงโควตาและนาฬิกาใหญ่ทับอยู่ ลายบนพื้นตรงนั้นจะแย่งกับตัวอักษร
    """
    color = quantize565(GRASS_COLOR[phase])
    y = HORIZON - 1  # แถวบนสุดของหญ้าอยู่เหนือเส้นขอบฟ้าหนึ่งพิกเซล = โคนติดพื้นพอดี
    for i, x in enumerate(L.sky.grass_x):
        # ความสูงวนตามลำดับกอ — กอสูงเท่ากันหมดอ่านเป็นรั้ว ไม่ใช่หญ้า
        main, side = 3 + i % 4, 2 + i % 3
        # ก้านหนา 2px เว้นช่อง 1px — ก้าน 1px หายไปเลยบนแผงจริง (ต่างจาก preview
        # ที่ขยาย 3 เท่า) และช่องว่าง 1px คือสิ่งที่ทำให้ยังอ่านเป็นกอ ไม่ใช่แถบทึบ
        draw_ctx.rectangle([x, y - main, x + 1, y], fill=color)
        draw_ctx.rectangle([x - 3, y - side, x - 2, y], fill=color)
        draw_ctx.rectangle([x + 3, y - (2 + (side + 1) % 3), x + 4, y], fill=color)


# --- สภาพอากาศ -------------------------------------------------------------
# อากาศเป็น "อีกแกน" ของท้องฟ้า ไม่ใช่ phase ใหม่: เวลาของวันยังคุมความสว่างพื้นฐาน
# ส่วนอากาศคุมว่ามีอะไรบังฟ้าอยู่ ต้องตรงกับ weather_* ใน firmware/main/pch_ui.c

WET = ("rain", "storm")


def _covered(weather: str) -> bool:
    """ฟ้าปิดพอที่จะไม่เห็นดวงอาทิตย์/จันทร์และดาว"""
    return weather != "clear"


def _sky_bg(phase: str, weather: str) -> str:
    """กลางคืนไม่ถูกแทนสี — ฝนตอนตีสองต้องยังมืดกว่าฟ้าโปร่งตอนบ่าย
    เมฆที่หนาขึ้นเป็นตัวบอกเองว่าปิด"""
    if weather == "clear" or phase == "night":
        return SKY_COLOR[phase]
    return {"cloudy": PAL.sky_overcast, "rain": PAL.sky_overcast,
            "storm": PAL.sky_storm, "fog": PAL.fog}.get(weather, SKY_COLOR[phase])


def _flash_on(weather: str, t: float) -> bool:
    """ฟ้าแลบ: กะพริบทั้งแผงสั้นๆ แล้วดับ คำนวณจากเวลาล้วน ไม่เก็บสถานะ"""
    return weather == "storm" and (t % L.weather.flash_every_s) < L.weather.flash_hold_s


def _draw_rain(draw_ctx: ImageDraw.ImageDraw, t: float) -> None:
    """ขีดเฉียงที่วนรอบเอง ไม่ใช่ particle จริง — ตำแหน่งกระจายด้วยตัวคูณเฉพาะกิจ
    ให้ดูสุ่มแต่คงที่ทุกครั้ง (ภาพนิ่งเวลาหยุดเวลา = ดีบักง่าย)"""
    span = HORIZON - SKY_TOP
    if span <= 0:
        return
    color = quantize565(PAL.rain)
    for i in range(L.weather.drops):
        x0 = (i * 61 + 13) % L.screen.width
        off = (t * L.weather.drop_speed_px_s + (i * 37 % span)) % span
        y0 = SKY_TOP + int(off)
        y1 = min(y0 + L.weather.drop_len, HORIZON - 1)
        if y1 <= y0:
            continue
        mid = (y0 + y1) // 2
        x1 = x0 + L.weather.drop_slant
        draw_ctx.rectangle([x0, y0, x0, mid], fill=color)
        draw_ctx.rectangle([x1, mid, x1, y1], fill=color)


def draw(draw_ctx: ImageDraw.ImageDraw, clock: str, connected: bool, t: float,
         weather: str = "clear") -> None:
    """วาดท้องฟ้า + พื้นดินลงในแถบ slot

    `t` = เวลาสัมบูรณ์เป็นวินาทีของฉาก ใช้เฉพาะกับเมฆและการกะพริบ
    ส่วนช่วงเวลาของฟ้ามาจาก `clock` ล้วนๆ

    ไม่ต่อลิงก์ = ไม่วาดอะไรเลย ปล่อยให้เป็นพื้นจอเดิม — clock ที่ค้างอยู่ไม่ใช่เวลาจริง
    อีกต่อไป ท้องฟ้าที่ยังสวยอยู่จะกลบสัญญาณว่าขาดการติดต่อ และโกหกเรื่องเวลาด้วย
    """
    if not connected:
        return
    h = hours(clock)
    if h is None:
        return
    phase = phase_at(h)
    W = L.screen.width
    covered = _covered(weather)
    bg = PAL.lightning if _flash_on(weather, t) else _sky_bg(phase, weather)
    draw_ctx.rectangle([0, SKY_TOP, W - 1, HORIZON - 1], fill=quantize565(bg))

    # ฟ้าปิด = ดาวกับดวงหายไปพร้อมกัน ไม่งั้นอ่านเป็นฟ้าโปร่งสีแปลก
    if not covered:
        _draw_stars(draw_ctx, phase, int(t))
        x, y, color = disc(h)
        _draw_disc(draw_ctx, x, y, color)
    # หมอกคือฟ้าที่ไม่มีอะไรเลย — เมฆในหมอกมองไม่เห็นอยู่แล้ว
    if weather != "fog":
        _draw_clouds(draw_ctx, phase, t, covered)
    if weather in WET:
        _draw_rain(draw_ctx, t)

    # พื้นดินวาดทับหลังสุด — ครึ่งล่างของดวงและเมฆที่ต่ำเกินไปจึงถูกตัดที่เส้นขอบฟ้าเอง
    draw_ctx.rectangle([0, HORIZON, W - 1, GROUND_BOTTOM - 1],
                       fill=quantize565(GROUND_COLOR[phase]))
    _draw_grass(draw_ctx, phase)

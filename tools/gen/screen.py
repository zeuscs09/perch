"""ประกอบจอทั้งใบ 320x240 — ตัวแทนของหน้าจอจริงตอน dev

จูน layout ที่นี่ได้ทันทีโดยไม่ต้องแฟลชบอร์ด
ค่าคงที่ทั้งหมดมาจาก layout.toml ชุดเดียวกับ firmware
"""

from __future__ import annotations

from dataclasses import dataclass, field

from PIL import Image, ImageDraw, ImageFont

from . import mascot, sky
from .config import L, PAL
from .mascot import BODY
from .props import BOX_X0, BOX_X1, BOX_Y1

BODY_CX = BODY[0] + BODY[2] / 2  # กึ่งกลางลำตัวในหน่วย unit — จุดที่เงาต้องอยู่ใต้
from .render import draw_rects, quantize565

_FONTS: dict[int, ImageFont.FreeTypeFont] = {}


def font(size: int) -> ImageFont.FreeTypeFont:
    if size not in _FONTS:
        _FONTS[size] = ImageFont.load_default(size=size)
    return _FONTS[size]


def _ascii_only(**fields: str) -> None:
    """กันข้อความสาธิตที่ฟอนต์บนบอร์ดวาดไม่ได้ — จะได้กล่องสี่เหลี่ยมแทน

    ข้อความจริงผ่าน Text.sanitize ฝั่ง daemon (host/Sources/TamaCore/Text.swift)
    มาแล้ว จอจึงเห็นแค่ ASCII 0x20..0x7E เสมอ ถ้า preview ยอมให้ใส่ em dash ได้
    ภาพที่ออกมาจะสวยกว่าของจริง ซึ่งแย่กว่าการพังตรงนี้
    """
    for name, value in fields.items():
        bad = sorted({c for c in value if not (" " <= c <= "~")})
        if bad:
            raise ValueError(
                f"{name}={value!r} มีอักขระนอก ASCII พิมพ์ได้: {bad} "
                f"— daemon จะแทนที่ให้ก่อนส่ง ใส่ตัวที่แทนแล้วมาตรงนี้"
            )


@dataclass(slots=True)
class Session:
    project: str
    state: str = "idle"
    phase_offset: float = 0.0

    def __post_init__(self) -> None:
        _ascii_only(project=self.project)


@dataclass(slots=True)
class Card:
    title: str
    body: str
    kind: str = "info"  # info | alert | done

    def __post_init__(self) -> None:
        _ascii_only(title=self.title, body=self.body)


@dataclass(slots=True)
class Usage:
    """หนึ่งหน้าต่างโควตา — ตรงกับ `rate_limits.five_hour` / `.seven_day` ที่ Claude Code ป้อน

    `pct` และ `remaining` เป็น None แยกกันได้ — เอกสารระบุว่าแต่ละหน้าต่างหายอิสระต่อกัน
    None คือ "ไม่รู้" ไม่ใช่ศูนย์ ศูนย์เป็นค่าจริง (ADR-0001: reported, never derived)
    """

    label: str
    window: int  # ความยาวหน้าต่างเป็นวินาที — ค่าคงที่ ใช้หาตำแหน่งขีด pace
    pct: int | None = None
    remaining: int | None = None  # วินาทีถึงรีเซ็ต — บอร์ดนับถอยลงเอง


@dataclass(slots=True)
class Screen:
    sessions: list[Session] = field(default_factory=list)
    overflow: int = 0
    clock: str = "14:32"
    date: str = "Mon 27 Jul"
    # มี snapshot สดอยู่ไหม — ไม่สนใจว่ามาทางไหน ตรงกับ ct_ui_set_connected
    connected: bool = True
    # บอร์ดอยู่บน WiFi แล้วหรือยัง
    wifi: bool = False
    # ลิงก์ BLE ขึ้นอยู่ไหม — None = เหมือน connected (ฉากเก่าทั้งหมดคุยกันทาง BLE)
    # แยกจาก connected ตั้งแต่ M2 เพราะ snapshot เดินทางมาทาง LAN ได้แล้ว: จอที่ข้อมูล
    # สดแต่ BLE ตายเป็นสภาพที่มีจริง และไอคอนต้องบอกให้ถูก
    ble: bool | None = None
    # ที่อยู่บอร์ดบน LAN — ขึ้นแทนชื่อบนแถบเมื่อเหลือแต่ WiFi ซึ่งเป็นตอนเดียวที่ต้องใช้
    ip: str = ""
    # ชื่อสถานที่ + อุณหภูมิบนแถบบน — "" / None = ไม่ได้ตั้ง ใช้ชื่อบอร์ดตามเดิม
    place: str = ""
    temperature: int | None = None
    # สภาพอากาศ: clear / cloudy / rain / storm / fog — อีกแกนของท้องฟ้า คนละแกนกับเวลา
    weather: str = "clear"
    # ภาระเครื่อง (cpu%, mem%) — ช่องที่ 4 ของตาราง วาดคนละแบบกับโควตา
    machine: tuple[int, int] | None = None

    @property
    def ble_link(self) -> bool:
        return self.connected if self.ble is None else self.ble
    # ใหม่สุดอยู่บน — session ที่เกิน 4 ตัวไม่มีมาสคอต แต่การเตือนยังมาโผล่ตรงนี้
    cards: list[Card] = field(default_factory=list)
    # การ์ดที่มีอยู่จริงแต่ไม่ได้ส่ง/วาดไม่พอ — daemon นับมาให้ (คีย์ "m" บนสาย)
    card_overflow: int = 0
    # None = ไม่เคยได้ข้อมูลเลย -> ถอยไปเป็นนาฬิกาตั้งโต๊ะ ไม่ใช่โครงเปล่าที่ดูเหมือนพัง
    usage: list[Usage] | None = None

    def shown_cards(self) -> list[Card]:
        """การ์ดที่มีสิทธิ์ขึ้นจอ — ลิงก์หลุดแล้วเหลือศูนย์ใบ ดูที่ shown_usage()"""
        return list(self.cards) if self.connected else []

    def shown_usage(self) -> list[Usage]:
        """โควตาที่มีสิทธิ์ขึ้นจอ — ลิงก์หลุดแล้วเหลือศูนย์แถว

        ตอนหลุดลิงก์ สิ่งเดียวที่บอร์ดยืนยันเองได้คือนาฬิกา ทั้งการ์ดและเปอร์เซ็นต์เป็นค่าที่
        host เคยบอกไว้และไม่มีใครรับรองแล้วว่ายังจริง ดูที่ DESIGN.md "แผงโควตา"
        """
        return list(self.usage) if self.connected and self.usage else []


def _fit(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont, max_w: int) -> str:
    """ตัดข้อความให้พอดีความกว้าง — daemon ต้องทำแบบเดียวกันก่อนส่งบน BLE"""
    if draw.textlength(text, font=f) <= max_w:
        return text
    ell = "..."
    while text and draw.textlength(text + ell, font=f) > max_w:
        text = text[:-1]
    return text + ell


# ไอคอนลิงก์ — ต้องตรงกับ ICON_* ใน firmware/main/ct_ui.c เป๊ะ
# BLE = แท่งไต่ขึ้น (ทางหลัก) · WiFi = คลื่นซ้อน (ทางสำรอง) · ขาด = ขีดเดียวจางๆ
_ICON_BLE = [(0, 6, 3, 3), (4, 3, 3, 6), (8, 0, 3, 9)]
_ICON_WIFI = [(0, 0, 11, 2), (2, 3, 7, 2), (4, 6, 3, 3)]
_ICON_NONE = [(1, 4, 9, 2)]


def _link_icon(draw: ImageDraw.ImageDraw, s: Screen) -> None:
    if s.ble_link:
        parts, col = _ICON_BLE, PAL.good
    elif s.wifi:
        parts, col = _ICON_WIFI, PAL.accent
    else:
        parts, col = _ICON_NONE, PAL.text_dim
    x0 = L.screen.width - 6 - L.topbar.link_icon_w
    y0 = (L.topbar.height - L.topbar.link_icon_h) // 2
    for x, y, w, h in parts:
        draw.rectangle([x0 + x, y0 + y, x0 + x + w - 1, y0 + y + h - 1],
                       fill=quantize565(col))


def _link_label(s: Screen) -> str:
    """ป้ายข้างไอคอน — ตรงกับ apply_link_label ใน firmware/main/ct_ui.c

    ชื่อสถานที่ชนะชื่อบอร์ด: ตอนต่อติดแล้ว "ต่อกับอะไรอยู่" ไม่ใช่คำถามอีกต่อไป
    (ไอคอนข้างๆ ตอบให้แล้ว) พื้นที่ตรงนี้จึงมีค่ากว่าถ้าบอกอย่างอื่น
    """
    if not s.ble_link:
        return s.ip if (s.wifi and s.ip) else "no link"
    label = s.place or "tamaclaude"
    if s.temperature is not None:
        return f"{label}  {s.temperature}\u00b0"
    return label


def _topbar(draw: ImageDraw.ImageDraw, s: Screen) -> None:
    h = L.topbar.height
    draw.rectangle([0, 0, L.screen.width - 1, h - 1], fill=quantize565(PAL.bg_slot))
    dot = PAL.good if s.connected else PAL.gray
    draw.rectangle([6, h // 2 - 3, 11, h // 2 + 2], fill=quantize565(dot))
    # ป้ายบอกทาง ส่วนสีบอกว่าข้อมูลสดไหม — สองคำถามคนละอัน (ต้องตรงกับ ct_ui_set_link)
    label = _link_label(s)
    draw.text((17, h // 2), label, font=font(11),
              fill=quantize565(PAL.text if s.connected else PAL.text_dim), anchor="lm")
    _link_icon(draw, s)
    # นาฬิกาบนแถบโผล่เมื่อพื้นที่ล่างถูกยึดไป (card หรือ usage) — ไม่ใช่ "เมื่อมี card"
    # อย่างเดิม เพราะตอนนี้มีผู้ยึดสองราย ถ้าเช็คแค่ card จะได้นาฬิกาซ้ำสองที่ในฉาก idle
    # ไอคอนลิงก์จองขวาสุดไว้ถาวร ทุกอย่างบนแถบจึงเริ่มนับจากซ้ายของมัน
    right = L.screen.width - 6 - L.topbar.link_icon_w - L.topbar.link_icon_gap
    cards, usage = s.shown_cards(), s.shown_usage()
    if cards or usage:
        draw.text((right, h // 2), s.clock, font=font(12),
                  fill=quantize565(PAL.text), anchor="rm")
        right -= 38
    if s.overflow:
        draw.text((right, h // 2), f"+{s.overflow}", font=font(11),
                  fill=quantize565(PAL.accent), anchor="rm")
        right -= 26

    # การ์ดยึดพื้นที่ล่างไปแล้ว แต่โควตาไม่ควรหายไปทั้งหมด — ย่อเหลือหน้าต่าง 5 ชม.
    # อย่างเดียวมาไว้บนแถบ ไม่มีป้ายกำกับเพราะบนแถบมีค่าเดียว ไม่ต้องแยกว่าตัวไหน
    # ไม่แสดงตอนไม่มีการ์ด เพราะแผงเต็มโชว์ตัวเลขเดียวกันอยู่แล้ว
    if cards and usage:
        u = usage[0]
        col = usage_color(u.pct)
        pct_text = "--%" if u.pct is None else f"{u.pct}%"
        draw.text((right, h // 2), pct_text, font=font(11), fill=quantize565(col), anchor="rm")
        right -= 30

        # แถบสั้นให้เหลือบแล้วรู้ทันทีว่าเหลือเท่าไร โดยไม่ต้องอ่านตัวเลข
        # สูง 6px บนแถบ 22px อ่านออก — ที่อ่านไม่ออกคือแถบบางในแผงเต็ม ไม่ใช่ตรงนี้
        # กรอบขาวรอบราง — พื้นรางสีเดียวกับพื้นหลังจอ ทำให้ส่วนที่ยังไม่ถูกใช้กลืนหาย
        # เห็นแต่ "ใช้ไปเท่าไร" ไม่เห็น "เหลือเท่าไร" กรอบตีขอบให้รู้ความยาวเต็ม
        bw, bh = 34, 6
        ox, oy = right - bw - 2, h // 2 - (bh + 2) // 2
        draw.rectangle([ox, oy, ox + bw + 1, oy + bh + 1],
                       fill=quantize565(PAL.bg), outline=quantize565(PAL.outline), width=1)
        bx, by = ox + 1, oy + 1
        if u.pct is not None:
            fill_w = round(bw * min(max(u.pct, 0), 100) / 100)
            if fill_w:
                draw.rectangle([bx, by, bx + fill_w - 1, by + bh - 1], fill=quantize565(col))


def slot_x(i: int, n: int) -> int:
    """ขอบซ้ายของ slot ที่ i เมื่อกำลังแสดง session อยู่ n ตัว

    ระยะห่างคงที่ 80px เสมอ แต่ยกทั้งกลุ่มมาไว้กึ่งกลางจอ
    สิ่งที่ต้องนิ่งคือ *ลำดับ* ซ้าย→ขวา ไม่ใช่พิกัดสัมบูรณ์ — ตัวละครไม่เคยสลับที่กัน
    มีแค่ทั้งกลุ่มเลื่อนพร้อมกันตอนมี session เข้า/ออก
    """
    return round((L.screen.width - n * L.slots.width) / 2) + i * L.slots.width


# เงาใต้เท้า — กว้าง 11 unit (แคบกว่าช่วงขา 14 unit) วางอยู่ใต้เส้นขอบฟ้าทั้งก้อน
# ขนาดคงที่ ไม่ยุบตามความสูงที่กระโดด: หน้าที่ของมันคือปักหมุดว่า "พื้นอยู่ตรงนี้"
# เงาที่ยุบตามจะกลายเป็นสิ่งที่ต้องมองแทนที่จะเป็นสิ่งที่ทำให้มองตัวละครถูก
SHADOW_W = 11.0


def _shadow(draw: ImageDraw.ImageDraw, cx: float, color: str | None) -> None:
    if color is None:
        return
    half = SHADOW_W * L.slots.unit_px / 2
    y = L.sky.horizon
    # แคปซูล ไม่ใช่วงรี — ฝั่ง LVGL วาดด้วย lv_draw_rect ที่ radius ถูก clamp ครึ่งด้านสั้น
    # ซึ่งได้แคปซูล ถ้า preview ใช้วงรีจริง สองฝั่งจะไม่ตรงกัน
    draw.rounded_rectangle([round(cx - half), y, round(cx + half), y + 4],
                           radius=2, fill=quantize565(color))


def _slot(draw: ImageDraw.ImageDraw, i: int, sess: Session | None, s: Screen,
          phase: float, cycle: int, n: int) -> None:
    sw, top, sh = L.slots.width, L.slots.top, L.slots.height
    if sess is None:
        return
    x = slot_x(i, n)
    # ไม่มีทั้งพื้นหลัง slot สลับสีและเส้นคั่น — ฉากเป็นผืนเดียวกันทั้งจอ เส้นแบ่งใดๆ
    # ตัดมันออกเป็นชิ้น ส่วนหน้าที่เดิมของเส้นคั่น (กันไม่ให้ prop ของตัวหนึ่งอ่านเป็น
    # ของตัวข้างๆ) ตอนนี้เงาใต้เท้าทำแทน: มันบอกว่าแต่ละตัวยืนอยู่ตรงไหน

    px = L.slots.unit_px
    foot_px = top + sh - L.slots.baseline_pad
    oy = foot_px - BOX_Y1 * px
    ox = x + sw / 2 - (BOX_X0 + BOX_X1) / 2 * px

    p = phase + sess.phase_offset
    # เงาเกาะกับ *ลำตัว* ไม่ใช่กึ่งกลาง slot — build_centered จัดกึ่งกลางกรอบที่รวม prop
    # ด้วย ท่าที่ถือของชิ้นใหญ่จึงมีลำตัวเยื้องไปจากกึ่งกลาง slot
    bx0, _, bx1, _ = mascot.state_box(sess.state)
    body_cx = x + sw / 2 + (BODY_CX - (bx0 + bx1) / 2) * px
    _shadow(draw, body_cx, sky.shadow_color(s.clock, s.connected))

    rects = mascot.build_centered(sess.state, p % 1.0, s.connected, cycle + int(p))
    draw_rects(draw, rects, px, ox, oy)

    f = font(9)
    name = _fit(draw, sess.project, f, sw - 8)
    draw.text((x + sw / 2, foot_px + 11), name, font=f,
              fill=quantize565(PAL.text if s.connected else PAL.text_dim), anchor="mm")


# --- มาสคอตเดินเล่นตอนไม่มี session ------------------------------------------
# ท่าที่หยุดทำกลางทาง วนไปตามรอบ — ต้องตรงกับ STROLL_ACTS ใน firmware/main/ct_ui.c
STROLL_ACTS = ("celebrate", "thinking", "searching", "waiting")
# ตำแหน่งหยุดเป็นสัดส่วนของเส้นทาง — วนคนละความยาวกับ ACTS เพื่อไม่ให้จับคู่ซ้ำ
STROLL_PAUSE_AT = (0.34, 0.5, 0.66)
STROLL_TRAVEL = L.screen.width + 2 * L.stroll.pad_px


def stroll_pose(t: float) -> tuple[str, float]:
    """เวลาสัมบูรณ์ (วินาที) -> (state, x ของขอบซ้ายกรอบวาด)

    เที่ยวหนึ่ง = เดินจากนอกจอซ้ายไปนอกจอขวา โดยหยุดทำท่าหนึ่งครั้งกลางทาง
    ต้องตรงกับ stroll_pose ใน firmware/main/ct_ui.c
    """
    walk_s = STROLL_TRAVEL / L.stroll.speed_px_s
    trip_s = walk_s + L.stroll.pause_s
    trip = int(t // trip_s)
    u = t - trip * trip_s
    hold_at = walk_s * STROLL_PAUSE_AT[trip % len(STROLL_PAUSE_AT)]

    if u < hold_at:
        walked = u
        state = "entering"
    elif u < hold_at + L.stroll.pause_s:
        walked = hold_at
        state = STROLL_ACTS[trip % len(STROLL_ACTS)]
    else:
        walked = u - L.stroll.pause_s
        state = "entering"
    return state, -L.stroll.pad_px + walked * L.stroll.speed_px_s


def _stroll(draw: ImageDraw.ImageDraw, s: Screen, phase: float, cycle: int) -> None:
    state, x = stroll_pose(cycle + phase)
    px = L.slots.unit_px
    foot_px = L.slots.top + L.slots.height - L.slots.baseline_pad
    ox = x - BOX_X0 * px
    # ตัวเดินเล่นใช้ build() ตรงๆ ไม่ผ่าน build_centered จึงไม่มี dx มาชดเชย
    _shadow(draw, ox + BODY_CX * px, sky.shadow_color(s.clock, s.connected))
    draw_rects(draw, mascot.build(state, phase, s.connected, cycle), px,
               ox, foot_px - BOX_Y1 * px)


CARD_H = 36
CARD_GAP = 4
CARD_MAX = L.card.max


def _card(draw: ImageDraw.ImageDraw, c: Card, y: int) -> None:
    pad, w = L.card.pad, L.screen.width
    draw.rectangle([pad, y, w - pad - 1, y + CARD_H - 1], fill=quantize565(PAL.bg_slot))
    accent = {"alert": PAL.alert, "done": PAL.good}.get(c.kind, PAL.accent)
    draw.rectangle([pad, y, pad + 2, y + CARD_H - 1], fill=quantize565(accent))

    tx = pad + 9
    tw = w - pad - 8 - tx
    ft, fb = font(12), font(10)
    draw.text((tx, y + 11), _fit(draw, c.title, ft, tw), font=ft,
              fill=quantize565(PAL.text), anchor="lm")
    draw.text((tx, y + 25), _fit(draw, c.body, fb, tw), font=fb,
              fill=quantize565(PAL.text_dim), anchor="lm")


def _cards(draw: ImageDraw.ImageDraw, cards: list[Card], overflow: int) -> None:
    y = L.card.top + L.card.pad
    for c in cards[:CARD_MAX]:
        _card(draw, c, y)
        y += CARD_H + CARD_GAP
    # การ์ดที่ไม่ได้วาดต้องเหลือร่องรอย ไม่ใช่หายเงียบ — "ไม่มีอะไรค้างแล้ว" กับ
    # "ยังค้างอีกสองเรื่องแต่จอไม่พอ" คือสองสถานะที่ต้องแยกออกจากกันได้ในเหลือบเดียว
    if overflow > 0:
        draw.text((L.screen.width - L.card.pad - 8, y + 1), f"+{overflow} more",
                  font=font(11), fill=quantize565(PAL.text_dim), anchor="rm")


def fmt_remaining(secs: int | None) -> str:
    """วินาทีที่เหลือ -> ข้อความสั้นที่สุดที่ยังบอกได้ว่าควรรีบไหม

    ระดับความละเอียดลดลงตามระยะ: ใกล้ = นาที, ไกล = ชั่วโมง/วัน
    ที่ 0 ไม่ใช่ "0m" แต่เป็น "resetting" เพราะ % ที่ถืออยู่หมดอายุไปแล้ว
    """
    if secs is None:
        return "no data"  # `--` ลอยเดี่ยวบนบรรทัดข้อความอ่านเป็นขยะ ไม่ใช่สถานะ
    if secs <= 0:
        return "resetting"
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m:02d}m"
    return f"{m}m"


def usage_color(pct: int | None) -> str:
    if pct is None:
        return PAL.text_dim
    if pct >= L.usage.crit_pct:
        return PAL.alert
    if pct >= L.usage.warn_pct:
        return PAL.accent
    return PAL.good


def usage_bar_color(u: Usage) -> str:
    """แดงทันทีที่ใช้เร็วกว่าเวลาที่ผ่านไปในหน้าต่าง ไม่ต้องรอถึงเกณฑ์ %

    "60% ตอนเหลือเวลาอีกครึ่ง" เป็นปัญหาคนละแบบกับ "60% ตอนหมดเวลาพอดี"
    ต้องตรงกับ usage_bar_color ใน firmware/main/ct_ui.c
    และ MenuBadge.alarming ใน host/Sources/TamaCore/MenuBadge.swift (แถบเมนูใช้สูตร pace เดียวกัน แต่ไม่มีเกณฑ์ %)
    """
    if u.pct is None:
        return PAL.text_dim
    if u.remaining is not None and u.remaining > 0 and u.window > 0:
        elapsed = max(0, min(u.window, u.window - u.remaining))
        if u.pct * u.window > elapsed * 100:
            return PAL.alert
    return usage_color(u.pct)


# ขอบซ้าย/ขวาของแผง และขนาดของหนึ่งช่องในตาราง
# ต้องตรงกับ USAGE_X0/USAGE_CELL_W/USAGE_PILL_W ใน firmware/main/ct_ui.c
USAGE_X0 = L.card.pad + 8
USAGE_X1 = L.screen.width - L.card.pad - 8
USAGE_W = USAGE_X1 - USAGE_X0
USAGE_CELL_W = (USAGE_W - (L.usage.cols - 1) * L.usage.gutter) // L.usage.cols
# pill แคบลงจาก 62 เพราะช่องแคบลงครึ่งหนึ่ง — ยังพอใส่ "Current" ที่ฟอนต์ 11
USAGE_PILL_W = 50

# สี pill แยกตามหน้าต่าง — สีคือสิ่งที่บอกว่ากำลังอ่านแถวไหนก่อนอ่านตัวอักษร
_PILL_COLORS = {"Current": PAL.clay, "Weekly": PAL.good, "Codex": PAL.codex}


def _usage_row(draw: ImageDraw.ImageDraw, u: Usage, y: int, x0: int, x1: int) -> None:
    """หนึ่งช่องของตาราง — ผู้เรียกเป็นคนบอกขอบซ้าย/ขวา ไม่ใช่กินเต็มจอ
    ต้องตรงกับ build_usage/layout_usage ใน firmware/main/ct_ui.c"""
    col = usage_bar_color(u)

    # เปอร์เซ็นต์ตัวใหญ่ — สิ่งเดียวที่ต้องอ่านออกจากอีกฝั่งห้อง
    # 24 ตรงกับ lv_font_montserrat_24 บนบอร์ด — ฟอนต์คนละตัวแต่ขนาดต้องไม่หลุดกัน
    # stroke_width=1 = ป้ายซ้อนเยื้อง 1px ฝั่ง LVGL ซึ่งไม่มี montserrat ตัวหนา
    big = "--%" if u.pct is None else f"{u.pct}%"
    big_col = quantize565(col if u.pct is not None else PAL.text_dim)
    draw.text((x0, y + 14), big, font=font(24), fill=big_col, anchor="lm",
              stroke_width=1, stroke_fill=big_col)

    # เวลารีเซ็ตอยู่บรรทัดเดียวกับเลข % ไม่ใช่ชั้นใต้แถบ — เกาะขอบขวาของเลขจริง
    # ไม่ใช่พิกัดตายตัวที่กันที่ไว้ให้ "100%" ซึ่งทำให้เลขสองหลักดูห่างจนไม่เป็นก้อนเดียวกัน
    # "resetting" / "no data" ยืนลำพัง — เติม "Resets in" ข้างหน้าแล้วอ่านไม่เป็นภาษา
    # ไม่มีคำว่า "Resets in" — ในตาราง 2 คอลัมน์ช่องกว้างครึ่งเดียว ข้อความเต็ม
    # ล้นไปทับ pill ส่วน pill ก็บอกอยู่แล้วว่าหน้าต่างไหน (ตรงกับ usage_reset_text)
    txt = fmt_remaining(u.remaining)
    big_w = draw.textlength(big, font=font(24)) + 2  # +2 = stroke_width ทั้งสองข้าง
    draw.text((x0 + big_w + 5, y + 14), txt, font=font(11),
              fill=quantize565(PAL.text_dim), anchor="lm")

    # ป้ายชื่อหน้าต่างชิดขวา — สีคงที่ต่อหน้าต่าง ไม่ตามระดับการใช้
    # ป้ายบอก *ว่านี่คือหน้าต่างไหน* ซึ่งไม่เคยเปลี่ยน การให้มันเปลี่ยนสีตาม %
    # ทำให้แถวทั้งแถวเป็นสีเดียวตอนวิกฤต แล้วสีหยุดเป็นสัญญาณ กลายเป็นพื้นหลัง
    fl = font(11)
    px0 = x1 - USAGE_PILL_W
    draw.rounded_rectangle([px0, y + 5, x1, y + 23], radius=9,
                           fill=quantize565(_PILL_COLORS.get(u.label, PAL.gray_dark)))
    draw.text(((px0 + x1) / 2, y + 14), u.label, font=fl,
              fill=quantize565(PAL.ink), anchor="mm")

    # แถบ — รางต้องสว่างกว่าพื้นจอพอให้เห็นความยาวเต็มตอนใช้ไปน้อย
    bh = L.usage.bar_h
    by = y + 28
    r = bh // 2
    draw.rounded_rectangle([x0, by, x1, by + bh - 1], radius=r,
                           fill=quantize565(PAL.gray_dark))
    if u.pct is not None:
        fill_w = round((x1 - x0) * min(max(u.pct, 0), 100) / 100)
        if fill_w > 0:
            draw.rounded_rectangle([x0, by, x0 + fill_w, by + bh - 1], radius=r,
                                   fill=quantize565(col))

    # ขีด pace — "ควรใช้ถึงไหนแล้ว" ตามเวลาที่ผ่านไปในหน้าต่าง
    # ขีดอยู่ขวาของเนื้อแถบ = ใช้ช้ากว่าเวลา · อยู่ซ้าย = ใช้เร็วเกินไป
    if u.remaining is not None and u.remaining > 0:
        elapsed = max(0, min(u.window, u.window - u.remaining))
        mx = x0 + round((x1 - x0) * elapsed / u.window)
        draw.rectangle([mx, by - 2, mx, by + bh + 1], fill=quantize565(PAL.outline))


def _usage(draw: ImageDraw.ImageDraw, rows: list[Usage]) -> None:
    """ตาราง 2 คอลัมน์ — ซ้อนลงมา 4 แถวต้องบีบความสูงเหลือ ~21px ซึ่งเลข %
    ขนาด 24px ใส่ไม่ลง สองคอลัมน์เก็บความสูงแถวเดิมไว้ได้ทั้งหมด

    แผงเตี้ยกว่าพื้นที่ที่มี จึงจัดกลางแนวตั้ง ไม่ชิดบน ไม่งั้นก้นจอโล่งเป็นแถบ
    แล้วอ่านเป็น "ของหาย" แทนที่จะเป็นการตัดสินใจ
    ต้องตรงกับ usage_row_y/usage_cell_x ใน firmware/main/ct_ui.c
    """
    grid_rows = (L.usage.rows + L.usage.cols - 1) // L.usage.cols
    block = grid_rows * L.usage.row_h + (grid_rows - 1) * L.usage.gap
    top = L.card.top + (L.card.height - block) // 2
    for i, u in enumerate(rows[:L.usage.rows]):
        y = top + (i // L.usage.cols) * (L.usage.row_h + L.usage.gap)
        x0 = USAGE_X0 + (i % L.usage.cols) * (USAGE_CELL_W + L.usage.gutter)
        _usage_row(draw, u, y, x0, x0 + USAGE_CELL_W)


# ต้องตรงกับ build_machine/layout_machine ใน firmware/main/ct_ui.c
MACHINE_LINE_H = 18
MACHINE_BAR_H = 4
MACHINE_LABEL_W = 30
MACHINE_VALUE_W = 34


def _machine(draw: ImageDraw.ImageDraw, cpu: int, mem: int) -> None:
    """ภาระเครื่องในช่องที่ 4 — สองบรรทัดเล็ก ไม่มี pill ไม่มีเวลานับถอยหลัง

    ตั้งใจให้หน้าตาไม่เหมือนแถวโควตา เพราะเป็นค่าคนละชนิด (ไม่มีเส้นตายรีเซ็ต)
    ถ้าทำให้เหมือนกัน ช่อง "resets in" ที่ว่างเปล่าจะอ่านเป็นข้อมูลขาด ไม่ใช่ดีไซน์
    """
    grid_rows = (L.usage.rows + L.usage.cols - 1) // L.usage.cols
    block = grid_rows * L.usage.row_h + (grid_rows - 1) * L.usage.gap
    top = L.card.top + (L.card.height - block) // 2
    y0 = top + (3 // L.usage.cols) * (L.usage.row_h + L.usage.gap)
    x0 = USAGE_X0 + (3 % L.usage.cols) * (USAGE_CELL_W + L.usage.gutter)
    track_w = USAGE_CELL_W - MACHINE_LABEL_W - MACHINE_VALUE_W

    for i, (name, pct) in enumerate((("CPU", cpu), ("RAM", mem))):
        ly = y0 + i * MACHINE_LINE_H
        v = min(max(pct, 0), 100)
        # เกณฑ์สีชุดเดียวกับโควตา — ผู้ใช้เรียนรู้ครั้งเดียวใช้ได้ทั้งจอ
        col = (PAL.alert if v >= L.usage.crit_pct
               else PAL.accent if v >= L.usage.warn_pct else PAL.good)
        draw.text((x0, ly + 7), name, font=font(11),
                  fill=quantize565(PAL.text_dim), anchor="lm")
        draw.text((x0 + MACHINE_LABEL_W, ly + 7), f"{v}%", font=font(11),
                  fill=quantize565(col), anchor="lm")
        bx = x0 + MACHINE_LABEL_W + MACHINE_VALUE_W
        by = ly + 5
        r = MACHINE_BAR_H // 2
        draw.rounded_rectangle([bx, by, bx + track_w, by + MACHINE_BAR_H - 1],
                               radius=r, fill=quantize565(PAL.gray_dark))
        fw = round(track_w * v / 100)
        if fw > 0:
            draw.rounded_rectangle([bx, by, bx + fw, by + MACHINE_BAR_H - 1],
                                   radius=r, fill=quantize565(col))


def _idle_clock(draw: ImageDraw.ImageDraw, s: Screen) -> None:
    """ไม่มีอะไรต้องเตือน = ให้พื้นที่นี้ทำหน้าที่นาฬิกาตั้งโต๊ะแทน

    นี่คือสิ่งที่จอเป็นอยู่เกือบตลอดเวลา ถ้าปล่อยว่างจะดูเหมือนอุปกรณ์พัง
    """
    cx = L.screen.width // 2
    cy = L.card.top + L.card.height // 2
    draw.text((cx, cy - 8), s.clock, font=font(46),
              fill=quantize565(PAL.text if s.connected else PAL.gray), anchor="mm")
    if s.date:
        draw.text((cx, cy + 26), s.date, font=font(12),
                  fill=quantize565(PAL.text_dim), anchor="mm")


def render(s: Screen, phase: float = 0.0, cycle: int = 0) -> Image.Image:
    img = Image.new("RGB", (L.screen.width, L.screen.height), quantize565(PAL.bg))
    draw = ImageDraw.Draw(img)
    # ฉากอยู่หลังทุกอย่าง กินเต็มจอใต้แถบบน — มาสคอตยืนทับ ยอมให้บังดวงอาทิตย์/ดาว
    # การถูกบังคือระยะลึก ไม่ใช่ของหาย และตอนไม่มี session (ซึ่งเป็นเกือบตลอดเวลา)
    # ฟ้าโล่งทั้งแถบอยู่แล้ว
    sky.draw(draw, s.clock, s.connected, cycle + phase, weather=s.weather)
    _topbar(draw, s)
    n = min(len(s.sessions), L.slots.count)
    if n == 0:
        # แถบ slot ที่ว่างเปล่าอ่านได้ว่า "อุปกรณ์ค้าง" — ให้มาสคอตเดินผ่านแทน
        _stroll(draw, s, phase, cycle)
    for i in range(n):
        _slot(draw, i, s.sessions[i], s, phase, cycle, n)
    # ลำดับความสำคัญของพื้นที่ล่าง: การเตือน > โควตา > นาฬิกา
    # โควตาไม่เคยชนะ card เพราะ card คือสิ่งที่ต้องการการกระทำจากผู้ใช้
    if cards := s.shown_cards():
        _cards(draw, cards, s.card_overflow or max(0, len(cards) - CARD_MAX))
    elif usage := s.shown_usage():
        _usage(draw, usage)
        # เซลล์เครื่องอยู่ในตารางเดียวกัน จึงโผล่/หายพร้อมโควตาเสมอ
        if s.machine:
            _machine(draw, *s.machine)
    else:
        _idle_clock(draw, s)
    return img

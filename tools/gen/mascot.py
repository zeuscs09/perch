"""มาสคอต Claude — สร้างเป็น rect list ล้วน ไม่มีบิตแมป

สองมิติที่แยกจากกัน (ตามที่ตกลงใน DESIGN.md):
  mood — ตา + ลำตัว + ขา   บอกว่า "รู้สึกยังไง"
  prop — ของที่ถือ/ลอยเหนือหัว  บอกว่า "ทำอะไรอยู่"

คูณกันได้อิสระ จึงได้ combination เยอะโดยวาดเพิ่มน้อย
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from functools import lru_cache

from .config import L, PAL
from .props import (
    HEAD_CX,
    BOX_X0,
    BOX_X1,
    EYE_MAG,
    EYE_R,
    EYE_S,
    EYE_Y,
    PROPS,
    HAM_STRIKE,
    HAM_WINDUP,
    glasses,
    hammer_anvil,
    hammer_stage,
    magnifier_glass,
)
from .rects import Rect, RectList, bounds, move, scaled

GW = L.mascot.grid_w  # 16.5 — ความกว้างซิลลูเอ็ตรวมแขนสองข้าง
GH = L.mascot.grid_h  # 12

# --- โครงร่าง (พิกัด unit) -------------------------------------------------
# ทุกค่าวัดจากภาพอ้างอิงซึ่งลงตารางสี่เหลี่ยม 12 x 8 ช่องพอดี CELL คือหนึ่งช่องนั้น
# (ลำตัว 8x8 ช่อง · แขนข้างละ 2x2 · ตา 1x1 · ขากว้าง 1 สูง 2)
# ค่าที่ได้จึงเป็นสัดส่วนของภาพอ้างอิงเป๊ะ ไม่ใช่ตัวเลขที่ปรับทีละส่วนจนเพี้ยนสะสม
CELL = 1.5
BODY = (2.0, 0.0, 8 * CELL, 6 * CELL)  # x, y, w, h — บล็อกบน 6 ช่อง ที่เหลือเป็นขา
# แขนยาว 1.5 ช่อง ไม่ใช่ 2 ช่องตามภาพอ้างอิง — จุดเดียวที่จงใจเบี่ยง: ที่ 4 px/unit
# แขนเต็มสองช่องยื่นออกไป 12 px ต่อข้าง ซึ่งอ่านเป็นแขนยาวเก้งก้าง ไม่ใช่ตอแขนแบบต้นฉบับ
NUB_Y, NUB_H, NUB_W = 2 * CELL, 2 * CELL, 1.5 * CELL
# ขาสูงสองช่อง = หนึ่งในสี่ของตัว ตรงกับภาพอ้างอิง
LEG_TOP, LEG_H = 6 * CELL, 2 * CELL
# ขาทั้งสี่กว้างเท่ากันช่องละหนึ่ง อยู่ที่ช่อง 0/2/5/7 ของลำตัว — ช่องกลางจึงกว้างสองช่อง
# ส่วนช่องข้างกว้างช่องเดียว และขาคู่นอกชิดขอบลำตัวพอดี (ทั้งหมดตามภาพอ้างอิง)
LEG_SPANS = tuple((2.0 + i * CELL, CELL) for i in (0, 2, 5, 7))  # x, w
EYE_L = 2.0 + CELL  # ตาข้างขวา (EYE_R/EYE_Y/EYE_S) อยู่ใน props.py — แว่นขยายเล็งไปที่นั่น

FOOT_Y = LEG_TOP + LEG_H  # 12 — ระดับที่มาสคอตยืน

# มุมมนของชิ้นซิลลูเอ็ต — มนทุกมุมของทุกชิ้น เพราะ lv_draw_rect กำหนดรายมุมไม่ได้
CORNER = L.mascot.corner
# แขนซ้อนเข้าไปในลำตัวเท่ารัศมี — พอให้มุมมนด้านในตกอยู่ใต้เนื้อลำตัวซึ่งทาสีเดียวกัน
# ตรงนั้นเป็นกลางลำตัว ไม่ใช่มุม จึงไม่ต้องเผื่อสองเท่าแบบขา
ARM_OVERLAP = CORNER


# --- รูปทรงต่อเอเจนต์ -------------------------------------------------------
@dataclass(frozen=True, slots=True)
class Shape:
    """สิ่งที่ทำให้เอเจนต์แต่ละตัวเป็นคนละสายพันธุ์ — ไม่ใช่แค่คนละสี

    ทุกค่าในนี้อยู่ *ข้างใน* ซิลลูเอ็ตเท่านั้น กรอบนอกของทุกเอเจนต์ต้องเท่ากันเป๊ะ:
    กว้าง 16.5 unit ยอดหัวที่ y = 0 ฝ่าเท้าที่ y = 12 — เพราะ state_box() กับ prop
    ทุกชิ้นวัดจากกรอบนั้น ถ้าเอเจนต์ไหนล้นออกไป ค้อนกับหมวกจะไปเกาะผิดที่ทั้งชุด
    """

    body_h: float
    legs: tuple[tuple[float, float], ...]  # (x, w) ต่อขาหนึ่งข้าง
    arm_y: float
    arm_h: float
    # จอจมสีเข้มที่ตาไปอยู่บนนั้น (x, y, w, h) — None = ลำตัวเรียบแบบ Claude
    screen: tuple[float, float, float, float] | None = None
    # ช่องโหว่กลางลำตัวล่าง (x, y, w) — ความสูงคือส่วนที่เหลือลงไปถึงก้นลำตัว
    #
    # เป็นช่อง *ว่างจริง* ไม่ใช่สี่เหลี่ยมสีพื้นหลังทับ เพราะมาสคอตถูกวาดบนท้องฟ้าที่
    # เปลี่ยนสีตามเวลา สี่เหลี่ยมสีตายตัวจะกลายเป็นรอยปะสีผิดทันทีที่ฟ้าเปลี่ยน
    # ลำตัวจึงถูกประกอบจากคานบนกับเสาสองข้างแทนที่จะเป็นก้อนเดียว
    notch: tuple[float, float, float] | None = None
    # รัศมีมุมของลำตัวกับขา — แขนไม่ใช้ค่านี้ ที่ความกว้าง 6px รัศมีใหญ่จะทำให้แขน
    # อ่านเป็นแคปซูลแทนที่จะเป็นท่อนที่ลบมุม
    corner: float = CORNER

    @property
    def leg_h(self) -> float:
        return FOOT_Y - self.body_h


CLAUDE_SHAPE = Shape(body_h=LEG_TOP, legs=LEG_SPANS, arm_y=NUB_Y, arm_h=NUB_H)

# Codex — จอบนสองขา ไม่ใช่ตัวสี่ขาทาสีใหม่
#
# ตัวแยกที่อ่านออกจากอีกฝั่งห้องคือ *ซิลลูเอ็ต* ไม่ใช่สี: จำนวนขาต่างกัน (2 ไม่ใช่ 4)
# และมีจอจมสีเข้มแทนหน้าเรียบ — สองอย่างนี้เห็นได้ก่อนที่สายตาจะแยกสีฟ้าออกจากสีดิน
#
# ขายาวกว่าของ Claude (3.6 เทียบกับ 3.0) เพราะลำตัวเตี้ยลงมาเพื่อให้จอได้สัดส่วน
# ฝ่าเท้ายังอยู่ที่ 12 เท่าเดิม — ที่เปลี่ยนคือเส้นแบ่งระหว่างตัวกับขา ไม่ใช่ความสูงรวม
CODEX_SHAPE = Shape(
    body_h=8.4,
    legs=((3.6, 3.4), (9.0, 3.4)),
    arm_y=2.6,
    arm_h=2.8,
    screen=(3.1, 0.7, 9.8, 6.0),
)

# Antigravity — ซุ้มโค้งที่มีช่องว่างอยู่ใต้ตัว ตามรูปตัว "A" ในโลโก้ของมัน
#
# ช่องโหว่คือตัวแยกที่แรงที่สุดในสามตัว: Claude กับ Codex เป็นก้อนตัน ตัวนี้มองทะลุได้
# ซึ่งอ่านออกจากอีกฝั่งห้องก่อนที่สายตาจะแยกสีม่วงออกจากสีฟ้าเสียอีก
#
# ขาอยู่ตรงใต้เสาพอดีและกว้างเท่ากัน เสากับขาจึงเป็นขาท่อนเดียวต่อเนื่อง — เคยลองให้ขา
# เยื้องออกด้านนอกตามที่โลโก้ถ่างออก แต่ที่ 4 px/unit มุมมนของขากับของเสาไปกัดกันจน
# เห็นเป็นรอยแหว่ง อ่านเป็นของที่วาดพลาด ไม่ใช่ของที่ตั้งใจ
ANTIGRAV_SHAPE = Shape(
    body_h=8.0,
    legs=((2.0, 3.6), (10.4, 3.6)),
    arm_y=2.6,
    arm_h=2.8,
    notch=(5.6, 4.6, 4.8),
    corner=CORNER * 2.0,
)

SHAPES: dict[str, Shape] = {
    "claude": CLAUDE_SHAPE,
    "codex": CODEX_SHAPE,
    "antigravity": ANTIGRAV_SHAPE,
}

# (ลำตัว, ลำตัวตอนหลับ, จอจม, ตา) — สามค่าแรกตรงกับ clay / clay_dark / clay_sleep ของ Claude
#
# สีตาอยู่ในตารางนี้เพราะมันขึ้นกับว่าตาไปวางอยู่บนอะไร ไม่ใช่รสนิยม: ตาของ Claude อยู่บน
# เนื้อตัวสีสว่างจึงต้องเป็นหมึก ส่วนตาของ Codex อยู่บนจอสีเข้มจึงต้องเรืองแสง
AGENT_SKIN: dict[str, tuple[str, str, str, str]] = {
    "claude": (PAL.clay, PAL.clay_dark, PAL.clay_sleep, PAL.ink),
    "codex": (PAL.codex, PAL.codex_dark, PAL.codex_sleep, PAL.codex_eye),
    "antigravity": (PAL.antigrav, PAL.antigrav_dark, PAL.antigrav_sleep, PAL.ink),
}


# --- ตา --------------------------------------------------------------------
def _eye(x: float, kind: str, look: float, ink: str, scale: float = 1.0) -> RectList:
    """ตาหนึ่งข้าง กล่องฐาน EYE_S x EYE_S ที่ (x, EYE_Y) — ทุกค่าอิงสัดส่วน ไม่ฝังตัวเลขดิบ

    scale > 1 = ตาโตขึ้นโดยยึดจุดกึ่งกลางเดิม (ใช้กับตาที่อยู่หลังเลนส์แว่นขยาย)
    """
    s = EYE_S * scale
    grow = (s - EYE_S) / 2.0
    x, y = x - grow, EYE_Y - grow
    if kind == "sleep":
        return [Rect(x, y + s * 0.62, s, s * 0.3, ink)]
    if kind == "squint":
        return [Rect(x, y + s * 0.34, s, s * 0.42, ink)]
    if kind == "focus":
        m = s * 0.22
        return [Rect(x + m + look, y + m, s - 2 * m, s - 2 * m, ink)]
    if kind == "wide":
        m = s * 0.24
        return [Rect(x - m + look, y - m, s + 2 * m, s + 2 * m, ink)]
    if kind == "blink":
        return [Rect(x, y + s * 0.42, s, s * 0.28, ink)]
    if kind == "happy":  # ^ ^ — ต้องไม่ใช่ขีดแบน ไม่งั้นซ้ำกับตาหลับ
        u = s / 3.0
        return [Rect(x + i * u, y + j * u, u, u, ink) for i, j in ((0, 1), (1, 0), (2, 1))]
    if kind == "dead":  # x_x — บันไดขั้นละ 1 บล็อกทำเป็นกากบาท
        u = s / 3.0
        return [
            Rect(x + i * u, y + j * u, u, u, ink)
            for i, j in ((0, 0), (1, 1), (2, 2), (2, 0), (0, 2))
        ]
    return [Rect(x + look, y, s, s, ink)]  # open


# --- ขา --------------------------------------------------------------------
def _legs(
    gait: str, phase: float, color: str, extra_lift: float = 0.0, shape: Shape = CLAUDE_SHAPE
) -> RectList:
    out: RectList = []
    leg_h = shape.leg_h
    for i, (lx, lw) in enumerate(shape.legs):
        lift = extra_lift
        if gait == "walk":
            # สลับข้างกันยกตามดัชนีคู่/คี่ — สี่ขาได้คู่ทแยง (0,2) กับ (1,3)
            # สองขาได้ซ้ายสลับขวา ซึ่งเป็นการเดินที่ถูกต้องของทั้งสองแบบโดยไม่ต้องแยกโค้ด
            up = (phase < 0.5) == (i % 2 == 0)
            lift += leg_h * 0.34 if up else 0.0
        elif gait == "sit":
            lift += leg_h * 0.66
        # ยืดขึ้นไปซ้อนใต้ลำตัว — ความสูงที่ *เห็น* ยังเป็น leg_h - lift เท่าเดิม
        h = max(leg_h - lift, 0.6)
        # ซ้อนขึ้นไปใต้ลำตัวเป็นสองเท่าของรัศมี — รัศมีที่ใหญ่ขึ้นต้องซ้อนลึกขึ้นตาม
        # ไม่งั้นมุมมนของขากับของลำตัวจะเว้าตรงกันแล้วเกิดรอยแหว่งกลางเส้นที่ควรต่อเนื่อง
        overlap = shape.corner * 2.0
        out.append(
            Rect(lx, shape.body_h - overlap, lw, h + overlap, color, shape.corner)
        )
    return out


# --- ลำตัว -----------------------------------------------------------------
def _arm(x0: float, y: float, h: float, side: float, color: str) -> Rect:
    """ท่อนแขนหนึ่งท่อน กว้าง NUB_W โดยขอบด้านที่หันเข้าตัวยืดเข้าไปซ้อนอีก ARM_OVERLAP

    side -1 = แขนซ้าย (ตัวอยู่ทางขวาของท่อน) / +1 = แขนขวา
    ท่อนนอกของท่ายกมือก็ใช้ตัวเดียวกัน มันจึงซ้อนกับท่อนในแทนที่จะแค่ชนกัน
    """
    w = NUB_W + ARM_OVERLAP
    x = x0 if side < 0 else x0 - ARM_OVERLAP
    return Rect(x, y, w, h, color, CORNER)


def _body(
    color: str,
    arm_dy: tuple[float, float] = (0.0, 0.0),
    arm_out: float = 0.0,
    shape: Shape = CLAUDE_SHAPE,
    screen_color: str | None = None,
) -> RectList:
    """ลำตัวกับแขนสองข้างในสัดส่วนปกติ — การยุบตัวทำทีหลังด้วย _squashed()

    arm_dy เลื่อนแขน (nub) ทีละข้าง — ท่าพิมพ์ใช้ค่าคนละเครื่องหมายจึงอ่านเป็นสลับมือ
    arm_out > 0 = แขนเป็นสองท่อนลดหลั่นออกนอกตัว (ท่ายกมือค้าง) แทนที่จะเป็นก้อนเดียว
    ก้อนเดียวที่เลื่อนขึ้นเฉยๆ อ่านเป็น "ไหล่สูงขึ้น" ไม่ใช่ "ยกมือ" — ต้องมีท่อนที่เยื้อง
    ออกไปนอกซิลลูเอ็ต สายตาถึงจะเห็นเป็นแขนที่กางขึ้น
    """
    bx, by, bw = BODY[0], BODY[1], BODY[2]
    bh = shape.body_h
    r = shape.corner
    if shape.notch is None:
        out = [Rect(bx, by, bw, bh, color, r)]
    else:
        # ซุ้ม: คานบน + เสาสองข้าง โดยช่องตรงกลางไม่มีอะไรวาดทับเลย
        nx, ny, nw = shape.notch
        out = [
            Rect(bx, by, bw, ny, color, r),
            Rect(bx, ny, nx - bx, bh - ny, color, r),
            Rect(nx + nw, ny, bx + bw - nx - nw, bh - ny, color, r),
        ]
    # จอจมวาดทับลำตัวทันที ก่อนแขน — ตาจะมาทับอีกทีตอนท้าย build()
    if shape.screen is not None and screen_color is not None:
        sx, sy, sw, sh = shape.screen
        out.append(Rect(sx, sy, sw, sh, screen_color, r * 0.6))
    arm_y, arm_h = shape.arm_y, shape.arm_h
    if arm_out == 0.0:
        out.append(_arm(bx - NUB_W, arm_y + arm_dy[0], arm_h, -1.0, color))
        out.append(_arm(bx + bw, arm_y + arm_dy[1], arm_h, 1.0, color))
        return out
    h = arm_h * 0.8  # แต่ละท่อนเตี้ยกว่าแขนปกติ สองท่อนรวมกันจึงไม่ยาวเกินสัดส่วนเดิม
    for side, x0, dy in ((-1.0, bx - NUB_W, arm_dy[0]), (1.0, bx + bw, arm_dy[1])):
        # ท่อนใน — ติดลำตัว ยกขึ้นครึ่งทางของท่อนนอก จึงอ่านเป็นแขนที่เอียงขึ้น
        out.append(_arm(x0, arm_y + dy + h * 0.5, h, side, color))
        out.append(_arm(x0 + side * arm_out, arm_y + dy, h, side, color))  # ท่อนนอก
    return out


def _squashed(rects: RectList, squash: float) -> RectList:
    """ยุบทั้งตัวรอบฝ่าเท้า — ลำตัว ขา และตา ต้องยุบเป็นก้อนเดียวกัน

    ถ้ายุบเฉพาะลำตัว ก้นลำตัวจะค้างอยู่ที่เดิมและขายาวเท่าเดิม อ่านเป็นกล่องเตี้ยลง
    บนขาชุดเดิม ไม่ใช่ตัวที่โดนกระแทก ฝ่าเท้าไม่ขยับเพราะระดับที่ยืนต้องคงที่
    """
    if squash == 0.0:
        return rects
    return scaled(rects, 1.0 + squash * 0.45, 1.0 - squash, HEAD_CX, FOOT_Y)


# --- อารมณ์ ----------------------------------------------------------------
@dataclass(frozen=True, slots=True)
class Mood:
    eye: str = "open"
    gait: str = "stand"
    squash: float = 0.0
    bob: float = 0.0  # ระยะแกว่งขึ้นลง (unit)
    bob_hz: float = 1.0
    shake: float = 0.0
    look: float = 0.0
    scan: float = 0.0  # กวาดสายตาซ้าย->ขวาแล้ววกกลับ (unit) — ท่าอ่านโค้ด
    arm: float = 0.0   # ระยะที่แขนขยับสลับข้าง (unit) — ท่าพิมพ์
    arm_up: float = 0.0  # ระยะที่แขนยกค้างพร้อมกันสองข้าง (unit) — ท่าเพ่งพลัง
    arm_out: float = 0.0  # ระยะที่ท่อนนอกของแขนเยื้องออกนอกตัว (unit) — ใช้คู่กับ arm_up
    blink: bool = True  # ตาลืมเท่านั้นที่กะพริบได้
    strike: bool = False  # ใช้จังหวะทุบของ props.hammer_stage() แทนการกระเด้งเป็นคลื่น
    sink: float = 0.0  # >0 = จมลงดินตามความคืบหน้าของ phase (ท่ามุดหาย)


# ช่วง phase ที่ตากะพริบ — สั้นมากโดยตั้งใจ กะพริบนานกว่านี้จะดูเหมือนง่วง
BLINK_FROM, BLINK_TO = 0.88, 0.94
# กะพริบทุกกี่รอบลูป — ลูปเดียวยาวราว 1 วินาที กะพริบทุกวินาทีจะดูกระวนกระวาย
BLINK_EVERY = 4


# bob วัดเป็น unit — 1 unit = unit_px พิกเซล ต่ำกว่า 0.5 unit จะมองแทบไม่เห็นบนจอ
MOODS: dict[str, Mood] = {
    "idle":      Mood(eye="open",   bob=0.75, bob_hz=1.0),
    "working":   Mood(eye="focus",  bob=0.50, bob_hz=2.4, squash=0.03),
    # ท่านั่งพิมพ์ — ตัวแทบไม่กระเด้ง เพราะสัญญาณอยู่ที่สายตาที่กวาดอ่านกับแขนที่พิมพ์
    "typing":    Mood(eye="focus",  bob=0.30, bob_hz=2.0, squash=0.03, scan=1.0,
                      arm=0.70),
    # ท่าทุบ — ไม่กระเด้งเป็นคลื่น แต่ยืดตัวตอนเงื้อและยุบตัวตอนกระแทกตามจังหวะค้อน
    "hammering": Mood(eye="focus",  strike=True, bob=0.35, bob_hz=2.0),
    "walking":   Mood(eye="open",   gait="walk", bob=0.75, bob_hz=2.0),
    "waiting":   Mood(eye="open",   bob=1.00, bob_hz=0.7, look=0.40),
    "sleeping":  Mood(eye="sleep",  gait="sit", squash=0.10, bob=0.50, bob_hz=0.35,
                      blink=False),
    "alert":     Mood(eye="wide",   bob=0.90, bob_hz=3.2, shake=0.20, blink=False),
    "celebrate": Mood(eye="happy",  bob=1.25, bob_hz=2.6, squash=-0.05, blink=False),
    "error":     Mood(eye="dead",   gait="sit", squash=0.12, shake=0.08, blink=False),
    # ท่าส่งสัญญาณ — ตาปกติ ไม่เบิกกว้าง (ตาโตอ่านเป็นตกใจ ซึ่งเป็นสารของ alert)
    # สารของท่านี้อยู่ที่เสาอากาศกับมือที่ยกค้าง ไม่ใช่ที่หน้า
    # แขนยกค้างนิ่งพร้อมกันสองข้างแบบเพ่งพลัง — ไม่โยก เพราะการโยกอ่านเป็นโบกมือ
    # ท่อนนอกเยื้องออกนอกตัว จึงเห็นเป็นมือที่ยกขึ้นจริง ไม่ใช่ไหล่ที่สูงขึ้นเฉยๆ
    "signalling": Mood(eye="open",   bob=0.45, bob_hz=1.3, arm_up=1.9, arm_out=0.9),
    # ท่าเปลี่ยนผ่าน — phase ทำหน้าที่เป็นความคืบหน้า 0→1 ไม่ใช่ลูปวน
    "entering":  Mood(eye="open",   gait="walk", bob=1.00, bob_hz=4.0),
    "leaving":   Mood(eye="squint", gait="sit", squash=0.30, sink=1.0, blink=False),
}


# --- visual state = mood + prop ---------------------------------------------
# enum นี้ต้องตรงกับ firmware ทุกตัว (daemon ส่งชื่อพวกนี้มาบน BLE)
STATES: dict[str, tuple[str, str | None]] = {
    "idle":      ("idle", None),
    "reading":   ("working", "magnifier"),
    "writing":   ("typing", "laptop"),
    "building":  ("hammering", "hammer"),
    "searching": ("working", "globe"),
    "thinking":  ("idle", "dots"),
    "waiting":   ("waiting", "clock"),
    "sleeping":  ("sleeping", "zzz"),
    "alert":     ("alert", "bang"),
    "celebrate": ("celebrate", "sparkle"),
    "error":     ("error", None),
    "entering":  ("entering", None),
    "leaving":   ("leaving", None),
    # ต่อท้ายเสมอ — ลำดับใน dict นี้คือค่าตัวเลขของ enum ใน layout.h
    "conducting": ("working", "crew"),
    "beacon": ("signalling", "beacon"),
}


# prop ที่ลอยนิ่งอยู่กับที่ ไม่เด้งขึ้นลงตามตัว — ตัวเด้งผ่านมันไปเฉยๆ
# ลูกโลกกับนาฬิกาใหญ่และคร่อมหัวอยู่แล้ว ถ้าเด้งตามตัวด้วยจะอ่านเป็นก้อนที่ติดหัวอยู่
# แต่ถ้ามันนิ่ง ตัวที่ขยับผ่านจะอ่านเป็น "ของที่ลอยอยู่" และการหมุน/เดินของเข็มก็เด่นขึ้นด้วย
# ทั้งคู่ยังมีขอบล่างจ่อตาอยู่แล้ว การเด้งลงอีกจะกินตาด้วย
FLOATING_PROPS = frozenset({"globe", "clock"})

# ท่าที่มีของประกอบเยอะจนแน่นช่อง — ย่อลงเล็กน้อยเพื่อให้ยังมีที่หายใจรอบตัว
# ย่อทั้งฉาก (ตัว + หมวก + ค้อน + แท่น) พร้อมกัน สัดส่วนภายในจึงไม่เพี้ยน
STATE_SCALE: dict[str, float] = {"building": 0.875}

# สถานะที่มาสคอตสวมแว่น — แว่นไม่ใช่ prop เพราะช่อง prop ถูกแล็ปท็อปจองไปแล้ว
# และแว่นต้องยุบ/เลื่อนไปกับตา ไม่ใช่กับชุด prop
GLASSES_STATES = frozenset({"writing"})


def _skin(connected: bool, state: str, agent: str = "claude") -> tuple[str, str, str]:
    """คืน (สีตัว, สีตา, สีจอจม)

    สีจอถูกคืนมาเสมอแม้เอเจนต์นั้นจะไม่มีจอ — `_body()` จะไม่ใช้มันเองถ้า shape.screen
    เป็น None ผู้เรียกจึงไม่ต้องรู้ว่าเอเจนต์ไหนมีจอบ้าง
    """
    base, dark, sleep, eye = AGENT_SKIN.get(agent, AGENT_SKIN["claude"])
    if not connected:
        # จอดับสนิท ไม่ใช่แค่เทาลง — ถ้าจอเป็น gray_dark เท่ากับสีตา ตาจะหายไปทั้งดวง
        # (มองไม่เห็นบนภาพนิ่งของสถานะอื่น เพราะมีแต่ตัวที่มีจอเท่านั้นที่โดน)
        return PAL.gray, PAL.gray_dark, PAL.ink
    if state == "sleeping":
        # หรี่ลงเล็กน้อยเท่านั้น — ถ้าเปลี่ยนสีแรงจะไปชนกับสัญญาณ "หลุดการเชื่อมต่อ"
        # ตัวที่มีจอได้ภาษาของตัวเองมาฟรี: ลำตัวหรี่ลงจนเกือบเท่าจอ = จอที่กำลังจะดับ
        return dark, eye, sleep
    return base, eye, sleep


def build(
    state: str,
    phase: float = 0.0,
    connected: bool = True,
    cycle: int = 0,
    agent: str = "claude",
) -> RectList:
    """สร้าง rect list ของมาสคอตหนึ่งตัว เรียงจากหลังไปหน้า

    phase  ความคืบหน้าในลูปอนิเมชัน 0..1 (ลูปหนึ่งราว 1 วินาที)
    cycle  ลูปที่เท่าไรแล้ว — ใช้กับจังหวะที่ช้ากว่าหนึ่งลูป เช่นการกะพริบตา
    agent  ตัวไหนใน SHAPES — คนละรูปทรง ไม่ใช่แค่คนละสี

    พิกัดอยู่ในตาราง 16.5 x 12 unit ฝ่าเท้าอยู่ที่ y = 12 เท่ากันทุกเอเจนต์
    """
    if state not in STATES:
        raise KeyError(f"unknown visual state: {state!r}")
    mood_name, prop_name = STATES[state]
    m = MOODS[mood_name]
    skin, ink, screen = _skin(connected, state, agent)
    shape = SHAPES.get(agent, CLAUDE_SHAPE)

    # ปัด dy ลงตารางพิกเซลก่อน ไม่งั้นแต่ละ rect ปัดคนละทางแล้วเห็นแค่เส้นขอบกระพริบ
    # แทนที่จะเห็นทั้งตัวเลื่อนขึ้นลงพร้อมกัน
    dy = -abs(math.sin(phase * math.pi * m.bob_hz)) * m.bob
    # ท่าทุบเดินตาม timeline ของค้อน ไม่ใช่คลื่น: ยืดตัวตอนเงื้อ ยุบตัวตอนกระแทก
    # (ยุบด้วย squash ซึ่งยึดฝ่าเท้าไว้ ไม่ใช่ dy บวก ที่จะดันขาจมลงใต้พื้น)
    stage = hammer_stage(phase) if m.strike else -1
    if stage == HAM_WINDUP:  # เงื้อค้าง — ตัวยกลอยขึ้นทั้งตัว
        dy = -0.5
    elif stage == HAM_STRIKE:  # แรงลง — ตัวหยุดนิ่งที่พื้น ที่ยุบคือ squash ไม่ใช่ dy
        dy = 0.0
    dy = round(dy * L.slots.unit_px) / L.slots.unit_px
    dx = math.sin(phase * math.pi * 12.0) * m.shake

    # ท่ามุดหาย: ยิ่ง phase เดินหน้า ยิ่งแบนลงติดพื้นและขาหด
    squash = m.squash + m.sink * phase * 0.60
    if m.strike:
        squash += {HAM_WINDUP: -0.04, HAM_STRIKE: 0.15}.get(stage, 0.03)
    # แขนพิมพ์ — แขนข้างลำตัวสลับขึ้นลงสองรอบต่อลูป ไม่มีแขนพาดหน้าแล็ปท็อป
    # (แขนที่เอื้อมมาข้างหน้าอ่านเป็น "กดจอ" ไม่ใช่ "พิมพ์อยู่หลังจอ")
    arm = m.arm * math.sin(phase * math.pi * 4.0)
    arm_lift = m.arm_up  # ยกค้างนิ่ง — ถ้าขยับขึ้นลงจะอ่านเป็นโบกมือ ไม่ใช่ยกค้างเพ่งพลัง
    silhouette = _squashed(
        _body(skin, (arm - arm_lift, -arm - arm_lift), m.arm_out, shape, screen)
        + _legs(m.gait, phase, skin, m.sink * phase * shape.leg_h * 0.9, shape),
        squash,
    )
    silhouette = move(silhouette, dx, dy)

    eye_kind = m.eye
    if stage == HAM_STRIKE:  # หลับตาเบ่งตอนแรงลง — เฟรมสั้นๆ นี้คือที่ที่น้ำหนักอยู่
        eye_kind = "squint"
    if m.blink and cycle % BLINK_EVERY == BLINK_EVERY - 1 and BLINK_FROM <= phase < BLINK_TO:
        eye_kind = "blink"

    look = m.look * math.sin(phase * math.pi * 2.0)
    # กวาดสายตา: ไล่จากซ้ายไปขวาแล้ววกกลับทันที = อ่านทีละบรรทัด ไม่ใช่ส่ายไปมา
    # สองบรรทัดต่อลูป — ช้ากว่านี้จะอ่านเป็นเหม่อ ไม่ใช่กำลังไล่โค้ด
    look += m.scan * ((phase * 2.0 % 1.0) - 0.5) * 2.0
    mag = EYE_MAG if prop_name == "magnifier" else 1.0  # ตาข้างที่อยู่หลังเลนส์
    eyes = _eye(EYE_L, eye_kind, look, ink) + _eye(EYE_R, eye_kind, look, ink, mag)
    if state in GLASSES_STATES:  # แว่นวาดหลังตา กรอบจึงทับขอบตา และยุบไปกับตาชุดเดียวกัน
        eyes += glasses(EYE_L, connected)
    eyes = move(_squashed(eyes, squash), dx, dy)  # ตายุบไปกับลำตัว ไม่ใช่ค้างอยู่บนหน้าที่เตี้ยลง

    out: RectList = list(silhouette)
    if prop_name == "hammer":  # แท่นวางอยู่กับพื้น จึงไม่เลื่อนตาม dy ที่ลำตัวขยับ
        out += hammer_anvil(phase, connected)
    if prop_name == "magnifier":
        # กระจกอยู่ใต้ตา ขอบเลนส์อยู่บนตา — แต่ทั้งคู่คือของชิ้นเดียวกัน จึงห้ามยุบตามลำตัว
        # เคยยุบตาม (ตอนนั้นดูเหมือนถูก เพราะกระจกเกาะหน้ามาสคอต) แล้วท่าที่มี squash > 0
        # ดันกระจกลงราว 1.5px ในขณะที่วงแหวนอยู่ที่เดิม เห็นเป็นเนื้อลำตัวโผล่ใต้ขอบบนของวง
        out += move(magnifier_glass(phase, connected), dx, dy)
    out += eyes
    if prop_name:
        # หมวกกับค้อนอยู่ติดตัว จึงต้องยุบลงพร้อมลำตัวเหมือนตา ไม่ใช่ค้างอยู่ที่เดิม
        # (prop อื่นวางอยู่หน้าลำตัวหรือลอยเหนือหัว ซึ่งไม่ได้เกาะกับความสูงของตัว)
        # หมวกกับค้อนอยู่ติดตัว จึงต้องต่ำลงพร้อมหัวที่ยุบ ไม่ใช่ค้างอยู่ที่เดิม
        # เลื่อนอย่างเดียวไม่ยุบตาม: หมวกแข็งและค้อนเป็นเหล็ก จะแบนไปกับตัวไม่ได้
        prop_dy = dy + (FOOT_Y * squash if m.strike else 0.0)
        if prop_name in FLOATING_PROPS:
            prop_dy = 0.0
        out += move(PROPS[prop_name](phase, connected), dx, prop_dy)
    if state in STATE_SCALE:  # ย่อทั้งฉากโดยยึดฝ่าเท้าและกึ่งกลางลำตัว
        k = STATE_SCALE[state]
        out = scaled(out, k, k, HEAD_CX, FOOT_Y)
    return out


@lru_cache(maxsize=None)
def state_box(state: str) -> tuple[float, float, float, float]:
    """กรอบจริงของสถานะหนึ่ง รวมทุกเฟรมของอนิเมชัน

    ท่าที่ไม่มี prop ถือ จะแคบกว่าท่าที่มี — ถ้าจัดกึ่งกลางด้วยกรอบรวม
    ตัวละครจะเอียงไปทางซ้ายในท่าที่ไม่มี prop
    """
    acc: RectList = []
    for i in range(12):
        acc += build(state, i / 12.0)
    return bounds(acc)


def build_centered(
    state: str,
    phase: float = 0.0,
    connected: bool = True,
    cycle: int = 0,
    agent: str = "claude",
) -> RectList:
    """เหมือน build() แต่เลื่อนแนวนอนให้กรอบของสถานะนั้นอยู่กึ่งกลางกรอบวาดมาตรฐาน

    ระดับฝ่าเท้าไม่ขยับ — จัดกึ่งกลางเฉพาะแกน x

    `state_box()` ไม่รับ agent โดยตั้งใจ: ระยะเลื่อนต้องเป็นค่าเดียวกันทุกเอเจนต์
    ไม่งั้นการสลับเอเจนต์ในช่องเดิมจะทำให้ทั้งตัวกระตุกไปด้านข้าง และฝั่ง firmware
    ซึ่งเก็บตาราง center_dx ไว้ชุดเดียวจะไม่ตรงกับที่นี่ — `agents_share_one_box()`
    คือตัวที่คอยยืนยันว่าข้อตกลงนี้ยังจริงอยู่
    """
    bx0, _, bx1, _ = state_box(state)
    dx = (BOX_X0 + BOX_X1) / 2.0 - (bx0 + bx1) / 2.0
    return move(build(state, phase, connected, cycle, agent), dx, 0.0)


def agents_share_one_box() -> list[str]:
    """คืนรายการข้อผิดพลาด — ว่างแปลว่าทุกเอเจนต์ยังกินพื้นที่แนวนอนเท่ากัน

    รูปทรงต่อเอเจนต์แก้ได้เฉพาะ *ข้างใน* ซิลลูเอ็ต ถ้าตัวไหนล้นออกด้านข้าง การจัด
    กึ่งกลางกับเงาใต้เท้าจะเพี้ยนเงียบๆ ทีละนิดโดยไม่มีอะไรพัง — ต้องจับที่นี่

    ดูเฉพาะแกน x เพราะมีแค่แกนนั้นที่ถูกใช้จริง (`build_centered`, `screen.py`,
    และ `pch_mascot_center_dx` ฝั่ง firmware ล้วนอ่านแต่ bx0/bx1)

    ขอบล่างต่างกันได้และต่างจริงในท่านั่ง/ท่าหลับ: ขาหดเป็น *สัดส่วน* ของความยาวขา
    ตัวที่ขายาวกว่าจึงหดได้ลึกกว่า นั่นคือท่านั่งของสัตว์คนละชนิด ไม่ใช่ความผิดพลาด
    """
    errs: list[str] = []
    for state in STATES:
        wx0, _, wx1, _ = bounds([r for i in range(12) for r in build(state, i / 12.0)])
        for agent in SHAPES:
            if agent == "claude":
                continue
            gx0, _, gx1, _ = bounds(
                [r for i in range(12) for r in build(state, i / 12.0, agent=agent)]
            )
            if abs(wx0 - gx0) > 1e-6 or abs(wx1 - gx1) > 1e-6:
                errs.append(
                    f"{agent}/{state}: x {gx0:.3f}..{gx1:.3f}"
                    f" != claude {wx0:.3f}..{wx1:.3f}"
                )
    return errs


def all_states() -> list[str]:
    return list(STATES)

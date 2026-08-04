#!/usr/bin/env python3
"""เรนเดอร์ทุกสถานะและจอทั้งใบเป็น PNG/GIF — dev loop ที่ไม่ต้องแตะบอร์ด

    python3 tools/preview.py           สร้างทุกอย่างลง out/
    python3 tools/preview.py --sheet   เฉพาะ contact sheet
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen import mascot, screen  # noqa: E402
from gen.config import L, PAL, REPO_DIR  # noqa: E402
from gen.props import BOX_X0, BOX_X1, BOX_Y0, BOX_Y1  # noqa: E402
from gen.render import quantize565, render_rects  # noqa: E402

OUT = REPO_DIR / "out"
# BOX_Y1 คือระดับฝ่าเท้าพอดี และไม่มีอะไรยื่นต่ำกว่านั้นอีกแล้ว
BOX = (BOX_X0, BOX_Y0, BOX_X1, BOX_Y1)
SESSION_WINDOW = L.usage.session_window
WEEKLY_WINDOW = L.usage.weekly_window
FRAMES = 12  # เฟรมต่อหนึ่งลูป (~1 วินาที)
LOOPS = 4  # GIF ยาวหลายลูป ไม่งั้นจะไม่มีวันเห็นการกะพริบตา
# ฉากมาสคอตเดินเล่น: หนึ่งเที่ยว = (320 + 2*96) / 34 + 2.5 ~ 17.6 วินาที
STROLL_LOOPS = 18


def _cell(state: str, phase: float, px: int, connected: bool = True,
          cycle: int = 0) -> Image.Image:
    return render_rects(
        mascot.build_centered(state, phase, connected, cycle), px, BOX, PAL.bg_slot
    )


def contact_sheet(px: int = 7, cols: int = 6) -> Image.Image:
    """ทุกสถานะเรียงในภาพเดียว — ใช้ตัดสินว่ามาสคอตสื่ออารมณ์ได้จริงไหม"""
    states = mascot.all_states()
    cw = round((BOX_X1 - BOX_X0) * px)
    ch = round((BOX_Y1 - BOX_Y0) * px)
    pad, label_h = 8, 16
    rows = (len(states) + cols - 1) // cols
    W = cols * (cw + pad) + pad
    H = rows * (ch + label_h + pad) + pad
    sheet = Image.new("RGB", (W, H), quantize565(PAL.bg))
    draw = ImageDraw.Draw(sheet)
    for i, st in enumerate(states):
        cx = pad + (i % cols) * (cw + pad)
        cy = pad + (i // cols) * (ch + label_h + pad)
        sheet.paste(_cell(st, 0.25, px), (cx, cy))
        draw.text((cx + cw / 2, cy + ch + label_h / 2), st, font=screen.font(12),
                  fill=quantize565(PAL.text), anchor="mm")
    return sheet


def state_gif(state: str, px: int = 7, connected: bool = True) -> list[Image.Image]:
    return [
        _cell(state, (f % FRAMES) / FRAMES, px, connected, f // FRAMES)
        for f in range(FRAMES * LOOPS)
    ]


SCENES: dict[str, screen.Screen] = {
    "busy": screen.Screen(
        sessions=[
            screen.Session("perch", "writing", 0.0),
            screen.Session("perch", "building", 0.3),
            screen.Session("sprite-gen", "reading", 0.6),
        ],
        overflow=3,
        cards=[
            screen.Card("perch", "needs permission to run git push", "alert"),
            screen.Card("infra-scripts", "Stopped - waiting for your reply", "info"),
            screen.Card("sprite-gen", "Build finished, 0 warnings", "done"),
        ],
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 88, 42 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 61, 3 * 86400),
        ],
    ),
    "idle": screen.Screen(
        sessions=[screen.Session("perch", "sleeping", 0.0)],
        clock="02:14",
    ),
    # โควตาปกติ — สภาพที่จอจะเป็นเกือบตลอดเวลาที่ไม่มีอะไรต้องเตือน
    "usage": screen.Screen(
        sessions=[
            screen.Session("perch", "writing", 0.0),
            screen.Session("docs", "reading", 0.4),
        ],
        clock="17:04",
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 35, 3 * 3600 + 5 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 48, 31 * 3600),
            # ช่องที่ 3 ของตาราง — Codex ส่งมาแค่หน้าต่างสัปดาห์หน้าต่างเดียว
            screen.Usage("Codex", WEEKLY_WINDOW, 41, 5 * 86400),
        ],
        place="Bangkok",
        temperature=31,
        weather="cloudy",
        machine=(23, 61),
    ),
    # ใกล้เต็มทั้งคู่ + ใช้เร็วกว่าเวลา (ขีด pace อยู่ซ้ายของเนื้อแถบ)
    # ฝน: พิสูจน์ว่าแกนอากาศทำงาน — ฟ้าหม่น เมฆหนา ดาว/ดวงหาย มีเส้นฝน
    "weather_rain": screen.Screen(
        sessions=[screen.Session("berlin", "writing")],
        clock="14:32",
        place="Bangkok",
        temperature=27,
        weather="rain",
    ),
    "usage_hot": screen.Screen(
        sessions=[screen.Session("perch", "building", 0.0)],
        clock="09:41",
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 92, 4 * 3600 + 20 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 71, 2 * 86400 + 5 * 3600),
        ],
    ),
    # หน้าต่างหมุนไปแล้ว + weekly หายไปทั้งตัว — ทั้งคู่ต้องเป็น `--` ห้ามเดา
    "usage_unknown": screen.Screen(
        sessions=[screen.Session("perch", "idle", 0.0)],
        clock="06:20",
        usage=[
            screen.Usage("Current", SESSION_WINDOW, None, 0),
            screen.Usage("Weekly", WEEKLY_WINDOW, None, None),
        ],
    ),
    "done": screen.Screen(
        sessions=[
            screen.Session("perch", "celebrate", 0.0),
            screen.Session("docs", "idle", 0.4),
        ],
        cards=[screen.Card("perch", "Build finished, 0 warnings", "done")],
    ),
    # มีทั้งการ์ดและตัวเลขโควตาค้างอยู่ในมือ แต่ต้องไม่ขึ้นจอสักอย่าง — หลุดลิงก์แล้ว
    # ไม่มีใครรับรองว่ายังจริง เหลือนาฬิกาที่หรี่เป็นเทาบอกว่าเป็นเวลาล่าสุดที่รู้
    "offline": screen.Screen(
        sessions=[
            screen.Session("perch", "idle", 0.0),
            screen.Session("docs", "idle", 0.5),
        ],
        connected=False,
        cards=[screen.Card("perch", "Needs your answer", "alert")],
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 43, 1 * 3600 + 40 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 8, 5 * 86400 + 8 * 3600),
        ],
    ),
    # BLE หลุด บอร์ดขึ้นเน็ตแล้วแต่ Mac ยังหาไม่เจอ — ข้อมูลบนจอตายเหมือน "offline"
    # ต่างกันที่แถบบน ซึ่งบอกที่อยู่ให้ผู้ใช้เอาไปกรอกในหน้าตั้งค่าเมื่อ mDNS ไม่ผ่าน
    "wifi": screen.Screen(
        sessions=[screen.Session("perch", "idle", 0.0)],
        connected=False,
        wifi=True,
        ip="192.168.1.42",
        cards=[screen.Card("perch", "Needs your answer", "alert")],
    ),
    # BLE หลุดแต่ snapshot ยังเดินทางมาทาง LAN — ข้อมูลสดทั้งจอ ไอคอนเป็นคลื่น WiFi
    "lan": screen.Screen(
        sessions=[
            screen.Session("perch", "writing", 0.0),
            screen.Session("docs", "idle", 0.5),
        ],
        connected=True,
        ble=False,
        wifi=True,
        ip="192.168.1.42",
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 43, 1 * 3600 + 40 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 8, 5 * 86400 + 8 * 3600),
        ],
    ),
    # ไม่มี session เลย — มาสคอตเดินข้ามแถบ slot ที่ว่างอยู่
    "empty": screen.Screen(
        sessions=[],
        clock="14:22",
        date="Mon 27 Jul",
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 35, 3 * 3600 + 5 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 48, 31 * 3600),
            # ช่องที่ 3 ของตาราง — Codex ส่งมาแค่หน้าต่างสัปดาห์หน้าต่างเดียว
            screen.Usage("Codex", WEEKLY_WINDOW, 41, 5 * 86400),
        ],
        place="Bangkok",
        temperature=31,
        weather="cloudy",
        machine=(23, 61),
    ),
    "waiting": screen.Screen(
        sessions=[
            screen.Session("perch", "waiting", 0.0),
            screen.Session("perch", "searching", 0.5),
            screen.Session("sprite-gen", "alert", 0.25),
        ],
        cards=[
            screen.Card("sprite-gen", "Stopped: test suite failed (3 failing)", "alert"),
            screen.Card("perch", "needs permission to write layout.h", "info"),
        ],
    ),
}


# ฉากตรวจท้องฟ้า — ไม่มี session เลย ซึ่งเป็นสภาพที่จอเป็นเกือบตลอดเวลา
# และเป็นตอนที่ฟ้าโล่งที่สุด ส่วนตอนถูกมาสคอตบังดูได้จาก screen_busy/waiting
SKY_CLOCKS = {"dawn": "05:40", "day": "12:00", "dusk": "18:10", "night": "02:14"}


def sky_scene(clock: str) -> screen.Screen:
    return screen.Screen(
        sessions=[],
        clock=clock,
        date="Mon 27 Jul",
        usage=[
            screen.Usage("Current", SESSION_WINDOW, 35, 3 * 3600 + 5 * 60),
            screen.Usage("Weekly", WEEKLY_WINDOW, 48, 31 * 3600),
            # ช่องที่ 3 ของตาราง — Codex ส่งมาแค่หน้าต่างสัปดาห์หน้าต่างเดียว
            screen.Usage("Codex", WEEKLY_WINDOW, 41, 5 * 86400),
        ],
        place="Bangkok",
        temperature=31,
        weather="cloudy",
        machine=(23, 61),
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sheet", action="store_true", help="เฉพาะ contact sheet")
    ap.add_argument("--scale", type=int, default=3, help="ขยายภาพจอตอน export")
    args = ap.parse_args()

    OUT.mkdir(exist_ok=True)
    (OUT / "anim").mkdir(exist_ok=True)

    sheet = contact_sheet()
    sheet.save(OUT / "states.png")
    print(f"states.png            {sheet.width}x{sheet.height}  {len(mascot.all_states())} states")
    if args.sheet:
        return

    for st in mascot.all_states():
        frames = state_gif(st)
        frames[0].save(OUT / "anim" / f"{st}.gif", save_all=True,
                       append_images=frames[1:], duration=90, loop=0)
    print(f"anim/*.gif            {len(mascot.all_states())} ไฟล์")

    for name, sc in SCENES.items():
        img = screen.render(sc, 0.25)
        img.save(OUT / f"screen_{name}.png")
        big = img.resize((img.width * args.scale, img.height * args.scale), Image.NEAREST)
        big.save(OUT / f"screen_{name}@{args.scale}x.png")
        # ฉากที่ไม่มี session ใช้ลูปยาวกว่า — เที่ยวเดินหนึ่งรอบกินเวลาหลายสิบวินาที
        # ถ้าตัดที่ 4 ลูปเหมือนฉากอื่นจะเห็นแค่มาสคอตขยับทีละไม่กี่พิกเซล
        loops = STROLL_LOOPS if not sc.sessions else LOOPS
        frames = [
            screen.render(sc, (f % FRAMES) / FRAMES, f // FRAMES)
            for f in range(FRAMES * loops)
        ]
        frames[0].save(OUT / f"screen_{name}.gif", save_all=True,
                       append_images=frames[1:], duration=90, loop=0)
    print(f"screen_*.png/gif      {len(SCENES)} ฉาก  (320x240)")

    for name, clock in SKY_CLOCKS.items():
        sc = sky_scene(clock)
        # cycle 6 = จังหวะที่มาสคอตเดินมาถึงกลางจอพอดี — ที่ cycle 0 มันยังอยู่นอกจอ
        # แล้วภาพตรวจจะไม่มีสิ่งที่ต้องตรวจ (มาสคอตยืนบนพื้น + contrast กับฟ้า)
        img = screen.render(sc, 0.25, 6)
        img.save(OUT / f"sky_{name}.png")
        big = img.resize((img.width * args.scale, img.height * args.scale), Image.NEAREST)
        big.save(OUT / f"sky_{name}@{args.scale}x.png")
        frames = [
            screen.render(sc, (f % FRAMES) / FRAMES, f // FRAMES)
            for f in range(FRAMES * STROLL_LOOPS)
        ]
        frames[0].save(OUT / f"sky_{name}.gif", save_all=True,
                       append_images=frames[1:], duration=90, loop=0)
    print(f"sky_*.png/gif         {len(SKY_CLOCKS)} ช่วงเวลา")
    print(f"\nout/ -> {OUT}")


if __name__ == "__main__":
    main()

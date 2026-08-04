#!/usr/bin/env python3
"""ไอคอนแอป — สองชุดในไฟล์เดียว: ภาพโลโก้สำหรับขนาดใหญ่ ภาพวาดใหม่สำหรับขนาดเล็ก

`.icns` เก็บภาพแยกต่อขนาดได้ ขนาดเล็กจึงไม่ใช่โลโก้ที่ย่อลง แต่เป็นภาพที่ตัดทุกอย่างออก
จนเหลือสิ่งที่ยังอ่านได้ — วัดจากของจริง: **ที่ 32 px สามตัวเละเป็นก้อนสีเดียวกัน**
≤64 px จึงเหลือมาสคอตตัวเดียวบนคอน ส่วน ≥128 px ใช้โลโก้เต็มที่มีครบสามสายพันธุ์

ทั้งสองชุดใช้พื้นหลังโค้งมนสีเดียวกัน คอนเส้นเดียวกัน และสีเดียวกัน — จุดตัด 64→128
จึงอ่านเป็น "เพื่อนมาเพิ่ม" ไม่ใช่ "ไอคอนเปลี่ยนเป็นของอื่น" ซึ่งเป็นอาการที่แย่กว่าไอคอนเบลอ

ต้นทางขนาดใหญ่คือ `docs/images/perch-logo.png` ซึ่งสร้างจาก `tools/make_logo.py`
แล้วให้โมเดลลงวัสดุ — อ่านที่ไฟล์นั้นว่าทำไมถึงมีสองขั้น

ผลลัพธ์: host/Resources/AppIcon.icns
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from PIL import Image, ImageDraw  # noqa: E402

from gen import mascot  # noqa: E402
from gen.config import PAL, REPO_DIR  # noqa: E402

SRC = REPO_DIR / "docs" / "images" / "perch-logo.png"
OUT = REPO_DIR / "host" / "Resources" / "AppIcon.icns"

# macOS เว้นขอบรอบไอคอนราว 10% ของด้าน ไอคอนที่ชิดขอบจะดูใหญ่ผิดพวกบน Dock
# ภาพต้นทางเป็น full-bleed (กรอบมนกินเกือบเต็มเฟรม) ขอบจึงต้องมาเติมที่นี่
MASTER = 1024
MARGIN = 0.10

# ขนาด *พิกเซลจริง* ที่ยังใช้ภาพวาดใหม่ ไม่ใช่ชื่อขนาดใน iconset — `icon_16x16@2x`
# คือ 32 px จริง จึงต้องตัดสินจากตัวเลขที่วาดออกมา ไม่ใช่จากชื่อไฟล์
SMALL_MAX = 64

# สีหยิบจากภาพโลโก้ ไม่ใช่จาก layout.toml — ขนาดเล็กกับขนาดใหญ่ต้องเป็นไอคอนตัวเดียวกัน
# ที่รายละเอียดต่างกัน ไม่ใช่ภาพคนละใบ ผู้ใช้เลื่อนขนาดใน Finder ผ่านจุดตัด 64→128 แล้ว
# เห็นตัวตนเปลี่ยนคืออาการที่แย่กว่าไอคอนเบลอ
BACKDROP = (20, 16, 14, 255)
BODY = (217, 119, 87, 255)
BAR = (61, 61, 61, 255)

# วาดใหญ่แล้วย่อ — ขอบมนที่ 16 px วาดตรงๆ ได้ขอบหยัก ไม่ใช่ขอบมน
SUPERSAMPLE = 8


def render_master() -> Image.Image:
    src = Image.open(SRC).convert("RGBA")
    # ครอปตาม alpha ก่อน ไม่งั้นขอบใสที่ติดมากับไฟล์บวกกับขอบที่เติมเองจะได้ขอบสองชั้น
    box = src.getchannel("A").getbbox()
    if box:
        src = src.crop(box)

    side = round(MASTER * (1 - 2 * MARGIN))
    # รักษาสัดส่วน: โลโก้ที่ไม่จัตุรัสพอดีต้องไม่ถูกยืด ให้ด้านยาวเป็นตัวกำหนด
    scale = side / max(src.size)
    fitted = src.resize(
        (max(1, round(src.width * scale)), max(1, round(src.height * scale))),
        Image.LANCZOS,
    )

    img = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    img.paste(
        fitted,
        ((MASTER - fitted.width) // 2, (MASTER - fitted.height) // 2),
        fitted,
    )
    return img


def render_small(size: int) -> Image.Image:
    """โลโก้เวอร์ชันตัดทอน วาดที่ขนาดปลายทางโดยตรง แทนการย่อภาพใหญ่ลงมา

    ตัดทิ้ง: เพื่อนอีกสองตัว วัสดุ แสงเงา เงาตกกระทบ — ทุกอย่างที่ต่ำกว่า 1 px ที่ 16 px
    ของพวกนี้ไม่ได้เล็กลง มันกลายเป็นฝ้าที่ทำให้ของที่เหลืออ่านยากขึ้น

    **เหลือตัวเดียวไม่ใช่สามตัว** — วัดแล้วที่ 32 px สามตัวเละเป็นก้อนสีเดียวกัน อ่านไม่ออก
    ว่ามีอะไรอยู่ ส่วนตัวเดียวยังเห็นเป็นสิ่งมีชีวิตที่เกาะอยู่บนคอน ซึ่งเป็นความหมายทั้งหมด
    ของไอคอนนี้ · นี่คือเหตุผลที่ `.icns` เก็บภาพแยกต่อขนาดตั้งแต่แรก
    """
    n = size * SUPERSAMPLE
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # ขอบเดียวกับขนาดใหญ่ ไม่ใช่ค่าที่บางลงเพื่อแลกเนื้อภาพ — ผู้ใช้เลื่อนขนาดไอคอนใน
    # Finder ผ่านจุดตัด 64→128 แล้วเห็นไอคอนกระโดดขนาด อ่านเหมือนภาพผิดมากกว่าภาพคมขึ้น
    inset = round(n * MARGIN)
    side = n - 2 * inset
    draw.rounded_rectangle(
        [inset, inset, n - inset - 1, n - inset - 1],
        radius=round(side * 0.22),
        fill=BACKDROP,
    )

    # คอน — ที่ 16 px มันเหลือหนาแค่ราวหนึ่งพิกเซล ซึ่งยังพอ: มันไม่ต้องอ่านออกว่าเป็นคอน
    # แค่ต้องมีเส้นให้ตัวมาสคอตยืนอยู่บน ไม่งั้นตัวมันลอยกลางกรอบแล้วอ่านเป็นแค่รูปทรง
    bar_h = max(SUPERSAMPLE, round(side * 0.075))
    bar_y = inset + round(side * 0.655)
    draw.rounded_rectangle(
        [inset + round(side * 0.13), bar_y, n - inset - round(side * 0.13) - 1,
         bar_y + bar_h - 1],
        radius=bar_h // 2,
        fill=BAR,
    )

    # มาสคอตมาจาก rect list ตัวเดียวกับบนจอ — ที่ขนาดนี้ silhouette แบนๆ คือสิ่งที่ต้องการ
    # พอดี ท่า idle เป็นท่าเดียวที่ไม่มี prop ถือ จึงสมมาตรพอจะเป็นไอคอนได้
    rects = mascot.build_centered("idle", phase=0.0)
    xs = [r.x for r in rects] + [r.x + r.w for r in rects]
    ys = [r.y for r in rects] + [r.y + r.h for r in rects]
    mw, mh = max(xs) - min(xs), max(ys) - min(ys)
    px = min(side * 0.60 / mw, side * 0.52 / mh)
    ox = inset + side / 2 - (min(xs) + mw / 2) * px
    oy = bar_y - max(ys) * px
    for r in rects:
        # ตาเป็นสีพื้นหลัง ไม่ใช่ `PAL.ink` — ที่ 16 px ตาคือรูที่เห็นพื้นทะลุ หมึกที่ต่างจาก
        # พื้นนิดเดียวกลายเป็นขอบเทาหนึ่งพิกเซลรอบรูแทนที่จะเป็นรู
        eye = r.color.upper() == PAL.ink.upper()
        draw.rectangle(
            [
                round(ox + r.x * px), round(oy + r.y * px),
                round(ox + (r.x + r.w) * px) - 1, round(oy + (r.y + r.h) * px) - 1,
            ],
            fill=BACKDROP if eye else BODY,
        )
    return img.resize((size, size), Image.LANCZOS)


def art(size: int, master: Image.Image) -> Image.Image:
    if size <= SMALL_MAX:
        return render_small(size)
    return master.resize((size, size), Image.LANCZOS)


def main() -> None:
    master = render_master()
    OUT.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            art(size, master).save(iconset / f"icon_{size}x{size}.png")
            art(size * 2, master).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True
        )
    print(f"{SRC.relative_to(REPO_DIR)} + mascot -> {OUT.relative_to(REPO_DIR)}")


if __name__ == "__main__":
    main()

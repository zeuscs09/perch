#!/usr/bin/env python3
"""สร้างโลโก้/ไอคอนจาก rect list ชุดเดียวกับมาสคอตบนจอ

    python3 tools/make_logo.py

เขียนทับ docs/images/perch-logo.png (1024x1024 RGBA) ซึ่งถูกใช้สองที่:
หัว README ทั้งสองภาษา และไอคอนแอป macOS ผ่าน tools/make_icon.py

## ทำไมถึงสร้างแทนที่จะวาดมือ

เดิมไอคอนขนาดใหญ่เป็น PNG วาดมือ ซึ่งเป็นข้อยกเว้นเดียวของกติกา "asset ทุกชิ้นเป็น
rect list" — และเป็นข้อยกเว้นที่ทำให้โลโก้ค้างอยู่ที่คอนเซ็ปต์เก่าตอนโครงการเปลี่ยนชื่อ
สร้างจาก mascot.py แทนแปลว่ามาสคอตเปลี่ยนเมื่อไหร่ โลโก้ตามได้ด้วยคำสั่งเดียว

## รูปที่วาด

ตัวมาสคอตเกาะอยู่บนคอน — ตรงตามชื่อโครงการ ไม่ใช่รูปอุปกรณ์ ซึ่งอุปกรณ์เป็นแค่
ที่ที่มันอาศัยอยู่ ไม่ใช่ตัวมัน
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen import mascot  # noqa: E402
from gen.config import PAL, REPO_DIR  # noqa: E402
from gen.render import quantize565  # noqa: E402

OUT = REPO_DIR / "docs" / "images" / "perch-logo.png"
SIZE = 1024
# วาดใหญ่กว่าจริงแล้วย่อลง — ขอบมนกับขาเรียวได้ขอบเรียบโดยไม่ต้องมีโค้ดลบรอยหยัก
SS = 4


def draw() -> Image.Image:
    n = SIZE * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # พื้นหลังโค้งมน — สีเดียวกับพื้นจอตอนกลางคืน ตัวมาสคอตจึงอ่านออกเหมือนตอนอยู่บนบอร์ด
    pad = round(n * 0.02)
    d.rounded_rectangle(
        [pad, pad, n - pad - 1, n - pad - 1],
        radius=round(n * 0.22),
        fill=quantize565(PAL.bg),
    )

    # คอน — แท่งนอนที่มาสคอตเกาะอยู่ ชื่อโครงการมาจากตรงนี้
    #
    # สีเทาเข้ม ไม่ใช่เฉดของสีดิน: เคยลองใช้ clay_dark แล้วคอนกลืนไปกับตัวมาสคอตจนอ่าน
    # เป็นเงาใต้เท้า ไม่ใช่ของที่มันยืนอยู่บน และเทาอ่อนกว่านี้จะแย่งสายตาไปจากตัวมาสคอตแทน
    bar_h = round(n * 0.060)
    bar_y = round(n * 0.745)
    d.rounded_rectangle(
        [round(n * 0.12), bar_y, round(n * 0.88), bar_y + bar_h],
        radius=bar_h // 2,
        fill=quantize565(PAL.gray_dark),
    )

    # มาสคอตวาดจาก rect list ชุดเดียวกับบนจอ ไม่ใช่ภาพที่วาดแยก
    rects = mascot.build("idle", 0.0)
    x0 = min(r.x for r in rects)
    x1 = max(r.x + r.w for r in rects)
    y0 = min(r.y for r in rects)
    y1 = max(r.y + r.h for r in rects)
    span = max(x1 - x0, y1 - y0)
    # 0.52 ไม่ใช่ 0.60 — ที่ 0.60 แขนเกือบชนขอบ อ่านเป็นตัวที่ถูกยัดใส่กรอบ ไม่ใช่ตัวที่เกาะอยู่
    px = n * 0.52 / span
    ox = (n - (x1 - x0) * px) / 2 - x0 * px
    # ฝ่าเท้าวางบนคอนพอดี ไม่ใช่ลอยหรือจม
    oy = bar_y - y1 * px

    for r in rects:
        rx, ry = ox + r.x * px, oy + r.y * px
        rr = r.r * px
        box = [rx, ry, rx + r.w * px - 1, ry + r.h * px - 1]
        if rr > 0.5:
            d.rounded_rectangle(box, radius=rr, fill=quantize565(r.color))
        else:
            d.rectangle(box, fill=quantize565(r.color))

    return img.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    img = draw()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"{OUT.relative_to(REPO_DIR)}  {img.size[0]}x{img.size[1]}")

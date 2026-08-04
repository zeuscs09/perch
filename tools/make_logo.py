#!/usr/bin/env python3
"""สร้าง *ต้นแบบ* ของโลโก้จาก rect list ชุดเดียวกับมาสคอตบนจอ

    python3 tools/make_logo.py

เขียน `docs/images/perch-logo-reference.png` — ภาพแบนที่ถูกต้องทุกสัดส่วน แต่ยังไม่มีวัสดุ

## ทำไมถึงมีสองไฟล์

`docs/images/perch-logo.png` (ตัวที่ README กับไอคอนแอปใช้จริง) คือภาพนี้ที่ถูกโมเดลสร้างภาพ
ลงวัสดุและแสงเงาให้ — ขั้นนั้นสร้างซ้ำจากโค้ดไม่ได้ ไฟล์ผลลัพธ์จึงถูกคอมมิตไว้

ที่ยังต้องมีต้นแบบในรีโปเพราะ **มันคือสิ่งเดียวที่ทำให้โลโก้ตามมาสคอตทันเมื่อมาสคอตเปลี่ยน**
ประวัติของไฟล์นี้พิสูจน์แล้วว่าจำเป็น: ตอนโครงการเปลี่ยนชื่อ โลโก้ที่วาดมือค้างอยู่ที่คอนเซ็ปต์เก่า
เพราะไม่มีใครมีต้นทางให้วาดตาม

## วิธีสร้างตัวจริงใหม่

    python3 tools/make_logo.py
    codex exec --skip-git-repo-check --sandbox workspace-write \\
      -i docs/images/perch-logo-reference.png -- "<prompt: คงซิลลูเอ็ต เปลี่ยนแค่ผิว>" </dev/null

`--` จำเป็น: `-i/--image` รับหลายค่า ถ้าไม่ปิดรายการมันจะกลืน prompt ไปเป็นชื่อไฟล์รูป
แล้ว codex จะไปรออ่าน prompt จาก stdin แทน · จากนั้นทำมุมให้โปร่งใสก่อนเซฟทับ
(โมเดลคืน RGB ไม่มี alpha มุมจึงเป็นดำทึบ ซึ่งบน Dock พื้นสว่างเห็นเป็นสี่เหลี่ยมดำ)

## รูปที่วาด

สามสายพันธุ์เกาะอยู่บนคอนเดียวกัน — ตรงตามชื่อโครงการ และตรงกับสิ่งที่จอแสดงจริง
ไม่ใช่รูปอุปกรณ์ ซึ่งอุปกรณ์เป็นแค่ที่ที่พวกมันอาศัยอยู่ ไม่ใช่ตัวมัน
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen import mascot  # noqa: E402
from gen.config import PAL, REPO_DIR  # noqa: E402
from gen.render import quantize565  # noqa: E402

OUT = REPO_DIR / "docs" / "images" / "perch-logo-reference.png"
SIZE = 1024
# วาดใหญ่กว่าจริงแล้วย่อลง — ขอบมนกับขาเรียวได้ขอบเรียบโดยไม่ต้องมีโค้ดลบรอยหยัก
SS = 4

# (เอเจนต์, กึ่งกลางแนวนอน, ขนาด) — Claude ใหญ่กว่าและอยู่กลางเพื่อให้มีจุดนำสายตา
# ไม่ใช่เพราะสำคัญกว่า แต่เพราะสามตัวเท่ากันเป๊ะอ่านเป็นแถวของที่ไม่มีใครเป็นประธาน
CAST = (("codex", 0.195, 0.30), ("claude", 0.50, 0.355), ("antigravity", 0.805, 0.30))
# คอนอยู่ที่ 0.665 ไม่ใช่ 0.735 — ที่ต่ำกว่านี้กลุ่มเทลงล่างจนเหลือที่ว่างข้างบนครึ่งกรอบ
BAR_Y, BAR_H = 0.665, 0.052


def draw() -> Image.Image:
    n = SIZE * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # พื้นหลังโค้งมน สีเดียวกับพื้นจอตอนกลางคืน — มาสคอตจึงอ่านออกเหมือนตอนอยู่บนบอร์ด
    pad = round(n * 0.02)
    d.rounded_rectangle(
        [pad, pad, n - pad - 1, n - pad - 1], radius=round(n * 0.22),
        fill=quantize565(PAL.bg),
    )

    # คอน — สีเทาเข้ม ไม่ใช่เฉดของสีดิน: เคยลองแล้วมันกลืนไปกับตัวมาสคอตจนอ่านเป็นเงาใต้เท้า
    bh, by = round(n * BAR_H), round(n * BAR_Y)
    d.rounded_rectangle(
        [round(n * 0.07), by, round(n * 0.93), by + bh], radius=bh // 2,
        fill=quantize565(PAL.gray_dark),
    )

    for agent, cx, scale in CAST:
        rects = mascot.build("idle", 0.0, agent=agent)
        x0 = min(r.x for r in rects)
        x1 = max(r.x + r.w for r in rects)
        y1 = max(r.y + r.h for r in rects)
        px = n * scale / max(x1 - x0, y1 - min(r.y for r in rects))
        ox = n * cx - (x0 + x1) / 2 * px
        oy = by - y1 * px  # ฝ่าเท้าวางบนคอนพอดี ไม่ลอยไม่จม
        for r in rects:
            rx, ry, rr = ox + r.x * px, oy + r.y * px, r.r * px
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

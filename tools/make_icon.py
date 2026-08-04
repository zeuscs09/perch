#!/usr/bin/env python3
"""ไอคอนแอป — สองชุดในไฟล์เดียว: ภาพโลโก้สำหรับขนาดใหญ่ ภาพวาดใหม่สำหรับขนาดเล็ก

เคยเรนเดอร์จาก gen/mascot.py ทุกขนาด เพื่อให้ไอคอนเปลี่ยนตามมาสคอตเอง แต่ rect list
ทำได้แค่ silhouette แบนๆ ส่วนไอคอนบน Dock อยู่ข้างไอคอนที่มีแสงเงาและวัสดุ
มาสคอตบนจอ 320x240 กับตราของแอปบนเดสก์ท็อปเป็นคนละงาน

แล้วโลโก้ที่มีแสงเงา ฟองคำพูด และหัวใจ ก็ละลายเป็นก้อนส้มที่ 16 px เหมือนกัน
`.icns` เก็บภาพแยกต่อขนาดได้อยู่แล้ว — ขนาดเล็กจึงไม่ใช่โลโก้ที่ย่อลง แต่เป็นภาพที่ตัด
ทุกอย่างออกจนเหลือสิ่งที่ยังอ่านได้: ตัวเครื่องสีส้ม จอมืด มาสคอตหนึ่งตัว

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

# สีหยิบจากภาพโลโก้ ไม่ใช่จาก layout.toml — จานสีบนจอบีบเป็น RGB565 แล้วและถูกเลือก
# ให้เข้ากับพื้นดำของพาเนล ส่วนนี่ต้องเข้ากับตัวเครื่องในภาพเดียวกัน
SHELL = (248, 100, 37, 255)
CREAM = (246, 206, 171, 255)
SCREEN = (30, 19, 12, 255)
INK = (253, 110, 36, 255)

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
    """โลโก้เวอร์ชันตัดทอน วาดที่ขนาดปลายทางโดยตรง

    ตัดทิ้ง: ปุ่มสามปุ่ม ฟองคำพูด หัวใจ แสงเงา เส้นสแกน — ทุกอย่างที่ต่ำกว่า 1 px
    ที่ 16 px ของพวกนี้ไม่ได้เล็กลง มันกลายเป็นฝ้าที่ทำให้ของที่เหลืออ่านยากขึ้น

    วงคาดครีมหายไปต่ำกว่า 64 px ด้วยเหตุผลเดียวกัน แต่คนละอาการ: มันยังเห็นอยู่
    แค่กินที่ ส้ม→ครีม→ดำ สามชั้นที่ 16 px เหลือจอกว้าง 6 px ให้มาสคอตทั้งตัว
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
        fill=SHELL,
    )

    if size >= SMALL_MAX:
        bezel = inset + round(side * 0.10)
        draw.rounded_rectangle(
            [bezel, bezel, n - bezel - 1, n - bezel - 1],
            radius=round((n - 2 * bezel) * 0.18),
            fill=CREAM,
        )
        screen = bezel + max(SUPERSAMPLE, round(side * 0.055))
    else:
        screen = inset + round(side * 0.12)
    screen_w = n - 2 * screen
    draw.rounded_rectangle(
        [screen, screen, n - screen - 1, n - screen - 1],
        radius=round(screen_w * 0.16),
        fill=SCREEN,
    )

    # มาสคอตยังมาจาก rect list ตัวเดียวกับบนจอ — ที่ขนาดนี้ silhouette แบนๆ คือสิ่งที่ต้องการ
    # พอดี ท่า idle เป็นท่าเดียวที่ไม่มี prop ถือ จึงสมมาตรพอจะเป็นไอคอนได้
    rects = mascot.build_centered("idle", phase=0.0)
    xs = [r.x for r in rects] + [r.x + r.w for r in rects]
    ys = [r.y for r in rects] + [r.y + r.h for r in rects]
    mw, mh = max(xs) - min(xs), max(ys) - min(ys)
    px = min(screen_w * 0.74 / mw, screen_w * 0.66 / mh)
    ox = screen + screen_w / 2 - (min(xs) + mw / 2) * px
    oy = screen + screen_w / 2 - (min(ys) + mh / 2) * px
    for r in rects:
        # ตาเป็นสีจอ ไม่ใช่ `PAL.ink` — ที่ 16 px ตาคือรูที่เห็นจอทะลุ หมึกที่ต่างจากพื้นจอ
        # นิดเดียวกลายเป็นขอบเทาหนึ่งพิกเซลรอบรูแทนที่จะเป็นรู
        eye = r.color.upper() == PAL.ink.upper()
        draw.rectangle(
            [
                round(ox + r.x * px), round(oy + r.y * px),
                round(ox + (r.x + r.w) * px) - 1, round(oy + (r.y + r.h) * px) - 1,
            ],
            fill=SCREEN if eye else INK,
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

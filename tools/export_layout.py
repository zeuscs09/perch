#!/usr/bin/env python3
"""layout.toml -> firmware/main/layout.h

ปิดช่องว่างของการตัด simulator ทิ้ง: preview ฝั่ง Python กับ firmware ฝั่ง C
อ่านตัวเลขจากไฟล์เดียวกัน ถ้าภาพที่เห็นบน preview ต่างจากบนบอร์ด
แปลว่าเป็นบั๊ก renderer ล้วนๆ ไม่ใช่ค่าคงที่ไม่ตรงกัน
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen import mascot  # noqa: E402
from gen.config import LAYOUT_TOML, REPO_DIR, _raw  # noqa: E402
from gen.props import BOX_X0, BOX_X1, BOX_Y0, BOX_Y1  # noqa: E402
from gen.render import to_rgb565  # noqa: E402

OUT = REPO_DIR / "firmware" / "main" / "layout.h"


def _f(v: float) -> str:
    """ค่าทศนิยมแบบ C — ต้องมีจุดเสมอ

    `f"{22.0:g}f"` ได้ `22f` ซึ่ง C ปฏิเสธ ("invalid digit 'f' in decimal constant")
    ตัวเลขที่ลงตัวพอดีจึงพังเงียบๆ ตอนคอมไพล์ firmware เท่านั้น
    """
    s = f"{v:g}"
    if "." not in s and "e" not in s:
        s += ".0"
    return s + "f"


def _emit_section(name: str, values: dict) -> list[str]:
    lines = []
    for k, v in values.items():
        if isinstance(v, list):
            continue  # ตารางไปออกเป็น C array ไม่ใช่ #define — ดู _emit_tables
        macro = f"PCH_{name.upper()}_{k.upper()}"
        if isinstance(v, float):
            lines.append(f"#define {macro:<28} {_f(v)}")
        else:
            lines.append(f"#define {macro:<28} {v}")
    return lines


def _emit_tables(name: str, values: dict) -> list[str]:
    """ตารางใน layout.toml -> C array + มาโครนับจำนวน

    ตำแหน่งดาว/กอหญ้า/เมฆต้องเป็นชุดเดียวกันเป๊ะทั้งสองฝั่ง ถ้าปล่อยให้แต่ละฝั่งสุ่มเอง
    ภาพบน preview จะไม่ใช่ภาพบนบอร์ด แล้ว preview ก็หมดประโยชน์
    """
    lines: list[str] = []
    for k, v in values.items():
        if not isinstance(v, list) or not v:
            continue
        sym = f"pch_{name}_{k}"
        count = f"PCH_{name.upper()}_{k.upper()}_COUNT"
        lines.append(f"#define {count:<28} {len(v)}")
        if isinstance(v[0], list):
            cols = len(v[0])
            if any(len(row) != cols for row in v):
                raise ValueError(f"{name}.{k}: ทุกแถวต้องยาวเท่ากัน")
            lines.append(f"static const int16_t {sym}[{count}][{cols}] = {{")
            for row in v:
                lines.append("    {" + ", ".join(f"{c:>3}" for c in row) + "},")
        else:
            lines.append(f"static const int16_t {sym}[{count}] = {{")
            for i in range(0, len(v), 12):
                lines.append("    " + ", ".join(f"{c:>3}" for c in v[i:i + 12]) + ",")
        lines += ["};", ""]
    return lines


def build_header() -> str:
    out = [
        "// สร้างอัตโนมัติจาก tools/layout.toml — ห้ามแก้ไฟล์นี้ด้วยมือ",
        "// แก้ที่ layout.toml แล้วรัน: python3 tools/export_layout.py",
        "#pragma once",
        "",
        "#include <stdint.h>",
        "",
    ]
    for section in ("screen", "topbar", "slots", "card", "usage", "weather", "stroll", "sky", "mascot"):
        out += _emit_section(section, _raw[section])
        out.append("")
        out += _emit_tables(section, _raw[section])

    out += [
        "// กรอบวาดมาสคอตรวม prop (หน่วย unit) — มาจาก tools/gen/props.py",
        f"#define PCH_BOX_X0                    {_f(BOX_X0)}",
        f"#define PCH_BOX_X1                    {_f(BOX_X1)}",
        f"#define PCH_BOX_Y0                    {_f(BOX_Y0)}",
        f"#define PCH_BOX_Y1                    {_f(BOX_Y1)}",
        "",
        "// จานสีเป็น RGB565 ตามที่แผงจอกินจริง",
    ]
    for k, v in _raw["palette"].items():
        out.append(f"#define PCH_COL_{k.upper():<21} 0x{to_rgb565(v):04X}")

    out += [
        "",
        "// visual state — daemon ส่งค่าพวกนี้มาบน BLE ห้ามเรียงใหม่",
        "typedef enum {",
    ]
    for i, st in enumerate(mascot.all_states()):
        out.append(f"    PCH_STATE_{st.upper():<12} = {i},")
    out += [
        f"    PCH_STATE_COUNT{'':<12} = {len(mascot.all_states())},",
        "} pch_state_t;",
        "",
        "static const char *const pch_state_names[PCH_STATE_COUNT] = {",
    ]
    for st in mascot.all_states():
        out.append(f'    "{st}",')
    out += ["};", ""]
    return "\n".join(out)


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(build_header(), encoding="utf-8")
    print(f"{LAYOUT_TOML.name} -> {OUT.relative_to(REPO_DIR)}")


if __name__ == "__main__":
    main()

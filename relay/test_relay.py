#!/usr/bin/env python3
"""ทดสอบ perch-relay ก่อนเอาขึ้นเซิร์ฟเวอร์

ทดสอบพฤติกรรมที่ *ถ้าผิดแล้วจะเจ็บตอนใช้จริง* ไม่ใช่แค่ทางที่ทุกอย่างเรียบร้อย:
ข้อมูลที่มาก่อนอีกฝั่งต้องหาย (ไม่ใช่ค้างคิว) · สายใหม่ต้องเตะสายผีออก · สายที่ถูกเตะ
ต้องไม่ไปลบสายที่มาแทนตัวเอง
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = 17333
fails: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if ok else 'พัง '} {name}{'  — ' + detail if detail else ''}")
    if not ok:
        fails.append(name)


async def hello(role: str, dev: str):
    r, w = await asyncio.open_connection("127.0.0.1", PORT)
    w.write(f"{role} {dev}\n".encode())
    await w.drain()
    return r, w


async def read_for(r: asyncio.StreamReader, seconds: float) -> bytes:
    try:
        return await asyncio.wait_for(r.read(4096), seconds)
    except asyncio.TimeoutError:
        return b""


async def closed_within(r: asyncio.StreamReader, seconds: float) -> bool:
    """สายถูกปิดจริงไหม — ต่างจาก "ไม่มีข้อมูล" คนละเรื่อง

    read() คืน b"" ตอน EOF ส่วน wait_for โยน TimeoutError ตอนสายยังเปิดแต่เงียบ
    การใช้ read_for แล้วเทียบกับ b"" รวมสองสถานะนี้เป็นอันเดียว ทำให้เทสต์ "ถูกปฏิเสธ"
    ผ่านทั้งตอนถูกปฏิเสธจริงและตอนถูกรับแต่ยังไม่มีคู่ — ซึ่งพิสูจน์แล้วว่าเป็นเทสต์เปล่า
    """
    try:
        return await asyncio.wait_for(r.read(1), seconds) == b""
    except asyncio.TimeoutError:
        return False


async def run() -> None:
    # 1. ส่งผ่านได้ทั้งสองทาง
    br, bw = await hello("B", "dev1xxxxxxxxxxxxxxxxxxxxx")
    hr, hw = await hello("H", "dev1xxxxxxxxxxxxxxxxxxxxx")
    await asyncio.sleep(0.2)
    bw.write(b"board->host"); await bw.drain()
    check("บอร์ด -> Mac", await read_for(hr, 2) == b"board->host")
    hw.write(b"host->board"); await hw.drain()
    check("Mac -> บอร์ด", await read_for(br, 2) == b"board->board"[:0] + b"host->board")

    # 2. คนละ device-id ต้องไม่ปนกัน — ข้อนี้ถ้าพลาดคือข้อมูลรั่วข้ามเครื่อง
    br2, bw2 = await hello("B", "dev2xxxxxxxxxxxxxxxxxxxxx")
    hr2, hw2 = await hello("H", "dev2xxxxxxxxxxxxxxxxxxxxx")
    await asyncio.sleep(0.2)
    bw2.write("เครื่องสอง".encode())
    await bw2.drain()
    got1 = await read_for(hr, 0.6)
    got2 = await read_for(hr2, 2)
    check("ไม่ปนข้าม device-id", got1 == b"" and got2 == "เครื่องสอง".encode(),
          f"dev1 ได้ {got1!r}")

    # 3. ข้อมูลที่มาก่อนอีกฝั่งต้องหายไป ไม่ใช่ค้างคิว
    br3, bw3 = await hello("B", "dev3xxxxxxxxxxxxxxxxxxxxx")
    await asyncio.sleep(0.2)
    bw3.write("ก่อนที่ Mac จะมา".encode()); await bw3.drain()
    await asyncio.sleep(0.3)
    hr3, hw3 = await hello("H", "dev3xxxxxxxxxxxxxxxxxxxxx")
    check("ไม่ค้างคิวของเก่า", await read_for(hr3, 0.8) == b"")

    # 4. สายบอร์ดใหม่ต้องเตะสายผีออก
    br4, bw4 = await hello("B", "dev1xxxxxxxxxxxxxxxxxxxxx")
    await asyncio.sleep(0.3)
    check("สายใหม่เตะสายเก่า", await read_for(br, 1.0) == b"")
    bw4.write("จากสายใหม่".encode()); await bw4.drain()
    check("สายใหม่ส่งถึง Mac", await read_for(hr, 2) == "จากสายใหม่".encode())

    # 5. สายเก่าที่ถูกเตะต้องไม่ลบสายใหม่ตอนมันปิดตัว
    #
    # ต้องยิง **Mac -> บอร์ด** เท่านั้น เพราะ guard ปกป้อง pair.board — ทิศทางบอร์ด -> Mac
    # อ่าน pair.host ซึ่งบั๊กไม่ได้แตะ เทสต์เดิมยิงผิดทิศจึงผ่านทั้งที่ guard ถูกถอดออก
    bw.close()
    await asyncio.sleep(0.5)
    hw.write("ถึงสายใหม่ไหม".encode()); await hw.drain()
    check("สายเก่าปิดแล้วไม่ลบสายใหม่", await read_for(br4, 2) == "ถึงสายใหม่ไหม".encode())

    # 6. id สั้นต้องถูกปฏิเสธ — id คือความลับเพียงอย่างเดียวที่กันคนอื่นมาเตะบอร์ดหลุด
    r7, w7 = await asyncio.open_connection("127.0.0.1", PORT)
    w7.write(b"B short\n"); await w7.drain()
    check("ปฏิเสธ device-id สั้น", await closed_within(r7, 3))
    try: w7.close()
    except Exception: pass

    # 7. แนะนำตัวผิดรูปแบบต้องถูกตัด
    r6, w6 = await asyncio.open_connection("127.0.0.1", PORT)
    w6.write(b"GET / HTTP/1.1\n"); await w6.drain()
    check("ตัดสายที่พูดไม่ถูกภาษา", await closed_within(r6, 3))

    for w in (bw2, hw, hw2, bw3, hw3, bw4, w6):
        try: w.close()
        except Exception: pass


if __name__ == "__main__":
    proc = subprocess.Popen([sys.executable, str(HERE / "perch-relay.py"), "--port", str(PORT)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(1.2)
    try:
        asyncio.run(run())
    finally:
        proc.terminate()
        out = proc.communicate(timeout=5)[0]
    print()
    print("--- log ของ relay ---")
    print("\n".join(out.strip().splitlines()[-14:]))
    print()
    if fails:
        print("ไม่ผ่าน:", ", ".join(fails))
        sys.exit(1)
    print("ผ่านหมด")

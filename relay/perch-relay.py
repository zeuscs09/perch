#!/usr/bin/env python3
"""perch-relay — ท่อส่งไบต์ระหว่างบอร์ดกับ Mac สำหรับตอนอยู่นอกบ้าน

ทำไมต้องมี: ทั้งบอร์ดและ Mac อยู่หลัง NAT ไม่มีใครรับสายได้ ทางแก้คือให้ *ทั้งคู่วิ่งออก*
มาเจอกันตรงกลาง NAT จึงไม่เป็นปัญหาอีกต่อไป

ทำไมไม่ใช่ MQTT: เราต้องการท่อระหว่างสองปลายที่รู้จักกัน ไม่ใช่ pub/sub ที่มี topic, QoS,
retained message ซึ่งไม่ได้ใช้สักอย่าง — และบนบอร์ด esp-mqtt กินหลาย KB ส่วนซ็อกเก็ตเปล่า
วัดได้ 556 ไบต์

**relay ถอดรหัสไม่ได้และไม่ต้องเชื่อถือ** — payload ถูกปิดผนึกด้วย AES-GCM กุญแจ 32 ไบต์
ที่บอร์ดกับ Mac แชร์กันไว้ก่อน (pch_lan.c) relay เห็นแต่ขยะ จึงไม่ต้องมี TLS ซ้อน
ซึ่งดีมากเพราะ TLS handshake กิน 20-40KB ที่บอร์ดไม่มี

โปรโตคอล: บรรทัดแรกบอกว่าเป็นใคร แล้วที่เหลือคือไบต์ดิบ
    B <device-id>\\n     บอร์ด
    H <device-id>\\n     Mac

หนึ่ง device-id มีได้ฝั่งละหนึ่งสาย สายใหม่ที่ซ้ำจะเตะสายเก่าออก — บอร์ดที่ WiFi หลุด
แล้วต่อกลับต้องแทนที่สายเดิมที่ค้างเป็นผีได้ ไม่งั้นมันจะต่อไม่ได้จนกว่า TCP timeout
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import re
import time

LOG = logging.getLogger("relay")

HELLO_MAX = 64          # บรรทัดแนะนำตัวยาวเกินนี้ = ไม่ใช่ลูกค้าของเรา ตัดทิ้ง
HELLO_TIMEOUT = 10.0
# device-id ต้องยาวพอที่จะ *เป็นความลับ* ไม่ใช่แค่ชื่อเรียก
#
# relay ไม่ถือกุญแจอะไรเลยโดยตั้งใจ — มันจึงยืนยันตัวตนใครไม่ได้ และกฎ "สายใหม่เตะสายเก่า"
# (ซึ่งจำเป็น ไม่งั้นบอร์ดที่ WiFi หลุดจะกลับเข้ามาไม่ได้จนกว่า TCP จะ timeout) แปลว่า
# **ใครก็ตามที่เดา device-id ถูก เตะบอร์ดหลุดได้** อ่านข้อมูลไม่ได้เพราะปิดผนึก AES-GCM
# ปลายทางถึงปลายทาง แต่กวนให้ใช้ไม่ได้ได้
#
# ทางแก้ที่ไม่ต้องให้ relay ถือความลับ: ทำให้ id เองเดาไม่ได้ 22 ตัวอักษรจากชุด 64 ตัว
# = 132 บิต ซึ่งเกินกว่าจะไล่เดา ชื่อสวยๆ อย่าง "perch-6716" จึงถูกปฏิเสธโดยตั้งใจ
#
# (ทางเลือกอื่นคือใส่ HMAC ตอน hello แต่ relay ต้องถือกุญแจไว้ตรวจ = มีของให้ขโมย
#  และต้องมีระบบแจกกุญแจ ซึ่งแพงกว่าปัญหาที่แก้)
ID_MIN = 22
ID_RE = re.compile(r"^[A-Za-z0-9_-]{%d,64}$" % ID_MIN)


class Pair:
    """สองฝั่งของ device-id หนึ่งตัว"""

    __slots__ = ("board", "host", "since")

    def __init__(self) -> None:
        self.board: asyncio.StreamWriter | None = None
        self.host: asyncio.StreamWriter | None = None
        self.since = time.time()

    def peer(self, role: str) -> asyncio.StreamWriter | None:
        return self.host if role == "B" else self.board


PAIRS: dict[str, Pair] = {}


async def pump(src: asyncio.StreamReader, dev: str, role: str) -> int:
    """อ่านจากฝั่งเรา ส่งให้อีกฝั่ง — หาอีกฝั่ง *ทุกครั้ง* ไม่ใช่จำไว้ตอนเริ่ม

    เพราะอีกฝั่งอาจมาทีหลัง หลุดแล้วต่อใหม่ หรือถูกแทนที่ด้วยสายใหม่ระหว่างทาง
    การจำ writer ไว้ตั้งแต่ต้นทำให้ส่งไปที่สายที่ตายแล้วโดยไม่มีใครรู้
    """
    moved = 0
    while True:
        data = await src.read(4096)
        if not data:
            return moved
        pair = PAIRS.get(dev)
        dst = pair.peer(role) if pair else None
        if dst is None or dst.is_closing():
            continue        # อีกฝั่งยังไม่มา — ทิ้งไป ไม่เก็บคิว
        try:
            dst.write(data)
            await dst.drain()
            moved += len(data)
        except (ConnectionError, OSError):
            continue


async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    addr = writer.get_extra_info("peername")
    dev = role = None
    try:
        try:
            line = await asyncio.wait_for(reader.readline(), HELLO_TIMEOUT)
        except asyncio.TimeoutError:
            LOG.info("%s ไม่แนะนำตัวใน %.0fs", addr, HELLO_TIMEOUT)
            return
        if not line or len(line) > HELLO_MAX:
            return
        parts = line.decode("ascii", "replace").strip().split()
        if len(parts) != 2 or parts[0] not in ("B", "H") or not ID_RE.match(parts[1]):
            LOG.info("%s แนะนำตัวไม่ถูกรูปแบบ: %r", addr, line[:40])
            return
        role, dev = parts

        pair = PAIRS.setdefault(dev, Pair())
        old = pair.board if role == "B" else pair.host
        if old is not None and not old.is_closing():
            # สายเก่าที่ค้างเป็นผีต้องถูกเตะออก ไม่งั้นบอร์ดที่ต่อกลับหลัง WiFi หลุด
            # จะเข้าไม่ได้จนกว่า TCP ฝั่งเก่าจะ timeout ซึ่งกินเวลาหลายนาที
            LOG.info("[%s] %s สายใหม่แทนสายเก่า", dev, role)
            old.close()
        if role == "B":
            pair.board = writer
        else:
            pair.host = writer

        both = pair.board is not None and pair.host is not None
        LOG.info("[%s] %s เข้ามาจาก %s%s", dev, role, addr, "  — ครบคู่แล้ว" if both else "")
        moved = await pump(reader, dev, role)
        LOG.info("[%s] %s ออก ส่งผ่านไป %d ไบต์", dev, role, moved)
    except (ConnectionError, OSError) as e:
        LOG.info("%s สายขาด: %s", addr, e)
    finally:
        pair = PAIRS.get(dev) if dev else None
        if pair is not None:
            # เคลียร์เฉพาะถ้าสายที่กำลังปิดคือสายที่จดไว้จริง — ไม่งั้นสายเก่าที่เพิ่ง
            # ถูกแทนที่จะไปลบสายใหม่ที่เข้ามาเสียบแทนตัวเอง
            if role == "B" and pair.board is writer:
                pair.board = None
            elif role == "H" and pair.host is writer:
                pair.host = None
            if pair.board is None and pair.host is None:
                PAIRS.pop(dev, None)
        writer.close()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7333)
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    server = await asyncio.start_server(serve, args.host, args.port)
    LOG.info("perch-relay ฟังที่ %s:%d", args.host, args.port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

import CryptoKit
import Foundation

/// ข้อตกลงบนสาย LAN — ต้องตรงกับ `firmware/main/pch_lan.c` ทุกไบต์
///
///     [4B len BE][12B nonce][ciphertext][16B tag]
///
/// `len` คือจำนวนไบต์ที่ตามหลังมันเอง · nonce คือศูนย์สี่ไบต์ตามด้วยตัวนับ 8 ไบต์ BE
///
/// ทำไมต้องเข้ารหัสทั้งที่อยู่บน LAN ของตัวเอง: WPA2 ปิดแค่ช่วงอากาศ ทุกเครื่องที่ต่อ
/// เราเตอร์ตัวเดียวกันอ่านและ *เขียน* ได้หมด — snapshot มีชื่อโปรเจกต์กับชื่อไฟล์อยู่ข้างใน
/// และช่องที่เขียนอะไรลงจอบนโต๊ะได้โดยไม่ต้องพิสูจน์ตัวคือช่องที่ไม่ควรมี
public enum LanWire {
    public static let port: UInt16 = 7333
    /// ประเภทบริการที่บอร์ดประกาศทาง mDNS
    public static let serviceType = "_perch._tcp"

    static let magic = Data("TAMA".utf8)
    static let version: UInt8 = 1
    static let nonceLength = 12
    static let tagLength = 16
    /// เท่ากับ MAX_CIPHERTEXT ฝั่ง firmware — snapshot ถูกบีบไว้ที่ 500 อยู่แล้ว
    static let maxPlaintext = 560

    /// คำทักทายที่บอร์ดส่งทันทีที่รับสาย: มายิก 4 + เวอร์ชัน 1 + ตัวนับ 8
    public static let greetingLength = 13
}

/// สิ่งที่บอร์ดบอกตอนรับสาย — ตัวนับที่มันรับไปถึงแล้ว
///
/// Mac นับต่อจากเลขนี้ จึงไม่ต้องเก็บไฟล์ตัวนับของตัวเองไว้ที่ไหนเลย ไฟล์แบบนั้นหายเมื่อไร
/// (ย้ายเครื่อง ล้าง home) ก็แปลว่าต่อบอร์ดไม่ได้อีกจนกว่าจะเปลี่ยนกุญแจ ซึ่งเป็นความพัง
/// ที่ไม่มีอาการให้เห็น · การโกหกเลขนี้ทำได้แค่ดันตัวนับให้สูงขึ้น ไม่เปิดทางให้เฟรมเก่าผ่าน
public struct LanGreeting: Equatable, Sendable {
    public let counter: UInt64

    public init(counter: UInt64) { self.counter = counter }

    /// คืน nil เมื่อไม่ใช่บอร์ดของเรา หรือพูดเวอร์ชันที่แอปนี้ยังไม่รู้จัก
    public static func decode(_ data: Data) -> LanGreeting? {
        guard data.count >= LanWire.greetingLength else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == [UInt8](LanWire.magic) else { return nil }
        guard bytes[4] == LanWire.version else { return nil }
        var counter: UInt64 = 0
        for byte in bytes[5..<13] { counter = (counter << 8) | UInt64(byte) }
        return LanGreeting(counter: counter)
    }
}

/// ปิดผนึก snapshot ทีละก้อน พร้อมเดินตัวนับให้เอง
///
/// ตัวนับอยู่ใน nonce ไม่ใช่ใน payload: มันต้องเป็นค่าเดียวกับที่ใช้เข้ารหัส ไม่งั้นคนกลาง
/// สลับ "เลขที่เขียนไว้" กับ "เลขที่ใช้จริง" ให้ไม่ตรงกันได้ · nonce ซ้ำใน GCM ทำลาย
/// ความลับทั้งหมด ตัวนับจึงเดินขึ้นอย่างเดียวและไม่มีทางถูกตั้งถอยหลัง
public struct LanSealer {
    public enum Failure: Error, Equatable {
        case payloadTooLarge(Int)
        case badKeyLength(Int)
    }

    private let key: SymmetricKey
    public private(set) var counter: UInt64

    /// `startingAfter` คือเลขที่บอร์ดบอกมาในคำทักทาย — เฟรมแรกจะเป็นเลขถัดไป
    public init(key: Data, startingAfter: UInt64 = 0) throws {
        guard key.count == 32 else { throw Failure.badKeyLength(key.count) }
        self.key = SymmetricKey(data: key)
        self.counter = startingAfter
    }

    /// ตัวนับเดิน *ก่อน* ปิดผนึกเสมอ แม้เฟรมนั้นจะส่งไม่สำเร็จ — เลขที่ถูกใช้ไปแล้วครั้งหนึ่ง
    /// ต้องไม่ถูกใช้อีก ไม่ว่าอะไรจะเกิดขึ้นกับซ็อกเก็ตหลังจากนั้น
    public mutating func seal(_ payload: Data) throws -> Data {
        guard payload.count <= LanWire.maxPlaintext else {
            throw Failure.payloadTooLarge(payload.count)
        }
        counter += 1
        let sealed = try AES.GCM.seal(
            payload, using: key, nonce: AES.GCM.Nonce(data: Self.nonce(counter)))
        var body = Data(Self.nonce(counter))
        body.append(sealed.ciphertext)
        body.append(sealed.tag)

        let length = UInt32(body.count)
        var frame = Data([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        frame.append(body)
        return frame
    }

    static func nonce(_ counter: UInt64) -> Data {
        var data = Data([0, 0, 0, 0])
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift)))
        }
        return data
    }

    /// ทางกลับ — มีไว้ให้ `perchtest` พิสูจน์ว่าสิ่งที่ปิดผนึกไปเปิดกลับได้จริง
    /// ตัวจริงที่เปิดคือ firmware ซึ่งใช้ mbedtls คนละตัวกัน จึงต้องพิสูจน์ทั้งสองทาง
    public static func open(frame: Data, key: Data) -> (counter: UInt64, payload: Data)? {
        guard key.count == 32, frame.count > 4 else { return nil }
        let bytes = [UInt8](frame)
        var length: UInt32 = 0
        for byte in bytes[0..<4] { length = (length << 8) | UInt32(byte) }
        guard Int(length) == bytes.count - 4 else { return nil }
        guard Int(length) >= LanWire.nonceLength + LanWire.tagLength else { return nil }

        let body = Data(bytes[4...])
        let nonce = body.prefix(LanWire.nonceLength)
        let rest = body.dropFirst(LanWire.nonceLength)
        let cipher = rest.dropLast(LanWire.tagLength)
        let tag = rest.suffix(LanWire.tagLength)
        guard
            let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher, tag: tag),
            let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else { return nil }

        var counter: UInt64 = 0
        for byte in nonce.dropFirst(4) { counter = (counter << 8) | UInt64(byte) }
        return (counter, plain)
    }
}

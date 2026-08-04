import Foundation

/// payload ของ statusline ที่ถูกส่งผ่าน socket ให้ daemon เขียน cache แทน
///
/// ## ทำไมต้องผ่าน daemon แทนที่จะเขียนไฟล์เอง
///
/// เดิมทุก session เขียนไฟล์เดียวกันเองทุกสิบวินาที บนเครื่องที่เปิดหลายสิบ session
/// นั่นคือหลายสิบกระบวนการที่เรียก `rename()` ใส่ *ชื่อไฟล์เดียวกัน* พร้อมกันตลอดเวลา
///
/// `rename()` ล็อกที่ชื่อปลายทางในไดเรกทอรี ตัวไหนที่เข้าไปแล้วค้าง จะทำให้ทุกตัวที่
/// ตามมาต่อคิวอยู่หลังมัน — และการรอ `rename()` เป็น uninterruptible wait ปลุกไม่ได้
/// ฆ่าไม่ได้ ตัวจับเวลาใดๆ ก็แทรกไม่ได้ วิธีเดียวที่ล้างได้คือรีสตาร์ตเครื่อง
///
/// เกิดขึ้นจริงบนเครื่องผู้ใช้: กระบวนการค้างสะสมนาทีละ 79 ตัวจนเต็มโควตา สแตกยืนยันว่า
/// ทุกตัวค้างที่ `UsageWriter.write -> replaceItemAt -> rename` เหมือนกันหมด
///
/// การมี **ผู้เขียนคนเดียว** ตัดคิวนั้นทิ้งทั้งหมด: daemon อยู่ยาว มีคิวของตัวเอง และเขียน
/// ทีละครั้งอยู่แล้ว — ไม่ใช่การทำให้เร็วขึ้น แต่เป็นการเอาโครงสร้างที่ค้างได้ออกไป
///
/// แยกจาก `HookEvent` ได้เองโดยไม่ต้องมีตัวบอกชนิด เพราะ `HookEvent` บังคับให้มี
/// `hookEventName` กับ `sessionId` ซึ่ง payload นี้ไม่มีทั้งคู่ — รูปแบบเดิมบนสายจึงไม่เปลี่ยน
public struct UsageMessage: Codable, Equatable, Sendable {
    /// JSON ดิบที่ Claude Code ป้อนเข้า statusline — daemon แกะเองด้วย `UsageWriter`
    public var statusline: String

    public init(statusline: String) {
        self.statusline = statusline
    }

    /// ส่งให้ daemon — คืน false เมื่อไม่มี daemon ให้ส่ง (ผู้เรียกต้องเขียนไฟล์เอง)
    public static func send(_ raw: Data, to socket: URL) -> Bool {
        guard !raw.isEmpty,
            let text = String(data: raw, encoding: .utf8),
            let line = try? Wire.encoder().encode(UsageMessage(statusline: text))
        else { return false }
        return SocketClient(path: socket).send(line)
    }
}

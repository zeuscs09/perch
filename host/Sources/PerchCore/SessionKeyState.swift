import Foundation

/// สิ่งที่หน้าตั้งค่าบอกใต้ปุ่ม "Set session key…"
///
/// แยกจาก `PanelText.keyProblem` ทั้งที่ดูคล้ายกัน เพราะสองที่นี้ตอบคนละคำถาม:
/// แผงบนแถบตอบว่า "ทำไมตัวเลขไม่ขยับ" จึงเงียบตอนทุกอย่างปกติ ส่วนที่นี่ตอบว่า
/// "ที่เพิ่งกด Save เข้าไปไหม" ซึ่ง**ต้องมีคำตอบเสมอ** รวมทั้งตอนที่ทุกอย่างปกติ —
/// ช่องกรอกเป็นแบบปิดบังตัวอักษรและ key ไม่เคยถูกใส่กลับเข้าช่อง ผู้ใช้จึงไม่มีทาง
/// ตรวจด้วยตาเองว่าบันทึกไปแล้วหรือยัง
///
/// "บันทึกแล้ว" กับ "ใช้ได้จริง" เป็นคนละสถานะ: ไฟล์เขียนสำเร็จทันที แต่คำตอบว่า
/// claude.ai รับ key นี้ไหมมาทีหลังเป็นวินาที การยุบสองอันนี้เป็นอันเดียวจะได้
/// ข้อความที่โกหกในช่วงระหว่างนั้น
public enum SessionKeyState: Equatable {
    /// ยังไม่มีไฟล์ key ที่ใช้ได้
    case none
    /// เขียนไฟล์แล้ว แต่ยังไม่มีรอบไหนถามกลับมา (เช่น `Refresh quota` เป็น Off)
    case saved
    /// รอบกำลังวิ่ง — คำตอบยังไม่กลับมา
    case checking
    /// รอบล่าสุดผ่าน
    case working
    /// รอบล่าสุดตอบว่าใช้ไม่ได้
    case rejected(PollBlock)

    /// ข้อความบรรทัดเดียวใต้ปุ่ม
    public var line: String {
        switch self {
        case .none: return "No session key saved"
        case .saved: return "Saved — not checked yet"
        case .checking: return "Checking the key with claude.ai…"
        case .working: return "Saved — claude.ai accepted it"
        case .rejected(.expiredKey): return "claude.ai rejected the key — paste a new one"
        case .rejected(.unusableKeyFile): return "The key file cannot be read — paste it again"
        }
    }

    /// ทาสีแดงไหม — "ยังไม่มี key" ไม่ใช่ความผิดพลาด มันคือค่าตั้งต้นของคนที่ไม่เปิดใช้
    public var isProblem: Bool {
        if case .rejected = self { return true }
        return false
    }

    /// อ่านสถานะจาก poller · เรียงลำดับนี้เพราะ "ไม่มีไฟล์" ชนะทุกอย่าง — ป้ายที่ค้าง
    /// จากรอบก่อนหน้าไม่ควรอธิบายไฟล์ที่ตอนนี้ไม่มีอยู่แล้ว
    public static func of(
        hasKey: Bool, running: Bool, blocked: PollBlock?, checked: Bool
    ) -> SessionKeyState {
        guard hasKey else { return .none }
        if let blocked { return .rejected(blocked) }
        if running { return .checking }
        return checked ? .working : .saved
    }
}

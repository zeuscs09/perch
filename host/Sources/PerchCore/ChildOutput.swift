import Foundation

/// สิ่งที่โปรเซสลูกพูดออกมา เก็บจากคิวของ pipe — คนอ่านกับคนเขียนอยู่คนละเธรด
///
/// มีเพดาน เพราะสิ่งที่พ่ออ่านจากลูกคือบรรทัดสั้นๆ ที่บอกว่ารอบนั้นจบยังไง ไม่ใช่เนื้อคำตอบ
/// ของ session ที่ยาวได้ไม่จำกัด · ส่วนที่เกินถูกทิ้ง ไม่ใช่ไปเบียดของเดิมออก: สาเหตุที่ลูก
/// จบมักถูกพูดตั้งแต่บรรทัดแรกๆ
public final class ChildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    public init(limit: Int = 1 << 16) {
        self.limit = limit
    }

    public func append(_ more: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(more.prefix(limit - data.count))
    }

    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// เริ่มดูด pipe ตั้งแต่ตอนนี้ — ต้องดูดจริง ไม่ใช่รอไปอ่านทีเดียวตอนลูกตาย:
    /// pipe ที่ไม่มีคนอ่านจะบล็อกลูกเมื่อ buffer เต็ม
    public static func draining(_ pipe: Pipe, limit: Int = 1 << 16) -> ChildOutput {
        let output = ChildOutput(limit: limit)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { output.append(chunk) }
        }
        return output
    }

    /// เก็บส่วนที่ค้างอยู่หลังลูกตาย
    ///
    /// ถอด handler *ก่อน* อ่านที่เหลือเสมอ — สองคนอ่าน fd เดียวกันจะแบ่งไบต์กันไป
    /// คนละครึ่งอย่างไม่แน่นอน ซึ่งอ่านออกมาเป็นบรรทัดที่ขาดหายเป็นครั้งคราว
    public func drain(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? nil { append(rest) }
    }
}

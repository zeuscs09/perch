import Foundation

/// เรียกโปรแกรมภายนอกแล้ว **รับประกันว่าจะกลับมาเสมอ**
///
/// มีอยู่เพราะเคยไม่มี: โค้ดที่เรียก `tmux` ตอนแรกรอด้วย `waitUntilExit()` เปล่าๆ
/// ตัวเรียกคือ hook ที่ยิงทุกครั้งที่เอเจนต์ใช้เครื่องมือ คูณด้วยจำนวน session ที่เปิดอยู่
/// พอเครื่องเข้าใกล้เพดานจำนวนกระบวนการ `tmux` เองก็ fork ไม่ได้และค้าง ตัว hook เลยค้างตาม
/// สะสมเป็น 7,000 กระบวนการที่ไม่มีวันตาย จนเครื่องหมดโควตาและทุกอย่างค้างหนักขึ้นอีก
/// — วงจรที่เร่งตัวเอง
///
/// บทเรียนที่ไฟล์นี้เก็บไว้: **การรอที่ไม่มีเพดานในโค้ดที่ถูกเรียกบ่อย ไม่ใช่ความช้า
/// แต่เป็นการรั่ว** และเพดานนั้นต้องมีเทสต์ ไม่ใช่ความตั้งใจในคอมเมนต์
public enum Subprocess {
    /// รันแล้วคืน stdout — คืน nil เมื่อ fork ไม่ผ่าน, หมดเวลา, หรือจบด้วยสถานะไม่เป็นศูนย์
    ///
    /// อ่าน pipe บนคิวอื่นแทนที่จะอ่านบนคิวนี้ ด้วยเหตุผลสองข้อ: กัน pipe เต็มแล้วลูกค้าง
    /// (ซึ่งจะกลายเป็นการค้างสองฝั่ง) และทำให้ตัวจับเวลาข้างล่างมีสิทธิ์ทำงานจริง —
    /// ถ้าอ่านบนคิวเดียวกัน การอ่านที่ค้างจะกินเวลาที่ตั้งใจจะนับไปเสียเอง
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        cwd: String? = nil
    ) -> String? {
        final class Box: @unchecked Sendable { var data = Data() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        // fork ไม่ผ่านคือคำตอบที่ใช้ได้ในตัวมันเอง (เครื่องเต็ม) — กลับทันที ไม่ลองซ้ำ
        // การลองซ้ำตอนเครื่องเต็มคือการเติมเชื้อให้กับสิ่งที่ทำให้มันเต็ม
        guard (try? task.run()) != nil else { return nil }

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }

        guard done.wait(timeout: .now() + timeout) == .success else {
            // SIGTERM ก่อนเผื่อลูกอยากเก็บของ แล้ว SIGKILL ทันทีเพราะลูกที่ค้างอยู่แล้ว
            // มักไม่อยู่ในสภาพจะรับ SIGTERM ได้ — ปล่อยไว้คือสิ่งที่เราพยายามเลี่ยงพอดี
            task.terminate()
            kill(task.processIdentifier, SIGKILL)
            // ไม่รอผลของการฆ่า: การรอตรงนี้คือการยอมค้างอีกครั้งในโค้ดที่มีไว้กันการค้าง
            return nil
        }
        task.waitUntilExit()  // pipe ปิดแล้ว = ลูกจบแล้ว บรรทัดนี้จึงไม่รอจริง
        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }
}

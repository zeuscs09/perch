import Darwin
import Foundation

/// ภาระของเครื่อง Mac — CPU กับหน่วยความจำ
///
/// คนละชนิดกับโควตา: โควตาคือ *งบที่ใช้ไปแล้ว* ซึ่งมีเส้นตายรีเซ็ต ส่วนนี่คือ
/// *ค่า ณ วินาทีนี้* ที่ไม่มีเส้นตาย จอจึงวาดมันคนละแบบ (ไม่มีเวลานับถอยหลัง)
///
/// อ่านผ่าน mach API ตรงๆ ไม่ fork `vm_stat`/`ps` ทุกวินาที — daemon เต้นทุก 1 วิ
/// การสร้าง process ที่ความถี่นั้นเปลืองกว่าค่าที่ได้มามาก
///
/// **ไม่มีอุณหภูมิ** — Apple Silicon ปิดเซ็นเซอร์ SMC ไว้หลัง entitlement
/// การไปพึ่งเครื่องมือนอก (smctemp ฯลฯ) แลกความเปราะบางกับตัวเลขที่ไม่ได้
/// ทำให้ตัดสินใจอะไรต่างไปจาก CPU load ที่มีอยู่แล้ว
public enum MachineLoad {
    public struct Sample: Equatable, Sendable {
        /// เปอร์เซ็นต์ CPU ที่ถูกใช้จริงในช่วงระหว่างสองครั้งที่อ่าน (0-100)
        public var cpu: Int
        /// เปอร์เซ็นต์หน่วยความจำที่ถูกใช้จริง (0-100)
        public var memory: Int
    }

    /// ตัวนับสะสมจากครั้งก่อน — CPU ใน mach เป็น *ticks สะสมตั้งแต่บูต*
    /// ค่าที่มีความหมายคือส่วนต่างระหว่างสองครั้ง ไม่ใช่ตัวเลขดิบ
    nonisolated(unsafe) private static var previous: (used: UInt64, total: UInt64)?
    private static let lock = NSLock()

    public static func sample() -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        guard let mem = memoryPercent() else { return nil }
        return Sample(cpu: cpuPercent() ?? 0, memory: mem)
    }

    /// ครั้งแรกที่เรียกยังไม่มีฐานให้เทียบ จึงคืน 0 — ครั้งถัดไปเป็นต้นไปได้ค่าจริง
    private static func cpuPercent() -> Int? {
        // มาโครนับขนาดของ C ไม่ถูก import เข้ามาใน Swift — คำนวณจาก struct จริงแทน
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let used = user &+ system &+ nice
        let total = used &+ idle

        defer { previous = (used, total) }
        guard let prev = previous, total > prev.total else { return nil }
        let dUsed = used &- prev.used
        let dTotal = total &- prev.total
        guard dTotal > 0 else { return nil }
        return min(100, Int(dUsed &* 100 / dTotal))
    }

    /// นับเฉพาะหน่วยความจำที่ "เอาคืนไม่ได้ทันที" — active + wired + ที่ถูกบีบอัด
    ///
    /// ไม่รวม inactive กับ speculative เพราะระบบยึดคืนได้ทันทีที่ต้องการ
    /// การรวมมันเข้าไปจะทำให้ Mac ที่ทำงานปกติดูเหมือนหน่วยความจำเต็มตลอดเวลา
    private static func memoryPercent() -> Int? {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return min(100, Int(used * 100 / total))
    }
}

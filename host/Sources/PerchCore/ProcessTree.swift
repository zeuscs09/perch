import Darwin
import Foundation

/// อ้างถึง process หนึ่งตัวแบบที่ PID ถูกใช้ซ้ำแล้วไม่หลอกเรา
///
/// PID อย่างเดียวไม่พอ: macOS วนเลข PID กลับมาใช้ใหม่ได้ภายในไม่กี่นาทีบนเครื่องที่
/// spawn process ถี่ๆ (ซึ่ง Claude Code ทำอยู่ตลอดผ่าน Bash tool) ถ้าเทียบแค่เลข
/// session ที่ตายไปแล้วจะ "ฟื้น" ขึ้นมาบนจอเพราะมีใครมาได้เลขเดิม — จึงผูก
/// เวลาเกิดของ process ไว้ด้วย ซึ่งคู่ (pid, startedAt) ไม่ซ้ำกันตลอดอายุเครื่อง
public struct ProcessHandle: Codable, Equatable, Sendable {
    public var pid: Int32
    /// `p_starttime` เป็นวินาที epoch — ตัวระบุตัวตน ไม่ได้เอาไปคำนวณอายุ
    public var startedAt: Double

    public init(pid: Int32, startedAt: Double) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// อ่านสายพันธุ์ของ process จาก kernel — ใช้ตอบคำถามเดียว: เจ้าของ session ยังอยู่ไหม
public enum ProcessTree {
    /// พาธเต็มของไบนารีที่ process นี้รันอยู่ — `p_comm` ใช้แทนไม่ได้ ดู `isClaude`
    public static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// process นี้คือ Claude Code ไหม
    ///
    /// **ห้ามตัดสินจาก `p_comm`** — ตัวติดตั้งหลักวาง executable ไว้ที่
    /// `~/.local/share/claude/versions/2.1.220` ชื่อไบนารีจึงเป็น *เลขเวอร์ชัน*
    /// ไม่ใช่ "claude" และเปลี่ยนทุกครั้งที่อัปเดต · สิ่งที่นิ่งคือ *คอมโพเนนต์* `claude`
    /// ในพาธ ซึ่งครอบคลุมทั้งแบบนั้นและ `/opt/homebrew/bin/claude`
    ///
    /// เทียบทั้งคอมโพเนนต์ ไม่ใช่ `contains` เพราะไบนารีของเราเองอยู่ใน `perch/`
    /// ซึ่ง `contains("claude")` จะจริงด้วย แล้วเราจะไปคว้า wrapper ของตัวเองมาเป็นเจ้าของ
    private static func isClaude(pid: Int32, comm: String) -> Bool {
        if let path = executablePath(pid) {
            for c in path.split(separator: "/") where c == "claude" || c.hasPrefix("claude-") {
                return true
            }
        }
        // ติดตั้งผ่าน npm: ตัว process คือ node/bun ที่รันสคริปต์ ชื่อสคริปต์ไม่โผล่ในพาธ
        return comm == "node" || comm == "bun"
    }

    /// สิ่งที่ kernel รู้เกี่ยวกับ process หนึ่งตัว — nil = ไม่มี process นี้แล้ว
    public static func info(_ pid: Int32) -> (ppid: Int32, name: String, startedAt: Double)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &proc, &size, nil, 0)
        // process ที่ตายแล้วให้ rc == 0 พร้อม size == 0 ไม่ใช่ error — เช็คทั้งสองอย่าง
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.size else { return nil }

        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let t = proc.kp_proc.p_starttime
        return (proc.kp_eproc.e_ppid, name, Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    public static func handle(for pid: Int32) -> ProcessHandle? {
        guard let i = info(pid) else { return nil }
        return ProcessHandle(pid: pid, startedAt: i.startedAt)
    }

    /// process ตัวเดิมตัวนั้นยังอยู่ไหม — เลข PID ตรงแต่เวลาเกิดไม่ตรง = คนละตัว
    public static func isAlive(_ h: ProcessHandle) -> Bool {
        guard let i = info(h.pid) else { return false }
        return i.startedAt == h.startedAt
    }

    /// ไต่สายบรรพบุรุษขึ้นไปหา process ของ Claude Code ที่เรียก hook นี้
    ///
    /// คืน nil เมื่อหาไม่เจอ **โดยตั้งใจ** และเป็นกฎที่ห้ามผ่อน: hook ถูกเรียกผ่าน
    /// เชลล์ และผู้ใช้ครอบ wrapper อะไรไว้ก็ได้ ถ้าเดาผิดแล้วไปคว้า wrapper ที่ตาย
    /// ทันทีหลัง hook จบมาเป็นเจ้าของ session ที่ยังทำงานอยู่จะหายจากจอทุกครั้ง
    /// — nil แปลว่า "ไม่รู้" แล้วตกกลับไปใช้เกณฑ์เงียบครบ `evict` แบบเดิม ซึ่งช้าแต่ไม่เคยผิด
    public static func claudeAncestor(of start: Int32 = getppid(), maxDepth: Int = 10)
        -> ProcessHandle?
    {
        var pid = start
        for _ in 0..<maxDepth {
            guard pid > 1, let i = info(pid) else { return nil }
            if isClaude(pid: pid, comm: i.name) {
                return ProcessHandle(pid: pid, startedAt: i.startedAt)
            }
            pid = i.ppid
        }
        return nil
    }
}

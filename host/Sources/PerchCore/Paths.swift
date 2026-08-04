import Foundation

/// ที่อยู่ไฟล์ทั้งหมดของฝั่ง Mac
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var stateDir: URL {
        home.appendingPathComponent(".perch", isDirectory: true)
    }

    /// ชื่อเดิมก่อนโครงการเปลี่ยนชื่อเป็น Perch
    static var legacyStateDir: URL {
        home.appendingPathComponent(".tamaclaude", isDirectory: true)
    }

    /// Unix socket ที่ hook คุยกับ daemon
    /// sun_path จำกัด 104 ไบต์ พาธนี้สั้นพอเสมอเพราะอยู่ใต้ home
    public static var socket: URL {
        stateDir.appendingPathComponent("daemon.sock")
    }

    public static var toolConfig: URL {
        stateDir.appendingPathComponent("tools.json")
    }

    /// session key ของ claude.ai — credential เต็มบัญชี ต้องเป็น mode 600
    /// อยู่ใต้ state dir ไม่ใช่ใน repo ไหน และไม่เคยผ่าน argv หรือ env
    public static var sessionKey: URL {
        stateDir.appendingPathComponent("session-key")
    }

    /// กุญแจปิดผนึกเฟรมบน LAN — 32 ไบต์เป็น hex, mode 600 เหมือน `sessionKey`
    /// คนละอย่างกับ `sessionKey` โดยสิ้นเชิง: อันนี้เปิดได้แค่ช่องคุยกับบอร์ด (`LanKey`)
    public static var lanKey: URL {
        stateDir.appendingPathComponent("lan-key")
    }

    public static var log: URL {
        stateDir.appendingPathComponent("daemon.log")
    }

    /// สคริปต์ที่เรายึดช่อง `statusLine.command` ไว้ — เขียน cache แล้วส่งงานวาดต่อ
    public static var statusline: URL {
        stateDir.appendingPathComponent("statusline.sh")
    }

    /// cache โควตาที่ statusline เขียน — ที่อยู่เดิมของ Claude Usage.app
    /// ใช้ที่เดียวกันเพื่อให้ statusline เดิมของผู้ใช้อ่านต่อได้โดยไม่ต้องแก้อะไร
    public static var usageCache: URL {
        home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".statusline-usage-cache")
    }

    @discardableResult
    public static func ensureStateDir() -> Bool {
        // ต้องมาก่อน createDirectory — ตัวย้ายทำงานก็ต่อเมื่อปลายทาง *ยังไม่มี*
        // สร้างโฟลเดอร์ว่างก่อนแล้วจะไม่มีวันได้ของเก่ากลับมาอีกเลย
        migrateLegacyState()
        return (try? FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true)) != nil
    }

    /// ย้ายของจาก `~/.tamaclaude` มา `~/.perch` ครั้งเดียวตอนอัปเกรดข้ามชื่อ
    ///
    /// ในนั้นมีของที่สร้างใหม่แทนกันไม่ได้: `session-key` ที่ผู้ใช้ไปลอกจากเบราว์เซอร์มาแปะเอง
    /// และ `lan-key` ที่ถ้าหายแล้วบอร์ดจะปฏิเสธทุกเฟรมจนกว่าจะแฟลชกุญแจใหม่ลงไป
    /// การเปลี่ยนชื่อโครงการต้องไม่แปลว่าผู้ใช้ต้องไปตั้งค่าพวกนั้นใหม่
    ///
    /// ย้ายทั้งโฟลเดอร์ทีเดียวแทนที่จะไล่ทีละไฟล์ เพราะของที่เพิ่มเข้ามาทีหลังจะได้ตามมาเอง
    /// โดยไม่ต้องมีใครจำได้ว่าต้องมาเติมชื่อไฟล์ในรายการนี้
    static func migrateLegacyState() {
        migrateState(from: legacyStateDir, to: stateDir)
    }

    /// รับพาธเข้ามาเพื่อให้ทดสอบได้จริง — `NSHomeDirectory()` บน macOS อ่านจาก getpwuid
    /// ไม่สน `$HOME` จึงหลอกด้วย env ไม่ได้ และเทสต์ที่ต้องแตะบ้านจริงของผู้ใช้คือเทสต์
    /// ที่ไม่มีใครกล้ารัน
    ///
    /// คืน `true` เมื่อย้ายจริงในรอบนี้ — ผู้เรียกใช้แยก "ย้ายสำเร็จ" ออกจาก "ไม่มีอะไรให้ย้าย"
    @discardableResult
    public static func migrateState(from legacy: URL, to current: URL) -> Bool {
        let fm = FileManager.default
        // ปลายทางมีอยู่แล้ว = เคยย้ายไปแล้ว หรือผู้ใช้เริ่มใหม่หมด — ห้ามทับของที่ใหม่กว่า
        guard !fm.fileExists(atPath: current.path),
            fm.fileExists(atPath: legacy.path)
        else { return false }
        do {
            try fm.createDirectory(
                at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: current)
        } catch {
            Log.info(
                "ย้าย \(legacy.path) ไม่สำเร็จ (\(error))"
                    + " — ลอก session-key กับ lan-key มาเองที่ \(current.path)")
            return false
        }
        // socket ที่ติดมาด้วยเป็นของ daemon ตัวที่ตายไปแล้ว ทิ้งไว้จะจองพาธใหม่ไม่ได้
        try? fm.removeItem(at: current.appendingPathComponent("daemon.sock"))
        Log.info("ย้าย \(legacy.path) -> \(current.path) แล้ว")
        return true
    }
}

/// log แบบง่ายที่สุดที่ยังใช้งานได้ — เขียน stderr เสมอ
///
/// เขียนลงไฟล์ด้วยเมื่อเปิด `toFile` เพราะตอนถูกปล่อยผ่าน LaunchServices (`open`)
/// ไม่มีใครเห็น stderr เลย ซึ่งเป็นวิธีเดียวที่ขอสิทธิ์ Bluetooth ได้สำเร็จ
public enum Log {
    public nonisolated(unsafe) static var verbose = false
    public nonisolated(unsafe) static var toFile = false

    private static let lock = NSLock()

    public static func info(_ msg: @autoclosure () -> String) {
        let line = "[perch] \(msg())\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard toFile else { return }
        lock.lock()
        defer { lock.unlock() }
        let url = Paths.log
        // ตัดทิ้งเมื่อโตเกิน 1MB — log ที่โตไม่หยุดคือปัญหาถัดไปที่ไม่อยากได้
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? Int, size > 1 << 20 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public static func debug(_ msg: @autoclosure () -> String) {
        guard verbose else { return }
        info(msg())
    }
}

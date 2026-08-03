import Foundation

/// ชื่อ tmux session ของ pane ที่ hook กำลังวิ่งอยู่
///
/// ทำไมต้องมี: หลายทีมวางโครงโฟลเดอร์เหมือนกันหมด (`<project>/agents/<role>`)
/// ชื่อโฟลเดอร์สุดท้ายจึงซ้ำกันข้ามทีม — วัดจากเครื่องจริงพบ `orchestrator` โผล่
/// 18 session, `qa` 13, `ba` 11 ป้ายใต้มาสคอตเลยบอกไม่ได้ว่ากำลังดูทีมไหนอยู่
///
/// ชื่อ session คือสิ่งที่ผู้ใช้พิมพ์ตอน `tmux attach` — มันตอบว่า "ต้องไปที่ไหน"
/// ซึ่งเป็นคำถามที่จอนี้มีไว้ตอบ
///
/// **ต้องหาในกระบวนการของ hook เท่านั้น** — `TMUX_PANE` สืบทอดมาจาก Claude Code
/// ที่รันอยู่ใน pane นั้นจริงๆ พอส่งเข้า socket แล้ว daemon อยู่คนละสาย หาไม่ได้อีก
public enum TmuxSession {
    /// จำผลไว้ตลอดอายุ process — hook เป็น process อายุสั้น ยิงครั้งเดียวก็จบ
    /// แต่ถ้าวันหนึ่งมันถูกเรียกซ้ำ ก็ไม่ต้อง fork tmux ใหม่
    nonisolated(unsafe) private static var cached: String??

    public static func current(env: [String: String] = ProcessInfo.processInfo.environment)
        -> String? {
        if let cached { return cached }
        let value = resolve(env: env)
        cached = value
        return value
    }

    /// รายชื่อ session ทั้งหมด — ใช้ตัดสินว่าคำนำหน้า/ต่อท้ายไหนซ้ำจนตัดทิ้งได้
    public static func allNames() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func resolve(env: [String: String]) -> String? {
        // ไม่ได้อยู่ใน tmux = ไม่ต้องเรียกอะไรเลย (เคสปกติของคนที่ไม่ได้ใช้ tmux)
        guard let pane = env["TMUX_PANE"], !pane.isEmpty, env["TMUX"] != nil else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "display-message", "-p", "-t", pane, "#{session_name}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        // hook ต้องจบเร็วเสมอ — tmux ที่ค้างต้องไม่ลากให้ session ของผู้ใช้ค้างตาม
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

        let name = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return SessionLabel.shorten(name, among: allNames())
    }

    /// หา session จาก cwd — ใช้กับ Codex ที่ไม่มี `TMUX_PANE` ให้เรา
    /// (เราอ่านไฟล์ rollout ของมันจากนอก pane) จับคู่ด้วยที่อยู่ของ pane ที่เปิดอยู่จริง
    public static func forWorkingDirectory(_ cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "list-panes", "-a", "-F", "#{session_name}\t#{pane_current_path}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if String(parts[1]) == cwd {
                return SessionLabel.shorten(String(parts[0]), among: allNames())
            }
        }
        return nil
    }
}

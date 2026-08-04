import Foundation

/// เขียน hook ของเราเข้า `~/.claude/settings.json` โดยไม่แตะของเดิม
///
/// ใช้ JSONSerialization ไม่ใช่ Codable เพราะไฟล์นี้เป็นของผู้ใช้:
/// คีย์ที่เราไม่รู้จักต้องรอดกลับออกไปครบ
public enum HookInstaller {
    public static var settingsPath: URL {
        Paths.home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// hook ที่ daemon ใช้จริง — ตรงกับ `switch` ใน SessionStore.apply
    public static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PreCompact",
        "Notification",
        "Stop",
        // ต้องมีคู่กับ SubagentStop เสมอ — ถ้าติดตั้งแต่ Stop ตัวนับจะติดลบไม่ได้
        // (max(0,·)) แล้วค้างที่ศูนย์ตลอด ท่า conducting จะไม่มีวันโผล่
        "SubagentStart",
        "SubagentStop",
        "SessionEnd",
    ]

    /// ชื่อไบนารีที่นับว่าเป็น "ของเรา" — รวมชื่อเดิมก่อนโครงการเปลี่ยนมาเป็น Perch
    ///
    /// ต้องจำชื่อเก่าไว้ ไม่งั้นการอัปเกรดข้ามชื่อจะไม่รู้จัก hook ชุดเดิมของตัวเอง แล้ว
    /// *เพิ่ม* ชุดใหม่ทับแทนที่จะแทนที่ — เหลือ hook สิบตัวชี้ไปที่แอปที่ถูกลบไปแล้ว
    /// ทุกเหตุการณ์จึงยิงโปรเซสที่ตายทันทีเพิ่มอีกสิบตัว ซึ่งเป็นรูปแบบเดียวกับที่เคยทำ
    /// ตารางโปรเซสของเครื่องเต็มมาแล้ว
    static let ownNames = ["perch", "tamaclaude"]

    static func isOurs(_ command: String) -> Bool {
        command.contains("--hook") && ownNames.contains { command.contains($0) }
    }

    /// ตารางเหตุการณ์ชุดใหม่ จากของเดิม — แยกออกมาเป็นฟังก์ชันบริสุทธิ์เพื่อให้ทดสอบได้
    /// โดยไม่ต้องแตะ `~/.claude/settings.json` ของจริง ซึ่งเป็นไฟล์ที่ผู้ใช้แก้เองอยู่
    public static func applying(command: String, to hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // ตัวแรกที่เจอได้พาธใหม่ ตัวที่เหลือถูกทิ้ง — หนึ่งเหตุการณ์ต้องยิงของเราครั้งเดียว
            // ไม่ว่าจะเคยติดตั้งมากี่รอบหรือเคยใช้ชื่ออะไรมาก่อน
            var kept = false
            entries = entries.compactMap { entry -> [String: Any]? in
                var entry = entry
                let before = entry["hooks"] as? [[String: Any]] ?? []
                let after = before.compactMap { h -> [String: Any]? in
                    guard let c = h["command"] as? String, isOurs(c) else { return h }
                    if kept { return nil }
                    kept = true
                    var h = h
                    h["command"] = command
                    return h
                }
                // กลุ่มที่เหลือแต่ของเราแล้วโดนทิ้งหมด ต้องหายไปทั้งกลุ่ม ไม่ใช่ค้างเป็นกลุ่มว่าง
                // (กลุ่มที่ว่างมาแต่แรกไม่ใช่ของเรา ปล่อยไว้ตามเดิม)
                if after.isEmpty && !before.isEmpty { return nil }
                entry["hooks"] = after
                return entry
            }
            if !kept {
                entries.append(["hooks": [["type": "command", "command": command]]])
            }
            hooks[event] = entries
        }
        return hooks
    }

    public enum InstallError: Error, CustomStringConvertible {
        case unreadableSettings
        case notJSONObject

        public var description: String {
            switch self {
            case .unreadableSettings: return "could not read ~/.claude/settings.json"
            case .notJSONObject: return "settings.json is not a JSON object"
            }
        }
    }

    public static func install(binary: String = CommandLine.arguments[0]) throws {
        let command = "\(URL(fileURLWithPath: binary).standardizedFileURL.path) --hook"
        var root: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: settingsPath.path) {
            guard let data = try? Data(contentsOf: settingsPath) else {
                throw InstallError.unreadableSettings
            }
            if !data.isEmpty {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw InstallError.notJSONObject }
                root = obj
            }
            // สำรองไว้ก่อนเสมอ ไฟล์นี้ผู้ใช้แก้เองมาแล้วแน่ๆ
            try? data.write(to: settingsPath.appendingPathExtension("perch.bak"))
        }

        root["hooks"] = applying(command: command, to: root["hooks"] as? [String: Any] ?? [:])

        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsPath)
    }
}

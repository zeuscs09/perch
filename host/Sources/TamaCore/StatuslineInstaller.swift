import Foundation

/// ยึดช่อง `statusLine.command` ใน `~/.claude/settings.json` เพื่อดักข้อมูลโควตา
///
/// Claude Code ป้อน JSON เข้า stdin ของ statusline ทุกครั้งที่ render และใน JSON นั้นมี
/// `rate_limits.five_hour` / `.seven_day` (`used_percentage` + `resets_at` เป็น epoch)
/// นี่คือแหล่งข้อมูลโควตาที่ไม่ต้องใช้ credential ไม่ต้องยิงเน็ต และไม่ต้องมี timer
///
/// สคริปต์ที่ติดตั้งจะ **ไม่เปลี่ยนสิ่งที่ผู้ใช้เห็น**: มันเขียน cache แล้วส่ง JSON ก้อนเดิม
/// ต่อให้คำสั่ง statusline เดิม แล้วพิมพ์ผลของคำสั่งนั้นออกไป การยึดช่องนี้เป็นการ
/// ควบคุมท่อข้อมูล ไม่ใช่การเปลี่ยนหน้าตา
///
/// ผู้ใช้ที่ *ไม่เคยมี* statusline เป็นข้อยกเว้นเดียว — ไม่มีอะไรให้ส่งต่อ เราจึงวาดเอง
/// ด้วย `StatuslineRender` ซึ่งเป็น port ของ `statusline-command.sh` ทั้งใบ
public enum StatuslineInstaller {
    public static var settingsPath: URL { HookInstaller.settingsPath }

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

    /// คำสั่ง statusline เดิมของผู้ใช้ที่เราจะส่งงานวาดต่อให้ — `nil` ถ้าไม่เคยมี
    public static func previousCommand() -> String? {
        guard let data = try? Data(contentsOf: settingsPath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let line = root["statusLine"] as? [String: Any],
            let command = line["command"] as? String,
            !command.contains(Paths.statusline.path)  // ของเราเอง อย่าเรียกวน
        else { return nil }
        return command
    }

    public static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsPath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let line = root["statusLine"] as? [String: Any],
            let command = line["command"] as? String
        else { return false }
        return command.contains(Paths.statusline.path)
    }

    public static func install(binary: String = CommandLine.arguments[0]) throws {
        let binaryPath = URL(fileURLWithPath: binary).standardizedFileURL.path
        // อ่านคำสั่งเดิม *ก่อน* เขียนทับ ไม่งั้นจะได้สคริปต์ที่เรียกตัวเองไม่รู้จบ
        //
        // ติดตั้งซ้ำ (อัปเกรด/ย้ายพาธ binary) จะเจอ statusLine ที่ชี้มาที่เราเองอยู่แล้ว
        // ซึ่ง previousCommand() คืน nil อย่างถูกต้อง — คำสั่งเดิมของผู้ใช้ตอนนั้น
        // เก็บอยู่ในสคริปต์เก่า ต้องกู้จากตรงนั้น ไม่งั้นการติดตั้งซ้ำ = ลบ statusline ของเขาทิ้ง
        let previous = previousCommand() ?? delegatedCommandInScript()

        Paths.ensureStateDir()
        try script(binary: binaryPath, delegateTo: previous)
            .write(to: Paths.statusline, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: Paths.statusline.path)

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
            try? data.write(to: settingsPath.appendingPathExtension("tamaclaude.bak"))
        }

        // refreshInterval: statusline เป็น event-driven ล้วนโดยดีฟอลต์ และเอกสารระบุว่า
        // trigger จะเงียบตอน session ว่าง ซึ่งเป็นสภาพที่จอนี้เจอเกือบตลอดเวลา
        // 10 วินาทีเร็วพอให้ตัวเลขตามทัน และช้าพอไม่ให้สคริปต์ 27KB กินซีพียู
        root["statusLine"] = [
            "type": "command",
            "command": "sh \(Paths.statusline.path)",
            "refreshInterval": 10,
        ]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsPath)
    }

    /// คืนช่องให้คำสั่งเดิมที่สคริปต์ของเราเก็บไว้ — ถอนการติดตั้งโดยไม่ต้องจำอะไรเอง
    public static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsPath),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw InstallError.unreadableSettings }

        if let restored = delegatedCommandInScript() {
            root["statusLine"] = ["type": "command", "command": restored]
        } else {
            root.removeValue(forKey: "statusLine")
        }
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsPath)
        try? FileManager.default.removeItem(at: Paths.statusline)
    }

    /// ดึงคำสั่งเดิมกลับจากสคริปต์ที่ติดตั้งไว้ — สคริปต์เป็นที่เก็บ ไม่ต้องมีไฟล์สำรองแยก
    public static func delegatedCommandInScript() -> String? {
        guard let text = try? String(contentsOf: Paths.statusline, encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("PREV=") {
            let raw = line.dropFirst("PREV=".count).trimmingCharacters(in: .whitespaces)
            guard raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") else { return nil }
            let inner = String(raw.dropFirst().dropLast())
            return inner.isEmpty ? nil : inner.replacingOccurrences(of: "'\\''", with: "'")
        }
        return nil
    }

    /// ครอบสตริงด้วย single quote ให้ปลอดภัยใน sh — พาธของผู้ใช้มีช่องว่างได้
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func script(binary: String, delegateTo previous: String?) -> String {
        """
        #!/bin/sh
        # สร้างโดย tamaclaude --install-statusline — แก้ที่ StatuslineInstaller.swift
        #
        # หน้าที่: ดัก JSON ที่ Claude Code ป้อนเข้า statusline เพื่อเก็บ rate_limits
        # ลง cache ให้ daemon อ่าน แล้วส่งงานวาดต่อให้คำสั่งเดิมของผู้ใช้
        #
        # กติกาข้อเดียวที่ห้ามพลาด: สคริปต์นี้ต้องไม่ทำให้ statusline ของผู้ใช้หายไป
        # ไม่ว่า binary จะหาย พัง หรือช้า — ทุกทางจึงมี || true และ exit 0 เสมอ
        PREV=\(shellQuote(previous ?? ""))
        BIN=\(shellQuote(binary))

        input=$(cat)

        # เขียน cache แบบเงียบ ๆ ผลลัพธ์ของขั้นนี้ไม่มีผลต่อสิ่งที่ผู้ใช้เห็น
        #
        # มี PREV = บรรทัดที่ผู้ใช้เห็นมาจาก PREV ทั้งหมด สิ่งที่เราวาดถูกโยนทิ้งเสมอ
        # `--cache-only` จึงข้ามการวาด ซึ่งแปลว่าไม่ต้องเรียก git เลย — ห้าคำสั่ง git
        # ทุกสิบวินาทีต่อทุก session เพื่อผลลัพธ์ที่ไม่มีใครอ่าน คือแรงกดที่ใหญ่ที่สุด
        # ที่สคริปต์นี้วางบนเครื่อง และเป็นจุดที่เคยค้างจนกระบวนการสะสมมาแล้ว
        if [ -n "$PREV" ]; then
            printf '%s' "$input" | "$BIN" --usage-cache --cache-only >/dev/null 2>&1 || true
            printf '%s' "$input" | sh -c "$PREV" || true
        else
            fallback=$(printf '%s' "$input" | "$BIN" --usage-cache 2>/dev/null) || fallback=""
            [ -n "$fallback" ] && printf '%s\\n' "$fallback"
        fi
        exit 0
        """
    }
}

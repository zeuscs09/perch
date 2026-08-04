import Foundation

/// ตาราง tool -> สถานะภาพ
///
/// การแปลอยู่ฝั่ง daemon ทั้งหมด (ข้อตกลงใน DESIGN.md) firmware รู้จักแค่ enum คงที่
/// ผู้ใช้แก้ตารางได้ที่ `~/.perch/tools.json` โดยไม่ต้องแฟลชบอร์ดใหม่
public struct ToolMap: Sendable {
    /// ชื่อเป๊ะ เช่น "Read"
    public var exact: [String: VisualState]
    /// ขึ้นต้นด้วย เช่น "mcp__" — ใช้เมื่อไม่เจอชื่อเป๊ะ ตัวที่ยาวกว่าชนะ
    public var prefixes: [String: VisualState]
    /// ไม่เข้าข้อไหนเลย
    public var fallback: VisualState

    public static let `default` = ToolMap(
        exact: [
            "Read": .reading,
            "Grep": .reading,
            "Glob": .reading,
            "NotebookRead": .reading,

            "Edit": .writing,
            "Write": .writing,
            "MultiEdit": .writing,
            "NotebookEdit": .writing,
            "TodoWrite": .writing,

            "Bash": .building,
            "BashOutput": .building,
            "KillShell": .building,

            "WebSearch": .searching,
            "WebFetch": .searching,

            "Task": .thinking,
            "Agent": .thinking,
            "Workflow": .thinking,
            "Skill": .thinking,

            // เครื่องมือของ Codex CLI — ชื่อเป็น snake_case จึงไม่ชนกับของ Claude Code
            // Codex เรียก "exec" แทบทุกอย่าง (แก้ไฟล์ผ่าน shell ด้วย) จึงจัดเป็น building
            // เหมือน Bash ส่วนการแพตช์ไฟล์มี event แยกของมันเอง
            "exec": .building,
            "shell": .building,
            "apply_patch": .writing,
            "update_plan": .thinking,
            "web_search": .searching,

            // คุยกับบริการนอกตัว ไม่ใช่อ่านไฟล์หรือค้นเว็บ — ควรแยกให้เห็นว่ารออีกฝั่งอยู่
            "LSP": .beacon,
            "ListMcpResourcesTool": .beacon,
            "ReadMcpResourceTool": .beacon,
            "ReadMcpResourceDirTool": .beacon,
        ],
        prefixes: [
            "mcp__": .beacon,
        ],
        fallback: .thinking
    )

    public init(
        exact: [String: VisualState],
        prefixes: [String: VisualState] = [:],
        fallback: VisualState = .thinking
    ) {
        self.exact = exact
        self.prefixes = prefixes
        self.fallback = fallback
    }

    public func state(for tool: String) -> VisualState {
        if let s = exact[tool] { return s }
        let match = prefixes
            .filter { tool.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }
        return match?.value ?? fallback
    }

    // MARK: - ไฟล์คอนฟิก

    /// รูปแบบไฟล์:
    /// ```json
    /// { "fallback": "thinking",
    ///   "tools": { "Read": "reading", "mcp__*": "searching" } }
    /// ```
    /// คีย์ที่ลงท้ายด้วย `*` คือกฎขึ้นต้นด้วย
    public static func load(from url: URL) throws -> ToolMap {
        struct File: Decodable {
            var fallback: String?
            var tools: [String: String]?
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        var map = ToolMap.default
        if let f = file.fallback, let s = VisualState(rawValue: f) { map.fallback = s }
        for (key, value) in file.tools ?? [:] {
            guard let state = VisualState(rawValue: value) else { continue }
            if key.hasSuffix("*") {
                map.prefixes[String(key.dropLast())] = state
            } else {
                map.exact[key] = state
            }
        }
        return map
    }

    /// อ่านคอนฟิกถ้ามี ไม่มีก็ใช้ค่าเริ่มต้น — ไฟล์เสียไม่ควรทำให้ daemon ตาย
    public static func loadOrDefault(_ url: URL) -> ToolMap {
        (try? load(from: url)) ?? .default
    }
}

import Foundation

/// สวิตช์หน้าตาของบรรทัด statusline ที่เราวาดเอง
///
/// อ่านจาก `~/.claude/statusline-config.txt` ซึ่งเป็นไฟล์เดิมของ Claude Usage.app
/// (รูปแบบ `KEY=VALUE` แบบ shell) — ใช้ไฟล์เดียวกันเพราะผู้ใช้ที่มาจากสคริปต์นั้น
/// ตั้งค่าไว้แล้ว การมีไฟล์ตั้งค่าตัวที่สองแปลว่าเขาต้องตั้งสองที่ให้ตรงกันตลอดไป
///
/// ค่าดีฟอลต์ตรงกับสคริปต์ต้นทางทุกตัว ไฟล์ที่ไม่มีอยู่จึงไม่ใช่กรณีพิเศษ
public struct StatuslineConfig: Sendable {
    public enum ColorMode: String, Sendable {
        case colored, monochrome, singleColor, perElement
    }

    public var showModel = true
    public var showDir = true
    public var showBranch = true
    public var showContext = true
    public var contextAsTokens = false
    public var showUsage = true
    public var showBar = true
    public var showPaceMarker = true
    public var showReset = true
    public var use24h = false
    public var showContextLabel = true
    public var showUsageLabel = true
    public var showResetLabel = true
    public var colorMode = ColorMode.colored
    public var singleColor = "#00BFFF"
    public var showProfile = false
    public var profileName = ""
    public var paceMarkerStepColors = true
    public var showWeekly = false
    public var showWeeklyBar = true
    public var showWeeklyPaceMarker = true
    public var showWeeklyReset = true
    public var showWeeklyLabel = true
    public var showExtraUsage = false
    public var showLinesChanged = true
    public var showTokenCount = true
    public var colorDir = "#0000EE"
    public var colorBranch = "#00BB00"
    public var colorModel = "#BBBB00"
    public var colorProfile = "#BB00BB"
    public var colorContext = "#00BBBB"
    public var colorSeparator = "#808080"
    public var colorUsage = ""
    public var colorPace = ""
    public var colorWeekly = ""
    public var colorExtra = ""

    public init() {}

    public static var path: URL {
        Paths.home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("statusline-config.txt")
    }

    public static func load(from url: URL = path) -> StatuslineConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return StatuslineConfig()
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> StatuslineConfig {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard !raw.hasPrefix("#"), let eq = raw.firstIndex(of: "=") else { continue }
            var value = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // ค่าถูกเขียนแบบ shell — เครื่องหมายคำพูดเป็นของ shell ไม่ใช่ของค่า
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
                value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            fields[String(raw[raw.startIndex..<eq])] = value
        }

        var c = StatuslineConfig()
        // "1" คือเปิด อย่างอื่นคือปิด — ตรงกับ `[ "$x" = "1" ]` ของสคริปต์ต้นทาง
        func flag(_ key: String, _ current: Bool) -> Bool {
            guard let v = fields[key] else { return current }
            return v == "1"
        }
        c.showModel = flag("SHOW_MODEL", c.showModel)
        c.showDir = flag("SHOW_DIRECTORY", c.showDir)
        c.showBranch = flag("SHOW_BRANCH", c.showBranch)
        c.showContext = flag("SHOW_CONTEXT", c.showContext)
        c.contextAsTokens = flag("CONTEXT_AS_TOKENS", c.contextAsTokens)
        c.showUsage = flag("SHOW_USAGE", c.showUsage)
        c.showBar = flag("SHOW_PROGRESS_BAR", c.showBar)
        c.showPaceMarker = flag("SHOW_PACE_MARKER", c.showPaceMarker)
        c.showReset = flag("SHOW_RESET_TIME", c.showReset)
        c.use24h = flag("USE_24_HOUR_TIME", c.use24h)
        c.showContextLabel = flag("SHOW_CONTEXT_LABEL", c.showContextLabel)
        c.showUsageLabel = flag("SHOW_USAGE_LABEL", c.showUsageLabel)
        c.showResetLabel = flag("SHOW_RESET_LABEL", c.showResetLabel)
        c.showProfile = flag("SHOW_PROFILE", c.showProfile)
        c.showWeekly = flag("SHOW_WEEKLY", c.showWeekly)
        c.showWeeklyBar = flag("SHOW_WEEKLY_BAR", c.showWeeklyBar)
        c.showWeeklyPaceMarker = flag("SHOW_WEEKLY_PACE_MARKER", c.showWeeklyPaceMarker)
        c.showWeeklyReset = flag("SHOW_WEEKLY_RESET_TIME", c.showWeeklyReset)
        c.showWeeklyLabel = flag("SHOW_WEEKLY_LABEL", c.showWeeklyLabel)
        c.showExtraUsage = flag("SHOW_EXTRA_USAGE", c.showExtraUsage)
        c.showLinesChanged = flag("SHOW_LINES_CHANGED", c.showLinesChanged)
        c.showTokenCount = flag("SHOW_TOKEN_COUNT", c.showTokenCount)
        // ตัวนี้กลับด้าน: สคริปต์ถือว่า "ไม่ใช่ 0" คือเปิด ค่าที่พิมพ์ผิดจึงยังได้สีเป็นขั้น
        if let v = fields["PACE_MARKER_STEP_COLORS"] { c.paceMarkerStepColors = v != "0" }

        if let v = fields["COLOR_MODE"], let mode = ColorMode(rawValue: v) { c.colorMode = mode }
        if let v = fields["SINGLE_COLOR"], !v.isEmpty { c.singleColor = v }
        if let v = fields["PROFILE_NAME"] { c.profileName = v }
        // สีรายชิ้นที่เป็นค่าว่างมีความหมาย ("ไม่กำหนด" = ใช้เกรเดียนต์ปกติ) จึงรับค่าว่างด้วย
        if let v = fields["ELEMENT_COLOR_DIR"] { c.colorDir = v }
        if let v = fields["ELEMENT_COLOR_BRANCH"] { c.colorBranch = v }
        if let v = fields["ELEMENT_COLOR_MODEL"] { c.colorModel = v }
        if let v = fields["ELEMENT_COLOR_PROFILE"] { c.colorProfile = v }
        if let v = fields["ELEMENT_COLOR_CONTEXT"] { c.colorContext = v }
        if let v = fields["ELEMENT_COLOR_SEPARATOR"] { c.colorSeparator = v }
        if let v = fields["ELEMENT_COLOR_USAGE"] { c.colorUsage = v }
        if let v = fields["ELEMENT_COLOR_PACE"] { c.colorPace = v }
        if let v = fields["ELEMENT_COLOR_WEEKLY"] { c.colorWeekly = v }
        if let v = fields["ELEMENT_COLOR_EXTRA"] { c.colorExtra = v }
        return c
    }
}

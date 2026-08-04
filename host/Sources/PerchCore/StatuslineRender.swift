import Foundation

/// วาดบรรทัด statusline เอง เมื่อผู้ใช้ไม่มีสคริปต์เดิมให้ส่งงานต่อ
///
/// เดิมทางนี้พิมพ์แค่ "5h 12% · 7d 30%" ซึ่งทำให้คนที่เปิด "Read quota from the statusline"
/// โดยยังไม่เคยตั้ง statusline รู้สึกว่าเราแย่งช่องไปทำของที่ด้อยกว่า ที่นี่จึงเป็น
/// port ของ `statusline-command.sh` (ตัวที่มากับ Claude Usage.app) มาไว้ในไบนารี:
/// องค์ประกอบชุดเดียวกัน ไอคอนชุดเดียวกัน สีชุดเดียวกัน และอ่านไฟล์ตั้งค่าไฟล์เดียวกัน
///
/// สิ่งที่ต้องไม่ลืม: ฟังก์ชันนี้ถูกเรียกทุกครั้งที่ Claude Code render statusline
/// (ทุก 10 วินาทีเป็นอย่างช้า) ทุกอย่างจึงต้องไม่ throw และไม่ค้าง — ข้อมูลที่หาย
/// แปลว่าชิ้นนั้นหายไปจากบรรทัด ไม่ใช่บรรทัดพัง
public enum StatuslineRender {
    /// สิ่งที่ git บอกเกี่ยวกับโฟลเดอร์ที่ session นี้อยู่ — `nil` เมื่อไม่ใช่ repo
    public struct GitInfo: Sendable, Equatable {
        public var branch: String?
        public var added: Int
        public var removed: Int

        public init(branch: String? = nil, added: Int = 0, removed: Int = 0) {
            self.branch = branch
            self.added = added
            self.removed = removed
        }
    }

    /// ทางเข้าที่ `--usage-cache` ใช้ — เก็บ I/O ทั้งหมดไว้ที่นี่ที่เดียว
    public static func line(
        json: Data,
        now: Date = Date(),
        config: StatuslineConfig = .load(),
        cacheURL: URL = Paths.usageCache
    ) -> String? {
        let cache = (try? String(contentsOf: cacheURL, encoding: .utf8)).map(UsageReader.parse)
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let dir = currentDir(root)
        let git = config.showBranch || config.showLinesChanged
            ? GitSummary.of(dir: dir, wantLines: config.showLinesChanged) : nil
        return render(root: root, cache: cache ?? [:], config: config, git: git, now: now)
    }

    // MARK: - การประกอบบรรทัด

    public static func render(
        root: [String: Any],
        cache: [String: String],
        config: StatuslineConfig,
        git: GitInfo?,
        now: Date
    ) -> String? {
        let p = Palette(config)
        var line1: [String] = []
        var line2: [String] = []

        if config.showDir, let dir = currentDir(root) {
            line1.append(p.wrap(p.blue, "❯ \(URL(fileURLWithPath: dir).lastPathComponent)"))
        }
        if config.showBranch, let branch = git?.branch, !branch.isEmpty {
            line1.append(p.wrap(p.green, "⎇ \(branch)"))
        }
        if config.showModel, let model = string(root, path: ["model", "display_name"]) {
            line1.append(p.wrap(p.yellow, "⌘ \(model)"))
        }
        if config.showLinesChanged, let git, git.added > 0 || git.removed > 0 {
            // สองสีในชิ้นเดียว: เขียวอ่อนสุดของเกรเดียนต์กับแดงเข้มสุด ตามสคริปต์ต้นทาง
            line1.append(
                p.wrap(p.levels[0], "+\(git.added) ") + p.wrap(p.levels[9], "-\(git.removed)"))
        }
        if config.showProfile, !config.profileName.isEmpty {
            line1.append(p.wrap(p.magenta, "● \(config.profileName)"))
        }
        if let text = contextText(root, config: config, palette: p) { line1.append(text) }
        if let text = tokenCountText(root, config: config, palette: p) { line1.append(text) }

        if config.showUsage {
            line2.append(
                windowText(
                    cache: cache, config: config, palette: p, now: now, weekly: false) ?? "")
            if config.showWeekly,
                let weekly = windowText(
                    cache: cache, config: config, palette: p, now: now, weekly: true) {
                line2.append(weekly)
            }
            if let extra = extraUsageText(cache: cache, config: config, palette: p) {
                line2.append(extra)
            }
        }

        let separator = p.wrap(p.gray, " │ ")
        let out = [line1, line2.filter { !$0.isEmpty }]
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: separator) }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    // MARK: - ชิ้นส่วนของบรรทัดแรก

    static func contextText(
        _ root: [String: Any], config: StatuslineConfig, palette p: Palette
    ) -> String? {
        guard config.showContext, let size = number(root, key: "context_window_size"), size > 0
        else { return nil }
        let used = tokensIn(root)
        let pct = used * 100 / size
        // เกณฑ์สีของ context ไม่ใช่เกรเดียนต์ 10 ขั้นแบบโควตา — มันมีแค่สามช่วง
        let color = pct <= 50 ? p.cyan : (pct <= 75 ? p.yellow : p.levels[8])
        let label = config.showContextLabel ? "Ctx: " : ""
        if config.contextAsTokens {
            let body = used >= 1000 ? "\(used / 1000)K" : "\(used)"
            return p.wrap(color, "◐ \(label)\(body)")
        }
        return p.wrap(color, "◐ \(label)\(pct)%")
    }

    static func tokenCountText(
        _ root: [String: Any], config: StatuslineConfig, palette p: Palette
    ) -> String? {
        guard config.showTokenCount else { return nil }
        let input = tokensIn(root)
        let output = number(root, key: "output_tokens") ?? 0
        guard input > 0 || output > 0 else { return nil }
        var body = "⧉ ↑\(tokenCount(input)) ↓\(tokenCount(output))"
        if let size = number(root, key: "context_window_size"), size > 0 {
            body += "/\(tokenCount(size))"
        }
        return p.wrap(p.cyan, body + " tok")
    }

    // MARK: - ชิ้นส่วนของบรรทัดที่สอง

    /// หน้าต่างโควตาหนึ่งบาน — 5 ชั่วโมงกับ 7 วันต่างกันแค่คีย์ ความยาว และไอคอน
    /// จึงเขียนครั้งเดียว ไม่งั้นกฎเรื่องขีด pace จะมีสองสำเนาให้เพี้ยนกันวันหนึ่ง
    static func windowText(
        cache: [String: String], config: StatuslineConfig, palette p: Palette,
        now: Date, weekly: Bool
    ) -> String? {
        let pctKey = weekly ? "WEEKLY_UTILIZATION" : "UTILIZATION"
        let resetKey = weekly ? "WEEKLY_RESETS_AT" : "RESETS_AT"
        let window = weekly ? UsageReader.weeklyWindow : UsageReader.sessionWindow
        // สคริปต์ต้นทางถือว่าตัวเลขที่เก่ากว่า 5 นาทีคือ "ยังไม่รู้" แล้วไปยิงเน็ตเอง
        // เราไม่มีทางยิงเน็ตตรงนี้ (ไม่ถือ credential) แต่ยังใช้เกณฑ์เดียวกันเพื่อไม่ให้
        // ตัวเลขที่ตายแล้วดูเหมือนของสด — ปกติ cache เพิ่งถูกเขียนเมื่อครู่โดย ingest
        let fresh = cache["TIMESTAMP"].flatMap(TimeInterval.init)
            .map { now.timeIntervalSince1970 - $0 < 300 } ?? false
        guard fresh, let percent = cache[pctKey].flatMap(Int.init) else {
            // หน้าต่างรายสัปดาห์ที่ไม่มีข้อมูลหายไปเงียบๆ ส่วน 5 ชั่วโมงบอกว่ายังไม่รู้
            // เพราะช่องนั้นคือเหตุผลที่บรรทัดนี้มีอยู่
            guard !weekly else { return nil }
            return p.wrap(p.yellow, config.showUsageLabel ? "⧖ Usage: ~" : "⧖ ~")
        }

        var color = p.level(percent)
        if config.colorMode == .perElement, weekly, !config.colorWeekly.isEmpty {
            color = Palette.ansi(config.colorWeekly)
        }
        let resetsAt = cache[resetKey].flatMap(UsageWriter.parseISO)

        var bar = ""
        if weekly ? config.showWeeklyBar : config.showBar {
            bar = Self.bar(percent)
            if (weekly ? config.showWeeklyPaceMarker : config.showPaceMarker), let resetsAt {
                bar = mark(
                    bar, resetsAt: resetsAt, now: now, window: window, percent: percent,
                    config: config, palette: p, fallback: color)
            }
        }

        var resetText = ""
        if (weekly ? config.showWeeklyReset : config.showReset), let resetsAt {
            resetText = self.resetText(resetsAt, now: now, config: config, weekly: weekly)
        }

        let icon = weekly ? "⧗" : "⧖"
        let label = weekly
            ? (config.showWeeklyLabel ? "Weekly: " : "")
            : (config.showUsageLabel ? "Usage: " : "")
        return p.wrap(color, "\(icon) \(label)\(percent)%\(bar)\(resetText)")
    }

    static func extraUsageText(
        cache: [String: String], config: StatuslineConfig, palette p: Palette
    ) -> String? {
        guard config.showExtraUsage,
            let used = cache["COST_USED"], let limit = cache["COST_LIMIT"].flatMap(Double.init),
            let currency = cache["COST_CURRENCY"], limit > 0,
            let usedValue = Double(used)
        else { return nil }
        let pct = min(100, max(0, Int(usedValue / limit * 100)))
        var color = p.level(pct)
        if config.colorMode == .perElement, !config.colorExtra.isEmpty {
            color = Palette.ansi(config.colorExtra)
        }
        return p.wrap(color, "◈ \(used) \(currency)")
    }

    // MARK: - แถบและขีด pace

    /// แถบ 10 ช่อง นำหน้าด้วยช่องว่างหนึ่งตัว — ช่องว่างเป็นส่วนหนึ่งของแถบ ไม่ใช่ตัวคั่น
    /// เพราะสูตรตำแหน่งขีดข้างล่างนับดัชนีจากสตริงที่มีมันอยู่แล้ว
    static func bar(_ percent: Int) -> String {
        let filled = percent <= 0 ? 0 : (percent >= 100 ? 10 : (percent * 10 + 50) / 100)
        return " " + String(repeating: "▓", count: filled)
            + String(repeating: "░", count: 10 - filled)
    }

    /// แทนช่องหนึ่งของแถบด้วยขีด ณ ตำแหน่งที่ "เวลาเดินไปถึง"
    ///
    /// เทียบสองอย่างในภาพเดียว: แถบคือโควตาที่ใช้ไป ขีดคือเวลาที่ผ่านไป
    /// ขีดอยู่ขวาของแถบ = ใช้ช้ากว่าเวลา สีของขีดคือความเร็วที่คาดการณ์ไปทั้งหน้าต่าง
    static func mark(
        _ bar: String, resetsAt: Date, now: Date, window: Int, percent: Int,
        config: StatuslineConfig, palette p: Palette, fallback: String
    ) -> String {
        let remaining = Int(resetsAt.timeIntervalSince(now))
        guard remaining > 0, remaining < window else { return bar }
        let elapsed = window - remaining
        let position = min(9, max(0, (elapsed * 10 + window / 2) / window))

        var color = fallback
        // ต่ำกว่า 3% ของหน้าต่าง (0.5% สำหรับรายสัปดาห์) การคาดการณ์ยังเป็นเสียงรบกวน:
        // ใช้ไป 1% ในนาทีแรกจะฉายภาพว่าจะทะลุ 100% ซึ่งไม่ได้บอกอะไรจริง
        let settled = elapsed >= (window == UsageReader.weeklyWindow ? 3024 : 540)
        if config.paceMarkerStepColors, settled {
            let projected = percent * window / elapsed
            switch projected {
            case ..<50: color = p.pace[0]
            case ..<75: color = p.pace[1]
            case ..<90: color = p.pace[2]
            case ..<100: color = p.pace[3]
            case ..<120: color = p.pace[4]
            default: color = p.pace[5]
            }
        }

        let chars = Array(bar)
        guard chars.indices.contains(position + 1) else { return bar }
        // ปิดสีของขีดแล้วทาสีเดิมกลับ ไม่งั้นช่องที่เหลือของแถบจะติดสีของขีดไปด้วย
        return String(chars[...position]) + p.wrap(color, "┃") + fallback
            + String(chars[(position + 2)...])
    }

    // MARK: - เวลา

    static func resetText(
        _ resetsAt: Date, now: Date, config: StatuslineConfig, weekly: Bool
    ) -> String {
        // ปัดเป็นนาทีที่ใกล้ที่สุด ไม่งั้นตัวเลขจะกระพริบระหว่าง 6:59 กับ 7:00 ทุกสิบวินาที
        let epoch = (resetsAt.timeIntervalSince1970 / 60).rounded() * 60
        let shown = Date(timeIntervalSince1970: epoch)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if weekly {
            f.dateFormat = config.use24h ? "EEE HH:mm" : "EEE hh:mm a"
        } else {
            f.dateFormat = config.use24h ? "HH:mm" : "hh:mm a"
        }
        // นับถอยหลังจากเวลาจริง ไม่ใช่เวลาที่ปัดแล้ว — ที่ปัดคือสิ่งที่แสดง ไม่ใช่ความจริง
        let remaining = Int(resetsAt.timeIntervalSince(now))
        let left = weekly ? daysHours(remaining) : hours(remaining)
        // ป้าย "Reset:" มีเฉพาะหน้าต่าง 5 ชั่วโมง ตามสคริปต์ต้นทาง
        let label = (!weekly && config.showResetLabel) ? "Reset: " : ""
        return " ⏲ \(label)\(f.string(from: shown)) (\(left))"
    }

    static func hours(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d Hr", s / 3600, (s % 3600) / 60)
    }

    static func daysHours(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let days = s / 86400
        let rest = s % 86400
        guard days > 0 else { return hours(rest) }
        return String(
            format: "%d %@ %d:%02d Hr", days, days == 1 ? "Day" : "Days", rest / 3600,
            (rest % 3600) / 60)
    }

    // MARK: - ตัวเลขและ JSON

    static func tokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return v == v.rounded(.down) ? "\(Int(v))M" : String(format: "%.1fM", v)
        }
        if n >= 1000 {
            let v = Double(n) / 1000
            return v == v.rounded(.down) ? "\(Int(v))K" : String(format: "%.1fK", v)
        }
        return "\(n)"
    }

    /// จำนวน token ที่ "อยู่ในหน้าต่าง context ตอนนี้" — input + cache ทั้งสองชนิด
    static func tokensIn(_ root: [String: Any]) -> Int {
        (number(root, key: "input_tokens") ?? 0)
            + (number(root, key: "cache_creation_input_tokens") ?? 0)
            + (number(root, key: "cache_read_input_tokens") ?? 0)
    }

    static func currentDir(_ root: [String: Any]) -> String? {
        string(root, path: ["workspace", "current_dir"]) ?? string(root, path: ["cwd"])
    }

    static func string(_ root: [String: Any], path: [String]) -> String? {
        var node: Any = root
        for key in path {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return (node as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// ค้นคีย์ตัวเลขทั้งก้อน JSON แทนที่จะผูกกับพาธ
    ///
    /// สคริปต์ต้นทางใช้ `grep` ซึ่งไม่สนใจว่าคีย์อยู่ชั้นไหน และรูปร่างของ payload
    /// ฝั่ง Claude Code ก็ขยับมาแล้วหลายรอบ การไล่ทั้งก้อนจึงทนกว่า — เรียงคีย์ก่อนไล่
    /// เพื่อให้ผลลัพธ์เท่าเดิมทุกครั้งเมื่อมีคีย์ชื่อซ้ำกันคนละชั้น
    static func number(_ node: Any, key: String) -> Int? {
        if let dict = node as? [String: Any] {
            if let value = dict[key] as? NSNumber { return value.intValue }
            for (_, child) in dict.sorted(by: { $0.key < $1.key }) {
                if let found = number(child, key: key) { return found }
            }
        }
        if let array = node as? [Any] {
            for child in array {
                if let found = number(child, key: key) { return found }
            }
        }
        return nil
    }

    // MARK: - สี

    /// จานสีทั้งใบ แปลงจากโหมดในไฟล์ตั้งค่าครั้งเดียว แล้วที่เหลือแค่หยิบใช้
    public struct Palette: Sendable {
        static let escape = "\u{1B}"
        public static let reset = "\(escape)[0m"

        var blue, green, gray, yellow, cyan, magenta: String
        var levels: [String]
        var pace: [String]

        /// เกรเดียนต์ 10 ขั้น เขียวเข้ม → แดงเข้ม และสี pace 6 ขั้น
        /// เป็นเลข 256 สี ไม่ใช่ truecolor เพราะต้องออกมาเหมือนสคริปต์ต้นทางเป๊ะ
        static let gradient = [22, 28, 34, 100, 142, 178, 172, 166, 160, 124]
            .map { "\(escape)[38;5;\($0)m" }
        static let paceSteps = [34, 37, 178, 208, 160, 135].map { "\(escape)[38;5;\($0)m" }

        init(_ c: StatuslineConfig) {
            switch c.colorMode {
            case .monochrome:
                blue = ""; green = ""; gray = ""; yellow = ""; cyan = ""; magenta = ""
                levels = Array(repeating: "", count: 10)
                pace = Array(repeating: "", count: 6)
            case .singleColor:
                let one = Palette.ansi(c.singleColor)
                blue = one; green = one; gray = one; yellow = one; cyan = one; magenta = one
                levels = Array(repeating: one, count: 10)
                pace = Array(repeating: one, count: 6)
            case .perElement:
                blue = Palette.ansi(c.colorDir)
                green = Palette.ansi(c.colorBranch)
                yellow = Palette.ansi(c.colorModel)
                magenta = Palette.ansi(c.colorProfile)
                cyan = Palette.ansi(c.colorContext)
                gray = Palette.ansi(c.colorSeparator)
                levels = c.colorUsage.isEmpty
                    ? Palette.gradient
                    : Array(repeating: Palette.ansi(c.colorUsage), count: 10)
                pace = c.colorPace.isEmpty
                    ? Palette.paceSteps
                    : Array(repeating: Palette.ansi(c.colorPace), count: 6)
            case .colored:
                blue = "\(Palette.escape)[0;34m"
                green = "\(Palette.escape)[0;32m"
                gray = "\(Palette.escape)[0;90m"
                yellow = "\(Palette.escape)[0;33m"
                cyan = "\(Palette.escape)[0;36m"
                magenta = "\(Palette.escape)[0;35m"
                levels = Palette.gradient
                pace = Palette.paceSteps
            }
            // สี pace ที่เป็นขั้นจริงชนะโหมดสีเสมอ (ยกเว้นขาวดำ) — ขีดนี้คือคำเตือน
            // การให้มันกลืนไปกับสีเดียวของทั้งบรรทัดทำให้คำเตือนหายไป
            if c.paceMarkerStepColors, c.colorMode != .monochrome { pace = Palette.paceSteps }
        }

        func level(_ percent: Int) -> String {
            levels[min(9, max(0, (percent - 1) / 10))]
        }

        /// ครอบด้วยสีแล้วปิดท้ายด้วย reset — สีว่าง (ขาวดำ) ไม่ต้องปิดอะไร
        func wrap(_ color: String, _ body: String) -> String {
            color.isEmpty ? body : color + body + Palette.reset
        }

        /// `#RRGGBB` → escape 24 บิต ค่าที่อ่านไม่ออกแปลว่า "ไม่กำหนดสี"
        static func ansi(_ hex: String) -> String {
            let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard text.count == 6, let value = Int(text, radix: 16) else { return "" }
            return "\(escape)[38;2;\((value >> 16) & 255);\((value >> 8) & 255);\(value & 255)m"
        }
    }
}

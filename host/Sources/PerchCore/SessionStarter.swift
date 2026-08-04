import Foundation

/// รอบหนึ่งจบลงด้วยอะไร — แยกเฉพาะเท่าที่เปลี่ยนการตัดสินใจของรอบถัดไป
/// เส้นแบ่งเดียวกับ `PollBlock`: อันที่ล็อกคืออันที่ยิงต่อไปก็ได้ผลเดิม
public enum SessionOutcome: Equatable {
    case ok
    /// ไม่มี `claude` ให้เรียก — พก path ที่ไล่หามาด้วย คนที่ติดตั้งไว้ที่แปลกๆ ต้องรู้ว่าเรามองที่ไหน
    case noBinary([String])
    /// ยังไม่ได้ login — ยิงอีกกี่รอบก็จบแบบเดิม
    case authFailed
    /// เน็ตสะดุด ครบเวลา หรือแยกไม่ออก — รอบหน้าก็หายเอง
    case failed
}

/// เหตุที่ session จะไม่ถูกเริ่มจนกว่าผู้ใช้จะลงมือ
///
/// คนละเรื่องกับ `PollBlock` แม้ทรงเหมือนกัน — ให้ผู้ใช้ทำคนละอย่าง
public enum StartBlock: Equatable {
    case noBinary([String])
    case notLoggedIn
}

/// เริ่ม Claude Code session สั้นๆ ให้เองเมื่อไม่มีหน้าต่าง 5 ชั่วโมงเปิดอยู่
///
/// ที่เดียวในฝั่ง host ที่ *ใช้* โควตา รั้วจึงไม่ใช่ของประดับ: ตัวยิงที่ไม่มีรั้วจะเริ่ม session
/// ใหม่ทุกวินาทีจนเลขโผล่ (ได้ถึงหนึ่งรอบ poll เต็ม) — เผาโควตาสิบรอบเพื่อเปิดหน้าต่างเดียว
///
/// ไม่มี timer ของตัวเอง เหมือน `UsagePoller` — ถูกป้อน `tick(now:usage:)` จากนาฬิกาของแอป
public final class SessionStarter {
    /// spawn หนึ่งตัว แล้วคืนวิธีฆ่ามัน — ทรงเดียวกับ `UsagePoller.Launcher`
    ///
    /// ลูกพูดกลับเป็น `SessionOutcome` ไม่ใช่ exit code ดิบ: การแปลเป็นชนิดของความล้มเหลว
    /// เป็นความรู้ของฝั่งที่ spawn (`SessionProcess.classify`) ที่นี่ตัดสินแค่ว่าชนิดไหนล็อก
    public typealias Launcher = (_ done: @escaping (SessionOutcome) -> Void) -> () -> Void

    /// ลูกที่ค้างกินช่องเดียวที่มีไว้ตลอดกาล — เลขเดียวกับ `UsagePoller.timeout`
    public static let timeout: TimeInterval = 30

    /// เว้นห้านาทีนับจากลูกตัวก่อนจบ
    ///
    /// อยู่คู่กับกติกาหนึ่งครั้งต่อหน้าต่าง ไม่ใช่แทนกัน — เย็นตัวอย่างเดียวยังลองใหม่ชั่วนิรันดร์
    /// เมื่อ session เริ่มไม่ขึ้น ส่วนหนึ่งครั้งต่อหน้าต่างอย่างเดียวยังยิงรัวได้ก่อน poll รายงาน
    public static let cooldown: TimeInterval = 300

    /// กติกา "หนึ่งครั้งต่อหนึ่งหน้าต่าง" เขียนเป็นสถานะ ไม่ใช่การเทียบ id ของหน้าต่าง
    ///
    /// host ไม่เคยเห็น id มีแต่ `resets_at` ที่แปลงเป็น countdown แล้ว การเทียบสตริงเวลา
    /// ข้าม seam คือกฎสำเนาที่สองที่จะเพี้ยนจากแบดจ์วันหนึ่ง
    private enum Arm {
        case ready
        /// ยิงไปแล้ว รอเห็นหน้าต่างเกิดขึ้นจริงก่อน
        case spent
        /// เห็นหน้าต่างแล้ว พอมันหายไปคือหน้าต่างใหม่รอบหน้า
        case sawWindow
    }

    /// ติ๊กในเมนู — ปิดแล้วเปิดใหม่คือคำสั่ง "ลองอีกที"
    ///
    /// ล้างสถานะตอน *เปิด* ไม่ใช่ตอนปิด: คนที่ปิดสวิตช์ไม่ได้บอกว่าเขาไปแก้อะไรมา
    public var enabled: Bool {
        didSet {
            guard enabled, !oldValue else { return }
            unblock()
        }
    }

    /// เหตุที่จะไม่มี session จนกว่าผู้ใช้จะลงมือ — `nil` คือไม่มีอะไรจะบอก
    public private(set) var blocked: StartBlock?

    private let launch: Launcher
    private var arm: Arm = .ready
    private var startedAt: Date?
    private var finishedAt: Date?
    private var kill: (() -> Void)?
    /// ลูกที่ถูกฆ่าไปแล้วยังพูดทีหลังได้ — รุ่นที่ไม่ตรงกันคือเสียงจากอดีต
    private var generation = 0
    /// ลูกจบแล้วแต่ยังไม่มีใครบอกว่ากี่โมง — callback ไม่มีนาฬิกาติดมา และการหยิบ `Date()`
    /// ตรงนั้นคือเอานาฬิกาจริงกลับเข้ามาในตรรกะที่ตั้งใจให้ฉีดเวลาได้ทั้งอัน
    private var pendingFinish = false

    public init(enabled: Bool = false, launch: @escaping Launcher) {
        self.enabled = enabled
        self.launch = launch
    }

    public var isRunning: Bool { startedAt != nil }

    /// `usage` คือแถวเดียวกับที่แบดจ์กิน — เงื่อนไขยิงคือ "แบดจ์ไม่มีอะไรจะบอก"
    ///
    /// ส่งทั้งก้อนแทนเปอร์เซ็นต์ เพราะกฎ "มีหน้าต่างไหม" เป็นของ `MenuBadge` อยู่แล้ว
    /// (ไม่รู้ ≠ ศูนย์ · countdown ถึงศูนย์ = หน้าต่างตายแล้ว)
    public func tick(now: Date = Date(), usage: [UsageSnap]?) {
        // เดินสถานะก่อนทุกทางออก แม้สวิตช์ปิดหรือมีลูกวิ่งอยู่ — หน้าต่างที่เกิดดับตอนไม่ได้มอง
        // ก็ผ่านไปแล้วจริง และหน้าต่างที่ลูกเราเปิดมักโผล่ตั้งแต่ลูกยังไม่ตาย
        let hasWindow = MenuBadge.from(usage) != nil
        observe(hasWindow)

        if let startedAt {
            guard now.timeIntervalSince(startedAt) >= Self.timeout else { return }
            // ลูกที่ถูกฆ่าตรงนี้พูดผ่าน `finished` ไม่ได้แล้ว (รุ่นไม่ตรง) บรรทัดนี้จึงเป็นที่เดียว
            // ที่บอกว่ารอบนั้นจบยังไง — และไม่ล็อก ด้วยเหตุผลเดียวกับ `.failed`
            Log.info("auto-start: the session took too long and was stopped")
            stop()
            finishedAt = now
            return
        }
        if pendingFinish {
            pendingFinish = false
            finishedAt = now
        }

        guard enabled, blocked == nil, !hasWindow, arm == .ready else { return }
        if let finishedAt, now.timeIntervalSince(finishedAt) < Self.cooldown { return }
        start(now)
    }

    /// ปิดแอปแล้วต้องไม่มีลูกกำพร้า — เหตุผลเดียวกับ `UsagePoller.stop`
    public func stop() {
        kill?()
        generation += 1
        kill = nil
        startedAt = nil
    }

    private func observe(_ hasWindow: Bool) {
        switch (arm, hasWindow) {
        case (.spent, true): arm = .sawWindow
        case (.sawWindow, false): arm = .ready
        default: break
        }
    }

    private func start(_ now: Date) {
        generation += 1
        let gen = generation
        startedAt = now
        arm = .spent
        let handle = launch { [weak self] code in
            self?.finished(gen, code)
        }
        // ลูกที่เริ่มไม่ขึ้นตอบกลับมาก่อนบรรทัดนี้ได้ — เก็บวิธีฆ่าลูกที่ตายแล้วไว้แปลว่า
        // `stop()` รอบหน้าจะไปฆ่าอะไรที่ไม่ใช่ลูกของเรา
        if isRunning { kill = handle }
    }

    private func finished(_ gen: Int, _ outcome: SessionOutcome) {
        guard gen == generation else { return }
        startedAt = nil
        kill = nil
        pendingFinish = true

        // รอบที่ไม่สำเร็จไม่ได้เปิดหน้าต่างไว้ให้รอ — ปล่อย `.spent` ค้างคือรอสิ่งที่ไม่มีวันมา
        // ทำให้ความล้มเหลวชั่วคราวครั้งเดียวฆ่าฟีเจอร์ถาวรพอๆ กับล็อก แต่เงียบกว่า
        if outcome != .ok { arm = .ready }

        switch outcome {
        case .ok:
            blocked = nil
        case .noBinary(let searched):
            blocked = .noBinary(searched)
            Log.info(
                "auto-start: stopped — no claude binary in \(searched.joined(separator: ", "))")
        case .authFailed:
            blocked = .notLoggedIn
            Log.info("auto-start: stopped — claude is not logged in")
        case .failed:
            // แยกไม่ออกว่าเพราะอะไร = ไม่มีอะไรให้ผู้ใช้ทำ การล็อกตรงนี้คือปิดฟีเจอร์ทิ้ง
            // เพราะเน็ตสะดุดครั้งเดียว
            break
        }
    }

    /// ล้างสถานะล็อกแล้วให้โอกาสยิงทันที — ไม่ต้องปิดเปิดแอป
    ///
    /// ล้าง `arm` ด้วย ไม่ใช่แค่ `blocked`: รอบที่ล็อกยิงไปแล้วหนึ่งครั้ง จึงค้าง `.spent` เสมอ
    /// และหน้าต่างที่มันรอจะไม่มีวันมา = ล็อกตัวที่สองที่ปลดไม่ได้ · เย็นตัวก็ล้าง เพราะเป็น
    /// วินัยของนาฬิกาแอป ไม่ใช่ของคนที่เพิ่งลงมือแก้แล้วสั่งลองใหม่
    private func unblock() {
        blocked = nil
        finishedAt = nil
        arm = .ready
    }
}

/// `claude` อยู่ที่ไหน
///
/// แอปที่ปล่อยผ่าน LaunchServices ได้ PATH ของ launchd ซึ่งไม่มีที่ที่ `claude` อยู่จริงสักที่
/// การเรียกชื่อเปล่าๆ จึงล้มเหลวเสมอบนเครื่องที่ติดตั้งถูกต้อง
public enum ClaudeBinary {
    /// ผลของการไล่หา — พก path ที่ค้นมาด้วยเสมอ เพราะ "หาไม่เจอ" ที่ไม่บอกว่าหาที่ไหน
    /// ไม่ช่วยคนที่ติดตั้งไว้ที่แปลกๆ
    public enum Found: Equatable {
        case at(URL)
        case missing([String])
    }

    /// path ที่ผู้ใช้ชี้เอง — ไม่มี UI โดยตั้งใจ
    ///
    ///     defaults write com.perch.daemon claudePath /where/claude/is
    ///
    /// คนที่ต้องใช้คือคนที่ติดตั้งนอกสี่ที่ข้างล่าง ซึ่งน้อยเกินกว่าจะกินที่ถาวรในเมนู
    public static let overrideKey = "claudePath"

    /// ที่ที่ `claude` อยู่ได้จริงบนเครื่องที่ติดตั้งตามปกติ
    public static var knownPaths: [URL] {
        [
            Paths.home.appendingPathComponent(".local/bin/claude"),
            Paths.home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
    }

    /// ค่าที่ผู้ใช้ตั้งไว้ ถ้ามีและไม่ใช่ที่ว่าง
    public static func override(_ defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// ค่าที่ผู้ใช้ชี้เอง *แทนที่* รายการทั้งอัน ไม่ใช่ถูกเติมท้าย — การไล่ต่อไปที่อื่นเมื่อตัวนั้น
    /// ใช้ไม่ได้คือการเงียบๆ ไปใช้ตัวที่เขาไม่ได้เลือก
    public static func candidates(override: String? = ClaudeBinary.override()) -> [URL] {
        guard let override else { return knownPaths }
        return [URL(fileURLWithPath: (override as NSString).expandingTildeInPath)]
    }

    /// ตัวแรกที่มีอยู่จริงและ execute ได้
    public static func locate(_ list: [URL] = candidates()) -> Found {
        if let found = list.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return .at(found)
        }
        return .missing(list.map(\.path))
    }
}

/// ตัว spawn จริง — และคนเดียวที่รู้ว่า `claude` พูดว่าอะไรตอนไหน
///
/// `classify` อยู่ตรงนี้เพราะเป็นความรู้เกี่ยวกับโปรเซสลูก ไม่ใช่กติกาว่าใครล็อก —
/// กติกานั้นอยู่ที่ `SessionStarter`
public enum SessionProcess {
    /// สั้นที่สุดเท่าที่ยังเป็น session จริง — ราคาทั้งหมดของฟีเจอร์นี้คือค่าเปิด session
    static let prompt = "ok"

    /// cwd ว่างเปล่า จึงไม่มี `CLAUDE.md` ของโปรเจกต์ไหนถูกลากเข้า prompt ที่ไม่ได้ทำงาน
    public static func workDir() -> URL {
        let dir = Paths.stateDir.appendingPathComponent("idle-session", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `claude` ใช้ exit code 1 กับทุกอย่างที่ผิดพลาด สิ่งที่แยก "ยังไม่ login" ออกจาก
    /// "เน็ตหลุด" จึงเป็นข้อความตอนตาย ไม่ใช่ตัวเลข · รายการนี้จงใจสั้น: marker ที่กว้างไป
    /// เปลี่ยนความล้มเหลวชั่วคราวเป็นล็อกถาวรที่ผู้ใช้ต้องมาปลดเอง ส่วนแคบไปแค่ยิงซ้ำอีกไม่กี่รอบ
    static let authMarkers = [
        "please run /login",
        "invalid api key",
        "oauth token has expired",
        "authentication_error",
    ]

    /// สิ่งที่ลูกพูดตอนตาย แปลเป็นชนิดของความล้มเหลว
    public static func classify(code: Int32, output: String) -> SessionOutcome {
        guard code != 0 else { return .ok }
        let text = output.lowercased()
        if authMarkers.contains(where: text.contains) { return .authFailed }
        return .failed
    }

    /// `-p` = one-shot print mode: ไม่มี TTY ไม่มีหน้าต่าง Terminal โผล่ ลูกจบเอง
    ///
    /// `haiku` เพราะหน้าต่าง 5 ชั่วโมงนับรวมทุกโมเดล (เฉพาะ `weekly_scoped` ที่แยกตามโมเดล)
    ///
    /// MCP ปิดทั้งหมด — ต้องเป็น `{"mcpServers":{}}` ไม่ใช่ `{}` เปล่า: `claude` ตรวจ schema
    /// และตายด้วย code 1 ("expected record, received undefined") ซึ่งแยกไม่ออกจากความ
    /// ล้มเหลวอื่น · ที่ปิดเพราะ schema ของ server ทุกตัวคือส่วนใหญ่ที่สุดของค่าเปิด session ·
    /// **hooks ไม่ปิด** เพราะเป็นทางเดียวที่ daemon จะรู้ว่ามี session
    public static func launcher(_ locate: @escaping () -> ClaudeBinary.Found = {
        ClaudeBinary.locate()
    }) -> SessionStarter.Launcher {
        { done in
            let executable: URL
            switch locate() {
            case .at(let found):
                executable = found
            case .missing(let searched):
                Log.info(
                    "auto-start: nothing started, no claude binary in "
                        + searched.joined(separator: ", "))
                DispatchQueue.main.async { done(.noBinary(searched)) }
                return {}
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "-p", prompt, "--model", "haiku", "--strict-mcp-config",
                "--mcp-config", #"{"mcpServers":{}}"#,
            ]
            process.currentDirectoryURL = workDir()

            // สองสายรวมเป็น pipe เดียว: อ่านเพื่อรู้ว่าตายเพราะอะไร และ `claude` ไม่ได้สัญญา
            // ว่าจะบ่นลงสายไหน · ต้องอ่านจริงด้วย — pipe ที่ไม่มีคนอ่านจะบล็อกลูกจนโดนฆ่า
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let output = ChildOutput.draining(pipe)
            process.terminationHandler = { finished in
                output.drain(pipe)
                let code = finished.terminationStatus
                let outcome = classify(code: code, output: output.text)
                Log.info("auto-start: the session ended with code \(code) (\(outcome))")
                DispatchQueue.main.async { done(outcome) }
            }

            do {
                Log.info("auto-start: starting a session with \(executable.path)")
                try process.run()
            } catch {
                // ไฟล์มีอยู่และ execute ได้เมื่อครู่ แต่รันไม่ขึ้น — แยกไม่ออกว่าถาวรหรือชั่วคราว
                Log.info("auto-start: could not run \(executable.path): \(error)")
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { done(.failed) }
                return {}
            }

            return {
                guard process.isRunning else { return }
                process.terminate()
                // TERM แล้วยังไม่ตายใน 2 วินาที = ค้างจริง ไม่ใช่กำลังเก็บกวาด
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

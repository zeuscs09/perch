import Foundation

/// รอบการยิงโควตาที่ผู้ใช้เลือกได้
///
/// ไม่มี 30 วินาที: เอกสารของ endpoint บอกว่า 60 วินาทีคือจังหวะที่แอปอื่นใช้อยู่จริง
/// และเลขนั้นเร็วเท่าที่ค่าจะขยับอยู่แล้ว (หน้าต่าง 5 ชม. ขยับราวหนึ่งเปอร์เซ็นต์ต่อ
/// สามนาที) ตัวเลือกที่เร็วกว่านั้นจึงเป็นแค่การยิงถี่ขึ้นเพื่อได้ค่าเดิม
public enum PollInterval: Int, CaseIterable, Equatable {
    case off = 0
    case minute = 60
    case fiveMinutes = 300

    public static let fallback = PollInterval.minute

    public var seconds: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .minute: return "60s"
        case .fiveMinutes: return "5 min"
        }
    }

    /// `off` เป็นค่าที่ผู้ใช้เลือกได้จริง จึงต้องแยกจาก "ยังไม่เคยเลือก" ให้ออก —
    /// ตัวอ่านค่าที่คืน 0 ให้กับคีย์ที่ไม่มีอยู่จะเปลี่ยนแอปที่เพิ่งติดตั้งให้เป็น `Off` เงียบๆ
    public static func stored(_ value: Int?) -> PollInterval {
        guard let value, let interval = PollInterval(rawValue: value) else { return fallback }
        return interval
    }
}

/// เหตุที่ค่าใหม่จะไม่มาจนกว่าผู้ใช้จะลงมือ — ต่างจาก error ที่รอบหน้าก็หายเอง
public enum PollBlock: Equatable {
    /// 401/403 — key หมดอายุ ต้องไปเอาอันใหม่จากเบราว์เซอร์
    ///
    /// อันเดียวที่ *ล็อก* การยิงไว้ เพราะยิงต่อไปก็ได้ 401 เหมือนเดิมทุกนาที และไม่มี
    /// อะไรนอกจากคนที่จะเปลี่ยนมันได้
    case expiredKey
    /// ไฟล์ key ใช้ไม่ได้ — สิทธิ์เปิดเกินไป หรือว่างเปล่า
    ///
    /// เป็นแค่ป้ายบอกอาการ ไม่ใช่ล็อก: ตัวที่กันไม่ให้ยิงคือ `hasKey` ซึ่งอ่านสภาพจริง
    /// ของไฟล์ทุกรอบ ผู้ใช้ที่ `chmod 600` เองข้างนอกจึงกลับมายิงได้โดยไม่ต้องเปิดปิดแอป
    case unusableKeyFile
}

/// สิ่งที่โปรเซสลูกพูดออก stdout
///
/// ลูกตายทุกรอบ อะไรที่มันรู้จึงต้องพูดตอนยังมีชีวิตอยู่ ไม่ใช่ทิ้งไว้ในไฟล์สถานะ
/// ตัวที่สองให้พ่อไปเก็บ — ไฟล์แบบนั้นจะค้างเป็นค่าเก่าทันทีที่ลูกตายกลางคัน
public enum PollOutput {
    static let orgPrefix = "org "

    public struct Parsed: Equatable {
        public let orgs: [UsagePoll.Org]
        public let summary: String?
    }

    public static func render(_ report: UsagePoll.Report) -> String {
        var lines = report.orgs.map { "\(orgPrefix)\($0.id) \($0.name)" }
        lines.append(report.summary)
        return lines.joined(separator: "\n")
    }

    /// บรรทัด `org <id> <ชื่อ>` คือรายการ org · บรรทัดอื่นบรรทัดสุดท้ายคือสถานะ
    ///
    /// ชื่อ org มีช่องว่างได้ ส่วน id ไม่มี — ตัดที่ช่องว่างแรกจึงพอ และ id ยังต้องผ่าน
    /// `validated` เหมือนตอนมาจากเน็ต เพราะทางเดินของมันจบที่ URL เหมือนกัน
    public static func parse(_ text: String) -> Parsed {
        var orgs: [UsagePoll.Org] = []
        var summary: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.hasPrefix(orgPrefix) else {
                summary = line
                continue
            }
            let rest = line.dropFirst(orgPrefix.count).trimmingCharacters(in: .whitespaces)
            let cut = rest.firstIndex(of: " ")
            let id = String(cut.map { rest[rest.startIndex..<$0] } ?? Substring(rest))
            let name = cut.map {
                String(rest[rest.index(after: $0)...]).trimmingCharacters(in: .whitespaces)
            } ?? ""
            guard let id = try? UsagePoll.validated(id) else { continue }
            orgs.append(UsagePoll.Org(id: id, name: name.isEmpty ? id : name))
        }
        return Parsed(orgs: orgs, summary: summary)
    }
}

/// ตัวจับเวลาที่ spawn `--usage-poll` ทีละตัว
///
/// จับเวลาอยู่ที่นี่ที่เดียว ไม่มีตัวที่สองในโปรเซสลูกให้ต้องซิงก์กัน — ลูกยิงรอบเดียว
/// แล้วตาย ตัวนี้ตัดสินว่าเมื่อไรจะมีลูกตัวถัดไป
///
/// ไม่มี timer ของตัวเอง: ถูกป้อน `tick(now:)` จากนาฬิกาวินาทีละครั้งของแอป ผลคือ
/// ตรรกะทั้งอันเป็นฟังก์ชันของเวลาที่ถูกส่งเข้ามา เทสต์ได้โดยไม่ต้องรอของจริง
public final class UsagePoller {
    /// ผลของลูกหนึ่งตัว — exit code แยกชนิดความล้มเหลว stdout พกสถานะกับรายการ org
    public struct Outcome {
        public let code: Int32
        public let output: String

        public init(code: Int32, output: String) {
            self.code = code
            self.output = output
        }
    }

    /// spawn หนึ่งตัว แล้วคืนวิธีฆ่ามัน
    public typealias Launcher = (_ orgID: String?, _ done: @escaping (Outcome) -> Void) -> () -> Void

    /// ลูกที่ไม่จบใน 30 วินาทีถูกฆ่า ไม่งั้นลูกที่ค้างจะกองกันทุกนาที
    public static let timeout: TimeInterval = 30

    public var interval: PollInterval
    /// org ที่ผู้ใช้เลือกไว้ — ไม่ใช่ความลับ จึงเดินทางไปทาง env ได้ ต่างจาก key
    public var preferredOrg: String?

    public private(set) var blocked: PollBlock?
    public private(set) var orgs: [UsagePoll.Org] = []
    public private(set) var status: String?
    public private(set) var lastStarted: Date?

    /// บอกว่าเปลี่ยนอะไรไปแล้ว ให้ผู้เรียกไปวาดใหม่
    public var onChange: (() -> Void)?

    private let hasKey: () -> Bool
    private let launch: Launcher
    private var startedAt: Date?
    private var kill: (() -> Void)?
    /// ลูกที่ถูกฆ่าไปแล้วยังพูดทีหลังได้ — รุ่นที่ไม่ตรงกันคือเสียงจากอดีต ต้องไม่ทับของใหม่
    private var generation = 0

    public init(
        interval: PollInterval = .fallback,
        preferredOrg: String? = nil,
        hasKey: @escaping () -> Bool = { SessionKeyFile.isUsable() },
        launch: @escaping Launcher
    ) {
        self.interval = interval
        self.preferredOrg = preferredOrg
        self.hasKey = hasKey
        self.launch = launch
    }

    public var isRunning: Bool { startedAt != nil }

    /// org ที่จะยิงจริง — ตัวที่เลือกไว้ถ้ายังอยู่ในรายการ ไม่งั้นตัวแรก
    ///
    /// การถอยไปตัวแรกอยู่ตรงนี้ ไม่ใช่ในโปรเซสลูก: ลูกได้ id มาก็ต้องเชื่อ (พินคือพิน)
    /// ส่วนตัวที่เห็นรายการทั้งอันและตัดสินใจแทนผู้ใช้ได้คือตัวนี้
    public var currentOrg: String? {
        UsagePoll.pick(orgs, preferred: preferredOrg)?.id ?? preferredOrg
    }

    /// ยิงได้ไหมตอนนี้ — `Off` ไม่ยิง · key หมดอายุไม่ยิง · ไม่มี key ไม่ยิง
    ///
    /// `hasKey` อยู่ท้ายสุดเสมอ เพราะมันแตะดิสก์ (และแตะไฟล์ credential) การเรียกมัน
    /// ทุกวินาทีเพื่อตอบคำถามที่ตัดจบไปแล้วด้วย `Off` คืองานที่ไม่มีใครขอ
    public var canPoll: Bool {
        interval != .off && blocked != .expiredKey && !isRunning && hasKey()
    }

    public func tick(now: Date = Date()) {
        if let startedAt {
            guard now.timeIntervalSince(startedAt) >= Self.timeout else { return }
            killRunning(status: "the quota check took too long and was stopped")
            return
        }
        // รอบยังไม่ครบก็ไม่ต้องไปถามดิสก์ว่ามี key ไหม — `canPoll` ถามให้ทีหลัง
        if let lastStarted,
            now.timeIntervalSince(lastStarted) < TimeInterval(interval.seconds) { return }
        guard canPoll else { return }
        start(now)
    }

    /// ยิงเดี๋ยวนี้โดยไม่รอครบรอบ — ใช้ตอนเครื่องตื่นจาก sleep และตอนเพิ่งตั้ง key
    public func pollNow(now: Date = Date()) {
        guard canPoll else { return }
        start(now)
    }

    /// ยิงเพราะผู้ใช้กดปุ่ม — ข้าม `Off` และข้ามล็อก key หมดอายุ
    ///
    /// `Off` สั่งว่าแอปอย่ายิง*เอง* ไม่ได้สั่งว่าห้ามผู้ใช้ดูค่าใหม่ · ล็อก key หมดอายุมีไว้
    /// กันการยิงซ้ำทุกนาทีเพื่อรับ 401 เดิม ซึ่งไม่ใช่เหตุผลที่จะปฏิเสธคนที่เพิ่งไปเอา key
    /// ใหม่มาแปะข้างนอกแล้วอยากรู้ว่าใช้ได้หรือยัง — ถ้ายังหมดอายุจริง รอบนี้ก็จะบอกแบบเดิม
    ///
    /// สองอย่างที่ยังกันอยู่คือลูกที่วิ่งอยู่ (หนึ่งตัวต่อหนึ่งรอบเสมอ) กับไฟล์ key ที่ไม่มี
    /// หรือใช้ไม่ได้ — อันหลังไม่มีคำถามจะยิงตั้งแต่แรก
    public func refreshNow(now: Date = Date()) {
        guard !isRunning, hasKey() else { return }
        start(now)
    }

    /// ตั้ง key ใหม่แล้วกลับมายิงตามรอบเอง — ไม่ต้องปิดเปิดแอป
    public func keyWasSet(now: Date = Date()) {
        // ลูกที่กำลังวิ่งอยู่อ่าน key คนละตัวกับที่เพิ่งตั้ง ผลของมันจึงเป็นเรื่องของอดีต
        // ปล่อยไว้แล้วมันจะกลับมาบอกว่า "ไฟล์ key ใช้ไม่ได้" ทับสถานะที่เพิ่งถูกแก้
        stop()
        blocked = nil
        status = nil
        pollNow(now: now)
        onChange?()
    }

    /// ปิดแอปแล้วต้องไม่มีลูกค้าง — ลูกที่กำพร้าจะยิงต่อโดยไม่มีใครอ่านผล
    ///
    /// ลูกไม่ดัก SIGTERM (ไม่มีอะไรให้เก็บกวาด cache เขียนแบบ temp + rename อยู่แล้ว)
    /// TERM จึงจบมันได้จริงแม้พ่อจะตายก่อนที่ KILL สำรองจะได้ทำงาน
    public func stop() {
        kill?()
        generation += 1
        kill = nil
        startedAt = nil
    }

    private func start(_ now: Date) {
        generation += 1
        let gen = generation
        startedAt = now
        lastStarted = now
        kill = launch(currentOrg) { [weak self] outcome in
            self?.finished(gen, outcome)
        }
        onChange?()
    }

    private func killRunning(status: String) {
        stop()
        self.status = status
        onChange?()
    }

    private func finished(_ gen: Int, _ outcome: Outcome) {
        guard gen == generation else { return }
        startedAt = nil
        kill = nil

        let parsed = PollOutput.parse(outcome.output)
        // รายการว่างแปลว่ารอบนี้ถามไม่สำเร็จ ไม่ใช่ว่าบัญชีไม่มี org แล้ว — ของเดิมยังจริงกว่า
        if !parsed.orgs.isEmpty { orgs = parsed.orgs }
        status = parsed.summary

        switch outcome.code {
        case 0:
            blocked = nil
        case UsagePoll.Failure.rejectedKey:
            blocked = .expiredKey
        case UsagePoll.Failure.unusableKeyFile:
            blocked = .unusableKeyFile
        default:
            // 5xx เน็ตหลุด timeout — รอบหน้าก็หายเอง ไม่มีอะไรให้ผู้ใช้ทำ · ป้าย
            // "ไฟล์ key ใช้ไม่ได้" ที่ค้างอยู่ต้องหายไปด้วย เพราะรอบนี้ไปได้ไกลกว่านั้นแล้ว
            if blocked == .unusableKeyFile { blocked = nil }
        }
        onChange?()
    }
}

/// ตัว spawn จริง — บางจนไม่มี logic ให้เทสต์ ตรรกะทั้งหมดอยู่ใน `UsagePoller`
public enum PollProcess {
    public static var executable: URL {
        URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    public static func launcher(_ executable: URL = PollProcess.executable) -> UsagePoller.Launcher {
        { orgID, done in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--usage-poll"]

            // key ไม่เคยผ่าน env และไม่เคยผ่าน argv — ลูกอ่านไฟล์ 600 เอง
            // org id ไม่ใช่ความลับ จึงส่งทางนี้ได้ และลูกยัง validate ซ้ำอยู่ดี
            var env = ProcessInfo.processInfo.environment
            if let orgID, !orgID.isEmpty {
                env["PERCH_ORG_ID"] = orgID
            } else {
                env.removeValue(forKey: "PERCH_ORG_ID")
            }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            // stderr ทิ้ง: สถานะเดินทางมาทาง stdout ทางเดียว และ pipe ที่ไม่มีใครอ่าน
            // จะบล็อกลูกจนโดนฆ่าตอนครบ 30 วินาทีโดยไม่มีเหตุผล
            process.standardError = FileHandle.nullDevice

            let output = ChildOutput.draining(pipe)
            process.terminationHandler = { finished in
                output.drain(pipe)
                let outcome = UsagePoller.Outcome(
                    code: finished.terminationStatus, output: output.text)
                DispatchQueue.main.async { done(outcome) }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    done(UsagePoller.Outcome(code: 1, output: "could not run the quota check"))
                }
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

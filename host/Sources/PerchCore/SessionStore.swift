import Foundation

/// ค่าเวลาทั้งหมดของตรรกะสถานะ รวมไว้ที่เดียวเพื่อให้เทสต์ตั้งค่าได้
public struct Timings: Sendable {
    /// Stop แล้วเงียบเกินเท่านี้ = ถือว่าต้องเตือนผู้ใช้ (เกณฑ์ใน DESIGN.md)
    public var stopAlert: TimeInterval = 45
    /// ท่าดีใจหลังงานจบ ก่อนกลับไป idle — อย่าตั้งต่ำกว่า `minPose` เพราะ minPose จะยืดให้เองอยู่ดี
    public var celebrate: TimeInterval = 5
    /// ท่าหนึ่งต้องอยู่บนจออย่างน้อยเท่านี้ ก่อนยอมให้ท่าถัดไปแทน
    ///
    /// Read/Edit ส่วนใหญ่จบใน ~100 มิลลิวินาที ถ้าเปลี่ยนท่าตามเหตุการณ์ทันที
    /// ท่า reading/writing จะโผล่สั้นกว่าหนึ่งเฟรมของบอร์ด (tick 1 วิ + ดีเลย์ BLE)
    /// ผู้ใช้จึงเห็นแต่ thinking ตลอด ทั้งที่ตรรกะข้างในถูกแล้ว
    public var minPose: TimeInterval = 5
    /// ท่าเดินเข้ามาของ session ใหม่
    public var entering: TimeInterval = 1.2
    /// ท่ามุดหายก่อนหายจากจอ
    public var leaving: TimeInterval = 1.2
    /// ไม่มีความเคลื่อนไหวเกินเท่านี้ = มาสคอตนอน
    public var sleep: TimeInterval = 300
    /// ไม่มีความเคลื่อนไหวเกินเท่านี้ = ทิ้ง session ไปเลย (กัน session ค้างจาก crash)
    public var evict: TimeInterval = 3600
    /// การ์ดหายเองเมื่อไม่มีใครสนใจ
    public var cardTTL: TimeInterval = 600

    public init() {}
}

/// สิ่งที่ session กำลังทำ — เก็บแค่นี้ ส่วนสถานะภาพคำนวณจากมันบวกเวลา
enum Activity: Equatable {
    case idle
    case thinking
    case tool(VisualState)
    case waiting  // Notification: Claude รอผู้ใช้ตอบ
    case failed   // StopFailure
}

struct Session {
    var id: String
    var project: String
    /// เอเจนต์เจ้าของ session — ตั้งครั้งเดียวตอนสร้าง ไม่เปลี่ยนตลอดอายุ session
    var agent: AgentKind = .claude
    var activity: Activity = .thinking
    var startedAt: Date
    var lastActivity: Date
    /// เวลาที่ Stop ยิงและยังไม่มี prompt ใหม่ — ใช้ตัดสินเกณฑ์เตือน 45 วิ
    var stoppedAt: Date?
    var celebrateUntil: Date?
    var endingAt: Date?
    var subagents: Int = 0
    /// process ของ Claude Code ที่เป็นเจ้าของ session นี้ — nil = ไม่รู้ (ดู `ProcessTree`)
    var owner: ProcessHandle?
    /// ท่าที่อยู่บนจอตอนนี้ และเวลาที่มันขึ้นจอ — ใช้บังคับเวลาขั้นต่ำต่อท่า
    var posed: VisualState?
    var posedAt: Date = .distantPast

    /// ท่าที่ "ควรจะเป็น" ตามสถานะจริง ณ วินาทีนี้ — ยังไม่ผ่านการหน่วง
    func visualState(now: Date, t: Timings) -> VisualState {
        if endingAt != nil { return .leaving }  // prune() เป็นคนเอาออกเมื่อท่าจบ
        if now < startedAt + t.entering { return .entering }
        switch activity {
        case .failed: return .error
        case .waiting: return .waiting
        case .tool, .thinking:
            // การกระจายงานชนะเครื่องมือ: ตอน subagent วิ่ง tool ที่เห็นเป็นของลูกน้อง
            // ไม่ใช่ของ session หลัก — "กำลังคุมงานอยู่" จึงตรงความจริงกว่า
            // (แต่แพ้ error กับ waiting ข้างบน: พังกับต้องการมือคน สำคัญกว่า)
            if subagents > 0 { return .conducting }
            if case .tool(let s) = activity { return s }
            return .thinking
        case .idle:
            if let c = celebrateUntil, now < c { return .celebrate }
            // นอนชนะการทวงถาม: ถ้าเงียบมาเป็นนาทีแล้ว ท่ายืนทวงตลอดกาลไม่ได้สื่ออะไรเพิ่ม
            // การเตือนยังอยู่ในรูปการ์ด ซึ่งเป็นคนละช่องทางกับท่าของมาสคอต
            if now >= lastActivity + t.sleep { return .sleeping }
            if let s = stoppedAt, now >= s + t.stopAlert { return .waiting }
            return .idle
        }
    }

    /// ท่าที่แสดงจริง: ท่าดิบที่ถูกหน่วงไว้ให้อยู่ครบ `minPose` ก่อนเปลี่ยนตัว
    ///
    /// ท่าที่ถูกข้ามระหว่างหน่วงจะหายไปเลย ไม่เข้าคิว — คิวจะทำให้มาสคอตเล่าอดีต
    /// ช้ากว่าความจริงเรื่อยๆ เมื่อเครื่องมือยิงรัว ซึ่งแย่กว่าการตกท่าไปบางท่า
    mutating func displayState(now: Date, t: Timings) -> VisualState {
        let raw = visualState(now: now, t: t)
        func latch() -> VisualState {
            posed = raw
            posedAt = now
            return raw
        }
        // ท่าเข้า/ออกมีนาฬิกาของตัวเองอยู่แล้ว จึงไม่หน่วง ทั้งขาเข้าและขาออกจากมัน
        // (และ prune นับเวลาท่ามุดหายจาก endingAt ไม่ใช่จากจอ ถ้าหน่วงจะโดนลบก่อนได้แสดง)
        if raw == .entering || raw == .leaving || posed == .entering { return latch() }
        guard let cur = posed else { return latch() }
        if cur == raw { return cur }
        // เรื่องด่วนกว่าแทรกได้ทันที (พัง/ต้องการมือคน) ที่เหลือรอให้ท่าปัจจุบันอยู่ครบเวลา
        if raw.priority > cur.priority || now >= posedAt + t.minPose { return latch() }
        return cur
    }
}

struct StoredCard {
    var sessionId: String?
    var title: String
    var body: String
    var kind: CardKind
    var createdAt: Date
}

/// ตัวจริงของ daemon: กินเหตุการณ์จาก hook แล้วคายภาพหน้าจอออกมา
///
/// ไม่มี timer อยู่ข้างใน — เวลาถูกป้อนเข้ามาทุกครั้ง จึงเทสต์ได้ทั้งหมดโดยไม่ต้องรอจริง
public final class SessionStore {
    public var toolMap: ToolMap
    public var timings: Timings
    /// จำนวน slot บนจอ ที่เหลือถูกนับเป็น "+N"
    ///
    /// ต้องตรงกับ `[slots] count` ใน tools/layout.toml เสมอ — ส่งเกินไปแล้วบอร์ดตัดทิ้งเงียบๆ
    /// (pch_model.c) และ "+N" จะนับต่ำกว่าจริง คือโกหกว่ามองเห็นครบทุก session
    public let slotCount: Int
    /// ถาม kernel ว่าเจ้าของ session ยังอยู่ไหม — แทนที่ได้เพื่อให้เทสต์ไม่ต้องฆ่า process จริง
    public var isProcessAlive: (ProcessHandle) -> Bool = { ProcessTree.isAlive($0) }

    private var order: [String] = []  // ลำดับซ้าย->ขวา ต้องนิ่ง = ลำดับที่ session เกิด
    private var sessions: [String: Session] = [:]
    private var cards: [StoredCard] = []

    public init(toolMap: ToolMap = .default, timings: Timings = Timings(), slotCount: Int = 3) {
        self.toolMap = toolMap
        self.timings = timings
        self.slotCount = slotCount
    }

    // MARK: - รับเหตุการณ์

    public func apply(_ e: HookEvent, now: Date = Date()) {
        let id = e.sessionId
        if sessions[id] == nil {
            // เหตุการณ์แรกที่เห็นเป็นตัวสร้าง session แม้จะไม่ใช่ SessionStart
            // (daemon อาจเพิ่งสตาร์ททีหลัง session)
            sessions[id] = Session(
                id: id,
                project: Text.fit(e.project, to: Text.Limit.project),
                agent: e.agent ?? .claude,
                startedAt: now,
                lastActivity: now
            )
            order.append(id)
        }
        guard var s = sessions[id] else { return }
        s.lastActivity = now
        s.endingAt = nil
        // เขียนทับได้เสมอ ไม่ใช่เขียนครั้งเดียว: ผู้ใช้ `--resume` session เดิมได้
        // ซึ่งได้ process ตัวใหม่แต่ id เดิม ถ้ายึดตัวแรกไว้ session ที่ฟื้นมาจะถูกฆ่าทิ้งทันที
        if let o = e.owner { s.owner = o }
        if let cwd = e.cwd, !cwd.isEmpty {
            s.project = Text.fit(e.project, to: Text.Limit.project)
        }

        switch e.hookEventName {
        case "SessionStart":
            s.startedAt = now
            s.activity = .idle
            s.stoppedAt = nil
            s.subagents = 0

        case "UserPromptSubmit":
            s.activity = .thinking
            s.stoppedAt = nil
            s.celebrateUntil = nil
            // เทิร์นใหม่ = ล้างตัวนับที่ค้างจากเทิร์นก่อน (SubagentStop ที่หายไปตอน
            // daemon ไม่ได้รัน จะทำให้ session ติดท่า conducting ตลอดกาลถ้าไม่ล้าง)
            s.subagents = 0
            dismissCards(for: id)

        case "PreToolUse":
            s.activity = .tool(toolMap.state(for: e.toolName ?? ""))
            s.stoppedAt = nil
            // ขออนุญาตแล้วได้ไปต่อ = คำขอนั้นตายแล้ว การ์ดต้องไม่ค้างจนหมดอายุเอง
            // (PermissionRequest ยิง Notification ทีหลัง PreToolUse ของตัวมันเอง
            //  การ์ดของรอบนี้จึงไม่โดนล้างทิ้งก่อนผู้ใช้เห็น)
            dismissCards(for: id)

        case "PostToolUse":
            s.activity = .thinking
            dismissCards(for: id)

        case "PreCompact":
            s.activity = .thinking

        case "SubagentStart":
            s.subagents += 1
            s.activity = .thinking

        case "SubagentStop":
            s.subagents = max(0, s.subagents - 1)

        case "Notification":
            s.activity = .waiting
            s.stoppedAt = nil
            push(
                StoredCard(
                    sessionId: id,
                    title: s.project,
                    body: e.message ?? "needs your input",
                    kind: .alert,
                    createdAt: now
                ))

        case "Stop":
            s.activity = .idle
            s.stoppedAt = now
            s.celebrateUntil = now + timings.celebrate
            // main loop จบแล้ว จะมี subagent ค้างจริงไม่ได้
            s.subagents = 0
            // เทิร์นจบแล้ว คำขออนุญาตของเทิร์นนั้นหมดความหมาย ต่อให้ผู้ใช้กดปฏิเสธ
            // (ทางนั้นไม่มี PostToolUse มาล้างให้) — การเตือนที่เหลือมาทาง stopAlerts
            dismissCards(for: id)

        case "StopFailure", "SubagentStopFailure":
            s.activity = .failed
            s.stoppedAt = nil
            s.celebrateUntil = nil
            push(
                StoredCard(
                    sessionId: id,
                    title: s.project,
                    body: e.reason ?? e.message ?? "stopped with an error",
                    kind: .alert,
                    createdAt: now
                ))

        case "SessionEnd":
            s.endingAt = now
            s.activity = .idle
            s.subagents = 0
            dismissCards(for: id)

        default:
            break
        }
        sessions[id] = s
    }

    private func push(_ card: StoredCard) {
        // ใบใหม่สุดอยู่บน และ session หนึ่งมีการ์ดค้างได้ใบเดียว
        cards.removeAll { $0.sessionId != nil && $0.sessionId == card.sessionId }
        cards.insert(card, at: 0)
    }

    private func dismissCards(for sessionId: String) {
        cards.removeAll { $0.sessionId == sessionId }
    }

    // MARK: - เวลาเดิน

    /// ทิ้ง session ที่จบท่ามุดหายแล้ว/ค้างนานเกิน และการ์ดที่หมดอายุ
    public func prune(now: Date = Date()) {
        for (id, s) in sessions {
            var s = s
            // ปิดหน้าต่าง terminal = process โดน SIGHUP ทันที `SessionEnd` ไม่มีวันยิง
            // จึงเช็คตัว process เองแทนที่จะรอ hook ที่ไม่มา · ให้มุดหายเหมือนจบปกติ
            // ไม่ใช่หายวับ เพราะจากตาผู้ใช้มันคือการปิด session เหมือนกัน
            if s.endingAt == nil, let o = s.owner, !isProcessAlive(o) {
                s.endingAt = now
                s.activity = .idle
                s.subagents = 0
                dismissCards(for: id)
                sessions[id] = s
            }
            let ended = s.endingAt.map { now >= $0 + timings.leaving } ?? false
            let stale = now >= s.lastActivity + timings.evict
            if ended || stale {
                sessions[id] = nil
                order.removeAll { $0 == id }
                dismissCards(for: id)
            }
        }
        cards.removeAll { now >= $0.createdAt + timings.cardTTL }
    }

    /// เติมการ์ดของ session ที่ Stop แล้วเงียบเกินเกณฑ์
    ///
    /// เป็น `.done` ไม่ใช่ `.alert` — เทิร์นจบเฉยๆ ไม่มีอะไรค้างให้ตอบ ต่างจาก
    /// `Notification`/`StopFailure` ที่ไม่มีมือคนแล้วเดินต่อไม่ได้จริง ถ้าย้อมแดง
    /// เหมือนกันหมด ทุกเทิร์นที่ผู้ใช้ลุกจากโต๊ะจะได้การ์ดแดง แล้วสีแดงจะเลิกแปลว่า
    /// "ต้องมือคน" · ท่ามาสคอตยังเป็น `waiting` (นาฬิกาเหลือง = ถึงตาคุณ) เหมือนเดิม
    private func stopAlerts(now: Date) {
        for id in order {
            guard let s = sessions[id], let stopped = s.stoppedAt else { continue }
            guard now >= stopped + timings.stopAlert else { continue }
            guard !cards.contains(where: { $0.sessionId == id }) else { continue }
            push(
                StoredCard(
                    sessionId: id,
                    title: s.project,
                    body: "your turn",
                    kind: .done,
                    createdAt: now
                ))
        }
    }

    // MARK: - ภาพหน้าจอ

    public func snapshot(now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        prune(now: now)
        stopAlerts(now: now)

        // เดินท่าของทุกตัวก่อน (รวมตัวที่ตกจอ) เพื่อให้นาฬิกาหน่วงท่าเดินสม่ำเสมอ
        var live: [(project: String, agent: AgentKind, state: VisualState, lastActivity: Date)] = []
        for id in order {
            guard var s = sessions[id] else { continue }
            let state = s.displayState(now: now, t: timings)
            sessions[id] = s
            live.append((s.project, s.agent, state, s.lastActivity))
        }

        // เลือกตัวที่ได้ slot ตามความสำคัญ แต่ *วาด* ตามลำดับเกิดเสมอ
        // สิ่งที่ต้องนิ่งคือลำดับซ้าย->ขวา ไม่ใช่พิกัด (DESIGN.md)
        let chosen: [(project: String, agent: AgentKind, state: VisualState, lastActivity: Date)]
        if live.count <= slotCount {
            chosen = live
        } else {
            // เรียงตาม: ความสำคัญ -> ขยับล่าสุด -> เกิดทีหลัง
            // ข้อสุดท้ายทำให้ผลนิ่ง (ไม่ขึ้นกับการเรียงที่ไม่เสถียร) และตัดตัวที่เก่าสุด
            // และเงียบสุดออกก่อน ซึ่งเป็นตัวที่ผู้ใช้น่าจะสนใจน้อยที่สุด
            let ranked = live.enumerated().sorted { a, b in
                let pa = a.element.state.priority
                let pb = b.element.state.priority
                if pa != pb { return pa > pb }
                if a.element.lastActivity != b.element.lastActivity {
                    return a.element.lastActivity > b.element.lastActivity
                }
                return a.offset > b.offset
            }
            let keep = Set(ranked.prefix(slotCount).map { $0.offset })
            chosen = live.enumerated().filter { keep.contains($0.offset) }.map { $0.element }
        }

        let snaps = chosen.map { SessionSnap(project: $0.project, state: $0.state, agent: $0.agent) }

        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let clock = f.string(from: now)
        f.dateFormat = "EEE d MMM"
        let date = f.string(from: now)

        return Snapshot(
            clock: clock,
            date: date,
            overflow: max(0, live.count - chosen.count),
            sessions: snaps,
            // จอวาดได้ 2 ใบ (PCH_CARD_MAX ใน tools/layout.toml) — ส่งเกินมาก็ถูกทิ้ง
            // แล้วยังกิน MTU ของสิ่งที่จอใช้จริง ที่เหลือไปโผล่เป็น "+N" แทน
            cards: cards.prefix(2).map {
                CardSnap(
                    title: Text.fit($0.title, to: Text.Limit.cardTitle),
                    body: Text.fit($0.body, to: Text.Limit.cardBody),
                    kind: $0.kind
                )
            },
            cardOverflow: max(0, cards.count - 2)
        )
    }

    public var sessionCount: Int { sessions.count }
}

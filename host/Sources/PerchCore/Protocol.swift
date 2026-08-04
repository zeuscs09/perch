import Foundation

// MARK: - เหตุการณ์จาก Claude Code hook

/// รูปแบบ JSON ที่ Claude Code ป้อนเข้า stdin ของ hook
/// เก็บเฉพาะฟิลด์ที่ daemon ใช้จริง ฟิลด์อื่นถูกละทิ้งตอน decode
public struct HookEvent: Codable, Equatable, Sendable {
    public var hookEventName: String
    public var sessionId: String
    public var cwd: String?
    public var toolName: String?
    public var message: String?
    public var prompt: String?
    public var reason: String?
    public var source: String?
    /// process ของ Claude Code ที่เป็นเจ้าของ session นี้
    ///
    /// Claude Code ไม่ได้ส่งมาใน stdin — `--hook` เป็นคนเติมเองจากสายบรรพบุรุษของตัวเอง
    /// ก่อนส่งต่อเข้า socket จึงต้อง optional เสมอ (ทั้งเหตุการณ์ที่มาจาก `--send`
    /// และ hook เก่าที่ยังไม่รู้จักคีย์นี้)
    public var owner: ProcessHandle?
    /// เอเจนต์ที่ก่อเหตุการณ์นี้
    ///
    /// Claude Code ไม่ส่งมา (มันไม่รู้ว่ามีเอเจนต์อื่น) จึงไม่มีคีย์นี้ = claude
    /// ตัวเฝ้า Codex เป็นคนเติมเองก่อนยิงเข้า `--send`
    public var agent: AgentKind?
    /// ชื่อ tmux session ของ pane ที่ก่อเหตุการณ์ — `--hook` เติมเองจาก TMUX_PANE
    /// ของตัวเอง (daemon อยู่คนละสาย หาให้ไม่ได้) nil = ไม่ได้อยู่ใน tmux
    public var tmux: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case toolName = "tool_name"
        case message
        case prompt
        case reason
        case source
        case owner
        case agent
        case tmux
    }

    public init(
        hookEventName: String,
        sessionId: String,
        cwd: String? = nil,
        toolName: String? = nil,
        message: String? = nil,
        prompt: String? = nil,
        reason: String? = nil,
        source: String? = nil,
        owner: ProcessHandle? = nil,
        agent: AgentKind? = nil,
        tmux: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.message = message
        self.prompt = prompt
        self.reason = reason
        self.source = source
        self.owner = owner
        self.agent = agent
        self.tmux = tmux
    }

    /// ป้ายใต้มาสคอต — "อยู่ tmux ไหน" + "บทบาทอะไร"
    ///
    /// ชื่อโฟลเดอร์อย่างเดียวใช้ไม่ได้เมื่อมีหลายทีม เพราะทุกทีมวางโครงเหมือนกัน
    /// (ดู SessionLabel) ไม่ได้อยู่ใน tmux ก็ถอยไปใช้ชื่อโฟลเดอร์แบบเดิม
    public var project: String {
        let fallback = (agent ?? .claude).rawValue
        let role: String
        if let cwd, !cwd.isEmpty {
            let name = SessionLabel.role(fromPath: cwd)
            role = name.isEmpty ? fallback : name
        } else {
            role = fallback
        }
        return SessionLabel.compose(session: tmux, role: role)
    }
}

// MARK: - สถานะภาพของมาสคอต

/// ต้องตรงกับ `STATES` ใน tools/gen/mascot.py และ enum ฝั่ง firmware ทุกตัว
public enum VisualState: String, Codable, Equatable, Sendable, CaseIterable {
    case idle
    case reading
    case writing
    case building
    case searching
    case thinking
    case waiting
    case sleeping
    case alert
    case celebrate
    case error
    case entering
    case leaving
    case conducting
    case beacon

    /// ลำดับความสำคัญตอนเลือกว่า session ไหนได้ slot เมื่อมีเกิน 4 ตัว
    /// ตัวเลขสูง = ได้ก่อน
    public var priority: Int {
        switch self {
        case .alert, .error: return 40
        case .waiting: return 30
        case .entering, .leaving: return 25
        // สูงกว่า tool: session ที่คุม subagent อยู่ *เงียบสนิท* ไม่มี hook ยิงเป็นนาทีๆ
        // ตัวตัดสินอันดับสองคือ lastActivity ล่าสุดชนะ ถ้าให้เท่ากับ tool มันจะแพ้
        // session ที่ไถ Read ไปเรื่อยๆ แล้วหลุดจอ ทั้งที่เป็นตัวที่น่าสนใจที่สุด
        case .conducting: return 22
        case .reading, .writing, .building, .searching, .thinking, .beacon: return 20
        case .celebrate: return 15
        case .idle: return 10
        case .sleeping: return 0
        }
    }
}

// MARK: - snapshot ที่ส่งข้ามสาย

public enum CardKind: String, Codable, Equatable, Sendable {
    case info
    case alert
    case done
}

public struct CardSnap: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var kind: CardKind

    enum CodingKeys: String, CodingKey {
        case title = "t"
        case body = "b"
        case kind = "k"
    }

    public init(title: String, body: String, kind: CardKind) {
        self.title = title
        self.body = body
        self.kind = kind
    }
}

/// เอเจนต์ที่เป็นเจ้าของ session — คนละแกนกับ `project` (ชื่อโฟลเดอร์)
///
/// Claude กับ Codex ทำงานในโฟลเดอร์เดียวกันได้ ชื่อโปรเจกต์จึงแยกไม่ออกว่าใครเป็นใคร
/// บอร์ดใช้ค่านี้เลือกจานสีของมาสคอต ไม่ได้ใช้เลือกท่า — ท่ายังมาจาก `state` เหมือนเดิม
public enum AgentKind: String, Codable, Equatable, Sendable, CaseIterable {
    case claude
    case codex
    case antigravity

    /// อักษรเดียวบนสาย — ประหยัดไบต์ในงบ 500 ที่แชร์กับ session และ card
    ///
    /// เขียนตรงๆ ทีละตัว ไม่ derive จากตัวแรกของชื่อ: claude กับ codex ขึ้นต้นด้วย c
    /// เหมือนกัน การ derive จึงทำให้ทั้งคู่ส่งค่าเดียวกันและบอร์ดแยกไม่ออก
    /// (เคยพลาดมาแล้ว — มาสคอตของ Codex ขึ้นเป็นสีของ Claude ทุกตัว)
    /// ค่าพวกนี้อยู่บนสาย ต้องตรงกับ `agent_from_name` ใน firmware/main/pch_model.c
    public var wire: String {
        switch self {
        case .claude: return "c"
        case .codex: return "x"
        case .antigravity: return "g"
        }
    }

    public init?(wire: String) {
        guard let match = Self.allCases.first(where: { $0.wire == wire }) else { return nil }
        self = match
    }
}

public struct SessionSnap: Codable, Equatable, Sendable {
    public var project: String
    public var state: VisualState
    public var agent: AgentKind

    enum CodingKeys: String, CodingKey {
        case project = "p"
        case state = "s"
        case agent = "a"
    }

    public init(project: String, state: VisualState, agent: AgentKind = .claude) {
        self.project = project
        self.state = state
        self.agent = agent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(String.self, forKey: .project)
        state = try c.decode(VisualState.self, forKey: .state)
        // ไม่มีคีย์ = daemon/บอร์ดรุ่นก่อนมี multi-agent ให้ถือเป็น claude
        agent = (try? c.decode(String.self, forKey: .agent)).flatMap(AgentKind.init(wire:)) ?? .claude
    }

    /// ไม่ส่ง `a` เมื่อเป็น claude — เคสที่พบบ่อยที่สุดจึงไม่กินไบต์เพิ่มเลย
    /// และ snapshot ยังถอดได้ด้วยบอร์ดรุ่นก่อนหน้า
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(project, forKey: .project)
        try c.encode(state, forKey: .state)
        if agent != .claude { try c.encode(agent.wire, forKey: .agent) }
    }
}

/// โควตาหนึ่งหน้าต่าง — มาจาก `rate_limits.five_hour` / `.seven_day` ที่ Claude Code
/// ป้อนเข้า statusline
///
/// เข้ารหัสเป็น array 2 ช่อง `[percent, secondsRemaining]` ไม่ใช่ object
/// เพราะคีย์กินไบต์ในงบ 500 ที่แชร์กับ session และ card
///
/// **ส่งวินาทีที่เหลือ ไม่ใช่เวลารีเซ็ตสัมบูรณ์** — บอร์ดนับถอยลงเอง ทำให้ countdown
/// ยังเดินถูกตอน BLE หลุด และ daemon ไม่ต้องยิงใหม่ทุกนาทีเพียงเพื่ออัปเดตตัวเลข
public struct UsageSnap: Codable, Equatable, Sendable {
    /// ค่าที่แปลว่า "ไม่รู้" — ศูนย์เป็นค่าจริง จึงใช้เป็น sentinel ไม่ได้
    /// (ADR-0001 ของ esp32-claude-quota: utilization is reported, never derived)
    public static let unknown = -1

    public var percent: Int
    public var remaining: Int

    public init(percent: Int = UsageSnap.unknown, remaining: Int = UsageSnap.unknown) {
        self.percent = percent
        self.remaining = remaining
    }

    public var isKnown: Bool { percent != Self.unknown || remaining != Self.unknown }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        percent = try c.decode(Int.self)
        remaining = try c.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(percent)
        try c.encode(remaining)
    }
}

/// สภาพอากาศ — เข้ารหัสเป็น `[condition, องศา C]` ด้วยเหตุผลเดียวกับ UsageSnap
/// คือคีย์กินไบต์ในงบที่แชร์กับ session และ card
public struct WeatherSnap: Codable, Equatable, Sendable {
    /// อุณหภูมิที่ไม่รู้ — ติดลบได้จริง (-40) จึงใช้ค่าที่พ้นช่วงจริงไปมาก
    public static let unknownTemp = -999

    public var condition: Int
    public var temperature: Int

    public init(condition: Int, temperature: Int) {
        self.condition = condition
        self.temperature = temperature
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        condition = try c.decode(Int.self)
        temperature = try c.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(condition)
        try c.encode(temperature)
    }
}

/// ก้อนเดียวที่อธิบายทั้งหน้าจอ — firmware วาดจากสิ่งนี้อย่างเดียว ไม่เก็บสถานะเอง
/// ต้องพอดี 1 MTU (517) เสมอ ดู `encoded(maxBytes:)`
public struct Snapshot: Codable, Equatable, Sendable {
    public var clock: String
    public var date: String
    public var overflow: Int
    public var sessions: [SessionSnap]
    public var cards: [CardSnap]
    /// จำนวน card ที่มีอยู่จริงแต่ไม่ได้ส่ง — จอวาดได้แค่ 2 ใบ
    /// การ์ดที่หายไปเงียบๆ คือการเตือนที่หายไป ต้องเหลือร่องรอยว่ายังมีอีก
    public var cardOverflow: Int
    /// `[session, weekly]` เสมอเมื่อมี — `nil` แปลว่าไม่เคยได้ข้อมูลเลย
    /// ซึ่งบอร์ดตีความว่า "ถอยไปเป็นนาฬิกาตั้งโต๊ะ" ไม่ใช่ "วาดโครงเปล่า"
    public var usage: [UsageSnap]?
    /// `nil` = ผู้ใช้ไม่ได้ตั้งพิกัด หรือยังยิงไม่สำเร็จสักครั้ง -> ฟ้าใสตามเดิม
    public var weather: WeatherSnap?
    /// ชื่อสถานที่สำหรับป้ายบนแถบบน — `nil` = ไม่ได้ตั้ง บอร์ดใช้ป้ายเดิมของมัน
    public var place: String?
    /// ภาระเครื่อง `[cpu%, mem%]` — แยกจาก `usage` เพราะเป็นค่า ณ วินาทีนี้
    /// ไม่ใช่งบที่มีเส้นตาย จอจึงวาดคนละแบบ (ไม่มีเวลานับถอยหลัง)
    public var machine: [Int]?

    enum CodingKeys: String, CodingKey {
        case clock = "c"
        case date = "d"
        case overflow = "o"
        case sessions = "s"
        case cards = "n"
        case cardOverflow = "m"
        case usage = "u"
        case weather = "w"
        case place = "l"
        case machine = "h"
    }

    public init(
        clock: String,
        date: String,
        overflow: Int = 0,
        sessions: [SessionSnap] = [],
        cards: [CardSnap] = [],
        cardOverflow: Int = 0,
        usage: [UsageSnap]? = nil,
        weather: WeatherSnap? = nil,
        place: String? = nil,
        machine: [Int]? = nil
    ) {
        self.clock = clock
        self.date = date
        self.overflow = overflow
        self.sessions = sessions
        self.cards = cards
        self.cardOverflow = cardOverflow
        self.usage = usage
        self.weather = weather
        self.place = place
        self.machine = machine
    }
}

public enum Wire {
    /// ขนาดสูงสุดที่เขียนลง GATT characteristic ได้ในครั้งเดียว
    /// MTU 517 หัก ATT header 3 ไบต์ แล้วเผื่อไว้อีกหน่อย
    public static let maxPayload = 500

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        // sortedKeys ไม่ใช่เรื่องความสวยงาม: ถ้าลำดับคีย์สุ่มไปเรื่อยๆ
        // การเทียบว่า "snapshot เปลี่ยนไหม" จะจริงทุกครั้ง แล้วบอร์ดโดนยิงทุกวินาที
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }
}

extension Snapshot {
    /// encode แล้วบีบข้อความให้พอดี `maxBytes` — ไม่มี chunking บนสาย
    /// ลำดับการตัด: body ของ card → title ของ card → ตัด card ทิ้งจากใบล่างสุด
    /// sessions ไม่เคยถูกตัดทิ้ง เพราะมันคือสิ่งที่จอนี้มีไว้แสดง
    public func encoded(maxBytes: Int = Wire.maxPayload) throws -> Data {
        let encoder = Wire.encoder()
        var copy = self
        var data = try encoder.encode(copy)
        if data.count <= maxBytes { return data }

        for limit in [40, 28, 18, 10, 0] {
            copy.cards = copy.cards.map {
                CardSnap(title: $0.title, body: Text.clip($0.body, to: limit), kind: $0.kind)
            }
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        for limit in [24, 16, 10] {
            copy.cards = copy.cards.map {
                CardSnap(title: Text.clip($0.title, to: limit), body: $0.body, kind: $0.kind)
            }
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        while !copy.cards.isEmpty {
            copy.cards.removeLast()
            // ใบที่ถูกตัดเพราะ MTU ล้นก็ยังต้องนับ — จอต้องบอกได้ว่ามีอีกกี่ใบ
            // ไม่ว่ามันหายไปเพราะจอวาดไม่พอหรือเพราะสายส่งไม่พอ
            copy.cardOverflow += 1
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        if copy.machine != nil {
            copy.machine = nil
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        if copy.place != nil {
            copy.place = nil
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        // อากาศตกก่อนโควตา — มันคือบรรยากาศ ไม่ใช่ข้อมูลที่ใครต้องตัดสินใจจากมัน
        if copy.weather != nil {
            copy.weather = nil
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        // โควตาตกก่อน session — session คือเหตุผลที่จอนี้มีอยู่ ส่วนโควตายังดูได้จาก
        // statusline บนจอคอม การหายไปของมันจึงไม่ทำให้อุปกรณ์ไร้ประโยชน์
        if copy.usage != nil {
            copy.usage = nil
            data = try encoder.encode(copy)
            if data.count <= maxBytes { return data }
        }
        return data
    }
}

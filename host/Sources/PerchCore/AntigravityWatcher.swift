import Foundation

/// เฝ้า session ของ Antigravity CLI (`agy`) แล้วแปลงเป็น `HookEvent` ชุดเดียวกับ Claude Code
///
/// `AgentKind.antigravity` มีมานานแล้วและทางเดินครบทั้งเส้น — บอร์ดถอดรหัส `'g'` เป็น
/// `PCH_AGENT_ANTIGRAVITY` ได้ จานสีม่วงก็มี — แต่ไม่เคยมีใครผลิตค่านั้นออกมาเลย
/// มันจึงไม่เคยโผล่บนจอสักครั้ง ไฟล์นี้คือชิ้นที่หายไป
///
/// ## สิ่งที่ agy ทิ้งไว้บนดิสก์
///
///     ~/.gemini/antigravity-cli/
///       history.jsonl                  {"display","timestamp","workspace","conversationId"}
///       conversations/<id>.db          SQLite ต่อหนึ่งบทสนทนา — mtime ขยับทุกครั้งที่มันทำงาน
///       presence/<id>.lock             ไฟล์เปล่าที่โปรเซสที่รันอยู่เปิดค้างไว้
///
/// เนื้อใน `.db` เป็น protobuf ทั้งก้อน (`step_payload` BLOB) และทุกแถวถูกเขียนด้วย
/// `status = 3` เมื่อจบแล้ว — มันจึงบอกไม่ได้ว่า *ตอนนี้* กำลังทำอะไร เราเลยไม่แตะมันเลย
/// ใช้ mtime ของไฟล์เป็นสัญญาณว่า "ขยับอยู่" แทน ซึ่งเป็นวิธีเดียวกับที่ `CodexWatcher` ใช้
/// และเพียงพอสำหรับสิ่งที่จอต้องการ: ยุ่งอยู่ / รอผู้ใช้ / จบแล้ว
///
/// ## ทำไมไม่ใช้ presence lock เป็นตัวตัดสิน
///
/// มันเป็นสัญญาณที่ตรงกว่า แต่การจะรู้ว่า lock *ถูกถืออยู่* หรือเป็นไฟล์ค้างจากตัวที่ crash
/// ต้องลองยึดมันดู ซึ่งแปลว่าไปยุ่งกับกลไกกันชนของโปรแกรมที่กำลังทำงานของผู้ใช้อยู่
/// การมีอยู่ของไฟล์จึงถูกใช้เป็นสัญญาณเสริมเท่านั้น ส่วนตัวตัดสินคือ mtime ที่อ่านอย่างเดียว
///
/// อ่านอย่างเดียว ไม่เคยเขียนอะไรลง `~/.gemini`
public final class AntigravityWatcher {
    /// เงียบเกินเท่านี้ถือว่า session จบ — agy ไม่เขียนอะไรบอกตอนปิด
    private let idleTimeout: TimeInterval = 15 * 60
    /// ไฟล์ที่ mtime เก่ากว่านี้ไม่ต้องสนใจเลย ประหยัดการ stat ทั้งโฟลเดอร์
    private let activeWindow: TimeInterval = 30 * 60
    /// ขยับล่าสุดเกินเท่านี้ = เทิร์นจบ ลูกบอลอยู่ที่ผู้ใช้
    ///
    /// ต้องยาวกว่าช่องว่างระหว่างการเรียกเครื่องมือสองครั้งติดกัน ไม่งั้นมาสคอตจะสลับ
    /// ยุ่ง/รอ ถี่ๆ ตลอดเทิร์นเดียว แต่ต้องสั้นพอให้ "เสร็จแล้ว" มาถึงตาก่อนที่ผู้ใช้จะเดินจากไป
    private let quietForStop: TimeInterval = 20
    /// อ่าน history ได้มากสุดต่อรอบ — ไฟล์นี้โตเรื่อยๆ ไม่มีการตัด
    private let maxBytesPerPoll = 256 * 1024

    private struct Tracked {
        var sessionId: String
        var workspace: String?
        var tmux: String?
        var mtime: Date
        var lastSeen: Date
        var announced = false
        var working = false
        var ended = false
    }

    private let root: URL
    private var tracked: [String: Tracked] = [:]  // conversationId -> state
    /// อ่าน history.jsonl ต่อจากที่ค้างไว้ ไม่ใช่ทั้งไฟล์ทุกรอบ
    private var historyOffset: UInt64 = 0
    /// conversationId -> workspace ที่เคยเห็นใน history — ใช้ตั้งชื่อโปรเจกต์บนจอ
    private var workspaces: [String: String] = [:]

    public init(root: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)) {
        self.root = root
    }

    private var conversationsDir: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    private var presenceDir: URL { root.appendingPathComponent("presence", isDirectory: true) }
    private var historyFile: URL { root.appendingPathComponent("history.jsonl") }

    public func poll(now: Date = Date()) -> [HookEvent] {
        readHistory(now: now)
        var events = scanConversations(now: now)
        events += expire(now: now)
        return events
    }

    /// เก็บ workspace ของแต่ละบทสนทนาจาก history.jsonl
    ///
    /// นี่คือแหล่งเดียวที่บอก *ไดเรกทอรีของ session* ได้อย่างเชื่อถือได้ พาธที่โผล่ใน `.db`
    /// คือพาธที่ถูก *พูดถึง* ในบทสนทนา ไม่ใช่ที่ที่ session ทำงานอยู่ — ใช้แทนกันไม่ได้
    private func readHistory(now: Date) {
        guard let handle = try? FileHandle(forReadingFrom: historyFile) else { return }
        defer { try? handle.close() }
        // ไฟล์สั้นลง = ถูกตัดหรือเขียนใหม่ ต้องเริ่มอ่านใหม่ ไม่ใช่ค้างที่ offset เดิมตลอดกาล
        let size = (try? handle.seekToEnd()) ?? 0
        if size < historyOffset { historyOffset = 0 }
        try? handle.seek(toOffset: historyOffset)
        guard let chunk = try? handle.read(upToCount: maxBytesPerPoll), !chunk.isEmpty else {
            return
        }
        // หยุดที่บรรทัดสมบูรณ์สุดท้าย — บรรทัดที่ถูกเขียนค้างครึ่งทางจะอ่านให้จบในรอบหน้า
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else { return }
        let usable = chunk[chunk.startIndex...lastNewline]
        historyOffset += UInt64(usable.count)

        for line in usable.split(separator: 0x0A) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = obj["conversationId"] as? String,
                let workspace = obj["workspace"] as? String, !workspace.isEmpty
            else { continue }
            workspaces[id] = workspace
            // มีบรรทัดใหม่ใน history = ผู้ใช้เพิ่งพิมพ์อะไรเข้าไป
            if var s = tracked[id], !s.ended {
                s.lastSeen = now
                tracked[id] = s
            }
        }
    }

    private func scanConversations(now: Date) -> [HookEvent] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: conversationsDir.path) else {
            return []
        }
        var events: [HookEvent] = []
        for name in names where name.hasSuffix(".db") {
            let id = String(name.dropLast(3))
            let path = conversationsDir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                let mtime = attrs[.modificationDate] as? Date
            else { continue }
            // บทสนทนาเก่าจากเดือนก่อนมีเป็นสิบ ไม่ต้องแตะเลย
            guard now.timeIntervalSince(mtime) < activeWindow else { continue }

            var s = tracked[id] ?? Tracked(
                sessionId: "antigravity-" + id, workspace: nil, tmux: nil,
                mtime: .distantPast, lastSeen: mtime)
            if s.ended { continue }

            if s.workspace == nil, let ws = workspaces[id] {
                s.workspace = ws
                s.tmux = TmuxSession.forWorkingDirectory(ws)
            }
            if !s.announced {
                s.announced = true
                events.append(make("SessionStart", s, source: "startup"))
            }

            if mtime > s.mtime {
                // ไฟล์เพิ่งถูกเขียน = กำลังทำงานอยู่
                //
                // บอกชื่อเครื่องมือไม่ได้เพราะเนื้อในเป็น protobuf — ปล่อยเป็น nil ดีกว่าเดา
                // ชื่อมั่วๆ ขึ้นจอ จอจะขึ้นท่า "ยุ่งอยู่" ซึ่งเป็นข้อมูลที่ถูกต้องเท่าที่เรารู้จริง
                s.mtime = mtime
                s.lastSeen = now
                if !s.working {
                    s.working = true
                    events.append(make("PreToolUse", s))
                }
            } else if s.working, now.timeIntervalSince(s.lastSeen) > quietForStop {
                s.working = false
                events.append(make("Stop", s))
            }
            tracked[id] = s
        }
        return events
    }

    /// ปิด session ที่เงียบนานเกิน — ไม่งั้นมาสคอตม่วงค้างบนจอตลอดไป
    private func expire(now: Date) -> [HookEvent] {
        var events: [HookEvent] = []
        for (id, var s) in tracked where !s.ended {
            guard now.timeIntervalSince(s.lastSeen) > idleTimeout else { continue }
            // ไฟล์ presence ยังอยู่ = น่าจะยังเปิดค้างอยู่จริง แค่ไม่ได้สั่งอะไรมานาน
            // สัญญาณนี้ใช้ *ยืดเวลา* ได้อย่างเดียว ไม่เคยใช้ตัดสินว่ายังมีชีวิต เพราะไฟล์
            // ที่ค้างจากตัวที่ crash หน้าตาเหมือนกันเป๊ะ และเราไม่ยึด lock ไปตรวจ
            if FileManager.default.fileExists(
                atPath: presenceDir.appendingPathComponent("\(id).lock").path) {
                continue
            }
            s.ended = true
            tracked[id] = s
            if s.announced { events.append(make("SessionEnd", s)) }
        }
        // ปล่อยของที่ปิดแล้วทิ้ง ไม่ให้ dict โตไม่หยุดในเครื่องที่เปิดทิ้งไว้เป็นเดือน
        tracked = tracked.filter { !$0.value.ended }
        return events
    }

    private func make(_ name: String, _ s: Tracked, source: String? = nil) -> HookEvent {
        HookEvent(hookEventName: name, sessionId: s.sessionId, cwd: s.workspace,
                  toolName: nil, source: source, agent: .antigravity, tmux: s.tmux)
    }
}

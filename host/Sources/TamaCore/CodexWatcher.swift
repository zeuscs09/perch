import Foundation

/// เฝ้า session ของ Codex CLI แล้วแปลงเป็น `HookEvent` ชุดเดียวกับที่ Claude Code ส่งมา
///
/// Codex ไม่มีระบบ hook แบบ Claude Code — มีแต่ `notify` ช่องเดียวที่ผู้ใช้มักจองไว้แล้ว
/// และมันยิงแค่ตอนจบเทิร์น ซึ่งหยาบเกินกว่าจะทำให้มาสคอตขยับตามงานจริงได้
///
/// สิ่งที่ Codex ทำแน่นอนคือ *เขียนไฟล์ rollout ตลอดเวลา* — ทุกการเรียกเครื่องมือ ทุกข้อความ
/// ลงไฟล์ทันที เราจึงอ่านส่วนที่งอกใหม่ของไฟล์แทนการรอให้มันบอก วิธีนี้ไม่ต้องแก้ config
/// ของผู้ใช้ ไม่แย่ง `notify` กับใคร และได้ความละเอียดระดับเดียวกับ hook
///
/// อ่านอย่างเดียว ไม่เคยเขียนอะไรลง `~/.codex`
public final class CodexWatcher {
    /// ไฟล์ที่เงียบเกินเท่านี้ถือว่า session จบ — Codex ไม่เขียนอะไรบอกตอนปิด
    private let idleTimeout: TimeInterval = 15 * 60
    /// ไฟล์ที่ mtime เก่ากว่านี้ไม่ต้องเปิดเลย ประหยัดการ stat ทั้งโฟลเดอร์
    private let activeWindow: TimeInterval = 30 * 60

    private struct Tracked {
        var offset: UInt64 = 0
        var sessionId: String
        var cwd: String?
        var lastSeen: Date
        var announced = false
        var ended = false
    }

    private let root: URL
    private var tracked: [String: Tracked] = [:]  // path -> state

    public init(root: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.root = root
    }

    /// ผูก session กับไฟล์ ไม่ใช่กับ uuid ที่อยู่ในเนื้อไฟล์ — uuid ในชื่อไฟล์มีเสมอ
    /// ส่วน `session_meta` อาจถูกอ่านไม่ทันถ้าเราเริ่มเฝ้ากลางคัน
    private static func sessionId(fromPath path: String) -> String {
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // rollout-2026-08-02T15-37-29-<uuid>
        let uuid = base.split(separator: "-").suffix(5).joined(separator: "-")
        return "codex-" + (uuid.isEmpty ? base : uuid)
    }

    /// เรียกจาก pulse ของ daemon — คืนเหตุการณ์ที่เพิ่งเกิดตั้งแต่ครั้งก่อน
    public func poll(now: Date = Date()) -> [HookEvent] {
        var events: [HookEvent] = []
        for path in activeFiles(now: now) {
            events += drain(path: path, now: now)
        }
        events += expire(now: now)
        return events
    }

    private func activeFiles(now: Date) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                url.pathExtension == "jsonl",
                let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else { continue }
            // ไฟล์เก่าที่เราเคยเฝ้าไว้ต้องคงอยู่ในลิสต์ ไม่งั้น expire() ไม่มีวันได้ปิดมัน
            if now.timeIntervalSince(mtime) < activeWindow || tracked[url.path] != nil {
                out.append(url.path)
            }
        }
        return out
    }

    /// อ่านเฉพาะไบต์ที่งอกใหม่ตั้งแต่รอบก่อน — ไฟล์ session ยาวหลายสิบเมกได้
    private func drain(path: String, now: Date) -> [HookEvent] {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return [] }
        defer { try? handle.close() }

        var state = tracked[path] ?? Tracked(sessionId: Self.sessionId(fromPath: path), lastSeen: now)
        let size = (try? handle.seekToEnd()) ?? 0
        // ไฟล์หดแปลว่าถูกเขียนทับ/หมุน — เริ่มอ่านใหม่ตั้งแต่ต้น ดีกว่าอ่านกลางบรรทัด
        if size < state.offset { state.offset = 0 }
        guard size > state.offset else {
            tracked[path] = state
            return []
        }

        try? handle.seek(toOffset: state.offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            tracked[path] = state
            return []
        }

        // หยุดที่ขึ้นบรรทัดสุดท้ายที่สมบูรณ์ — Codex อาจกำลังเขียนบรรทัดค้างอยู่
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            tracked[path] = state
            return []
        }
        let usable = chunk[chunk.startIndex...lastNewline]
        state.offset += UInt64(usable.count)
        state.lastSeen = now

        var events: [HookEvent] = []
        for line in usable.split(separator: 0x0A) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if obj["type"] as? String == "session_meta", let cwd = payload["cwd"] as? String {
                state.cwd = cwd
            }
            if !state.announced {
                events.append(make("SessionStart", state, source: "startup"))
                state.announced = true
            }
            if let e = translate(payload, state) { events.append(e) }
        }
        tracked[path] = state
        return events
    }

    /// event ของ Codex -> hook ของ Claude Code
    /// คืน nil สำหรับ event ที่ไม่เปลี่ยนสิ่งที่เห็นบนจอ (reasoning, token_count ฯลฯ)
    private func translate(_ payload: [String: Any], _ s: Tracked) -> HookEvent? {
        switch payload["type"] as? String {
        case "user_message":
            return make("UserPromptSubmit", s)
        case "task_complete":
            // เทิร์นจบ = ลูกบอลอยู่ที่ผู้ใช้ ตรงกับความหมายของ Stop ฝั่ง Claude Code
            return make("Stop", s)
        case "custom_tool_call", "function_call":
            return make("PreToolUse", s, tool: payload["name"] as? String)
        case "custom_tool_call_output", "function_call_output":
            return make("PostToolUse", s, tool: payload["name"] as? String)
        case "patch_apply_begin":
            return make("PreToolUse", s, tool: "apply_patch")
        case "patch_apply_end":
            return make("PostToolUse", s, tool: "apply_patch")
        default:
            return nil
        }
    }

    /// ปิด session ที่เงียบนานเกิน — ไม่งั้นมาสคอตของ Codex ค้างบนจอตลอดไป
    private func expire(now: Date) -> [HookEvent] {
        var events: [HookEvent] = []
        for (path, var s) in tracked where !s.ended {
            guard now.timeIntervalSince(s.lastSeen) > idleTimeout else { continue }
            s.ended = true
            tracked[path] = s
            if s.announced { events.append(make("SessionEnd", s)) }
        }
        // ปล่อยของที่ปิดแล้วทิ้งไป ไม่ให้ dict โตไม่หยุดในเครื่องที่เปิดทิ้งไว้เป็นเดือน
        tracked = tracked.filter { !$0.value.ended }
        return events
    }

    private func make(_ name: String, _ s: Tracked, tool: String? = nil,
                      source: String? = nil) -> HookEvent {
        HookEvent(hookEventName: name, sessionId: s.sessionId, cwd: s.cwd,
                  toolName: tool, source: source, agent: .codex)
    }
}

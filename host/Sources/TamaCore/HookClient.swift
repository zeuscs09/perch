import Foundation

/// โหมด `--hook` — ต่อท้าย Claude Code hook ทุกตัว
///
/// กติกาข้อเดียวที่ห้ามพลาด: ต้องคืน 0 และจบเร็วเสมอ แม้ daemon ไม่ทำงาน
/// hook ที่พังหรือค้างจะไปทำให้ session ของผู้ใช้พังตาม ซึ่งแย่กว่าจอไม่ขยับมาก
public enum HookClient {
    public static func run(input: FileHandle = .standardInput) -> Int32 {
        guard let raw = try? input.readToEnd(), !raw.isEmpty else { return 0 }
        guard var event = try? JSONDecoder().decode(HookEvent.self, from: raw) else {
            Log.debug("hook input was not a recognised event")
            return 0
        }
        // ต้องหาที่นี่เท่านั้น: hook process ยังเป็นลูกของ Claude Code อยู่ตอนนี้
        // พอส่งเข้า socket แล้ว daemon อยู่คนละสายบรรพบุรุษ ไต่กลับไปไม่ได้อีก
        event.owner = ProcessTree.claudeAncestor()
        // ด้วยเหตุผลเดียวกับ owner: TMUX_PANE เป็นของ pane นี้ ตอนนี้เท่านั้น
        if event.tmux == nil { event.tmux = TmuxSession.current() }
        guard let line = try? Wire.encoder().encode(event) else { return 0 }
        let ok = SocketClient(path: Paths.socket).send(line)
        if !ok { Log.debug("daemon not running, event dropped") }
        return 0
    }
}

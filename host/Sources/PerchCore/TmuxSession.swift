import Foundation

/// ชื่อ tmux session ของ pane ที่ hook กำลังวิ่งอยู่
///
/// ทำไมต้องมี: หลายทีมวางโครงโฟลเดอร์เหมือนกันหมด (`<project>/agents/<role>`)
/// ชื่อโฟลเดอร์สุดท้ายจึงซ้ำกันข้ามทีม — วัดจากเครื่องจริงพบ `orchestrator` โผล่
/// 18 session, `qa` 13, `ba` 11 ป้ายใต้มาสคอตเลยบอกไม่ได้ว่ากำลังดูทีมไหนอยู่
///
/// ชื่อ session คือสิ่งที่ผู้ใช้พิมพ์ตอน `tmux attach` — มันตอบว่า "ต้องไปที่ไหน"
/// ซึ่งเป็นคำถามที่จอนี้มีไว้ตอบ
///
/// **ต้องหาในกระบวนการของ hook เท่านั้น** — `TMUX_PANE` สืบทอดมาจาก Claude Code
/// ที่รันอยู่ใน pane นั้นจริงๆ พอส่งเข้า socket แล้ว daemon อยู่คนละสาย หาไม่ได้อีก
///
/// ## เรื่องที่ต้องระวังที่สุดในไฟล์นี้: ต้นทุนของการ fork
///
/// hook ถูกเรียก *ทุกครั้งที่ agent เรียกเครื่องมือ* คูณด้วยจำนวน session ที่เปิดอยู่
/// เครื่องที่รันหลายสิบทีมพร้อมกันจึงเรียกไฟล์นี้เป็นพันครั้งต่อนาที ทุกกระบวนการที่
/// ไฟล์นี้ยอมให้ค้างจะกลายเป็น process ที่ไม่มีวันตาย
///
/// เคยเกิดขึ้นจริง: เวอร์ชันแรก fork `tmux` สองตัวต่อหนึ่ง hook แล้วรอด้วย
/// `waitUntilExit()` เปล่าๆ พอเครื่องเข้าใกล้เพดาน process ตัว `tmux` เองก็ fork ไม่ได้
/// และค้าง ทำให้ hook ค้างตาม สะสมจนแตะ 7,000 กระบวนการค้างและเครื่องหมดโควตา
/// ซึ่งย้อนกลับมาทำให้ทุกอย่างค้างหนักขึ้นอีก
///
/// กติกาสองข้อจึงห้ามผ่อน: **หนึ่ง hook ต่อหนึ่ง fork** และ **ทุกการรอมีเพดานเวลา**
public enum TmuxSession {
    /// เพดานเวลาของทุกคำสั่ง — tmux ที่ตอบไม่ได้ใน 1.5 วิ คือ tmux ที่กำลังมีปัญหา
    /// รอต่อไม่ได้ช่วยอะไร ป้ายชื่อที่หายไปหนึ่งใบดีกว่ากระบวนการที่ไม่ตาย
    private static let timeout: TimeInterval = 1.5

    /// จำผลไว้ตลอดอายุ process — hook เป็น process อายุสั้น ยิงครั้งเดียวก็จบ
    /// แต่ฝั่ง daemon อยู่ยาว การจำจึงเป็นสิ่งที่กันไม่ให้มันยิง tmux ทุกจังหวะ
    nonisolated(unsafe) private static var cached: String??
    nonisolated(unsafe) private static var cachedPanes: [Pane]?
    nonisolated(unsafe) private static var cachedAt: Date?

    public struct Pane {
        public var session: String
        public var id: String
        public var path: String
    }

    public static func current(env: [String: String] = ProcessInfo.processInfo.environment)
        -> String? {
        if let cached { return cached }
        let value = resolve(env: env)
        cached = value
        return value
    }

    /// รายชื่อ session ทั้งหมด — ใช้ตัดสินว่าคำนำหน้า/ต่อท้ายไหนซ้ำจนตัดทิ้งได้
    ///
    /// อ่านจากผลชุดเดียวกับที่ใช้หา pane ไม่ได้ยิง `list-sessions` แยกอีกรอบ:
    /// pane ทุกตัวบอกชื่อ session ของมันอยู่แล้ว การถามซ้ำคือการ fork ฟรีๆ
    public static func allNames() -> [String] {
        var seen = Set<String>()
        return panes().compactMap { seen.insert($0.session).inserted ? $0.session : nil }
    }

    /// แปลรหัส pane ("%12") -> ชื่อ session ที่ย่อแล้ว
    ///
    /// ทางเข้าของฝั่ง daemon: hook ส่งแต่รหัสดิบมาให้เพราะมันอ่านฟรีจาก env ส่วนการแปล
    /// ต้องเรียก tmux ซึ่ง daemon ทำแทนได้และทำครั้งเดียวใช้ได้กับทุก event ที่ตามมา
    ///
    /// `maxAge` ทำให้ผลที่จำไว้หมดอายุ — pane ย้าย session ได้และ session ใหม่เกิดได้
    /// ตลอดเวลา แต่ไม่ใช่ทุกวินาที 30 วิจึงเป็นความสดที่พอสำหรับป้ายชื่อ โดยจ่ายแค่
    /// สอง fork ต่อนาที ไม่ว่าจะมี event เข้ามากี่พันครั้งก็ตาม
    public static func sessionName(forPane pane: String, maxAge: TimeInterval = 30,
                                   now: Date = Date()) -> String? {
        guard !pane.isEmpty else { return nil }
        if let stamp = cachedAt, now.timeIntervalSince(stamp) > maxAge { cachedPanes = nil }
        if cachedPanes == nil { cachedAt = now }
        guard let match = panes().first(where: { $0.id == pane }) else { return nil }
        return SessionLabel.shorten(match.session, among: allNames())
    }

    /// ทุกอย่างที่ไฟล์นี้ต้องรู้ มาจากคำสั่งเดียวนี้คำสั่งเดียว
    private static func panes() -> [Pane] {
        if let cachedPanes { return cachedPanes }
        let rows = run(["list-panes", "-a", "-F",
                        "#{session_name}\t#{pane_id}\t#{pane_current_path}"])
            .map { text in
                text.split(separator: "\n").compactMap { line -> Pane? in
                    let parts = line.split(separator: "\t", maxSplits: 2)
                    guard parts.count == 3, !parts[0].isEmpty else { return nil }
                    return Pane(session: String(parts[0]), id: String(parts[1]),
                                path: String(parts[2]))
                }
            } ?? []
        cachedPanes = rows
        return rows
    }

    private static func resolve(env: [String: String]) -> String? {
        // ไม่ได้อยู่ใน tmux = ไม่ต้อง fork อะไรเลย (เคสปกติของคนที่ไม่ได้ใช้ tmux)
        guard let pane = env["TMUX_PANE"], !pane.isEmpty, env["TMUX"] != nil else { return nil }
        guard let match = panes().first(where: { $0.id == pane }) else { return nil }
        return SessionLabel.shorten(match.session, among: allNames())
    }

    /// หา session จาก cwd — ใช้กับ Codex ที่ไม่มี `TMUX_PANE` ให้เรา
    /// (เราอ่านไฟล์ rollout ของมันจากนอก pane) จับคู่ด้วยที่อยู่ของ pane ที่เปิดอยู่จริง
    public static func forWorkingDirectory(_ cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        guard let match = panes().first(where: { $0.path == cwd }) else { return nil }
        return SessionLabel.shorten(match.session, among: allNames())
    }

    /// daemon อยู่ยาวและ pane ย้ายได้ — ต้องมีทางล้างของที่จำไว้
    public static func forgetPanes() { cachedPanes = nil }

    private static func run(_ arguments: [String]) -> String? {
        Subprocess.run("/usr/bin/env", ["tmux"] + arguments, timeout: timeout)
    }
}

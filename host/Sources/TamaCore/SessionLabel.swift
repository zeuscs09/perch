import Foundation

/// ประกอบป้ายใต้มาสคอตจาก "อยู่ tmux session ไหน" + "เป็นบทบาทอะไร"
///
/// ชื่อโฟลเดอร์สุดท้ายอย่างเดียวใช้ไม่ได้เมื่อมีหลายทีม เพราะทุกทีมวางโครงเหมือนกัน
/// (`<project>/agents/<role>`) — วัดจากเครื่องจริงพบว่า `orchestrator` โผล่ 18 session,
/// `qa` 13, `ba` 11 ป้ายจึงบอกไม่ได้เลยว่ากำลังดูทีมไหน
///
/// ชื่อ tmux session คือสิ่งที่ผู้ใช้คิดและใช้ `tmux attach` จริง — มันตอบคำถามว่า
/// "ต้องไปที่ไหน" ส่วนบทบาทตอบว่า "ใครในทีมนั้น" ป้ายต้องมีทั้งคู่แต่มีที่แค่ 14 ตัว
public enum SessionLabel {
    /// ตัวคั่นที่ไม่ใช่ `/` — เส้นทับอ่านเป็น path แล้วชวนให้คิดว่าตัดมาไม่ครบ
    static let separator = "\u{00B7}"  // ·

    /// บทบาทเหลือสั้นสุดเท่านี้ก่อนจะถือว่าอ่านไม่รู้เรื่องแล้ว
    /// ("orch" ยังเดาออกว่า orchestrator, "or" ไม่ออก)
    static let roleFloor = 4

    /// โฟลเดอร์ที่เป็นแค่ที่เก็บ ไม่ได้บอกอะไรเกี่ยวกับงาน — ถ้าชื่อสุดท้ายเป็นตัวพวกนี้
    /// ให้ถอยขึ้นไปอีกชั้น ไม่งั้นได้ป้ายว่า "agents" ซึ่งไม่ต่างกันสักทีม
    static let containers: Set<String> = [
        "agents", "src", "app", "apps", "packages", "services", "workers", "repo",
    ]

    /// ชื่อบทบาทจาก path — ข้ามโฟลเดอร์ที่เป็นแค่ที่เก็บ
    public static func role(fromPath path: String) -> String {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<3 {
            let name = url.lastPathComponent
            if name.isEmpty || name == "/" { break }
            if !containers.contains(name.lowercased()) { return name }
            url.deleteLastPathComponent()
        }
        return url.lastPathComponent
    }

    /// ตัดคำนำหน้า/ต่อท้ายที่ซ้ำกันหลาย session ออก
    ///
    /// ชื่อ session จริงบนเครื่องเป็นแบบ `ai-dev-talk2me`, `ai-dev-ba`, `netflix-team`,
    /// `ghost-team` — ท่อน `ai-dev-` กับ `-team` กิน 7 และ 5 ตัวอักษรจากงบ 14 โดยไม่แยก
    /// อะไรออกจากอะไรเลย เพราะทุกตัวที่มีมันก็มีเหมือนกันหมด
    ///
    /// คิดจากรายชื่อจริงตอนรัน ไม่ได้ hardcode — คนอื่นตั้งชื่อคนละแบบก็ยังได้ผล
    /// ตัดเฉพาะตอนที่ผลลัพธ์ยัง **ไม่ซ้ำกับใคร** ไม่งั้นย่อแล้วแยกไม่ออกยิ่งแย่กว่าเดิม
    public static func shorten(_ name: String, among all: [String], minShared: Int = 3) -> String {
        guard all.count >= minShared else { return name }

        func head(_ s: String, _ n: Int) -> String {
            s.split(separator: "-").prefix(n).joined(separator: "-")
        }
        func tail(_ s: String, _ n: Int) -> String {
            s.split(separator: "-").suffix(n).joined(separator: "-")
        }

        var out = name
        // คำนำหน้า: ลองท่อนยาวก่อน ("ai-dev-" ดีกว่าตัดแค่ "ai-")
        for n in stride(from: 3, through: 1, by: -1) {
            let prefix = head(out, n)
            guard !prefix.isEmpty, prefix != out else { continue }
            let sharing = all.filter { $0 != out && head($0, n) == prefix }.count
            guard sharing + 1 >= minShared else { continue }
            let candidate = String(out.dropFirst(prefix.count + 1))
            // ตัดแล้วต้องไม่ไปชนกับ session อื่น และต้องไม่เหลือว่าง
            let others = all.filter { $0 != name }.map { s -> String in
                head(s, n) == prefix ? String(s.dropFirst(prefix.count + 1)) : s
            }
            if !candidate.isEmpty, !others.contains(candidate) {
                out = candidate
                break
            }
        }
        // คำต่อท้าย: เหตุผลเดียวกัน ("-team", "-dev")
        for n in stride(from: 2, through: 1, by: -1) {
            let suffix = tail(out, n)
            guard !suffix.isEmpty, suffix != out else { continue }
            let sharing = all.filter { $0 != name && tail($0, n) == suffix }.count
            guard sharing + 1 >= minShared else { continue }
            let candidate = String(out.dropLast(suffix.count + 1))
            let others = all.filter { $0 != name }.map { s -> String in
                tail(s, n) == suffix ? String(s.dropLast(suffix.count + 1)) : s
            }
            if !candidate.isEmpty, !others.contains(candidate) {
                out = candidate
                break
            }
        }
        return out
    }

    /// รวมชื่อ session กับบทบาทให้พอดี `limit` ตัวอักษร
    ///
    /// ลำดับการยอมเสีย: บทบาทย่อก่อน (เดาได้จากตัวหน้า) แล้วค่อยย่อชื่อ session
    /// เพราะชื่อ session คือสิ่งที่ต้องพิมพ์ตอน attach — ผิดตัวอักษรเดียวก็หาไม่เจอ
    public static func compose(session: String?, role: String, limit: Int = 14) -> String {
        let role = role.trimmingCharacters(in: .whitespaces)
        guard let session = session?.trimmingCharacters(in: .whitespaces), !session.isEmpty else {
            return String(role.prefix(limit))
        }
        // pane ที่นั่งอยู่ที่รากของโปรเจกต์เลย ชื่อจะซ้ำกับ session — อย่าเขียนสองรอบ
        if role.isEmpty || role.lowercased() == session.lowercased() {
            return String(session.prefix(limit))
        }

        let full = session + separator + role
        if full.count <= limit { return full }

        // ย่อบทบาทลงมาจนถึงพื้น แล้วดูว่าพอหรือยัง
        let roomForRole = limit - session.count - separator.count
        if roomForRole >= roleFloor {
            return session + separator + String(role.prefix(roomForRole))
        }

        // ยังไม่พอ: บทบาทอยู่ที่พื้น ที่เหลือเป็นของ session
        let roomForSession = max(1, limit - roleFloor - separator.count)
        return String(session.prefix(roomForSession)) + separator + String(role.prefix(roleFloor))
    }
}

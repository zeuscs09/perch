import Foundation

/// สิ่งที่ statusline อยากรู้จาก git: อยู่ branch ไหน และแก้ไปกี่บรรทัดแล้ว
///
/// ยิง `git` จริงแทนที่จะอ่านตัวเลข `cost.total_lines_*` จาก payload เพราะสองอย่างนี้
/// ตอบคนละคำถาม: payload นับสิ่งที่ *session นี้* แก้ ส่วนบรรทัดสถานะควรบอกว่า
/// *ต้นไม้ทำงาน* ต่างจาก HEAD แค่ไหน ซึ่งรวมของที่แก้ด้วยมือและของจาก session อื่น
///
/// ทุกคำสั่งใส่ `--no-optional-locks` เพราะสิ่งนี้ทำงานทุกสิบวินาทีระหว่างที่ผู้ใช้
/// กำลังพิมพ์คำสั่ง git อยู่ — การแย่ง index.lock กันคือการทำให้เครื่องมือของเขาพัง
public enum GitSummary {
    public static func of(dir: String?, wantLines: Bool) -> StatuslineRender.GitInfo? {
        guard let dir, run(["rev-parse", "--git-dir"], in: dir) != nil else { return nil }

        var info = StatuslineRender.GitInfo()
        info.branch = run(["branch", "--show-current"], in: dir)
        guard wantLines else { return info }

        // ยังไม่มี commit แรก: เทียบกับ HEAD ไม่ได้ ก็เหลือแค่ของที่ stage ไว้
        let hasHead = run(["rev-parse", "--verify", "HEAD"], in: dir) != nil
        let stat = run(
            hasHead ? ["diff", "--shortstat", "HEAD"] : ["diff", "--shortstat", "--cached"],
            in: dir) ?? ""
        info.added = count(stat, unit: "insertion")
        info.removed = count(stat, unit: "deletion")

        // `git diff` ไม่เห็นไฟล์ที่ยังไม่ถูก track เลย — ไฟล์ใหม่ทั้งไฟล์คือบรรทัดที่เพิ่ม
        for name in (run(["ls-files", "--others", "--exclude-standard"], in: dir) ?? "")
            .split(whereSeparator: \.isNewline) {
            let path = URL(fileURLWithPath: dir).appendingPathComponent(String(name))
            guard let data = try? Data(contentsOf: path, options: .mappedIfSafe) else { continue }
            info.added += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        return info
    }

    /// "3 files changed, 12 insertions(+), 4 deletions(-)" → ตัวเลขหน้าคำที่ขอ
    public static func count(_ stat: String, unit: String) -> Int {
        for part in stat.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count >= 2, words[1].hasPrefix(unit) else { continue }
            return Int(words[0]) ?? 0
        }
        return 0
    }

    /// คืน `nil` เมื่อ git บอกว่าล้มเหลว และคืนสตริงว่างเมื่อสำเร็จแต่ไม่มีอะไรจะบอก
    /// — สองกรณีนี้ต่างกัน (ไม่ใช่ repo กับ HEAD ที่ยังไม่มี branch)
    /// เพดานเวลาต่อคำสั่ง git หนึ่งคำสั่ง
    ///
    /// git ค้างได้จริงและค้างบ่อยกว่าที่คิด: repo ใหญ่, ดิสก์ที่ยัง sync อยู่ (iCloud/Dropbox),
    /// remote ที่ตอบช้า, หรือเครื่องที่กำลังตันจน `fork` เองก็บล็อก
    ///
    /// สิ่งที่ทำให้เรื่องนี้ร้ายกว่าปกติคือความถี่: ทำงานทุกสิบวินาที *ต่อทุก session*
    /// บนเครื่องที่เปิดหลายสิบ session การรอที่ไม่มีเพดานจึงไม่ใช่ "บรรทัดสถานะช้า"
    /// แต่เป็นกระบวนการที่ไม่มีวันตายสะสมไปเรื่อยๆ จนเครื่องหมดโควตา — เกิดขึ้นจริงแล้ว
    ///
    /// เป็นบั๊กชนิดเดียวกับที่ `TmuxSession` เคยมี ต่างกันแค่ว่าอันนี้เรียก git แทน tmux
    /// การไล่หา "ที่อื่นที่รอโดยไม่มีเพดาน" หลังแก้อันแรกน่าจะเจอไฟล์นี้ตั้งแต่ตอนนั้น
    private static let timeout: TimeInterval = 2

    /// คืน `nil` เมื่อ git บอกว่าล้มเหลว และคืนสตริงว่างเมื่อสำเร็จแต่ไม่มีอะไรจะบอก
    /// — สองกรณีนี้ต่างกัน (ไม่ใช่ repo กับ HEAD ที่ยังไม่มี branch)
    static func run(_ args: [String], in dir: String) -> String? {
        Subprocess.run("/usr/bin/env", ["git", "--no-optional-locks"] + args,
                       timeout: timeout, cwd: dir)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

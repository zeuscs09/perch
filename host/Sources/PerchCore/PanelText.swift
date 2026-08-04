import Foundation

/// ข้อความท้าย popover — สถานะบอร์ดกับรายการ session
///
/// อยู่ใน PerchCore ไม่ใช่ใน MenuBarApp เพราะเป็นตรรกะล้วนที่เทสต์ได้ ส่วนที่เหลือของ
/// popover เป็น AppKit ที่เทสต์ไม่ได้บนเครื่องที่ไม่มีหน้าจอ แยกออกมาแล้วเส้นแบ่ง
/// ระหว่าง "สิ่งที่พูด" กับ "วิธีวาด" ก็ชัดขึ้นด้วย
public enum PanelText {
    /// ไม่มีคำว่า disconnected: บอร์ดที่ยังหาไม่เจอกับบอร์ดที่หลุดไปเป็นสภาพเดียวกัน
    /// สำหรับผู้ใช้ — แอปกำลังสแกนอยู่และจะกลับมาต่อเอง
    ///
    /// ทาง LAN ถูกบอกออกมาตรงๆ ไม่ใช่กลืนเป็น "connected" เฉยๆ: มันเป็นทางที่ทำงานได้
    /// ก็ต่อเมื่อ Mac กับบอร์ดอยู่บนเน็ตเดียวกัน ผู้ใช้ที่กำลังจะพกโน้ตบุ๊กออกจากบ้าน
    /// ควรรู้ว่าจอบนโต๊ะจะค้างเมื่อเขาเดินพ้นประตู
    public static func board(route: LanRoute) -> String {
        switch route {
        case .ble: return "Board connected"
        case .lan: return "Board connected over Wi-Fi"
        case .none: return "Looking for the board…"
        }
    }

    /// ชื่อแอปตอนยังไม่มี org ให้พูดถึง — ไม่ใช่ที่ว่าง ไม่ใช่ `—`
    public static let appName = "Perch"

    /// ชื่อรายการ "ลิงก์โปรเจกต์" ในเมนูเฟือง — ข้อความ *คือ* ปลายทาง ไม่ใช่คำว่า "GitHub"
    /// ที่ซ่อนพาธไว้ ผู้ใช้ที่กำลังจะให้ credential กับแอปนี้ควรอ่านออกว่ามันจะพาไปไหนก่อนกด
    ///
    /// ไม่มี scheme เพราะ `https://` ไม่ได้บอกอะไรที่ปลายทางอื่นไม่มีเหมือนกัน — ส่วนที่
    /// ต่างกันคือส่วนที่เหลือ · อยู่ใน `PanelText` แม้จะเป็นรายการในเมนู เพราะเมนูเฟือง
    /// เป็นส่วนหนึ่งของแผง (ดู `DESIGN.md`: ของที่ต้องมองอยู่บนแผง ของที่ต้องกดอยู่หลังเฟือง)
    public static let projectLink = "github.com/zeuscs09/perch"

    public static var projectURL: URL? { URL(string: "https://" + projectLink) }

    /// หัว popover — ชื่อ org ที่ตัวเลขบนแผงนี้มาจาก
    ///
    /// ยังไม่ได้ตั้ง key แปลว่ายังไม่เคยถามใครว่าบัญชีมี org อะไรบ้าง รายการที่ค้างอยู่จาก
    /// key ตัวก่อนจึงเป็นของเก่าที่ไม่มีอะไรรับรอง — ชื่อแอปจริงกว่า · id ที่เรียกชื่อไม่ได้
    /// ก็ไม่ใช่ชื่อ ปกติ `currentOrg` ถอยเป็นตัวแรกให้ก่อนถึงตรงนี้อยู่แล้ว เหลือกรณีเดียว
    /// คือรายการยังมาไม่ถึง
    public static func heading(orgs: [UsagePoll.Org], current: String?, hasKey: Bool) -> String {
        guard hasKey, let current,
            let org = orgs.first(where: { $0.id == current })
        else { return appName }
        return org.name
    }

    /// ลูกศรสลับ org โผล่ต่อเมื่อมีอะไรให้สลับ — บัญชีที่มี org เดียวไม่มีอะไรให้ตัดสินใจ
    /// และลูกศรที่กดแล้วเจอรายการที่มีตัวเลือกเดียวคือคำสัญญาที่ผิด
    ///
    /// ไม่มี key ก็ไม่มีลูกศร ด้วยเหตุผลเดียวกับที่หัวแผงกลับไปเป็นชื่อแอป: รายการที่ค้าง
    /// อยู่จาก key ตัวก่อนไม่มีอะไรรับรอง หัวแผงที่พูดว่า "ยังไม่มี org" พร้อมลูกศรที่กาง
    /// รายการ org ออกมาได้คือสองประโยคที่ขัดกันเอง
    public static func canSwitchOrg(orgs: [UsagePoll.Org], hasKey: Bool) -> Bool {
        hasKey && orgs.count > 1
    }

    /// บรรทัด "ท่อพัง" — มีก็ต่อเมื่อผู้ใช้ต้องลงมือ ไม่ใช่ตอนเน็ตสะดุด
    ///
    /// แยกจาก `figures` โดยตั้งใจ: อันนี้บอกว่าค่าใหม่จะไม่มีวันมาจนกว่าจะแปะ key
    /// อีกอันบอกว่าค่าที่เห็นอยู่เก่าแค่ไหน ยุบสองเรื่องนี้เป็นบรรทัดเดียวเมื่อไร
    /// ผู้ใช้จะแยกไม่ออกว่า "เก่า" แปลว่าต้องทำอะไรหรือไม่ต้องทำอะไร
    public static func keyProblem(_ blocked: PollBlock?) -> String? {
        switch blocked {
        case .expiredKey: return "Session key expired — click to paste a new one"
        case .unusableKeyFile: return "Session key file unusable — click to paste a new one"
        case nil: return nil
        }
    }

    /// บรรทัด "สวิตช์ติ๊กอยู่แต่ไม่มีอะไรเกิดขึ้น เพราะแบบนี้" — มีก็ต่อเมื่อล็อกอยู่
    ///
    /// คนละฟังก์ชันกับ `keyProblem` ทั้งที่ทรงเหมือนกัน เพราะสองอย่างนี้สั่งให้ผู้ใช้ทำ
    /// คนละเรื่อง (ไปติดตั้ง/login `claude` กับ ไปเอา key ใหม่จากเบราว์เซอร์) ฟังก์ชัน
    /// เดียวที่รับทั้งสองชนิดจะบังคับให้ผู้เรียกตัดสินใจแทนว่าอันไหนสำคัญกว่า ซึ่งไม่ใช่
    /// คำถามที่มีคำตอบ — มันพังคนละท่อ และพังพร้อมกันได้
    public static func startProblem(_ blocked: StartBlock?) -> String? {
        switch blocked {
        case .noBinary: return "Cannot start sessions — claude was not found"
        case .notLoggedIn: return "Cannot start sessions — claude is not logged in"
        case nil: return nil
        }
    }

    /// รายละเอียดของบรรทัดข้างบน — อยู่ใน tooltip ไม่ใช่ในบรรทัด
    ///
    /// path สี่บรรทัดในแผงกว้าง 260 คือกำแพงข้อความที่คนที่ไม่ได้มีปัญหานี้ต้องอ่านผ่าน
    /// ทุกครั้ง ส่วนคนที่มีปัญหาจริงกำลังมองหามันอยู่แล้ว
    public static func startProblemDetail(_ blocked: StartBlock?) -> String? {
        switch blocked {
        case .noBinary(let searched):
            // ชื่อคีย์มาจากที่เดียวกับที่โค้ดอ่านมันจริง — คำสั่งที่ผู้ใช้ก็อปไปวางแล้วไม่มีผล
            // เพราะมีคนเปลี่ยนชื่อคีย์ คือคำแนะนำที่แย่กว่าไม่แนะนำอะไรเลย
            return (["Looked in:"] + searched).joined(separator: "\n")
                + "\n\ndefaults write com.perch.daemon \(ClaudeBinary.overrideKey) <path>"
        case .notLoggedIn:
            return "Run claude in a terminal and log in, then switch auto-start off and on again."
        case nil:
            return nil
        }
    }

    /// บรรทัด "ค่านี้อายุเท่าไร" — ความเก่าของตัวเลขที่เห็นอยู่ ไม่ใช่สถานะของท่อ
    ///
    /// มีวินาทีจริงๆ ต่างจากที่อื่นในแอปนี้: ทั้งฟีเจอร์เกิดจากคำถาม "เลขนี้ค้างหรือเปล่า"
    /// และคำตอบที่หยาบระดับนาทีก็แค่ย้ายความสงสัยจากบอร์ดมาไว้บนเมนูบาร์ แผงที่เปิดค้าง
    /// วาดใหม่ทุกวินาทีอยู่แล้ว ตัวเลขที่เดินจึงเป็นหลักฐานว่าแผงยังมีชีวิต
    public static func updated(stamp: Date?, now: Date = Date()) -> String {
        guard let stamp else { return "No quota figures yet" }
        // นาฬิกาเครื่องเดินถอยหลังได้ (sleep, NTP) — อายุติดลบต้องไม่กลายเป็นข้อความประหลาด
        let age = Int(max(0, now.timeIntervalSince(stamp)))
        if age < 60 { return "Updated \(age)s ago" }
        let minutes = age / 60
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "Updated \(hours)h ago" }
        return "Updated \(hours / 24)d ago"
    }

    /// หนึ่งแถวต่อหนึ่ง session แล้วปิดท้ายด้วยจำนวนที่ล้นออกจาก slot ของบอร์ด
    ///
    /// `+N more` เป็นแถวสุดท้ายเสมอ ถ้าอยู่ข้างบนมันจะอ่านเหมือนหัวข้อของแถวที่ตามมา
    public static func sessions(_ snapshot: Snapshot) -> [String] {
        guard !snapshot.sessions.isEmpty else { return ["No sessions"] }
        var rows = snapshot.sessions.map { "\($0.project) · \($0.state.rawValue)" }
        if snapshot.overflow > 0 { rows.append("+\(snapshot.overflow) more") }
        return rows
    }
}

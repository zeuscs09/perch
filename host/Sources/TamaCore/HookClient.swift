import Foundation

/// โหมด `--hook` — ต่อท้าย Claude Code hook ทุกตัว
///
/// กติกาข้อเดียวที่ห้ามพลาด: ต้องคืน 0 และจบเร็วเสมอ แม้ daemon ไม่ทำงาน
/// hook ที่พังหรือค้างจะไปทำให้ session ของผู้ใช้พังตาม ซึ่งแย่กว่าจอไม่ขยับมาก
public enum HookClient {
    /// เพดานอายุของกระบวนการ hook — ไม่ว่าจะค้างที่ไหน
    ///
    /// ไม่ใช่การกันบั๊กตัวใดตัวหนึ่ง แต่กัน *ทั้งชนิด*: ไฟล์นี้ถูกเรียกหลายพันครั้งต่อนาที
    /// อะไรก็ตามที่ค้างในนี้จะกลายเป็นกระบวนการที่ไม่มีวันตายและสะสมจนเครื่องหมดโควตา
    /// เกิดขึ้นมาแล้วสองครั้ง ทั้งสองครั้งเพราะจุดที่ตอนเขียนไม่คิดว่าจะค้างได้
    ///
    /// ตัวจับเวลาตัวนี้ไม่ต้องรู้ว่าอะไรค้าง — มันรับประกันแค่ว่าไม่มีอะไรค้างได้นานกว่านี้
    /// และ hook ที่ตายเงียบเสียหายน้อยกว่า hook ที่ค้างมาก (อย่างมากคือมาสคอตตกท่าไปหนึ่งท่า)
    private static let deadline: TimeInterval = 3

    public static func run(input: FileHandle = .standardInput) -> Int32 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
            exit(0)  // คืน 0 เสมอ — hook ที่คืนค่าผิดจะไปทำให้ session ของผู้ใช้พัง
        }
        guard let raw = try? input.readToEnd(), !raw.isEmpty else { return 0 }
        guard var event = try? JSONDecoder().decode(HookEvent.self, from: raw) else {
            Log.debug("hook input was not a recognised event")
            return 0
        }
        // ต้องหาที่นี่เท่านั้น: hook process ยังเป็นลูกของ Claude Code อยู่ตอนนี้
        // พอส่งเข้า socket แล้ว daemon อยู่คนละสายบรรพบุรุษ ไต่กลับไปไม่ได้อีก
        event.owner = ProcessTree.claudeAncestor()

        // ส่ง *รหัส pane ดิบ* ไปให้ daemon แปลเป็นชื่อ session เอง ไม่แปลที่นี่
        //
        // สิ่งเดียวที่หาได้เฉพาะที่นี่คือค่า `TMUX_PANE` ซึ่งเป็นตัวแปรสภาพแวดล้อม
        // ที่สืบทอดมาจาก Claude Code ในเพนนั้น — อ่านฟรี ไม่ต้อง fork อะไรเลย
        // ส่วนการแปล pane -> ชื่อ session ต้องเรียก `tmux` ซึ่งเป็นการ fork
        //
        // ไฟล์นี้ถูกเรียกทุกครั้งที่เอเจนต์ใช้เครื่องมือ คูณด้วยจำนวน session ที่เปิดอยู่
        // บนเครื่องที่รันหลายสิบทีมคือหลายพันครั้งต่อนาที การ fork ตรงนี้จึงไม่ใช่
        // "ต้นทุนเล็กน้อยต่อครั้ง" แต่เป็นภาระที่ใหญ่ที่สุดที่โปรแกรมนี้วางบนเครื่อง
        // และเคยทำให้เครื่องหมดโควตากระบวนการมาแล้วสองครั้ง
        //
        // daemon อยู่ยาวและแปลได้เหมือนกันเป๊ะ โดยจำผลไว้ใช้ซ้ำ — จากหลายพันครั้ง
        // ต่อนาที เหลือสองครั้งต่อนาที
        if event.tmux == nil { event.tmux = ProcessInfo.processInfo.environment["TMUX_PANE"] }
        guard let line = try? Wire.encoder().encode(event) else { return 0 }
        let ok = SocketClient(path: Paths.socket).send(line)
        if !ok { Log.debug("daemon not running, event dropped") }
        return 0
    }
}

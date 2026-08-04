import Foundation

/// ตัวเขียนไฟล์ session key — แอปเป็นคนเขียน ผู้ใช้แค่วางค่าลงช่องกรอก
///
/// เหตุผลที่ไม่ปล่อยให้ผู้ใช้ไปสร้างไฟล์เอง: สิทธิ์ของไฟล์เป็นส่วนหนึ่งของความปลอดภัย
/// ของ credential เต็มบัญชี คนที่ `echo … > file` แล้วลืม `chmod 600` จะได้ไฟล์ที่
/// ทุกคนบนเครื่องอ่านได้ แล้วเจอแค่ข้อความปฏิเสธที่เขาไม่ได้ตั้งใจให้เกิด
///
/// อ่านกลับมาทาง `UsagePoll.readKey` ตัวเดิมเสมอ — กฎว่าอะไรคือไฟล์ที่ใช้ได้มีสำเนาเดียว
public enum SessionKeyFile {
    /// เขียน key ทับของเดิมแบบ mode 600 ตั้งแต่วินาทีแรกที่ไฟล์มีตัวตน
    ///
    /// สร้างไฟล์ชั่วคราวด้วยสิทธิ์ 600 แล้วค่อย rename ทับ ไม่ใช่เขียนก่อนแล้ว `chmod`
    /// ทีหลัง — ช่วงระหว่างสองคำสั่งนั้นคือช่วงที่ credential เปิดให้คนอื่นอ่าน
    public static func write(_ raw: String, to url: URL = Paths.sessionKey) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw UsagePoll.Failure(
                message: "the session key is empty — paste the claude.ai sessionKey cookie",
                code: UsagePoll.Failure.unusableKeyFile)
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).perch.tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        else {
            throw UsagePoll.Failure(
                message: "could not write \(url.path)",
                code: UsagePoll.Failure.unusableKeyFile)
        }
        // `replaceItemAt` คัดลอกสิทธิ์ของไฟล์เดิมกลับมาได้ — ไฟล์ 644 ที่ผู้ใช้เคยสร้างเอง
        // จะยังเป็น 644 ต่อไปทั้งที่เพิ่งเขียนใหม่ จึงลบทิ้งแล้ว rename ตรงๆ แทน
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw UsagePoll.Failure(
                message: "could not write \(url.path)",
                code: UsagePoll.Failure.unusableKeyFile)
        }
    }

    /// มี key ที่ใช้ยิงได้จริงไหม — ไม่ใช่แค่ "ไฟล์มีอยู่"
    ///
    /// ผู้เรียกใช้ตัวนี้ตัดสินใจว่าจะ spawn ลูกไหม: ยิงทั้งที่รู้อยู่แล้วว่าไม่มี key คือ
    /// การเผาโปรเซสทุกนาทีเพื่อให้ได้ error เดิม
    public static func isUsable(at url: URL = Paths.sessionKey) -> Bool {
        (try? UsagePoll.readKey(at: url)) != nil
    }
}

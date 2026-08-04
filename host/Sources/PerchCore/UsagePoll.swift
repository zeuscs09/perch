import Foundation

/// ยิงโควตาจาก claude.ai หนึ่งรอบแล้วจบ — โปรเซสอายุสั้น ไม่ใช่ daemon
///
/// ตัวจับเวลาอยู่ฝั่ง menu bar โปรเซสที่ตายเองไม่ต้องมี supervision ไม่มี backoff
/// ไม่มี crash loop ไม่มีลูกกำพร้า และ credential อยู่ใน RAM แค่ช่วงยิง
///
/// **นี่คือจุดที่ credential เต็มบัญชีเดินทาง** — `sessionKey` ทำได้ทุกอย่างที่เจ้าของ
/// บัญชีทำได้ ไม่ใช่ key จำกัดสิทธิ์ จึงห้าม log request หรือ header ทุกกรณี เพราะ
/// cookie อยู่ในนั้น และห้ามให้ key ผ่าน argv (ทุกคนบนเครื่องเห็นด้วย `ps`) หรือ env
///
/// รายละเอียด endpoint, สอง shape ของ response และ error mapping อยู่ที่
/// `docs/claude-usage-api.md`
public enum UsagePoll {
    static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!

    /// ผลลัพธ์ที่ไม่สำเร็จ พร้อม exit code ที่ผู้เรียกแยกแยะได้
    ///
    /// ผู้เรียก (menu bar ในใบถัดไป) ต้องแยก "ผู้ใช้ต้องไปแปะ key ใหม่" ออกจาก
    /// "เน็ตสะดุด เดี๋ยวรอบหน้าก็หาย" ให้ได้โดยไม่ต้องอ่านข้อความ
    public struct Failure: Error {
        public let message: String
        public let code: Int32
        /// org ที่รู้แล้วก่อนจะล้ม — ผู้เรียกต้องได้รายการแม้รอบนี้จะไม่สำเร็จ ไม่งั้น
        /// การพินไว้ที่ org ที่หายไปจากบัญชีจะล็อกตัวเองไว้ตลอด: ยิงพลาดทุกรอบ
        /// และไม่เคยได้รายการมาให้เปลี่ยนใจ
        public var orgs: [Org] = []

        /// key ถูกปฏิเสธจากปลายทาง — หมดอายุแล้ว ต้องไปเอาอันใหม่จากเบราว์เซอร์
        public static let rejectedKey: Int32 = 2
        /// ไฟล์ key ใช้ไม่ได้ — ไม่มี ว่าง หรือคนอื่นอ่านได้
        public static let unusableKeyFile: Int32 = 3
    }

    /// อ่าน session key จากไฟล์ — ปฏิเสธไฟล์ที่คนอื่นบนเครื่องเปิดได้
    ///
    /// อ่านใหม่ทุกรอบ ไม่เก็บไว้ในหน่วยความจำ: key หมดอายุได้ และวิธีแก้ต้องเป็นแค่
    /// การ paste ทับไฟล์ ไม่ใช่การไล่หาโปรเซสมารีสตาร์ท
    public static func readKey(at url: URL) throws -> String {
        // ตรวจสิทธิ์ของไฟล์ปลายทาง ไม่ใช่ของ symlink — `attributesOfItem` ไม่ตาม link
        // และ symlink มีสิทธิ์ 0o755 เสมอ ผู้ใช้ที่ link ไฟล์ 600 มาไว้ตรงนี้จะโดนปฏิเสธ
        // พร้อมคำแนะนำ `chmod` ที่แก้อะไรไม่ได้เลย
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw Failure(
                message: "no session key at \(url.path) — "
                    + "set one from the Perch gear menu, or paste the claude.ai sessionKey "
                    + "cookie into that file and `chmod 600` it",
                code: Failure.unusableKeyFile)
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        else {
            throw Failure(
                message: "cannot read the permissions of \(url.path)",
                code: Failure.unusableKeyFile)
        }
        // 0o077 = สิทธิ์ของ group และ other ทั้งหมด — บิตใดติดก็แปลว่า credential
        // เต็มบัญชีนี้ไม่ได้เป็นของเจ้าของไฟล์คนเดียวแล้ว
        guard mode & 0o077 == 0 else {
            throw Failure(
                message: "\(url.path) is readable by other users; run `chmod 600 \(url.path)`",
                code: Failure.unusableKeyFile)
        }
        // อ่านไม่ออกกับว่างเปล่าเป็นคนละอาการ วิธีแก้จึงคนละอย่าง — ข้อความต้องแยกกัน
        guard let text = try? String(contentsOf: target, encoding: .utf8) else {
            throw Failure(
                message: "\(url.path) is not readable text", code: Failure.unusableKeyFile)
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw Failure(
                message: "\(url.path) is empty — "
                    + "paste the claude.ai sessionKey cookie into it",
                code: Failure.unusableKeyFile)
        }
        return key
    }

    /// org หนึ่งอันจาก `/organizations` — id ที่ validate แล้ว กับชื่อไว้โชว์ในเมนู
    public struct Org: Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// แกะ org ทั้งรายการจาก response ของ `/organizations`
    ///
    /// อันที่ id ใช้ไม่ได้ถูกทิ้งเงียบๆ ไม่ใช่ทำให้ทั้งรายการล้ม — org ที่แปลกอยู่อันเดียว
    /// ต้องไม่พาอันที่ใช้ได้ตกไปด้วย
    public static func organizations(from data: Data) -> [Org] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let entry = entry as? [String: Any],
                let id = try? validated((entry["uuid"] as? String) ?? (entry["id"] as? String) ?? "")
            else { return nil }
            let name = (entry["name"] as? String) ?? ""
            return Org(id: id, name: name.isEmpty ? id : name)
        }
    }

    /// org ที่จะยิงจริง: ตัวที่ผู้ใช้เลือกไว้ถ้ายังอยู่ในรายการ ไม่งั้นตัวแรก
    ///
    /// ตัวที่เลือกไว้แล้วหายไปจากบัญชีต้องไม่ทำให้ทั้งเรื่องหยุด — ตัวแรกใช้ได้เสมอ
    /// และเมนูจะแสดงติ๊กที่ตัวแรกเอง เพราะติ๊กอ่านจากค่าที่ยิงจริง
    public static func pick(_ orgs: [Org], preferred: String?) -> Org? {
        if let preferred, let match = orgs.first(where: { $0.id == preferred }) { return match }
        return orgs.first
    }

    /// org แรกจาก response ของ `/organizations`
    ///
    /// บัญชีปกติมี org เดียว ถ้ามีหลายอันก็เดาไม่ได้ว่าหมายถึงอันไหน ตัวแรกจึงเป็นแค่
    /// ค่าตั้งต้นที่ใช้ได้ทันที ส่วนการเลือกจริงอยู่ที่ผู้เรียกซึ่งมีรายการทั้งอันอยู่ในมือ
    public static func organizationID(from data: Data) throws -> String {
        guard let first = organizations(from: data).first else {
            throw Failure(message: "no organizations on this account", code: 1)
        }
        return first.id
    }

    /// ตรวจ org id ก่อนต่อเข้า URL เสมอ แม้จะมาจาก response ของเราเอง
    ///
    /// ค่าที่มี `/` หรือ `..` เปลี่ยน path ที่เรายิงได้ทั้งเส้น — ปลายทางเป็นของคนอื่น
    /// เราจึงถือว่าทุกอย่างที่กลับมาเป็นข้อมูลจากภายนอก ไม่ใช่ค่าที่เราเขียนเอง
    public static func validated(_ orgID: String) throws -> String {
        guard !orgID.isEmpty, !orgID.contains("/"), !orgID.contains("..") else {
            throw Failure(
                message: "organization id must not be empty or contain '/' or '..'", code: 1)
        }
        return orgID
    }

    static func usageURL(_ orgID: String) throws -> URL {
        let id = try validated(orgID)
        guard let url = URL(string: "https://claude.ai/api/organizations/\(id)/usage") else {
            throw Failure(message: "organization id does not form a usable URL", code: 1)
        }
        return url
    }

    /// GET หนึ่งครั้งพร้อม cookie — บางจนไม่มี logic ให้เทสต์ จึงไม่มีเทสต์โดยตั้งใจ
    ///
    /// ข้อความ error ทุกอันสร้างจาก status code หรือ URLError code เท่านั้น ไม่เคยพก
    /// request หรือ header ติดไปด้วย เพราะ cookie อยู่ในนั้น
    static func get(_ url: URL, key: String, timeout: TimeInterval = 20) throws -> Data {
        // session ของตัวเอง ไม่ใช่ `URLSession.shared` — shared ใช้ cookie storage กลาง
        // ที่เขียนลงดิสก์ `Set-Cookie` ที่ claude.ai ส่งกลับ (รวมถึง sessionKey ตัวใหม่)
        // จะไปนอนอยู่ใน ~/Library/Cookies แทนที่จะอยู่ในไฟล์ mode 600 ที่ทั้งดีไซน์นี้
        // สร้างขึ้นมาเพื่อคุมมัน — credential ต้องอยู่ใน RAM แค่ช่วงยิงเท่านั้น
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("perch", forHTTPHeaderField: "User-Agent")

        var body: Data?
        var status = 0
        var transport: URLError?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            transport = error as? URLError
            done.signal()
        }.resume()
        // โปรเซสนี้ไม่มี run loop ให้รอ — บล็อกตรงนี้แล้วจบ คือทั้งชีวิตของมัน
        done.wait()

        if let transport {
            throw Failure(message: "cannot reach claude.ai (\(transport.code.rawValue))", code: 1)
        }
        if status == 401 || status == 403 {
            throw Failure(
                message: "claude.ai rejected the session key (HTTP \(status)); "
                    + "it has most likely expired — set a fresh one from the gear menu",
                code: Failure.rejectedKey)
        }
        guard (200..<300).contains(status), let body else {
            throw Failure(message: "claude.ai returned HTTP \(status)", code: 1)
        }
        return body
    }

    /// ผลของการยิงหนึ่งรอบ — บรรทัดสรุป กับรายการ org ที่เจอระหว่างทาง
    ///
    /// รายการ org เดินทางกลับไปหาผู้เรียกทาง stdout เหมือนบรรทัดสรุป ไม่ใช่ไฟล์สถานะ
    /// ตัวที่สอง: โปรเซสนี้ตายทุกรอบ อะไรที่มันรู้จึงต้องพูดออกมาตอนยังมีชีวิตอยู่
    public struct Report {
        public let orgs: [Org]
        public let summary: String

        public init(orgs: [Org], summary: String) {
            self.orgs = orgs
            self.summary = summary
        }
    }

    /// ยิงหนึ่งรอบ: อ่าน key -> หา org -> ยิง -> เขียน cache -> คืนบรรทัดสรุป
    ///
    /// ล้มเหลวแบบไหนก็ไม่แตะ cache เดิม: ค่าที่ค้างอยู่ยังจริงกว่าการไม่มีค่าเลย
    /// และผู้บริโภคตัดสินเองได้ว่าเก่าเกินไปหรือยัง จาก `TIMESTAMP`
    public static func run(
        keyFile: URL = Paths.sessionKey,
        cache: URL = Paths.usageCache,
        orgOverride: String? = ProcessInfo.processInfo.environment["PERCH_ORG_ID"],
        now: Date = Date()
    ) throws -> Report {
        // ถามรายการ org ทุกรอบแม้จะถูกพินไว้แล้ว: เมนูของผู้เรียกต้องมีรายการให้เลือก
        // และเรามีคำตอบก็ต่อเมื่อถาม — ราคาคือหนึ่งคำขอต่อรอบ ซึ่งถูกกว่าเมนูที่ว่างเปล่า
        // จนกว่าจะบังเอิญยิงสำเร็จสักครั้ง
        var orgs: [Org] = []
        do {
            let orgID: String
            if let orgOverride, !orgOverride.isEmpty {
                // พินคือพิน — ค่าที่กำหนดมาจากภายนอกต้องไม่ถูกแทนเงียบๆ ด้วยตัวแรก
                // ไม่งั้นผู้ใช้ที่ตั้ง env ไว้จะได้ตัวเลขของ org อื่นโดยไม่มีอะไรบอก
                // การถอยไปตัวแรกเป็นการตัดสินใจของผู้เรียก ซึ่งเห็นรายการทั้งอัน
                orgID = try validated(orgOverride)
                orgs = (try? organizations(from: get(organizationsURL, key: readKey(at: keyFile))))
                    ?? []
            } else {
                orgs = organizations(from: try get(organizationsURL, key: readKey(at: keyFile)))
                guard let first = orgs.first else {
                    throw Failure(message: "no organizations on this account", code: 1)
                }
                orgID = first.id
            }
            let payload = try get(usageURL(orgID), key: readKey(at: keyFile))
            guard let line = UsageWriter.ingestAPI(payload, now: now, to: cache) else {
                throw Failure(
                    message: "no window we recognise in the usage payload; "
                        + "a field was probably renamed — see docs/claude-usage-api.md",
                    code: 1)
            }
            return Report(orgs: orgs, summary: line)
        } catch var failure as Failure {
            failure.orgs = orgs
            throw failure
        }
    }
}

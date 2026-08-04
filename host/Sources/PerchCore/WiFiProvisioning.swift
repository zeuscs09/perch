import Foundation

/// สิ่งที่วิ่งบนสองท่อของ GATT ตอนตั้งค่า WiFi ให้บอร์ด
///
/// คำสั่งออกทาง config characteristic (`...0003`) ซึ่ง firmware บังคับให้ลิงก์เข้ารหัสก่อน
/// เพราะรหัส WiFi ของผู้ใช้เดินผ่านตรงนี้ · รายงานกลับมาทาง event characteristic
/// (`...0004`) เป็น JSON บรรทัดเดียวต่อหนึ่ง notification
///
/// **บอร์ดไม่เคยได้ `sessionKey`** — WiFi มีไว้ให้บอร์ดคุยกับ Mac ผ่าน LAN เมื่อ BLE
/// ไกลเกินไป ไม่ใช่ให้บอร์ดยิง claude.ai เอง (DESIGN.md)
public enum WiFiCommand: Equatable, Sendable {
    /// สแกนแล้วรายงานผลกลับมาทีละตัว
    case scan
    /// จำเครือข่ายแล้วต่อทันที — `psk` ว่างคือเครือข่ายเปิด
    case join(ssid: String, psk: String)
    case forget(ssid: String)
    /// ขอสถานะปัจจุบันซ้ำ — ใช้ตอนเพิ่งเปิดหน้าตั้งค่า
    case status
    /// กุญแจของทาง LAN เป็น hex 64 ตัว — บอร์ดล้างตัวนับกันเล่นซ้ำทิ้งเมื่อได้รับ
    /// เดินทางช่องเดียวกับรหัส WiFi ด้วยเหตุผลเดียวกัน: ช่องนี้บังคับเข้ารหัส
    case key(hex: String)

    public var payload: Data {
        var object: [String: String]
        switch self {
        case .scan: object = ["c": "scan"]
        case .status: object = ["c": "status"]
        case .join(let ssid, let psk): object = ["c": "join", "ssid": ssid, "psk": psk]
        case .forget(let ssid): object = ["c": "forget", "ssid": ssid]
        case .key(let hex): object = ["c": "key", "k": hex]
        }
        // sortedKeys เหมือนที่ snapshot ใช้ — คำสั่งเดิมต้องได้ไบต์เดิมเสมอ ไม่งั้นเทสต์
        // เทียบผลลัพธ์ไม่ได้ และการดีบักด้วยสายตาจะขึ้นกับลำดับที่ Foundation เลือกวันนั้น
        return (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// เครือข่ายหนึ่งวงที่บอร์ด (ไม่ใช่ Mac) มองเห็น
///
/// รายการนี้มาจากวิทยุของบอร์ดโดยตั้งใจ: ESP32 รับได้แค่ 2.4GHz และตั้งอยู่คนละที่กับ
/// Mac — รายการของ Mac จะมีวงที่บอร์ดเข้าไม่ได้ปนมา ซึ่งผู้ใช้จะรู้ก็ต่อเมื่อกดต่อแล้วล้ม
public struct AccessPoint: Equatable, Sendable {
    public let ssid: String
    public let rssi: Int
    public let secured: Bool

    public init(ssid: String, rssi: Int, secured: Bool) {
        self.ssid = ssid
        self.rssi = rssi
        self.secured = secured
    }
}

/// สถานะ WiFi ของบอร์ด พร้อมรายชื่อที่มันจำไว้
///
/// รายชื่อที่จำไว้เดินทางมากับสถานะเสมอ ไม่ใช่ข้อความแยก — หน้าตั้งค่าต้องการทั้งคู่พร้อมกัน
/// และสองข้อความที่มาไม่พร้อมกันแปลว่ามีจังหวะที่หน้าจอแสดงของครึ่งเดียว
public struct WiFiStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case off, connecting, connected, failed
    }

    public let state: State
    public let ssid: String
    public let ip: String
    /// เหตุผลที่รอบล่าสุดล้ม — แยก "รหัสผิด" (ผู้ใช้ต้องพิมพ์ใหม่) ออกจาก "ไม่เจอ" (รอ)
    public let error: String?
    public let saved: [String]
    /// ลายนิ้วมือกุญแจ LAN ที่บอร์ดถืออยู่ (8 hex) — ว่างคือยังไม่เคยตั้ง
    ///
    /// มีไว้ตอบคำถามเดียว: กุญแจสองฝั่งตรงกันไหม ถ้าไม่ตรง เฟรมบน LAN จะถูกทิ้งทุกก้อน
    /// โดยไม่มีอาการอื่นให้เห็นเลยนอกจากจอที่ค้าง
    public let keyFingerprint: String

    public init(state: State, ssid: String, ip: String, error: String?, saved: [String],
                keyFingerprint: String = "") {
        self.state = state
        self.ssid = ssid
        self.ip = ip
        self.error = error
        self.saved = saved
        self.keyFingerprint = keyFingerprint
    }
}

/// สิ่งที่บอร์ดแจ้งกลับมาทาง event characteristic
public enum BoardEvent: Equatable, Sendable {
    case accessPoint(AccessPoint)
    /// จบรายการสแกน — ไม่มีตัวนับ ไม่มีหมายเลขชิ้น มีแค่เครื่องหมายจบ
    case scanFinished
    case wifi(WiFiStatus)

    /// คืน nil เมื่อไม่ใช่ข้อความที่เรารู้จัก — firmware รุ่นใหม่กว่าต้องไม่ทำให้แอปพัง
    public static func decode(_ data: Data) -> BoardEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["t"] as? String
        else { return nil }

        switch kind {
        case "ap":
            guard let ssid = object["s"] as? String, !ssid.isEmpty else { return nil }
            let rssi = (object["r"] as? NSNumber)?.intValue ?? 0
            let secured = ((object["e"] as? NSNumber)?.intValue ?? 1) != 0
            return .accessPoint(AccessPoint(ssid: ssid, rssi: rssi, secured: secured))

        case "ap_end":
            return .scanFinished

        case "wifi":
            let state = WiFiStatus.State(rawValue: object["st"] as? String ?? "") ?? .off
            let error = (object["er"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .wifi(
                WiFiStatus(
                    state: state,
                    ssid: object["s"] as? String ?? "",
                    ip: object["ip"] as? String ?? "",
                    error: error,
                    saved: object["nets"] as? [String] ?? [],
                    keyFingerprint: object["kf"] as? String ?? ""))

        default:
            return nil
        }
    }
}

/// รายการที่หน้าตั้งค่าเอาไปวาด — ผลสแกนผสมกับสิ่งที่บอร์ดจำไว้
///
/// เก็บสถานะการสแกนไว้ที่เดียว ไม่ใช่กระจายอยู่ในตัว view: บอร์ดส่งผลมาทีละใบและ
/// อาจไม่ส่ง `ap_end` เลยถ้าหลุดกลางคัน หน้าตั้งค่าจึงต้องมีที่ให้ถามว่า "ตอนนี้รู้อะไรแล้ว"
public struct NetworkList: Equatable, Sendable {
    public private(set) var scanning = false
    public private(set) var found: [AccessPoint] = []
    public private(set) var saved: [String] = []

    public init() {}

    public mutating func beginScan() {
        scanning = true
        found = []
    }

    public mutating func apply(_ event: BoardEvent) {
        switch event {
        case .accessPoint(let ap):
            // AP เดียวกันตอบสองครั้งได้ตอนสแกนซ้อนรอบ — เก็บใบที่แรงกว่าไว้ใบเดียว
            if let i = found.firstIndex(where: { $0.ssid == ap.ssid }) {
                if ap.rssi > found[i].rssi { found[i] = ap }
            } else {
                found.append(ap)
            }
            found.sort { $0.rssi > $1.rssi }
        case .scanFinished:
            scanning = false
        case .wifi(let status):
            saved = status.saved
        }
    }

    /// ล้างสถานะกำลังสแกนเมื่อลิงก์ BLE หลุด — สปินเนอร์ที่หมุนค้างคือคำโกหก
    public mutating func linkLost() {
        scanning = false
    }
}

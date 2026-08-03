import Foundation

/// ทางที่ snapshot กำลังเดินอยู่จริง
public enum LanRoute: String, Equatable, Sendable {
    case ble, lan, none
}

/// เมื่อไรถึงจะเปิดทาง LAN — ตรรกะล้วน ไม่มีซ็อกเก็ต ไม่มีนาฬิกาของตัวเอง
///
/// รอ 10 วินาทีก่อนเสมอ ไม่ใช่สลับทันทีที่ BLE หลุด: การหลุดสั้นๆ เกิดเป็นปกติ (เดินผ่าน
/// ตัวเครื่อง ไมโครเวฟ Mac หลับครึ่งหนึ่ง) และ CoreBluetooth ต่อกลับได้เองในไม่กี่วินาที
/// การกระโดดไป LAN ทุกครั้งแปลว่าเปิด/ปิดซ็อกเก็ตทั้งวันเพื่อสิ่งที่หายเองอยู่แล้ว
///
/// นาฬิกาถูกป้อนเข้ามา (`now`) ไม่ได้อ่านเอง — สถานะที่ขึ้นกับเวลาต้องทดสอบได้โดยไม่ต้องรอ
public struct FailoverPolicy: Equatable, Sendable {
    public let grace: TimeInterval
    /// หลุดกี่ครั้งภายใน `flapWindow` ถึงจะถือว่าลิงก์ "ไม่นิ่ง"
    public let flapCount: Int
    public let flapWindow: TimeInterval
    /// ต่อติดต่อเนื่องนานเท่านี้ = กลับมานิ่งแล้ว เลิกอุ้ม LAN ไว้
    public let steady: TimeInterval

    private var bleLostAt: Date?
    private var bleUpSince: Date?
    private var drops: [Date] = []
    /// ลิงก์อยู่ในสภาพหลุดๆ ติดๆ — ทาง LAN ต้องเปิดค้างไว้แม้ตอน BLE กลับมา
    public private(set) var unstable = false
    /// ทาง LAN ควรเปิดอยู่ไหม — คนละคำถามกับ "ต่อติดหรือยัง"
    public private(set) var wantsLan = false
    public private(set) var route: LanRoute = .none

    /// `since` คือจุดที่เริ่มนับว่า BLE ยังไม่มา — ตอนแอปเพิ่งเปิดคือ "เดี๋ยวนี้" ไม่ใช่ nil
    /// ไม่งั้น Mac ที่ตื่นมาไกลจากบอร์ดจะรอ BLE ที่ไม่มีวันมาโดยไม่เคยลองทาง LAN เลย
    public init(grace: TimeInterval = 10, flapCount: Int = 3, flapWindow: TimeInterval = 180,
                steady: TimeInterval = 300, since: Date) {
        self.grace = grace
        self.flapCount = flapCount
        self.flapWindow = flapWindow
        self.steady = steady
        self.bleLostAt = since
    }

    public mutating func update(ble: Bool, lan: Bool, now: Date) {
        // คัดลอกออกมาก่อนกรอง — `removeAll(where:)` อ่านและเขียน `drops` พร้อมกัน
        // ซึ่ง Swift ถือว่าเป็นการเข้าถึงซ้อนกันในเมธอด mutating
        let window = flapWindow
        drops = drops.filter { now.timeIntervalSince($0) <= window }

        if ble {
            if bleUpSince == nil { bleUpSince = now }
            // ต่อติดยาวพอแล้ว = สภาพเปลี่ยนจริง ไม่ใช่ช่วงว่างระหว่างการหลุดสองครั้ง
            if unstable, let up = bleUpSince, now.timeIntervalSince(up) >= steady {
                unstable = false
                drops.removeAll()
            }
            bleLostAt = nil
            // **ตรงนี้คือจุดที่เคยผิด**: เดิมสั่ง `wantsLan = false` ทุกครั้งที่ BLE กลับมา
            // ทาง LAN จึงถูกปิดทันทีและตัวนับเวลาเริ่มใหม่จากศูนย์ — บอร์ดที่อยู่สุดระยะ
            // หลุดแล้วต่อกลับเร็วกว่า `grace` ทำให้เงื่อนไขเปิด LAN ไม่มีวันเป็นจริงเลย
            // เครื่องเลยแกว่งระหว่าง ble กับ none ตลอด ทั้งที่ WiFi ต่ออยู่และใช้ได้
            // (วัดจากเครื่องจริง: connected 24 ครั้ง / disconnected 19 ครั้ง)
            //
            // ลิงก์ที่หลุดถี่ไม่ใช่ลิงก์ที่ใช้ได้ การอุ้มทางสำรองไว้จึงถูกกว่าการเปิดปิดตาม
            wantsLan = unstable
            route = .ble
            return
        }

        bleUpSince = nil
        if bleLostAt == nil {
            bleLostAt = now
            drops.append(now)
            if drops.count >= flapCount { unstable = true }
        }
        wantsLan = unstable || now.timeIntervalSince(bleLostAt ?? now) >= grace
        route = lan ? .lan : .none
    }
}

/// BLE เป็นทางหลัก LAN เป็นทางสำรอง — daemon เห็นเป็นทางออกเดียว
///
/// `Daemon` ส่ง snapshot ให้ transport ที่ `isConnected` เท่านั้น และเทียบกับก้อนที่ส่งไป
/// ล่าสุดเพื่อไม่ให้ยิงซ้ำ การสลับทางจึงต้องปลุก `onConnect` ด้วย ไม่งั้นบอร์ดที่เพิ่งรับสาย
/// ใหม่จะรอ snapshot ก้อนถัดไปที่ *เนื้อหาเปลี่ยน* ซึ่งอาจเป็นอีกหลายนาที
public final class FailoverTransport: Transport {
    public let name = "failover"
    public var onConnect: (() -> Void)?
    /// ทางเปลี่ยน — เมนูบาร์กับหน้าตั้งค่าเอาไปบอกผู้ใช้ว่าตอนนี้คุยกันทางไหน
    public var onRouteChanged: ((LanRoute) -> Void)?

    public var isConnected: Bool { ble.isConnected || lan.isConnected }
    public private(set) var route: LanRoute = .none

    private let ble: Transport
    private let lan: LanTransport
    private var policy: FailoverPolicy

    public init(ble: Transport, lan: LanTransport, grace: TimeInterval = 10,
                now: Date = Date()) {
        self.ble = ble
        self.lan = lan
        self.policy = FailoverPolicy(grace: grace, since: now)
    }

    public func start() {
        // ลูกทั้งสองแจ้งการต่อติดของตัวเองขึ้นมาตรงๆ ไม่ผ่านการเทียบ route: การต่อกลับ
        // ที่เกิดและจบภายในหนึ่ง tick จะไม่ปรากฏใน route เลย แต่บอร์ดปลายทางลืมทุกอย่าง
        // ไปแล้วจริงๆ
        ble.onConnect = { [weak self] in self?.onConnect?() }
        lan.onConnect = { [weak self] in self?.onConnect?() }
        ble.start()
    }

    public func tick(now: Date) {
        policy.update(ble: ble.isConnected, lan: lan.isConnected, now: now)
        if policy.wantsLan { lan.start() } else { lan.stop() }
        guard policy.route != route else { return }
        route = policy.route
        Log.info("snapshot route is now \(route.rawValue)")
        onRouteChanged?(route)
        onConnect?()
    }

    /// BLE ชนะเสมอเมื่อทั้งคู่ต่ออยู่ — มันคือทางที่บอร์ดตอบกลับได้ด้วย
    public func send(_ payload: Data) {
        if ble.isConnected {
            ble.send(payload)
        } else if lan.isConnected {
            lan.send(payload)
        }
    }
}

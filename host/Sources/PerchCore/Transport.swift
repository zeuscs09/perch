import Foundation

/// ทางออกของ snapshot — v1 มี BLE เป็นตัวจริง และ stdout ไว้ใช้ตอนพัฒนา
/// แยกเป็น protocol ตั้งแต่ต้นเพราะข้อตกลงว่าจะเติม WiFi ทีหลังได้ (DESIGN.md)
public protocol Transport: AnyObject {
    var name: String { get }
    var isConnected: Bool { get }
    /// เรียกเมื่อเพิ่งต่อติด — daemon ใช้บังคับส่ง snapshot ซ้ำหลัง reconnect
    var onConnect: (() -> Void)? { get set }
    func start()
    func send(_ payload: Data)
    /// นาฬิกาของ daemon เดินผ่านมาหนึ่งครั้ง — transport ที่ต้องตัดสินใจตามเวลา
    /// (เช่น การสลับไป LAN เมื่อ BLE หายไปนานพอ) ทำตรงนี้ ไม่ใช่มี timer ของตัวเอง
    func tick(now: Date)
}

extension Transport {
    public func tick(now: Date) {}
}

/// พิมพ์ snapshot ออก stdout — ใช้ตรวจ pipeline ตั้งแต่ยังไม่มีบอร์ด
public final class PrintTransport: Transport {
    public let name = "stdout"
    public var isConnected: Bool { true }
    public var onConnect: (() -> Void)?

    public init() {}

    public func start() {
        onConnect?()
    }

    public func send(_ payload: Data) {
        FileHandle.standardOutput.write(payload)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

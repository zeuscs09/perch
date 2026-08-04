import CoreBluetooth
import Foundation

/// UUID ของ GATT — firmware ต้องใช้ชุดเดียวกันนี้
public enum GATT {
    public static let service = CBUUID(string: "7A9B0001-4C1E-4B6D-9E2A-1D5C3F0A0001")
    /// daemon เขียน snapshot ลงตัวนี้
    public static let state = CBUUID(string: "7A9B0002-4C1E-4B6D-9E2A-1D5C3F0A0002")
    /// ความสว่าง + คำสั่ง WiFi — firmware บังคับให้ลิงก์เข้ารหัสก่อนถึงจะเขียนได้
    public static let config = CBUUID(string: "7A9B0003-4C1E-4B6D-9E2A-1D5C3F0A0003")
    /// บอร์ดแจ้งกลับ — ผลสแกน WiFi และสถานะการต่อ (`BoardEvent`)
    public static let event = CBUUID(string: "7A9B0004-4C1E-4B6D-9E2A-1D5C3F0A0004")

    /// ชื่อที่บอร์ดโฆษณา ใช้เป็นตัวกรองสำรองเมื่อ advertisement ไม่ประกาศ service
    public static let deviceName = "perch"
}

/// บอร์ดหนึ่งตัวที่สแกนเจอ
public struct Board: Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// ตัวที่กำลังคุยอยู่จริงตอนนี้
    public var isCurrent: Bool
}

/// ฝั่ง Mac เป็น central — บอร์ดเป็น peripheral
///
/// สแกนใหม่เองทุกครั้งที่หลุด ไม่มีการหยุดถาวร: จอต้องกลับมาเองโดยผู้ใช้ไม่ต้องทำอะไร
///
/// การเลือกบอร์ดต้องอยู่ในแอปนี้ ไม่ใช่หน้า Bluetooth ของ macOS — peripheral ที่เป็น
/// GATT ล้วน (ไม่ใช่ HID/audio) ไม่โผล่ให้จับคู่ที่นั่นเลย ระบบปฏิบัติการเปิดทางให้
/// เฉพาะแอปที่สแกนเองผ่าน CoreBluetooth
public final class BLETransport: NSObject, Transport {
    public let name = "ble"
    public var onConnect: (() -> Void)?
    /// รายชื่อบอร์ดที่เห็นตอนนี้เปลี่ยน — เมนูบาร์ใช้วาดรายการให้เลือก
    public var onBoardsChanged: (([Board]) -> Void)?
    /// บอร์ดแจ้งอะไรกลับมาทาง event characteristic (ผลสแกน WiFi, สถานะการต่อ)
    public var onEvent: ((BoardEvent) -> Void)?
    /// ลิงก์ต่อติด/หลุด — หน้าตั้งค่าต้องหยุดสปินเนอร์เองเมื่อบอร์ดหายไปกลางสแกน
    public var onLinkChanged: ((Bool) -> Void)?

    public private(set) var isConnected = false

    // ไม่ใช่ IUO: เมนูบาร์ตั้งค่า preferredBoard (จาก UserDefaults) ก่อนเรียก start()
    // เสมอ ช่วงนั้น central ยังไม่มีตัวตน การ unwrap อัตโนมัติจึงเป็น crash
    // ที่เกิดทุกครั้งที่ผู้ใช้เคยเลือกบอร์ดไว้ — สถานะนี้ต้องเป็น no-op ไม่ใช่ตาย
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stateChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private let queue = DispatchQueue(label: "perch.ble")
    /// snapshot ล่าสุด เก็บไว้ยิงซ้ำทันทีที่ต่อติด
    private var pending: Data?
    private var writeLimit = Wire.maxPayload

    /// บอร์ดที่เห็นระหว่างสแกน (id -> ชื่อ)
    private var seen: [UUID: (peripheral: CBPeripheral, name: String)] = [:]
    private var preferred: UUID?

    public override init() {
        super.init()
    }

    /// บอร์ดที่ผู้ใช้เลือกไว้ — nil = ต่อตัวไหนก็ได้ที่เจอก่อน (ถูกต้องเมื่อมีจอเดียว)
    public var preferredBoard: UUID? {
        get {
            queue.sync { preferred }
        }
        set {
            queue.async { [weak self] in
                guard let self else { return }
                self.preferred = newValue
                // กำลังคุยกับตัวอื่นอยู่ก็ตัดแล้วไปหาตัวที่ถูกเลือก
                if let p = self.peripheral, let want = newValue, p.identifier != want {
                    self.central?.cancelPeripheralConnection(p)
                } else if self.peripheral == nil {
                    self.scan()
                }
            }
        }
    }

    public var boards: [Board] {
        queue.sync { boardList() }
    }

    private func boardList() -> [Board] {
        let current = peripheral?.identifier
        return seen
            .map { Board(id: $0.key, name: $0.value.name, isCurrent: $0.key == current) }
            .sorted { $0.name < $1.name }
    }

    private func publishBoards() {
        let list = boardList()
        onBoardsChanged?(list)
    }

    public func start() {
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = payload
            self.flush()
        }
    }

    /// เขียนคอนฟิกลงบอร์ด (ความสว่าง ฯลฯ) — เมนูบาร์จะเรียกทางนี้
    public func sendConfig(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, let p = self.peripheral, let c = self.configChar else { return }
            p.writeValue(payload, for: c, type: .withResponse)
        }
    }

    private func flush() {
        guard let data = pending, let p = peripheral, let c = stateChar else { return }
        guard data.count <= writeLimit else {
            Log.info("snapshot \(data.count)B exceeds negotiated write limit \(writeLimit)B, dropped")
            pending = nil
            return
        }
        p.writeValue(data, for: c, type: .withResponse)
        pending = nil
    }

    private func scan() {
        // ยังไม่ start = ยังไม่มีอะไรให้สแกน ค่าที่ตั้งไว้จะถูกใช้ตอน central พร้อม
        guard let central, central.state == .poweredOn else { return }
        isConnected = false
        stateChar = nil
        configChar = nil
        // ค้นต่อไปเรื่อยๆ แม้จะต่อได้แล้ว เพื่อให้เมนูมีรายชื่อบอร์ดตัวอื่นให้สลับไปหา
        central.scanForPeripherals(withServices: [GATT.service], options: nil)
        Log.debug("scanning for \(GATT.service)")
    }
}

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.debug("bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            scan()
        case .unauthorized:
            Log.info("bluetooth permission denied — grant it in System Settings > Privacy")
        case .poweredOff:
            Log.info("bluetooth is off")
            forgetPeripheral()
        default:
            forgetPeripheral()
        }
    }

    /// วิทยุดับ = CoreBluetooth ทิ้ง CBPeripheral ทุกตัวโดย *ไม่* เรียก
    /// didDisconnectPeripheral ให้ ตัวที่ค้างอยู่จึงไม่มีวันถูกล้าง และ didDiscover ที่กัน
    /// "ต่ออยู่แล้ว" ด้วย `peripheral == nil` จะไม่ยอมต่อกลับอีกเลยหลังเปิด Bluetooth คืน
    /// — อาการคือบอร์ดค้างอยู่บนทาง LAN จนกว่าจะรีสตาร์ทแอป
    private func forgetPeripheral() {
        isConnected = false
        peripheral = nil
        stateChar = nil
        configChar = nil
        // CBPeripheral ที่เก็บไว้ก็ใช้ไม่ได้แล้วเช่นกัน รายชื่อจะถูกเติมใหม่ตอนสแกนรอบหน้า
        seen.removeAll()
        publishBoards()
        onLinkChanged?(false)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let label = peripheral.name ?? advertised ?? "board \(peripheral.identifier.uuidString.prefix(4))"
        let isNew = seen[peripheral.identifier] == nil || seen[peripheral.identifier]?.name != label
        seen[peripheral.identifier] = (peripheral, label)
        if isNew { publishBoards() }

        // ต่ออยู่แล้ว = แค่เก็บรายชื่อไว้ให้เมนู ไม่ต้องกระโดดไปตัวใหม่
        guard self.peripheral == nil else { return }
        // ผู้ใช้เลือกตัวไหนไว้ก็รอตัวนั้น ไม่งั้นตัวแรกที่เจอ (ถูกต้องเมื่อมีจอเดียว)
        if let want = preferred, peripheral.identifier != want { return }

        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        Log.debug("connecting to \(label) \(peripheral.identifier)")
    }

    public func centralManager(
        _ central: CBCentralManager, didConnect peripheral: CBPeripheral
    ) {
        writeLimit = min(
            Wire.maxPayload, peripheral.maximumWriteValueLength(for: .withResponse))
        peripheral.discoverServices([GATT.service])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        self.peripheral = nil
        scan()
        publishBoards()
        onLinkChanged?(false)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Log.info("board disconnected, rescanning")
        self.peripheral = nil
        scan()
        publishBoards()
        onLinkChanged?(false)
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == GATT.service })
        else {
            scan()
            return
        }
        peripheral.discoverCharacteristics([GATT.state, GATT.config, GATT.event], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case GATT.state: stateChar = c
            case GATT.config: configChar = c
            case GATT.event: peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        guard stateChar != nil else {
            Log.info("board is missing the state characteristic")
            return
        }
        isConnected = true
        writeLimit = min(
            Wire.maxPayload, peripheral.maximumWriteValueLength(for: .withResponse))
        Log.info("board connected (write limit \(writeLimit)B)")
        publishBoards()
        // ส่ง snapshot ปัจจุบันซ้ำทันที — บอร์ดไม่จำอะไรข้ามการเชื่อมต่อ
        onLinkChanged?(true)
        onConnect?()
        flush()
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == GATT.event, let data = characteristic.value else { return }
        guard let event = BoardEvent.decode(data) else {
            // firmware ใหม่กว่าแอปพูดอะไรที่เรายังไม่รู้จัก — ข้ามไป ไม่ใช่ล้ม
            Log.debug("unknown board event (\(data.count)B)")
            return
        }
        onEvent?(event)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            Log.info("write failed: \(error.localizedDescription)")
        }
        flush()  // มี snapshot ใหม่คิวอยู่ก็ส่งต่อเลย
    }
}

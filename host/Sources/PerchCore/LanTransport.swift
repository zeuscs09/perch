import Foundation
import Network

/// ทางเดินที่สองของ snapshot — TCP ไปหาบอร์ดบน LAN เดียวกัน
///
/// เปิดต่อเมื่อถูกสั่งเท่านั้น (`start`) ไม่ใช่ค้างไว้ตลอด: ตราบใดที่ BLE ยังดี ทางนี้ไม่มี
/// ประโยชน์เลย และซ็อกเก็ตที่อุ่นอยู่เฉยๆ ก็ยังเป็นซ็อกเก็ตที่บอร์ดต้องเฝ้า ตัวตัดสินว่า
/// เมื่อไรคือ `FailoverTransport`
///
/// หาบอร์ดสามทาง เรียงตามความแน่นอน: ที่อยู่ที่ผู้ใช้กรอกเอง → mDNS → IP ล่าสุดที่บอร์ด
/// รายงานมาทาง BLE · ทางที่สามมีไว้เพราะ mDNS เป็นสิ่งแรกที่เราเตอร์รุ่นประหยัดปิดทิ้ง
public final class LanTransport: Transport {
    public let name = "lan"
    public var onConnect: (() -> Void)?
    /// บอกว่าตอนนี้ทำอะไรอยู่ — หน้าตั้งค่าเอาไปเขียนให้ผู้ใช้อ่าน
    public var onStatus: ((String) -> Void)?

    public private(set) var isConnected = false

    private let queue = DispatchQueue(label: "perch.lan")
    private var running = false
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var discovered: NWEndpoint?
    private var sealer: LanSealer?
    private var pending: Data?
    private var retry: DispatchWorkItem?
    private var backoff: TimeInterval = 2

    private var manual: String?
    private var lastKnown: String?

    public init() {}

    /// ที่อยู่ที่ผู้ใช้กรอกเองในหน้าตั้งค่า — ว่างคือให้หาเอง
    public func setManualHost(_ host: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let cleaned = host?.trimmingCharacters(in: .whitespaces)
            let value = (cleaned?.isEmpty ?? true) ? nil : cleaned
            guard value != self.manual else { return }
            self.manual = value
            // ที่อยู่เปลี่ยนแปลว่าปลายทางเปลี่ยน สายที่เปิดค้างอยู่ไปผิดที่แล้ว
            if self.running { self.reconnect(after: 0) }
        }
    }

    /// IP ที่บอร์ดเพิ่งรายงานมาทาง BLE — ทางสำรองสุดท้ายเมื่อ mDNS ไม่ผ่านเราเตอร์
    public func noteBoardAddress(_ ip: String?) {
        queue.async { [weak self] in
            let value = (ip?.isEmpty ?? true) ? nil : ip
            self?.lastKnown = value
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            Log.info("lan: looking for the board")
            self.startBrowsing()
            self.attempt()
        }
    }

    /// BLE กลับมาแล้ว — ปล่อยสายทิ้งทั้งหมด ทางหลักกลับมาทำงานแทน
    public func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.retry?.cancel()
            self.retry = nil
            self.browser?.cancel()
            self.browser = nil
            self.teardown()
        }
    }

    public func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = payload
            self.flush()
        }
    }

    // --- การค้นหา ------------------------------------------------------------
    private func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: LanWire.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async {
                guard let self else { return }
                // บอร์ดตัวแรกที่เจอ — ผู้ใช้ที่มีสองตัวบน LAN เดียวกันต้องกรอกที่อยู่เอง
                // (เลือกจากหน้าตั้งค่าไม่ได้ เพราะตอนที่ทางนี้ทำงาน BLE ตายไปแล้ว
                // แอปจึงไม่มีทางรู้ว่าชื่อ mDNS ตัวไหนคือบอร์ดที่เขาเลือกไว้)
                let found = results.first?.endpoint
                guard found != self.discovered else { return }
                self.discovered = found
                if self.connection == nil { self.reconnect(after: 0) }
            }
        }
        browser.stateUpdateHandler = { state in
            // macOS 15 ขึ้นไปขออนุญาต Local Network ก่อน — ถูกปฏิเสธแล้ว browser ตาย
            // เงียบๆ ตรงนี้ ไม่ใช่ตอน connect ข้อความจึงต้องออกจากที่นี่
            if case .failed(let error) = state {
                Log.info("lan: bonjour browse failed (\(error))")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func endpoint() -> NWEndpoint? {
        if let manual {
            return .hostPort(host: NWEndpoint.Host(manual), port: .init(rawValue: LanWire.port)!)
        }
        if let discovered { return discovered }
        if let lastKnown {
            return .hostPort(
                host: NWEndpoint.Host(lastKnown), port: .init(rawValue: LanWire.port)!)
        }
        return nil
    }

    // --- การเชื่อมต่อ --------------------------------------------------------
    private func attempt() {
        guard running, connection == nil else { return }
        guard let key = LanKey.load() else {
            // ยังไม่เคยมีกุญแจ = ยังไม่เคยจับคู่ทาง BLE เลย ต่อไปก็ถูกปฏิเสธทุกเฟรม
            onStatus?("no key yet — connect over Bluetooth once")
            reconnect(after: 30)
            return
        }
        guard let target = endpoint() else {
            onStatus?("looking for the board on this network")
            reconnect(after: 5)
            return
        }

        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 5
        options.enableKeepalive = true
        options.keepaliveIdle = 10
        let connection = NWConnection(to: target, using: NWParameters(tls: nil, tcp: options))
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.stateChanged(state, key: key) }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func stateChanged(_ state: NWConnection.State, key: Data) {
        switch state {
        case .ready:
            readGreeting(key: key)
        case .failed(let error):
            Log.debug("lan: connection failed (\(error))")
            onStatus?("cannot reach the board")
            reconnect(after: backoff)
        case .cancelled:
            break
        default:
            break
        }
    }

    /// บอร์ดพูดก่อนเสมอ — จนกว่าจะได้ยินคำทักทาย เรายังไม่รู้ว่าต้องนับต่อจากเลขไหน
    /// และการส่งเฟรมด้วยเลขที่เดาเองจะถูกทิ้งทั้งหมดอย่างเงียบที่สุด
    private func readGreeting(key: Data) {
        guard let conn = connection else { return }
        conn.receive(
            minimumIncompleteLength: LanWire.greetingLength,
            maximumLength: LanWire.greetingLength
        ) { [weak self] data, _, _, error in
            self?.queue.async {
                guard let self else { return }
                guard conn === self.connection else { return }
                guard let data, let hello = LanGreeting.decode(data), error == nil else {
                    Log.info("lan: the peer did not greet us like a board")
                    self.onStatus?("something else is listening on that address")
                    self.reconnect(after: 10)
                    return
                }
                guard let sealer = try? LanSealer(key: key, startingAfter: hello.counter) else {
                    self.reconnect(after: 30)
                    return
                }
                self.sealer = sealer
                self.isConnected = true
                self.backoff = 2
                Log.info("lan: board reached, counter continues from \(hello.counter)")
                self.onStatus?("connected over Wi-Fi")
                self.watchForClose()
                self.onConnect?()
                self.flush()
            }
        }
    }

    /// บอร์ดไม่ตอบอะไรอีกเลยหลังคำทักทาย — การอ่านค้างไว้จึงไม่ได้รอข้อมูล แต่รอ *การปิด*
    /// ซึ่งเป็นวิธีเดียวที่บอร์ดบอกว่ามันปฏิเสธเฟรมของเรา (กุญแจไม่ตรง หรือตัวนับซ้ำ)
    private func watchForClose() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64) {
            [weak self] _, _, done, error in
            self?.queue.async {
                guard let self else { return }
                // การอ่านที่ค้างอยู่จะคืน error ตอนเรา cancel เองด้วย (BLE กลับมา = stop)
                // ซึ่งไม่ใช่การถูกปฏิเสธ — เทียบตัวสายก่อน ไม่งั้น log กับหน้าตั้งค่าจะโทษ
                // กุญแจทุกครั้งที่สลับกลับไปทางหลัก
                guard conn === self.connection else { return }
                if done || error != nil {
                    Log.info("lan: board closed the connection")
                    self.onStatus?("the board rejected us — check the key")
                    self.reconnect(after: self.backoff)
                } else {
                    self.watchForClose()
                }
            }
        }
    }

    private func flush() {
        guard isConnected, let data = pending, var sealer else { return }
        guard let frame = try? sealer.seal(data) else {
            Log.info("lan: snapshot too large to seal, dropped")
            pending = nil
            return
        }
        self.sealer = sealer
        pending = nil
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                Log.debug("lan: send failed (\(error))")
                self?.reconnect(after: 2)
            }
        })
    }

    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        sealer = nil
        if isConnected { onStatus?("disconnected") }
        isConnected = false
    }

    private func reconnect(after delay: TimeInterval) {
        teardown()
        guard running else { return }
        // เพดาน 30 วิ ไม่ใช่การเลิกลอง: บอร์ดที่หายไปเพราะเราเตอร์รีบูตจะกลับมาเอง และ
        // ไม่มีใครมากดปุ่ม — เหตุผลเดียวกับ backoff ฝั่ง firmware
        backoff = min(30, max(2, backoff * 2))
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attempt() }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

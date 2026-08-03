import Foundation

/// ตัว daemon: socket -> store -> snapshot -> transports
///
/// ทุกอย่างวิ่งบนคิวเดียว (`work`) สถานะจึงไม่ต้องล็อก
public final class Daemon {
    private let store: SessionStore
    private let work = DispatchQueue(label: "tamaclaude.daemon")
    private var server: SocketServer?
    private var transports: [Transport]
    private var timer: DispatchSourceTimer?
    private var lastSent: Data?
    /// Codex ไม่มี hook ให้ติดตั้ง — เราไปอ่าน rollout ของมันเองทุกจังหวะแทน
    private let codex = CodexWatcher()
    /// ไม่ต้องสแกนโฟลเดอร์ทุกวินาที — งานจริงของ Codex ช้ากว่านั้นมาก
    private var pulses = 0
    private let codexEvery = 2
    /// อากาศเปลี่ยนช้ากว่าทุกอย่างบนจอนี้ — ตัวมันเองคุมจังหวะยิงเน็ต
    private let weather = WeatherPoller()

    /// ทุกกี่วินาทีที่คำนวณ snapshot ใหม่ — สถานะหลายอย่างเกิดจากเวลาผ่านไปเฉยๆ
    /// (นอน, เกณฑ์เตือน 45 วิ, นาฬิกาเปลี่ยนนาที) ไม่ใช่จากเหตุการณ์
    private let tick: TimeInterval = 1.0

    /// เรียกทุกครั้งที่ภาพเปลี่ยน — เมนูบาร์ใช้แสดงว่ากำลังเกิดอะไรอยู่
    /// ถูกเรียกจากคิวของ daemon ไม่ใช่เธรดหลัก
    public var onPublish: ((Snapshot) -> Void)?

    public init(store: SessionStore, transports: [Transport]) {
        self.store = store
        self.transports = transports
    }

    public func start() throws {
        Paths.ensureStateDir()

        for t in transports {
            t.onConnect = { [weak self] in
                // บอร์ดเพิ่งกลับมา — มันไม่จำอะไรเลย ต้องบังคับส่งใหม่ทั้งก้อน
                self?.work.async { self?.lastSent = nil }
            }
            t.start()
        }

        let server = SocketServer(path: Paths.socket) { [weak self] line in
            self?.handle(line)
        }
        try server.start()
        self.server = server
        Log.info("listening on \(Paths.socket.path)")

        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now(), repeating: tick)
        t.setEventHandler { [weak self] in self?.pulse() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        server?.stop()
        server = nil
    }

    private func handle(_ line: Data) {
        work.async { [weak self] in
            guard let self else { return }
            do {
                let event = try JSONDecoder().decode(HookEvent.self, from: line)
                Log.debug("event \(event.hookEventName) \(event.toolName ?? "")")
                self.store.apply(event, now: Date())
                self.publish()
            } catch {
                Log.debug("bad event: \(error)")
            }
        }
    }

    /// หนึ่งจังหวะของนาฬิกา — transport ได้เวลาปัจจุบันก่อน แล้วค่อยคิดภาพใหม่
    ///
    /// เรียงลำดับนี้เพราะ tick อาจสลับทางเดิน ซึ่งจะล้าง `lastSent` ผ่าน `onConnect`
    /// การ publish ก่อนแล้วค่อย tick จะทำให้ snapshot ก้อนแรกของทางใหม่ตกหายไปหนึ่งจังหวะ
    private func pulse() {
        let now = Date()
        for t in transports { t.tick(now: now) }

        pulses += 1
        if pulses % codexEvery == 0 {
            for e in codex.poll(now: now) {
                Log.debug("codex \(e.hookEventName) \(e.toolName ?? "")")
                store.apply(e, now: now)
            }
        }
        weather.tick(now: now)
        publish()
    }

    /// ส่งเมื่อภาพเปลี่ยนจริงเท่านั้น — ไม่งั้นบอร์ดโดนยิงทุกวินาทีโดยเปล่าประโยชน์
    private func publish() {
        let now = Date()
        var snapshot = store.snapshot(now: now)
        snapshot.usage = UsageReader.read(now: now)
        if let w = weather.reading {
            snapshot.weather = WeatherSnap(
                condition: w.condition.rawValue, temperature: w.temperature)
        }
        guard let data = try? snapshot.encoded() else { return }
        guard data != lastSent else { return }
        lastSent = data
        Log.debug("publish \(snapshot.sessions.map { "\($0.project):\($0.state.rawValue)" })"
            + " cards=\(snapshot.cards.count)")
        for t in transports where t.isConnected {
            t.send(data)
        }
        onPublish?(snapshot)
    }
}

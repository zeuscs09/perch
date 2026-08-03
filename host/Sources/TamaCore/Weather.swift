import Foundation

/// สภาพอากาศจาก Open-Meteo — ตัวเดียวที่ daemon ยิงเน็ตออกไปนอกเครื่อง
///
/// เลือก Open-Meteo เพราะ **ไม่ต้องใช้ API key** ซึ่งตรงกับข้อตกลงของโปรเจกต์นี้ที่
/// ไม่ถือ credential ของใครเลย (โควตายังอ่านจากไฟล์ในเครื่องเหมือนเดิม)
/// สิ่งที่ส่งออกไปมีแค่พิกัดที่ผู้ใช้ตั้งเอง ไม่มีอะไรเกี่ยวกับ session หรือโค้ด
///
/// ปิดได้ด้วยการไม่ตั้งพิกัด — ไม่ตั้ง = ไม่ยิงเน็ตเลย ไม่ใช่เดาตำแหน่งให้
public enum Weather {
    /// สภาพที่จอวาดแยกออกจากกันได้จริงจากระยะโต๊ะ — ละเอียดกว่านี้ดูไม่ออก
    ///
    /// ค่าตัวเลขถูกส่งบนสายและ firmware ใช้ตรงๆ ห้ามเรียงใหม่
    public enum Condition: Int, Codable, Equatable, Sendable, CaseIterable {
        case clear = 0
        case cloudy = 1
        case rain = 2
        case storm = 3
        case fog = 4

        /// WMO weather code (มาตรฐานที่ Open-Meteo ใช้) -> สภาพที่เราวาดได้
        ///
        /// จับกลุ่มหยาบโดยตั้งใจ: ฝนปรอยกับฝนหนักวาดเหมือนกันบนจอ 320x240
        /// สิ่งที่ต้องแยกออกคือ "เปียกไหม" กับ "อันตรายไหม" ไม่ใช่ปริมาณน้ำฝน
        public static func fromWMO(_ code: Int) -> Condition {
            switch code {
            case 0, 1: return .clear
            case 2, 3: return .cloudy
            case 45, 48: return .fog
            case 95, 96, 99: return .storm  // ฟ้าคะนอง — ต้องแยกเพราะมันคือเหตุผลที่จะไม่ออกจากบ้าน
            case 51...67, 71...86: return .rain  // ปรอย/ฝน/หิมะ/ฝนซู่ — เปียกเหมือนกันหมด
            default: return .clear
            }
        }
    }

    public struct Reading: Equatable, Sendable {
        public var condition: Condition
        /// องศาเซลเซียส ปัดเป็นจำนวนเต็ม — ทศนิยมอ่านไม่ออกจากระยะโต๊ะ
        public var temperature: Int
        public var fetchedAt: Date
    }

    /// พิกัดที่ผู้ใช้ตั้งเอง — ไม่มีการเดาจาก IP หรือขอสิทธิ์ตำแหน่ง
    /// ไฟล์นี้ไม่มี = ปิดฟีเจอร์ (ไม่ยิงเน็ต)
    public struct Location: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public static var configPath: URL {
        Paths.stateDir.appendingPathComponent("location")
    }

    /// อ่านพิกัดจากไฟล์ `lat,lon` บรรทัดเดียว
    public static func location(at url: URL = configPath) -> Location? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count == 2,
            let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)),
            (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return Location(latitude: lat, longitude: lon)
    }

    public static func save(_ loc: Location, to url: URL = configPath) throws {
        Paths.ensureStateDir()
        try "\(loc.latitude),\(loc.longitude)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// ดึงค่าปัจจุบัน — ผู้เรียกเป็นคนคุมจังหวะ ตัวนี้ไม่มีตัวจับเวลาในตัว
    public static func fetch(
        _ loc: Location,
        timeout: TimeInterval = 10,
        session: URLSession = .shared
    ) async -> Reading? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", loc.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", loc.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("tamaclaude", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = root["current"] as? [String: Any],
            let code = current["weather_code"] as? Int
        else { return nil }

        // อุณหภูมิหายได้โดยที่ code ยังมา — วาดฟ้าถูกดีกว่าไม่วาดอะไรเลย
        let temp = (current["temperature_2m"] as? Double).map { Int($0.rounded()) }
        return Reading(
            condition: Condition.fromWMO(code),
            temperature: temp ?? WeatherSnap.unknownTemp,
            fetchedAt: Date())
    }
}

/// ตัวเก็บค่าล่าสุด + คุมจังหวะการยิง
///
/// อากาศเปลี่ยนช้ากว่าทุกอย่างบนจอนี้มาก การถามถี่กว่านี้คือการกวน API ฟรีเปล่าๆ
public final class WeatherPoller: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var latest: Weather.Reading?
    private var inFlight = false
    private var lastAttempt: Date = .distantPast

    public init(interval: TimeInterval = 15 * 60) {
        self.interval = interval
    }

    /// ค่าล่าสุดที่ได้มา — ไม่หมดอายุเอง เพราะค่าที่เก่าหนึ่งชั่วโมงยังใกล้ความจริง
    /// มากกว่าการไม่แสดงอะไรเลย (ต่างจากโควตาที่ค่าเก่าอาจผิดสิ้นเชิง)
    public var reading: Weather.Reading? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// เรียกได้ทุก tick — ตัวมันเองตัดสินว่าถึงเวลายิงหรือยัง
    public func tick(now: Date = Date()) {
        guard let loc = Weather.location() else { return }  // ไม่ตั้งพิกัด = ไม่ยิงเน็ต
        lock.lock()
        guard !inFlight, now.timeIntervalSince(lastAttempt) >= interval else {
            lock.unlock()
            return
        }
        inFlight = true
        lastAttempt = now
        lock.unlock()

        Task { [weak self] in
            let result = await Weather.fetch(loc)
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            // ยิงพลาดแล้วเก็บค่าเดิมไว้ ไม่ล้างเป็นว่าง — เน็ตสะดุดไม่ได้แปลว่าฟ้าเปลี่ยน
            if let result {
                self.latest = result
                Log.info("weather \(result.condition) \(result.temperature)C")
            } else {
                Log.info("weather fetch failed")
            }
            self.lock.unlock()
        }
    }
}

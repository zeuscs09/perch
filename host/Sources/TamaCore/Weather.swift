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
        /// ชื่อที่ผู้ใช้ตั้งเอง — ไม่มีการ reverse-geocode เพราะนั่นต้องยิงไปอีกบริการ
        /// และผู้ใช้รู้ดีกว่าอยู่แล้วว่าจะเรียกที่ที่ตัวเองนั่งอยู่ว่าอะไร
        public var name: String?

        public init(latitude: Double, longitude: Double, name: String? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.name = name
        }
    }

    public static var configPath: URL {
        Paths.stateDir.appendingPathComponent("location")
    }

    /// อ่านพิกัดจากไฟล์ `lat,lon` บรรทัดเดียว
    public static func location(at url: URL = configPath) -> Location? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // รูปแบบ: `lat,lon` หรือ `lat,lon,ชื่อ` — ชื่อมีช่องว่างได้ จึงตัดแค่สองครั้งแรก
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", maxSplits: 2)
        guard parts.count >= 2,
            let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)),
            (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        let name = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        return Location(latitude: lat, longitude: lon, name: name.isEmpty ? nil : name)
    }

    public static func save(_ loc: Location, to url: URL = configPath) throws {
        Paths.ensureStateDir()
        let line = loc.name.map { "\(loc.latitude),\(loc.longitude),\($0)" }
            ?? "\(loc.latitude),\(loc.longitude)"
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - ค้นหาสถานที่

    /// ผลค้นหาจาก Open-Meteo geocoding (ฟรี ไม่ต้องใช้ key เหมือนตัวพยากรณ์)
    public struct Place: Equatable, Sendable {
        public var name: String
        public var admin1: String?
        public var country: String?
        public var latitude: Double
        public var longitude: Double

        public init(name: String, admin1: String? = nil, country: String? = nil,
                    latitude: Double, longitude: Double) {
            self.name = name
            self.admin1 = admin1
            self.country = country
            self.latitude = latitude
            self.longitude = longitude
        }

        /// บรรทัดที่โชว์ในรายการให้เลือก — จังหวัดกับประเทศคือสิ่งที่แยก "Chiang Mai"
        /// ในไทยออกจากชื่อซ้ำที่อื่น ซึ่งเป็นเหตุผลเดียวที่รายการนี้มีมากกว่าหนึ่งบรรทัด
        public var label: String {
            [name, admin1, country].compactMap { $0 }
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { acc, s in if acc.last != s { acc.append(s) } }
                .joined(separator: ", ")
        }

        public var location: Location {
            Location(latitude: latitude, longitude: longitude, name: Weather.latin(name))
        }
    }

    /// ถอดเป็นอักษรละตินล้วน
    ///
    /// ฟอนต์บนบอร์ดคือ `lv_font_montserrat_12` ซึ่งมีแต่ ASCII ชื่อไทย/จีน/ญี่ปุ่น
    /// ที่ส่งขึ้นไปตรงๆ จะกลายเป็นกล่องเปล่า การถอดเสียงตรงนี้จึงไม่ใช่ความสวยงาม
    /// แต่เป็นเงื่อนไขที่จะได้เห็นอะไรบนจอเลย
    public static func latin(_ s: String) -> String {
        let romanised = s.applyingTransform(.toLatin, reverse: false) ?? s
        let flattened = romanised.applyingTransform(.stripDiacritics, reverse: false)
            ?? romanised
        // ตัวที่เหลือจากการถอดเสียงบางภาษายังไม่ใช่ ASCII (เช่น ı จากภาษาไทย)
        // จับคู่ที่เจอบ่อยก่อน แล้วค่อยทิ้งที่เหลือ — ทิ้งเงียบๆ ดีกว่าโชว์กล่องเปล่า
        let mapped = flattened
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "đ", with: "d")
        let kept = mapped.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespaces)
    }

    /// ค้นชื่อเมือง -> พิกัด
    ///
    /// ถามภาษาอังกฤษก่อนเสมอ เพราะดัชนีของ Open-Meteo แยกตามภาษา และชื่อที่ได้กลับมา
    /// เป็นอักษรละตินอยู่แล้วซึ่งตรงกับที่จอวาดได้ ถ้าไม่เจอค่อยถามไทย (คนพิมพ์ "ภูเก็ต"
    /// จะไม่เจออะไรเลยในดัชนีอังกฤษ) แล้วค่อยถอดเสียงตอนบันทึก
    public static func search(
        _ query: String,
        limit: Int = 8,
        timeout: TimeInterval = 10,
        session: URLSession = .shared
    ) async -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        for language in ["en", "th"] {
            let found = await searchOnce(trimmed, language: language, limit: limit,
                                         timeout: timeout, session: session)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func searchOnce(
        _ query: String, language: String, limit: Int,
        timeout: TimeInterval, session: URLSession
    ) async -> [Place] {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: String(limit)),
            .init(name: "language", value: language),
            .init(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("tamaclaude", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        // ไม่เจอ = ไม่มีคีย์ `results` เลย ไม่ใช่ลิสต์ว่าง
        let rows = root["results"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                let lat = row["latitude"] as? Double,
                let lon = row["longitude"] as? Double
            else { return nil }
            return Place(name: name, admin1: row["admin1"] as? String,
                         country: row["country"] as? String,
                         latitude: lat, longitude: lon)
        }
    }

    /// ลบพิกัดที่ตั้งไว้ = ปิดฟีเจอร์ (daemon จะเลิกยิงเน็ตทันที)
    public static func clear(at url: URL = configPath) {
        try? FileManager.default.removeItem(at: url)
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
    /// พิกัดที่ค่าใน `latest` มาจาก — ใช้จับว่าผู้ใช้ย้ายที่ตั้งระหว่างรอบ
    private var lastLocation: Weather.Location?

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
        guard let loc = Weather.location() else {  // ไม่ตั้งพิกัด = ไม่ยิงเน็ต
            lock.lock()
            // ลบพิกัดแล้วต้องลบค่าที่ค้างด้วย ไม่งั้นจอยังโชว์อากาศของที่เดิมต่อไป
            latest = nil
            lastLocation = nil
            lock.unlock()
            return
        }
        lock.lock()
        if loc != lastLocation {
            // ย้ายที่ตั้ง = ค่าที่มีอยู่เป็นของเมืองอื่นแล้ว ต้องถามใหม่เดี๋ยวนี้
            // ไม่ใช่รอครบ 15 นาที ไม่งั้นผู้ใช้กดเปลี่ยนเมืองแล้วจอไม่ขยับเลย
            lastLocation = loc
            lastAttempt = .distantPast
            latest = nil
        }
        guard !inFlight, now.timeIntervalSince(lastAttempt) >= interval else {
            lock.unlock()
            return
        }
        inFlight = true
        lastAttempt = now
        lock.unlock()

        Task { [weak self] in
            let result = await Weather.fetch(loc)
            self?.finish(result)
        }
    }

    /// เก็บผลลงตัวแปรร่วม
    ///
    /// แยกออกมาเป็นเมธอดธรรมดา ไม่ทำในบล็อก `Task` ตรงๆ เพราะการถือ `NSLock` คร่อม
    /// จุด await ไม่ปลอดภัย: งานอาจถูกย้ายเธรดระหว่างที่ยังถือล็อกอยู่ Swift 6 จึงถือเป็น
    /// error ไม่ใช่คำเตือน ในเมธอดที่ไม่ async ปัญหานั้นหายไปเพราะไม่มีจุด await ให้ย้าย
    private func finish(_ result: Weather.Reading?) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        // ยิงพลาดแล้วเก็บค่าเดิมไว้ ไม่ล้างเป็นว่าง — เน็ตสะดุดไม่ได้แปลว่าฟ้าเปลี่ยน
        if let result {
            latest = result
            Log.info("weather \(result.condition) \(result.temperature)C")
        } else {
            Log.info("weather fetch failed")
        }
    }
}

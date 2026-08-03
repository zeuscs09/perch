import Foundation

/// อ่านโควตาของ Codex CLI จากไฟล์ session ในเครื่อง
///
/// Codex แนบ `rate_limits` มากับ event `token_count` ทุกครั้งที่เรียกโมเดล — ค่าที่สดที่สุด
/// จึงอยู่ท้ายไฟล์ session ที่ถูกแตะล่าสุด ไม่ต้องยิง API และไม่ต้องถือ credential
/// เหมือนกับที่ฝั่ง Claude อ่าน cache ของ statusline
///
/// อ่านอย่างเดียว ไม่เคยเขียนอะไรลง `~/.codex`
public enum CodexQuota {
    public struct Window: Equatable, Sendable {
        public var percent: Int
        /// วินาทีจนกว่าหน้าต่างจะรีเซ็ต
        public var remaining: Int
        /// ความยาวหน้าต่างเป็นวินาที — ใช้วาดขีด pace
        public var window: Int
    }

    /// ค่าที่เก่ากว่านี้ไม่เอา — Codex ที่ไม่ได้ใช้มาหลายวันไม่ควรกินช่องบนจอ
    /// (ต่างจากฝั่ง Claude ที่ค่าเก่ายังถูกเสมอ เพราะที่นี่เราไม่รู้ว่าผู้ใช้ยังใช้ plan เดิมอยู่ไหม)
    static let maxAge: TimeInterval = 14 * 24 * 3600

    public static func read(
        now: Date = Date(),
        root: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    ) -> Window? {
        guard let path = newestSession(root: root, now: now),
            let limits = lastRateLimits(path: path),
            let primary = limits["primary"] as? [String: Any]
        else { return nil }

        guard let used = primary["used_percent"] as? Double else { return nil }
        let minutes = (primary["window_minutes"] as? Int) ?? 0
        var remaining = UsageSnap.unknown
        if let resets = primary["resets_at"] as? Double {
            let raw = max(0, Int(Date(timeIntervalSince1970: resets).timeIntervalSince(now).rounded(.up)))
            // ปัดเป็นนาทีด้วยเหตุผลเดียวกับ UsageReader — กันไม่ให้ snapshot ต่างกันทุกวินาที
            remaining = raw > 0 ? max(60, raw / 60 * 60) : 0
        }
        // หน้าต่างหมุนไปแล้วแต่ยังไม่มีใครอัปเดต = เปอร์เซ็นต์ที่ถืออยู่ผิดแน่นอน
        let percent = remaining == 0 ? UsageSnap.unknown : max(0, min(100, Int(used.rounded())))
        return Window(percent: percent, remaining: remaining, window: max(60, minutes * 60))
    }

    private static func newestSession(root: URL, now: Date) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var best: (URL, Date)?
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                now.timeIntervalSince(mtime) < maxAge
            else { continue }
            if best == nil || mtime > best!.1 { best = (url, mtime) }
        }
        return best?.0
    }

    /// ไฟล์ session ยาวได้หลายสิบเมกและ `rate_limits` ตัวที่ต้องการอยู่ *ท้ายสุด*
    /// จึงอ่านจากท้ายไฟล์ถอยขึ้นมาเป็นก้อน แทนการไล่ทั้งไฟล์
    private static func lastRateLimits(path: URL, chunk: Int = 64 * 1024) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        var end = size
        // สามก้อนพอสำหรับทุกกรณีจริง (token_count ถูกเขียนถี่มาก) และกันไฟล์ยักษ์
        for _ in 0..<3 {
            let start = end > UInt64(chunk) ? end - UInt64(chunk) : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(end - start)), !data.isEmpty
            else { return nil }

            // ตัดบรรทัดแรกทิ้งถ้าไม่ได้เริ่มที่ต้นไฟล์ — มันถูกหั่นกลางบรรทัด
            var slice = data
            if start > 0, let nl = slice.firstIndex(of: 0x0A) {
                slice = slice[slice.index(after: nl)...]
            }
            for line in slice.split(separator: 0x0A).reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    let payload = obj["payload"] as? [String: Any],
                    let limits = payload["rate_limits"] as? [String: Any]
                else { continue }
                return limits
            }
            if start == 0 { return nil }
            end = start
        }
        return nil
    }
}

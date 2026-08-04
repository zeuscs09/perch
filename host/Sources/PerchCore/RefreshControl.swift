import Foundation

/// สภาพของปุ่ม refresh ที่หัว popover — กดได้ไหม กำลังยิงอยู่ไหม และทำไม
public struct RefreshState: Equatable {
    public let enabled: Bool
    public let spinning: Bool
    public let tooltip: String

    public init(enabled: Bool, spinning: Bool, tooltip: String) {
        self.enabled = enabled
        self.spinning = spinning
        self.tooltip = tooltip
    }
}

/// วินัยของปุ่ม refresh — ตรรกะล้วน อยู่ใน PerchCore ด้วยเหตุผลเดียวกับ `PanelText`
///
/// endpoint นี้ไม่มีเอกสาร และเราเพิ่งตัดตัวเลือก 30 วินาทีทิ้งเพราะไม่อยากยิงถี่เกินจำเป็น
/// ปุ่มที่กดรัวได้จะทำลายเหตุผลนั้นทั้งหมด — ปุ่มจึงเป็นทางออกฉุกเฉิน ไม่ใช่ทางปกติ
///
/// สิ่งที่ปุ่มไม่สนใจคือ `Off` กับ key ที่หมดอายุ: อันแรกเป็นคำสั่งว่าอย่ายิง*เอง*
/// อันหลังเป็นล็อกที่มีไว้กันการยิงซ้ำทุกนาทีเพื่อรับ 401 เดิม ทั้งคู่ไม่ใช่คำสั่งว่า
/// ห้ามผู้ใช้ดูค่าใหม่ (เหตุผลเดียวกันอยู่ที่ `UsagePoller.refreshNow`)
public enum RefreshControl {
    /// เย็นตัวหลังยิงเสร็จ — สั้นพอจะไม่รู้สึกเหมือนถูกลงโทษ ยาวพอจะกันการกดรัว
    public static let cooldown: TimeInterval = 10

    public static func state(
        running: Bool, hasKey: Bool, finished: Date?, now: Date = Date()
    ) -> RefreshState {
        if running {
            return RefreshState(enabled: false, spinning: true, tooltip: "Checking your quota…")
        }
        // ไม่มี key ก็ไม่มีคำถามจะยิง — ปุ่มที่กดแล้วไม่เกิดอะไรแย่กว่าปุ่มที่กดไม่ได้
        guard hasKey else {
            return RefreshState(
                enabled: false, spinning: false,
                tooltip: "Set a session key before checking your quota")
        }
        if let left = secondsLeft(finished: finished, now: now) {
            return RefreshState(
                enabled: false, spinning: false,
                tooltip: "Just checked · you can check again in \(left)s")
        }
        return RefreshState(enabled: true, spinning: false, tooltip: "Check your quota now")
    }

    /// เหลืออีกกี่วินาทีถึงกดได้ · `nil` = กดได้แล้ว
    ///
    /// นาฬิกาเครื่องเดินถอยหลังได้ (sleep, NTP) เวลาที่ประทับไว้ในอนาคตจึงต้องไม่กลายเป็น
    /// การเย็นตัวชั่วนิรันดร์ — ตัดที่ `cooldown` เต็มจำนวนแล้วมันจะคลายเองภายในสิบวินาที
    private static func secondsLeft(finished: Date?, now: Date) -> Int? {
        guard let finished else { return nil }
        let left = min(cooldown, cooldown - now.timeIntervalSince(finished))
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    /// เปิดแผงแล้วควรยิงเองไหม — ยิงเมื่อค่าที่มีเก่ากว่ารอบที่ผู้ใช้ตั้งไว้
    ///
    /// การเปิด popover เป็นสัญญาณความตั้งใจที่ชัดพอจะใช้เป็น trigger อยู่แล้ว จึงไม่ต้อง
    /// ให้ผู้ใช้กดปุ่มเพื่อบอกสิ่งที่เขาบอกไปแล้วด้วยการเปิดแผง · `Off` ไม่ยิง เพราะนี่คือ
    /// การยิงเองของแอป ซึ่งเป็นสิ่งเดียวที่ `Off` สั่งห้ามไว้
    ///
    /// `polled` (รอบล่าสุดที่*ออกไป*) ไม่ใช่ของซ้ำกับ `stamp` (ค่าล่าสุดที่*กลับมา*) —
    /// รอบที่ล้มเหลวไม่เคยขยับ `stamp` ถ้าดูแต่ `stamp` การเปิดปิดแผงตอนเน็ตล่มจะยิงลูก
    /// ทุกครั้งที่ชำเลืองดู ซึ่งเป็นการยิงถี่กว่ารอบที่ผู้ใช้ตั้งไว้ ทั้งที่เขาไม่ได้ขออะไรเลย
    public static func wantsPoll(
        interval: PollInterval, stamp: Date?, polled: Date? = nil, now: Date = Date()
    ) -> Bool {
        guard interval != .off else { return false }
        let round = TimeInterval(interval.seconds)
        if let polled, now.timeIntervalSince(polled) < round { return false }
        guard let stamp else { return true }
        return now.timeIntervalSince(stamp) >= round
    }
}

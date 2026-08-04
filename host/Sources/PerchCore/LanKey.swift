import CryptoKit
import Foundation

/// กุญแจของทาง LAN — 32 ไบต์สุ่ม เก็บที่ `~/.perch/lan-key` mode 600
///
/// แอปสร้างเองครั้งเดียว ไม่มีอะไรให้ผู้ใช้พิมพ์: มันไม่ใช่รหัสผ่านที่ใครต้องจำ และรหัสผ่าน
/// ที่คนตั้งเองจะสั้นพอให้เดาได้ทุกครั้ง · กุญแจเดินทางไปบอร์ดทาง config characteristic
/// ซึ่งบังคับให้ลิงก์ BLE เข้ารหัสแล้ว — ที่เดียวกับที่รหัส WiFi เดินอยู่
///
/// นี่ไม่ใช่ `sessionKey`: อันนั้นเปิดบัญชี claude.ai ทั้งใบและ **ไม่เคย** ออกจากเครื่องนี้
/// อันนี้เปิดได้แค่ช่องคุยกับจอบนโต๊ะ (DESIGN.md "WiFi")
public enum LanKey {
    public static let byteCount = 32

    /// อ่านกุญแจที่มีอยู่ — nil เมื่อยังไม่เคยสร้าง หรือไฟล์เสีย
    public static func load(from url: URL = Paths.lanKey) -> Data? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return decode(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// อ่าน หรือสร้างใหม่ถ้ายังไม่มี — คืน nil เมื่อเขียนไฟล์ไม่ได้
    ///
    /// สร้างแล้วเขียนทันที ไม่ใช่ถือไว้ในหน่วยความจำ: กุญแจที่บอร์ดจำได้แต่ Mac จำไม่ได้
    /// หลังรีสตาร์ตแปลว่าต้องผลักกุญแจใหม่ไปทุกครั้งที่เปิดแอป ซึ่งใช้ BLE ที่อาจไม่มี
    public static func loadOrCreate(at url: URL = Paths.lanKey) -> Data? {
        if let existing = load(from: url) { return existing }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        let key = Data(bytes)
        guard write(key, to: url) else { return nil }
        Log.info("generated a new lan key (\(fingerprint(key)))")
        return key
    }

    /// ลบทิ้งเพื่อให้รอบหน้าสร้างใหม่ — ใช้ตอนผู้ใช้สั่งจับคู่ใหม่
    public static func forget(at url: URL = Paths.lanKey) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func hex(_ key: Data) -> String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ hex: String) -> Data? {
        guard hex.count == byteCount * 2 else { return nil }
        var out = Data(capacity: byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// 8 hex ตัวแรกของ SHA-256(key) — ต้องตรงกับ `fingerprint()` ใน `ct_lan.c`
    ///
    /// ใช้ถามว่า "สองฝั่งถือกุญแจเดียวกันไหม" โดยไม่ต้องส่งกุญแจไปเทียบ · เปิดเผยได้:
    /// มันคือแฮชของกุญแจ ไม่ใช่กุญแจ และเราไม่ได้ใช้มันแทนการพิสูจน์ตัวตน
    public static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ key: Data, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // สิทธิ์ 600 ตั้งแต่วินาทีที่ไฟล์มีตัวตน ไม่ใช่ `chmod` ตามหลัง — เหตุผลเดียวกับ
        // `SessionKeyFile.write` ช่วงระหว่างสองคำสั่งคือช่วงที่คนอื่นบนเครื่องอ่านได้
        try? FileManager.default.removeItem(at: url)
        return FileManager.default.createFile(
            atPath: url.path, contents: Data(hex(key).utf8),
            attributes: [.posixPermissions: 0o600])
    }
}

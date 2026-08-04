import Foundation

/// การเตรียมข้อความก่อนส่งบน BLE
///
/// ฟอนต์บนบอร์ดมีแค่ ASCII พิมพ์ได้ (0x20..0x7E) ตัวอักษรนอกชุดนี้จะกลายเป็น
/// กล่องสี่เหลี่ยมบนจอ (เจอจริงตอนทำ preview กับ em dash) daemon จึงต้องกรองเอง
/// ไม่ใช่ปล่อยให้ firmware ไปเดา
public enum Text {
    /// ตัวที่แทนได้ด้วย ASCII แบบไม่เสียความหมาย
    private static let substitutions: [Character: String] = [
        "\u{2014}": "-",  // em dash
        "\u{2013}": "-",  // en dash
        "\u{2212}": "-",  // minus
        "\u{2018}": "'", "\u{2019}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{2026}": "...",
        "\u{00A0}": " ", "\u{2009}": " ", "\u{202F}": " ",
        "\u{2192}": "->", "\u{2190}": "<-",
        "\u{2022}": "*", "\u{00B7}": "*",
        "\u{2713}": "ok", "\u{2717}": "x",
    ]

    /// เหลือเฉพาะอักขระที่ฟอนต์บนบอร์ดมีจริง และยุบช่องว่างซ้อนให้เหลือช่องเดียว
    public static func sanitize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            let piece: String
            if let sub = substitutions[ch] {
                piece = sub
            } else if let a = ch.asciiValue, (0x20...0x7E).contains(a) {
                piece = String(ch)
            } else if ch.isWhitespace {
                piece = " "
            } else {
                continue  // ทิ้ง ไม่แทนด้วย '?' เพราะจะกลายเป็นขยะเต็มบรรทัด
            }
            for p in piece {
                if p == " " {
                    if lastWasSpace { continue }
                    lastWasSpace = true
                } else {
                    lastWasSpace = false
                }
                out.append(p)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// ตัดให้ยาวไม่เกิน `limit` ตัวอักษร โดยเติม "..." เมื่อถูกตัดจริง
    public static func clip(_ s: String, to limit: Int) -> String {
        if limit <= 0 { return "" }
        if s.count <= limit { return s }
        if limit <= 3 { return String(s.prefix(limit)) }
        return String(s.prefix(limit - 3)) + "..."
    }

    /// sanitize + clip ในขั้นตอนเดียว — ทุกข้อความที่ออกจาก daemon ต้องผ่านทางนี้
    public static func fit(_ s: String, to limit: Int) -> String {
        clip(sanitize(s), to: limit)
    }

    /// ความยาวสูงสุดตามพื้นที่จริงบนจอ (วัดจาก tools/gen/screen.py)
    public enum Limit {
        /// ป้ายชื่อโปรเจกต์ใต้มาสคอต — slot กว้าง 80px ฟอนต์ 9
        public static let project = 14
        /// หัวการ์ด — กว้าง ~293px ฟอนต์ 12
        public static let cardTitle = 34
        /// เนื้อการ์ด — กว้างเท่ากัน ฟอนต์ 10
        public static let cardBody = 46
    }
}

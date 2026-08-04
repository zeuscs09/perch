import AppKit
import PerchCore

/// แบดจ์บนแถบเมนูในรูปภาพเดียว — แถบวัดสั้นๆ กับเปอร์เซ็นต์
///
/// อยู่คนละไฟล์กับ `MenuBarApp` เพราะเป็นคนละเหตุผลที่จะแก้: ไฟล์นั้นเปลี่ยนเมื่อเมนู
/// มีรายการใหม่หรือ daemon ต่อสายใหม่ ไฟล์นี้เปลี่ยนเมื่อหน้าตาของแบดจ์เปลี่ยน
enum MenuBadgeImage {
    private static let barWidth: CGFloat = 35
    private static let barHeight: CGFloat = 11
    private static let gap: CGFloat = 5
    /// สูงกว่านี้ระบบย่อภาพให้เองแล้วเส้นขอบ 1 px กลายเป็นเส้นเบลอครึ่งพิกเซล
    private static let height: CGFloat = 16
    private static let border: CGFloat = 1
    /// มุมมนพอไม่ให้เป็นกล่องแข็ง แต่ไม่ถึงครึ่งความสูง — pill อ่านเหมือนปุ่มหรือป้าย
    /// ส่วนนี่คือเครื่องวัด ปลายแถบที่โค้งจนกลมทำให้ 3% แรกกับ 3% สุดท้ายกินพื้นที่
    /// ไม่เท่ากับ 3% ตรงกลาง
    private static let radius: CGFloat = 2.5
    /// ช่องว่างระหว่างขอบกับเนื้อแถบ — ขอบที่ติดเนื้อกลายเป็นก้อนเดียวกัน แล้ว "เต็มแค่ไหน"
    /// ต้องเดาจากน้ำหนักสีแทนที่จะอ่านจากระยะ
    private static let padding: CGFloat = 1.5

    /// ไอคอนตอนไม่มีอะไรจะบอก — `0%` ที่เดาเอาคือคำโกหกที่ดูเหมือนค่าที่วัดมา
    /// ส่วนแถบเปล่าดูเหมือนแอปพัง
    ///
    /// เคยใช้ไอคอนของแอปย่อลงมา ด้วยเหตุผลว่าตราของแอปพูดประโยค "แอปอยู่ แต่ยังไม่รู้
    /// ตัวเลข" ตรงกว่าสัญลักษณ์ที่ยืมความหมายมา แต่ที่ 16 px โลโก้เหลือแค่ก้อนส้ม
    /// ที่อ่านไม่ออก และเพราะไม่ใช่ template มันยังไม่กลับสีตามธีมด้วย — สถานะนี้
    /// ต้องการรูปที่ *เห็น* ก่อนจะต้องการรูปที่ถูกความหมาย
    ///
    /// เป็นเครื่องวัด ไม่ใช่ `desktopcomputer` ที่พูดถึงจอ ซึ่งเป็นคนละเรื่องกับโควตา —
    /// ที่ตรงนี้จะกลายเป็นแถบโควตาทันทีที่รู้ตัวเลข ไอคอนแทนจึงควรเป็นเครื่องมือชนิด
    /// เดียวกันที่เข็มยังไม่ขยับ ไม่ใช่วัตถุอื่นที่ผู้ใช้ต้องแปลความใหม่
    static func fallback() -> NSImage? {
        let icon = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: PanelText.appName)
        icon?.isTemplate = true
        return icon
    }

    /// ปกติเป็น template ขาวดำ ระบบจึงกลับสีให้เองทั้งพื้นสว่าง/มืด และตอนเมนูถูกไฮไลต์
    /// ตอนต้องเตือนเลิกเป็น template แล้วทาแดง — สีที่ระบบกลับได้ตามใจ
    /// ไม่สามารถแปลว่า "แดง" ได้
    ///
    /// แดง*เฉพาะขีด pace* ไม่ใช่ทั้งภาพ — สิ่งที่ผิดปกติคือความสัมพันธ์ระหว่างเนื้อแถบ
    /// กับขีด ไม่ใช่ตัวเลขหรือตัวแถบ ภาพที่แดงทั้งอันทำให้ตาไม่รู้ว่าจะมองตรงไหน
    /// และกลืนตัวเลขที่ยังต้องอ่านได้อยู่ไปด้วย · ขีดที่เปลี่ยนสีคือขีดที่ชี้ตัวเอง
    ///
    /// ราคาของการเลิกเป็น template คือหมึกที่ระบบเคยกลับให้ต้องเลือกเอง จึงต้องรู้
    /// appearance ของ *ปุ่มบนแถบเมนู* (ไม่ใช่ของแอป — แถบเมนูมืดได้ทั้งที่แอปสว่าง)
    /// และผู้เรียกต้องวาดใหม่เมื่อ appearance เปลี่ยน ไม่งั้นหมึกค้างเป็นสีของธีมก่อนหน้า
    ///
    /// ยกเว้นตอนเมนูเปิด (`highlighted`) ซึ่งระบบถมพื้นปุ่มด้วยสีเน้นแล้ววาดภาพที่ไม่ใช่
    /// template ทับตรงๆ — หมึกดำบนน้ำเงินอ่านไม่ออก ตอนนั้นกลับไปเป็น template
    /// เสียขีดแดงไปชั่วขณะที่ผู้ใช้กำลังอ่านเมนูอยู่แล้ว ดีกว่าเสียตัวเลขไปทั้งตัว
    static func make(_ badge: MenuBadge, highlighted: Bool, dark: Bool = false) -> NSImage {
        let template = !badge.isAlarming || highlighted
        // ขาวดำมาจาก isTemplate ไม่ใช่จากสีที่วาด — วาดดำแล้วระบบเก็บแค่ alpha ไปใช้
        // ส่วนภาพที่ไม่ใช่ template ต้องเลือกหมึกให้ตรงกับพื้นที่มันไปนั่งเอง
        let ink: NSColor = template || !dark ? .black : .white
        let text = "\(badge.percent)%" as NSString
        // ตัวเลขความกว้างคงที่ ไม่งั้นไอคอนขยับซ้ายขวาทุกครั้งที่เปอร์เซ็นต์เปลี่ยนหลัก
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: ink,
        ]
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: barWidth + gap + ceil(textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            // หดเข้ามาครึ่งเส้น เพราะ stroke วาดคร่อมเส้นทาง ครึ่งนอกจะถูกขอบภาพตัดทิ้ง
            let shell = NSRect(
                x: border / 2, y: (height - barHeight) / 2 + border / 2,
                width: barWidth - border, height: barHeight - border)
            let outline = NSBezierPath(roundedRect: shell, xRadius: radius, yRadius: radius)

            // เนื้อแถบอยู่ในกรอบ ไม่ใช่*เป็น*กรอบ — เว้นขอบในทั้งสี่ด้านเท่ากัน
            let inset = border / 2 + padding
            let track = shell.insetBy(dx: inset, dy: inset)
            let trackPath = NSBezierPath(
                roundedRect: track, xRadius: max(0, radius - inset),
                yRadius: max(0, radius - inset))
            // รางจางแต่ยังเห็น — แถบที่ไม่มีรางบอกไม่ได้ว่า 20% นี้คือ 20% ของเท่าไร
            ink.withAlphaComponent(0.25).setFill()
            trackPath.fill()

            let filled = track.width * CGFloat(min(100, max(0, badge.percent))) / 100
            if filled > 0 {
                // ตัดด้วย clip ไม่ใช่วาดรางที่แคบลง ไม่งั้นปลายซ้ายของเนื้อแถบ
                // จะโค้งตามความยาวของตัวเอง แทนที่จะโค้งตามราง
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(
                    rect: NSRect(
                        x: track.minX, y: track.minY, width: filled, height: track.height)
                ).setClip()
                ink.setFill()
                trackPath.fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // ขีด "ควรใช้ถึงไหนแล้ว" — อยู่ขวาของเนื้อแถบ = ใช้ช้ากว่าเวลา
            // อยู่ซ้าย = ใช้เร็วเกินไป ภาษาเดียวกับแผงบนบอร์ด
            //
            // สูงเท่าแถบพอดี จึงพาดผ่านเนื้อแถบเต็มๆ ได้ — ตรงที่ทับเนื้อจะเจาะเป็นร่องโปร่ง
            // แทนการวาดหมึกทับหมึกซึ่งมองไม่เห็น ส่วนตรงที่อยู่บนรางว่างยังวาดด้วยหมึก
            if badge.pace != MenuBadge.unknown {
                let pace = CGFloat(min(100, max(0, badge.pace))) / 100
                let at = min(track.minX + track.width * pace, shell.maxX - border / 2)
                let mark = NSRect(
                    x: at, y: shell.minY - border / 2, width: border, height: barHeight)
                NSGraphicsContext.saveGraphicsState()
                if !template {
                    // ภาพนี้ไม่ใช่ template ก็ต่อเมื่อเนื้อแถบแซงขีดไปแล้ว — ตรงนี้จึงเป็น
                    // ขีดที่จมอยู่ในเนื้อแถบเสมอ แดงทับลงไปตรงๆ เห็นชัดกว่าร่องโปร่ง
                    // และเป็นสิ่งเดียวในภาพที่เปลี่ยนสี
                    NSColor.systemRed.setFill()
                } else if badge.pace <= badge.percent {
                    NSGraphicsContext.current?.compositingOperation = .clear
                } else {
                    ink.setFill()
                }
                NSBezierPath(rect: mark).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // ขอบทึบวาดท้ายสุด — บนพื้นแถบเมนูที่มีวอลเปเปอร์อยู่ข้างหลัง รางจางๆ อย่างเดียว
            // หายไปกับพื้น เส้นขอบคือสิ่งที่บอกว่าแถบเริ่มและจบตรงไหน
            //
            // ต้องมาหลังขีด pace: ขีดที่สูงเท่าแถบพาดทับเส้นขอบบนล่างด้วย และร่องโปร่ง
            // ที่เจาะทะลุขอบทำให้กรอบขาดเป็นสองท่อน วาดขอบทับทีหลังจึงได้ทั้งขีดเต็มความสูง
            // และกรอบที่ยังเป็นกรอบ
            ink.setStroke()
            outline.lineWidth = border
            outline.stroke()

            text.draw(
                at: NSPoint(x: barWidth + gap, y: (height - textSize.height) / 2),
                withAttributes: attributes)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = description(badge)
        return image
    }

    static func description(_ badge: MenuBadge) -> String {
        let used = "\(badge.percent)% of the 5 hour window used"
        guard badge.pace != MenuBadge.unknown else { return used }
        // ขีดบนภาพบอกเรื่องนี้กับตา คำอธิบายต้องบอกเรื่องเดียวกันกับคนที่ไม่ได้ใช้ตาอ่าน
        return used + ", \(badge.pace)% of the window elapsed"
    }
}

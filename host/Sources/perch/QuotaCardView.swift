import AppKit
import PerchCore

/// การ์ดโควตาหนึ่งใบ — หัวแถว, คำอธิบาย, แถบพร้อมขีด pace, แล้วเวลารีเซ็ต
///
/// อยู่คนละไฟล์กับ `PanelViewController` ด้วยเหตุผลเดียวกับ `MenuBadgeImage`:
/// ไฟล์นั้นเปลี่ยนเมื่อโครงของแผงเปลี่ยน ไฟล์นี้เปลี่ยนเมื่อหน้าตาของการ์ดเปลี่ยน
/// สิ่งที่*พูด* อยู่ที่ `QuotaCard` ใน PerchCore ที่นี่มีแต่วิธีวาด
final class QuotaCardView: NSView {
    /// สามขั้นเดียวกับบอร์ด แต่ใช้สีของระบบ ไม่ใช่ค่าจาก `tools/layout.toml`
    ///
    /// พาเลตต์ของบอร์ดถูกจูนมาสำหรับ TFT 320x240 ที่หรี่ไฟหลังอยู่บนโต๊ะในห้องที่มีไฟ
    /// สีเดียวกันนั้นบนพื้นดำของ popover อ่านเป็นสีขุ่น ไม่ใช่สัญญาณ · สีระบบยังตามธีม
    /// สว่าง/มืด และการตั้งค่าการเข้าถึง (increase contrast, differentiate without colour)
    /// ให้เอง ซึ่งค่าคงที่ทำไม่ได้ · เกณฑ์ที่ *เลือก* สียังเป็นของบอร์ดทั้งหมด (`QuotaCard`)
    static func color(_ level: QuotaCard.Level) -> NSColor {
        switch level {
        case .good: return .systemGreen
        case .warn: return .systemOrange
        case .crit: return .systemRed
        // ไม่รู้ = สีของข้อความจาง ไม่ใช่เขียว — สีที่ดูปลอดภัยบนค่าที่ไม่มีคือการโกหก
        case .unknown: return .tertiaryLabelColor
        }
    }

    private let title = NSTextField(labelWithString: "")
    private let pill = PillView()
    private let subtitle = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let bar = QuotaBarView()
    private let reset = NSTextField(labelWithString: "")

    /// ระยะจากเส้นขอบถึงเนื้อการ์ด — น้อยกว่านี้ตัวอักษรอ่านเหมือนติดกรอบ
    private static let pad: CGFloat = 12

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // เส้นขอบบางๆ ทำให้การ์ดเป็น *ก้อน* ไม่ใช่ข้อความสองบล็อกที่บังเอิญอยู่ใกล้กัน
        // ระยะห่างอย่างเดียวบอกว่า "คนละกลุ่ม" ได้ก็จริง แต่ต้องกินที่มากกว่าเส้น 1 px
        // ในแผงที่มีของสี่ชั้นซ้อนกันอยู่แล้ว
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        applyColors()

        // ทุกบรรทัดในการ์ดต้องสูงเท่าตัวหนังสือของมันเสมอ — ค่าปริยาย (750) แพ้ขอบล่างของ
        // การ์ด (999 ดูข้างล่าง) ผลคือกรอบที่เตี้ยกว่ากดหัวการ์ดจนสูงเป็นศูนย์ ชื่อกับ
        // เปอร์เซ็นต์หายไปทั้งแถวโดยที่การ์ดยังดูปกติ ซึ่งอ่านไม่ออกว่ามีอะไรหายไป
        for line in [title, subtitle, percent, reset] {
            line.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        // ชื่อใหญ่กว่าทุกอย่างในการ์ด — มันคือสิ่งที่ตาจับก่อนแล้วค่อยไล่ลงมาหาเลข
        title.font = .systemFont(ofSize: 14, weight: .bold)

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        // ตัวเลขความกว้างคงที่ ไม่งั้นเปอร์เซ็นต์ขยับซ้ายขวาทุกครั้งที่เปลี่ยนหลัก
        // ในแผงที่วาดใหม่ทุกวินาที
        percent.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        percent.alignment = .right
        percent.setContentHuggingPriority(.required, for: .horizontal)
        percent.setContentCompressionResistancePriority(.required, for: .horizontal)

        reset.font = .systemFont(ofSize: 11)
        reset.textColor = .secondaryLabelColor
        reset.lineBreakMode = .byTruncatingTail

        // ตัวคั่นต้องยอมยืดก่อนใคร ไม่งั้นความกว้างที่เหลือถูกแบ่งกับ label แล้วเปอร์เซ็นต์
        // ไม่ชิดขวาจริงเวลาชื่อสั้น
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let head = NSStackView(views: [title, pill, spacer, percent])
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .centerY
        // หัวการ์ดต้องไม่ยอมถูกบีบสูงเป็นศูนย์ — ค่าปริยายของ NSStackView ยอมให้กรอบที่เตี้ย
        // กว่ากดแถวจนหายไปทั้งแถว ผลคือชื่อกับเปอร์เซ็นต์หายพร้อมกัน เหลือแต่คำอธิบาย
        // แถบ และเวลารีเซ็ต ซึ่งอ่านไม่ออกว่านี่คือหน้าต่างไหน (ดู `stack` ข้างล่างด้วย)
        head.setClippingResistancePriority(.required, for: .vertical)

        // คำอธิบายอยู่ *ใต้* ชื่อ ไม่ใช่ต่อท้ายในบรรทัดเดียว — บรรทัดเดียวทำให้ชื่อ
        // กับคำอธิบายแย่งกันเป็นสิ่งที่อ่านก่อน และบีบเปอร์เซ็นต์จนไม่ชิดขวาเวลาชื่อยาว
        let stack = NSStackView(views: [head, subtitle, bar, reset])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.setCustomSpacing(2, after: head)
        // เนื้อการ์ดยอมล้นออกนอกกรอบ แต่ไม่ยอมหดตัวเอง — ตัวที่ควรหักตอนที่กรอบเตี้ยกว่า
        // ที่ควรเป็นคือความสูงของการ์ด (ขอบล่างที่ปล่อยให้หักไว้แล้วข้างล่าง)
        // ไม่ใช่แถวใดแถวหนึ่งในนั้นหายไปเงียบๆ
        stack.setClippingResistancePriority(.required, for: .vertical)
        // ไม่ยืดตามกรอบที่สูงเกินด้วย — ที่เกินมาต้องไปอยู่ท้ายแผง ไม่ใช่กลายเป็นช่องว่าง
        // ก้อนใหญ่กลางการ์ดที่อ่านเหมือนมีอะไรหายไปจากการ์ด
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pad = Self.pad
        // ขอบล่างหักได้ ด้วยเหตุผลเดียวกับขอบล่างของแผง (`PanelViewController`): ถ้าการ์ด
        // ถูกกรอบที่เตี้ยกว่าบีบ ตัวที่ยอมหักต้องเป็นความสูงของการ์ด ไม่ใช่ระยะห่างภายใน
        // — ไม่งั้นหัวการ์ดกับแถบจะไต่ขึ้นไปโผล่เหนือเส้นขอบของการ์ดตัวเอง
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad)
        bottom.priority = .init(999)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            bottom,
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // สูงกว่าตัวแถบ เผื่อที่ให้ขีดที่โผล่พ้นบนล่าง — แถบวาดกลางกรอบของตัวเอง
            bar.heightAnchor.constraint(equalToConstant: QuotaBarView.boxHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// `CGColor` ไม่ใช่ dynamic color — มันถูกคลี่เป็นสีจริงตอนที่ตั้ง ไม่ใช่ตอนวาด
    /// สลับ Light/Dark แล้วขอบจะค้างเป็นสีของธีมก่อนหน้า ทางที่ AppKit เตรียมไว้ให้คือ
    /// `updateLayer` ซึ่งถูกเรียกใหม่เมื่อธีมเปลี่ยน โดยมี appearance ที่ถูกต้องตั้งไว้แล้ว
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColors()
    }

    private func applyColors() {
        // `separatorColor` เป็นเส้นสำหรับพื้นสว่างของหน้าต่างปกติ บนพื้นดำของ popover
        // มันจางจนขอบการ์ดกลืนไปกับพื้น แล้วการ์ดสองใบอ่านเป็นข้อความสี่ก้อนที่ไม่รู้ว่า
        // ก้อนไหนคู่กับก้อนไหน · `tertiary` คือระดับที่ยังเป็นเส้นบางๆ ไม่ใช่กรอบที่ดังกว่า
        // ตัวเลขข้างใน และยังตามธีมสว่าง/มืดกับ increase contrast ให้เอง
        layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        // พื้นจางกว่าแผงนิดเดียว — การ์ดที่มีพื้นเป็นของตัวเองเต็มๆ กลายเป็นกล่องซ้อนกล่อง
        // ซึ่งดังกว่าสิ่งที่มันมีไว้บอก · แต่ 0.06 ของสีที่จางอยู่แล้วคือแทบไม่มีพื้นเลย
        // เส้นขอบจึงต้องแบกงานทั้งหมดคนเดียว
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
    }

    func show(_ card: QuotaCard) {
        title.stringValue = card.title
        subtitle.stringValue = card.subtitle
        // บรรทัดว่างยังกินระยะห่างของ stack — การ์ดที่ไม่มีคำอธิบายจะมีช่องลอยๆ
        subtitle.isHidden = card.subtitle.isEmpty
        pill.text = card.pill
        reset.stringValue = card.reset

        let color = Self.color(card.level)
        // `--%` ไม่ใช่ `0%` — ศูนย์เป็นค่าที่วัดได้จริง ความไม่รู้ต้องหน้าตาไม่เหมือนมัน
        percent.stringValue = card.percent == UsageSnap.unknown ? "--%" : "\(card.percent)%"
        percent.textColor = color

        bar.percent = card.percent
        bar.pace = card.pace
        bar.color = color
        bar.needsDisplay = true
    }
}

/// ป้ายเล็กข้างชื่อ — บอกความยาวของหน้าต่างโดยไม่ต้องมีบรรทัดคำอธิบายเป็นของตัวเอง
///
/// สีคงที่ ไม่ตามระดับการใช้ ด้วยเหตุผลเดียวกับ pill บนบอร์ด: ป้ายบอก*ว่านี่คือหน้าต่างไหน*
/// ซึ่งไม่เคยเปลี่ยน ถ้ามันเปลี่ยนสีตามด้วย ทั้งการ์ดจะเป็นสีเดียวกันตอนวิกฤต
/// แล้วสีก็หยุดเป็นสัญญาณ
final class PillView: NSView {
    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            isHidden = text == nil
        }
    }

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor
    }
}

/// แถบวัดกับขีด pace — ภาษาเดียวกับแถบบนแถบเมนูและบนบอร์ด
///
/// ขีดอยู่ที่ `elapsed/window` เสมอ ไม่ว่าจะแซงหรือไม่: สีตอบว่ามีปัญหาไหม
/// ขีดตอบว่าห่างแค่ไหน ซึ่งเป็นคำถามที่สีตอบไม่ได้
final class QuotaBarView: NSView {
    /// บางกว่าแถบบนแถบเมนู — ที่นี่มีชื่อ เปอร์เซ็นต์ และเวลารีเซ็ตช่วยกันพูดอยู่แล้ว
    /// แถบหนาจะกลายเป็นสิ่งที่ดังที่สุดในการ์ดทั้งที่บอกน้อยที่สุด
    static let height: CGFloat = 6
    /// ขีดโผล่พ้นแถบทั้งบนและล่าง — ขีดที่สูงเท่าแถบพอดีหายไปในเนื้อแถบเวลาสีใกล้กัน
    private static let markOverhang: CGFloat = 3
    private static let markWidth: CGFloat = 2
    /// กรอบของ view สูงกว่าตัวแถบ เพื่อให้ขีดมีที่ยืนโดยไม่ต้องล้นออกไปทับของข้างเคียง
    static var boxHeight: CGFloat { height + 2 * markOverhang }

    var percent = UsageSnap.unknown
    var pace = UsageSnap.unknown
    var color: NSColor = .tertiaryLabelColor

    /// ขีดล้นกรอบของตัวเอง จึงต้องบอก AppKit ว่าอย่าตัด ไม่งั้นหัวท้ายของขีดหายไป
    override var wantsDefaultClipping: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: (bounds.height - Self.height) / 2,
                         width: bounds.width, height: Self.height)
        let radius = Self.height / 2
        let track = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        // รางยังต้องเห็นแม้ไม่มีค่า — แถบที่หายไปทั้งอันอ่านเหมือนแผงวาดไม่เสร็จ
        //
        // `tertiary` ไม่ใช่ `quaternary`: รางไม่ได้วาดบนพื้นแผง แต่วาดบนพื้นการ์ดที่จาง
        // อยู่แล้วอีกที ระดับจางที่สุดซ้อนบนของจางจึงกลืนไปกับพื้น — ส่วนที่ยังไม่ถูกใช้
        // หายไปทั้งท่อน แล้วเนื้อแถบอ่านเป็นขีดลอยๆ ที่ไม่รู้ว่ายาวเทียบกับอะไร
        NSColor.tertiaryLabelColor.setFill()
        track.fill()

        if percent != UsageSnap.unknown {
            let filled = bar.width * CGFloat(min(100, max(0, percent))) / 100
            if filled > 0 {
                // ตัดด้วย clip ไม่ใช่วาดรางที่แคบลง ไม่งั้นปลายซ้ายของเนื้อแถบจะโค้ง
                // ตามความยาวของตัวเอง แทนที่จะโค้งตามราง
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(
                    rect: NSRect(x: bar.minX, y: bar.minY, width: filled, height: bar.height)
                ).setClip()
                color.setFill()
                track.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        guard pace != UsageSnap.unknown else { return }
        // ที่นี่วาดบนพื้นทึบของแผง จึงใช้สีข้อความทับลงไปตรงๆ ได้ ไม่ต้องเจาะร่องโปร่ง
        // อย่างบนแถบเมนู (ที่นั่นพื้นหลังคือวอลเปเปอร์ของผู้ใช้)
        let at = bar.width * CGFloat(min(100, max(0, pace))) / 100
        let width = Self.markWidth
        // ขีดที่ 0% หรือ 100% ครึ่งหนึ่งจะอยู่นอกแถบ — ดันเข้ามาให้เห็นเต็มเส้น
        let x = min(max(bar.minX, at - width / 2), bar.maxX - width)
        let mark = NSRect(
            x: x, y: bar.minY - Self.markOverhang, width: width,
            height: bar.height + 2 * Self.markOverhang)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: mark, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

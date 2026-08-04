import AppKit
import PerchCore

/// หน้าตาของ popover ที่เด้งจากไอคอนแถบเมนู
///
/// อยู่คนละไฟล์กับ `MenuBarApp` ด้วยเหตุผลเดียวกับ `MenuBadgeImage`: ไฟล์นั้นเปลี่ยน
/// เมื่อการต่อสายระหว่าง daemon กับ UI เปลี่ยน ไฟล์นี้เปลี่ยนเมื่อหน้าตาของแผงเปลี่ยน
///
/// โครงคือ หัว / เนื้อ / ท้าย โดยเนื้อคือการ์ดโควตาสองใบกับบรรทัดอายุของค่า
final class PanelViewController: NSViewController {
    /// ปุ่มเฟืองไม่รู้ว่าเมนูมีอะไร — `MenuBarApp` เป็นเจ้าของ NSMenu ตัวนั้น
    var onGear: ((NSButton) -> Void)?
    /// ลูกศรข้างชื่อ org ก็เหมือนกัน — รายการ org อยู่ที่ poller ไม่ใช่ที่แผง
    var onOrgs: ((NSButton) -> Void)?
    /// ปุ่ม refresh — วินัยของมัน (กดได้ไหม เย็นตัวหรือยัง) อยู่ที่ `RefreshControl`
    var onRefresh: (() -> Void)?
    /// บรรทัด "key หมดอายุ" กดได้ — ที่ที่บอกว่าพังคือที่ที่ควรแก้ได้
    var onKeyProblem: (() -> Void)?

    private static let width: CGFloat = 260
    private static let inset: CGFloat = 14
    /// ที่ยืนของปุ่ม refresh — ปุ่มกับตัวหมุนสลับกันอยู่ในกรอบเดียวขนาดคงที่ ไม่งั้นหัวแผง
    /// ขยับทุกครั้งที่เริ่มยิงและทุกครั้งที่ยิงจบ
    private static let iconSize: CGFloat = 16

    /// ชื่อ org ที่ตัวเลขมาจาก — ชื่อแอปตอนที่ยังไม่มี org ให้พูดถึง
    private let heading = NSTextField(labelWithString: PanelText.appName)
    private let orgs = NSButton()
    private let refresh = NSButton()
    private let spinner = NSProgressIndicator()
    private let gear = NSButton()
    /// การ์ดสองใบ — ใบเดิมสองใบตลอดอายุแผง เปลี่ยนแต่เนื้อใน การสร้างใหม่ทุกวินาที
    /// คือการทิ้ง view ทุกวินาทีเพื่อผลลัพธ์หน้าตาเดียวกัน
    private let sessionCard = QuotaCardView()
    private let weeklyCard = QuotaCardView()
    private let cards = NSStackView()
    private let boardLabel = NSTextField(labelWithString: "")
    /// สองบรรทัดที่พูดคนละเรื่อง: ท่อพัง (กดได้) กับ ค่าที่เห็นอยู่เก่าแค่ไหน
    private let keyButton = NSButton()
    /// บรรทัดที่สาม: สวิตช์ auto-start ติ๊กอยู่แต่ยิงไม่ได้ — ป้ายเฉยๆ ไม่ใช่ปุ่ม เพราะสิ่งที่
    /// ต้องทำเพื่อแก้ (ติดตั้ง/login `claude`) อยู่นอกแอปทั้งหมด ปุ่มที่กดแล้วไม่มีอะไร
    /// เกิดขึ้นคือคำสัญญาที่ผิด ต่างจากบรรทัด key ที่กดแล้วได้ช่องกรอกจริง
    private let startLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let sessions = NSStackView()
    private var shownRows: [String] = []

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        // ส่วนที่ล้นออกนอกกรอบต้องถูกตัด ไม่ใช่ไปวาดทับขอบมนของ popover
        root.clipsToBounds = true

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        // ชื่อ org ยาวได้ตามใจคนตั้ง — ปุ่มทางขวาต้องไม่ถูกดันตกขอบแผงไปด้วย
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        icon(orgs, "chevron.up.chevron.down", "Switch organization", #selector(orgsClicked))
        orgs.isHidden = true

        icon(refresh, "arrow.clockwise", "Refresh", #selector(refreshClicked))
        // ปุ่มนี้ทำงานตอน *ปล่อย* ต่างจากอีกสองปุ่มที่เด้งเมนู — มันยิงจริง ไม่ได้กางอะไร
        // และการยิงที่เริ่มตอนกดลงคือการยิงที่ยกเลิกไม่ได้
        refresh.cell?.sendAction(on: .leftMouseUp)

        spinner.style = .spinning
        spinner.controlSize = .small
        // หยุดแล้วต้องหายไปเอง ไม่งั้นวงกลมจางๆ ค้างทับปุ่มที่กดได้อยู่
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        icon(gear, "gearshape", "Settings", #selector(gearClicked))

        // ปุ่มกับตัวหมุนซ้อนกันในกรอบเดียว — สลับด้วย isHidden แล้วหัวแผงจะขยับ
        // เพราะ stack ไม่นับ view ที่ซ่อนอยู่
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(refresh)
        holder.addSubview(spinner)

        let header = NSStackView(views: [heading, orgs, NSView(), holder, gear])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 6

        cards.setViews([sessionCard, weeklyCard], in: .top)
        cards.orientation = .vertical
        cards.spacing = 10
        cards.alignment = .leading
        // ซ่อนไว้จนกว่าจะมีค่าจริง — stack ที่ว่างยังกินระยะห่างของ stack ที่ครอบมันอยู่
        // และการ์ดเปล่าสองใบอ่านได้ว่าอุปกรณ์พัง ทั้งที่ยังไม่เคยมีตัวเลขมาถึง
        cards.isHidden = true

        boardLabel.font = .systemFont(ofSize: 12)
        boardLabel.textColor = .secondaryLabelColor

        sessions.orientation = .vertical
        sessions.spacing = 2
        sessions.alignment = .leading

        keyButton.isBordered = false
        keyButton.target = self
        keyButton.action = #selector(keyProblemClicked)
        keyButton.contentTintColor = .systemOrange
        keyButton.font = .systemFont(ofSize: 12)
        keyButton.alignment = .left
        keyButton.isHidden = true

        startLabel.font = .systemFont(ofSize: 12)
        startLabel.textColor = .systemOrange
        startLabel.lineBreakMode = .byTruncatingTail
        startLabel.isHidden = true

        ageLabel.font = .systemFont(ofSize: 12)
        ageLabel.textColor = .secondaryLabelColor

        // เหตุผลเดียวกับบรรทัดในการ์ด (`QuotaCardView`): ค่าปริยาย (750) แพ้ขอบล่างของแผง
        // (999) กรอบที่เตี้ยกว่าจึงกดบรรทัดจนสูงศูนย์แทนที่จะปล่อยให้ล้นออกไปโดนตัด
        // — บรรทัดที่หายไปเงียบๆ อ่านเหมือนแอปไม่รู้อะไรเลย ต่างจากบรรทัดที่ถูกตัดครึ่ง
        for line in [boardLabel, ageLabel, startLabel] {
            line.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        // อายุของค่าอยู่ใต้การ์ด ไม่ใช่ท้ายแผง — มันเป็นคำอธิบายของตัวเลขที่อยู่เหนือมัน
        // ("เลขนี้ค้างหรือเปล่า") ไม่ใช่สถานะของแอปแบบเดียวกับบรรทัดบอร์ดหรือรายการ session
        let body = NSStackView(views: [cards, ageLabel])
        body.orientation = .vertical
        body.spacing = 8
        body.alignment = .leading

        // ทั้งสองบรรทัดพังอยู่บนสุดของท้ายแผง เรียงตามลำดับที่ผู้ใช้ต้องลงมือ: ไม่มี key
        // แปลว่าไม่มีตัวเลขเลย ส่วน auto-start ที่ยิงไม่ได้แค่แปลว่าตัวเลขจะไม่ขยับเอง
        let footer = NSStackView(views: [keyButton, startLabel, boardLabel, sessions])
        footer.orientation = .vertical
        footer.spacing = 4
        footer.alignment = .leading

        let stack = NSStackView(views: [header, body, separator(), footer])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        // กรอบของ popover กับความสูงที่เนื้อในต้องการไม่เท่ากันเสมอ (ดู `resize`) และค่าปริยาย
        // ของ NSStackView คือ "กรอบชนะ": สูงเกินก็ยืดของข้างในให้เต็ม เตี้ยไปก็บีบจนแถวหาย
        // ทั้งสองทางทำให้แผงโกหก — ช่องว่างก้อนใหญ่กลางการ์ด และหัวการ์ดที่หายไปทั้งแถว
        // ที่นี่จึงบอกว่าเนื้อในไม่ยืดและไม่ยอมถูกบีบ ส่วนที่เกินไปล้นออกไปโดนตัดแทน
        for group in [stack, body, cards] {
            group.setHuggingPriority(.required, for: .vertical)
            group.setClippingResistancePriority(.required, for: .vertical)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        // เนื้อในสูงเท่าไรก็ตาม ต้องไม่ถูกกรอบที่เตี้ยกว่าบีบ — `NSPopover` ตั้งขนาด
        // content view ตามที่ *เคย* บอกไว้ ส่วนความสูงจริงของเนื้อในเปลี่ยนได้ทีหลัง
        // (การ์ดโผล่, แถวเพิ่ม) ในจังหวะที่คร่อมกันนั้น ถ้าขอบล่างเป็นข้อบังคับเด็ดขาด
        // ตัวที่ยอมหักคือระยะห่างระหว่าง view — หัวแผงกับการ์ดใบแรกทับกันเป็นสิบเฟรม
        // ปล่อยให้ขอบล่างหักแทน แล้วส่วนเกินจะล้นออกไปโดนตัด ซึ่งอ่านออกว่า "ยังไม่นิ่ง"
        // ไม่ใช่ "แผงพัง"
        let inset = Self.inset
        let bottom = stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
        bottom.priority = .init(999)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            bottom,
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            holder.widthAnchor.constraint(equalToConstant: Self.iconSize),
            holder.heightAnchor.constraint(equalToConstant: Self.iconSize),
            refresh.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            refresh.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: Self.iconSize),
            spinner.heightAnchor.constraint(equalToConstant: Self.iconSize),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cards.widthAnchor.constraint(equalTo: body.widthAnchor),
            sessionCard.widthAnchor.constraint(equalTo: cards.widthAnchor),
            weeklyCard.widthAnchor.constraint(equalTo: cards.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        // view ถูกโหลดตอนแผงเปิดครั้งแรก ซึ่งช้ากว่า snapshot แรกเสมอ — แถวที่มาก่อนหน้านั้น
        // อยู่ใน `sessions` แล้วและต้องรอด ตัวนี้เผื่อไว้เฉพาะกรณีที่ยังไม่เคยมี snapshot เลย
        if shownRows.isEmpty { showSessions(Snapshot(clock: "", date: "")) }
    }

    /// ปุ่มไอคอนล้วนสามตัวในหัวแผงตั้งเหมือนกันหมด ต่างกันแค่รูปกับสิ่งที่มันทำ
    ///
    /// ปุ่มที่เด้งเมนูทำงานตอน *กดลง* เหมือนปุ่มที่มีเมนูทุกตัวใน macOS — ผู้เรียกที่ต้องการ
    /// อย่างอื่นเปลี่ยนทีหลังได้
    private func icon(
        _ button: NSButton, _ symbol: String, _ label: String, _ action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.cell?.sendAction(on: .leftMouseDown)
    }

    /// บอกความสูงที่เนื้อในต้องการใหม่ หลังจากอะไรก็ตามที่ทำให้มันเปลี่ยน
    ///
    /// NSPopover โตตาม autolayout ได้ แต่ไม่หดกลับเอง — ความสูงสูงสุดที่มันเคยโตค้างอยู่
    /// จนปิดแผง แถวที่หายไป (session ปิด, บรรทัด key พังที่ซ่อนตัว, การ์ดที่ซ่อน)
    /// จึงกลายเป็นช่องว่างท้ายแผงแทนที่จะหายไปด้วย
    private func resize() {
        // ถูกเรียกได้ก่อน view โหลด — snapshot แรกมาถึงก่อนที่ผู้ใช้จะเปิดแผงเสมอ
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        // จัดใหม่ทันทีในเฟรมเดียวกัน ไม่ปล่อยให้ค้างข้ามรอบ run loop — ระหว่างนั้น
        // กรอบใหม่มาถึงแล้วแต่ของข้างในยังอยู่ที่เดิม ซึ่งคือเฟรมที่ผู้ใช้จับภาพได้
        view.layoutSubtreeIfNeeded()
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset).isActive = true
        return line
    }

    @objc private func gearClicked() {
        onGear?(gear)
    }

    @objc private func orgsClicked() {
        onOrgs?(orgs)
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }

    /// หัวแผง — ชื่อ org ที่ตัวเลขมาจาก และลูกศรเมื่อมีอะไรให้สลับ
    func showHeading(_ title: String, switchable: Bool) {
        // แตะเฉพาะตอนเปลี่ยนจริง: ถูกเรียกทุกวินาทีที่แผงเปิดอยู่ และการเขียนทับด้วยค่าเดิม
        // ทำให้ NSTextField วาดใหม่ทั้งบรรทัด
        if heading.stringValue != title { heading.stringValue = title }
        // ลูกศรที่โผล่มาทีหลัง (รายการ org มาจากรอบ poll ไม่ใช่ตอนเปิดแผง) เปลี่ยนความ
        // ต้องการของหัวแผง — ขนาดที่บอก popover ไว้ต้องเปลี่ยนตามในจังหวะเดียวกัน
        if orgs.isHidden == switchable {
            orgs.isHidden = !switchable
            resize()
        }
    }

    /// ปุ่ม refresh — สามสภาพ: กดได้ · กำลังยิง · เย็นตัวอยู่
    ///
    /// ตอนกำลังยิงคือตัวหมุนแทนที่ปุ่ม ไม่ใช่ปุ่มที่จางลงเฉยๆ — ปุ่มจางอ่านได้ว่า
    /// "กดไม่ได้ตอนนี้" ซึ่งเป็นสภาพเดียวกับตอนเย็นตัว ทั้งที่สองอย่างนี้ต่างกัน
    func showRefresh(_ state: RefreshState) {
        refresh.isEnabled = state.enabled
        refresh.isHidden = state.spinning
        refresh.toolTip = state.tooltip
        if state.spinning {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        spinner.toolTip = state.tooltip
    }

    @objc private func keyProblemClicked() {
        onKeyProblem?()
    }

    /// บรรทัดท่อพังโผล่เฉพาะตอนพัง ส่วนบรรทัดอายุของค่ามีตลอด — ค่าที่ไม่มีก็เป็นอายุแบบหนึ่ง
    ///
    /// `detail` คือสิ่งที่ตัวยิงพูดล่าสุด (`HTTP 503`, บรรทัดสรุป) อยู่ใน tooltip เพราะ
    /// เป็นคำตอบของคำถามที่นานๆ ถามที ("ทำไมค่าถึงเก่า") ไม่ใช่ของที่ต้องเห็นตลอดเวลา
    func showQuota(
        problem: String?, age: String, cards quota: [QuotaCard]?, detail: String? = nil
    ) {
        keyButton.isHidden = problem == nil
        keyButton.title = problem ?? ""
        ageLabel.stringValue = age
        ageLabel.toolTip = detail

        // `nil` = ไม่รู้อะไรเลยทั้งสองหน้าต่าง ซึ่งไม่ใช่ 0% สองใบ — ซ่อนทั้งช่อง
        // แล้วเหลือแต่บรรทัดอายุที่พูดว่ายังไม่เคยมีตัวเลข
        cards.isHidden = quota == nil
        defer { resize() }
        guard let quota else { return }
        // การ์ดมาเป็นคู่เสมอจาก `QuotaCard.cards` — ใบที่หายไปแปลว่าสัญญาเปลี่ยน ไม่ใช่ค่าหาย
        if let session = quota.first { sessionCard.show(session) }
        if quota.count > 1 { weeklyCard.show(quota[1]) }
    }

    /// บรรทัด "เริ่ม session เองไม่ได้" — โผล่เฉพาะตอนล็อก และหายไปเองเมื่อไม่ล็อกแล้ว
    ///
    /// `resize()` เฉพาะตอนบรรทัดโผล่หรือหายจริง: ถูกเรียกทุกวินาทีที่แผงเปิดอยู่ และ
    /// ความสูงของแผงไม่ได้เปลี่ยนเมื่อข้อความเดิมถูกเขียนทับด้วยตัวมันเอง
    func showStartProblem(_ text: String?, detail: String?) {
        let hidden = text == nil
        startLabel.stringValue = text ?? ""
        startLabel.toolTip = detail
        guard startLabel.isHidden != hidden else { return }
        startLabel.isHidden = hidden
        resize()
    }

    // MARK: - อัปเดตข้อความ

    func showBoard(route: LanRoute) {
        boardLabel.stringValue = PanelText.board(route: route)
    }

    /// วาดใหม่เฉพาะตอนข้อความเปลี่ยนจริง — ถูกเรียกทุก snapshot ซึ่งขยับทุกนาที
    /// ตามนาฬิกา ส่วนรายการ session เปลี่ยนนานๆ ครั้ง
    func showSessions(_ snapshot: Snapshot) {
        let rows = PanelText.sessions(snapshot)
        guard rows != shownRows else { return }
        shownRows = rows

        for old in sessions.arrangedSubviews {
            sessions.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        for row in rows {
            let label = NSTextField(labelWithString: row)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            sessions.addArrangedSubview(label)
        }
        resize()
    }
}

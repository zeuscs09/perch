import AppKit
import PerchCore

/// หน้าตั้งค่าเต็มรูป — ที่เดียวของทุกสวิตช์ที่เคยอยู่หลังปุ่มเฟือง
///
/// เมนูเฟืองรับหน้า WiFi ไม่ไหว: รายชื่อเครือข่ายยาวไม่แน่นอน มีช่องรหัสผ่านที่ต้องพิมพ์
/// และมีสถานะที่เปลี่ยนเองระหว่างที่ผู้ใช้มองอยู่ ทั้งสามอย่างเป็นสิ่งที่ `NSMenu` ทำไม่ได้
/// (เมนูปิดตัวเองทันทีที่คลิก และไม่มีที่ให้ข้อความสถานะยาวๆ)
///
/// controller ตัวนี้ไม่รู้จัก BLE, ไฟล์ หรือ UserDefaults เลย — ทุกอย่างเข้าออกผ่าน closure
/// ที่ `MenuBarApp` ผูกให้ เพื่อให้ที่เก็บสถานะจริงยังมีที่เดียวเหมือนเดิม
final class PreferencesWindowController: NSWindowController {
    // --- ทางออกไปหา MenuBarApp ---------------------------------------------
    var onSelectBoard: ((UUID?) -> Void)?
    var onBrightness: ((Int) -> Void)?
    var onInterval: ((PollInterval) -> Void)?
    var onSetSessionKey: (() -> Void)?
    var onInstallHooks: (() -> Void)?
    var onToggleStatusline: (() -> Void)?
    var onToggleLogin: (() -> Void)?
    var onToggleAutoStart: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onOpenProject: (() -> Void)?

    /// ค้นชื่อเมือง — ผลกลับมาทาง `showPlaces`
    var onSearchPlace: ((String) -> Void)?
    var onPickPlace: ((Weather.Place) -> Void)?
    var onClearPlace: (() -> Void)?

    var onScan: (() -> Void)?
    var onJoin: ((String, String) -> Void)?
    var onForget: ((String) -> Void)?
    /// ที่อยู่บอร์ดที่ผู้ใช้กรอกเอง — สตริงว่างคือกลับไปให้แอปหาเอง
    var onBoardHost: ((String) -> Void)?

    // --- General ------------------------------------------------------------
    private let boardPopup = NSPopUpButton()
    private let brightness = NSSlider(value: 100, minValue: 5, maxValue: 100, target: nil,
                                      action: nil)
    private let intervalPopup = NSPopUpButton()
    private let statuslineBox = NSButton(checkboxWithTitle: "Read quota from the statusline",
                                         target: nil, action: nil)
    private let autoStartBox = NSButton(checkboxWithTitle: "Auto-start a session when idle",
                                        target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil,
                                    action: nil)
    private let keyLabel = NSTextField(labelWithString: "")

    // --- ที่ตั้งสำหรับพยากรณ์อากาศ --------------------------------------------
    private let placeField = NSTextField()
    private let placeResults = NSPopUpButton()
    private let placeLabel = NSTextField(labelWithString: "")
    private var places: [Weather.Place] = []

    // --- Wi-Fi --------------------------------------------------------------
    private let statusLabel = NSTextField(labelWithString: "")
    private let ipLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let spinner = NSProgressIndicator()
    private let password = NSSecureTextField()
    private let joinButton = NSButton(title: "Connect", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget", target: nil, action: nil)
    private let hostField = NSTextField()
    private let routeLabel = NSTextField(labelWithString: "")

    private var boards: [Board] = []
    private var selectedBoard: UUID?
    private var list = NetworkList()
    private var status: WiFiStatus?
    private var linked = false
    private var route: LanRoute = .none

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Perch Settings"
        super.init(window: window)
        window.contentView = buildTabs()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // ปกติแอปนี้ไม่มีหน้าต่างเลย (`.accessory`) การเปิดหน้าตั้งค่าจึงต้องดึงแอปขึ้นมา
        // หน้าสุดเอง ไม่งั้นหน้าต่างโผล่หลังหน้าต่างของแอปอื่นแล้วดูเหมือนกดปุ่มไม่ติด
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        onScan?()
    }

    // --- โครงหน้าต่าง -------------------------------------------------------
    private func buildTabs() -> NSView {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = pad(buildGeneral())
        tabs.addTabViewItem(general)

        let wifi = NSTabViewItem(identifier: "wifi")
        wifi.label = "Wi-Fi"
        wifi.view = pad(buildWiFi())
        tabs.addTabViewItem(wifi)

        let container = NSView()
        container.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func pad(_ view: NSView) -> NSView {
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
        ])
        return host
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return stack
    }

    private func buildGeneral() -> NSView {
        boardPopup.target = self
        boardPopup.action = #selector(boardChanged)

        brightness.target = self
        brightness.action = #selector(brightnessChanged)
        brightness.isContinuous = false  // ส่งตอนปล่อยเมาส์ ไม่ใช่ทุกพิกเซลที่ลาก

        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        for interval in PollInterval.allCases {
            intervalPopup.addItem(withTitle: interval.title)
            intervalPopup.lastItem?.representedObject = interval.rawValue
        }

        let key = NSButton(title: "Set session key…", target: self,
                           action: #selector(setSessionKey))
        let hooks = NSButton(title: "Install hooks in settings.json", target: self,
                             action: #selector(installHooks))
        hooks.toolTip = "~/.claude/settings.json"
        let log = NSButton(title: "Open log", target: self, action: #selector(openLog))
        // ปลายทางอยู่ในชื่อปุ่ม ไม่ใช่คำว่า "GitHub" — แอปนี้ขอ credential เต็มบัญชี
        // ลิงก์ที่ซ่อนปลายทางไว้หลังคำสวยๆ เป็นท่าเดียวกับที่ผู้ใช้ควรระวัง
        let project = NSButton(title: PanelText.projectLink, target: self,
                               action: #selector(openProject))
        for button in [key, hooks, log, project] { button.bezelStyle = .rounded }

        for box in [statuslineBox, autoStartBox, loginBox] { box.target = self }
        statuslineBox.action = #selector(statuslineToggled)
        autoStartBox.action = #selector(autoStartToggled)
        loginBox.action = #selector(loginToggled)

        // ช่องกรอก key เป็นแบบปิดบังตัวอักษรและไม่เคยถูกเติมกลับ บรรทัดนี้จึงเป็น
        // ทางเดียวที่ผู้ใช้รู้ว่ากด Save แล้วเข้าไหม
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            row("Board", boardPopup),
            row("Brightness", brightness),
            row("Refresh quota", intervalPopup),
            row("Session key", key),
            row("", keyLabel),
            separator(),
            row("Weather", buildPlaceSearch()),
            row("", placeResults),
            row("", placeLabel),
            separator(),
            row("", statuslineBox),
            row("", autoStartBox),
            row("", loginBox),
            separator(),
            row("", hooks),
            row("", log),
            row("", project),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    /// ช่องค้นเมือง + ปุ่มปิดฟีเจอร์
    ///
    /// ปุ่ม Off อยู่ตรงนี้ ไม่ใช่ในเมนูซ่อน เพราะ "ไม่ตั้งพิกัด" คือสถานะเดียวที่ daemon
    /// ไม่ยิงเน็ตออกนอกเครื่องเลย ผู้ใช้ควรกลับไปหามันได้ง่ายพอๆ กับตอนเปิด
    private func buildPlaceSearch() -> NSView {
        placeField.placeholderString = "City name, e.g. Chiang Mai"
        placeField.target = self
        placeField.action = #selector(searchPlace)   // กด Enter ในช่อง = ค้น
        placeField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let find = NSButton(title: "Search", target: self, action: #selector(searchPlace))
        let off = NSButton(title: "Off", target: self, action: #selector(clearPlace))
        for button in [find, off] { button.bezelStyle = .rounded }
        off.toolTip = "Stop showing weather — the app stops calling the network"

        placeResults.target = self
        placeResults.action = #selector(placePicked)
        placeResults.isHidden = true
        placeResults.widthAnchor.constraint(equalToConstant: 280).isActive = true

        placeLabel.font = .systemFont(ofSize: 11)
        placeLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [placeField, find, off])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func buildWiFi() -> NSView {
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        ipLabel.font = .systemFont(ofSize: 11)
        ipLabel.textColor = .secondaryLabelColor

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ssid")))
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(join)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        rescan.bezelStyle = .rounded
        joinButton.target = self
        joinButton.action = #selector(join)
        joinButton.bezelStyle = .rounded
        joinButton.keyEquivalent = "\r"
        forgetButton.target = self
        forgetButton.action = #selector(forget)
        forgetButton.bezelStyle = .rounded

        password.placeholderString = "Network password"

        let buttons = NSStackView(views: [rescan, spinner, NSView(), forgetButton, joinButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        // เขียนไว้ตรงนี้ ไม่ใช่ในกล่องข้อผิดพลาดตอนล้ม — เน็ตที่เปิด client isolation
        // (โรงแรม ออฟฟิศ) ให้บอร์ดขึ้นเน็ตได้ตามปกติแล้วเงียบทีหลัง ผู้ใช้ควรรู้ล่วงหน้า
        let hint = NSTextField(wrappingLabelWithString:
            "The board only talks to this Mac over your LAN — it never contacts claude.ai "
            + "itself, so your session key stays here. Networks that isolate clients from "
            + "each other will connect but stay unreachable.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        routeLabel.font = .systemFont(ofSize: 11)
        routeLabel.textColor = .secondaryLabelColor

        // ช่องกรอกที่อยู่เอง: mDNS เป็นสิ่งแรกที่หายไปเมื่อมี VLAN ของแขก, subnet ที่สอง
        // หรือเราเตอร์ที่กรอง multicast — และตอนนั้น BLE ก็ตายไปแล้ว ไม่มีทางอื่นเหลือ
        hostField.placeholderString = "Board address (leave empty to find it automatically)"
        hostField.target = self
        hostField.action = #selector(hostChanged)

        let stack = NSStackView(views: [
            statusLabel, ipLabel, scroll, password, buttons, separator(), routeLabel,
            hostField, hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [scroll, password, buttons, hostField, hint] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    // --- ให้ MenuBarApp ป้อนสถานะเข้ามา ------------------------------------
    func showBoards(_ list: [Board], selected: UUID?) {
        boards = list
        selectedBoard = selected
        boardPopup.removeAllItems()
        boardPopup.addItem(withTitle: "Any board")
        boardPopup.lastItem?.representedObject = nil
        for board in list {
            boardPopup.addItem(withTitle: board.name + (board.isCurrent ? " ✓" : ""))
            boardPopup.lastItem?.representedObject = board.id.uuidString
        }
        let index = list.firstIndex { $0.id == selected }
        boardPopup.selectItem(at: index.map { $0 + 1 } ?? 0)
    }

    func showBrightness(_ value: Int) { brightness.integerValue = value }

    func showInterval(_ interval: PollInterval) {
        let index = PollInterval.allCases.firstIndex(of: interval) ?? 0
        intervalPopup.selectItem(at: index)
    }

    func showToggles(statusline: Bool, autoStart: Bool, login: Bool) {
        statuslineBox.state = statusline ? .on : .off
        autoStartBox.state = autoStart ? .on : .off
        loginBox.state = login ? .on : .off
    }

    func showBoardHost(_ host: String) { hostField.stringValue = host }

    func showKey(_ state: SessionKeyState) {
        keyLabel.stringValue = state.line
        keyLabel.textColor = state.isProblem ? .systemRed : .secondaryLabelColor
    }

    /// ที่ตั้งที่บันทึกไว้ — nil = ปิดอยู่
    func showPlace(_ location: Weather.Location?) {
        places = []
        placeResults.isHidden = true
        placeResults.removeAllItems()
        guard let location else {
            placeLabel.stringValue = "Off — no weather, and nothing leaves this Mac."
            placeLabel.textColor = .secondaryLabelColor
            placeField.stringValue = ""
            return
        }
        let name = location.name ?? "Unnamed"
        placeLabel.stringValue = String(
            format: "%@ · %.4f, %.4f", name, location.latitude, location.longitude)
        placeLabel.textColor = .secondaryLabelColor
        placeField.stringValue = ""
    }

    func showSearching() {
        places = []
        placeResults.isHidden = true
        placeLabel.stringValue = "Searching…"
        placeLabel.textColor = .secondaryLabelColor
    }

    /// ผลค้นหา — ว่างแปลว่าไม่เจอ ซึ่งต้องบอกให้ชัดเพราะช่องค้นไม่มีอะไรเปลี่ยนเลย
    func showPlaces(_ found: [Weather.Place]) {
        places = found
        guard !found.isEmpty else {
            placeResults.isHidden = true
            placeLabel.stringValue = "No place by that name. Try the English spelling."
            placeLabel.textColor = .systemRed
            return
        }
        placeResults.removeAllItems()
        placeResults.addItem(withTitle: "Pick a place…")
        for place in found { placeResults.addItem(withTitle: place.label) }
        placeResults.selectItem(at: 0)
        placeResults.isHidden = false
        placeLabel.stringValue = "\(found.count) found — pick one to save it."
        placeLabel.textColor = .secondaryLabelColor
    }

    /// ทางที่ snapshot เดินอยู่จริง — คนละเรื่องกับ "บอร์ดต่อ WiFi แล้ว"
    ///
    /// บอร์ดที่ขึ้นเน็ตสำเร็จแต่ Mac หาไม่เจอ (client isolation, คนละ subnet) จะดูดีทุกอย่าง
    /// บนหน้านี้ทั้งที่ทางสำรองใช้ไม่ได้เลย บรรทัดนี้เป็นที่เดียวที่แยกสองอย่างนั้นออก
    func showRoute(_ route: LanRoute, detail: String?) {
        self.route = route
        routeLabel.stringValue = detail ?? PanelText.board(route: route)
    }

    func showLink(_ connected: Bool) {
        linked = connected
        if !connected { list.linkLost() }
        redraw()
    }

    func apply(_ event: BoardEvent) {
        list.apply(event)
        if case .wifi(let status) = event { self.status = status }
        redraw()
    }

    func beginScan() {
        list.beginScan()
        redraw()
    }

    private func redraw() {
        table.reloadData()
        if list.scanning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        guard linked else {
            statusLabel.stringValue = "No board connected over Bluetooth"
            ipLabel.stringValue = "Wi-Fi can only be set up while the board is in range."
            return
        }
        guard let status else {
            statusLabel.stringValue = "Asking the board…"
            ipLabel.stringValue = ""
            return
        }
        switch status.state {
        case .connected:
            statusLabel.stringValue = "Connected to \(status.ssid)"
            ipLabel.stringValue = "Board address \(status.ip)"
        case .connecting:
            statusLabel.stringValue = "Connecting to \(status.ssid)…"
            ipLabel.stringValue = ""
        case .failed:
            statusLabel.stringValue = "\(status.ssid): \(status.error ?? "failed")"
            // ไม่ต้องบอกให้กดลองใหม่ — firmware ลองเองเรื่อยๆ อยู่แล้ว
            ipLabel.stringValue = "The board keeps retrying on its own."
        case .off:
            statusLabel.stringValue = "No network saved yet"
            ipLabel.stringValue = ""
        }
    }

    private var selectedSSID: String? {
        let row = table.selectedRow
        guard row >= 0, row < list.found.count else { return nil }
        return list.found[row].ssid
    }

    // --- การกระทำ ----------------------------------------------------------
    @objc private func boardChanged() {
        let raw = boardPopup.selectedItem?.representedObject as? String
        onSelectBoard?(raw.flatMap(UUID.init(uuidString:)))
    }

    @objc private func brightnessChanged() { onBrightness?(brightness.integerValue) }

    @objc private func intervalChanged() {
        let raw = intervalPopup.selectedItem?.representedObject as? Int
        onInterval?(PollInterval.stored(raw))
    }

    @objc private func setSessionKey() { onSetSessionKey?() }
    @objc private func installHooks() { onInstallHooks?() }
    @objc private func statuslineToggled() { onToggleStatusline?() }
    @objc private func autoStartToggled() { onToggleAutoStart?() }
    @objc private func loginToggled() { onToggleLogin?() }
    @objc private func openLog() { onOpenLog?() }
    @objc private func openProject() { onOpenProject?() }

    @objc private func searchPlace() {
        let query = placeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        showSearching()
        onSearchPlace?(query)
    }

    @objc private func placePicked() {
        // ช่องแรกเป็นหัวข้อ ไม่ใช่ตัวเลือก
        let index = placeResults.indexOfSelectedItem - 1
        guard index >= 0, index < places.count else { return }
        onPickPlace?(places[index])
    }

    @objc private func clearPlace() { onClearPlace?() }

    @objc private func rescan() {
        beginScan()
        onScan?()
    }

    @objc private func join() {
        guard let ssid = selectedSSID else { return }
        onJoin?(ssid, password.stringValue)
        password.stringValue = ""
    }

    @objc private func hostChanged() {
        onBoardHost?(hostField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func forget() {
        guard let ssid = selectedSSID else { return }
        onForget?(ssid)
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { list.found.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let ap = list.found[row]
        // เครือข่ายที่บอร์ดจำไว้ต้องแยกออกจากที่เพิ่งเห็น ไม่งั้นผู้ใช้ไม่รู้ว่าต้องพิมพ์รหัส
        // ซ้ำไหม และปุ่ม Forget จะดูเหมือนใช้ได้กับทุกแถว
        var marks: [String] = []
        if list.saved.contains(ap.ssid) { marks.append("saved") }
        if ap.secured { marks.append("locked") }
        marks.append("\(ap.rssi) dBm")
        let text = "\(ap.ssid)   —   \(marks.joined(separator: ", "))"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

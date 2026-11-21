import AppKit
import CedarKit
import ServiceManagement

/// What the settings and welcome windows need from the app delegate.
protocol AppControls: AnyObject {
    var engine: EngineClient! { get }
    var shortcutIndex: Int { get }
    var shortcutTaken: Bool { get }
    func setShortcut(_ index: Int)
}

enum StatusText {
    /// One-line indexing status for the menu and the windows.
    static func line(_ s: EngineClient.Status?) -> String {
        guard let s else { return "Engine not running" }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let n = { (x: Int) in fmt.string(from: NSNumber(value: x)) ?? "\(x)" }
        var line = "\(n(s.names)) files · \(n(s.documents)) documents"
        if s.state == "downloading the model" { return line + " · downloading the model (640 MB, once)" }
        if s.to_embed > 0 {
            let total = s.vectors + s.to_embed
            let pct = total > 0 ? Int(Double(s.vectors) / Double(total) * 100) : 0
            line += " · understanding \(pct)%"
            if let rate = s.rate, rate > 0, s.state == "embedding" {
                let minutes = Double(s.to_embed) / rate / 60
                line += minutes < 90 ? " · about \(max(Int(minutes.rounded()), 1)) min left" : " · about \(Int((minutes / 60).rounded())) h left"
            }
            if s.state == "waiting for the charger" { line += " (waiting for the charger)" }
            if s.state == "paused" { line += " (paused)" }
        } else if s.state != "up to date" && s.state != "embedding" {
            line += " · \(s.state)"
        } else {
            line += " · up to date"
        }
        return line
    }
}

/// State of Spotlight's own ⌘Space shortcut in System Settings.
enum SpotlightShortcut {
    static var isOn: Bool {
        let keys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        guard let entry = keys?["64"] as? [String: Any] else { return true }
        if let on = entry["enabled"] as? Bool { return on }
        return ((entry["enabled"] as? Int) ?? 1) != 0
    }
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

func heading(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: 13, weight: .semibold)
    return l
}

func note(_ text: String, width: CGFloat = 440) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = .systemFont(ofSize: 11)
    l.textColor = .secondaryLabelColor
    l.preferredMaxLayoutWidth = width
    return l
}

final class SettingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private unowned let app: AppControls
    private(set) var window: NSWindow!
    private var settings = Settings.load()
    private let shortcut = NSPopUpButton()
    private let shortcutNote = note("")
    private let login = NSButton(checkboxWithTitle: "Open Cedar at login", target: nil, action: nil)
    private let rates = NSButton(checkboxWithTitle: "Fetch exchange rates once a day, for currency conversion", target: nil, action: nil)
    private let table = NSTableView()
    private let statusLabel = note("")
    private let paused = NSButton(checkboxWithTitle: "Pause indexing", target: nil, action: nil)
    private let deep = NSButton(checkboxWithTitle: "Read older documents in full too", target: nil, action: nil)
    private var timer: Timer?

    init(app: AppControls) {
        self.app = app
        super.init()
        build()
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Cedar Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        for combo in Hotkey.choices { shortcut.addItem(withTitle: combo.label) }
        shortcut.target = self; shortcut.action = #selector(shortcutChanged)
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Shortcut:"), shortcut])
        for b in [login, rates, paused, deep] { b.target = self }
        login.action = #selector(loginChanged); rates.action = #selector(ratesChanged)
        paused.action = #selector(indexingChanged); deep.action = #selector(indexingChanged)

        let column = NSTableColumn(identifier: .init("path"))
        column.width = 420
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self; table.delegate = self
        table.rowHeight = 20
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeFolder))
        let rebuild = NSButton(title: "Rebuild Index…", target: self, action: #selector(rebuildIndex))

        let stack = NSStackView(views: [
            heading("General"), shortcutRow, shortcutNote, login, rates,
            heading("Folders Cedar doesn't search"),
            note("Files in these folders aren't listed or read. Folders whose name ends in .noindex, hidden folders and ~/Library are always skipped."),
            scroll, NSStackView(views: [add, remove]),
            heading("Indexing"), statusLabel, paused,
            deep, note("Normally Cedar reads a document in full if it changed or was opened in the last two years, and only the first pages of older ones. Every word of every document is searchable either way."),
            rebuild,
            heading("Privacy"),
            note("Your files, the index, the model and text recognition stay on this Mac. Cedar goes online only to download its model once and, if enabled above, the day's exchange rates. Neither request includes anything you type or store."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: rates)
        stack.setCustomSpacing(18, after: stack.views[8])
        stack.setCustomSpacing(18, after: rebuild)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 500),
            scroll.heightAnchor.constraint(equalToConstant: 96), scroll.widthAnchor.constraint(equalToConstant: 452),
        ])
        window.contentView = content
    }

    func show() {
        settings = Settings.load()
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    func refresh() {
        shortcut.selectItem(at: app.shortcutIndex)
        shortcutNote.stringValue = app.shortcutTaken ? "Another app holds this shortcut. Pick another."
            : app.shortcutIndex == 0 && SpotlightShortcut.isOn
            ? "Spotlight still uses ⌘Space. Turn it off in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, or pick another shortcut here." : ""
        shortcutNote.isHidden = shortcutNote.stringValue.isEmpty
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        rates.state = Converter.ratesAllowed ? .on : .off
        paused.state = settings.paused ? .on : .off
        deep.state = settings.deepEverything ? .on : .off
        table.reloadData()
        refreshStatus()
    }

    private func refreshStatus() {
        app.engine.status { [weak self] s in self?.statusLabel.stringValue = StatusText.line(s) }
    }

    private func saveAndTell() {
        settings.save()
        app.engine.reload()
        refreshStatus()
    }

    @objc private func shortcutChanged() { app.setShortcut(shortcut.indexOfSelectedItem); refresh() }

    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Cedar: login item: \(error)") }
        refresh()
    }

    @objc private func ratesChanged() { Converter.ratesAllowed = rates.state == .on }

    @objc private func indexingChanged() {
        settings.paused = paused.state == .on
        settings.deepEverything = deep.state == .on
        saveAndTell()
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Don't Search"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.excluded.contains(url.path) { settings.excluded.append(url.path) }
        settings.excluded.sort()
        table.reloadData()
        saveAndTell()
    }

    @objc private func removeFolder() {
        let row = table.selectedRow
        guard row >= 0, row < settings.excluded.count else { return }
        settings.excluded.remove(at: row)
        table.reloadData()
        saveAndTell()
    }

    @objc private func rebuildIndex() {
        let alert = NSAlert()
        alert.messageText = "Rebuild the index?"
        alert.informativeText = "Cedar forgets everything it has read and starts over. Listing files takes under a minute; understanding documents again takes as long as the first time."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.engine.rebuild()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { settings.excluded.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: Paths.short(settings.excluded[row]))
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}

/// First-run window.
final class WelcomeController: NSObject, NSWindowDelegate {
    private unowned let app: AppControls
    private(set) var window: NSWindow!
    private let shortcutState = NSTextField(wrappingLabelWithString: "")
    private let openKeyboard = NSButton(title: "Open Keyboard Settings", target: nil, action: nil)
    private let useOption = NSButton(title: "Use ⌥ Space instead", target: nil, action: nil)
    private let progress = note("")
    private var timer: Timer?

    init(app: AppControls) {
        self.app = app
        super.init()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Welcome to Cedar"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "Find anything on your Mac by what's in it")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Type what you remember: a name, a phrase, or what a document is about. Cedar searches your apps, files and the contents of your documents, scanned PDFs included, and does math and conversions.")
        intro.preferredMaxLayoutWidth = 460
        let privacy = NSTextField(wrappingLabelWithString: "Everything stays on this Mac. Cedar reads your documents here, with a model that runs here. It goes online only to download that model once (640 MB) and to fetch exchange rates.")
        privacy.preferredMaxLayoutWidth = 460
        shortcutState.preferredMaxLayoutWidth = 460
        openKeyboard.target = self; openKeyboard.action = #selector(openSettings)
        useOption.target = self; useOption.action = #selector(switchToOption)
        let access = NSTextField(wrappingLabelWithString: "macOS may ask whether Cedar can read Desktop, Documents and Downloads. Say yes, or those folders can't be searched.")
        access.preferredMaxLayoutWidth = 460
        let done = NSButton(title: "Start Using Cedar", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let stack = NSStackView(views: [
            title, intro,
            heading("Private"), privacy,
            heading("The shortcut"), shortcutState, NSStackView(views: [openKeyboard, useOption]),
            heading("Permissions"), access,
            heading("First indexing"), progress,
            note("You can search right away: file names first, then every word, then meaning as documents are read. Reading happens in the background and waits for the charger on battery."),
            done,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for i in [1, 3, 6, 8, 11] { stack.setCustomSpacing(18, after: stack.views[i]) }
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        window.contentView = content
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let label = Hotkey.choices[app.shortcutIndex].label
        let blocked = app.shortcutIndex == 0 && SpotlightShortcut.isOn
        shortcutState.stringValue = blocked
            ? "Spotlight still uses ⌘ Space, so Cedar can't. In Keyboard Settings choose Keyboard Shortcuts → Spotlight and untick “Show Spotlight search”. Or give Cedar another shortcut."
            : "✓ Press \(label) in any app to open Cedar."
        shortcutState.textColor = blocked ? .labelColor : .systemGreen
        openKeyboard.isHidden = !blocked
        useOption.isHidden = !blocked
        app.engine.status { [weak self] s in self?.progress.stringValue = StatusText.line(s) }
    }

    @objc private func openSettings() { SpotlightShortcut.openKeyboardSettings() }
    @objc private func switchToOption() { app.setShortcut(1); refresh() }
    @objc private func finish() { window.close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        UserDefaults.standard.set(true, forKey: "welcomed")
        app.setShortcut(app.shortcutIndex)
    }
}

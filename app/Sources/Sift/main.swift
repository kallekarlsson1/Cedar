import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private var hotkey: Hotkey!
    private var engine: EngineClient!
    private var search: SearchController!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let shortcutMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sift")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        // Where the engine lives: written into Info.plist by build.sh, or next to the app's sources in development.
        let engineDir = Bundle.main.object(forInfoDictionaryKey: "SiftEngineDir") as? String
            ?? NSHomeDirectory() + "/Sift/engine"
        engine = EngineClient(dataDir: data, engineDir: engineDir)
        engine.startIfNeeded()

        search = SearchController(engine: engine, apps: Apps(), converter: Converter(dataDir: data),
                                  usage: Usage(dataDir: data))
        hotkey = Hotkey { [weak self] in self?.search.toggle() }
        registerSavedShortcut()
        buildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: shortcut

    private func registerSavedShortcut() {
        let saved = UserDefaults.standard.integer(forKey: "shortcut")
        let combo = Hotkey.choices[min(max(saved, 0), Hotkey.choices.count - 1)]
        if !hotkey.register(combo) {
            NSLog("Sift: \(combo.label) is taken by another app")
        }
    }

    @objc private func chooseShortcut(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "shortcut")
        registerSavedShortcut()
        updateShortcutMenu()
    }

    // MARK: menu bar

    private func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Sift")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Sift", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcut.submenu = shortcutMenu
        menu.addItem(shortcut)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.tag = 99
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = item.action == #selector(NSApplication.terminate(_:)) ? nil : self }
        status.menu = menu
        updateShortcutMenu()
    }

    private func updateShortcutMenu() {
        shortcutMenu.removeAllItems()
        for (i, combo) in Hotkey.choices.enumerated() {
            let item = NSMenuItem(title: combo.label, action: #selector(chooseShortcut(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = hotkey.combo == combo ? .on : .off
            shortcutMenu.addItem(item)
        }
        if hotkey.combo == nil {
            let note = NSMenuItem(title: "Taken by another app: pick another, or turn off Spotlight's", action: nil,
                                  keyEquivalent: "")
            note.isEnabled = false
            shortcutMenu.addItem(.separator())
            shortcutMenu.addItem(note)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 99)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        engine.status { [weak self] s in
            guard let self else { return }
            guard let s else { self.statusLine.title = "Engine not running"; return }
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            let n = { (x: Int) in fmt.string(from: NSNumber(value: x)) ?? "\(x)" }
            var line = "\(n(s.names)) files · \(n(s.documents)) documents"
            if s.to_embed > 0 {
                let total = s.vectors + s.to_embed
                let pct = total > 0 ? Int(Double(s.vectors) / Double(total) * 100) : 0
                line += " · understanding \(pct)%"
                if s.state == "waiting for the charger" { line += " (paused on battery)" }
            } else if s.state != "up to date" && s.state != "embedding" {
                line += " · \(s.state)"
            }
            self.statusLine.title = line
        }
    }

    @objc private func openPanel() { search.show() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Sift: login item: \(error)")
        }
    }
}

// `Sift --try "100 usd" "2+2" …` prints what the panel would answer, for testing from a terminal.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--try" {
    let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sift")
    try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let converter = Converter(dataDir: data)
    let apps = Apps()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // rates and the app list load
    for q in CommandLine.arguments.dropFirst(2) {
        var lines: [String] = []
        if let v = Calculator.evaluate(q) { lines.append("= " + Calculator.format(v)) }
        lines += converter.convert(q).map { "\($0.text)  [\($0.note)]" }
        lines += apps.search(q).prefix(3).map { "app: \($0.0.name) (\(Int($0.1)))" }
        print("\(q) → " + (lines.isEmpty ? "-" : lines.joined(separator: " | ")))
    }
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--snapshot" {
    app.setActivationPolicy(.accessory)
    let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sift")
    let engine = EngineClient(dataDir: data, engineDir: NSHomeDirectory() + "/Sift/engine")
    let apps = Apps()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let search = SearchController(engine: engine, apps: apps, converter: Converter(dataDir: data), usage: Usage(dataDir: data))
    search.debugSnapshot(CommandLine.arguments[2], to: CommandLine.arguments[3],
                         row: CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) : nil)
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

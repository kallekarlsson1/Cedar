import AppKit
import CedarKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, AppControls {
    private var status: NSStatusItem!
    private var hotkey: Hotkey!
    var engine: EngineClient!
    private var settingsWindow: SettingsController?
    private var welcomeWindow: WelcomeController?
    private var search: SearchController!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let shortcutMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cedar")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        engine = EngineClient(dataDir: data)
        engine.startIfNeeded()

        search = SearchController(engine: engine, apps: Apps(), converter: Converter(dataDir: data),
                                  usage: Usage(dataDir: data))
        hotkey = Hotkey { [weak self] in self?.search.toggle() }
        registerSavedShortcut()
        buildMenu()
        if !UserDefaults.standard.bool(forKey: "welcomed") { showWelcome() }
    }

    var shortcutIndex: Int { min(max(UserDefaults.standard.integer(forKey: "shortcut"), 0), Hotkey.choices.count - 1) }
    var shortcutTaken: Bool { hotkey.combo == nil }

    func setShortcut(_ index: Int) {
        UserDefaults.standard.set(index, forKey: "shortcut")
        registerSavedShortcut()
        updateShortcutMenu()
    }

    @objc func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsController(app: self) }
        settingsWindow?.show()
    }

    @objc func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeController(app: self) }
        welcomeWindow?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: shortcut

    private func registerSavedShortcut() {
        let saved = UserDefaults.standard.integer(forKey: "shortcut")
        let combo = Hotkey.choices[min(max(saved, 0), Hotkey.choices.count - 1)]
        if !hotkey.register(combo) {
            NSLog("Cedar: \(combo.label) is taken by another app")
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
        status.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Cedar")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Cedar", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Welcome Guide", action: #selector(showWelcome), keyEquivalent: "")
        let shortcut = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcut.submenu = shortcutMenu
        menu.addItem(shortcut)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.tag = 99
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cedar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        engine.status { [weak self] s in self?.statusLine.title = StatusText.line(s) }
    }

    @objc private func openPanel() { search.show() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Cedar: login item: \(error)")
        }
    }
}

// `Cedar --try "100 usd" "2+2" …` prints what the panel would answer, for testing from a terminal.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--try" {
    let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cedar")
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

// `Cedar --search "halvorsen plural"` and `Cedar --status`: ask the running engine from a terminal.
if CommandLine.arguments.count > 1, ["--search", "--status"].contains(CommandLine.arguments[1]) {
    let client = EngineClient(dataDir: Config.data)
    var done = false
    if CommandLine.arguments[1] == "--status" {
        client.status { s in
            if let s { print("\(s.state): \(s.names) files, \(s.documents) documents, \(s.vectors) passages understood, \(s.to_embed) to go") }
            else { print("the engine isn't running") }
            done = true
        }
    } else {
        let q = CommandLine.arguments.dropFirst(2).joined(separator: " ")
        client.search(q, deep: true) { a in
            guard let a else { print("the engine isn't running"); done = true; return }
            print("\(a.ms) ms")
            for d in a.docs { print("  \(d.title ?? (d.path as NSString).lastPathComponent)\(d.page.map { "  p.\($0)" } ?? "")\n      \(Paths.short(d.path))") }
            for f in a.files.prefix(6) { print("  \(Paths.short(f.path))") }
            done = true
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    exit(0)
}

// `Cedar --model file`: the helper process that holds the model.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--model" {
    ModelClient.serve(modelPath: CommandLine.arguments[2])
}

// `Cedar --engine`: the indexes and search, serving the panel over a socket.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--engine" {
    do { try Engine().run() } catch { logLine("engine failed to start: \(error)"); exit(1) }
}

// `Cedar --eval corpus queries.json [--words-only]`: the search-quality check on the Swift engine.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--eval" {
    let wordsOnly = CommandLine.arguments.contains("--words-only")
    let model = ProcessInfo.processInfo.environment["CEDAR_MODEL"] ?? ModelClient.modelFile()
    do {
        let ok = try Eval.run(corpus: CommandLine.arguments[2], queries: CommandLine.arguments[3], modelPath: wordsOnly ? nil : model)
        fflush(stdout); _exit(ok ? 0 : 1)
    } catch { print("eval failed: \(error)"); fflush(stdout); _exit(2) }
}

// `Cedar --quant-test`: does searching through 1-bit codes, then scoring the best few exactly, give the same results?
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--quant-test" {
    guard let file = ModelClient.modelFile(), let model = try? EmbeddingModel(path: file) else { print("no model"); exit(1) }
    let db = try! Database(path: Config.contentDB)
    var matrix: [Float16] = [], docs: [Int64] = []
    for row in try! db.query("SELECT doc, vec FROM chunks WHERE vec IS NOT NULL") {
        guard let blob = row[1].blob, blob.count == 2048 else { continue }
        blob.withUnsafeBytes { matrix.append(contentsOf: $0.bindMemory(to: Float16.self)) }
        docs.append(row[0].int ?? 0)
    }
    let n = docs.count, dim = 1024
    var codes: [UInt64] = []
    matrix.withUnsafeBufferPointer { m in
        for r in 0..<n { codes.append(contentsOf: Bits.code(UnsafeBufferPointer(rebasing: m[r * dim..<(r + 1) * dim]))) }
    }
    func exact(_ q: [Float], _ r: Int) -> Float { var s: Float = 0; for i in 0..<dim { s += Float(matrix[r * dim + i]) * q[i] }; return s }
    func topDocs(_ rows: [(Int, Float)]) -> [Int64] {
        var out: [Int64] = []
        for (r, _) in rows.sorted(by: { $0.1 > $1.1 }) { if !out.contains(docs[r]) { out.append(docs[r]) }; if out.count == 10 { break } }
        return out
    }
    // General questions: what matters is that both ways of searching agree, on whatever library this Mac has.
    let queries = ["people using several chatbots for math and writing", "does debate help people judge correctly", "assistants that agree too much",
        "learning from wrong examples", "social conformity online", "changing beliefs by talking", "tutoring with more than one tutor",
        "computer vision textbook", "a rental agreement", "meeting notes from last month", "project plan and next steps",
        "learning by listening to a conversation", "productive failure", "disagreement between peers", "how many participants took part",
        "detecting objects in images", "receipt for an order", "curriculum vitae", "updating a belief after counterarguments",
        "trust in algorithms versus humans", "a questionnaire and its validation", "turn-taking in conversation", "worked examples in physics",
        "models of human cognition", "invoice", "flattery", "bank payment", "self explanation", "glacier", "asdf qwerty"]
    print("\(n) passages; \(queries.count) queries")
    for keep in [100, 300, 1000] {
        var top1 = 0, overlap = 0.0, zdiff = 0.0, tExact = 0.0, tFast = 0.0
        for text in queries {
            guard let q = model.embedQuery(text) else { continue }
            var t = Date()
            let all = (0..<n).map { ($0, exact(q, $0)) }
            let truth = topDocs(all)
            tExact += Date().timeIntervalSince(t)
            t = Date()
            let near = Bits.nearest(Bits.code(q), in: codes, rows: n, keep: keep)
            let got = topDocs(near.map { ($0, exact(q, $0)) })
            // The scale for "stands out" from a sample of 2,000 rows instead of all of them.
            var sm: Float = 0, ss: Float = 0, sn: Float = 0
            for r in stride(from: 0, to: n, by: max(n / 2000, 1)) { let v = exact(q, r); sm += v; ss += v * v; sn += 1 }
            tFast += Date().timeIntervalSince(t)
            let mean = all.map(\.1).reduce(0, +) / Float(n), sd = (all.map { ($0.1 - mean) * ($0.1 - mean) }.reduce(0, +) / Float(n)).squareRoot()
            let smean = sm / sn, ssd = max(ss / sn - smean * smean, 0).squareRoot()
            let best = all.map(\.1).max() ?? 0
            zdiff += Double(abs((best - mean) / sd - (best - smean) / ssd))
            if truth.first == got.first { top1 += 1 }
            overlap += Double(Set(truth).intersection(got).count) / Double(max(truth.count, 1))
        }
        let c = Double(queries.count)
        print(String(format: "keep %4d: top hit same %2d/%d, top-10 overlap %.3f, z of best off by %.2f on average, %.1f ms (exact scan in plain Swift %.1f ms)",
                     keep, top1, queries.count, overlap / c, zdiff / c, tFast / c * 1000, tExact / c * 1000))
    }
    // Speed at a million passages (made-up codes: only the timing means anything).
    let big = 1_000_000
    var fake = [UInt64](repeating: 0, count: big * Bits.words)
    for i in fake.indices { fake[i] = UInt64.random(in: 0...UInt64.max) }
    let probe = Bits.code(model.embedQuery("x")!)
    let t = Date(); for _ in 0..<5 { _ = Bits.nearest(probe, in: fake, rows: big, keep: 4000) }
    print(String(format: "1,000,000 passages: %.1f ms per search for the bit scan, %d MB of codes in memory (float16 would be %d MB)",
                 Date().timeIntervalSince(t) / 5 * 1000, big * 128 / 1_000_000, big * 2048 / 1_000_000))
    fflush(stdout); _exit(0)
}

// `Cedar --embed-test`: do this binary's vectors match the ones in the index? (And how fast is it.)
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--embed-test" {
    let model = Config.modelPath
    let started = Date()
    guard let m = try? EmbeddingModel(path: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : model) else { print("no model"); exit(1) }
    _ = m.embed("warm up")
    print(String(format: "load %.2f s", Date().timeIntervalSince(started)))
    let db = try! Database(path: Config.contentDB)
    let rows = try! db.query("SELECT text, vec FROM chunks WHERE vec IS NOT NULL ORDER BY id % 97, id LIMIT 64")
    var worst: Float = 1, sum: Float = 0
    let t = Date()
    for row in rows {
        guard let text = row[0].text, let blob = row[1].blob, let got = m.embed(text) else { continue }
        let ref = blob.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        var dot: Float = 0
        for i in 0..<EmbeddingModel.dimension { dot += got[i] * Float(ref[i]) }
        worst = min(worst, dot); sum += dot
    }
    print(String(format: "parity with the index over %d passages: mean %.4f, worst %.4f", rows.count, sum / Float(rows.count), worst))
    print(String(format: "%.1f passages/s", Double(rows.count) / Date().timeIntervalSince(t)))
    let q = Date(); for _ in 0..<10 { _ = m.embedQuery("the paper about several chatbots") }
    print(String(format: "query %.1f ms", Date().timeIntervalSince(q) * 100))
    fflush(stdout); _exit(0)      // skip exit handlers: Metal's teardown asserts while a model is still alive
}

// `Cedar --ocr file.pdf 1,2,5`: the text of those pages, for the engine (scanned PDFs).
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--ocr" {
    let pages = CommandLine.arguments[3].split(separator: ",").compactMap { Int($0) }
    let result = OCR.run(path: CommandLine.arguments[2], pages: pages)
    if let data = try? JSONSerialization.data(withJSONObject: result) { FileHandle.standardOutput.write(data) }
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--snapshot-window" {
    app.setActivationPolicy(.accessory)
    final class Stand: NSObject, AppControls {
        var engine: EngineClient! = EngineClient(dataDir: Config.data)
        var shortcutIndex = 0
        var shortcutTaken = false
        func setShortcut(_ index: Int) { shortcutIndex = index }
    }
    let stand = Stand()
    var window: NSWindow
    var keep: AnyObject
    if CommandLine.arguments[2] == "settings" { let c = SettingsController(app: stand); c.show(); window = c.window; keep = c }
    else { let c = WelcomeController(app: stand); c.show(); window = c.window; keep = c }
    window.contentView?.wantsLayer = true      // the picture has no window behind it: paint the background in
    window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print("window", window.frame.size)
    }
    _ = keep
    exit(0)
}
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--snapshot" {
    app.setActivationPolicy(.accessory)
    let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cedar")
    let engine = EngineClient(dataDir: data)
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

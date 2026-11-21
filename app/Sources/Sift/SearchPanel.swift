import AppKit
import Quartz

/// One row in the results.
enum Item {
    case header(String)
    case answer(text: String, copy: String, note: String)
    case app(Apps.App)
    case doc(EngineClient.Doc)
    case file(EngineClient.File)

    var path: String? {
        switch self {
        case .app(let a): return a.url.path
        case .doc(let d): return d.path
        case .file(let f): return f.path
        default: return nil
        }
    }
    var selectable: Bool { if case .header = self { return false }; return true }
}

/// The floating panel: a borderless window that takes the keyboard without pulling the app in front.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let engine: EngineClient
    private let apps: Apps
    private let converter: Converter
    private let usage: Usage

    private let panel: Panel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let detail = DetailView()
    private let divider = NSBox()
    private var items: [Item] = []
    private var answer: EngineClient.Answer?
    private var generation = 0
    private var deepWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var navigated = false      // moved through results since the last keystroke: Space previews

    private let width: CGFloat = 760
    private let barHeight: CGFloat = 56
    private let listWidth: CGFloat = 340
    private let maxBody: CGFloat = 440

    init(engine: EngineClient, apps: Apps, converter: Converter, usage: Usage) {
        self.engine = engine
        self.apps = apps
        self.converter = converter
        self.usage = usage
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 56),
                      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        build()
    }

    // MARK: layout

    private func build() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Sift Search"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        column.width = listWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        detail.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        for v in [glass, field, divider, scroll, line, detail] { background.addSubview(v) }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: background.topAnchor, constant: barHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            divider.topAnchor.constraint(equalTo: background.topAnchor, constant: barHeight),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: listWidth),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            line.topAnchor.constraint(equalTo: divider.bottomAnchor),
            line.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            detail.topAnchor.constraint(equalTo: divider.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: line.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in self?.hide()
        }
    }

    // MARK: showing

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let top = frame.maxY - frame.height * 0.22
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - width / 2, y: top))
        }
        resize()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        startKeyMonitor()
        if !field.stringValue.isEmpty { run(field.stringValue) }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func resize() {
        let rows = items.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        let body = items.isEmpty ? 0 : min(max(rows, 260), maxBody)
        let height = barHeight + body
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        divider.isHidden = items.isEmpty
    }

    // MARK: searching

    func controlTextDidChange(_ obj: Notification) {
        navigated = false
        run(field.stringValue)
    }

    private func run(_ text: String) {
        generation += 1
        let g = generation
        deepWork?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            answer = nil
            show(items: [])
            return
        }
        rebuild(q)   // instantly: math, conversions, apps (and the last answer while the new one comes)
        engine.search(text, deep: false) { [weak self] a in
            guard let self, g == self.generation, let a else { return }
            self.answer = a
            self.rebuild(q)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.engine.search(text, deep: true) { a in
                guard let self, g == self.generation, let a else { return }
                self.answer = a
                self.rebuild(q)
            }
        }
        deepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rebuild(_ q: String) {
        var answers: [Item] = []
        if let v = Calculator.evaluate(q) {
            answers.append(.answer(text: "= " + Calculator.format(v), copy: Calculator.format(v), note: "Calculator"))
        }
        for r in converter.convert(q) { answers.append(.answer(text: r.text, copy: r.copy, note: r.note)) }

        let appHits = apps.search(q).map { ($0.0, $0.1 + usage.boost($0.0.url.path)) }
            .sorted { $0.1 > $1.1 }.prefix(4)
        let docs = (answer?.docs ?? []).prefix(8)
        let files = (answer?.files ?? []).map { ($0, $0.score + usage.boost($0.path)) }
            .sorted { $0.1 > $1.1 }.prefix(6)

        var appSection: [Item] = appHits.isEmpty ? [] : [.header("Applications")] + appHits.map { .app($0.0) }
        let docSection: [Item] = docs.isEmpty ? [] : [.header("Documents")] + docs.map { .doc($0) }
        var fileSection: [Item] = files.isEmpty ? [] : [.header("Folders & Files")] + files.map { .file($0.0) }
        if (appHits.first?.1 ?? 0) < 40 { appSection = [] }

        var out: [Item] = answers.isEmpty ? [] : [.header(answers.count == 1 ? "Answer" : "Answers")] + answers
        let appsFirst = (appHits.first?.1 ?? 0) >= 74
        let filesFirst = (files.first?.1 ?? 0) >= 100 && !appsFirst
        if appsFirst { out += appSection; appSection = [] }
        if filesFirst { out += fileSection; fileSection = [] }
        out += docSection + fileSection + appSection
        show(items: out)
    }

    private func show(items new: [Item]) {
        let keep = table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow].path : nil
        items = new
        table.reloadData()
        var row = items.firstIndex { $0.selectable } ?? -1
        if navigated, let keep, let same = items.firstIndex(where: { $0.path == keep }) { row = same }
        select(row)
        resize()
    }

    private func select(_ row: Int) {
        if row >= 0 {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        detail.show(row >= 0 && row < items.count ? items[row] : nil, query: field.stringValue)
    }

    // MARK: keys

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 125: move(1); return true                     // ↓
        case 126: move(-1); return true                    // ↑
        case 36, 76:                                       // ↩
            cmd ? revealSelected() : openSelected()
            return true
        case 53:                                           // esc
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; run("") }
            return true
        case 49 where navigated && !cmd:                   // space after moving: preview
            preview(); return true
        default: break
        }
        if cmd, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "y": preview(); return true
            case "c" where (field.currentEditor()?.selectedRange.length ?? 0) == 0:
                copySelected(); return true
            default: break
            }
        }
        return false
    }

    private func move(_ step: Int) {
        guard !items.isEmpty else { return }
        var row = table.selectedRow
        repeat { row += step } while row >= 0 && row < items.count && !items[row].selectable
        guard row >= 0 && row < items.count else { return }
        navigated = true
        select(row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        detail.show(row >= 0 && row < items.count ? items[row] : nil, query: field.stringValue)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].selectable }

    private var selected: Item? {
        let row = table.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    // MARK: actions

    @objc private func openSelected() {
        guard let item = selected else { return }
        switch item {
        case .answer(_, let copy, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        case .app(let app):
            usage.opened(app.url.path)
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        case .doc(let d):
            usage.opened(d.path)
            // Preview and most apps read the find pasteboard: ⌘G jumps to the words you searched for.
            let words = field.stringValue.trimmingCharacters(in: .whitespaces)
            let find = NSPasteboard(name: .find)
            find.clearContents()
            find.setString(words, forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: d.path))
        case .file(let f):
            usage.opened(f.path)
            NSWorkspace.shared.open(URL(fileURLWithPath: f.path))
        case .header: return
        }
        hide()
    }

    private func revealSelected() {
        guard let path = selected?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        hide()
    }

    private func copySelected() {
        guard let item = selected else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if case .answer(_, let copy, _) = item {
            pb.setString(copy, forType: .string)
        } else if let path = item.path {
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        }
    }

    private func preview() {
        guard let path = selected?.path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    private func rowHeight(_ item: Item) -> CGFloat {
        if case .header = item { return 26 }
        return 44
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(items[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if case .header(let title) = item {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            let cell = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        }
        let cell = ResultCell()
        cell.fill(item)
        return cell
    }
}

/// Icon, title and one line under it.
final class ResultCell: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        for v in [icon, title, subtitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fill(_ item: Item) {
        switch item {
        case .answer(let text, _, let note):
            icon.image = NSImage(systemSymbolName: note == "Calculator" ? "equal.square" : "arrow.left.arrow.right.square",
                                 accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
            title.stringValue = text
            subtitle.stringValue = note
        case .app(let app):
            icon.image = Icons.shared.icon(app.url.path)
            title.stringValue = app.name
            subtitle.stringValue = "Application"
        case .doc(let d):
            icon.image = Icons.shared.icon(d.path)
            let name = (d.path as NSString).lastPathComponent
            title.stringValue = d.title ?? name
            subtitle.stringValue = d.title == nil ? Paths.short((d.path as NSString).deletingLastPathComponent) : name
        case .file(let f):
            icon.image = Icons.shared.icon(f.path)
            title.stringValue = f.name
            subtitle.stringValue = Paths.short((f.path as NSString).deletingLastPathComponent)
        case .header: break
        }
    }
}

/// The right side: what the selected result is, where it is, and the passage that matched.
final class DetailView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let place = NSTextField(wrappingLabelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.maximumNumberOfLines = 4
        place.font = .systemFont(ofSize: 11)
        place.textColor = .secondaryLabelColor
        place.maximumNumberOfLines = 4
        snippet.font = .systemFont(ofSize: 12)
        snippet.textColor = .labelColor
        snippet.maximumNumberOfLines = 12
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, place, snippet])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(hint)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for v in [title, place, snippet] { v.preferredMaxLayoutWidth = 370 }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: Item?, query: String) {
        isHidden = item == nil
        guard let item else { return }
        snippet.attributedStringValue = NSAttributedString()
        hint.stringValue = "↩ Open   ⌘↩ Show in Finder   ⌘Y Preview   ⌘C Copy"
        switch item {
        case .answer(let text, _, let note):
            icon.image = NSImage(systemSymbolName: "equal.square", accessibilityDescription: nil)
            title.stringValue = text
            place.stringValue = note
            hint.stringValue = "↩ Copy result"
        case .app(let app):
            icon.image = Icons.shared.icon(app.url.path)
            title.stringValue = app.name
            place.stringValue = Paths.short(app.url.path)
            hint.stringValue = "↩ Open   ⌘↩ Show in Finder"
        case .doc(let d):
            icon.image = Icons.shared.icon(d.path)
            title.stringValue = d.title ?? (d.path as NSString).lastPathComponent
            var where_ = Paths.short(d.path)
            if let page = d.page, let pages = d.pages { where_ += "\nPage \(page) of \(pages)" }
            else if let pages = d.pages { where_ += "\n\(pages) pages" }
            where_ += Paths.modified(d.path)
            place.stringValue = where_
            if let s = d.snippet { snippet.attributedStringValue = Self.highlight(s) }
        case .file(let f):
            icon.image = Icons.shared.icon(f.path)
            title.stringValue = f.name
            place.stringValue = Paths.short(f.path) + Paths.modified(f.path)
        case .header: break
        }
    }

    /// «matched words» in bold.
    static func highlight(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        var rest = Substring(text.replacingOccurrences(of: "\n", with: " "))
        while let open = rest.firstIndex(of: "«") {
            out.append(NSAttributedString(string: String(rest[..<open]), attributes: normal))
            rest = rest[rest.index(after: open)...]
            let close = rest.firstIndex(of: "»") ?? rest.endIndex
            out.append(NSAttributedString(string: String(rest[..<close]), attributes: bold))
            rest = close < rest.endIndex ? rest[rest.index(after: close)...] : ""
        }
        out.append(NSAttributedString(string: String(rest), attributes: normal))
        return out
    }
}

enum Paths {
    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
    static func modified(_ path: String) -> String {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return "\nModified " + f.string(from: date)
    }
}

final class Icons {
    static let shared = Icons()
    private let cache = NSCache<NSString, NSImage>()
    func icon(_ path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

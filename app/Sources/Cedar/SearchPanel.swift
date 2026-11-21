import AppKit
import PDFKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One row in the results.
enum Item {
    case header(String)
    case answer(text: String, result: String, copy: String, note: String)
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

/// Which group a file goes in, as Spotlight groups them.
enum Group: Int, CaseIterable {
    case pdf, documents, folders, images, other
    var title: String {
        switch self {
        case .pdf: return "PDF Documents"
        case .documents: return "Documents"
        case .folders: return "Folders"
        case .images: return "Images"
        case .other: return "Other"
        }
    }
    static func of(path: String, isDir: Bool) -> Group {
        if isDir { return .folders }
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": return .pdf
        case "md", "markdown", "txt", "tex", "docx", "doc", "rtf", "odt", "pptx", "key", "xlsx", "numbers", "pages",
             "html", "htm", "rst", "org", "csv", "epub": return .documents
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "tif", "bmp", "svg", "raw", "dng": return .images
        default: return .other
        }
    }
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
    private let inline = NSTextField(labelWithString: "")   // the answer or top hit, in gray after what you typed
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
    private var bodyHeight: NSLayoutConstraint!
    private var isAnswerOnly = false

    private let width: CGFloat = 820
    private let barHeight: CGFloat = 60
    private let listWidth: CGFloat = 330
    private let bodyFull: CGFloat = 470

    init(engine: EngineClient, apps: Apps, converter: Converter, usage: Usage) {
        self.engine = engine
        self.apps = apps
        self.converter = converter
        self.usage = usage
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 60),
                      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        build()
        Thumbnails.shared.onReady = { [weak self] path in self?.thumbnailReady(path) }
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
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 21, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 25, weight: .regular)
        field.placeholderString = "Cedar Search"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false

        inline.font = field.font
        inline.textColor = .tertiaryLabelColor
        inline.lineBreakMode = .byTruncatingTail
        inline.isHidden = true

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
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 6, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        detail.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        for v in [glass, field, inline, divider, scroll, line, detail] { background.addSubview(v) }
        // Without a set height, Auto Layout shrinks the window to the smallest size its contents allow (just the bar).
        bodyHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            glass.centerYAnchor.constraint(equalTo: background.topAnchor, constant: barHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            divider.topAnchor.constraint(equalTo: background.topAnchor, constant: barHeight),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: listWidth),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bodyHeight,
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

    // MARK: testing

    /// Types `query` into the panel, waits for the answers, and saves a picture of the panel:
    /// `Cedar --snapshot "query" out.png [row]`.
    func debugSnapshot(_ query: String, to path: String, row: Int? = nil) {
        show()
        field.stringValue = query
        run(query)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        if let row, row < items.count { select(row); RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
        print("items:", items.count, "selected:", table.selectedRow, "panel:", panel.frame)
        if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: showing

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let top = frame.maxY - frame.height * 0.2
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
        let body: CGFloat = items.isEmpty ? 0 : isAnswerOnly ? 190 : bodyFull
        bodyHeight.constant = body
        divider.isHidden = items.isEmpty
        let height = barHeight + 1 + body
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height          // grow downwards from the bar
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        updateInline()
    }

    /// The answer ("= 121,57 kr") or the top hit ("— Safari") in gray, right after what you typed.
    private func updateInline() {
        let typed = field.stringValue
        var hint: String?
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            for item in items {
                if case .answer(_, let result, _, _) = item { hint = " = " + result; break }
                if case .app(let a) = item { hint = " — " + a.name; break }
                if case .header = item { continue }
                break
            }
        }
        guard let hint, let font = field.font else { inline.isHidden = true; return }
        let typedWidth = (typed as NSString).size(withAttributes: [.font: font]).width
        let x = field.frame.minX + typedWidth + 3
        let available = field.frame.maxX - x
        guard available > 40 else { inline.isHidden = true; return }
        inline.stringValue = hint
        inline.frame = NSRect(x: x, y: field.frame.minY, width: available, height: field.frame.height)
        inline.isHidden = false
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
        if isAnswerOnly { answer = nil; return }   // math or a conversion: the answer is all you see
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
            let r = Calculator.format(v)
            answers.append(.answer(text: q + " = " + r, result: r, copy: r, note: "Calculator"))
        }
        for r in converter.convert(q) {
            answers.append(.answer(text: r.text, result: r.result, copy: r.copy, note: r.note))
        }

        if !answers.isEmpty {
            isAnswerOnly = true
            show(items: [.header("Top Hit"), answers[0]] + (answers.count > 1 ? [.header("Conversions")] + answers.dropFirst() : []))
            return
        }
        isAnswerOnly = false

        let appHits = apps.search(q).map { ($0.0, $0.1 + usage.boost($0.0.url.path)) }
            .filter { $0.1 >= 40 }.sorted { $0.1 > $1.1 }

        // Documents from the engine keep its order (meaning + words); name matches follow within each group.
        var grouped: [Group: [Item]] = [:]
        var seen = Set<String>()
        for d in answer?.docs ?? [] where seen.insert(d.path).inserted {
            grouped[Group.of(path: d.path, isDir: false), default: []].append(.doc(d))
        }
        let files = (answer?.files ?? []).map { ($0, $0.score + usage.boost($0.path)) }.sorted { $0.1 > $1.1 }
        for (f, _) in files where seen.insert(f.path).inserted {
            grouped[Group.of(path: f.path, isDir: f.dir), default: []].append(.file(f))
        }

        // Top hit: an answer, a strongly matching app, a file named exactly what you typed, or the best document.
        var top: Item?
        if let first = answers.first { top = first; answers.removeFirst() }
        else if let a = appHits.first, a.1 >= 74 { top = .app(a.0) }
        else if let f = files.first, f.1 >= 100 { top = .file(f.0) }
        else if let d = answer?.docs.first { top = .doc(d) }
        else if let a = appHits.first { top = .app(a.0) }
        else if let f = files.first { top = .file(f.0) }

        var out: [Item] = []
        if let top { out += [.header("Top Hit"), top] }
        let topPath = top?.path
        if !answers.isEmpty { out += [.header("Conversions")] + answers }
        let appRows = appHits.prefix(4).map { Item.app($0.0) }.filter { $0.path != topPath }
        if !appRows.isEmpty { out += [.header("Applications")] + appRows.prefix(3) }
        let limits: [Group: Int] = [.pdf: 6, .documents: 6, .folders: 4, .images: 4, .other: 4]
        for group in Group.allCases {
            let rows = (grouped[group] ?? []).filter { $0.path != topPath }.prefix(limits[group] ?? 4)
            if !rows.isEmpty { out += [.header(group.title)] + rows }
        }
        show(items: out)
    }

    private func show(items new: [Item]) {
        let keep = table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow].path : nil
        let wasEmpty = items.isEmpty
        items = new
        table.reloadData()
        var row = items.firstIndex { $0.selectable } ?? -1
        if navigated, let keep, let same = items.firstIndex(where: { $0.path == keep }) { row = same }
        select(row)
        let height = barHeight + 1 + (items.isEmpty ? 0 : isAnswerOnly ? 190 : bodyFull)
        if wasEmpty != items.isEmpty || abs(panel.frame.height - height) > 1 { resize() } else { updateInline() }
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

    private func thumbnailReady(_ path: String) {
        let rows = IndexSet(items.indices.filter { items[$0].path == path })
        if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: [0]) }
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
        case .answer(_, _, let copy, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        case .app(let app):
            usage.opened(app.url.path)
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        case .doc(let d):
            usage.opened(d.path)
            engine.opened(d.path)
            // Preview and most apps read the find pasteboard: ⌘G jumps to the words you searched for.
            let find = NSPasteboard(name: .find)
            find.clearContents()
            find.setString(field.stringValue.trimmingCharacters(in: .whitespaces), forType: .string)
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
        if case .answer(_, _, let copy, _) = item {
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

    private func isTopHit(_ row: Int) -> Bool {
        guard row > 0, case .header("Top Hit") = items[row - 1] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 26 }
        return isTopHit(row) ? 46 : 32
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if case .header(let title) = item {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let cell = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5),
            ])
            return cell
        }
        let cell = ResultCell(big: isTopHit(row))
        cell.fill(item)
        return cell
    }
}

/// Thumbnail (or icon), name, and the folder it's in.
final class ResultCell: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init(big: Bool) {
        super.init(frame: .zero)
        let size: CGFloat = big ? 32 : 22
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: big ? 14 : 13, weight: big ? .medium : .regular)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .systemFont(ofSize: 11)
        trailing.textColor = .tertiaryLabelColor
        trailing.lineBreakMode = .byTruncatingHead
        trailing.alignment = .right
        for v in [icon, title, trailing] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: size),
            icon.heightAnchor.constraint(equalToConstant: size),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fill(_ item: Item) {
        switch item {
        case .answer(let text, _, _, let note):
            icon.image = NSImage(systemSymbolName: note == "Calculator" ? "plus.forwardslash.minus" : "arrow.left.arrow.right",
                                 accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            title.stringValue = text
            trailing.stringValue = note == "Calculator" ? "" : note.hasPrefix("ECB") ? "Currency" : "Units"
        case .app(let app):
            icon.image = Icons.shared.icon(app.url.path)
            title.stringValue = app.name
            trailing.stringValue = ""
        case .doc(let d):
            icon.image = Thumbnails.shared.image(for: d.path)
            title.stringValue = d.title ?? (d.path as NSString).lastPathComponent
            trailing.stringValue = Self.folder(d.path)
        case .file(let f):
            icon.image = Thumbnails.shared.image(for: f.path)
            title.stringValue = f.name
            trailing.stringValue = Self.folder(f.path)
        case .header: break
        }
    }

    static func folder(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }
}

/// The right side: a preview (a PDF at the page that matched, with your words highlighted; Quick Look for the
/// rest), then what the file is and where it lives.
final class DetailView: NSView {
    private let previewArea = NSView()
    private let pageImage = NSImageView()      // a PDF page, drawn with your words highlighted
    private let quickLook: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)!
    private let bigIcon = NSImageView()
    private let bigText = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let facts = NSTextField(wrappingLabelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var loading = 0

    init() {
        super.init(frame: .zero)
        pageImage.imageScaling = .scaleProportionallyUpOrDown
        // Fit the space; never size the window to the picture.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            pageImage.setContentCompressionResistancePriority(.init(1), for: axis)
            pageImage.setContentHuggingPriority(.init(1), for: axis)
        }
        pageImage.wantsLayer = true
        pageImage.shadow = {
            let sh = NSShadow()
            sh.shadowBlurRadius = 6
            sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
            return sh
        }()
        quickLook.shouldCloseWithWindow = false
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        bigText.font = .systemFont(ofSize: 30, weight: .medium)
        bigText.alignment = .center
        for v in [pageImage, quickLook, bigIcon, bigText] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewArea.addSubview(v)
        }
        NSLayoutConstraint.activate([
            pageImage.topAnchor.constraint(equalTo: previewArea.topAnchor),
            pageImage.bottomAnchor.constraint(equalTo: previewArea.bottomAnchor),
            pageImage.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            pageImage.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            quickLook.topAnchor.constraint(equalTo: previewArea.topAnchor),
            quickLook.bottomAnchor.constraint(equalTo: previewArea.bottomAnchor),
            quickLook.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            quickLook.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            bigIcon.centerXAnchor.constraint(equalTo: previewArea.centerXAnchor),
            bigIcon.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor),
            bigIcon.widthAnchor.constraint(equalToConstant: 128),
            bigIcon.heightAnchor.constraint(equalToConstant: 128),
            bigText.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor),
            bigText.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor, constant: 10),
            bigText.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor, constant: -10),
        ])

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        facts.maximumNumberOfLines = 6
        snippet.maximumNumberOfLines = 4
        snippet.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        for v in [previewArea, title, facts, snippet, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            previewArea.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            previewArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            previewArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            previewArea.heightAnchor.constraint(equalToConstant: 250),
            title.topAnchor.constraint(equalTo: previewArea.bottomAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            facts.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            facts.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            facts.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            snippet.topAnchor.constraint(equalTo: facts.bottomAnchor, constant: 8),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            snippet.bottomAnchor.constraint(lessThanOrEqualTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for v in [title, facts, snippet] { v.preferredMaxLayoutWidth = 450 }
    }

    required init?(coder: NSCoder) { fatalError() }

    private enum Mode { case pdf, quickLook, icon, text }

    private func use(_ mode: Mode) {
        pageImage.isHidden = mode != .pdf
        quickLook.isHidden = mode != .quickLook
        bigIcon.isHidden = mode != .icon
        bigText.isHidden = mode != .text
    }

    func show(_ item: Item?, query: String) {
        isHidden = item == nil
        loading += 1
        guard let item else { return }
        snippet.attributedStringValue = NSAttributedString()
        snippet.isHidden = true
        hint.stringValue = "↩ Open    ⌘↩ Show in Finder    ⌘Y Quick Look    ⌘C Copy"
        switch item {
        case .answer(_, let result, _, let note):
            use(.text)
            bigText.stringValue = result
            title.stringValue = note == "Calculator" ? "Calculator" : note.hasPrefix("ECB") ? "Currency conversion" : "Unit conversion"
            facts.attributedStringValue = Self.facts([("Source", note)])
            hint.stringValue = "↩ Copy result"
        case .app(let app):
            use(.icon)
            bigIcon.image = Icons.shared.icon(app.url.path)
            title.stringValue = app.name
            let version = Bundle(url: app.url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            facts.attributedStringValue = Self.facts([("Kind", "Application"), ("Version", version ?? "–"),
                                                      ("Where", Paths.short(app.url.path))])
            hint.stringValue = "↩ Open    ⌘↩ Show in Finder"
        case .doc(let d):
            title.stringValue = d.title ?? (d.path as NSString).lastPathComponent
            var rows = Self.fileFacts(d.path)
            if let page = d.page, let pages = d.pages { rows.insert(("Match", "page \(page) of \(pages)"), at: 1) }
            facts.attributedStringValue = Self.facts(rows)
            if d.path.lowercased().hasSuffix(".pdf") {
                showPDF(d.path, page: d.page, query: query)
            } else {
                showQuickLook(d.path)
                if let s = d.snippet {
                    snippet.attributedStringValue = Self.highlight(s)
                    snippet.isHidden = false
                }
            }
        case .file(let f):
            title.stringValue = f.name
            facts.attributedStringValue = Self.facts(Self.fileFacts(f.path))
            if f.path.lowercased().hasSuffix(".pdf") { showPDF(f.path, page: nil, query: query) }
            else if f.dir { use(.icon); bigIcon.image = Icons.shared.icon(f.path) }
            else { showQuickLook(f.path) }
        case .header: break
        }
    }

    private func showQuickLook(_ path: String) {
        use(.quickLook)
        quickLook.previewItem = URL(fileURLWithPath: path) as NSURL
    }

    /// The page that matched, drawn with the words you typed highlighted.
    private var document: (path: String, doc: PDFDocument)?
    private let renderQueue = DispatchQueue(label: "cedar.pdf", qos: .userInitiated)

    private func showPDF(_ path: String, page: Int?, query: String) {
        use(.pdf)
        pageImage.image = nil
        let token = loading
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 }
        let cached = document?.path == path ? document?.doc : nil
        renderQueue.async {
            guard let doc = cached ?? PDFDocument(url: URL(fileURLWithPath: path)) else { return }
            let image = Self.render(doc, page: page, words: words)
            DispatchQueue.main.async {
                self.document = (path, doc)
                guard token == self.loading else { return }
                self.pageImage.image = image
            }
        }
    }

    private static func render(_ doc: PDFDocument, page: Int?, words: [String]) -> NSImage? {
        let index = max(0, min((page ?? 1) - 1, doc.pageCount - 1))
        guard let pdfPage = doc.page(at: index) else { return nil }
        let box = pdfPage.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = 900 / max(box.width, box.height)
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        let thumb = pdfPage.thumbnail(of: size, for: .cropBox)

        // Where the words are on the page, in the image's coordinates.
        var rects: [NSRect] = []
        if pdfPage.rotation == 0, let text = pdfPage.string as NSString? {
            for word in words {
                var range = NSRange(location: 0, length: text.length)
                while rects.count < 80 {
                    let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                    if found.location == NSNotFound { break }
                    if let r = pdfPage.selection(for: found)?.bounds(for: pdfPage), !r.isEmpty {
                        rects.append(NSRect(x: (r.minX - box.minX) * scale - 1, y: (r.minY - box.minY) * scale - 1,
                                            width: r.width * scale + 2, height: r.height * scale + 2))
                    }
                    let next = found.location + found.length
                    range = NSRange(location: next, length: text.length - next)
                }
            }
        }
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        thumb.draw(in: NSRect(origin: .zero, size: size))
        NSColor.systemYellow.withAlphaComponent(0.45).setFill()
        for r in rects { NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill() }
        out.unlockFocus()
        return out
    }

    private static func fileFacts(_ path: String) -> [(String, String)] {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
                                                       .isDirectoryKey])
        var rows: [(String, String)] = [("Kind", values?.localizedTypeDescription ?? "File")]
        if values?.isDirectory != true, let size = values?.fileSize {
            rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let date = values?.contentModificationDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            rows.append(("Modified", f.string(from: date)))
        }
        rows.append(("Where", Paths.short((path as NSString).deletingLastPathComponent)))
        return rows
    }

    /// "Kind   PDF document" lines, labels in gray.
    private static func facts(_ rows: [(String, String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 72)]
        style.headIndent = 72
        style.lineSpacing = 2
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        for (i, (k, v)) in rows.enumerated() {
            out.append(NSAttributedString(string: k + "\t", attributes: label))
            out.append(NSAttributedString(string: v + (i < rows.count - 1 ? "\n" : ""), attributes: value))
        }
        return out
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

/// Quick Look thumbnails (a PDF's first page, a picture itself), made in the background; the icon until then.
final class Thumbnails {
    static let shared = Thumbnails()
    var onReady: ((String) -> Void)?
    private let cache = NSCache<NSString, NSImage>()
    private var pending = Set<String>()

    func image(for path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let icon = Icons.shared.icon(path)
        guard !pending.contains(path) else { return icon }
        pending.insert(path)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(path)
                if let rep {
                    self.cache.setObject(rep.nsImage, forKey: path as NSString)
                    self.onReady?(path)
                } else {
                    self.cache.setObject(icon, forKey: path as NSString)
                }
            }
        }
        return icon
    }
}

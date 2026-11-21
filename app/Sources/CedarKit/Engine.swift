import Foundation

/// The running engine (`Cedar --engine`): keeps both indexes current and answers the panel over a private socket.
///
/// Protocol: one JSON object per line each way.
///   {"op": "search", "q": "halvorsen plural", "deep": true}   → {"docs": [...], "files": [...], "ms": 12.3}
///   {"op": "status"}                                      → {"state": ..., "names": 646466, "documents": 1696, ...}
public final class Engine {
    static let idleBeforeEmbedding = 15.0   // seconds after the last search before the GPU goes back to indexing
    static let idleBeforeUnload = 120.0     // with nothing left to embed, free the model after this long without a search

    let names: Names
    let content: ContentIndex
    let model = ModelClient()
    private var watcher: Watcher?
    private let lock = NSLock()
    private var state = "starting"
    private var lastSearch = Date.distantPast
    private var changed = Set<String>()
    private let changeSignal = DispatchSemaphore(value: 0)
    private var work = 0                    // counts up when there may be new passages to embed
    private var rate = 0.0                  // passages per second, smoothed: for the time estimate
    private var settingsChanged: Settings?  // the settings before a change the reader still has to apply
    private var downloading = false

    struct Answer: Codable { let docs: [DocHit]; let files: [FileHit]; let ms: Double }
    struct Status: Codable {
        let state: String; let names: Int; let model: Bool
        let documents: Int; let vectors: Int; let to_embed: Int; let first_pass_left: Int
        let rate: Double        // passages embedded per second lately (0: not measured yet)
    }

    public init() throws {
        names = try Names()
        content = try ContentIndex()
    }

    private func set(_ text: String) { lock.lock(); state = text; lock.unlock() }
    private func moreWork() { lock.lock(); work += 1; lock.unlock() }
    private var sinceSearch: Double { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastSearch) }

    // MARK: reading

    private func readerLoop() {
        do {
            watcher = Watcher(paths: Config.roots()) { [weak self] paths in
                guard let self else { return }
                let kept = paths.filter { !Self.ignored($0) }
                guard !kept.isEmpty else { return }
                self.lock.lock(); self.changed.formUnion(kept); self.lock.unlock()
                self.changeSignal.signal()
            }
            if names.needsRebuild() {
                set("listing files")
                try names.rebuild(log: logLine)
            } else {
                // Search is already up on the last run's index; find what changed while Cedar wasn't running.
                set("checking for changes")
                try names.catchUp(log: logLine)
                for path in try content.knownDocuments() { try names.upsert(path) }   // edited in place, or gone
            }
            set("reading documents")
            try syncAll()
            var lastFull = Date()
            set("up to date")
            while true {
                _ = changeSignal.wait(timeout: .now() + 60)      // sleeps until a file changes
                Thread.sleep(forTimeInterval: 2)                 // let a burst of changes (a download, a save) finish
                try applySettings()
                try applyChanges()
                if try content.readScans(log: logLine) > 0 { moreWork() }   // scans that waited for the charger
                if Date().timeIntervalSince(lastFull) > 7 * 24 * 3600 {     // a safety net; changes arrive live
                    try names.rebuild(log: logLine)
                    try syncAll()
                    lastFull = Date()
                }
            }
        } catch {
            logLine("reader stopped: \(error)")
        }
    }

    private func syncAll() throws {
        // Files that are only in iCloud keep their names searchable; their contents aren't read (no downloads).
        let wanted = try names.documents().filter { !Config.isDataless($0.key) }
        try content.sync(wanted, log: logLine)
        try content.readScans(log: logLine)
        try content.markCopies(log: logLine)
        moreWork()
    }

    /// Settings changed: forget what's in newly excluded folders, and list the ones that are searched again.
    private func applySettings() throws {
        lock.lock(); let before = settingsChanged; settingsChanged = nil; lock.unlock()
        guard let before else { return }
        let now = Settings.current
        for folder in now.excluded where !before.excluded.contains(folder) {
            try names.remove(folder)
            try content.remove(path: folder)
            try content.removeUnder(folder: folder)
        }
        let back = before.excluded.filter { !now.excluded.contains($0) }
        for folder in back { try names.reread((folder as NSString).deletingLastPathComponent) }
        if !back.isEmpty { try syncAll() }
        moreWork()
        logLine("settings applied: \(now.excluded.count) folders excluded, paused \(now.paused)")
    }

    private func applyChanges() throws {
        lock.lock(); let paths = changed; changed = []; lock.unlock()
        for path in paths {
            var st = stat()
            if lstat(path, &st) == 0 {
                try names.upsert(path)
                let isFile = (st.st_mode & S_IFMT) == S_IFREG
                if isFile, Config.docExtensions.contains(Config.ext(path)), !Config.isDataless(path) {
                    let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                    if try content.mtime(of: path) != mtime {
                        try content.add(path, mtime: mtime, size: Int64(st.st_size))
                        try content.markCopies(only: path, log: logLine)
                        moreWork()
                    }
                }
            } else {
                try names.remove(path)
                try content.remove(path: path)
                try content.removeUnder(folder: path)
            }
        }
    }

    static func ignored(_ path: String) -> Bool {
        var parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") || Config.skipNames.contains($0) }) { return true }
        if parts.dropLast().contains(where: { $0.hasSuffix(".noindex") }) { return true }
        if Settings.current.excludes(path) { return true }
        if path.hasPrefix(Config.iCloud + "/") {
            parts = Array(parts.dropFirst(Config.iCloud.split(separator: "/").count))    // inside ~/Library but wanted
        } else if Config.skipPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        return parts.dropLast().contains { Config.packages.contains(Config.ext($0)) }
    }

    // MARK: embedding

    private func wake() {
        try? content.makeMissingCodes()
        content.loadVectors()
        lock.lock(); downloading = !ModelClient.modelIsHere; lock.unlock()
        model.load(log: logLine)
        lock.lock(); downloading = false; lock.unlock()
    }

    private func embedLoop() {
        wake()
        var checked: (Int, Bool)?
        while true {
            let idle = sinceSearch
            if idle < Self.idleBeforeEmbedding { Thread.sleep(forTimeInterval: 0.5); continue }
            if Settings.current.paused { Thread.sleep(forTimeInterval: 2); continue }
            let battery = Config.onBattery()
            if !model.loaded {
                // Unloaded while idle: come back only when there's work it's allowed to do now. The database is
                // asked only when the reader reported something new or the charger was (un)plugged.
                lock.lock(); let seen = (work, battery); lock.unlock()
                if let c = checked, c == seen { Thread.sleep(forTimeInterval: 5); continue }
                checked = seen
                let p = content.progress()
                if p.first_pass_left > 0 || (p.to_embed > 0 && !battery) { wake() } else { Thread.sleep(forTimeInterval: 5) }
                continue
            }
            // On battery only titles and first pages; the long tail waits for the charger.
            let began = Date()
            let done = (try? content.embedSome(model: { [model] in model.document($0) }, limit: 8, firstPassOnly: battery,
                                               pause: { [unowned self] in self.sinceSearch < Self.idleBeforeEmbedding || self.model.searchWaiting })) ?? 0
            if done >= 4 {
                let now = Double(done) / max(Date().timeIntervalSince(began), 0.01)
                lock.lock(); rate = rate == 0 ? now : rate * 0.9 + now * 0.1; lock.unlock()
            }
            if done == 0 {
                if idle > Self.idleBeforeUnload {
                    model.unload(log: logLine)
                    content.releaseVectors()
                    checked = nil
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    // MARK: answering

    func search(_ q: String, deep: Bool) -> Answer {
        let started = Date()
        lock.lock(); lastSearch = started; lock.unlock()
        var vector: [Float]?
        if deep {
            if !model.loaded {
                // Back from idle: words answer now; meaning joins once the model is in, for this search if it can.
                let ready = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async { self.wake(); ready.signal() }
                _ = ready.wait(timeout: .now() + 2.5)
            }
            vector = model.query(q)
        }
        let docs = (try? content.search(q, queryVector: vector)) ?? []
        // A copy of the same file ("paper (1).pdf") shows once.
        var seen = Set<String>(), unique: [DocHit] = []
        for d in docs {
            let stem = ((d.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let key = (d.title ?? stem.components(separatedBy: " (")[0].lowercased()) + "|\(d.pages ?? -1)"
            if seen.insert(key).inserted { unique.append(d) }
        }
        let docPaths = Set(unique.map(\.path))
        let files = names.search(q).filter { !docPaths.contains($0.path) }
        lock.lock(); lastSearch = Date(); lock.unlock()
        return Answer(docs: Array(unique.prefix(12)), files: Array(files.prefix(12)),
                      ms: (Date().timeIntervalSince(started) * 10000).rounded() / 10)
    }

    func status() -> Status {
        lock.lock(); var reading = state; let rate = self.rate; lock.unlock()
        let p = content.progress()
        if reading == "up to date" && p.to_embed > 0 {
            reading = Settings.current.paused ? "paused"
                : Config.onBattery() && p.first_pass_left == 0 ? "waiting for the charger" : "embedding"
        }
        lock.lock(); if downloading { reading = "downloading the model" }; lock.unlock()
        return Status(state: reading, names: names.count(), model: model.loaded, documents: p.documents, vectors: p.vectors,
                      to_embed: p.to_embed, first_pass_left: p.first_pass_left, rate: (rate * 10).rounded() / 10)
    }

    private func reply(to line: Data) -> Data {
        let encoder = JSONEncoder()
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return Data(#"{"error":"bad request"}"#.utf8) }
        switch request["op"] as? String {
        case "search": return (try? encoder.encode(search(request["q"] as? String ?? "", deep: request["deep"] as? Bool ?? false))) ?? Data()
        case "reload":
            let before = Settings.current
            Settings.current = Settings.load()
            if before != Settings.current {
                lock.lock(); settingsChanged = settingsChanged ?? before; lock.unlock()
                changeSignal.signal()
            }
            return Data("{}".utf8)
        case "opened":
            try? content.opened(request["path"] as? String ?? "")
            moreWork()
            return Data("{}".utf8)
        case "status": return (try? encoder.encode(status())) ?? Data()
        default: return Data(#"{"error":"unknown op"}"#.utf8)
        }
    }

    // MARK: running

    public func run() -> Never {
        // When the app that started us goes, so do we.
        let parent = getppid()
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        watch.setEventHandler { _exit(0) }
        watch.resume()
        signal(SIGPIPE, SIG_IGN)

        let reader = Thread { [self] in readerLoop() }
        reader.qualityOfService = .utility
        reader.start()
        let embedder = Thread { [self] in embedLoop() }
        embedder.qualityOfService = .utility
        embedder.start()

        unlink(Config.socket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Config.socket.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in pathBytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) } }
        let old = umask(0o077)                   // the socket is usable by this user only
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard bound == 0, listen(fd, 16) == 0 else { logLine("can't listen on \(Config.socket)"); _exit(1) }
        logLine("listening on \(Config.socket)")
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            let thread = Thread { [self] in
                var buffer = [UInt8](repeating: 0, count: 65536)
                var line = Data()
                while true {
                    let n = recv(client, &buffer, buffer.count, 0)
                    if n <= 0 { break }
                    line.append(buffer, count: n)
                    while let newline = line.firstIndex(of: 0x0A) {
                        var out = reply(to: line[line.startIndex..<newline])
                        out.append(0x0A)
                        line = Data(line[(newline + 1)...])
                        _ = out.withUnsafeBytes { send(client, $0.baseAddress, out.count, 0) }
                    }
                }
                close(client)
            }
            thread.qualityOfService = .userInitiated      // out of App Nap, on the performance cores
            thread.start()
        }
    }
}

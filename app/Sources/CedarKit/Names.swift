import Foundation

public struct FileHit: Codable {
    public let path: String
    public let name: String
    public let dir: Bool
    public let score: Double
    public let modified: Double?
}

/// Every file and folder name under the roots. Any part of a name matches in a few milliseconds (trigram index);
/// files in dataset folders (more than `Config.crowded` entries) are found by how their name starts instead.
public final class Names {
    static let schema = """
    CREATE TABLE IF NOT EXISTS entries(
        id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, name TEXT NOT NULL COLLATE NOCASE, is_dir INTEGER NOT NULL,
        mtime REAL, size INTEGER, depth INTEGER, crowded INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS entries_name ON entries(name);
    CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(name, tokenize='trigram remove_diacritics 1');
    """
    let db: Database        // writing
    let read: Database      // searching

    public init() throws {
        try FileManager.default.createDirectory(at: Config.data, withIntermediateDirectories: true)
        db = try Database(path: Config.namesDB)
        try db.execute(Self.schema)
        read = try Database(path: Config.namesDB)
    }

    struct Entry { let path: String; let name: String; let isDir: Bool; let mtime: Double; let size: Int64; let crowded: Bool }

    public func count() -> Int { Int((try? read.query("SELECT COUNT(*) FROM entries").first?[0].int) ?? 0 ?? 0) }

    public func needsRebuild() -> Bool {
        let version = (try? db.query("PRAGMA user_version").first?[0].int) ?? 0 ?? 0
        return version < 2 || count() == 0
    }

    /// What's directly inside a folder and worth listing.
    static func list(_ folder: String) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let kept = names.filter { !$0.hasPrefix(".") && !Config.skipNames.contains($0) }
        let crowded = kept.count > Config.crowded
        var out: [Entry] = []
        out.reserveCapacity(kept.count)
        for name in kept {
            let path = folder == "/" ? "/" + name : folder + "/" + name
            if Config.skipPaths.contains(path) || Settings.current.excluded.contains(path) { continue }
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            out.append(Entry(path: path, name: name, isDir: isDir,
                             mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                             size: Int64(st.st_size), crowded: crowded))
        }
        return out
    }

    /// Everything under `root`, folder by folder.
    static func walk(_ root: String, _ visit: (Entry) throws -> Void) rethrows {
        var stack = [root]
        while let folder = stack.popLast() {
            for e in list(folder) {
                try visit(e)
                if e.isDir && !Config.skipDir(path: e.path, name: e.name) { stack.append(e.path) }
            }
        }
    }

    private func insert(_ e: Entry, into table: String = "entries", fts: String? = "names") throws {
        try db.query("INSERT OR IGNORE INTO \(table)(path,name,is_dir,mtime,size,depth,crowded) VALUES(?,?,?,?,?,?,?)",
                     [.text(e.path), .text(e.name), .int(e.isDir ? 1 : 0), .double(e.mtime), .int(e.size),
                      .int(Int64(e.path.filter { $0 == "/" }.count)), .int(e.crowded ? 1 : 0)])
        if let fts, db.changes > 0, !e.crowded {
            try db.query("INSERT INTO \(fts)(rowid, name) VALUES(?, ?)", [.int(db.lastInsertID), .text(e.name)])
        }
    }

    /// Lists everything again into fresh tables, then swaps them in; searches keep working meanwhile.
    public func rebuild(log: (String) -> Void = { _ in }) throws {
        let started = Date()
        try db.execute("""
            DROP TABLE IF EXISTS entries_new; DROP TABLE IF EXISTS names_new;
            CREATE TABLE entries_new(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, name TEXT NOT NULL COLLATE NOCASE,
                is_dir INTEGER NOT NULL, mtime REAL, size INTEGER, depth INTEGER, crowded INTEGER NOT NULL DEFAULT 0);
            """)
        for root in Config.roots() {
            var pending = 0
            try db.execute("BEGIN")
            try Self.walk(root) { e in
                try insert(e, into: "entries_new", fts: nil)
                pending += 1
                if pending % 20000 == 0 { try db.execute("COMMIT; BEGIN") }
            }
            try db.execute("COMMIT")
        }
        try db.execute("""
            CREATE VIRTUAL TABLE names_new USING fts5(name, tokenize='trigram remove_diacritics 1');
            INSERT INTO names_new(rowid, name) SELECT id, name FROM entries_new WHERE crowded = 0;
            BEGIN;
            DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS names;
            ALTER TABLE entries_new RENAME TO entries; ALTER TABLE names_new RENAME TO names;
            CREATE INDEX IF NOT EXISTS entries_name ON entries(name);
            COMMIT;
            PRAGMA user_version = 2;
            PRAGMA wal_checkpoint(TRUNCATE);
            VACUUM;
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        log("names: \(count()) entries in \(Int(Date().timeIntervalSince(started)))s")
    }

    /// Finds what changed while Cedar wasn't running, without listing everything: a folder's modification time
    /// changes when something in it is added, removed or renamed, so only folders whose time moved are read again.
    @discardableResult
    public func catchUp(log: (String) -> Void = { _ in }) throws -> Int {
        let started = Date()
        var changed = Config.roots()
        for row in try db.query("SELECT path, mtime FROM entries WHERE is_dir = 1") {
            guard let path = row[0].text else { continue }
            if Config.skipDir(path: path, name: (path as NSString).lastPathComponent) { continue }
            var st = stat()
            if lstat(path, &st) != 0 { try remove(path); continue }
            let now = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if now != row[1].double { changed.append(path) }
        }
        var touched = 0
        for folder in changed { touched += try reread(folder) }
        log(String(format: "names: caught up in %.1fs (%d folders read, %d changes)", Date().timeIntervalSince(started), changed.count, touched))
        return touched
    }

    /// Brings one folder's direct children in line with the disk. Returns how many entries changed.
    @discardableResult
    public func reread(_ folder: String) throws -> Int {
        let listed = Dictionary(Self.list(folder).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var known: [String: Bool] = [:]
        for row in try db.query("SELECT path, crowded FROM entries WHERE path > ? AND path < ? AND instr(substr(path, ?), '/') = 0",
                                [.text(folder + "/"), .text(folder + "0"), .int(Int64(folder.utf8.count + 2))]) {
            known[row[0].text ?? ""] = row[1].int == 1
        }
        var changes = 0
        for path in known.keys where listed[path] == nil { try remove(path); changes += 1 }
        var newFolders: [String] = []
        try db.transaction {
            for (path, e) in listed where known[path] == nil {
                try insert(e)
                changes += 1
                if e.isDir && !Config.skipDir(path: e.path, name: e.name) { newFolders.append(path) }
            }
            let crowded = listed.count > Config.crowded
            if let was = known.values.first, was != crowded {       // the folder crossed the dataset line
                for row in try db.query("SELECT id, name FROM entries WHERE path > ? AND path < ? AND instr(substr(path, ?), '/') = 0",
                                        [.text(folder + "/"), .text(folder + "0"), .int(Int64(folder.utf8.count + 2))]) {
                    try db.query("UPDATE entries SET crowded = ? WHERE id = ?", [.int(crowded ? 1 : 0), row[0]])
                    try db.query("DELETE FROM names WHERE rowid = ?", [row[0]])
                    if !crowded { try db.query("INSERT INTO names(rowid, name) VALUES(?, ?)", [row[0], row[1]]) }
                }
            }
            var st = stat()
            if lstat(folder, &st) == 0 {
                try db.query("UPDATE entries SET mtime = ? WHERE path = ?",
                             [.double(Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9), .text(folder)])
            }
        }
        for folder in newFolders {          // a new folder: everything in it is new
            try db.transaction { try Self.walk(folder) { try insert($0); changes += 1 } }
        }
        return changes
    }

    /// A live change from the file watcher: the path appeared, changed or went away.
    public func upsert(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return try remove(path) }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if let id = try db.query("SELECT id FROM entries WHERE path = ?", [.text(path)]).first?[0] {
            try db.query("UPDATE entries SET mtime = ?, size = ? WHERE id = ?", [.double(mtime), .int(Int64(st.st_size)), id])
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let sibling = try db.query("SELECT crowded FROM entries WHERE path > ? AND path < ? LIMIT 1",
                                   [.text(parent + "/"), .text(parent + "0")]).first?[0].int
        try insert(Entry(path: path, name: (path as NSString).lastPathComponent, isDir: (st.st_mode & S_IFMT) == S_IFDIR,
                         mtime: mtime, size: Int64(st.st_size), crowded: sibling == 1))
    }

    /// The path itself and, if it was a folder, everything under it.
    public func remove(_ path: String) throws {
        let ids = try db.query("SELECT id FROM entries WHERE path = ? OR (path > ? AND path < ?)",
                               [.text(path), .text(path + "/"), .text(path + "0")]).compactMap { $0[0].int }
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.query("DELETE FROM entries WHERE id = ?", [.int(id)])
                try db.query("DELETE FROM names WHERE rowid = ?", [.int(id)])
            }
        }
    }

    /// Paths of documents to read: (modification time, size), leaving out dataset folders.
    public func documents() throws -> [String: (mtime: Double, size: Int64)] {
        var out: [String: (mtime: Double, size: Int64)] = [:]
        for row in try db.query("SELECT path, mtime, size FROM entries WHERE is_dir = 0 AND crowded = 0") {
            guard let path = row[0].text, Config.docExtensions.contains(Config.ext(path)) else { continue }
            out[path] = (row[1].double ?? 0, row[2].int ?? 0)
        }
        return out
    }

    public func search(_ query: String, limit: Int = 30) -> [FileHit] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let firstWord = words.first else { return [] }
        let long = words.filter { $0.count >= 3 }
        let prefix = firstWord.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        var rows: [[SQLValue]] = []
        if !long.isEmpty {
            let match = long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            rows = (try? read.query("""
                SELECT e.path, e.name, e.is_dir, e.mtime, e.depth, e.crowded FROM names JOIN entries e ON e.id = names.rowid
                WHERE names MATCH ? LIMIT 3000
                """, [.text(match)])) ?? []
            // Files in dataset folders aren't in the trigram index: they're found by how their name starts.
            rows += (try? read.query("""
                SELECT path, name, is_dir, mtime, depth, crowded FROM entries WHERE name LIKE ? ESCAPE '\\' AND crowded = 1 LIMIT 40
                """, [.text(prefix)])) ?? []
        } else {
            // One or two letters: names that start with them.
            rows = (try? read.query("""
                SELECT path, name, is_dir, mtime, depth, crowded FROM entries WHERE name LIKE ? ESCAPE '\\' AND crowded = 0
                ORDER BY depth LIMIT 3000
                """, [.text(prefix)])) ?? []
        }
        let now = Date().timeIntervalSince1970
        let q = words.joined(separator: " ")
        let starts = words.map { try! NSRegularExpression(pattern: #"(^|[\s_\-.()\[\]])"# + NSRegularExpression.escapedPattern(for: $0)) }
        var out: [FileHit] = []
        for row in rows {
            guard let path = row[0].text, let name = row[1].text else { continue }
            let low = name.lowercased(), isDir = row[2].int == 1
            guard words.allSatisfy({ low.contains($0) }), !low.hasSuffix(".app") else { continue }   // apps: the app's own list
            let stem = isDir ? low : (low as NSString).deletingPathExtension
            var score: Double
            if stem == q || low == q { score = 100 }
            else if low.hasPrefix(q) { score = 80 }
            else if starts.allSatisfy({ $0.firstMatch(in: low, range: NSRange(location: 0, length: (low as NSString).length)) != nil }) { score = 62 }
            else { score = 40 }
            if isDir { score += 6 } else if Config.docExtensions.contains(Config.ext(low)) { score += 8 }
            if row[5].int == 1 { score -= 30 }
            score -= 1.5 * Double(max((row[4].int ?? 1) - 2, 0))
            let age = (now - (row[3].double ?? 0)) / 86400
            score += age < 7 ? 6 : age < 60 ? 3 : 0
            out.append(FileHit(path: path, name: name, dir: isDir, score: (score * 100).rounded() / 100, modified: row[3].double))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }
}

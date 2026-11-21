import Foundation
import zlib

public struct DocHit: Codable {
    public let path: String
    public let title: String?
    public let pages: Int?
    public let page: Int?
    public let snippet: String?
    public let region: String?
    public let score: Double
    public let z: Double?
    public let words: Double
}

public struct Progress: Codable {
    public var documents = 0, vectors = 0, to_embed = 0, first_pass_left = 0
}

/// The document index: passages in SQLite with a keyword index (FTS5) and a vector each, plus the search over both.
/// The file format is the one the Python engine wrote, so an existing index carries over.
public final class ContentIndex {
    static let schema = """
    CREATE TABLE IF NOT EXISTS docs(
        id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, mtime REAL, size INTEGER, title TEXT, pages INTEGER,
        embed INTEGER NOT NULL DEFAULT 1,
        state TEXT NOT NULL                 -- ok | ocr (scanned pages waiting) | unreadable
    );
    CREATE TABLE IF NOT EXISTS chunks(
        id INTEGER PRIMARY KEY, doc INTEGER NOT NULL,
        region TEXT NOT NULL,               -- name | head | body | refs
        page INTEGER, ord INTEGER, text TEXT, first_pass INTEGER NOT NULL DEFAULT 0,
        vec BLOB                            -- 1024 x float16, normalized; NULL until embedded (or never: name, refs)
    );
    CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc);
    CREATE TABLE IF NOT EXISTS shingles(hash INTEGER NOT NULL, doc INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS shingles_hash ON shingles(hash);
    CREATE INDEX IF NOT EXISTS shingles_doc ON shingles(doc);
    CREATE INDEX IF NOT EXISTS chunks_todo ON chunks(first_pass, doc) WHERE vec IS NULL;
    CREATE INDEX IF NOT EXISTS chunks_twin ON chunks(substr(text, 1, 40)) WHERE vec IS NULL;
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    -- One bit per dimension of each vector (128 bytes): what search keeps in memory. The vectors stay on disk.
    CREATE TABLE IF NOT EXISTS codes(chunk INTEGER PRIMARY KEY, doc INTEGER NOT NULL, bits BLOB NOT NULL);
    CREATE INDEX IF NOT EXISTS codes_doc ON codes(doc);
    CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(name, head, body, refs, d, tokenize='porter unicode61 remove_diacritics 2');
    CREATE VIRTUAL TABLE IF NOT EXISTS docfts USING fts5(name, head, body, refs, tokenize='porter unicode61 remove_diacritics 2');
    """

    /// How much finding a word counts, by where it is. A paper's authors beat the names it cites.
    static let fieldWeight: [String: Double] = ["name": 1.0, "head": 1.0, "body": 0.5, "refs": 0.12]
    static let columns = ["name", "head", "body", "refs"]
    /// A passage is a meaning match when it stands out from the rest for this query (z) AND is close in absolute
    /// terms (cosine): among thousands of passages something always stands out, even for a nonsense query.
    /// Measured with this model: real matches have cosine 0.44-0.75, the best passage for a query about nothing in
    /// the library 0.29-0.38.
    static let zGate = 2.0
    static let minCosine: Float = 0.42
    static let wordWeight = 5.0
    static let titleWeight = 3.0
    /// Ties go to the documents people mean: a paper's PDF before a text dump of it.
    static let kindPrior: [String: Double] = ["pdf": 0.4, "docx": 0.35, "pptx": 0.35, "xlsx": 0.2, "doc": 0.3, "md": 0.2,
                                              "tex": 0.15, "txt": 0.0, "html": 0.05, "htm": 0.05]
    /// Words in nearly every document: they cost the most to look up and say nothing about which one is meant.
    static let stopwords: Set<String> = Set("""
    a an the and or but if of to in on at by for with from into about as is are was were be been being it its this that
    these those there here what which who whom whose when where why how i me my we our you your he she they them their
    his her not no yes do does did done can could would should will shall may might must have has had having than then
    so such very more most some any all each every both few other also just only own same too s t up down out over under
    again further once using use used paper document file one two thing things like
    och att det som en ett är på för med av till den de om inte har var jag du vi ni han hon men så kan ska från eller
    när där hur vad vem vilken vilket vilka också bara efter under över mellan
    """.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init))

    let write: Database      // indexing
    let read: Database       // searching: its own connection, so it never waits for a document being written
    static let dim = EmbeddingModel.dimension

    // In memory: a 1-bit code per passage (128 bytes) and a small sample of full vectors. A search finds the
    // closest codes, then scores those few hundred passages exactly from the vectors on disk. Measured on a real
    // 22,000-passage library over 30 queries: the same top 10 as scoring everything, in 1/16 of the memory.
    private var codes: [UInt64] = []
    private var rowChunk: [Int64] = []
    private var rowDoc: [Int64] = []
    private var sample: [Float16] = []       // every k-th vector: sets the scale for "stands out" (mean, deviation)
    private var sampleEvery: Int64 = 1
    private let vectorLock = NSLock()
    public private(set) var vectorsLoaded = false
    public var rows: Int { rowChunk.count }

    public init() throws {
        try FileManager.default.createDirectory(at: Config.data, withIntermediateDirectories: true)
        write = try Database(path: Config.contentDB)
        try write.execute(Self.schema)
        if try !write.query("PRAGMA table_info(docs)").contains(where: { $0[1].text == "opened" }) {
            try write.execute("ALTER TABLE docs ADD COLUMN opened REAL")      // when it was last opened from Cedar
        }
        read = try Database(path: Config.contentDB)
        // Vectors made by another model don't compare: embed again.
        let named = try write.query("SELECT value FROM meta WHERE key = 'vectors'").first?[0].text
        if let named, named != Config.vectors, !Config.compatible.contains(named) {
            try write.query("UPDATE chunks SET vec = NULL WHERE vec IS NOT NULL")
            try write.query("DELETE FROM codes")
        }
        try write.query("INSERT OR REPLACE INTO meta(key, value) VALUES('vectors', ?)", [.text(Config.vectors)])
    }

    // MARK: vectors

    static func half(_ blob: Data) -> [Float16] { blob.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) } }

    /// Codes for vectors that don't have one yet (an index from before codes existed).
    public func makeMissingCodes() throws {
        let missing = try write.query("""
            SELECT c.id, c.doc, c.vec FROM chunks c WHERE c.vec IS NOT NULL AND c.id NOT IN (SELECT chunk FROM codes)
            """)
        guard !missing.isEmpty else { return }
        try write.transaction {
            for row in missing {
                guard let blob = row[2].blob, blob.count == Self.dim * 2 else { continue }
                let bits = Self.half(blob).withUnsafeBufferPointer { Bits.code($0) }
                try write.query("INSERT OR REPLACE INTO codes(chunk, doc, bits) VALUES(?,?,?)",
                                [row[0], row[1], .blob(bits.withUnsafeBufferPointer { Data(buffer: $0) })])
            }
        }
    }

    public func loadVectors() {
        vectorLock.lock(); defer { vectorLock.unlock() }
        guard !vectorsLoaded else { return }
        let found = (try? read.query("SELECT chunk, doc, bits FROM codes ORDER BY chunk")) ?? []
        codes = []; codes.reserveCapacity(found.count * Bits.words)
        rowChunk = []; rowDoc = []
        for row in found {
            guard let blob = row[2].blob, blob.count == Bits.words * 8 else { continue }
            blob.withUnsafeBytes { codes.append(contentsOf: $0.bindMemory(to: UInt64.self)) }
            rowChunk.append(row[0].int ?? 0)
            rowDoc.append(row[1].int ?? 0)
        }
        sampleEvery = Int64(max(rowChunk.count / 2000, 1))
        sample = []
        for row in (try? read.query("SELECT vec FROM chunks WHERE vec IS NOT NULL AND id % ? = 0", [.int(sampleEvery)])) ?? [] {
            if let blob = row[0].blob, blob.count == Self.dim * 2 { sample.append(contentsOf: Self.half(blob)) }
        }
        vectorsLoaded = true
    }

    /// Frees the in-memory copy; keyword search keeps working.
    public func releaseVectors() {
        vectorLock.lock(); defer { vectorLock.unlock() }
        codes = []; rowChunk = []; rowDoc = []; sample = []
        vectorsLoaded = false
    }

    private func append(chunk: Int64, doc: Int64, vector: [Float16], bits: [UInt64]) {
        vectorLock.lock(); defer { vectorLock.unlock() }
        guard vectorsLoaded else { return }      // they're in the database; the next load brings them
        codes.append(contentsOf: bits)
        rowChunk.append(chunk)
        rowDoc.append(doc)
        if chunk % sampleEvery == 0 { sample.append(contentsOf: vector) }
    }

    static func dot(_ v: [Float16], _ q: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(v.count, q.count) { s += Float(v[i]) * q[i] }
        return s
    }

    /// The passages closest to the query, scored exactly, best first; and the mean and deviation of scores across
    /// the library (from the sample), which say how far a score stands out.
    private func closest(_ q: [Float]) -> (hits: [(doc: Int64, chunk: Int64, score: Float)], mean: Float, deviation: Float) {
        vectorLock.lock()
        let n = rowChunk.count
        let keep = min(n, max(300, min(n / 70, 4000)))     // more candidates as the library grows
        let near = Bits.nearest(Bits.code(q), in: codes, rows: n, keep: keep)
        let picked = near.map { (chunk: rowChunk[$0], doc: rowDoc[$0]) }
        var sum: Float = 0, squares: Float = 0
        let sampled = sample.count / Self.dim
        sample.withUnsafeBufferPointer { s in
            for r in 0..<sampled {
                var v: Float = 0
                for i in 0..<Self.dim { v += Float(s[r * Self.dim + i]) * q[i] }
                sum += v; squares += v * v
            }
        }
        vectorLock.unlock()
        let mean = sampled > 0 ? sum / Float(sampled) : 0
        let deviation = sampled > 0 ? max(squares / Float(sampled) - mean * mean, 0).squareRoot() : 1
        var docOf: [Int64: Int64] = [:]
        for p in picked { docOf[p.chunk] = p.doc }
        var hits: [(doc: Int64, chunk: Int64, score: Float)] = []
        let ids = picked.map(\.chunk)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let part = ids[start..<min(start + 500, ids.count)]
            let marks = part.map { _ in "?" }.joined(separator: ",")
            for row in (try? read.query("SELECT id, vec FROM chunks WHERE id IN (\(marks))", part.map { .int($0) })) ?? [] {
                guard let id = row[0].int, let blob = row[1].blob, blob.count == Self.dim * 2, let doc = docOf[id] else { continue }
                hits.append((doc, id, Self.dot(Self.half(blob), q)))
            }
        }
        hits.sort { $0.score > $1.score }
        return (hits, mean, deviation)
    }

    // MARK: indexing

    /// Brings the index in line with `wanted` (path → modification time, size): reads new and changed documents,
    /// newest first, and drops the ones that are gone.
    public func sync(_ wanted: [String: (mtime: Double, size: Int64)], log: (String) -> Void = { _ in }) throws {
        var have: [String: (mtime: Double, id: Int64)] = [:]
        for row in try write.query("SELECT id, path, mtime FROM docs") {
            have[row[1].text ?? ""] = (row[2].double ?? 0, row[0].int ?? 0)
        }
        var gone = 0
        for (path, known) in have where wanted[path] == nil { try delete(known.id); gone += 1 }
        let todo = wanted.filter { have[$0.key] == nil || have[$0.key]!.mtime != $0.value.mtime }
            .sorted { $0.value.mtime > $1.value.mtime }
        let started = Date()
        for (n, item) in todo.enumerated() {
            try add(item.key, mtime: item.value.mtime, size: item.value.size)
            if (n + 1) % 100 == 0 { log("read \(n + 1)/\(todo.count) documents (\(Int(Date().timeIntervalSince(started)))s)") }
        }
        if !todo.isEmpty || gone > 0 { log("documents: \(todo.count) read, \(gone) removed") }
    }

    public func add(_ path: String, mtime: Double, size: Int64) throws {
        if let old = try write.query("SELECT id FROM docs WHERE path = ?", [.text(path)]).first?[0].int { try delete(old) }
        let doc = autoreleasepool { Extract.read(path) }
        try write.transaction {
            guard let doc else {
                try write.query("INSERT INTO docs(path, mtime, size, state, embed) VALUES(?, ?, ?, 'unreadable', 0)",
                                [.text(path), .double(mtime), .int(size)])
                return
            }
            try write.query("INSERT INTO docs(path, mtime, size, title, pages, embed, state) VALUES(?,?,?,?,?,?,?)",
                            [.text(path), .double(mtime), .int(size), doc.title.map { .text($0) } ?? .null,
                             doc.pages.map { .int(Int64($0)) } ?? .null, .int(doc.embed ? 1 : 0),
                             .text(doc.pendingOCR ? "ocr" : "ok")])
            let id = write.lastInsertID
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            // The name row also gets the file name split at _ - . so "Halvorsen_et_al_2026" matches "halvorsen".
            let nameText = stem + (doc.title.map { " — " + $0 } ?? "") + " "
                + stem.replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
            try insert(doc: id, region: "name", page: nil, order: 0, text: nameText, first: false)
            var regions: [String: [String]] = ["name": [nameText], "head": [], "body": [], "refs": []]
            for p in doc.passages { regions[p.region, default: []].append(p.text) }
            try write.query("INSERT INTO docfts(rowid, name, head, body, refs) VALUES(?,?,?,?,?)",
                            [.int(id)] + Self.columns.map { .text(regions[$0]!.joined(separator: " ")) })
            for (i, p) in doc.passages.enumerated() {
                let first = p.region == "head" || (p.page != nil && p.page! <= Config.firstPassPages)
                    || (p.page == nil && i < Config.firstPassChunks)
                try insert(doc: id, region: p.region, page: p.page, order: i, text: p.text, first: first)
            }
            try fingerprint(id)
        }
    }

    private func insert(doc: Int64, region: String, page: Int?, order: Int, text: String, first: Bool) throws {
        try write.query("INSERT INTO chunks(doc, region, page, ord, text, first_pass) VALUES(?,?,?,?,?,?)",
                        [.int(doc), .text(region), page.map { .int(Int64($0)) } ?? .null, .int(Int64(order)), .text(text),
                         .int(first ? 1 : 0)])
        let id = write.lastInsertID
        var values: [SQLValue] = [.null, .null, .null, .null]
        values[Self.columns.firstIndex(of: region)!] = .text(text)
        // d holds one token naming the passage's document ("x42"), so one document's passages are found directly.
        try write.query("INSERT INTO fts(rowid, name, head, body, refs, d) VALUES(?,?,?,?,?,?)", [.int(id)] + values + [.text("x\(doc)")])
    }

    private func delete(_ doc: Int64) throws {
        try write.transaction {
            try write.query("DELETE FROM fts WHERE rowid IN (SELECT id FROM chunks WHERE doc = ?)", [.int(doc)])
            try write.query("DELETE FROM docfts WHERE rowid = ?", [.int(doc)])
            try write.query("DELETE FROM shingles WHERE doc = ?", [.int(doc)])
            try write.query("DELETE FROM codes WHERE doc = ?", [.int(doc)])
            try write.query("DELETE FROM chunks WHERE doc = ?", [.int(doc)])
            try write.query("DELETE FROM docs WHERE id = ?", [.int(doc)])
        }
        vectorLock.lock()
        if vectorsLoaded, rowDoc.contains(doc) {       // drop its rows from memory
            var keptCodes: [UInt64] = []; keptCodes.reserveCapacity(codes.count)
            var keptChunk: [Int64] = [], keptDoc: [Int64] = []
            for i in rowDoc.indices where rowDoc[i] != doc {
                keptCodes.append(contentsOf: codes[i * Bits.words..<(i + 1) * Bits.words])
                keptChunk.append(rowChunk[i]); keptDoc.append(rowDoc[i])
            }
            codes = keptCodes; rowChunk = keptChunk; rowDoc = keptDoc
        }
        vectorLock.unlock()
    }

    public func remove(path: String) throws {
        if let id = try write.query("SELECT id FROM docs WHERE path = ?", [.text(path)]).first?[0].int { try delete(id) }
    }

    public func removeUnder(folder: String) throws {
        for row in try write.query("SELECT id FROM docs WHERE path > ? AND path < ?", [.text(folder + "/"), .text(folder + "0")]) {
            try delete(row[0].int ?? 0)
        }
    }

    public func knownDocuments() throws -> [String] { try write.query("SELECT path FROM docs").compactMap { $0[0].text } }

    public func mtime(of path: String) throws -> Double? {
        try write.query("SELECT mtime FROM docs WHERE path = ?", [.text(path)]).first?[0].double
    }

    // MARK: copies and scans

    /// Hashes of 4-word runs from the start of a document: finds text files that copy a PDF.
    private func fingerprint(_ doc: Int64) throws {
        let texts = try write.query("SELECT text FROM chunks WHERE doc = ? AND region IN ('head', 'body') ORDER BY ord LIMIT 8",
                                    [.int(doc)]).compactMap { $0[0].text }
        let words = Self.tokens(texts.joined(separator: " "), pattern: "[a-z0-9]+").prefix(1200)
        guard words.count >= 4 else { return }
        var hashes = Set<Int64>()
        let list = Array(words)
        for i in 0...(list.count - 4) {
            let run = Array(list[i..<i + 4].joined(separator: " ").utf8)
            hashes.insert(Int64(crc32(0, run, UInt32(run.count))))
        }
        for h in hashes { try write.query("INSERT INTO shingles(hash, doc) VALUES(?, ?)", [.int(h), .int(doc)]) }
    }

    /// Text and Markdown files that copy a PDF keep their words in keyword search but aren't embedded: the PDF
    /// carries the meaning. PDFs themselves are never skipped.
    public func markCopies(only path: String? = nil, log: (String) -> Void = { _ in }) throws {
        let p: SQLValue = path.map { .text($0) } ?? .null
        let candidates = try write.query("""
            SELECT id FROM docs WHERE embed = 1 AND state = 'ok' AND
            (path LIKE '%.txt' OR path LIKE '%.md' OR path LIKE '%.html' OR path LIKE '%.htm') AND (? IS NULL OR path = ?)
            """, [p, p]).compactMap { $0[0].int }
        var copies = 0
        for doc in candidates {
            let total = try write.query("SELECT COUNT(*) FROM shingles WHERE doc = ?", [.int(doc)]).first?[0].int ?? 0
            guard total >= 50 else { continue }
            let best = try write.query("""
                SELECT COUNT(*) FROM shingles a JOIN shingles b ON b.hash = a.hash AND b.doc != a.doc
                JOIN docs d ON d.id = b.doc WHERE a.doc = ? AND lower(d.path) LIKE '%.pdf'
                GROUP BY b.doc ORDER BY 1 DESC LIMIT 1
                """, [.int(doc)]).first?[0].int ?? 0
            if Double(best) / Double(total) >= 0.3 {
                try write.query("UPDATE docs SET embed = 0 WHERE id = ?", [.int(doc)])
                copies += 1
            }
        }
        if copies > 0 { log("\(copies) text copies of PDFs: found by their words, not embedded again") }
    }

    /// Reads again the PDFs whose scanned pages were waiting for the charger.
    @discardableResult
    public func readScans(log: (String) -> Void = { _ in }) throws -> Int {
        guard !Config.onBattery(), !Settings.current.paused else { return 0 }
        let waiting = try write.query("SELECT path, mtime, size FROM docs WHERE state = 'ocr'")
        for row in waiting { try add(row[0].text ?? "", mtime: row[1].double ?? 0, size: row[2].int ?? 0) }
        if !waiting.isEmpty { log("read \(waiting.count) scanned PDFs") }
        return waiting.count
    }

    // MARK: embedding

    /// Beyond its title and first pages, a document is embedded in full only if it's in use: changed, added or
    /// opened from Cedar within this long. Older ones stay searchable by every word and by the meaning of their
    /// first pages, and are embedded in full the moment you open one. This is what keeps a library of tens of
    /// thousands of documents from costing days of GPU time.
    public static let deepWindow: Double = 2 * 365 * 86400

    /// SQL condition on chunks c / docs d: this passage should have a vector.
    static func wanted(now: Double = Date().timeIntervalSince1970) -> String {
        Settings.current.deepEverything ? "1" : "(c.first_pass = 1 OR max(COALESCE(d.opened, 0), d.mtime) > \(now - deepWindow))"
    }

    /// You opened this document from Cedar: read it in full, soon.
    public func opened(_ path: String) throws {
        try write.query("UPDATE docs SET opened = ? WHERE path = ?", [.double(Date().timeIntervalSince1970), .text(path)])
    }

    /// Embeds the next passages, one at a time: first pages of every document before the rest. Stops early when
    /// `pause` says someone is searching. Returns how many it did.
    public func embedSome(model: (String) -> [Float]?, limit: Int = 8, firstPassOnly: Bool = false,
                          pause: () -> Bool = { false }) throws -> Int {
        let todo = try write.query("""
            SELECT c.id, c.doc, c.text FROM chunks c JOIN docs d ON d.id = c.doc
            WHERE c.vec IS NULL AND d.embed = 1 AND c.region IN ('head', 'body') AND \(Self.wanted())
            \(firstPassOnly ? "AND c.first_pass = 1" : "")
            ORDER BY c.first_pass DESC, -max(COALESCE(d.opened, 0), d.mtime), c.doc, c.ord LIMIT ?
            """, [.int(Int64(limit))])
        var done = 0
        for row in todo {
            if pause() { break }
            guard let id = row[0].int, let doc = row[1].int, let text = row[2].text else { continue }
            guard let vector = model(text) else { break }
            let half = vector.map { Float16($0) }
            let blob = half.withUnsafeBufferPointer { Data(buffer: $0) }
            // A document deleted meanwhile keeps no vectors.
            guard try write.query("UPDATE chunks SET vec = ? WHERE id = ? RETURNING id", [.blob(blob), .int(id)]).first != nil
            else { continue }
            let bits = half.withUnsafeBufferPointer { Bits.code($0) }
            let bitsBlob = bits.withUnsafeBufferPointer { Data(buffer: $0) }
            try write.query("INSERT OR REPLACE INTO codes(chunk, doc, bits) VALUES(?,?,?)", [.int(id), .int(doc), .blob(bitsBlob)])
            append(chunk: id, doc: doc, vector: half, bits: bits)
            done += 1
            // Passages with the same text ("paper (1).pdf"): one embedding serves them all.
            for twin in try write.query("""
                UPDATE chunks SET vec = ? WHERE vec IS NULL AND substr(text, 1, 40) = substr(?, 1, 40) AND text = ?
                AND region IN ('head', 'body') AND doc IN (SELECT id FROM docs WHERE embed = 1) RETURNING id, doc
                """, [.blob(blob), .text(text), .text(text)]) {
                try write.query("INSERT OR REPLACE INTO codes(chunk, doc, bits) VALUES(?,?,?)", [twin[0], twin[1], .blob(bitsBlob)])
                append(chunk: twin[0].int ?? 0, doc: twin[1].int ?? 0, vector: half, bits: bits)
            }
        }
        return done
    }

    public func progress() -> Progress {
        var p = Progress()
        p.documents = Int((try? read.query("SELECT COUNT(*) FROM docs WHERE state IN ('ok', 'ocr')").first?[0].int) ?? 0 ?? 0)
        p.vectors = Int((try? read.query("SELECT COUNT(*) FROM chunks WHERE vec IS NOT NULL").first?[0].int) ?? 0 ?? 0)
        if let row = try? read.query("""
            SELECT COUNT(*), SUM(c.first_pass) FROM chunks c JOIN docs d ON d.id = c.doc
            WHERE c.vec IS NULL AND d.embed = 1 AND c.region IN ('head', 'body') AND \(Self.wanted())
            """).first {
            p.to_embed = Int(row[0].int ?? 0)
            p.first_pass_left = Int(row[1].int ?? 0)
        }
        return p
    }

    // MARK: search

    static func tokens(_ text: String, pattern: String = #"\w+"#) -> [String] {
        let lower = text.lowercased()
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = lower as NSString
        return re.matches(in: lower, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// `queryVector`: the query embedded, for the meaning part; nil searches by words only.
    public func search(_ query: String, queryVector: [Float]? = nil, limit: Int = 15) throws -> [DocHit] {
        let every = Self.tokens(query)
        var terms = every.filter { !Self.stopwords.contains($0) }
        if terms.isEmpty { terms = every }
        guard !terms.isEmpty else { return [] }
        let typingLast = !query.hasSuffix(" ")
        let db = read
        let total = Double(max(try db.query("SELECT COUNT(*) FROM docs").first?[0].int ?? 1, 1))

        // Words: where in each document each word is found, weighted by how rare the word is.
        var patterns: [String] = [], weights: [Double] = []
        var found: [Int64: [Double]] = [:]
        for (t, term) in terms.enumerated() {
            var pattern = "\"" + term + "\""
            if (typingLast && t == terms.count - 1 && term.count >= 2) || !indexed(term) { pattern += "*" }
            patterns.append(pattern)
            var perDoc: [Int64: Double] = [:]
            for column in Self.columns {
                for row in (try? db.query("SELECT rowid FROM docfts WHERE docfts MATCH ?", [.text("\(column) : \(pattern)")])) ?? [] {
                    let doc = row[0].int ?? 0
                    perDoc[doc] = max(perDoc[doc] ?? 0, Self.fieldWeight[column]!)
                }
            }
            weights.append(log((total + 1) / (Double(perDoc.count) + 1)) + 0.1)
            for (doc, w) in perDoc { found[doc, default: [Double](repeating: 0, count: terms.count)][t] = w }
        }
        let weightSum = weights.reduce(0, +)
        var strength: [Int64: Double] = [:]
        if !found.isEmpty {
            let ranked = ((try? db.query("SELECT rowid FROM docfts WHERE docfts MATCH ? ORDER BY bm25(docfts, 4.0, 4.0, 1.0, 0.1) LIMIT 500",
                                         [.text(patterns.joined(separator: " OR "))])) ?? []).compactMap { $0[0].int }
            for (i, d) in ranked.enumerated() { strength[d] = 1 - Double(i) / Double(ranked.count) }
        }
        var words: [Int64: Double] = [:]
        for (doc, ws) in found { words[doc] = zip(weights, ws).map(*).reduce(0, +) / weightSum }

        // Meaning: every passage scored, put on this query's scale, best passage per document.
        var meaning: [Int64: (z: Double, chunk: Int64)] = [:]
        if let q = queryVector, q.count == Self.dim, vectorsLoaded, rows >= 8 {
            let (hits, mean, deviation) = closest(q)
            let scale = max(deviation, 0.02)
            for hit in hits.prefix(400) {
                if hit.score < Self.minCosine { break }     // sorted by score: nothing after this is close enough
                if meaning[hit.doc] == nil { meaning[hit.doc] = (Double((hit.score - mean) / scale), hit.chunk) }
            }
        }

        var candidates = Set(words.filter { $0.value >= 0.45 }.keys)
        for (d, m) in meaning where m.z >= Self.zGate { candidates.insert(d) }
        guard !candidates.isEmpty else { return [] }
        let marks = candidates.map { _ in "?" }.joined(separator: ",")
        let ids = candidates.map { SQLValue.int($0) }
        var heads: [Int64: String] = [:]
        for row in try db.query("SELECT doc, text FROM chunks WHERE region = 'head' AND doc IN (\(marks))", ids) {
            heads[row[0].int ?? 0] = String((row[1].text ?? "").prefix(400))
        }
        var kinds: [Int64: Double] = [:], titled: [Int64: Double] = [:]
        var info: [Int64: (path: String, title: String?, pages: Int?)] = [:]
        for row in try db.query("SELECT id, title, path, embed, pages FROM docs WHERE id IN (\(marks))", ids) {
            let d = row[0].int ?? 0, path = row[2].text ?? "", ext = Config.ext(path)
            info[d] = (path, row[1].text, row[4].int.map { Int($0) })
            kinds[d] = Self.kindPrior[ext] ?? 0
            if row[3].int == 0, ["txt", "md", "html", "htm"].contains(ext) { kinds[d]! -= 1.0 }   // a text copy of a PDF
            // Your words in the title, the file name or the author line: the strongest sign it's the one you mean.
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let name = Self.tokens([row[1].text ?? "", stem, heads[d] ?? ""].joined(separator: " "))
            let nameSet = Set(name)
            var hits = 0
            for (i, t) in terms.enumerated() {
                if nameSet.contains(t) || (i == terms.count - 1 && typingLast && name.contains { $0.hasPrefix(t) }) { hits += 1 }
            }
            titled[d] = Double(hits) / Double(terms.count)
        }
        var scored: [(score: Double, doc: Int64)] = []
        for d in candidates {
            let z = meaning[d]?.z ?? 0, w = words[d] ?? 0
            // Meaning counts only where a passage stands out; a near-miss adds nothing.
            let meant = z >= Self.zGate ? z : 0
            scored.append((meant + Self.wordWeight * pow(w, 1.5) + Self.titleWeight * pow(titled[d] ?? 0, 2)
                           + (strength[d] ?? 0) + (kinds[d] ?? 0), d))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.doc > $1.doc }

        var out: [DocHit] = []
        for (score, d) in scored.prefix(limit) {
            guard let doc = info[d] else { continue }
            let m = meaning[d], w = words[d] ?? 0
            var page: Int?, snippet: String?, region: String?
            if w > 0 && (w >= 0.99 || m == nil || m!.z < Self.zGate) {
                let match = "d : \"x\(d)\" AND (\(patterns.joined(separator: " OR ")))"
                if let hit = try? db.query("""
                    SELECT c.page, c.region,
                    snippet(fts, CASE c.region WHEN 'head' THEN 1 WHEN 'body' THEN 2 ELSE 3 END, '«', '»', '…', 24)
                    FROM fts JOIN chunks c ON c.id = fts.rowid WHERE fts MATCH ? AND c.region != 'name'
                    ORDER BY bm25(fts, 1.0, 3.0, 1.0, 0.1, 0.0) LIMIT 1
                    """, [.text(match)]).first {
                    page = hit[0].int.map { Int($0) }; region = hit[1].text; snippet = hit[2].text
                }
            }
            if snippet == nil, let m, let hit = try? db.query("SELECT page, region, text FROM chunks WHERE id = ?", [.int(m.chunk)]).first {
                page = hit[0].int.map { Int($0) }; region = hit[1].text
                let text = hit[2].text ?? ""
                snippet = String(text.prefix(260)) + (text.count > 260 ? "…" : "")
            }
            out.append(DocHit(path: doc.path, title: doc.title, pages: doc.pages, page: page, snippet: snippet, region: region,
                              score: (score * 1000).rounded() / 1000, z: m.map { ($0.z * 100).rounded() / 100 },
                              words: (w * 1000).rounded() / 1000))
        }
        return out
    }

    /// True when the word occurs as written somewhere (else it's matched as the start of longer words).
    private func indexed(_ term: String) -> Bool {
        ((try? read.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text("\"" + term + "\"")])) ?? []).first != nil
    }
}

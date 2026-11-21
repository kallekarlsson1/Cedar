import Foundation

/// Builds an index of a folder of test documents and checks that searches find what they should
/// (`Cedar --eval corpus-folder queries.json [--words-only]`, with CEDAR_DATA pointing at a scratch folder).
public enum Eval {
    struct Query: Decodable { let q: String; let expect: [String]; let tag: String }

    /// Share of queries whose expected file must come first / in the first three.
    static let bars: [String: (Double, Double)] = [
        "author": (0.8, 1.0), "title": (1.0, 1.0), "typing": (1.0, 1.0), "exact": (1.0, 1.0), "words": (1.0, 1.0),
        "scan": (1.0, 1.0), "meaning": (0.8, 0.9), "nothing": (1.0, 1.0),
    ]

    public static func run(corpus: String, queries: String, modelPath: String?) throws -> Bool {
        Config.ignoreBattery = true
        let index = try ContentIndex()
        var wanted: [String: (mtime: Double, size: Int64)] = [:]
        let walker = FileManager.default.enumerator(atPath: corpus)
        while let rel = walker?.nextObject() as? String {
            let path = corpus + "/" + rel
            guard Config.docExtensions.contains(Config.ext(path)),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            wanted[path] = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (attrs[.size] as? Int64) ?? 0)
        }
        try index.sync(wanted)
        try index.markCopies()
        var model: EmbeddingModel?
        if let modelPath {
            model = try EmbeddingModel(path: modelPath)
            try index.makeMissingCodes()
            index.loadVectors()
            let started = Date()
            var n = 0
            while true {
                let done = try index.embedSome(model: { model!.embed($0) }, limit: 16)
                if done == 0 { break }
                n += done
            }
            print("embedded \(n) passages in \(Int(Date().timeIntervalSince(started)))s")
        }
        let items = try JSONDecoder().decode([Query].self, from: Data(contentsOf: URL(fileURLWithPath: queries)))
        var scores: [String: [(Bool, Bool)]] = [:]
        var order: [String] = []
        for item in items {
            if model == nil && (item.tag == "meaning" || item.tag == "nothing") { continue }
            let hits = try index.search(item.q, queryVector: model?.embedQuery(item.q))
            let names = hits.map { ($0.path as NSString).lastPathComponent }
            var first: Bool, top3: Bool
            if item.tag == "nothing" {
                first = !hits.contains { $0.z != nil && $0.words < 0.45 }
                top3 = first
            } else {
                first = names.first.map { item.expect.contains($0) } ?? false
                top3 = names.prefix(3).contains { item.expect.contains($0) }
            }
            if scores[item.tag] == nil { order.append(item.tag) }
            scores[item.tag, default: []].append((first, top3))
            if !first { print("  miss [\(item.tag)] \(item.q): got \(Array(names.prefix(3))), wanted \(item.expect)") }
        }
        var ok = true
        print("\nkind       queries  first  top 3")
        for tag in order {
            let rows = scores[tag]!
            let first = Double(rows.filter(\.0).count) / Double(rows.count), top3 = Double(rows.filter(\.1).count) / Double(rows.count)
            let passed = first >= (bars[tag]?.0 ?? 1) && top3 >= (bars[tag]?.1 ?? 1)
            ok = ok && passed
            print(String(format: "%@ %7d %6.2f %6.2f  %@", tag.padding(toLength: 10, withPad: " ", startingAt: 0), rows.count, first, top3,
                         passed ? "" : "<- below the bar"))
        }
        return ok
    }
}

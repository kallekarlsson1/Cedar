import AppKit

/// Installed apps, matched by prefix, word, initials or subsequence.
final class Apps {
    struct App { let name: String; let url: URL; let lower: String; let initials: String; let words: [String] }

    private(set) var all: [App] = []
    private let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                           "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
                           "/System/Library/CoreServices/Applications", "/System/Cryptexes/App/System/Applications"]

    init() { reload() }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            var seen = Set<String>(), found: [App] = []
            for folder in self.folders {
                guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                    var name = FileManager.default.displayName(atPath: url.path)
                    if name.hasSuffix(".app") { name.removeLast(4) }
                    guard seen.insert(name.lowercased()).inserted else { continue }
                    found.append(Self.make(name, url))
                }
            }
            for extra in ["/System/Library/CoreServices/Finder.app"] {
                let url = URL(fileURLWithPath: extra)
                let name = FileManager.default.displayName(atPath: extra).replacingOccurrences(of: ".app", with: "")
                if seen.insert(name.lowercased()).inserted { found.append(Self.make(name, url)) }
            }
            DispatchQueue.main.async { self.all = found }
        }
    }

    private static func make(_ name: String, _ url: URL) -> App {
        let lower = name.lowercased()
        // Split into words at separators and at lower-to-upper case changes.
        var words: [String] = []
        var current = ""
        for ch in name {
            if ch == " " || ch == "-" || ch == "_" || ch == "." {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
            } else if ch.isUppercase, let last = current.last, last.isLowercase {
                words.append(current.lowercased()); current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return App(name: name, url: url, lower: lower, initials: String(words.compactMap(\.first)), words: words)
    }

    /// Matches with scores from 100 (exact) down to about 40 (subsequence), best first.
    func search(_ query: String) -> [(App, Double)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [(App, Double)] = []
        for app in all {
            var score: Double
            if app.lower == q { score = 100 }
            else if app.lower.hasPrefix(q) { score = 92 - min(Double(app.lower.count - q.count) * 0.3, 6) }
            else if app.words.contains(where: { $0.hasPrefix(q) }) { score = 80 }
            else if app.initials.hasPrefix(q), q.count >= 2 { score = 76 }
            else if app.lower.replacingOccurrences(of: " ", with: "").hasPrefix(q.replacingOccurrences(of: " ", with: "")) { score = 74 }
            else if app.lower.contains(q), q.count >= 3 { score = 60 }
            else if q.count >= 3, let gaps = Self.scattered(q, in: app.lower), gaps <= 6 { score = 45 - Double(gaps) }
            else { continue }
            out.append((app, score))
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// Subsequence match. Returns the number of skipped letters, or nil.
    private static func scattered(_ q: String, in name: String) -> Int? {
        var gaps = 0, started = false
        var qi = q.startIndex
        for ch in name {
            guard qi < q.endIndex else { break }
            if ch == q[qi] { qi = q.index(after: qi); started = true }
            else if started { gaps += 1 }
        }
        return qi == q.endIndex ? gaps : nil
    }
}

/// Open counts and times, used to rank frequently used items higher.
final class Usage {
    private var entries: [String: [Double]] = [:]   // path: [count, last opened]
    private let file: URL

    init(dataDir: URL) {
        file = dataDir.appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: [Double]].self, from: data) { entries = saved }
    }

    func opened(_ path: String) {
        let now = Date().timeIntervalSince1970
        let count = (entries[path]?.first ?? 0) + 1
        entries[path] = [count, now]
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }

    /// Boost from 0 to 20, decaying with a two-week half-life.
    func boost(_ path: String) -> Double {
        guard let e = entries[path], e.count == 2 else { return 0 }
        let days = (Date().timeIntervalSince1970 - e[1]) / 86400
        return min(20, 7 * log2(1 + e[0])) * pow(0.5, days / 14)
    }
}

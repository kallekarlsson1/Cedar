import AppKit
import Foundation
import PDFKit

/// A passage of a document. Regions:
///  head  title and author block (page 1 up to the abstract)
///  body  overlapping ~200-word passages, with page numbers
///  refs  the reference list; keyword-indexed with a low weight, never embedded
public struct Passage {
    public let region: String
    public let page: Int?
    public let text: String
}

public struct ReadDocument {
    public var title: String?
    public var pages: Int?
    public var passages: [Passage]
    public var embed = true   // false: keyword search only
    public var pendingOCR = false   // scanned pages not read yet
}

public enum Extract {
    static let words = 200, overlap = 40
    static let ocrPageLimit = 400

    static let abstract = regex(#"^\s*(abstract|a b s t r a c t|summary|introduction|1\.?\s+introduction|sammanfattning)\b"#)
    static let references = regex(#"^\s*(\d+\.?\s*)?(references|bibliography|works cited|literature cited|referenser|literaturverzeichnis|cited literature)\s*$"#)
    static let junkTitle = regex(#"arxiv|untitled|microsoft word|^\s*$|\.(docx?|pdf|tex|dvi)$|^[\d\W_]+$"#)

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
    }

    static func matches(_ re: NSRegularExpression, _ text: String) -> [NSRange] {
        re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    public static func read(_ path: String, allowOCR: Bool = true) -> ReadDocument? {
        let ext = Config.ext(path)
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        switch ext {
        case "pdf":
            return size > Config.maxPDFBytes ? nil : pdf(path, allowOCR: allowOCR)
        case "docx", "doc", "rtf", "odt":
            guard let text = try? NSAttributedString(url: URL(fileURLWithPath: path), options: [:], documentAttributes: nil)
            else { return nil }
            return plain(path, text.string)
        case "pptx", "xlsx":
            guard let text = office(path, ext) else { return nil }
            return plain(path, text)
        default:
            guard size <= Config.maxTextBytes, let data = FileManager.default.contents(atPath: path) else { return nil }
            var text = String(decoding: data, as: UTF8.self)
            if ext == "html" || ext == "htm" { text = stripHTML(text) }
            return plain(path, text)
        }
    }

    // MARK: PDF

    static func pdf(_ path: String, allowOCR: Bool) -> ReadDocument? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else { return nil }
        var pages: [String] = []
        pages.reserveCapacity(doc.pageCount)
        for i in 0..<doc.pageCount {
            autoreleasepool { pages.append(doc.page(at: i)?.string ?? "") }
        }
        let title = pdfTitle(doc)

        // Pages without a text layer go through OCR.
        var pending = false
        let blank = pages.indices.filter { pages[$0].trimmingCharacters(in: .whitespacesAndNewlines).count < 30 }
            .prefix(ocrPageLimit).map { $0 + 1 }
        if !blank.isEmpty && allowOCR {
            if Config.onBattery() {
                pending = Double(blank.count) > Double(pages.count) * 0.5
            } else {
                for (number, text) in OCR.run(path: path, pages: Array(blank)) {
                    if let n = Int(number), n >= 1, n <= pages.count { pages[n - 1] = text }
                }
            }
        }

        var passages: [Passage] = []
        let first = pages.first ?? ""
        var head = String(first.prefix(1500))
        if let m = matches(abstract, first).first, m.location > 40 {
            head = (first as NSString).substring(to: m.location)
        }
        if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { passages.append(Passage(region: "head", page: 1, text: squash(head))) }

        // The reference list starts at the last "References" heading in the second half.
        var refsAt: (page: Int, offset: Int)?
        var i = pages.count - 1
        while i >= pages.count / 2 && i >= 0 {
            if let last = matches(references, pages[i]).last { refsAt = (i, last.location); break }
            i -= 1
        }
        for (i, text) in pages.enumerated() {
            if let r = refsAt, i > r.page {
                passages += windows(text).map { Passage(region: "refs", page: i + 1, text: $0) }
            } else if let r = refsAt, i == r.page {
                let ns = text as NSString
                passages += windows(ns.substring(to: r.offset)).map { Passage(region: "body", page: i + 1, text: $0) }
                passages += windows(ns.substring(from: r.offset)).map { Passage(region: "refs", page: i + 1, text: $0) }
            } else {
                passages += windows(text).map { Passage(region: "body", page: i + 1, text: $0) }
            }
        }
        return ReadDocument(title: title, pages: pages.count, passages: passages, embed: wordy(passages), pendingOCR: pending)
    }

    static func pdfTitle(_ doc: PDFDocument) -> String? {
        if let meta = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           meta.count > 8, matches(junkTitle, meta).isEmpty {
            return meta.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fall back to the largest text on page 1.
        guard let text = doc.page(at: 0)?.attributedString, text.length > 0 else { return nil }
        var biggest: CGFloat = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let run = text.attributedSubstring(from: range).string
            if let font = value as? NSFont, !run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                biggest = max(biggest, (font.pointSize * 10).rounded() / 10)
            }
        }
        var parts: [String] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont, (font.pointSize * 10).rounded() / 10 == biggest {
                parts.append(text.attributedSubstring(from: range).string)
            }
        }
        let title = parts.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return title.count > 8 && title.count < 300 && matches(junkTitle, title).isEmpty ? title : nil
    }

    // MARK: text, notes, Office

    static func plain(_ path: String, _ text: String) -> ReadDocument {
        var passages: [Passage] = []
        var title: String?
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            let ext = Config.ext(path)
            if ["md", "markdown", "org", "rst"].contains(ext) { title = mdTitle(text) }
            // For notes, the head is the front matter and title.
            var head = lines.prefix(3).joined(separator: "\n")
            if let block = frontMatter(text) { head = block.whole + "\n" + (title ?? "") }
            passages.append(Passage(region: "head", page: nil, text: String(squash(head).prefix(1500))))
        }
        passages += windows(text).map { Passage(region: "body", page: nil, text: $0) }
        // "paper.pdf.txt" is a text dump of a PDF: keyword index only.
        let embed = !path.lowercased().hasSuffix(".pdf.txt") && wordy(passages)
        return ReadDocument(title: title, pages: nil, passages: passages, embed: embed)
    }

    static let frontMatterRE = try! NSRegularExpression(pattern: #"\A---\s*\n(.*?)\n---\s*(\n|\z)"#, options: [.dotMatchesLineSeparators])

    static func frontMatter(_ text: String) -> (whole: String, inner: String, end: Int)? {
        let ns = text as NSString
        guard let m = frontMatterRE.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range), ns.substring(with: m.range(at: 1)), m.range.location + m.range.length)
    }

    /// Title from front matter `title:`, else the first heading.
    public static func mdTitle(_ text: String) -> String? {
        var body = text
        if let block = frontMatter(text) {
            let re = regex(#"^title:\s*["']?(.+?)["']?\s*$"#)
            if let m = re.firstMatch(in: block.inner, range: NSRange(location: 0, length: (block.inner as NSString).length)) {
                let t = (block.inner as NSString).substring(with: m.range(at: 1))
                if t.count > 2 && t.count < 200 { return t }
            }
            body = (text as NSString).substring(from: block.end)
        }
        let heading = regex(#"^#{1,3}\s+(.+?)\s*#*\s*$"#)
        if let m = heading.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
            let t = (body as NSString).substring(with: m.range(at: 1))
            if t.count > 2 && t.count < 200 { return t }
        }
        return nil
    }

    /// Text of a .pptx or .xlsx file, extracted with /usr/bin/unzip.
    static func office(_ path: String, _ ext: String) -> String? {
        let members = ext == "pptx" ? ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"]
                                    : ["xl/sharedStrings.xml", "xl/worksheets/sheet*.xml"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", "-qq", path] + members
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let xml = String(decoding: data, as: UTF8.self)
        let pattern = ext == "pptx" ? #"<a:t>([^<]*)</a:t>|(</a:p>)"# : #"<t[^>]*>([^<]*)</t>|<v>([^<]*)</v>"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = xml as NSString
        var out: [String] = []
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound { out.append(unescape(ns.substring(with: m.range(at: 1)))) }
            else if ext == "pptx" { out.append("\n") }
            else if m.range(at: 2).location != NSNotFound { out.append(ns.substring(with: m.range(at: 2))) }
        }
        return out.joined(separator: " ")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func stripHTML(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        return unescape(t)
    }

    // MARK: pieces

    static func windows(_ text: String) -> [String] {
        let all = text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
        guard !all.isEmpty else { return [] }
        var out: [String] = []
        var start = 0
        let step = words - overlap
        while start < max(all.count - overlap, 1) {
            out.append(all[start..<min(start + words, all.count)].joined(separator: " "))
            start += step
        }
        return out
    }

    static func squash(_ text: String) -> String {
        text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// False for text that is mostly digits (data tables).
    static func wordy(_ passages: [Passage]) -> Bool {
        let sample = passages.prefix(20).map(\.text).joined(separator: " ")
        guard !sample.isEmpty else { return false }
        var letters = 0, nonSpace = 0
        for ch in sample where ch != " " { nonSpace += 1; if ch.isLetter { letters += 1 } }
        return Double(letters) / Double(max(nonSpace, 1)) > 0.55
    }
}

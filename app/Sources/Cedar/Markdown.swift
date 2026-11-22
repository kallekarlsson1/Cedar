import AppKit

/// Renders Markdown to an attributed string: headings, emphasis, lists, quotes, code, tables, links and
/// [[wiki links]]. Front matter is shown as a small header.
enum Markdown {
    /// Text size multiplier, changed by zooming in the reader.
    static var scale: CGFloat = 1
    static var body: NSFont { .systemFont(ofSize: 14 * scale) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: 12.5 * scale, weight: .regular) }

    static func render(_ source: String, highlight words: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Front matter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let block = lines[1..<end].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let style = paragraph(spacing: 1)
            for line in block {
                let clean = line.replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
                out.append(NSAttributedString(string: clean + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
            lines = Array(lines[(end + 1)...])
        }

        var inCode = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode {
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                    .paragraphStyle: paragraph(spacing: 0, indent: 10)]))
                continue
            }
            if trimmed.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)])); continue }

            // Headings.
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = trimmed[m].filter { $0 == "#" }.count
                let size: CGFloat = [22, 18, 16, 14.5, 14, 14][level - 1] * scale
                let text = String(trimmed[m.upperBound...]).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                out.append(inline(text, font: .systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold),
                                  style: paragraph(spacing: 6, before: level <= 2 ? 10 : 6)))
                continue
            }
            // Horizontal rule.
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                out.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", attributes: [
                    .font: body, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph(spacing: 6)]))
                continue
            }
            // Block quotes and callouts.
            if trimmed.hasPrefix(">") {
                var text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                text = text.replacingOccurrences(of: #"^\[!(\w+)\][+-]?\s*"#, with: "$1: ", options: .regularExpression)
                out.append(inline(text, font: body, color: .secondaryLabelColor, style: paragraph(spacing: 3, indent: 16)))
                continue
            }
            // Lists and checkboxes, nested by indentation.
            if let m = line.range(of: #"^(\s*)([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
                let lead = line[m]
                let depth = CGFloat(lead.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
                var bullet = "•"
                if let n = lead.range(of: #"\d+"#, options: .regularExpression) { bullet = lead[n] + "." }
                if lead.contains("[ ]") { bullet = "☐" } else if lead.lowercased().contains("[x]") { bullet = "☑" }
                let indent = 6 + depth * 14
                let style = paragraph(spacing: 2, indent: indent + 18, firstIndent: indent)
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
                out.append(inline(bullet + "\t" + String(line[m.upperBound...]), font: body, style: style))
                continue
            }
            // Tables, aligned in a monospaced font.
            if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                var j = i - 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                    if row.range(of: #"^\|[\s:|-]+\|?$"#, options: .regularExpression) != nil { continue }   // divider row
                    var cells = row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    rows.append(cells.map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") })
                }
                i = j
                let columns = rows.map(\.count).max() ?? 0
                let widths = (0..<columns).map { c in min(rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0, 26) }
                // Hanging indent so a long last cell wraps under its own column.
                let tableFont = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
                let charWidth = ("0" as NSString).size(withAttributes: [.font: tableFont]).width
                let lastStart = CGFloat(widths.dropLast().reduce(0, +) + 3 * max(columns - 1, 0)) * charWidth
                let rowStyle = paragraph(spacing: 3, indent: min(lastStart, 500), firstIndent: 0)
                for (n, row) in rows.enumerated() {
                    let text = row.enumerated().map { c, cell in
                        c == columns - 1 ? cell : String(cell.prefix(26)).padding(toLength: widths[c], withPad: " ", startingAt: 0)
                    }.joined(separator: "   ")
                    out.append(NSAttributedString(string: text + "\n", attributes: [
                        .font: n == 0 ? NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .semibold) : tableFont,
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: rowStyle]))
                }
                continue
            }
            // Paragraph: join lines up to the next blank line or block.
            var text = trimmed
            while i < lines.count {
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.range(of: #"^(#{1,6}\s|>|```|~~~|\||([-*+]|\d+[.)])\s)"#, options: .regularExpression) != nil { break }
                text += " " + next
                i += 1
            }
            out.append(inline(text, font: body, style: paragraph(spacing: 8)))
        }

        mark(words, in: out)
        return out
    }

    /// Plain text, shown as written.
    static func plain(_ source: String, monospaced: Bool, highlight words: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: source.replacingOccurrences(of: "\r\n", with: "\n"), attributes: [
            .font: monospaced ? mono : body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(spacing: 2)])
        mark(words, in: out)
        return out
    }

    private static func mark(_ words: [String], in out: NSMutableAttributedString) {
        let plain = out.string as NSString
        for word in words where word.count >= 3 {
            var range = NSRange(location: 0, length: plain.length)
            while true {
                let found = plain.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                if found.location == NSNotFound { break }
                out.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)], range: found)
                let next = found.location + found.length
                range = NSRange(location: next, length: plain.length - next)
            }
        }
    }

    private static func paragraph(spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0, firstIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = before
        p.lineSpacing = 3
        p.headIndent = indent
        p.firstLineHeadIndent = firstIndent ?? indent
        return p
    }

    /// Applies inline markup to one block.
    private static func inline(_ raw: String, font: NSFont, color: NSColor = .labelColor, style: NSParagraphStyle) -> NSAttributedString {
        var text = raw
        // [[page|label]] becomes label, [[page]] becomes page, ==mark== loses its markers.
        text = text.replacingOccurrences(of: #"!?\[\[([^\]|]*\|)?([^\]]+)\]\]"#, with: "⟦$2⟧", options: .regularExpression)
        text = text.replacingOccurrences(of: "==", with: "")
        let result = NSMutableAttributedString()
        if let parsed = try? NSAttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            result.append(parsed)
        } else {
            result.append(NSAttributedString(string: text))
        }
        let all = NSRange(location: 0, length: result.length)
        // Convert presentation intents to fonts.
        result.enumerateAttribute(.inlinePresentationIntent, in: all) { value, range, _ in
            var f = font
            var extra: [NSAttributedString.Key: Any] = [:]
            if let raw = value as? Int {
                let intent = InlinePresentationIntent(rawValue: UInt(raw))
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty { f = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
                if intent.contains(.code) { f = mono; extra[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07) }
                if intent.contains(.strikethrough) { extra[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            extra[.font] = f
            result.addAttributes(extra, range: range)
        }
        result.addAttributes([.foregroundColor: color, .paragraphStyle: style], range: all)
        result.enumerateAttribute(.link, in: all) { value, range, _ in
            if value != nil { result.addAttributes([.foregroundColor: NSColor.linkColor], range: range) }
        }
        // Color wiki links and drop the brackets.
        let s = result.string as NSString
        let re = try! NSRegularExpression(pattern: "⟦([^⟧]+)⟧")
        for m in re.matches(in: result.string, range: NSRange(location: 0, length: s.length)).reversed() {
            let name = NSMutableAttributedString(attributedString: result.attributedSubstring(from: m.range(at: 1)))
            name.addAttributes([.foregroundColor: NSColor.controlAccentColor], range: NSRange(location: 0, length: name.length))
            result.replaceCharacters(in: m.range, with: name)
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        return result
    }
}

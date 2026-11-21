import Foundation

/// Arithmetic typed into the search field: 24*1.25, (3+4)^2, sqrt(2), 15% of 80, 1,5 * 2 (Swedish decimal comma).
/// A small parser of its own (NSExpression crashes the app on input it can't parse).
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        var text = input.lowercased().trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        // "15% of 80" → 15/100*80
        text = text.replacingOccurrences(of: #"(\d+(?:[.,]\d+)?)\s*%\s*of\s*"#, with: "($1/100)*", options: .regularExpression)
        // Only math: digits, operators, parentheses and a few function names.
        guard text.range(of: #"^[0-9\s.,+\-*/×÷^%()a-z]+$"#, options: .regularExpression) != nil else { return nil }
        let hasOperator = text.range(of: #"[+\-*/×÷^%]|sqrt|sin|cos|tan|log|ln|abs|pi"#, options: .regularExpression) != nil
        guard hasOperator, text.range(of: #"\d|pi"#, options: .regularExpression) != nil else { return nil }
        var parser = Parser(tokens: tokenize(text))
        guard let tokens = parser.tokens, !tokens.isEmpty, let value = parser.expression(), parser.atEnd,
              value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(value) < 1 ? 10 : 6
        f.usesGroupingSeparator = true
        f.locale = Locale.current
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    private enum Token: Equatable { case number(Double), op(Character), open, close, name(String) }

    private static func tokenize(_ s: String) -> [Token]? {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c.isNumber || ((c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var digits = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," {
                    digits.append(chars[j] == "," ? "." : chars[j]); j += 1
                }
                guard let v = Double(digits) else { return nil }
                out.append(.number(v)); i = j; continue
            }
            if c.isLetter {
                var j = i
                var word = ""
                while j < chars.count, chars[j].isLetter { word.append(chars[j]); j += 1 }
                out.append(.name(word)); i = j; continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%": out.append(.op(c))
            case "×": out.append(.op("*"))
            case "÷": out.append(.op("/"))
            case "(": out.append(.open)
            case ")": out.append(.close)
            default: return nil
            }
            i += 1
        }
        return out
    }

    private struct Parser {
        let tokens: [Token]?
        var pos = 0
        init(tokens: [Token]?) { self.tokens = tokens }
        var atEnd: Bool { pos == (tokens?.count ?? 0) }
        private var peek: Token? { guard let t = tokens, pos < t.count else { return nil }; return t[pos] }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while case .op(let c)? = peek, c == "+" || c == "-" {
                pos += 1
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }
        mutating func term() -> Double? {
            guard var left = power() else { return nil }
            while true {
                if case .op(let c)? = peek, c == "*" || c == "/" {
                    pos += 1
                    guard let right = power() else { return nil }
                    left = c == "*" ? left * right : left / right
                } else if case .op("%")? = peek {      // 50% → 0.5
                    pos += 1
                    left /= 100
                } else if let p = peek, p == .open || { if case .name = p { return true }; return false }() {
                    guard let right = power() else { return nil }   // 2(3+4), 2pi
                    left *= right
                } else { return left }
            }
        }
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if case .op("^")? = peek {
                pos += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }
        mutating func unary() -> Double? {
            if case .op("-")? = peek { pos += 1; return unary().map { -$0 } }
            if case .op("+")? = peek { pos += 1; return unary() }
            return primary()
        }
        mutating func primary() -> Double? {
            guard let t = peek else { return nil }
            pos += 1
            switch t {
            case .number(let v): return v
            case .open:
                guard let v = expression(), peek == .close else { return nil }
                pos += 1
                return v
            case .name(let n):
                switch n {
                case "pi": return .pi
                case "e": return M_E
                default:
                    guard let arg = primary() else { return nil }
                    switch n {
                    case "sqrt": return sqrt(arg)
                    case "sin": return sin(arg)
                    case "cos": return cos(arg)
                    case "tan": return tan(arg)
                    case "log": return log10(arg)
                    case "ln": return log(arg)
                    case "abs": return abs(arg)
                    default: return nil
                    }
                }
            default: return nil
            }
        }
    }
}

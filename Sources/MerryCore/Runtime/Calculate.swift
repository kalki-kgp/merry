import Foundation

/// A calculator with no model behind it.
///
/// "54/30" is not a task and must never reach a planner: it is arithmetic, and
/// arithmetic is the one thing a launcher can answer perfectly, instantly, for
/// free. Deliberately not an evaluator of code: only digits, the four
/// operators, parentheses and a percent form are accepted, and anything else
/// returns nil rather than being executed. A launcher that runs arbitrary
/// typed text as code is a liability.
public func evaluateArithmetic(_ input: String) -> Double? {
    var normalized = input.lowercased().replacingOccurrences(of: ",", with: "")
    normalized = Rx.ecma("(\\d+(?:\\.\\d+)?)\\s*%\\s*of\\s*").replaceAll(normalized, "($1/100)*")
    normalized = Rx.ecma("\\s+").replaceAll(normalized, "")
    if !Rx.ecma("^[0-9+\\-*/().]+$").test(normalized) || !Rx.ecma("\\d").test(normalized) { return nil }

    let tokens = Rx.ecma("\\d+(?:\\.\\d+)?|[+\\-*/()]").all(normalized).map(\.text)
    if tokens.isEmpty { return nil }
    var pos = 0
    func peek() -> String? { pos < tokens.count ? tokens[pos] : nil }

    func expr() -> Double? {
        guard var left = term() else { return nil }
        while peek() == "+" || peek() == "-" {
            let op = tokens[pos]
            pos += 1
            guard let right = term() else { return nil }
            left = op == "+" ? left + right : left - right
        }
        return left
    }
    func term() -> Double? {
        guard var left = factor() else { return nil }
        while peek() == "*" || peek() == "/" {
            let op = tokens[pos]
            pos += 1
            guard let right = factor() else { return nil }
            if op == "/" && right == 0 { return nil }
            left = op == "*" ? left * right : left / right
        }
        return left
    }
    func factor() -> Double? {
        guard let t = peek() else { return nil }
        if t == "-" {
            pos += 1
            return factor().map { -$0 }
        }
        if t == "(" {
            pos += 1
            guard let v = expr(), peek() == ")" else { return nil }
            pos += 1
            return v
        }
        if let first = t.unicodeScalars.first, ("0"..."9").contains(first) {
            pos += 1
            return Double(t)
        }
        return nil
    }

    guard let value = expr(), pos == tokens.count, value.isFinite else { return nil }
    // `Math.round`: halves go up.
    let scaled = value * 1e10
    let floor = scaled.rounded(.down)
    return (scaled - floor >= 0.5 ? floor + 1 : floor) / 1e10
}

import Foundation

// Saved data and model-facing text follow JavaScript conventions, and a great deal of that behaviour lives in
// regular expressions and string arithmetic. These helpers give Swift the
// same semantics (UTF-16 indices, JavaScript's regex flags, Node's path
// rules), so ported logic can stay line-for-line comparable with its source.

/// Milliseconds since 1970, like `Date.now()`.
public func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

/// A regular expression with JavaScript's flags (`i`, `m`, `s`; `g` is implied
/// by which method is called). Compiled patterns are cached.
public struct Rx: @unchecked Sendable {
    public let regex: NSRegularExpression

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSRegularExpression] = [:]

    public init(_ pattern: String, _ flags: String = "") {
        let key = "\(flags)/\(pattern)"
        Rx.lock.lock()
        defer { Rx.lock.unlock() }
        if let cached = Rx.cache[key] { regex = cached; return }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        // A pattern is a literal in the source; one that does not compile is a
        // porting bug, and crashing in the first test run is the right result.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
        Rx.cache[key] = regex
    }

    public struct Match {
        /// Capture groups, with index 0 the whole match. `nil` for a group that did not take part.
        public let groups: [String?]
        /// UTF-16 offset of the match in the input, like `match.index`.
        public let index: Int
        public let length: Int
        public subscript(i: Int) -> String? { i < groups.count ? groups[i] : nil }
        public var text: String { groups[0] ?? "" }
        public var end: Int { index + length }
    }

    private func make(_ result: NSTextCheckingResult, in ns: NSString) -> Match {
        var groups: [String?] = []
        for i in 0..<result.numberOfRanges {
            let r = result.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return Match(groups: groups, index: result.range.location, length: result.range.length)
    }

    /// `regex.test(text)`
    public func test(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    /// `regex.exec(text)` / `text.match(regex)` without the `g` flag.
    public func exec(_ text: String) -> Match? {
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).map { make($0, in: ns) }
    }

    /// `[...text.matchAll(regex)]`
    public func all(_ text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { make($0, in: ns) }
    }

    /// `text.replace(regex, template)` with the `g` flag. The template uses
    /// JavaScript's `$1`; a literal `$` or `\` in it must not be special.
    public func replaceAll(_ text: String, _ template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: Rx.template(template))
    }

    /// `text.replace(regex, template)` without the `g` flag: the first match only.
    public func replaceFirst(_ text: String, _ template: String) -> String {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        let replacement = regex.replacementString(for: m, in: text, offset: 0, template: Rx.template(template))
        return ns.replacingCharacters(in: m.range, with: replacement)
    }

    /// `text.replace(regex, (match) => ...)` with the `g` flag.
    public func replaceAll(_ text: String, _ transform: (Match) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: result.range.location - last))
            out += transform(make(result, in: ns))
            last = result.range.location + result.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `text.split(regex)`. Like JavaScript, captured groups are not spliced in
    /// (no ported pattern relies on that) and empty pieces are kept.
    public func split(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        var last = 0
        for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // JavaScript never splits on an empty match at the very start or end.
            if result.range.length == 0 && (result.range.location == 0 || result.range.location == ns.length) { continue }
            out.append(ns.substring(with: NSRange(location: last, length: result.range.location - last)))
            last = result.range.location + result.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }

    /// JavaScript's `$1` is ICU's `$1` too, but ICU also treats `\` as an escape.
    private static func template(_ js: String) -> String {
        js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$&", with: "$0")
    }

    /// Escapes text for use inside a pattern, like the usual `escapeRegExp`.
    public static func escape(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }
}

extension String {
    /// `string.length`: UTF-16 code units, which is what every JavaScript limit counts.
    public var jsLength: Int { utf16.count }

    /// `string.trim()`.
    public var jsTrimmed: String {
        let space = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}\u{00A0}\u{2028}\u{2029}"))
        return trimmingCharacters(in: space)
    }

    /// `string.slice(start, end)` on UTF-16 offsets, with negative offsets counting from the end.
    public func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
        let ns = self as NSString
        let n = ns.length
        var a = start < 0 ? Swift.max(n + start, 0) : Swift.min(start, n)
        var b = end.map { $0 < 0 ? Swift.max(n + $0, 0) : Swift.min($0, n) } ?? n
        if b < a { return "" }
        // Never cut a surrogate pair in half: Swift strings cannot hold one.
        if a > 0, a < n, CFStringIsSurrogateLowCharacter(ns.character(at: a)) { a += 1 }
        if b > 0, b < n, CFStringIsSurrogateLowCharacter(ns.character(at: b)) { b -= 1 }
        if b < a { return "" }
        return ns.substring(with: NSRange(location: a, length: b - a))
    }

    /// `string.indexOf(needle)` as a UTF-16 offset, or -1.
    public func jsIndexOf(_ needle: String, from: Int = 0) -> Int {
        let ns = self as NSString
        guard from <= ns.length else { return -1 }
        let r = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
        return r.location == NSNotFound ? -1 : r.location
    }

    /// `string.split(separator)`, keeping empty pieces.
    public func jsSplit(_ separator: String) -> [String] {
        if separator.isEmpty { return map(String.init) }
        return components(separatedBy: separator)
    }

    /// `string.padStart(length, pad)`.
    public func jsPadStart(_ length: Int, _ pad: String = " ") -> String {
        let missing = length - utf16.count
        guard missing > 0, !pad.isEmpty else { return self }
        var prefix = ""
        while prefix.utf16.count < missing { prefix += pad }
        return prefix.jsSlice(0, missing) + self
    }

    /// The first character upper-cased, the rest untouched.
    public var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

extension Array where Element: Hashable {
    /// `[...new Set(array)]`: duplicates dropped, first-seen order kept.
    public var unique: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Double {
    /// `number.toFixed(digits)`.
    public func toFixed(_ digits: Int) -> String {
        if isNaN { return "NaN" }
        if self == 0 { return String(format: "%.\(digits)f", 0.0) }
        // JavaScript rounds an exact tie away from zero ((0.125).toFixed(2) is
        // "0.13", (2.5).toFixed(0) is "3"); printf rounds it to even. A double
        // is such a tie exactly when it is an odd number of 2^-(digits+1).
        let scaled = magnitude * Double(sign: .plus, exponent: digits + 1, significand: 1)
        let tie = scaled.isFinite && scaled == scaled.rounded() && scaled.truncatingRemainder(dividingBy: 2) == 1
        let value = tie ? (self < 0 ? nextDown : nextUp) : self
        return String(format: "%.\(digits)f", value)
    }
}

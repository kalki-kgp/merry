import Foundation

/// A JSON value.
///
/// Tool inputs, tool results, observations and model messages are all dynamic
/// data, so they travel as `JSON` rather than as typed structs. Objects keep
/// their keys in insertion order, the way a JavaScript object does, so what is
/// serialised for a model reads in the order it was built.
public enum JSON: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An object whose keys keep the order they were first set in.
public struct JSONObject: Sendable {
    public private(set) var keys: [String] = []
    private var values: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public func has(_ key: String) -> Bool { values[key] != nil }

    /// Key/value pairs in insertion order.
    public var pairs: [(key: String, value: JSON)] { keys.map { ($0, values[$0]!) } }

    /// Sets every pair of `other` on top of this object, like `{ ...a, ...b }`.
    public func merging(_ other: JSONObject) -> JSONObject {
        var out = self
        for (k, v) in other.pairs { out[k] = v }
        return out
    }
}

extension JSONObject: Equatable {
    /// Key order is presentation, not identity.
    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.values == b.values }
}

extension JSON: Equatable {}

// MARK: - Literals

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Building from Swift values

extension JSON {
    public init(_ value: String) { self = .string(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Int64) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: [JSON]) { self = .array(value) }
    public init(_ value: [String]) { self = .array(value.map(JSON.string)) }
    public init(_ value: JSONObject) { self = .object(value) }

    /// `nil` becomes `null`, the way an optional is usually sent.
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
    public init(_ value: Double?) { self = value.map(JSON.number) ?? .null }
    public init(_ value: Bool?) { self = value.map(JSON.bool) ?? .null }

    /// An object from pairs, leaving out the ones whose value is `nil`. This is
    /// what `{ a, ...(b ? { b } : {}) }` and `JSON.stringify` dropping
    /// `undefined` amount to.
    public static func obj(_ pairs: KeyValuePairs<String, JSON?>) -> JSON {
        var o = JSONObject()
        for (k, v) in pairs { if let v { o[k] = v } }
        return .object(o)
    }
}

// MARK: - Reading

extension JSON {
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int? {
        guard case .number(let n) = self, n.isFinite, n.rounded() == n, abs(n) < 9.3e18 else { return nil }
        return Int(n)
    }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }

    /// A member of an object, or `nil` when this is not an object or has no such key.
    public subscript(key: String) -> JSON? {
        get { objectValue?[key] }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSON? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    // Shorthands for validated tool input, where the schema has already
    // guaranteed the shape: `i.str("path")`, `i.int("maxDepth")`.
    public func str(_ key: String) -> String { self[key]?.stringValue ?? "" }
    public func optStr(_ key: String) -> String? { self[key]?.stringValue }
    public func int(_ key: String) -> Int { self[key]?.intValue ?? 0 }
    public func optInt(_ key: String) -> Int? { self[key]?.intValue }
    public func num(_ key: String) -> Double { self[key]?.doubleValue ?? 0 }
    public func optNum(_ key: String) -> Double? { self[key]?.doubleValue }
    public func flag(_ key: String) -> Bool { self[key]?.boolValue ?? false }
    public func optFlag(_ key: String) -> Bool? { self[key]?.boolValue }
    public func list(_ key: String) -> [JSON] { self[key]?.arrayValue ?? [] }
    public func optList(_ key: String) -> [JSON]? { self[key]?.arrayValue }
    public func strings(_ key: String) -> [String] { list(key).compactMap(\.stringValue) }
    public func optStrings(_ key: String) -> [String]? { optList(key)?.compactMap(\.stringValue) }
    /// True when the key is present and not null.
    public func has(_ key: String) -> Bool { if let v = self[key] { return !v.isNull }; return false }
}

// MARK: - Serialising

extension JSON {
    /// Compact JSON text, matching `JSON.stringify(value)`.
    public func stringify() -> String {
        var out = ""
        write(to: &out, indent: nil, depth: 0)
        return out
    }

    /// Indented JSON text, matching `JSON.stringify(value, null, indent)`.
    public func stringify(indent: Int) -> String {
        var out = ""
        write(to: &out, indent: indent > 0 ? String(repeating: " ", count: min(indent, 10)) : nil, depth: 0)
        return out
    }

    private func write(to out: inout String, indent: String?, depth: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSON.format(n)
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if let indent { out += "\n" + String(repeating: indent, count: depth + 1) }
                item.write(to: &out, indent: indent, depth: depth + 1)
            }
            if let indent { out += "\n" + String(repeating: indent, count: depth) }
            out += "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{"
            for (i, pair) in object.pairs.enumerated() {
                if i > 0 { out += "," }
                if let indent { out += "\n" + String(repeating: indent, count: depth + 1) }
                JSON.quote(pair.key, into: &out)
                out += indent == nil ? ":" : ": "
                pair.value.write(to: &out, indent: indent, depth: depth + 1)
            }
            if let indent { out += "\n" + String(repeating: indent, count: depth) }
            out += "}"
        }
    }

    /// A number the way JavaScript prints it: the shortest digits that round
    /// trip, plain decimals between 1e-7 and 1e21, exponents outside that, and
    /// `null` for the values JSON cannot hold.
    static func format(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == 0 { return "0" }
        if n.rounded() == n && abs(n) < 9.2e18 { return String(Int64(n)) }
        // Swift's description already has the shortest round-trip digits; only
        // the layout differs.
        var text = "\(abs(n))"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        var digits = whole + fraction
        // The decimal point sits after `point` digits.
        var point = whole.count + exponent
        let leading = digits.prefix { $0 == "0" }.count
        digits.removeFirst(leading)
        point -= leading
        while digits.hasSuffix("0") { digits.removeLast() }
        let sign = n < 0 ? "-" : ""
        let k = digits.count
        if point >= k && point <= 21 { return sign + digits + String(repeating: "0", count: point - k) }
        if point > 0 && point <= 21 { return sign + digits.prefix(point) + "." + digits.dropFirst(point) }
        if point > -6 && point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        let e = point - 1
        let mantissa = k == 1 ? digits : digits.prefix(1) + "." + digits.dropFirst()
        return "\(sign)\(mantissa)e\(e < 0 ? "-" : "+")\(abs(e))"
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}

extension JSON: CustomStringConvertible {
    public var description: String { stringify() }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at offset \(offset)" }
}

extension JSON {
    /// Parses JSON text, keeping object keys in the order they appear.
    public static func parse(_ text: String) throws -> JSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        if parser.at < parser.bytes.count { throw parser.fail("unexpected text after the value") }
        return value
    }

    public static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        if parser.at < parser.bytes.count { throw parser.fail("unexpected text after the value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0

        func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: at) }

        mutating func skipWhitespace() {
            while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D || bytes[at] == 0x09 { at += 1 }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512 else { throw fail("nested too deeply") }
            guard at < bytes.count else { throw fail("unexpected end of input") }
            switch bytes[at] {
            case UInt8(ascii: "{"):
                at += 1
                var object = JSONObject()
                skipWhitespace()
                if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(object) }
                while true {
                    skipWhitespace()
                    guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                    let key = try string()
                    skipWhitespace()
                    guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                    at += 1
                    skipWhitespace()
                    object[key] = try value(depth: depth + 1)
                    skipWhitespace()
                    guard at < bytes.count else { throw fail("unterminated object") }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(object) }
                    throw fail("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                at += 1
                var items: [JSON] = []
                skipWhitespace()
                if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard at < bytes.count else { throw fail("unterminated array") }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                    throw fail("expected ',' or ']'")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null"); return .null
            default:
                return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { throw fail("unexpected token") }
            at += w.count
        }

        mutating func number() throws -> Double {
            let start = at
            if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
            while at < bytes.count, (bytes[at] >= 0x30 && bytes[at] <= 0x39) || bytes[at] == UInt8(ascii: ".")
                || bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") || bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at > start, let text = String(bytes: bytes[start..<at], encoding: .utf8), let n = Double(text) else {
                at = start
                throw fail("unexpected token")
            }
            return n
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count, let text = String(bytes: bytes[at..<at + 4], encoding: .utf8), let v = UInt32(text, radix: 16) else {
                throw fail("bad unicode escape")
            }
            at += 4
            return v
        }

        mutating func string() throws -> String {
            at += 1 // opening quote
            var out: [UInt8] = []
            while at < bytes.count {
                let b = bytes[at]
                if b == UInt8(ascii: "\"") {
                    at += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b != UInt8(ascii: "\\") { out.append(b); at += 1; continue }
                at += 1
                guard at < bytes.count else { break }
                let e = bytes[at]
                at += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    // A surrogate pair is one character written as two escapes.
                    if (0xD800...0xDBFF).contains(code), at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                        let saved = at
                        at += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) } else { at = saved }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: out.append(e)
                }
            }
            throw fail("unterminated string")
        }
    }
}

// MARK: - Codable

extension JSON: Codable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var object = JSONObject()
            for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(JSON.self, forKey: key) }
            self = .object(object)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSON] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(JSON.self)) }
            self = .array(items)
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { self = .null }
            else if let b = try? single.decode(Bool.self) { self = .bool(b) }
            else if let n = try? single.decode(Double.self) { self = .number(n) }
            else { self = .string(try single.decode(String.self)) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .number(let n):
            var c = encoder.singleValueContainer()
            if n.rounded() == n, abs(n) < 9.2e18 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let items):
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        case .object(let object):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in object.pairs { try c.encode(v, forKey: DynamicKey(stringValue: k)) }
        }
    }

    /// Any `Encodable` as a JSON value.
    public static func encode<T: Encodable>(_ value: T) -> JSON {
        guard let data = try? JSONEncoder().encode(value), let json = try? JSON.parse(data) else { return .null }
        return json
    }

    /// This value as a typed model, when it has that shape.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(stringify().utf8))
    }
}

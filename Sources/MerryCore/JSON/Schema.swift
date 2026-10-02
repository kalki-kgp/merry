import Foundation

/// A description of the shape a JSON value must have.
///
/// One schema does two jobs, as it did with zod in the reference: it is the
/// JSON Schema shown to the planning model, and it is the local validator
/// every proposed tool input is parsed through before anything runs.
///
///     S.object([
///         "path": S.string(),
///         "maxDepth": S.number().int().min(1).max(5).default(2)
///     ])
public struct Schema: Sendable {
    indirect enum Kind: Sendable {
        case string(StringRules)
        case number(NumberRules)
        case boolean
        case array(Schema, min: Int?, max: Int?)
        case object([(String, Schema)], strict: Bool)
        case enumeration([String])
        case literal(JSON)
        case nullable(Schema)
        case record(Schema)
        case union(discriminator: String, options: [Schema])
        case any
    }

    struct StringRules: Sendable {
        var min: Int?
        var max: Int?
        var trim = false
        var format: String?
        /// A JavaScript regular expression the text must match, and what to say when it does not.
        var pattern: String?
        var patternMessage: String?
    }

    struct NumberRules: Sendable {
        var min: Double?
        var max: Double?
        var int = false
    }

    var kind: Kind
    var isOptional = false
    var defaultValue: JSON?
    var summary: String?

    init(_ kind: Kind) { self.kind = kind }
}

/// Schema builders, named after the zod calls they replace.
public enum S {
    public static func string() -> Schema { Schema(.string(.init())) }
    public static func number() -> Schema { Schema(.number(.init())) }
    public static func int() -> Schema { number().int() }
    public static func bool() -> Schema { Schema(.boolean) }
    public static func array(_ items: Schema) -> Schema { Schema(.array(items, min: nil, max: nil)) }
    public static func object(_ fields: KeyValuePairs<String, Schema>) -> Schema { Schema(.object(fields.map { ($0.key, $0.value) }, strict: false)) }
    public static func object() -> Schema { Schema(.object([], strict: false)) }
    public static func oneOf(_ values: [String]) -> Schema { Schema(.enumeration(values)) }
    public static func oneOf(_ values: String...) -> Schema { Schema(.enumeration(values)) }
    public static func literal(_ value: JSON) -> Schema { Schema(.literal(value)) }
    public static func record(_ values: Schema) -> Schema { Schema(.record(values)) }
    /// Objects told apart by the literal value of one key.
    public static func union(on discriminator: String, _ options: [Schema]) -> Schema { Schema(.union(discriminator: discriminator, options: options)) }
    public static func any() -> Schema { Schema(.any) }
}

extension Schema {
    public func optional() -> Schema { var s = self; s.isOptional = true; return s }
    public func `default`(_ value: JSON) -> Schema { var s = self; s.defaultValue = value; return s }
    public func describe(_ text: String) -> Schema { var s = self; s.summary = text; return s }
    public func nullable() -> Schema { Schema(.nullable(self)) }

    /// Shortest string, smallest number, or fewest items, depending on the type.
    public func min(_ n: Double) -> Schema {
        var s = self
        switch kind {
        case .string(var r): r.min = Int(n); s.kind = .string(r)
        case .number(var r): r.min = n; s.kind = .number(r)
        case .array(let items, _, let max): s.kind = .array(items, min: Int(n), max: max)
        default: break
        }
        return s
    }

    public func max(_ n: Double) -> Schema {
        var s = self
        switch kind {
        case .string(var r): r.max = Int(n); s.kind = .string(r)
        case .number(var r): r.max = n; s.kind = .number(r)
        case .array(let items, let min, _): s.kind = .array(items, min: min, max: Int(n))
        default: break
        }
        return s
    }

    public func int() -> Schema {
        guard case .number(var r) = kind else { return self }
        var s = self; r.int = true; s.kind = .number(r); return s
    }

    public func trim() -> Schema {
        guard case .string(var r) = kind else { return self }
        var s = self; r.trim = true; s.kind = .string(r); return s
    }

    public func url() -> Schema { format("uri") }
    public func email() -> Schema { format("email") }

    private func format(_ name: String) -> Schema {
        guard case .string(var r) = kind else { return self }
        var s = self; r.format = name; s.kind = .string(r); return s
    }

    /// zod's `.regex(/pattern/, message)`. The pattern is written as JavaScript.
    public func regex(_ pattern: String, _ message: String? = nil) -> Schema {
        guard case .string(var r) = kind else { return self }
        var s = self; r.pattern = pattern; r.patternMessage = message; s.kind = .string(r); return s
    }

    /// Refuses keys the schema does not name, instead of dropping them.
    public func strict() -> Schema {
        guard case .object(let fields, _) = kind else { return self }
        var s = self; s.kind = .object(fields, strict: true); return s
    }

    /// The same schema with its default taken away.
    public func removeDefault() -> Schema { var s = self; s.defaultValue = nil; return s }

    /// The schema of one field of an object schema.
    public func field(_ name: String) -> Schema {
        guard case .object(let fields, _) = kind, let found = fields.first(where: { $0.0 == name }) else { return S.any() }
        return found.1
    }
}

// MARK: - Validation

public struct SchemaError: Error, CustomStringConvertible, LocalizedError {
    public struct Issue: Sendable {
        public let path: [String]
        public let message: String
    }
    public let issues: [Issue]
    public var description: String {
        issues.map { $0.path.isEmpty ? $0.message : "\($0.path.joined(separator: ".")): \($0.message)" }.joined(separator: "; ")
    }
    public var errorDescription: String? { description }
}

private let maxSafeInteger = 9007199254740991.0
private let emailSource = "^(?:[A-Za-z0-9_'+\\-]+\\.)*[A-Za-z0-9_'+\\-]*[A-Za-z0-9_+-]@(?:[A-Za-z0-9][A-Za-z0-9\\-]*\\.)+[A-Za-z]{2,}$"
private let emailPattern = try! NSRegularExpression(pattern: emailSource)

extension Schema {
    /// Checks a value against the schema and returns it with defaults filled
    /// in, strings trimmed and unnamed keys dropped. Throws `SchemaError`
    /// listing everything that is wrong.
    public func parse(_ value: JSON?) throws -> JSON {
        var issues: [SchemaError.Issue] = []
        let out = check(value, path: [], issues: &issues)
        if !issues.isEmpty { throw SchemaError(issues: issues) }
        return out ?? .null
    }

    /// `nil` in means the key was absent; `nil` out means it stays absent.
    private func check(_ value: JSON?, path: [String], issues: inout [SchemaError.Issue]) -> JSON? {
        guard let value else {
            if let defaultValue { return defaultValue }
            if isOptional { return nil }
            issues.append(.init(path: path, message: "Invalid input: expected \(typeName), received undefined"))
            return nil
        }
        func bad(_ message: String) -> JSON? { issues.append(.init(path: path, message: message)); return nil }
        func received(_ v: JSON) -> String {
            switch v {
            case .null: return "null"
            case .bool: return "boolean"
            case .number(let n): return n.isNaN ? "NaN" : "number"
            case .string: return "string"
            case .array: return "array"
            case .object: return "object"
            }
        }
        switch kind {
        case .any:
            return value
        case .string(let rules):
            guard case .string(var s) = value else { return bad("Invalid input: expected string, received \(received(value))") }
            if rules.trim { s = s.jsTrimmed }
            // zod measures a string in code points, not UTF-16 units.
            let length = s.unicodeScalars.count
            if let min = rules.min, length < min { return bad("Too small: expected string to have >=\(min) characters") }
            if let max = rules.max, length > max { return bad("Too big: expected string to have <=\(max) characters") }
            if let pattern = rules.pattern, !Rx(Schema.icuPattern(pattern)).test(s) {
                return bad(rules.patternMessage ?? "Invalid string: must match pattern /\(pattern)/")
            }
            if rules.format == "uri", !Schema.isURL(s) { return bad("Invalid URL") }
            if rules.format == "email", emailPattern.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) == nil { return bad("Invalid email address") }
            return .string(s)
        case .number(let rules):
            guard case .number(let n) = value, n.isFinite else { return bad("Invalid input: expected number, received \(received(value))") }
            if rules.int {
                if n.rounded() != n { return bad("Invalid input: expected int, received number") }
                if abs(n) > maxSafeInteger { return bad("Invalid input: expected a safe integer") }
            }
            if let min = rules.min, n < min { return bad("Too small: expected number to be >=\(JSON.format(min))") }
            if let max = rules.max, n > max { return bad("Too big: expected number to be <=\(JSON.format(max))") }
            return value
        case .boolean:
            guard case .bool = value else { return bad("Invalid input: expected boolean, received \(received(value))") }
            return value
        case .enumeration(let allowed):
            guard case .string(let s) = value, allowed.contains(s) else {
                return bad("Invalid option: expected one of \(allowed.map { "\"\($0)\"" }.joined(separator: "|"))")
            }
            return value
        case .literal(let expected):
            guard value == expected else { return bad("Invalid input: expected \(expected.stringify())") }
            return value
        case .nullable(let inner):
            if case .null = value { return value }
            return inner.check(value, path: path, issues: &issues)
        case .array(let items, let min, let max):
            guard case .array(let list) = value else { return bad("Invalid input: expected array, received \(received(value))") }
            if let min, list.count < min { return bad("Too small: expected array to have >=\(min) items") }
            if let max, list.count > max { return bad("Too big: expected array to have <=\(max) items") }
            var out: [JSON] = []
            for (i, item) in list.enumerated() {
                if let parsed = items.check(item, path: path + [String(i)], issues: &issues) { out.append(parsed) }
            }
            return .array(out)
        case .record(let values):
            guard case .object(let object) = value else { return bad("Invalid input: expected record, received \(received(value))") }
            var out = JSONObject()
            for (k, v) in object.pairs {
                if let parsed = values.check(v, path: path + [k], issues: &issues) { out[k] = parsed }
            }
            return .object(out)
        case .object(let fields, let strict):
            guard case .object(let object) = value else { return bad("Invalid input: expected object, received \(received(value))") }
            var out = JSONObject()
            for (name, schema) in fields {
                if let parsed = schema.check(object[name], path: path + [name], issues: &issues) { out[name] = parsed }
            }
            if strict {
                let unknown = object.keys.filter { key in !fields.contains { $0.0 == key } }
                if !unknown.isEmpty {
                    _ = bad("Unrecognized key\(unknown.count == 1 ? "" : "s"): \(unknown.map { "\"\($0)\"" }.joined(separator: ", "))")
                }
            }
            return .object(out)
        case .union(let discriminator, let options):
            guard case .object(let object) = value else { return bad("Invalid input: expected object, received \(received(value))") }
            let tag = object[discriminator]
            for option in options {
                if case .literal(let expected) = option.field(discriminator).kind, tag == expected {
                    return option.check(value, path: path, issues: &issues)
                }
            }
            issues.append(.init(path: path + [discriminator], message: "Invalid input"))
            return nil
        }
    }

    private var typeName: String {
        switch kind {
        case .string: return "string"
        case .number(let r): return r.int ? "int" : "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object, .union: return "object"
        case .record: return "record"
        case .enumeration: return "option"
        case .literal(let v): return v.stringify()
        case .nullable(let inner): return inner.typeName
        case .any: return "any"
        }
    }

    /// A JavaScript pattern as ICU reads it the same way: `\d` is ASCII digits
    /// only, and a closing `$` is the very end, not also before a final newline.
    static func icuPattern(_ js: String) -> String {
        var p = js.replacingOccurrences(of: "\\d", with: "[0-9]")
        if p.hasSuffix("$"), !p.hasSuffix("\\$") { p = String(p.dropLast()) + "\\z" }
        return p
    }

    /// Whether `new URL(text)` would accept it.
    static func isURL(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first), first.isASCII,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }) else { return false }
        let special = ["http", "https", "ftp", "ws", "wss", "file"].contains(scheme.lowercased())
        if !special { return true }
        if scheme.lowercased() == "file" { return true }
        // A special scheme needs a host.
        var rest = text[text.index(after: colon)...]
        while rest.hasPrefix("/") || rest.hasPrefix("\\") { rest = rest.dropFirst() }
        let host = rest.prefix { !"/?#".contains($0) }
        return !host.isEmpty && !host.contains(" ")
    }
}

// MARK: - JSON Schema

extension Schema {
    /// The draft-7 JSON Schema a model is shown for this input, matching
    /// zod's `toJSONSchema(schema, { io: 'input', target: 'draft-7' })`.
    public func jsonSchema() -> JSON {
        var out = JSONObject()
        out["$schema"] = "http://json-schema.org/draft-07/schema#"
        return .object(out.merging(body()))
    }

    private func body() -> JSONObject {
        var out = JSONObject()
        if let defaultValue { out["default"] = defaultValue }
        if let summary { out["description"] = .string(summary) }
        switch kind {
        case .any:
            break
        case .string(let rules):
            out["type"] = "string"
            if let min = rules.min { out["minLength"] = JSON(min) }
            if let max = rules.max { out["maxLength"] = JSON(max) }
            if let pattern = rules.pattern { out["pattern"] = .string(pattern) }
            if let format = rules.format {
                out["format"] = .string(format)
                if format == "email" { out["pattern"] = .string(emailSource) }
            }
        case .number(let rules):
            out["type"] = rules.int ? "integer" : "number"
            if let min = rules.min { out["minimum"] = .number(min) } else if rules.int { out["minimum"] = .number(-maxSafeInteger) }
            if let max = rules.max { out["maximum"] = .number(max) } else if rules.int { out["maximum"] = .number(maxSafeInteger) }
        case .boolean:
            out["type"] = "boolean"
        case .enumeration(let values):
            out["type"] = "string"
            out["enum"] = JSON(values)
        case .literal(let value):
            switch value {
            case .string: out["type"] = "string"
            case .number: out["type"] = "number"
            case .bool: out["type"] = "boolean"
            case .null: out["type"] = "null"
            default: break
            }
            out["const"] = value
        case .nullable(let inner):
            let wrapped = inner.body()
            // A bare type folds into a type list; anything richer keeps its own branch.
            if wrapped.keys == ["type"], let type = wrapped["type"] { out["type"] = [type, "null"] } else { out["anyOf"] = [.object(wrapped), ["type": "null"]] }
        case .array(let items, let min, let max):
            if let min { out["minItems"] = JSON(min) }
            if let max { out["maxItems"] = JSON(max) }
            out["type"] = "array"
            out["items"] = .object(items.body())
        case .record(let values):
            out["type"] = "object"
            out["propertyNames"] = ["type": "string"]
            out["additionalProperties"] = .object(values.body())
        case .object(let fields, let strict):
            out["type"] = "object"
            var properties = JSONObject()
            var required: [String] = []
            for (name, schema) in fields {
                properties[name] = .object(schema.body())
                if !schema.isOptional && schema.defaultValue == nil { required.append(name) }
            }
            out["properties"] = .object(properties)
            if !required.isEmpty { out["required"] = JSON(required) }
            if strict { out["additionalProperties"] = false }
        case .union(_, let options):
            out["oneOf"] = .array(options.map { .object($0.body()) })
        }
        return out
    }
}

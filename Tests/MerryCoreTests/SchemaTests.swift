import Testing
@testable import MerryCore

/// The schemas the fixture cases were recorded against.
private let cases: [String: Schema] = [
    "strings": S.object(["a": S.string(), "b": S.string().min(2).max(5), "c": S.string().trim().min(1).max(4).optional(), "d": S.string().describe("a thing").optional(), "e": S.string().default("x")]),
    "numbers": S.object(["n": S.number(), "i": S.number().int(), "r": S.number().int().min(1).max(5).default(2), "f": S.number().min(0.5).max(1440).optional()]),
    "collections": S.object([
        "list": S.array(S.string()).min(1).max(3), "ops": S.array(S.object(["from": S.string(), "to": S.string()])).optional(), "flags": S.array(S.string()).default([]),
        "kind": S.oneOf("a", "b"), "mode": S.oneOf("x", "y").default("x"), "on": S.bool(), "maybe": S.bool().optional().describe("later"), "about": S.array(S.string()).max(2).default([]).describe("words")
    ]),
    "nullable": S.object(["p": S.string().max(100).nullable().default(nil), "d": S.number().int().min(0).nullable().default(nil), "q": S.string().nullable(), "o": S.string().nullable().optional()]),
    "strict": S.object(["kind": S.oneOf("path", "url"), "label": S.string().max(3), "value": S.string().min(1)]).strict(),
    "formats": S.object(["url": S.string().url(), "to": S.array(S.string().email()).optional(), "rec": S.record(S.string()).optional()]),
    "brain": S.object(["request": BrainSchema.request])
]

@Test func schemasMatchZodJSONSchema() {
    let fixture = Fixture.load("schema-cases")
    for (name, schema) in cases.sorted(by: { $0.key < $1.key }) {
        let expected = fixture[name]!["schema"]!
        #expect(schema.jsonSchema().firstDifference(from: expected) == nil, "\(name)")
    }
}

@Test func parsingMatchesZod() {
    let fixture = Fixture.load("schema-cases")
    for (name, schema) in cases.sorted(by: { $0.key < $1.key }) {
        for (index, result) in fixture[name]!.list("results").enumerated() {
            let input = result["input"]
            let label = "\(name)[\(index)] \(input?.stringify() ?? "undefined")"
            do {
                let output = try schema.parse(input)
                #expect(result.flag("ok"), "\(label) should be rejected but parsed to \(output)")
                if result.flag("ok") { #expect(output.firstDifference(from: result["output"] ?? .null) == nil, "\(label)") }
            } catch {
                #expect(!result.flag("ok"), "\(label) should parse but failed: \(error)")
            }
        }
    }
}

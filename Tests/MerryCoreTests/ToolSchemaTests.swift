import Testing
@testable import MerryCore

/// Every tool that has been ported must look, to the planning model, exactly
/// as it does in the reference: same name, description, schema and gating.
@Test func portedToolsMatchTheOriginal() {
    let golden = Dictionary(uniqueKeysWithValues: (Fixture.load("tool-schemas").arrayValue ?? []).map { ($0.str("name"), $0) })
    for tool in allTools() {
        guard let expected = golden[tool.name] else {
            Issue.record("\(tool.name) is not a tool the reference has")
            continue
        }
        #expect(tool.description == expected.str("description"), "\(tool.name) description")
        #expect(tool.capability == expected.str("capability"), "\(tool.name) capability")
        #expect(tool.exclusiveDesktop == expected.flag("exclusiveDesktop"), "\(tool.name) exclusiveDesktop")
        #expect((tool.verify != nil) == expected.flag("hasVerify"), "\(tool.name) verify")
        #expect((tool.precondition != nil) == expected.flag("hasPrecondition"), "\(tool.name) precondition")
        #expect((tool.confirm != nil) == expected.flag("hasConfirm"), "\(tool.name) confirm")
        let difference = tool.input.jsonSchema().firstDifference(from: expected["input_schema"] ?? .null)
        #expect(difference == nil, "\(tool.name) schema: \(difference ?? "")")
    }
}

/// The reference's tools, in its registration order. This fails until the port is complete.
@Test func everyOriginalToolIsPorted() {
    let wanted = (Fixture.load("tool-schemas").arrayValue ?? []).map { $0.str("name") }
    let have = allTools().map(\.name)
    let missing = wanted.filter { !have.contains($0) }
    #expect(missing.isEmpty, "not yet ported: \(missing.joined(separator: ", "))")
    if missing.isEmpty { #expect(have == wanted, "tools are registered in a different order") }
}

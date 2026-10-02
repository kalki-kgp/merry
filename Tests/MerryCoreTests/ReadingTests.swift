import Testing
@testable import MerryCore

@Test func arithmeticMatchesTheOriginal() {
    let rows = Fixture.load("reading").list("sums")
    for row in rows {
        let input = row.str("input")
        let value = evaluateArithmetic(input)
        switch row["value"] ?? .null {
        case .null: #expect(value == nil, "\(input.debugDescription) gave \(String(describing: value))")
        case .number(let n): #expect(value == n, "\(input.debugDescription) gave \(String(describing: value)), expected \(n)")
        case .string(let s): #expect(value.map { $0.isInfinite ? ($0 < 0 ? "-Infinity" : "Infinity") : "NaN" } == s, "\(input.debugDescription)")
        default: Issue.record("unexpected fixture value")
        }
    }
    #expect(rows.count > 80)
}

@Test func questionsAboutMerryAreRecognisedLikeTheOriginal() {
    let fixture = Fixture.load("reading")
    for row in fixture.list("about") + fixture.list("model") {
        let text = row.str("text")
        #expect(isAboutMerry(text) == row.flag("merry"), "isAboutMerry \(text.debugDescription)")
        #expect(isAboutModel(text) == row.flag("model"), "isAboutModel \(text.debugDescription)")
    }
}

@Test func modelsAreDescribedLikeTheOriginal() {
    for row in Fixture.load("reading").list("models") {
        var config = ModelConfig()
        let c = row["config"]!
        config.planner = c.str("planner"); config.jev = c.str("jev"); config.claudeCode = c.str("claudeCode")
        config.codex = c.str("codex"); config.opencode = c.str("opencode"); config.maxTokens = c.int("maxTokens")
        let route: ThinkingRoute? = row.optStr("route").map { $0 == "api" ? .api : .app(CodingApp(rawValue: $0)!) }
        let said = describeModels(route, config, jev: row.flag("jev"))
        let difference = said.parityJSON.firstDifference(from: row["said"]!)
        #expect(difference == nil, "\(row.optStr("route") ?? "none") \(c.stringify()): \(difference ?? "")")
    }
}

@Test func merryDescribesItselfLikeTheOriginal() {
    let fixture = Fixture.load("reading")
    for row in fixture.list("self") {
        let said = describeSelf(CapabilityOnlyAdapter(row.strings("caps")), canPlan: row.flag("canPlan"), workflowsEnabled: row.flag("workflows"), workspace: row.flag("workspace"))
        let difference = said.parityJSON.firstDifference(from: row["said"]!)
        #expect(difference == nil, "\(row.stringify().prefix(120)): \(difference ?? "")")
    }
    #expect(describeSelf(UnavailableOsAdapter(), canPlan: true, workflowsEnabled: true).parityJSON == fixture["selfDefault"])
}

@Test func costsMatchTheOriginal() {
    for row in Fixture.load("reading").list("costs") {
        let model = row.str("model")
        #expect(costOf(model, inputTokens: row.int("input"), outputTokens: row.int("output"), cacheReadTokens: row.int("read"), cacheWriteTokens: row.int("write")) == row.num("usd"), "\(row)")
        #expect(rateFor(model).inputPerMTok == row["rate"]!.num("inputPerMTok"))
        #expect(rateFor(model).outputPerMTok == row["rate"]!.num("outputPerMTok"))
    }
}

@Test func toFixedRoundsLikeJavaScript() {
    for row in Fixture.load("reading").list("fixed") {
        let n = row.flag("negativeZero") ? -0.0 : row.optNum("n") ?? .nan
        #expect(n.toFixed(row.int("digits")) == row.str("text"), "\(n).toFixed(\(row.int("digits")))")
    }
}

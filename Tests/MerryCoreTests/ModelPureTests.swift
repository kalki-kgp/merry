import Testing
@testable import MerryCore

func proposalJSON(_ p: PlannerProposal) -> JSON {
    .obj([
        "calls": .array(p.calls.map { ["id": .string($0.id), "name": .string($0.name), "input": $0.input] }),
        "text": .string(p.text),
        "stopReason": JSON(p.stopReason),
        "refusal": p.refusal.map(JSON.string),
        "usd": .number(p.usd),
        "inputTokens": JSON(p.inputTokens),
        "outputTokens": JSON(p.outputTokens)
    ])
}

private func expectSame(_ got: JSON, _ want: JSON, _ what: String) {
    let difference = got.firstDifference(from: want)
    #expect(difference == nil, "\(what): \(difference ?? "")")
}

@Suite struct ModelPureTests {
    let fixture = Fixture.load("model-pure")

    @Test func systemPromptIsByteIdentical() {
        #expect(SYSTEM_PROMPT == fixture.str("systemPrompt"))
        #expect(Array(SYSTEM_PROMPT.utf8) == Array(fixture.str("systemPrompt").utf8))
    }

    @Test func pricingMatches() {
        for row in fixture.list("rates") {
            let rate = rateFor(row.str("model"))
            #expect(rate.inputPerMTok == row["rate"]!.num("inputPerMTok") && rate.outputPerMTok == row["rate"]!.num("outputPerMTok"), "\(row.str("model"))")
        }
        #expect(fixture.list("costs").count > 80)
        for row in fixture.list("costs") {
            let model = row.str("model")
            #expect(costOf(model, row.int("input"), row.int("output"), readTokens: row.int("read"), writeTokens: row.int("write")) == row.num("usd"), "\(row)")
            #expect(costOf(model, row.int("input"), row.int("output")) == row.num("plain"), "\(row)")
        }
    }

    @Test func parseProposalMatches() {
        let now = fixture.num("now")
        #expect(fixture.list("proposals").count > 40)
        for row in fixture.list("proposals") {
            let parsed = parseProposal(row.str("reply"), now: now)
            let got: JSON = parsed.map { p in
                ["text": .string(p.text), "calls": .array(p.calls.map { ["id": .string($0.id), "name": .string($0.name), "input": $0.input] })]
            } ?? .null
            expectSame(got, row["parsed"] ?? .null, "parseProposal \(row.str("reply"))")
        }
    }

    @Test func clipMatches() {
        for row in fixture.list("clips") {
            let got = row.optInt("max").map { clip(row.str("text"), $0) } ?? clip(row.str("text"))
            #expect(got == row.str("clipped"), "clip \(row.str("text").prefix(20)) \(String(describing: row.optInt("max")))")
        }
    }

    @Test func claudeCheckMatches() {
        for row in fixture.list("claudeChecks") {
            let got = parseClaudeCheck(row.str("output"), row.str("requested"), row.optStr("expected"))
            expectSame(JSON.encode(got), row["check"]!, "parseClaudeCheck \(row.str("output")) \(row.str("requested"))")
        }
    }

    @Test func openCodeCheckMatches() {
        for row in fixture.list("openCodeChecks") {
            expectSame(JSON.encode(parseOpenCodeCheck(row.str("output"), row.str("model"))), row["check"]!, "parseOpenCodeCheck \(row.str("output"))")
        }
    }

    @Test func modelCheckFailureMatches() {
        #expect(fixture.list("failures").count > 50)
        for row in fixture.list("failures") {
            expectSame(JSON.encode(modelCheckFailure(row.str("error"))), row["check"]!, "modelCheckFailure \(row.str("error"))")
        }
    }

    @Test func openCodeProvidersMatch() {
        for (i, row) in fixture.list("providers").enumerated() {
            let got = try? parseOpenCodeProviders(row["input"] ?? .null, row.optStr("configured"))
            if row.flag("error") {
                #expect(got == nil, "providers[\(i)] should be refused")
                continue
            }
            guard let got else { Issue.record("providers[\(i)] threw"); continue }
            let want = row["value"] ?? .null
            expectSame(JSON.encode(got), want, "providers[\(i)]")
            // Order is part of the answer: it is what the picker shows.
            #expect(got.models.map(\.id) == want.list("models").map { $0.str("id") }, "providers[\(i)] order")
        }
    }

    @Test func openCodeModelListMatches() {
        for row in fixture.list("modelOutputs") {
            let got = parseOpenCodeModels(row.str("output"))
            expectSame(.array(got.map { JSON.encode($0) }), row["models"]!, "parseOpenCodeModels \(row.str("output"))")
        }
    }
}

import Testing
@testable import MerryCore

private func question(_ q: JSON) -> JevQuestion {
    func pairs(_ list: [JSON]) -> [(String, String)] { list.map { ($0[0]!.stringValue!, $0[1]!.stringValue!) } }
    switch q.str("type") {
    case "choice": return .choice(q.str("instructions"), pairs(q.list("criteria")))
    case "score": return .score(q.str("instructions"), q.list("criteria").map(\.stringValue))
    default:
        if let criteria = q.optList("criteria") { return .noul(q.optStr("instructions"), pairs(criteria)) }
        return q.has("instructions") ? .noul(q.str("instructions")) : .noul()
    }
}

/// Runs one fixture step against the Swift client and returns what the reference's result would serialise to.
private func run(_ op: String, _ a: JSON, _ jev: Jev, now: Double) async -> JSON {
    switch op {
    case "ask":
        let answers = await jev.ask(a.str("label"), state: a["state"] ?? .null, questions: a.list("questions").map { ($0.str("name"), question($0)) })
        // Answers are compared as answers, not as text: see `sameAnswers`.
        return answers == nil ? .null : .bool(true)
    case "close": return .bool(await jev.shouldCloseBrowser(a.str("request")))
    case "route": return await jev.routeRequest(a.str("request"), hasDroppedPaths: a.flag("dropped")).parityJSON
    case "plan": return await jev.planSetup(a.str("request"), route: a.str("route"), hasDroppedPaths: a.flag("dropped")).parityJSON
    case "progress": return await jev.assessProgress(parityTask(request: "sort my downloads by project", max: a.optInt("max"), actions: a.list("actions"))).parityJSON
    case "assign":
        let files = a.list("files").map { JevFile(name: $0.str("name"), ext: $0.str("ext"), modifiedAt: $0.num("modifiedAt")) }
        let groups = a.list("groups").map { JevGroup(name: $0.str("name"), description: $0.str("description")) }
        guard let result = await jev.assignFilesToGroups(files, groups) else { return .null }
        return ["assignments": .object(JSONObject(result.assignments.map { ($0.key, JSON.string($0.value)) })), "unsorted": JSON(result.unsorted)]
    case "understand": return await understand(a.str("request"), jev, hasDroppedPaths: a.flag("dropped"), now: now).parityJSON
    case "recall":
        let recalled = await recall(a.str("request"), parityMemories(a.list("memories")), jev, limit: a.int("limit"))
        return .array(recalled.map { ["id": .string($0.memory.id), "why": .string($0.why)] })
    default: fatalError("unknown op \(op)")
    }
}

@Test func jevSendsAndConcludesWhatTheOriginalDoes() async {
    LocalTime.use(timeZone: "Asia/Kolkata")
    let fixture = Fixture.load("jev-wire")
    var steps = 0, requests = 0
    for scenario in fixture.list("scenarios") {
        let name = scenario.str("name")
        let wire = CannedTransport()
        let clock = TestClock(fixture.num("start"))
        var environment: [String: String] = [:]
        for (key, value) in scenario["env"]?.objectValue?.pairs ?? [] { environment[key] = value.stringValue }
        let jev = Jev(apiKey: scenario.optStr("key"), enabled: true, model: scenario.str("model"), transport: wire.transport, environment: environment, now: { clock.now })
        // The reference waits its full 1500ms for the reply that never comes; nothing here needs that long.
        jev.timeoutMs = 150

        for (index, step) in scenario.list("steps").enumerated() {
            steps += 1
            let label = "\(name) [\(index)] \(step.str("op"))"
            clock.advance(step.num("advanceMs"))
            wire.load(step.list("replies"))

            // `ask` hands back the answers themselves; compare those before they are flattened.
            var result: JSON
            if step.str("op") == "ask" {
                let a = step["args"]!
                let answers = await jev.ask(a.str("label"), state: a["state"] ?? .null, questions: a.list("questions").map { ($0.str("name"), question($0)) })
                var expected: [String: JevAnswer]?
                if let object = step["result"]?.objectValue {
                    expected = [:]
                    for (key, value) in object.pairs { expected![key] = JevAnswer(value) }
                }
                #expect(answers == expected, "\(label): answers \(String(describing: answers))")
                result = step["result"] ?? .null
            } else {
                result = await run(step.str("op"), step["args"]!, jev, now: clock.now)
            }
            let difference = result.firstDifference(from: step["result"] ?? .null)
            #expect(difference == nil, "\(label): \(difference ?? "")")

            let sent = wire.sent
            let expected = step.list("sent")
            #expect(sent.count == expected.count, "\(label): sent \(sent.count) requests, expected \(expected.count)")
            for (request, want) in zip(sent, expected) {
                requests += 1
                #expect(sentURL(request) == want.str("url"), "\(label): url")
                #expect(sentMethod(request) == want.str("method"), "\(label): method")
                #expect(sentHeader(request, "Authorization") == want.str("authorization"), "\(label): authorization")
                #expect(sentHeader(request, "Accept") == want.str("accept"), "\(label): accept")
                #expect(sentHeader(request, "Content-Type") == want.str("contentType"), "\(label): content type")
                let raw = sentBody(request)
                let body = (try? JSON.parse(raw)) ?? .null
                let bodyDifference = body.firstDifference(from: want["body"]!)
                #expect(bodyDifference == nil, "\(label): body \(bodyDifference ?? "")")
                // The same JSON, and the same bytes: key order and number formatting included.
                #expect(raw == want.str("raw"), "\(label): body text differs")
            }
            #expect(wire.unused == step.int("unused"), "\(label): unused replies")
            #expect(jev.available == step.flag("available"), "\(label): available")
        }
        let difference = jev.metrics.json.firstDifference(from: scenario["metrics"]!)
        #expect(difference == nil, "\(name): metrics \(difference ?? "")")
    }
    #expect(steps > 130 && requests > 90, "\(steps) steps, \(requests) requests")
}

private let untidy: [JSON] = [
    ["id": "a0", "step": 0, "tool": "files_list", "input": [:], "startedAt": 0, "outcome": "success"],
    ["id": "a1", "step": 1, "tool": "files_move", "input": [:], "startedAt": 1, "outcome": "failure", "error": "denied"],
    ["id": "a2", "step": 2, "tool": "files_list", "input": [:], "startedAt": 2, "outcome": "success"],
    ["id": "a3", "step": 3, "tool": "files_move", "input": [:], "startedAt": 3, "outcome": "uncertain"],
    ["id": "a4", "step": 4, "tool": "files_stat", "input": [:], "startedAt": 4, "outcome": "success"]
]

private func choice(_ label: String, _ confidence: Double = 0.9) -> JSON {
    ["type": "choice", "choice": .string(label), "confidence": .number(confidence), "probabilities": [:]]
}

private func noul(_ p: Double) -> JSON { ["type": "noul", "noul": .number(p)] }

private func connected(_ wire: CannedTransport, clock: TestClock = TestClock(1_790_000_000_000), key: String? = nil) -> Jev {
    Jev(apiKey: "test-key", enabled: true, transport: wire.transport, transportKey: key, environment: [:], now: { clock.now })
}

@Test func aFailingJevFallsBackToTheLocalVerdict() async {
    let wire = CannedTransport()
    let jev = connected(wire)
    let task = parityTask(max: 3, actions: untidy)
    wire.load([["status": 500, "body": "{\"error\":\"boom\"}"]])
    #expect(await jev.assessProgress(task) == jev.assessProgressLocally(task))
    #expect(wire.sent.count == 1)

    for status in [500, 503, 401, 429] {
        let wire = CannedTransport()
        let jev = connected(wire)
        wire.load([["status": .number(Double(status)), "body": ""]])
        let local = Jev(apiKey: nil, enabled: false).routeLocally("play some lofi", hasDroppedPaths: false)
        #expect(await jev.routeRequest("play some lofi", hasDroppedPaths: false) == local)
        #expect(jev.metrics.calls.last?.outcome == "unclear (fallback)" && jev.metrics.totalUsd == 0)
        #expect(await jev.planSetup("play some lofi", route: "unclear", hasDroppedPaths: false) == localPlanSetup("play some lofi", route: "unclear", hasDroppedPaths: false))
        #expect(wire.sent.count == 1, "the second call is inside the cooldown")
    }
}

@Test func aConfidentLocalRouteMakesNoNetworkCall() async {
    let wire = CannedTransport()
    let jev = connected(wire)
    wire.load([CannedTransport.ok(["route": choice("browser"), "needsClarification": noul(0.9)])])
    let decision = await jev.routeRequest("organise my downloads folder", hasDroppedPaths: false)
    #expect(decision.route == .files && decision.confidence == 0.85 && !decision.needsClarification)
    #expect(wire.sent.isEmpty && wire.unused == 1)
    #expect(jev.metrics.calls == [JevCallRecord(decision: "route", usedModel: false, latencyMs: 0, usd: 0, inputTokens: 0, outcome: "files", confidence: 0.85)])
    #expect(jev.metrics.overrides == 0)
}

@Test func jevCannotTalkALocalAskDownToContinue() async {
    let failing: [JSON] = (0..<4).map { i in
        ["id": .string("a\(i)"), "step": .number(Double(i)), "tool": .string("t\(i)"), "input": [:], "startedAt": 0, "outcome": i == 0 ? "success" : "failure", "error": .string("e\(i)")]
    }
    let wire = CannedTransport()
    let jev = connected(wire)
    wire.load([CannedTransport.ok(["nextMove": choice("continue", 1), "stuck": noul(0)])])
    let verdict = await jev.assessProgress(parityTask(max: 3, actions: failing))
    #expect(verdict == ProgressVerdict(action: .ask, reason: "3 actions failed in a row", deterministic: true))
    #expect(wire.sent.isEmpty, "a local verdict other than continue is never put to Jev")

    // The clamp itself: whatever Jev proposes, the result is never less cautious than the local verdict.
    let order: [ProgressAction] = [.continue, .reobserve, .replan, .ask, .abort]
    for (l, local) in order.enumerated() {
        for (p, proposed) in order.enumerated() {
            #expect(atLeastAsCautious(local, proposed) == order[max(l, p)], "\(local) vs \(proposed)")
        }
        #expect(atLeastAsCautious(local, nil) == local)
    }

    // And through the client: an untidy history that local rules pass, with Jev offering each move.
    for (proposed, expected) in [("continue", ProgressAction.continue), ("reobserve", .reobserve), ("replan", .replan), ("ask", .ask), ("abort", .abort), ("relax", .continue)] {
        let wire = CannedTransport()
        let jev = connected(wire)
        wire.load([CannedTransport.ok(["nextMove": choice(proposed), "stuck": noul(0.5)])])
        let verdict = await jev.assessProgress(parityTask(max: 3, actions: untidy))
        #expect(verdict.action == expected && verdict.deterministic == (expected == .continue), "\(proposed)")
        #expect(jev.metrics.overrides == (expected == .continue ? 0 : 1))
    }
}

@Test func jevIsLeftAloneForAMinuteAfterAFailure() async {
    let clock = TestClock(1_000_000)
    let wire = CannedTransport()
    let key = "cooldown-\(newId())"
    let jev = connected(wire, clock: clock, key: key)
    let sibling = connected(wire, clock: clock, key: key)
    let stranger = connected(CannedTransport(), clock: clock)
    let ask: () async -> [String: JevAnswer]? = { await jev.ask("probe", state: [:], questions: [("q", .noul("Yes?"))]) }

    wire.load([["fail": true]])
    #expect(await ask() == nil)
    #expect(wire.sent.count == 1 && !jev.available)
    // Instances on the same transport share the cooldown; one on another transport does not.
    #expect(!sibling.available && stranger.available)

    wire.load([CannedTransport.ok(["q": noul(1)])])
    #expect(await ask() == nil && wire.sent.isEmpty)
    #expect(await jev.shouldCloseBrowser("x") == true)
    #expect(await jev.routeRequest("play some lofi", hasDroppedPaths: false).reason == "no strong signal in the wording")
    #expect(wire.sent.isEmpty && wire.unused == 1)

    clock.advance(59_999)
    #expect(!jev.available)
    clock.advance(1)
    #expect(jev.available && sibling.available)
    #expect(await ask() == ["q": .noul(noul: 1)])
    #expect(wire.sent.count == 1)

    // A reply that is not what was promised fails the call without a cooldown: the service answered.
    wire.load([["status": 200, "body": "not json"]])
    #expect(await ask() == nil && jev.available)
}

@Test func jevCostsWhatItsInputCosts() async {
    let wire = CannedTransport()
    let jev = connected(wire)
    wire.load([CannedTransport.ok(["q": noul(1)], tokens: 1_000_000)])
    _ = await jev.ask("million", state: "x", questions: [("q", .noul("Yes?"))])
    #expect(jev.metrics.totalUsd == 0.042)
    #expect(jev.metrics.calls[0].usd == 0.042 && jev.metrics.calls[0].inputTokens == 1_000_000)

    // Output tokens are not metered, however many there are.
    wire.load([["status": 200, "body": "{\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":1}},\"usage\":{\"input_tokens\":500,\"output_tokens\":900000000}}"]])
    _ = await jev.ask("output", state: "x", questions: [("q", .noul("Yes?"))])
    #expect(jev.metrics.calls[1].usd == 500 * 0.042 / 1_000_000)
    #expect(jev.metrics.totalUsd == 0.042 + 500 * 0.042 / 1_000_000)

    // A failed call and a local decision cost nothing.
    wire.load([["status": 500, "body": ""]])
    _ = await jev.ask("failed", state: "x", questions: [("q", .noul("Yes?"))])
    _ = await jev.routeRequest("organise my downloads folder", hasDroppedPaths: false)
    #expect(jev.metrics.calls.count == 4 && jev.metrics.calls[2].usd == 0 && jev.metrics.calls[3].usd == 0)
    #expect(summarizeJev(jev.metrics) == "4 decisions (3 via Jev, 0 changed the local verdict), 0ms, $0.04202")
}

@Test func aSlowJevIsAbandonedAfterTheTimeout() async {
    #expect(Jev(apiKey: "k", enabled: true, transport: { _ in throw MerryError("unused") }, environment: [:]).timeoutMs == 1500)

    // A transport that honours cancellation, and one that ignores it: neither may hold the task up.
    for transport in [politeSlowTransport, stubbornSlowTransport] {
        let jev = Jev(apiKey: "k", enabled: true, transport: transport, environment: [:])
        jev.timeoutMs = 80
        let started = nowMs()
        #expect(await jev.ask("slow", state: "x", questions: [("q", .noul("Yes?"))]) == nil)
        #expect(nowMs() - started < 3000)
        #expect(!jev.available && jev.metrics.calls.map(\.outcome) == ["failed"])
        #expect(await jev.shouldCloseBrowser("x"))
    }
}

@Test func jevIsUnavailableWithoutAKey() async {
    let wire = CannedTransport()
    #expect(!Jev(apiKey: nil, enabled: true, transport: wire.transport, environment: [:]).available)
    #expect(!Jev(apiKey: "", enabled: true, transport: wire.transport, environment: ["TYPESAFE_API_KEY": " \n"]).available)
    #expect(!Jev(apiKey: "key", enabled: false, transport: wire.transport, environment: ["TYPESAFE_API_KEY": "env"]).available)
    #expect(Jev(apiKey: nil, enabled: true, transport: wire.transport, environment: ["TYPESAFE_API_KEY": "env"]).available)
    #expect(wire.sent.isEmpty)
}

@Test func questionsSerialiseLikeTheBuilders() {
    #expect(JevQuestion.choice("Which?", ["b": "B.", "a": "A."]).json.stringify() == "{\"type\":\"choice\",\"instructions\":\"Which?\",\"criteria\":{\"b\":\"B.\",\"a\":\"A.\"}}")
    #expect(JevQuestion.choice("Which?", [("b", "B."), ("2", "Two."), ("1", "One.")]).json.stringify() == "{\"type\":\"choice\",\"instructions\":\"Which?\",\"criteria\":{\"1\":\"One.\",\"2\":\"Two.\",\"b\":\"B.\"}}")
    #expect(JevQuestion.noul("Yes?").json.stringify() == "{\"type\":\"noul\",\"instructions\":\"Yes?\"}")
    #expect(JevQuestion.noul().json.stringify() == "{\"type\":\"noul\",\"instructions\":null}")
    #expect(JevQuestion.noul("Yes?", ["true": "Y.", "false": "N."]).json.stringify() == "{\"type\":\"noul\",\"instructions\":\"Yes?\",\"criteria\":{\"true\":\"Y.\",\"false\":\"N.\"}}")
    #expect(JevQuestion.score("How?", ["Low.", nil, "High."]).json.stringify() == "{\"type\":\"score\",\"instructions\":\"How?\",\"criteria\":[\"Low.\",null,\"High.\"]}")
}

@Test func answersReadWhateverShapeArrives() {
    let picked = JevAnswer(["type": "choice", "choice": "a", "confidence": 0.75, "probabilities": ["a": 0.75, "b": 0.25]])
    #expect(picked == .choice(choice: "a", confidence: 0.75, probabilities: ["a": 0.75, "b": 0.25]))
    #expect(picked.choice == "a" && picked.confidence == 0.75 && picked.noul == nil && picked.type == "choice")
    #expect(JevAnswer(["type": "noul", "noul": 0.25]) == .noul(noul: 0.25) && JevAnswer(["type": "noul", "noul": 0.25]).noul == 0.25)
    let scored = JevAnswer(["type": "score", "score": 1.5, "confidence": 0.5])
    #expect(scored == .score(score: 1.5, confidence: 0.5) && scored.score == 1.5 && scored.confidence == 0.5 && scored.choice == nil)
    // Half-formed answers keep what they have.
    let partial = JevAnswer(["type": "choice", "choice": "a"])
    #expect(partial.choice == "a" && partial.confidence == nil && partial.type == "choice")
    #expect(JevAnswer(["noul": 0.9]).noul == 0.9 && JevAnswer(["noul": 0.9]).type == nil)
    #expect(JevAnswer(.null).choice == nil && JevAnswer(7).noul == nil && JevAnswer(["type": "noul", "noul": "yes"]).noul == nil)
}

@Test func javaScriptPatternsKeepTheirMeaning() {
    // `\b`, `\w` and `\d` are ASCII-only in JavaScript.
    #expect(Rx.ecma("\\bapp\\b").test("éapp") && !Rx("\\bapp\\b").test("éapp"))
    #expect(!Rx.ecma("^\\w+$").test("café") && !Rx.ecma("\\d").test("७"))
    // `$` is the very end, and `.` stops only at the four line breaks JavaScript knows.
    #expect(!Rx.ecma("a$").test("a\n") && Rx("a$").test("a\n"))
    #expect(Rx.ecma("^a.b$").test("a\u{0085}b") && !Rx.ecma("^a.b$").test("a\u{2028}b") && Rx.ecma("^a.b$", "s").test("a\nb"))
    // `\s` includes the byte order mark and excludes the next-line control.
    #expect(Rx.ecma("^\\s$").test("\u{FEFF}") && !Rx.ecma("^\\s$").test("\u{0085}") && Rx.ecma("^[\\s-]+$").test(" -\u{00A0}"))
    // Brackets and ampersands inside a class are themselves.
    #expect(Rx.ecma("^[.*+?^${}()|[\\]\\\\&&]+$").test("[&]\\$^"))
    #expect(Rx.ecmaEscape("a.b*c (d) [e] {f} g|h ^$ \\ +?") == "a\\.b\\*c \\(d\\) \\[e\\] \\{f\\} g\\|h \\^\\$ \\\\ \\+\\?")
    #expect(" \u{FEFF}\u{00A0}x y\u{2029}\n".ecmaTrimmed == "x y" && "\u{0085}x".ecmaTrimmed == "\u{0085}x")
    #expect("".ecmaWordCount == 1 && "  a  b\tc ".ecmaWordCount == 3)
    #expect("éa".ecmaUpperFirst == "Éa" && "😀a".ecmaUpperFirst == "😀a" && "".ecmaUpperFirst == "" && "ßa".ecmaUpperFirst == "SSa")
}

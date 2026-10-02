import Testing
@testable import MerryCore

/// The Swift planner against the requests and proposals recorded from the
/// reference driven through the Anthropic SDK with a stubbed `fetch`.
@Suite(.serialized) struct AnthropicPlannerTests {
    let fixture = Fixture.load("anthropic-planner")

    @Test func everyScenarioSendsAndReturnsWhatTheOriginalDoes() async {
        let scenarios = fixture.list("scenarios")
        #expect(scenarios.count >= 18)
        var proposals = 0
        for scenario in scenarios {
            let problems = await replayAnthropicScenario(scenario, fixture: fixture)
            #expect(problems.isEmpty, "\(problems.prefix(5).joined(separator: "\n"))")
            proposals += scenario.list("ops").filter { $0.str("op") == "propose" }.count
        }
        #expect(proposals >= 45)
    }

    @Test func longHistoryIsTrimmedInTheFixture() {
        // Guards the fixture itself: the long scenario must actually reach the trim.
        let long = fixture.list("scenarios").first { $0.str("name") == "long history" }!
        let sizes = long.list("ops").filter { $0.str("op") == "propose" }.map { $0.list("requests")[0]["body"]!.list("messages").count }
        #expect(sizes.max() == 40)
        let last = long.list("ops").last!.list("requests")[0]["body"]!.list("messages")
        #expect(last[1].str("content") == "[Earlier steps in this task were summarised away to stay within context.]")
        #expect(!Planner.isToolResultMessage(last[2]))
    }

    @Test func retriesBackOffWithJitterWhenTheServerNamesNoWait() async {
        let overloaded: JSON = ["status": 529, "headers": [:], "body": "{}"]
        let ok = fixture.list("scenarios")[1].list("ops")[1].list("responses")[0]
        let run = await anthropicRetryWaits([overloaded, ["status": 500, "headers": [:], "body": ""], ok])
        #expect(run.error == nil && run.requests == 3 && run.waits.count == 2)
        #expect(run.waits[0] > 375 && run.waits[0] <= 500)
        #expect(run.waits[1] > 750 && run.waits[1] <= 1000)

        let failed = await anthropicRetryWaits([["fail": true], ["fail": true], ["fail": true], ok])
        #expect(failed.error == "Connection error." && failed.requests == 3)

        let refused = await anthropicRetryWaits([["status": 400, "headers": [:], "body": "{\"error\":{\"message\":\"bad\"}}"], ok])
        #expect(refused.requests == 1 && refused.waits.isEmpty && refused.error == "400 {\"error\":{\"message\":\"bad\"}}")
    }

    @Test func retryDelayFollowsTheServer() {
        func delay(_ headers: [String: String], remaining: Int = 2, random: Double = 0) -> Double {
            Planner.retryDelayMs(cannedHeaders(headers, status: 429), retriesRemaining: remaining, random: random, nowMs: 1_790_000_000_000)
        }
        #expect(delay(["retry-after-ms": "250"]) == 250)
        #expect(delay(["retry-after": "3"]) == 3000)
        #expect(delay(["retry-after": "1.5"]) == 1500)
        #expect(delay(["retry-after-ms": "40", "retry-after": "9"]) == 40)
        #expect(delay(["retry-after-ms": "0", "retry-after": "2"]) == 2000)
        #expect(delay(["retry-after": "Mon, 21 Sep 2026 14:13:30 GMT"]) == 10_000)
        #expect(delay(["retry-after": "Mon, 21 Sep 2026 13:00:00 GMT"]) == 500)
        #expect(delay(["retry-after": "soon"]) == 500)
        #expect(delay(["retry-after": "-4"]) == 500)
        #expect(delay(["retry-after-ms": "9999999999999"]) == 500)
        #expect(delay([:]) == 500)
        #expect(delay([:], remaining: 1) == 1000)
        #expect(delay([:], remaining: 2, random: 0.999999) > 375)
        #expect(Planner.retryDelayMs(nil, retriesRemaining: 1, random: 0.5) == 875)
    }

    @Test func aMissingKeyIsReportedBeforeAnythingIsSent() async {
        let message = await anthropicWithoutKey()
        #expect(message?.hasPrefix("Could not resolve authentication method.") == true)
    }

    @Test func environmentCanRedirectAndAuthorize() {
        let request = anthropicRequestFromEnvironment()
        #expect(request.url == "http://127.0.0.1:9/v1/messages?beta=true")
        #expect(request.authorization == "Bearer tok")
        #expect(request.key == nil)
    }

    @Test func streamOddities() throws {
        // CRLF line ends, comments, a data field split over lines, and an unknown event.
        let body = ": hello\r\nevent: message_start\r\ndata: {\"type\":\"message_start\",\r\ndata: \"message\":{\"model\":\"m\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\r\n\r\nevent: mystery\r\ndata: {}\r\n\r\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let message = try AnthropicStream.finalMessage(.init(body.utf8))
        #expect(message.str("stop_reason") == "end_turn")
        #expect(message["usage"]!.int("output_tokens") == 4)

        #expect(throws: AnthropicError.self) { try AnthropicStream.finalMessage(.init()) }
        let cut = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"content\":[],\"usage\":{}}}\n\n"
        #expect(throws: AnthropicError.self) { try AnthropicStream.finalMessage(.init(cut.utf8)) }
    }
}

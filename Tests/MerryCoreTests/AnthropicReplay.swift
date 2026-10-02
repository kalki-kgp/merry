import Foundation
@testable import MerryCore

/// A transport that answers from a list of canned responses and keeps what it was sent.
final class AnthropicCannedTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [JSON] = []
    private(set) var requests: [URLRequest] = []
    private(set) var sleeps: [Double] = []

    func load(_ responses: [JSON]) {
        lock.withLock { queue = responses; requests = []; sleeps = [] }
    }

    var unused: Int { lock.withLock { queue.count } }
    var seen: [URLRequest] { lock.withLock { requests } }
    var waited: [Double] { lock.withLock { sleeps } }

    func slept(_ ms: Double) { lock.withLock { sleeps.append(ms) } }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let next: JSON? = lock.withLock {
            requests.append(request)
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let next else { throw MerryError("no canned response left") }
        if next.flag("fail") { throw URLError(.cannotConnectToHost) }
        var headers: [String: String] = [:]
        for key in next["headers"]?.objectValue?.keys ?? [] { headers[key] = next["headers"]!.str(key) }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.int("status"), httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(next.str("body").utf8), response)
    }
}

/// Runs one recorded scenario through the Swift planner and lists everything
/// that differs from what the reference sent and returned.
func replayAnthropicScenario(_ scenario: JSON, fixture: JSON) async -> [String] {
    LocalTime.use(timeZone: "Asia/Kolkata")
    var problems: [String] = []
    let name = scenario.str("name")
    let stub = AnthropicCannedTransport()
    var environment = ["HOME": fixture.str("home")]
    if let key = scenario.optStr("envKey") { environment["ANTHROPIC_API_KEY"] = key }
    let fixedNow = fixture.num("now")
    let planner = Planner(
        model: scenario.str("model"), maxTokens: scenario.int("maxTokens"), apiKey: scenario.optStr("apiKey"),
        transport: { request in try stub.send(request) },
        environment: environment,
        now: { JSDate(fixedNow) },
        sleep: { ms in stub.slept(ms) }
    )
    for (index, op) in scenario.list("ops").enumerated() {
        let at = "\(name) op \(index)"
        switch op.str("op") {
        case "seed":
            let a = op["authorization"] ?? .null
            let task = TaskState(request: op.str("request"), authorization: Authorization(readRoots: a.strings("readRoots"), writeRoots: a.strings("writeRoots"), apps: a.strings("apps")))
            planner.seed(task: task, droppedPaths: op.strings("droppedPaths"))
        case "addToolResults":
            planner.addToolResults(op.list("results").map { ToolResultInput(callId: $0.str("callId"), content: $0.str("content"), isError: $0.flag("isError")) })
        case "addNote":
            planner.addNote(op.str("note"))
        case "setTier":
            planner.setTier(op.str("tier") == "quick" ? .quick : .full)
        case "propose":
            let toolSet = op.str("toolSet")
            stub.load(op.list("responses"))
            do {
                let proposal = try await planner.propose(tools: fixture["toolSets"]!.list(toolSet))
                if let wanted = op["proposal"] {
                    if let d = proposalJSON(proposal).firstDifference(from: wanted) { problems.append("\(at) proposal: \(d)") }
                } else {
                    problems.append("\(at): succeeded, expected error \(op.str("error"))")
                }
            } catch {
                if op["error"] == nil { problems.append("\(at): threw \(messageOf(error))") }
                else if messageOf(error) != op.str("error") { problems.append("\(at): error \(messageOf(error)), expected \(op.str("error"))") }
            }
            let wantedRequests = op.list("requests")
            let sent = stub.seen
            if sent.count != wantedRequests.count { problems.append("\(at): \(sent.count) requests, expected \(wantedRequests.count)") }
            if stub.unused != op.int("unused") { problems.append("\(at): \(stub.unused) responses unused, expected \(op.int("unused"))") }
            if stub.waited.count != max(0, sent.count - 1) { problems.append("\(at): waited \(stub.waited.count) times for \(sent.count) requests") }
            for (i, (request, wanted)) in zip(sent, wantedRequests).enumerated() {
                let label = "\(at) request \(i)"
                if request.url?.absoluteString != wanted.str("url") { problems.append("\(label) url \(request.url?.absoluteString ?? "")") }
                if request.httpMethod != wanted.str("method") { problems.append("\(label) method \(request.httpMethod ?? "")") }
                if request.timeoutInterval != 120 { problems.append("\(label) timeout \(request.timeoutInterval)") }
                let headers = wanted["headers"]!.objectValue!
                for key in ["x-api-key", "anthropic-version", "anthropic-beta", "content-type", "accept", "authorization"] {
                    let got = request.value(forHTTPHeaderField: key)
                    if got != headers[key]?.stringValue { problems.append("\(label) header \(key): \(got ?? "nil")") }
                }
                guard var body = try? JSON.parse(request.httpBody ?? Data()) else { problems.append("\(label): body is not JSON"); continue }
                // The fixture names the prompt and the tool list rather than repeating them.
                if body["system"]?[0]?.str("text") == SYSTEM_PROMPT, var system = body["system"]?.arrayValue {
                    system[0]["text"] = "<<SYSTEM_PROMPT>>"
                    body["system"] = .array(system)
                }
                if body["tools"] == fixture["toolSets"]![toolSet] { body["tools"] = .string("<<\(toolSet)>>") }
                if let d = body.firstDifference(from: wanted["body"] ?? .null) { problems.append("\(label) body: \(d)") }
            }
        default:
            problems.append("\(at): unknown op")
        }
    }
    return problems
}

/// The waits between attempts for one scripted run of responses.
func anthropicRetryWaits(_ responses: [JSON]) async -> (waits: [Double], requests: Int, error: String?) {
    let stub = AnthropicCannedTransport()
    stub.load(responses)
    let planner = Planner(model: "claude-sonnet-5-5", maxTokens: 100, apiKey: "k", transport: { try stub.send($0) }, environment: ["HOME": "/Users/tester"], sleep: { stub.slept($0) })
    planner.seed(task: TaskState(request: "hi"), droppedPaths: [])
    do {
        _ = try await planner.propose(tools: [])
        return (stub.waited, stub.seen.count, nil)
    } catch {
        return (stub.waited, stub.seen.count, messageOf(error))
    }
}

func cannedHeaders(_ pairs: [String: String], status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: pairs)!
}

/// What the planner does with no key anywhere.
func anthropicWithoutKey() async -> String? {
    let planner = Planner(model: "m", maxTokens: 1, apiKey: nil, transport: { _ in throw MerryError("must not be reached") }, environment: [:])
    planner.seed(task: TaskState(request: "hi"), droppedPaths: [])
    do { _ = try await planner.propose(tools: []); return nil } catch { return messageOf(error) }
}

/// The request built when the environment points somewhere else and carries a token.
func anthropicRequestFromEnvironment() -> (url: String?, authorization: String?, key: String?) {
    let planner = Planner(model: "m", maxTokens: 1, apiKey: nil, environment: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:9/", "ANTHROPIC_AUTH_TOKEN": "tok"])
    let request = try? planner.request(["model": "m"])
    return (request?.url?.absoluteString, request?.value(forHTTPHeaderField: "authorization"), request?.value(forHTTPHeaderField: "x-api-key"))
}

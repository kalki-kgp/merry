import Foundation
@testable import MerryCore

// Shapes the reference returns, rebuilt from the Swift values so a fixture row
// can be compared whole.

extension Understanding {
    var parityJSON: JSON {
        ["action": .string(action.rawValue), "kind": .string(kind.rawValue), "size": .string(size.rawValue), "when": .string(when.rawValue),
         "place": .string(place.rawValue), "vague": .bool(vague), "confidence": .number(confidence), "source": .string(source.rawValue)]
    }

    init(parity json: JSON) {
        self.init(
            action: Action(rawValue: json.str("action"))!, kind: Kind(rawValue: json.str("kind"))!, size: Size(rawValue: json.str("size"))!,
            when: When(rawValue: json.str("when"))!, place: Place(rawValue: json.str("place"))!, vague: json.flag("vague"),
            confidence: json.num("confidence"), source: JevSource(rawValue: json.str("source"))!
        )
    }
}

extension UnderstoodRoute {
    var parityJSON: JSON { ["route": .string(route), "reason": .string(reason), "needsClarification": .bool(needsClarification)] }
}

extension RouteDecision {
    var parityJSON: JSON {
        ["route": .string(route.rawValue), "confidence": .number(confidence), "reason": .string(reason), "needsClarification": .bool(needsClarification)]
    }
}

extension PlanSetup {
    var parityJSON: JSON {
        ["families": JSON(families.map(\.rawValue)),
         "context": ["selection": .bool(context.selection), "tab": .bool(context.tab), "finder": .bool(context.finder), "clipboard": .bool(context.clipboard)],
         "quick": .bool(quick), "ownBrowser": .bool(ownBrowser), "start": .string(start.rawValue), "source": .string(source.rawValue)]
    }
}

extension ProgressVerdict {
    var parityJSON: JSON { ["action": .string(action.rawValue), "reason": .string(reason), "deterministic": .bool(deterministic)] }
}

extension SelfDescription {
    var parityJSON: JSON {
        ["headline": .string(headline), "evidence": .array(evidence.map { ["kind": .string($0.kind.rawValue), "label": .string($0.label), "value": .string($0.value)] })]
    }
}

extension Recalled {
    var parityJSON: JSON { ["memory": JSON.encode(memory), "why": .string(why)] }
}

extension JevMetrics {
    init(parity json: JSON) {
        self.init()
        calls = json.list("calls").map {
            JevCallRecord(decision: $0.str("decision"), usedModel: $0.flag("usedModel"), latencyMs: $0.num("latencyMs"), usd: $0.num("usd"),
                          inputTokens: $0.int("inputTokens"), outcome: $0.str("outcome"), confidence: $0.num("confidence"))
        }
        totalUsd = json.num("totalUsd")
        totalLatencyMs = json.num("totalLatencyMs")
        overrides = json.int("overrides")
    }
}

/// A task with the history a fixture row describes.
func parityTask(request: String = "do the thing", max: Int?, actions: [JSON]) -> TaskState {
    var task = TaskState(id: "t", request: request, limits: TaskLimits(maxConsecutiveFailures: max ?? 3), now: 0)
    task.actions = actions.map { a in
        var record = ActionRecord(id: a.str("id"), step: a.int("step"), tool: a.str("tool"), input: a["input"] ?? [:], startedAt: a.num("startedAt"),
                                  outcome: ActionRecord.Outcome(rawValue: a.str("outcome"))!)
        record.error = a.optStr("error")
        if let v = a["verification"] { record.verification = VerificationResult(verified: v.flag("verified"), method: v.str("method"), detail: v.str("detail")) }
        return record
    }
    return task
}

func parityMemories(_ list: [JSON]) -> [Memory] {
    list.map { try! $0.decode(Memory.self) }
}

/// An adapter that supports exactly the capabilities it is given, and does nothing else.
final class CapabilityOnlyAdapter: OsAdapter {
    let capabilities: Set<String>
    init(_ capabilities: [String]) { self.capabilities = Set(capabilities) }
    func supports(_ capability: Capability) -> Bool { capabilities.contains(capability.rawValue) }
    func getPermissions() async throws -> [PermissionStatus] { [] }
    func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus { PermissionStatus(permission: permission, granted: false, purpose: "") }
    func automationPermission(bundleId: String, ask: Bool) async throws -> AutomationStatus { .unknown }
    func listApps() async throws -> [AppInfo] { [] }
    func getFrontmostWindow() async throws -> WindowSnapshot? { nil }
    func focusWindow(pid: Int, windowId: String?) async throws {}
    func inspectWindow(pid: Int, maxDepth: Int?, maxNodes: Int?) async throws -> WindowSnapshot { throw UnsupportedCapabilityError(.windowInspect) }
    func pressElement(_ ref: ElementRef, action: String?) async throws {}
    func setElementValue(_ ref: ElementRef, value: String) async throws {}
    func click(_ point: ScreenPoint, button: String?, count: Int?) async throws {}
    func typeText(_ text: String) async throws {}
    func shortcut(_ keys: String) async throws {}
    func scroll(_ point: ScreenPoint, dx: Double, dy: Double) async throws {}
    func captureWindow(pid: Int, windowId: String?) async throws -> CaptureResult { throw UnsupportedCapabilityError(.windowCapture) }
    func listDisplays() async throws -> [DisplayInfo] { [] }
    func dispose() async {}
}

/// A transport that records what is sent and answers from a queue of canned
/// replies, in the fixture's shape: `{status, body}`, `{fail: true}` or `{hang: true}`.
final class CannedTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [JSON] = []
    private var requests: [URLRequest] = []

    var sent: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var unused: Int { lock.lock(); defer { lock.unlock() }; return queue.count }

    func load(_ replies: [JSON]) {
        lock.lock(); defer { lock.unlock() }
        queue = replies
        requests = []
    }

    private func take(_ request: URLRequest) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    var transport: JevTransport {
        { [self] request in
            guard let next = take(request), !next.flag("fail") else { throw MerryError("network down") }
            if next.flag("hang") {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw MerryError("aborted")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.int("status"), httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
            return (Data(next.str("body").utf8), response)
        }
    }

    static func ok(_ answers: JSON, tokens: Int = 400) -> JSON {
        ["status": 200, "body": .string(JSON.obj(["model": "jev-latest", "answers": answers, "usage": ["input_tokens": .number(Double(tokens)), "output_tokens": 12]]).stringify())]
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double
    init(_ ms: Double) { self.ms = ms }
    var now: Double { lock.lock(); defer { lock.unlock() }; return ms }
    func advance(_ by: Double) { lock.lock(); defer { lock.unlock() }; ms += by }
}

// What a recorded request carried.
func sentURL(_ request: URLRequest) -> String? { request.url?.absoluteString }
func sentMethod(_ request: URLRequest) -> String? { request.httpMethod }
func sentHeader(_ request: URLRequest, _ name: String) -> String? { request.value(forHTTPHeaderField: name) }
func sentBody(_ request: URLRequest) -> String { String(decoding: request.httpBody ?? Data(), as: UTF8.self) }

/// Never answers, but stops when cancelled.
let politeSlowTransport: JevTransport = { _ in
    try await Task.sleep(nanoseconds: 20_000_000_000)
    throw MerryError("never")
}

/// Answers after three seconds, cancelled or not.
let stubbornSlowTransport: JevTransport = { request in
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

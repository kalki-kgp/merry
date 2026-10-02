import Foundation
@testable import MerryCore

/// What a tool did, in the order it did it: desktop claims, log lines and
/// calls that reached the adapter.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var seen: [JSON] = []
    private var pressed: [ElementRef] = []

    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func observe(_ o: JSON) { lock.lock(); seen.append(o); lock.unlock() }
    func acted(on ref: ElementRef) { lock.lock(); pressed.append(ref); lock.unlock() }

    var events: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var observations: [JSON] { lock.lock(); defer { lock.unlock() }; return seen }
    var refs: [ElementRef] { lock.lock(); defer { lock.unlock() }; return pressed }
    func reset() { lock.lock(); lines = []; seen = []; pressed = []; lock.unlock() }
}

struct ScriptedFailure {
    var stale: Bool
    var message: String
    var error: Error { stale ? StaleElementError(message) : MerryError(message) }
}

/// An adapter over scripted windows and elements. It never touches macOS.
final class FakeOsAdapter: OsAdapter, @unchecked Sendable {
    private let lock = NSLock()
    let log: EventLog

    private var apps: [AppInfo] = []
    private var displays: [DisplayInfo] = []
    private var snapshots: [String: WindowSnapshot] = [:]
    /// Which scripted snapshot is in front, and which one each pid shows.
    private var front: String?
    private var windows: [String: String] = [:]
    /// How long ago each snapshot claims to have been observed.
    private var ages: [String: Double] = [:]
    private var pressError: ScriptedFailure?
    private var setError: ScriptedFailure?
    private var capture = CaptureResult(path: "", width: 0, height: 0, scaleFactor: 1)

    init(log: EventLog = EventLog(), world: JSON, snapshots: JSON) {
        self.log = log
        for (key, value) in snapshots.objectValue?.pairs ?? [] {
            self.snapshots[key] = try! value.decode(WindowSnapshot.self)
        }
        apply(world)
    }

    /// Replaces the parts of the scripted world that `patch` names.
    func apply(_ patch: JSON) {
        lock.lock(); defer { lock.unlock() }
        func failure(_ v: JSON) -> ScriptedFailure? { v.isNull ? nil : ScriptedFailure(stale: v.flag("stale"), message: v.str("message")) }
        for (key, value) in patch.objectValue?.pairs ?? [] {
            switch key {
            case "apps": apps = try! value.decode([AppInfo].self)
            case "displays": displays = try! value.decode([DisplayInfo].self)
            case "front": front = value.stringValue
            case "windows": windows = (value.objectValue?.pairs ?? []).reduce(into: [:]) { $0[$1.key] = $1.value.stringValue }
            case "ages": ages = (value.objectValue?.pairs ?? []).reduce(into: [:]) { $0[$1.key] = $1.value.doubleValue }
            case "pressError": pressError = failure(value)
            case "setError": setError = failure(value)
            case "capture": capture = try! value.decode(CaptureResult.self)
            default: fatalError("unknown world key \(key)")
            }
        }
    }

    private func stamped(_ key: String) -> WindowSnapshot {
        var snap = snapshots[key]!
        snap.observedAt = nowMs() - (ages[key] ?? 0)
        return snap
    }

    private func text(_ value: Int?) -> String { value.map(String.init) ?? "undefined" }
    private func number(_ n: Double) -> String { JSON.number(n).stringify() }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func supports(_ capability: Capability) -> Bool { true }
    func getPermissions() async throws -> [PermissionStatus] { [] }
    func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus {
        PermissionStatus(permission: permission, granted: false, purpose: "")
    }
    func automationPermission(bundleId: String, ask: Bool) async throws -> AutomationStatus { .unknown }

    func listApps() async throws -> [AppInfo] { locked { apps } }
    func listDisplays() async throws -> [DisplayInfo] { locked { displays } }
    func getFrontmostWindow() async throws -> WindowSnapshot? { locked { front.map(stamped) } }

    func inspectWindow(pid: Int, maxDepth: Int?, maxNodes: Int?) async throws -> WindowSnapshot {
        log.add("call inspectWindow \(pid) maxDepth=\(text(maxDepth)) maxNodes=\(text(maxNodes))")
        return try locked {
            guard let key = windows[String(pid)] else { throw MerryError("no running application with pid \(pid)") }
            return stamped(key)
        }
    }

    func focusWindow(pid: Int, windowId: String?) async throws {
        log.add("call focusWindow \(pid) \(windowId ?? "undefined")")
    }

    func pressElement(_ ref: ElementRef, action: String?) async throws {
        log.add("call pressElement \(ref.pid) \(ref.id) \(action ?? "undefined")")
        log.acted(on: ref)
        if let failure = locked({ pressError }) { throw failure.error }
    }

    func setElementValue(_ ref: ElementRef, value: String) async throws {
        log.add("call setElementValue \(ref.pid) \(ref.id) \(JSON.string(value).stringify())")
        log.acted(on: ref)
        if let failure = locked({ setError }) { throw failure.error }
    }

    func click(_ point: ScreenPoint, button: String?, count: Int?) async throws {
        log.add("call click \(number(point.x)) \(number(point.y)) \(button ?? "undefined") \(text(count))")
    }
    func typeText(_ text: String) async throws { log.add("call typeText \(JSON.string(text).stringify())") }
    func shortcut(_ keys: String) async throws { log.add("call shortcut \(keys)") }
    func scroll(_ point: ScreenPoint, dx: Double, dy: Double) async throws {
        log.add("call scroll \(number(point.x)) \(number(point.y)) \(number(dx)) \(number(dy))")
    }

    func captureWindow(pid: Int, windowId: String?) async throws -> CaptureResult {
        log.add("call captureWindow \(pid) \(windowId ?? "undefined")")
        return locked { capture }
    }

    func dispose() async {}
}

/// A tool context whose claims, log lines and observations land in `log`.
func fakeToolContext(taskId: String, os: OsAdapter, log: EventLog, claim: (@Sendable (String) async throws -> Void)? = nil) -> ToolContext {
    let task = TaskState(id: taskId, request: "test")
    return ToolContext(
        task: { task },
        os: os,
        browser: NoBrowser(),
        log: { level, message, _ in log.add("log \(level.rawValue) \(message)") },
        observe: { kind, summary, data, stale in
            log.observe(["kind": .string(kind), "summary": .string(summary), "data": data, "staleAfterMs": .number(stale)])
            return Observation(id: newId(), kind: kind, summary: summary, data: data, observedAt: nowMs(), staleAfterMs: stale)
        },
        claimDesktop: { reason in
            log.add("claim \(reason)")
            try await claim?(reason)
        }
    )
}

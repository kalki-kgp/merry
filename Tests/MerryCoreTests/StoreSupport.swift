import Foundation
@testable import MerryCore

/// Scratch folders for the store tests. Nothing here ever touches the real data folder.
enum Scratch {
    static func directory(_ label: String = "store") -> String {
        let path = Path.join(Path.tmp, "merry-tests-\(label)-\(UUID().uuidString.lowercased())")
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // The paths the code under test sees must be the real ones, not /var -> /private/var.
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func write(_ path: String, _ text: String = "x") {
        try! FileManager.default.createDirectory(atPath: Path.dirname(path), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    static func mkdir(_ path: String) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func move(_ from: String, _ to: String) {
        try! FileManager.default.moveItem(atPath: from, toPath: to)
    }

    static func chmod(_ path: String, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    static var isRoot: Bool { getuid() == 0 }
}

/// Ids in order of creation, as the parity fixtures were recorded with.
final class IdSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return made }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        made += 1
        return "id-\(made)"
    }
}

// MARK: - Setup

final class FakeOs: OsAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [OsPermission: Bool] = [:]
    private var automation: [String: AutomationStatus] = [:]
    private var onAsk: [String: AutomationStatus] = [:]
    private var log: [String] = []
    private var failing = false

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func grant(_ permission: OsPermission, _ value: Bool) { lock.lock(); grants[permission] = value; lock.unlock() }
    func set(_ bundleId: String, _ status: AutomationStatus) { lock.lock(); automation[bundleId] = status; lock.unlock() }
    func whenAsked(_ bundleId: String, _ status: AutomationStatus) { lock.lock(); onAsk[bundleId] = status; lock.unlock() }
    func fail(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }

    func supports(_ capability: Capability) -> Bool { false }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func getPermissions() async throws -> [PermissionStatus] {
        try locked {
            if failing { throw MerryError("helper is gone") }
            return grants.map { PermissionStatus(permission: $0.key, granted: $0.value, purpose: "") }
        }
    }
    func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus {
        locked {
            log.append("request \(permission.rawValue)")
            return PermissionStatus(permission: permission, granted: grants[permission] ?? false, purpose: "")
        }
    }
    func automationPermission(bundleId: String, ask: Bool) async throws -> AutomationStatus {
        try locked {
            if failing { throw MerryError("helper is gone") }
            if ask {
                log.append("ask \(bundleId)")
                if let answer = onAsk[bundleId] { automation[bundleId] = answer }
            }
            return automation[bundleId] ?? .notInstalled
        }
    }
    func listApps() async throws -> [AppInfo] { throw UnsupportedCapabilityError(.appsList) }
    func getFrontmostWindow() async throws -> WindowSnapshot? { throw UnsupportedCapabilityError(.windowInspect) }
    func focusWindow(pid: Int, windowId: String?) async throws { throw UnsupportedCapabilityError(.windowFocus) }
    func inspectWindow(pid: Int, maxDepth: Int?, maxNodes: Int?) async throws -> WindowSnapshot { throw UnsupportedCapabilityError(.windowInspect) }
    func pressElement(_ ref: ElementRef, action: String?) async throws { throw UnsupportedCapabilityError(.elementAct) }
    func setElementValue(_ ref: ElementRef, value: String) async throws { throw UnsupportedCapabilityError(.elementAct) }
    func click(_ point: ScreenPoint, button: String?, count: Int?) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    func typeText(_ text: String) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    func shortcut(_ keys: String) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    func scroll(_ point: ScreenPoint, dx: Double, dy: Double) async throws { throw UnsupportedCapabilityError(.inputSynthetic) }
    func captureWindow(pid: Int, windowId: String?) async throws -> CaptureResult { throw UnsupportedCapabilityError(.windowCapture) }
    func listDisplays() async throws -> [DisplayInfo] { throw UnsupportedCapabilityError(.displayInfo) }
    func dispose() async {}
}

struct SetupRig {
    let os = FakeOs()
    let store: Store
    let home: String
    let notified = Recorder<Bool>()
    let opened = Recorder<String>()
    let setup: Setup

    init() throws {
        store = try Store.inMemory()
        home = Scratch.directory("home")
        let notified = self.notified, opened = self.opened, home = self.home
        setup = Setup(os: os, store: store, notify: { notified.add(true) }, openURL: { opened.add($0) }, home: { home })
    }

    func answers() -> JSON { (try? JSON.parse((try? store.getSetting("setup_answers")) ?? "{}")) ?? .null }
    func close() { store.close(); Scratch.remove(home) }
}


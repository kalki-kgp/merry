import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

// macOS integration: Accessibility, window capture, displays and permissions.
//
// It is deliberately dumb: it exposes capabilities and reports failure
// honestly. All policy lives in the tools and the task loop.
//
// Every call runs off the main thread and is bounded by a timeout, so an app
// that has stopped answering Accessibility requests can never stall a task or
// the interface.

private let permissionPurpose: [OsPermission: String] = [
    .accessibility: "Lets Merry read window contents and press buttons in apps, instead of guessing from pixels.",
    .screenRecording: "Lets Merry take a picture of a specific window when an app exposes no readable controls.",
    .automation: "Lets Merry ask apps to perform scripted actions.",
    .fullDisk: "Lets Merry reach folders macOS protects, such as Mail or Messages storage."
]

// MARK: - Bounded calls

/// When a call must have finished. Long walks check it between steps, so the
/// thread doing the work stops soon after the caller has given up on it.
final class CallDeadline: Sendable {
    let op: String
    let timeoutMs: Int
    let at: DispatchTime

    init(op: String, timeoutMs: Int) {
        self.op = op
        self.timeoutMs = timeoutMs
        self.at = .now() + .milliseconds(timeoutMs)
    }

    var error: MerryError { MerryError("macOS helper timed out after \(timeoutMs)ms on \"\(op)\"") }
    func check() throws { if DispatchTime.now() >= at { throw error } }
}

/// Resumes a continuation with whichever arrives first: the result or the timeout.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// Accessibility calls block on the other app; they get their own threads.
private let workQueue = DispatchQueue(label: "merry.os.work", qos: .userInitiated, attributes: .concurrent)
/// Synthetic input is strictly one event sequence at a time.
private let inputQueue = DispatchQueue(label: "merry.os.input", qos: .userInitiated)
private let timerQueue = DispatchQueue(label: "merry.os.timeout", qos: .userInitiated)

func bounded<T: Sendable>(
    _ op: String,
    timeoutMs: Int = 12_000,
    on queue: DispatchQueue = workQueue,
    _ body: @escaping @Sendable (CallDeadline) throws -> T
) async throws -> T {
    let deadline = CallDeadline(op: op, timeoutMs: timeoutMs)
    return try await withCheckedThrowingContinuation { continuation in
        let once = Once(continuation)
        queue.async { once.finish(Result { try body(deadline) }) }
        timerQueue.asyncAfter(deadline: deadline.at) { once.finish(.failure(deadline.error)) }
    }
}

private func boundedAsync<T: Sendable>(
    timeoutMs: Int,
    timeout: MerryError,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = Once(continuation)
        let task = Task.detached(priority: .userInitiated) {
            do { once.finish(.success(try await body())) } catch { once.finish(.failure(error)) }
        }
        timerQueue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
            once.finish(.failure(timeout))
            task.cancel()
        }
    }
}

// MARK: - Accessibility helpers

private func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var out: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &out)
    return err == .success ? out : nil
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let v = axCopy(element, attribute) else { return nil }
    if let s = v as? String { return s }
    if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    guard let v = axCopy(element, attribute) as? NSNumber else { return false }
    return v.boolValue
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let v = axCopy(element, kAXChildrenAttribute as String) else { return [] }
    return (v as? [AXUIElement]) ?? []
}

private func axWindows(_ app: AXUIElement) -> [AXUIElement]? {
    axCopy(app, kAXWindowsAttribute as String) as? [AXUIElement]
}

private func axFrame(_ element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero
    var size = CGSize.zero
    if let p = axCopy(element, kAXPositionAttribute as String), CFGetTypeID(p) == AXValueGetTypeID() {
        AXValueGetValue((p as! AXValue), .cgPoint, &origin)
    }
    if let s = axCopy(element, kAXSizeAttribute as String), CFGetTypeID(s) == AXValueGetTypeID() {
        AXValueGetValue((s as! AXValue), .cgSize, &size)
    }
    return CGRect(origin: origin, size: size)
}

private func axActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return list
}

/// A human-usable label: AX exposes the same idea under several attributes.
private func axLabel(_ element: AXUIElement) -> String {
    for attr in [kAXTitleAttribute as String,
                 kAXDescriptionAttribute as String,
                 "AXLabel",
                 kAXHelpAttribute as String,
                 kAXPlaceholderValueAttribute as String] {
        if let s = axString(element, attr), !s.isEmpty { return s }
    }
    if let v = axString(element, kAXValueAttribute as String), !v.isEmpty, v.count < 80 { return v }
    return ""
}

private func frameOf(_ rect: CGRect) -> Frame {
    Frame(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.size.width), height: Double(rect.size.height))
}

private func serializeElement(
    _ element: AXUIElement, path: [Int], pid: Int, windowId: String,
    depth: Int, maxDepth: Int, budget: inout Int, deadline: CallDeadline
) throws -> UiElement? {
    if budget <= 0 { return nil }
    try deadline.check()
    budget -= 1
    let role = axString(element, kAXRoleAttribute as String) ?? "AXUnknown"
    let frame = frameOf(axFrame(element))
    let label = axLabel(element)
    let actions = axActions(element)

    var node = UiElement(
        ref: ElementRef(
            id: "\(windowId):" + path.map(String.init).joined(separator: "."),
            pid: pid,
            windowId: windowId,
            path: path,
            stamp: ElementStamp(role: role, title: label, frame: frame)
        ),
        role: role,
        title: label,
        enabled: axBool(element, kAXEnabledAttribute as String),
        focused: axBool(element, kAXFocusedAttribute as String),
        frame: frame,
        actions: actions
    )
    if let sub = axString(element, kAXSubroleAttribute as String) { node.subrole = sub }
    if let value = axString(element, kAXValueAttribute as String), value.count < 2000 { node.value = value }

    if depth < maxDepth {
        var kids: [UiElement] = []
        for (i, child) in axChildren(element).enumerated() {
            if budget <= 0 { break }
            if let c = try serializeElement(child, path: path + [i], pid: pid, windowId: windowId,
                                            depth: depth + 1, maxDepth: maxDepth, budget: &budget, deadline: deadline) {
                kids.append(c)
            }
        }
        if !kids.isEmpty { node.children = kids }
    }
    return node
}

private func processId(_ pid: Int) -> pid_t? { pid_t(exactly: pid) }

private func resolveElement(pid: pid_t, windowId: String, path: [Int], deadline: CallDeadline) throws -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    guard let windows = axWindows(app) else {
        throw MerryError("application \(pid) exposes no windows")
    }
    let index = MacOsAdapter.windowIndex(from: windowId)
    guard index >= 0, index < windows.count else {
        throw MerryError("window \(windowId) no longer exists")
    }
    var current = windows[index]
    for step in path {
        try deadline.check()
        let kids = axChildren(current)
        guard step >= 0, step < kids.count else {
            throw MerryError("element path no longer resolves (index \(step) out of range)")
        }
        current = kids[step]
    }
    return current
}

/// Confirms the element still looks like what was observed. Callers pass the
/// stamp recorded at observation time; a mismatch means "re-observe", not "act".
private func validateStamp(_ element: AXUIElement, _ stamp: ElementStamp) throws {
    let role = axString(element, kAXRoleAttribute as String) ?? "AXUnknown"
    if stamp.role != role {
        throw MerryError("element changed: expected role \(stamp.role), found \(role)")
    }
    if !stamp.title.isEmpty {
        let actual = axLabel(element)
        if actual != stamp.title {
            throw MerryError("element changed: expected \"\(stamp.title)\", found \"\(actual)\"")
        }
    }
}

// MARK: - Apps and windows

private func appInfo(_ app: NSRunningApplication, windowCount: Int) -> AppInfo {
    AppInfo(
        bundleId: app.bundleIdentifier ?? "",
        name: app.localizedName ?? "",
        pid: Int(app.processIdentifier),
        active: app.isActive,
        windowCount: windowCount
    )
}

private func runningApps(deadline: CallDeadline) throws -> [AppInfo] {
    try NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .map { app in
            try deadline.check()
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            return appInfo(app, windowCount: (axWindows(ax) ?? []).count)
        }
}

private func snapshotWindow(pid: Int, windowId: String?, maxDepth: Int, maxNodes: Int, deadline: CallDeadline) throws -> WindowSnapshot {
    guard let processId = processId(pid), let app = NSRunningApplication(processIdentifier: processId) else {
        throw MerryError("no running application with pid \(pid)")
    }
    let ax = AXUIElementCreateApplication(processId)
    guard let windows = axWindows(ax), !windows.isEmpty else {
        throw MerryError("\(app.localizedName ?? "app") has no accessible windows (is Accessibility permission granted?)")
    }
    let index = windowId.map(MacOsAdapter.windowIndex(from:)) ?? 0
    guard index >= 0, index < windows.count else { throw MerryError("window index \(index) out of range") }
    let window = windows[index]
    let wid = "w\(index)"
    let frame = axFrame(window)
    var budget = maxNodes
    let root = try serializeElement(window, path: [], pid: pid, windowId: wid,
                                    depth: 0, maxDepth: maxDepth, budget: &budget, deadline: deadline)

    // Accessibility frames and display bounds share one coordinate space, so
    // they can be intersected directly.
    let displays = MacOsAdapter.displays()
    let display = displays.first { d in
        CGRect(x: d.bounds.x, y: d.bounds.y, width: d.bounds.width, height: d.bounds.height).intersects(frame)
    } ?? displays.first

    return WindowSnapshot(
        app: appInfo(app, windowCount: windows.count),
        windowId: wid,
        title: axString(window, kAXTitleAttribute as String) ?? "",
        frame: frameOf(frame),
        displayId: display?.id ?? 0,
        elements: root.map { [$0] } ?? [],
        observedAt: Date().timeIntervalSince1970 * 1000
    )
}

// MARK: - Synthetic input

private let keyCodeMap: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
    "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
    "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117
]

/// Posting events without the grant is silently ignored by macOS, which would
/// leave the caller believing it had clicked or typed. Checking never prompts.
private func mayPostEvents() -> Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

private func postShortcut(_ spec: String) throws {
    let (key, flags) = try MacOsAdapter.parseShortcut(spec)
    let source = CGEventSource(stateID: .combinedSessionState)
    guard mayPostEvents(),
          let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
        throw MerryError("could not create key events (Accessibility permission required)")
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(12_000)
    up.post(tap: .cghidEventTap)
}

/// Types literal text. Uses unicode payloads so layout and diacritics behave.
private func postText(_ text: String, deadline: CallDeadline) throws {
    let source = CGEventSource(stateID: .combinedSessionState)
    for chunk in MacOsAdapter.chunked(text, into: 16) {
        try deadline.check()
        guard mayPostEvents(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw MerryError("could not create key events (Accessibility permission required)")
        }
        var utf16 = Array(chunk.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        usleep(4_000)
        up.post(tap: .cghidEventTap)
        usleep(6_000)
    }
}

private func postClick(x: Double, y: Double, button: String, count: Int) throws {
    guard mayPostEvents() else {
        throw MerryError("could not create mouse events (Accessibility permission required)")
    }
    let source = CGEventSource(stateID: .combinedSessionState)
    let point = CGPoint(x: x, y: y)
    let (downType, upType, mouseButton): (CGEventType, CGEventType, CGMouseButton) =
        button == "right" ? (.rightMouseDown, .rightMouseUp, .right)
                          : (.leftMouseDown, .leftMouseUp, .left)
    if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                          mouseCursorPosition: point, mouseButton: mouseButton) {
        move.post(tap: .cghidEventTap)
        usleep(15_000)
    }
    for click in 1...max(1, count) {
        guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                 mouseCursorPosition: point, mouseButton: mouseButton),
              let up = CGEvent(mouseEventSource: source, mouseType: upType,
                               mouseCursorPosition: point, mouseButton: mouseButton) else {
            throw MerryError("could not create mouse events (Accessibility permission required)")
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

private func postScroll(x: Double, y: Double, dx: Int32, dy: Int32) throws {
    guard mayPostEvents() else {
        throw MerryError("could not create scroll event (Accessibility permission required)")
    }
    let source = CGEventSource(stateID: .combinedSessionState)
    if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                          mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) {
        move.post(tap: .cghidEventTap)
        usleep(10_000)
    }
    guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                               wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
        throw MerryError("could not create scroll event")
    }
    scroll.post(tap: .cghidEventTap)
}

// MARK: - Capture (ScreenCaptureKit)

private func captureWindowImage(pid: Int, windowId: String?, outputPath: String) async throws -> CaptureResult {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows
            .filter { $0.owningApplication.map { Int($0.processID) } == pid && $0.isOnScreen }
            .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
        let index = windowId.map(MacOsAdapter.windowIndex(from:)) ?? 0
        guard let window = candidates.indices.contains(index) ? candidates[index] : candidates.first else {
            throw MerryError("no capturable on-screen window for pid \(pid)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = MacOsAdapter.displays().first?.scaleFactor ?? 2.0
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let url = URL(fileURLWithPath: outputPath)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MerryError("could not open \(outputPath) for writing")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MerryError("could not encode PNG") }
        return CaptureResult(path: outputPath, width: image.width, height: image.height, scaleFactor: scale)
    } catch let error as MerryError {
        throw error
    } catch {
        throw MerryError("capture failed: \(error.localizedDescription)")
    }
}

// MARK: - Automation (Apple Events) permission

private final class LaunchedApp: @unchecked Sendable {
    private let lock = NSLock()
    private var app: NSRunningApplication?
    func set(_ value: NSRunningApplication?) { lock.lock(); app = value; lock.unlock() }
    var value: NSRunningApplication? { lock.lock(); defer { lock.unlock() }; return app }
}

/// Whether Merry may send Apple Events to an app. With `ask`, macOS shows its
/// "Merry wants to control …" dialog when the person has not answered yet; an
/// app that is not open is started hidden for the question and quit after.
private func automationStatus(bundleId: String, ask: Bool) -> AutomationStatus {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return .notInstalled }
    var launched: NSRunningApplication?
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
        if !ask { return .notRunning }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        let opened = DispatchSemaphore(value: 0)
        let box = LaunchedApp()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            box.set(app)
            opened.signal()
        }
        _ = opened.wait(timeout: .now() + 15)
        launched = box.value
        for _ in 0..<50 where !(launched?.isFinishedLaunching ?? true) { usleep(100_000) }
    }
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    let err = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    if let app = launched { app.terminate() }
    switch Int(err) {
    case Int(noErr): return .granted
    case -1743: return .denied          // errAEEventNotPermitted
    case -1744: return .notAsked        // errAEEventWouldRequireUserConsent
    case -600: return .notRunning       // procNotFound
    default: return .unknown
    }
}

// MARK: - The adapter

public final class MacOsAdapter: OsAdapter {
    public init() {}

    public func supports(_ capability: Capability) -> Bool {
        switch capability {
        case .appsList, .windowInspect, .windowFocus, .windowCapture, .elementAct, .inputSynthetic, .displayInfo:
            return true
        }
    }

    public func getPermissions() async throws -> [PermissionStatus] {
        try await bounded("permissions") { _ in
            // Checking must not prompt: neither of these calls ever does.
            let accessibility = AXIsProcessTrusted()
            let screen = CGPreflightScreenCaptureAccess()
            return [
                PermissionStatus(permission: .accessibility, granted: accessibility, purpose: permissionPurpose[.accessibility]!),
                PermissionStatus(permission: .screenRecording, granted: screen, purpose: permissionPurpose[.screenRecording]!)
            ]
        }
    }

    public func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus {
        let granted: Bool = try await bounded("requestPermission", timeoutMs: 30_000) { _ in
            switch permission {
            case .accessibility:
                let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                if !granted {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                return granted
            case .screenRecording:
                let granted = CGRequestScreenCaptureAccess()
                if !granted {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                return granted
            default:
                throw MerryError("unknown permission \(permission.rawValue)")
            }
        }
        return PermissionStatus(permission: permission, granted: granted, purpose: permissionPurpose[permission]!)
    }

    public func automationPermission(bundleId: String, ask: Bool) async throws -> AutomationStatus {
        // Asking waits for the person to answer a system dialog.
        try await bounded("automation", timeoutMs: ask ? 180_000 : 10_000) { _ in
            automationStatus(bundleId: bundleId, ask: ask)
        }
    }

    public func listApps() async throws -> [AppInfo] {
        try await bounded("listApps") { deadline in try runningApps(deadline: deadline) }
    }

    public func getFrontmostWindow() async throws -> WindowSnapshot? {
        try await bounded("frontmostWindow") { deadline in
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return try snapshotWindow(pid: Int(app.processIdentifier), windowId: nil, maxDepth: 12, maxNodes: 400, deadline: deadline)
        }
    }

    public func focusWindow(pid: Int, windowId: String?) async throws {
        try await bounded("focusWindow") { deadline in
            guard let processId = processId(pid), let app = NSRunningApplication(processIdentifier: processId) else {
                throw MerryError("no application with that pid")
            }
            app.activate(options: [.activateAllWindows])
            if let wid = windowId {
                let element = try resolveElement(pid: processId, windowId: wid, path: [], deadline: deadline)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
            usleep(150_000)
        }
    }

    public func inspectWindow(pid: Int, maxDepth: Int?, maxNodes: Int?) async throws -> WindowSnapshot {
        try await bounded("inspectWindow") { deadline in
            try snapshotWindow(pid: pid, windowId: nil, maxDepth: maxDepth ?? 12, maxNodes: maxNodes ?? 400, deadline: deadline)
        }
    }

    public func pressElement(_ ref: ElementRef, action: String?) async throws {
        let action = action ?? "AXPress"
        try await withStaleCheck {
            try await bounded("pressElement") { deadline in
                guard let processId = processId(ref.pid) else { throw MerryError("application \(ref.pid) exposes no windows") }
                let element = try resolveElement(pid: processId, windowId: ref.windowId, path: ref.path, deadline: deadline)
                try validateStamp(element, ref.stamp)
                let available = axActions(element)
                guard available.contains(action) else {
                    throw MerryError("element does not support \(action); it supports [\(available.joined(separator: ", "))]")
                }
                let err = AXUIElementPerformAction(element, action as CFString)
                guard err == .success else { throw MerryError("action \(action) failed with AX error \(err.rawValue)") }
            }
        }
    }

    public func setElementValue(_ ref: ElementRef, value: String) async throws {
        let readBack: String = try await withStaleCheck {
            try await bounded("setElementValue") { deadline in
                guard let processId = processId(ref.pid) else { throw MerryError("application \(ref.pid) exposes no windows") }
                let element = try resolveElement(pid: processId, windowId: ref.windowId, path: ref.path, deadline: deadline)
                try validateStamp(element, ref.stamp)
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                guard settable.boolValue else { throw MerryError("element value is not settable") }
                let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
                guard err == .success else { throw MerryError("setting value failed with AX error \(err.rawValue)") }
                // Read back: AX writes can silently no-op in some apps.
                return axString(element, kAXValueAttribute as String) ?? ""
            }
        }
        if readBack != value {
            throw MerryError("value did not take effect: element now reads \"\(readBack)\"")
        }
    }

    public func click(_ point: ScreenPoint, button: String?, count: Int?) async throws {
        try await bounded("click", on: inputQueue) { _ in
            try postClick(x: point.x, y: point.y, button: button ?? "left", count: count ?? 1)
        }
    }

    public func typeText(_ text: String) async throws {
        // Long strings are slow to synthesise; the timeout scales with length.
        try await bounded("type", timeoutMs: max(12_000, text.jsLength * 40), on: inputQueue) { deadline in
            try postText(text, deadline: deadline)
        }
    }

    public func shortcut(_ keys: String) async throws {
        try await bounded("shortcut", on: inputQueue) { _ in try postShortcut(keys) }
    }

    public func scroll(_ point: ScreenPoint, dx: Double, dy: Double) async throws {
        try await bounded("scroll", on: inputQueue) { _ in
            try postScroll(x: point.x, y: point.y, dx: Int32(clamping: Int(dx)), dy: Int32(clamping: Int(dy)))
        }
    }

    public func captureWindow(pid: Int, windowId: String?) async throws -> CaptureResult {
        // Asking ScreenCaptureKit without the grant makes macOS prompt, and the
        // call then fails anyway. Say what is missing instead.
        guard CGPreflightScreenCaptureAccess() else {
            throw MerryError("capture failed: Screen Recording permission is not granted. Allow Merry in System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        let outputPath = Path.join(NSTemporaryDirectory(), "merry-capture-\(newId()).png")
        return try await boundedAsync(timeoutMs: 15_000, timeout: MerryError("capture timed out")) {
            try await captureWindowImage(pid: pid, windowId: windowId, outputPath: outputPath)
        }
    }

    public func listDisplays() async throws -> [DisplayInfo] {
        try await bounded("listDisplays") { _ in MacOsAdapter.displays() }
    }

    public func dispose() async {}

    /// Turns "element changed" failures into a typed re-observe signal.
    private func withStaleCheck<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let message = messageOf(error)
            if Rx("element changed|no longer (exists|resolves)|out of range", "i").test(message) {
                throw StaleElementError(message)
            }
            throw error
        }
    }

    // MARK: Pure pieces

    /// Displays in the SAME coordinate space everything else here uses: global
    /// points with the origin at the top-left of the primary display, y
    /// increasing downwards. That is what Accessibility frames and CGEvent
    /// mouse positions use, and what Core Graphics reports display bounds in,
    /// so nothing needs converting from AppKit's bottom-left origin.
    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let primary = CGMainDisplayID()
        return ids.prefix(Int(count))
            // A display mirroring another shows the same points; it is not a second screen.
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .sorted { a, _ in a == primary }
            .map { id in
                let bounds = CGDisplayBounds(id)
                var scale = 1.0
                if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                    scale = Double(mode.pixelWidth) / Double(mode.width)
                }
                return DisplayInfo(id: Int(id), bounds: frameOf(bounds), scaleFactor: scale, primary: id == primary)
            }
    }

    static func windowIndex(from windowId: String) -> Int {
        Int(windowId.replacingOccurrences(of: "w", with: "")) ?? 0
    }

    static func parseShortcut(_ spec: String) throws -> (key: CGKeyCode, flags: CGEventFlags) {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for rawPart in spec.lowercased().split(separator: "+") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default:
                guard let code = keyCodeMap[part] else {
                    throw MerryError("unknown key \"\(part)\" in shortcut \"\(spec)\"")
                }
                key = code
            }
        }
        guard let key = key else { throw MerryError("shortcut \"\(spec)\" names no key") }
        return (key, flags)
    }

    static func chunked(_ text: String, into size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if current.count >= size { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

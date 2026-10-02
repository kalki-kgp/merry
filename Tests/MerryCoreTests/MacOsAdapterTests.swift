import Testing
@testable import MerryCore

// The real adapter, run for real, but only where nothing is moved, pressed,
// typed or prompted for. Operations that need a grant are aimed at a process
// id nothing is running under, so they fail the same way whether or not the
// machine running the tests happens to have granted that permission.

/// The message a call fails with, and how long failing took.
private func failure(_ body: () async throws -> Void) async -> (message: String?, stale: Bool, ms: Double) {
    let start = MacProbe.uptimeMs
    var message: String?
    var stale = false
    do { try await body() } catch { message = messageOf(error); stale = error is StaleElementError }
    return (message, stale, MacProbe.uptimeMs - start)
}

private func deadRef(_ pid: Int) -> ElementRef {
    ElementRef(id: "w0:0", pid: pid, windowId: "w0", path: [0], stamp: ElementStamp(role: "AXButton", title: "OK", frame: Frame(x: 0, y: 0, width: 10, height: 10)))
}

@Test func macAdapterSupportsEveryCapability() {
    let os = MacOsAdapter()
    for capability in [Capability.appsList, .windowInspect, .windowFocus, .windowCapture, .elementAct, .inputSynthetic, .displayInfo] {
        #expect(os.supports(capability), "\(capability.rawValue)")
    }
}

@Test func macAdapterReportsPermissionsTruthfullyWithoutPrompting() async throws {
    let os = MacOsAdapter()
    let start = MacProbe.uptimeMs
    let permissions = try await os.getPermissions()
    #expect(MacProbe.uptimeMs - start < 5_000)
    #expect(permissions.map(\.permission) == [.accessibility, .screenRecording])
    #expect(permissions[0].granted == MacProbe.accessibilityTrusted)
    #expect(permissions[1].granted == MacProbe.screenCaptureAllowed)
    #expect(permissions[0].purpose == "Lets Merry read window contents and press buttons in apps, instead of guessing from pixels.")
    #expect(permissions[1].purpose == "Lets Merry take a picture of a specific window when an app exposes no readable controls.")
}

@Test func macAdapterListsRunningApps() async throws {
    let before = MacProbe.regularAppPids()
    let apps = try await MacOsAdapter().listApps()
    let after = MacProbe.regularAppPids()
    #expect(!apps.isEmpty)
    for app in apps {
        #expect(app.pid > 0, "\(app.name)")
        #expect(app.windowCount >= 0, "\(app.name)")
    }
    // Apps come and go while the suite runs; the ones there throughout must be listed.
    #expect(before.intersection(after).subtracting(apps.map(\.pid)).isEmpty)
    #expect(Set(apps.map(\.pid)).count == apps.count)
    #expect(apps.filter(\.active).count <= 1)
    if let finder = apps.first(where: { $0.bundleId == "com.apple.finder" }) {
        #expect(finder.pid == MacProbe.runningApp("com.apple.finder")?.pid)
    }
}

@Test func macAdapterListsDisplaysInTopLeftPoints() async throws {
    let displays = try await MacOsAdapter().listDisplays()
    let primary = try #require(displays.first, "no display attached")
    #expect(primary.primary)
    #expect(displays.filter(\.primary).count == 1)
    #expect(primary.bounds.x == 0 && primary.bounds.y == 0)
    #expect(primary.id == MacProbe.mainDisplayId)
    for d in displays {
        #expect(d.bounds.width >= 320 && d.bounds.height >= 200, "display \(d.id)")
        #expect(d.scaleFactor >= 1 && d.scaleFactor <= 4, "display \(d.id) scale \(d.scaleFactor)")
    }
    // Converting each NSScreen's bottom-left frame once, as the reference
    // helper did, gives exactly these displays.
    let screens = MacProbe.screens()
    #expect(displays.map(\.id) == screens.map(\.id))
    for screen in screens {
        guard let d = displays.first(where: { $0.id == screen.id }) else { continue }
        #expect(d.bounds == Frame(x: screen.x, y: screen.topLeftY, width: screen.width, height: screen.height), "display \(d.id)")
        #expect(d.scaleFactor == screen.scale, "display \(d.id)")
    }
}

@Test func accessibilityOperationsFailClearlyAndPromptly() async throws {
    let os = MacOsAdapter()
    let pid = MacProbe.unusedPid()

    let inspect = await failure { _ = try await os.inspectWindow(pid: pid, maxDepth: nil, maxNodes: nil) }
    #expect(inspect.message == "no running application with pid \(pid)")
    #expect(inspect.ms < 12_500)

    let focus = await failure { try await os.focusWindow(pid: pid, windowId: nil) }
    #expect(focus.message == "no application with that pid")

    let press = await failure { try await os.pressElement(deadRef(pid), action: nil) }
    #expect(press.message == "application \(pid) exposes no windows" || press.stale, "\(press.message ?? "did not fail")")
    #expect(press.ms < 12_500)

    let set = await failure { try await os.setElementValue(deadRef(pid), value: "x") }
    #expect(set.message == "application \(pid) exposes no windows" || set.stale, "\(set.message ?? "did not fail")")
    #expect(set.ms < 12_500)

    // The frontmost window is only read. Without the Accessibility grant that
    // must be a plain statement of what is missing, not a hang.
    let frontmost = await failure { _ = try await os.getFrontmostWindow() }
    #expect(frontmost.ms < 12_500)
    if !MacProbe.accessibilityTrusted, let message = frontmost.message {
        #expect(message.hasSuffix("has no accessible windows (is Accessibility permission granted?)"), "\(message)")
    }

    // Inspecting a real app without the grant says the same, by name.
    if !MacProbe.accessibilityTrusted, let finder = MacProbe.runningApp("com.apple.finder") {
        let real = await failure { _ = try await os.inspectWindow(pid: finder.pid, maxDepth: 3, maxNodes: 50) }
        #expect(real.message == "\(finder.name) has no accessible windows (is Accessibility permission granted?)")
        #expect(real.ms < 12_500)
    }
}

@Test func captureFailsClearlyAndPromptly() async {
    let pid = MacProbe.unusedPid()
    let capture = await failure { _ = try await MacOsAdapter().captureWindow(pid: pid, windowId: nil) }
    #expect(capture.ms < 15_500)
    if MacProbe.screenCaptureAllowed {
        #expect(capture.message == "no capturable on-screen window for pid \(pid)")
    } else {
        #expect(capture.message?.contains("Screen Recording permission is not granted") == true, "\(capture.message ?? "did not fail")")
    }
}

@Test func automationStatusIsReportedWithoutAsking() async throws {
    let os = MacOsAdapter()
    #expect(try await os.automationPermission(bundleId: "studio.merry.tests.no-such-app", ask: false) == .notInstalled)
    // An installed app that is not open is never launched just to check.
    if let closed = MacProbe.closedApp() {
        #expect(try await os.automationPermission(bundleId: closed, ask: false) == .notRunning)
        #expect(MacProbe.runningApp(closed) == nil)
    }
}

/// A shortcut is parsed before anything is posted, so a bad one fails without touching the keyboard.
@Test func badShortcutsAreRefusedBeforeAnyKeyIsSent() async {
    let os = MacOsAdapter()
    let unknown = await failure { try await os.shortcut("cmd+hyperdrive") }
    #expect(unknown.message == "unknown key \"hyperdrive\" in shortcut \"cmd+hyperdrive\"")
    let noKey = await failure { try await os.shortcut("Cmd+Shift") }
    #expect(noKey.message == "shortcut \"Cmd+Shift\" names no key")
}

@Test func shortcutsParseTheWayTheHelperParsedThem() throws {
    func parsed(_ spec: String) throws -> String {
        let s = try MacProbe.shortcut(spec)
        return (s.modifiers + ["\(s.key)"]).joined(separator: "+")
    }
    #expect(try parsed("cmd+s") == "cmd+1")
    #expect(try parsed("Cmd + Shift + N") == "cmd+shift+45")
    #expect(try parsed("control+option+command+fn+shift+f5") == "cmd+shift+alt+ctrl+fn+96")
    #expect(try parsed("meta+opt+alt+ctrl+function+esc") == "cmd+alt+ctrl+fn+53")
    #expect(try parsed("return") == "36")
    #expect(try parsed("enter") == "36")
    #expect(try parsed("alt+backspace") == "alt+51")
    #expect(try parsed("cmd+[") == "cmd+33")
    #expect(try parsed("shift+pagedown") == "shift+121")
    // The last key named wins, as it did in the helper.
    #expect(try parsed("a+b") == "11")
    #expect(throws: MerryError.self) { try MacProbe.shortcut("") }
    #expect(throws: MerryError.self) { try MacProbe.shortcut("cmd+") }
    #expect(throws: MerryError.self) { try MacProbe.shortcut("cmd+ß") }
}

@Test func textIsTypedInChunksOfSixteenCharacters() {
    #expect(MacOsAdapter.chunked("", into: 16) == [""])
    #expect(MacOsAdapter.chunked("short", into: 16) == ["short"])
    #expect(MacOsAdapter.chunked(String(repeating: "a", count: 16), into: 16) == [String(repeating: "a", count: 16)])
    let long = String(repeating: "ab", count: 20)
    let chunks = MacOsAdapter.chunked(long, into: 16)
    #expect(chunks.map(\.count) == [16, 16, 8] && chunks.joined() == long)
    // A grapheme is never split across two key events.
    #expect(MacOsAdapter.chunked(String(repeating: "👍🏽", count: 17), into: 16).map(\.count) == [16, 1])
}

@Test func windowIdsAreIndexes() {
    #expect(MacOsAdapter.windowIndex(from: "w0") == 0)
    #expect(MacOsAdapter.windowIndex(from: "w12") == 12)
    #expect(MacOsAdapter.windowIndex(from: "3") == 3)
    #expect(MacOsAdapter.windowIndex(from: "front") == 0)
}

/// A call that does not come back is abandoned at its timeout, with the bridge's wording.
@Test func aHungCallIsAbandonedAtItsTimeout() async {
    let hung = await failure {
        try await bounded("inspectWindow", timeoutMs: 150) { _ in MacProbe.sleep(ms: 1_500) }
    }
    #expect(hung.message == "macOS helper timed out after 150ms on \"inspectWindow\"")
    // The work sleeps 1.5s; coming back well before that is the point. The
    // margin allows for a busy machine running other suites alongside.
    #expect(hung.ms < 1_450)

    // Work that checks its deadline stops instead of running on unobserved.
    let stopped = await failure {
        try await bounded("walk", timeoutMs: 100) { deadline in
            for _ in 0..<200 { MacProbe.sleep(ms: 10); try deadline.check() }
        }
    }
    #expect(stopped.message == "macOS helper timed out after 100ms on \"walk\"")

    let value = try? await bounded("quick", timeoutMs: 2_000) { _ in 42 }
    #expect(value == 42)
}

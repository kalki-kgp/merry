import Foundation

/// Element references handed to the model are opaque strings. We keep the real
/// ElementRef here, keyed by task, and refuse to act on one that came from a
/// snapshot other than the most recent; that is what stops the assistant from
/// clicking where a button used to be.
private struct ElementCacheEntry {
    var ref: ElementRef
    var label: String
    var role: String
    var snapshotId: Int
    var observedAt: Double
}

private final class ElementCache: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [String: [String: ElementCacheEntry]] = [:]
    private var latestSnapshot: [String: Int] = [:]
    private var snapshotCounter = 0

    /// Starts a new snapshot for the task, dropping what the last one cached.
    func replace(_ taskId: String, observedAt: Double, with refs: [(ref: ElementRef, label: String, role: String)]) {
        lock.lock(); defer { lock.unlock() }
        snapshotCounter += 1
        latestSnapshot[taskId] = snapshotCounter
        var cache: [String: ElementCacheEntry] = [:]
        for r in refs {
            cache[r.ref.id] = ElementCacheEntry(ref: r.ref, label: r.label, role: r.role, snapshotId: snapshotCounter, observedAt: observedAt)
        }
        elements[taskId] = cache
    }

    func lookup(_ taskId: String, _ refId: String) -> (entry: ElementCacheEntry?, latest: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (elements[taskId]?[refId], latestSnapshot[taskId])
    }

    func clear(_ taskId: String) {
        lock.lock(); defer { lock.unlock() }
        elements[taskId] = nil
        latestSnapshot[taskId] = nil
    }
}

private let elementCache = ElementCache()

/// Observations older than this must be refreshed before they are acted on.
private let snapshotTtlMs: Double = 30_000

public func clearElementCache(_ taskId: String) {
    elementCache.clear(taskId)
}

/// Flattens the AX tree into the interactive elements a model can act on.
func flattenElements(_ elements: [UiElement]) -> [UiElement] {
    var out: [UiElement] = []
    func walk(_ list: [UiElement]) {
        for el in list {
            out.append(el)
            if let children = el.children { walk(children) }
        }
    }
    walk(elements)
    return out
}

private let actionable: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXIncrement", "AXDecrement", "AXShowMenu"]
private let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

/// `Math.round`: halves go towards positive infinity.

private func frameJSON(_ f: Frame) -> JSON {
    ["x": .number(f.x), "y": .number(f.y), "width": .number(f.width), "height": .number(f.height)]
}

private func appJSON(_ a: AppInfo) -> JSON {
    ["bundleId": .string(a.bundleId), "name": .string(a.name), "pid": JSON(a.pid), "active": .bool(a.active), "windowCount": JSON(a.windowCount)]
}

private func openAppJSON(_ a: AppInfo) -> JSON {
    ["name": .string(a.name), "pid": JSON(a.pid), "windows": JSON(a.windowCount)]
}

func summarizeSnapshot(_ snap: WindowSnapshot, taskId: String) -> JSON {
    let flat = flattenElements(snap.elements)
    let useful = flat.filter { el in
        el.actions.contains { actionable.contains($0) }
            || textRoles.contains(el.role)
            || (el.role == "AXStaticText" && !el.title.isEmpty)
    }
    let shown = useful.prefix(120)
    elementCache.replace(taskId, observedAt: snap.observedAt, with: shown.map { ($0.ref, $0.title, $0.role) })

    let items = shown.map { el -> JSON in
        .obj([
            "ref": .string(el.ref.id),
            "role": .string(el.role),
            "label": .string(el.title),
            "value": el.value.map(JSON.string),
            "enabled": .bool(el.enabled),
            "focused": .bool(el.focused),
            "actions": JSON(el.actions.filter { actionable.contains($0) }),
            // Centre point in global top-left-origin points, for click fallback.
            "center": [
                "x": .number(jsRound(el.frame.x + el.frame.width / 2)),
                "y": .number(jsRound(el.frame.y + el.frame.height / 2))
            ]
        ])
    }

    return [
        "app": appJSON(snap.app),
        "windowId": .string(snap.windowId),
        "title": .string(snap.title),
        "frame": frameJSON(snap.frame),
        "displayId": JSON(snap.displayId),
        "elementCount": JSON(flat.count),
        "truncated": .bool(useful.count > 120),
        "elements": .array(items)
    ]
}

private func resolveRef(_ ctx: ToolContext, _ refId: String) throws -> ElementRef {
    let found = elementCache.lookup(ctx.task().id, refId)
    guard let entry = found.entry else {
        throw StaleElementError("Unknown element \"\(refId)\". Call desktop_inspect_window again and use a reference from the new result.")
    }
    if entry.snapshotId != found.latest {
        throw StaleElementError("Element \"\(refId)\" came from an earlier look at the window. Re-inspect before acting.")
    }
    if nowMs() - entry.observedAt > snapshotTtlMs {
        throw StaleElementError("Element \"\(refId)\" was observed over 30s ago. Re-inspect before acting.")
    }
    return entry.ref
}

private let appScope: @Sendable (JSON) -> [ScopeRequest] = { i in [.app(name: i.str("appName"))] }

/// A number the way a JavaScript template literal prints it.
private func js(_ n: Double) -> String { JSON.number(n).stringify() }

public let desktopListApps = ToolDefinition(
    name: "desktop_list_apps",
    description: "List running applications with their process ids and window counts. A window count of 0 usually means Accessibility permission is missing.",
    capability: "desktop.observe",
    input: S.object(),
    execute: { _, ctx in
        let apps = try await ctx.os.listApps()
        _ = ctx.observe("window", "\(apps.count) running apps", .array(apps.map(openAppJSON)), 30_000)
        return ToolOutcome(.array(apps.map(appJSON)))
    }
)

public let desktopInspectWindow = ToolDefinition(
    name: "desktop_inspect_window",
    description: "Read the controls in an application window using macOS accessibility. Returns element references you can press or set. Prefer this over screenshots and clicking: it is far more reliable. Re-run it after anything that changes the window.",
    capability: "desktop.observe",
    input: S.object([
        "pid": S.number().int().optional().describe("Process id; omit to inspect the frontmost window"),
        "maxNodes": S.number().int().min(50).max(800).default(400)
    ]),
    execute: { i, ctx in
        let found: WindowSnapshot?
        if let pid = i.optInt("pid"), pid != 0 {
            found = try await ctx.os.inspectWindow(pid: pid, maxDepth: nil, maxNodes: i.int("maxNodes"))
        } else {
            found = try await ctx.os.getFrontmostWindow()
        }
        guard let snap = found else { throw MerryError("no frontmost window to inspect") }
        let summary = summarizeSnapshot(snap, taskId: ctx.task().id)
        let controls = summary.list("elements").count
        _ = ctx.observe(
            "window",
            "\(snap.app.name), \"\(snap.title)\" (\(controls) controls)",
            ["app": .string(snap.app.name), "title": .string(snap.title), "controls": JSON(controls)],
            snapshotTtlMs
        )
        return ToolOutcome(summary)
    }
)

public let desktopFocusWindow = ToolDefinition(
    name: "desktop_focus_window",
    description: "Bring an application to the front. Required before synthetic clicks or typing, which go to whatever is focused.",
    capability: "desktop.control",
    input: S.object([
        "pid": S.number().int(),
        "appName": S.string().describe("Used for the authorization check and the activity log"),
        "windowId": S.string().optional()
    ]),
    exclusiveDesktop: true,
    scopes: appScope,
    execute: { i, ctx in
        try await ctx.claimDesktop("focusing \(i.str("appName"))")
        try await ctx.os.focusWindow(pid: i.int("pid"), windowId: i.optStr("windowId"))
        return ToolOutcome(["pid": JSON(i.int("pid")), "focused": true])
    },
    verify: { i, _, ctx in
        let apps = try await ctx.os.listApps()
        let app = apps.first { $0.pid == i.int("pid") }
        let active = app?.active ?? false
        return VerificationResult(
            verified: active,
            method: "frontmost app check",
            detail: active ? "\(app?.name ?? "") is frontmost" : "\(i.str("appName")) did not come to the front"
        )
    }
)

public let desktopPressElement = ToolDefinition(
    name: "desktop_press_element",
    description: "Perform an accessibility action on an element from desktop_inspect_window. This is the reliable way to press a button or pick a menu item. Fails cleanly if the window changed, which means you should re-inspect rather than retry.",
    capability: "desktop.control",
    input: S.object([
        "ref": S.string().describe("An element reference from desktop_inspect_window"),
        "appName": S.string(),
        "action": S.string().default("AXPress").describe("One of the actions listed on the element")
    ]),
    exclusiveDesktop: true,
    scopes: appScope,
    execute: { i, ctx in
        try await ctx.claimDesktop("pressing a control in \(i.str("appName"))")
        let ref = try resolveRef(ctx, i.str("ref"))
        try await ctx.os.pressElement(ref, action: i.str("action"))
        return ToolOutcome(["ref": .string(i.str("ref")), "action": .string(i.str("action"))])
    }
)

public let desktopSetValue = ToolDefinition(
    name: "desktop_set_value",
    description: "Set the text of a field directly through accessibility, without typing. Faster and more reliable than synthetic keystrokes. Reads the value back and fails if it did not take.",
    capability: "desktop.control",
    input: S.object([
        "ref": S.string(),
        "appName": S.string(),
        "value": S.string()
    ]),
    exclusiveDesktop: true,
    scopes: appScope,
    execute: { i, ctx in
        try await ctx.claimDesktop("filling a field in \(i.str("appName"))")
        let ref = try resolveRef(ctx, i.str("ref"))
        try await ctx.os.setElementValue(ref, value: i.str("value"))
        return ToolOutcome(["ref": .string(i.str("ref")), "value": .string(i.str("value"))])
    }
)

public let desktopClick = ToolDefinition(
    name: "desktop_click",
    description: "Click at a screen point. This is the fallback for when an element exposes no accessibility action; prefer desktop_press_element. Coordinates are in points with the origin at the top-left of the primary display.",
    capability: "desktop.control",
    input: S.object([
        "x": S.number(),
        "y": S.number(),
        "appName": S.string(),
        "button": S.oneOf("left", "right").default("left"),
        "count": S.number().int().min(1).max(3).default(1),
        "reason": S.string().describe("Why a raw click is needed instead of an accessibility action")
    ]),
    exclusiveDesktop: true,
    scopes: appScope,
    precondition: { i, ctx in
        let x = i.num("x"), y = i.num("y")
        let displays = try await ctx.os.listDisplays()
        let onScreen = displays.contains { d in
            x >= d.bounds.x && x <= d.bounds.x + d.bounds.width && y >= d.bounds.y && y <= d.bounds.y + d.bounds.height
        }
        if !onScreen { throw MerryError("(\(js(x)), \(js(y))) is not on any display") }
    },
    execute: { i, ctx in
        let x = i.num("x"), y = i.num("y")
        try await ctx.claimDesktop("clicking in \(i.str("appName"))")
        ctx.log(.info, "raw click at (\(js(x)), \(js(y))): \(i.str("reason"))")
        try await ctx.os.click(ScreenPoint(x: x, y: y), button: i.str("button"), count: i.int("count"))
        return ToolOutcome(["x": .number(x), "y": .number(y)], uncertain: true)
    }
)

public let desktopType = ToolDefinition(
    name: "desktop_type",
    description: "Type text into whatever is focused. Focus a field first. Prefer desktop_set_value when the field is reachable through accessibility.",
    capability: "desktop.control",
    input: S.object(["text": S.string().min(1).max(5000), "appName": S.string()]),
    exclusiveDesktop: true,
    scopes: appScope,
    execute: { i, ctx in
        try await ctx.claimDesktop("typing in \(i.str("appName"))")
        try await ctx.os.typeText(i.str("text"))
        return ToolOutcome(["typed": JSON(i.str("text").jsLength)], uncertain: true)
    }
)

public let desktopShortcut = ToolDefinition(
    name: "desktop_shortcut",
    description: "Send a keyboard shortcut to the focused app, e.g. \"cmd+s\" or \"cmd+shift+n\".",
    capability: "desktop.control",
    input: S.object([
        "keys": S.string().describe("Modifiers plus one key, joined by \"+\", e.g. \"cmd+shift+n\""),
        "appName": S.string()
    ]),
    exclusiveDesktop: true,
    scopes: appScope,
    execute: { i, ctx in
        try await ctx.claimDesktop("sending \(i.str("keys")) to \(i.str("appName"))")
        try await ctx.os.shortcut(i.str("keys"))
        return ToolOutcome(["keys": .string(i.str("keys"))], uncertain: true)
    }
)

public let desktopScroll = ToolDefinition(
    name: "desktop_scroll",
    description: "Scroll at a screen point. Positive dy scrolls up, negative scrolls down.",
    capability: "desktop.control",
    input: S.object([
        "x": S.number(),
        "y": S.number(),
        "dx": S.number().int().default(0),
        "dy": S.number().int().default(-120),
        "appName": S.string()
    ]),
    exclusiveDesktop: true,
    scopes: appScope,
    execute: { i, ctx in
        try await ctx.claimDesktop("scrolling in \(i.str("appName"))")
        try await ctx.os.scroll(ScreenPoint(x: i.num("x"), y: i.num("y")), dx: i.num("dx"), dy: i.num("dy"))
        return ToolOutcome(["scrolled": true])
    }
)

public let desktopCaptureWindow = ToolDefinition(
    name: "desktop_capture_window",
    description: "Take a picture of one application window. Use only when accessibility gives you nothing usable: it costs more and reveals screen contents to the vision model. Never use it to watch continuously.",
    capability: "desktop.capture",
    input: S.object(["pid": S.number().int(), "appName": S.string()]),
    scopes: appScope,
    execute: { i, ctx in
        let shot = try await ctx.os.captureWindow(pid: i.int("pid"), windowId: nil)
        _ = ctx.observe(
            "screen",
            "Captured \(i.str("appName")) (\(shot.width)x\(shot.height) @\(js(shot.scaleFactor))x)",
            ["path": .string(shot.path), "scaleFactor": .number(shot.scaleFactor)],
            15_000
        )
        return ToolOutcome(["path": .string(shot.path), "width": JSON(shot.width), "height": JSON(shot.height), "scaleFactor": .number(shot.scaleFactor)])
    }
)

/// One call that answers "what am I looking at".
///
/// Composing this out of desktop_list_apps plus desktop_inspect_window cost a
/// round trip each and left the model deciding which window mattered. The
/// frontmost window is almost always the answer, so this returns it together
/// with what else is open, in one step.
public let screenLook = ToolDefinition(
    name: "screen_look",
    description: "Look at what is on screen right now: the window in front, the controls inside it, and what else is open. Start here whenever the user refers to what they are doing, looking at, or \"this\". Reads the accessibility tree, not pixels, so it is fast and exact.",
    capability: "desktop.observe",
    input: S.object([
        "controls": S.bool()
            .default(true)
            .describe("Include the controls of the frontmost window. Turn off for a bare list of what is open.")
    ]),
    execute: { i, ctx in
        async let listed = ctx.os.listApps()
        async let frontmost = ctx.os.getFrontmostWindow()
        let (apps, found) = try await (listed, frontmost)
        let others = apps.filter { $0.windowCount > 0 && $0.pid != found?.app.pid }.map(openAppJSON)

        guard let front = found else {
            _ = ctx.observe("screen", "Nothing is frontmost; \(others.count) apps have windows open", ["others": .array(others)], snapshotTtlMs)
            return ToolOutcome(["frontmost": .null, "alsoOpen": .array(others)])
        }

        // `.none`, not `nil`: a bare nil literal here would be JSON null.
        let summary: JSON? = i.flag("controls") ? summarizeSnapshot(front, taskId: ctx.task().id) : .none
        _ = ctx.observe(
            "screen",
            "In front: \(front.app.name), \"\(front.title)\"" + (summary.map { " (\($0.list("elements").count) controls)" } ?? ""),
            ["app": .string(front.app.name), "title": .string(front.title), "others": JSON(others.count)],
            snapshotTtlMs
        )
        return ToolOutcome([
            "frontmost": summary ?? [
                "app": .string(front.app.name),
                "pid": JSON(front.app.pid),
                "title": .string(front.title),
                "frame": frameJSON(front.frame)
            ],
            "alsoOpen": .array(others)
        ])
    }
)

/// What Merry may do in other apps: look at windows, bring one forward, and
/// press buttons or fill fields through accessibility actions, none of which
/// moves the pointer or presses a key.
public let desktopTools: [ToolDefinition] = [
    screenLook,
    desktopListApps,
    desktopInspectWindow,
    desktopFocusWindow,
    desktopPressElement,
    desktopSetValue,
    desktopCaptureWindow
]

/// Tools that move the person's real mouse or type on their real keyboard.
/// They are deliberately not registered anywhere: Merry never takes over the
/// cursor or the keyboard. They stay defined, and tested, so the guardrails
/// around them keep working if that decision is ever revisited.
public let syntheticInputTools: [ToolDefinition] = [desktopClick, desktopType, desktopShortcut, desktopScroll]

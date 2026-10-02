import Testing
@testable import MerryCore

private let allDesktopTools = Dictionary(uniqueKeysWithValues: (desktopTools + syntheticInputTools).map { ($0.name, $0) })

private func scopeJSON(_ scope: ScopeRequest) -> JSON {
    switch scope {
    case .read(let path): return ["kind": "read", "path": .string(path)]
    case .write(let path): return ["kind": "write", "path": .string(path)]
    case .app(let name): return ["kind": "app", "name": .string(name)]
    case .origin(let url): return ["kind": "origin", "url": .string(url)]
    case .capability(let name): return ["kind": "capability", "name": .string(name)]
    }
}

/// A scripted desktop of its own, with task ids no other test shares: the
/// element cache is process-wide and tests run side by side.
private struct Desk {
    let log = EventLog()
    let os: FakeOsAdapter
    let taskId = "desk-\(newId())"

    init() {
        let fixture = Fixture.load("desktop-tools")
        os = FakeOsAdapter(log: log, world: fixture["world"] ?? .null, snapshots: fixture["snapshots"] ?? .null)
    }

    func context(_ task: String? = nil, claim: (@Sendable (String) async throws -> Void)? = nil) -> ToolContext {
        fakeToolContext(taskId: task ?? taskId, os: os, log: log, claim: claim)
    }

    @discardableResult
    func run(_ name: String, _ input: JSON, task: String? = nil) async throws -> ToolOutcome {
        let tool = allDesktopTools[name]!
        return try await tool.execute(try tool.input.parse(input), context(task))
    }
}

private func staleMessage(_ body: () async throws -> Void) async -> String? {
    do { try await body() } catch let error as StaleElementError { return error.message } catch { return nil }
    return nil
}

/// Every scenario the reference was driven through must play out identically:
/// same results, same observations, same claims and adapter calls in the same
/// order, same error text.
@Test func desktopToolsBehaveLikeTheOriginal() async throws {
    let fixture = Fixture.load("desktop-tools")
    for (index, scenario) in fixture.list("scenarios").enumerated() {
        let log = EventLog()
        let os = FakeOsAdapter(log: log, world: fixture["world"] ?? .null, snapshots: fixture["snapshots"] ?? .null)
        let taskIds = { (name: String) in "parity-\(index)-\(name)" }
        for name in ["task-a", "task-b"] { clearElementCache(taskIds(name)) }

        for (number, step) in scenario.list("steps").enumerated() {
            if let patch = step["world"] { os.apply(patch); continue }
            if let cleared = step.optStr("clear") { clearElementCache(taskIds(cleared)); continue }
            let label = "\(scenario.str("name")) #\(number) \(step.str("tool")).\(step.str("fn"))"
            let tool = try #require(allDesktopTools[step.str("tool")], "\(label)")
            let ctx = fakeToolContext(taskId: taskIds(step.str("task")), os: os, log: log)
            let expected = step["outcome"] ?? .null
            log.reset()

            var got: JSON
            do {
                let input = try tool.input.parse(step["input"])
                switch step.str("fn") {
                case "scopes":
                    got = ["ok": true, "scopes": .array(tool.scopes(input).map(scopeJSON))]
                case "precondition":
                    try await tool.precondition!(input, ctx)
                    got = ["ok": true]
                case "verify":
                    got = ["ok": true, "verification": JSON.encode(try await tool.verify!(input, ToolOutcome(.null), ctx))]
                default:
                    let out = try await tool.execute(input, ctx)
                    got = ["ok": true, "result": out.result, "uncertain": .bool(out.uncertain), "undo": JSON(out.undo.count), "evidence": JSON(out.evidence.count)]
                }
            } catch {
                got = ["ok": false, "stale": .bool(error is StaleElementError), "message": .string(messageOf(error))]
            }

            let difference = got.firstDifference(from: expected)
            #expect(difference == nil, "\(label): \(difference ?? "")")
            #expect(log.events == step.strings("events"), "\(label) events")
            let seen = JSON.array(log.observations).firstDifference(from: step["observations"] ?? .null)
            #expect(seen == nil, "\(label) observations: \(seen ?? "")")
        }
    }
}

/// The result keeps the reference's key order: the planning model reads it as text.
@Test func desktopResultsAreSerialisedInTheOriginalOrder() async throws {
    let fixture = Fixture.load("desktop-tools")
    let desk = Desk()
    let look = fixture.list("scenarios")[0].list("steps")[1]
    #expect(try await desk.run("screen_look", [:]).result.stringify() == (look["outcome"]?["result"] ?? .null).stringify())
    let apps = fixture.list("scenarios")[2].list("steps").first { $0.str("tool") == "desktop_list_apps" && $0.str("fn") == "execute" }!
    #expect(try await desk.run("desktop_list_apps", [:]).result.stringify() == (apps["outcome"]?["result"] ?? .null).stringify())
}

@Test func syntheticInputToolsMatchTheOriginalAndStayUnregistered() {
    let golden = Fixture.load("desktop-tools").list("syntheticInputTools")
    #expect(syntheticInputTools.map(\.name) == golden.map { $0.str("name") })
    for (tool, expected) in zip(syntheticInputTools, golden) {
        #expect(tool.description == expected.str("description"), "\(tool.name) description")
        #expect(tool.capability == expected.str("capability"), "\(tool.name) capability")
        #expect(tool.exclusiveDesktop == expected.flag("exclusiveDesktop"), "\(tool.name) exclusiveDesktop")
        #expect((tool.verify != nil) == expected.flag("hasVerify"), "\(tool.name) verify")
        #expect((tool.precondition != nil) == expected.flag("hasPrecondition"), "\(tool.name) precondition")
        #expect((tool.confirm != nil) == expected.flag("hasConfirm"), "\(tool.name) confirm")
        let difference = tool.input.jsonSchema().firstDifference(from: expected["input_schema"] ?? .null)
        #expect(difference == nil, "\(tool.name) schema: \(difference ?? "")")
    }
    // Merry never moves the mouse or types: nothing offers these to the planner.
    let registered = Set(allTools().map(\.name))
    for tool in syntheticInputTools { #expect(!registered.contains(tool.name), "\(tool.name) must not be registered") }
    #expect(desktopTools.map(\.name) == Fixture.load("desktop-tools").strings("desktopTools"))
}

@Test func guiToolsClaimTheDesktopBeforeActing() async throws {
    let desk = Desk()
    try await desk.run("desktop_inspect_window", ["pid": 101])
    let calls: [(String, JSON)] = [
        ("desktop_focus_window", ["pid": 202, "appName": "Mail"]),
        ("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"]),
        ("desktop_set_value", ["ref": "w0:3", "appName": "Notes", "value": "bread"]),
        ("desktop_click", ["x": 10, "y": 10, "appName": "Notes", "reason": "test"]),
        ("desktop_type", ["text": "hi", "appName": "Notes"]),
        ("desktop_shortcut", ["keys": "cmd+s", "appName": "Notes"]),
        ("desktop_scroll", ["x": 10, "y": 10, "appName": "Notes"])
    ]
    for (name, input) in calls {
        #expect(allDesktopTools[name]!.exclusiveDesktop, "\(name) drives the real desktop")
        desk.log.reset()
        try await desk.run(name, input)
        let events = desk.log.events
        #expect(events.first?.hasPrefix("claim ") == true, "\(name) claims first: \(events)")
        #expect(events.filter { $0.hasPrefix("call ") }.count == 1, "\(name) acts once: \(events)")

        // A claim that is refused stops the tool before anything is touched.
        desk.log.reset()
        let tool = allDesktopTools[name]!
        let refused = desk.context(claim: { _ in throw MerryError("the desktop is in use") })
        await #expect(throws: MerryError.self) { try await tool.execute(try tool.input.parse(input), refused) }
        #expect(!desk.log.events.contains { $0.hasPrefix("call ") }, "\(name) acted without the desktop: \(desk.log.events)")
    }
    // Looking never needs the desktop to itself.
    for name in ["screen_look", "desktop_list_apps", "desktop_inspect_window", "desktop_capture_window"] {
        #expect(!allDesktopTools[name]!.exclusiveDesktop, "\(name)")
    }
    desk.log.reset()
    try await desk.run("screen_look", [:])
    try await desk.run("desktop_capture_window", ["pid": 101, "appName": "Notes"])
    #expect(!desk.log.events.contains { $0.hasPrefix("claim ") })
}

@Test func inspectReturnsReferencesThatPressAndSetValueAccept() async throws {
    let desk = Desk()
    let summary = try await desk.run("desktop_inspect_window", ["pid": 101]).result
    let elements = summary.list("elements")
    let button = try #require(elements.first { $0.str("label") == "New Note" })
    let field = try #require(elements.first { $0.str("role") == "AXTextArea" })
    #expect(button.strings("actions") == ["AXPress"])

    let pressed = try await desk.run("desktop_press_element", ["ref": button["ref"]!, "appName": "Notes"])
    #expect(pressed.result == ["ref": "w0:0.0", "action": "AXPress"])
    let set = try await desk.run("desktop_set_value", ["ref": field["ref"]!, "appName": "Notes", "value": "bread"])
    #expect(set.result == ["ref": "w0:3", "value": "bread"])

    // The adapter is handed the full reference the observation recorded, stamp and all.
    let refs = desk.log.refs
    #expect(refs.count == 2)
    #expect(refs[0] == ElementRef(id: "w0:0.0", pid: 101, windowId: "w0", path: [0, 0],
                                  stamp: ElementStamp(role: "AXButton", title: "New Note", frame: Frame(x: 700.5, y: 30.5, width: 31, height: 21))))
    #expect(refs[1].path == [3] && refs[1].stamp.role == "AXTextArea")

    // screen_look hands out references the same way.
    let looked = try await desk.run("screen_look", [:]).result
    let ref = try #require(looked["frontmost"]?.list("elements").first?["ref"])
    try await desk.run("desktop_press_element", ["ref": ref, "appName": "Notes"])
}

@Test func staleReferencesAskForAnotherLook() async throws {
    let desk = Desk()
    // Never observed.
    #expect(await staleMessage { try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"]) }
        == "Unknown element \"w0:0.0\". Call desktop_inspect_window again and use a reference from the new result.")

    // Observed, then the window was looked at again: the old reference is gone.
    try await desk.run("desktop_inspect_window", ["pid": 101])
    try await desk.run("desktop_inspect_window", ["pid": 202])
    #expect(await staleMessage { try await desk.run("desktop_set_value", ["ref": "w0:3", "appName": "Notes", "value": "x"]) }?.contains("desktop_inspect_window again") == true)

    // Observed too long ago.
    desk.os.apply(["ages": ["notes": 30_500]])
    try await desk.run("desktop_inspect_window", ["pid": 101])
    #expect(await staleMessage { try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"]) }
        == "Element \"w0:0.0\" was observed over 30s ago. Re-inspect before acting.")
    #expect(!desk.log.events.contains { $0.hasPrefix("call pressElement") || $0.hasPrefix("call setElementValue") })

    // The adapter finding the element changed is the same signal.
    desk.os.apply(["ages": [:], "pressError": ["stale": true, "message": "element changed: expected role AXButton, found AXGroup"]])
    try await desk.run("desktop_inspect_window", ["pid": 101])
    #expect(await staleMessage { try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"]) }
        == "element changed: expected role AXButton, found AXGroup")
}

@Test func elementCacheIsKeptAndClearedPerTask() async throws {
    let desk = Desk()
    let other = "desk-\(newId())"
    try await desk.run("desktop_inspect_window", ["pid": 101])
    try await desk.run("desktop_inspect_window", ["pid": 101], task: other)

    // One task's references mean nothing to a task that never observed them.
    let stranger = "desk-\(newId())"
    #expect(await staleMessage { try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"], task: stranger) } != nil)

    // A later look by another task does not invalidate this one's.
    try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"])

    clearElementCache(desk.taskId)
    #expect(await staleMessage { try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"]) }?.hasPrefix("Unknown element") == true)
    try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"], task: other)
    clearElementCache(other)
    #expect(await staleMessage { try await desk.run("desktop_press_element", ["ref": "w0:0.0", "appName": "Notes"], task: other) } != nil)
}

@Test func aClickOutsideEveryDisplayIsRejected() async throws {
    let desk = Desk()
    let click = allDesktopTools["desktop_click"]!
    let precondition = try #require(click.precondition)
    func check(_ x: Double, _ y: Double) async throws {
        try await precondition(try click.input.parse(["x": .number(x), "y": .number(y), "appName": "Notes", "reason": "test"]), desk.context())
    }
    try await check(100, 100)
    try await check(-1000, 0)
    do {
        try await check(5000, 5000)
        Issue.record("a click off every display must be refused")
    } catch {
        #expect(messageOf(error) == "(5000, 5000) is not on any display")
    }
    await #expect(throws: MerryError.self) { try await check(100, -200) }
    #expect(desk.log.events.isEmpty, "a precondition changes nothing")
}

@Test func appScopesAreWhatTheOriginalRequests() throws {
    let observing: [(String, JSON)] = [
        ("screen_look", [:]), ("desktop_list_apps", [:]), ("desktop_inspect_window", ["pid": 5])
    ]
    for (name, input) in observing {
        let tool = allDesktopTools[name]!
        #expect(tool.scopes(try tool.input.parse(input)) == [], "\(name)")
    }
    let acting: [(String, JSON)] = [
        ("desktop_focus_window", ["pid": 5, "appName": "Notes"]),
        ("desktop_press_element", ["ref": "r", "appName": "Notes"]),
        ("desktop_set_value", ["ref": "r", "appName": "Notes", "value": "v"]),
        ("desktop_capture_window", ["pid": 5, "appName": "Notes"]),
        ("desktop_click", ["x": 1, "y": 1, "appName": "Notes", "reason": "r"]),
        ("desktop_type", ["text": "t", "appName": "Notes"]),
        ("desktop_shortcut", ["keys": "cmd+s", "appName": "Notes"]),
        ("desktop_scroll", ["x": 1, "y": 1, "appName": "Notes"])
    ]
    for (name, input) in acting {
        let tool = allDesktopTools[name]!
        let scopes = tool.scopes(try tool.input.parse(input))
        #expect(scopes == [.app(name: "Notes")], "\(name)")
        // The grant is by app, and is what the authorization check compares against.
        #expect(checkScopes(Authorization(apps: ["notes"]), scopes).allowed, "\(name)")
        #expect(checkScopes(Authorization(apps: ["Mail"]), scopes).missing == [.app(name: "Notes")], "\(name)")
    }
}

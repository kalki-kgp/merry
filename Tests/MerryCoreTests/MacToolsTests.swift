import Testing
@testable import MerryCore

// MARK: - Source text that must be identical

@Test func jxaScriptsAreByteForByteTheOriginals() {
    let rows = Fixture.load("mac-scripts").list("scripts")
    #expect(rows.count == SCRIPTS.all.count)
    #expect(rows.map { $0.str("name") } == SCRIPTS.all.map(\.name), "scripts are declared in a different order")
    for (row, script) in zip(rows, SCRIPTS.all) {
        #expect(Array(script.body.utf8) == Array(row.str("body").utf8), "\(script.name) differs from the reference")
    }
    #expect(Set(SCRIPTS.all.map(\.body)).count == SCRIPTS.all.count)
}

@Test func pageProgramsAreByteForByteTheOriginals() {
    let programs = Fixture.load("mac-scripts")["pagePrograms"]!
    #expect(programs.objectValue?.count == PagePrograms.all.count)
    for program in PagePrograms.all {
        #expect(Array(program.body.utf8) == Array(programs.str(program.name).utf8), "\(program.name) differs from the reference")
    }
}

// MARK: - Pure helpers

@Test func noteHtmlMatchesTheOriginal() {
    for row in Fixture.load("mac-scripts").list("notes") {
        #expect(noteHtml(row.str("title"), row.str("body")) == row.str("html"), "\(row.str("title")) / \(row.str("body"))")
    }
}

@Test func consequentialLabelsMatchTheOriginal() {
    for row in Fixture.load("mac-scripts").list("labels") {
        #expect(isConsequential(row.str("label")) == row.flag("consequential"), "\(row.str("label"))")
    }
}

@Test func datesAreReadTheSameWay() {
    LocalTime.use(timeZone: "Asia/Kolkata")
    for row in Fixture.load("mac-scripts").list("dates") {
        let text = row.str("text")
        if let iso = row.optStr("iso") {
            #expect(macDate(text)?.toISOString() == iso, "\(text)")
        } else {
            #expect(macDate(text) == nil, "\(text) should not be a date")
        }
    }
}

@Test func familiesAndOrderMatchTheOriginal() {
    let fixture = Fixture.load("mac-scripts")
    #expect(macTools.map(\.name) == fixture.strings("macTools"))
    #expect(yourBrowserTools.map(\.name) == fixture.strings("yourBrowserTools"))
    let families = fixture["families"]!
    #expect(Set(MAC_FAMILIES.keys) == Set(families.objectValue?.keys ?? []))
    for (name, tools) in MAC_FAMILIES { #expect(tools == families.strings(name), "\(name)") }
}

@Test func screenContextKeepsMissingAndNullApart() {
    var context = ScreenContext(app: nil)
    #expect(context.json.stringify() == #"{"app":null}"#)
    context.tab = .null
    context.selection = "words"
    #expect(context.json.firstDifference(from: ["app": nil, "selection": "words", "tab": nil]) == nil)
    #expect(ScreenContext(json: context.json) == context)
}

// MARK: - Behaviour through a fake bridge

@Suite(.serialized) struct MacBehaviour {
    @Test func toolsBehaveAsTheOriginalDoes() async {
        LocalTime.use(timeZone: "Asia/Kolkata")
        let previous = macBridge()
        let realSleep = YourBrowserClock.sleep, realNow = YourBrowserClock.now
        defer { setMacBridge(previous); YourBrowserClock.sleep = realSleep; YourBrowserClock.now = realNow }
        let tools = Dictionary(uniqueKeysWithValues: (macTools + yourBrowserTools).map { ($0.name, $0) })

        let cases = Fixture.load("mac-behaviour").list("cases")
        #expect(cases.count > 150)
        for c in cases {
            let name = c.str("name")
            let bridge = FakeMacBridge(jxa: c["jxa"] ?? [:], exec: c["exec"] ?? [:])
            setMacBridge(bridge)
            let recorder = MacRecorder(answers: c.list("answers"))
            YourBrowserClock.sleep = { ms in recorder.slept(ms) }
            YourBrowserClock.now = { recorder.now }

            let state = TaskState(request: name, authorization: Authorization(origins: c.strings("origins")))
            let ctx = ToolContext(
                task: { state },
                os: UnavailableOsAdapter(),
                browser: NoBrowser(),
                progress: { line in recorder.add(["t": "progress", "line": .string(line)]) },
                observe: { kind, summary, data, stale in
                    recorder.add(["t": "observe", "kind": .string(kind), "summary": .string(summary), "data": data, "staleAfterMs": .number(stale)])
                    return Observation(id: newId(), kind: kind, summary: summary, data: data, observedAt: nowMs(), staleAfterMs: stale)
                },
                ask: { q in
                    recorder.add(.obj([
                        "t": "ask", "reason": .string(q.reason.rawValue), "prompt": .string(q.prompt), "allowFreeText": .bool(q.allowFreeText),
                        "options": q.options.map { .array($0.map { ["id": .string($0.id), "label": .string($0.label)] }) }
                    ]))
                    return UserAnswer(optionId: recorder.nextAnswer())
                },
                claimDesktop: { reason in recorder.add(["t": "claim", "reason": .string(reason)]) }
            )

            var got = JSONObject()
            switch c.str("kind") {
            case "tool":
                guard let tool = tools[c.str("tool")] else { Issue.record("\(name): no tool \(c.str("tool"))"); continue }
                guard let i = try? tool.input.parse(c["input"]) else {
                    #expect(c.flag("parseError"), "\(name): input should have been accepted")
                    continue
                }
                #expect(!c.flag("parseError"), "\(name): input should have been refused")
                got["parsed"] = i
                got["scopes"] = .array(tool.scopes(i).map(macScopeJSON))
                got["confirm"] = JSON(tool.confirm?(i))
                var ready = true
                if let precondition = tool.precondition {
                    do { try await precondition(i, ctx); got["precondition"] = ["ok": true] } catch { got["precondition"] = ["error": .string(messageOf(error))]; ready = false }
                }
                if ready {
                    do {
                        let outcome = try await tool.execute(i, ctx)
                        got["outcome"] = macOutcomeJSON(outcome)
                        if let verify = tool.verify {
                            do { got["verification"] = macVerificationJSON(try await verify(i, outcome, ctx)) } catch { got["verification"] = ["error": .string(messageOf(error))] }
                        }
                    } catch {
                        got["outcome"] = ["error": .string(messageOf(error))]
                    }
                }
            case "reverse":
                let args = c["args"]!
                let r = await reverseMacChange(MacUndoKind(rawValue: args.str("kind"))!, UndoEntry.Payload(from: args.str("from"), to: args.str("to")))
                got["result"] = .obj(["ok": .bool(r.ok), "reason": r.reason.map(JSON.string)])
            case "gather":
                let args = c["args"]!, want = args["want"] ?? [:]
                let context = await gatherContext(args.optStr("app"), ContextWant(selection: want.flag("selection"), clipboard: want.flag("clipboard"), finder: want.flag("finder"), tab: want.flag("tab")))
                got["result"] = context.json
            case "page":
                do { got["result"] = try await readOpenPage(c["args"]!.optStr("prefer"))?.json ?? .null } catch { got["result"] = ["error": .string(messageOf(error))] }
            case "choose":
                got["result"] = .string(await chooseBrowser(c["args"]!.optStr("prefer")))
            case "resolve":
                got["result"] = JSON(await resolveAppName(c["args"]!.str("name")))
            default:
                do { got["result"] = JSON(try await listShortcuts()) } catch { got["result"] = ["error": .string(messageOf(error))] }
            }

            for key in ["parsed", "scopes", "confirm", "precondition", "outcome", "verification", "result"] {
                let expected = c[key], actual = got[key]
                if expected == nil && actual == nil { continue }
                guard let expected, let actual else { Issue.record("\(name): \(key) is \(actual?.stringify() ?? "absent"), expected \(expected?.stringify() ?? "absent")"); continue }
                let difference = actual.firstDifference(from: expected)
                #expect(difference == nil, "\(name) \(key): \(difference ?? "")")
            }

            var calls = bridge.calls, wanted = c.list("calls")
            if c.flag("unordered") {
                calls.sort { $0.stringify() < $1.stringify() }
                wanted.sort { $0.stringify() < $1.stringify() }
            }
            let callDifference = JSON.array(calls).firstDifference(from: .array(wanted))
            #expect(callDifference == nil, "\(name) bridge calls: \(callDifference ?? "")")
            #expect(calls.map { $0.str("input") } == wanted.map { $0.str("input") }, "\(name): script input text")

            let eventDifference = JSON.array(recorder.events).firstDifference(from: .array(c.list("events")))
            #expect(eventDifference == nil, "\(name) events: \(eventDifference ?? "")")

            #expect(state.authorization.origins + YourBrowserSites.origins(for: state.id) == c.strings("originsAfter"), "\(name): allowed sites")
            YourBrowserSites.forget(taskId: state.id)
            #expect(bridge.leftoverFolders.isEmpty, "\(name): scratch folder left behind")
        }
    }

    @Test func anAllowedSiteIsNotAskedAboutTwice() async throws {
        let previous = macBridge()
        defer { setMacBridge(previous) }
        let status: JSON = ["ok": ["browser": "Safari", "result": ["ready": "complete", "url": "https://www.example.com/a", "title": "A"]]]
        let scrolled: JSON = ["ok": ["browser": "Safari", "result": ["scrolled": 0]]]
        setMacBridge(FakeMacBridge(jxa: ["pageRun": [status, scrolled, status, scrolled]], exec: [:]))
        let realSleep = YourBrowserClock.sleep
        YourBrowserClock.sleep = { _ in }
        defer { YourBrowserClock.sleep = realSleep }
        let recorder = MacRecorder(answers: ["allow"])
        let state = TaskState(request: "scroll")
        let ctx = ToolContext(task: { state }, os: UnavailableOsAdapter(), browser: NoBrowser(), ask: { _ in
            recorder.add(["t": "ask"])
            return UserAnswer(optionId: recorder.nextAnswer())
        })
        let input = try yourBrowserScroll.input.parse(["browser": "Safari"])
        _ = try await yourBrowserScroll.execute(input, ctx)
        _ = try await yourBrowserScroll.execute(input, ctx)
        #expect(recorder.events.count == 1)
        #expect(YourBrowserSites.origins(for: state.id) == ["https://www.example.com"])
        YourBrowserSites.forget(taskId: state.id)
        #expect(YourBrowserSites.origins(for: state.id).isEmpty)
    }

    @Test func undoEntriesReverseThroughTheirKind() async {
        let previous = macBridge()
        defer { setMacBridge(previous) }
        let bridge = FakeMacBridge(jxa: ["deleteNote": [["ok": ["deleted": true]]]], exec: [:])
        setMacBridge(bridge)
        #expect(await reverseMacChange(UndoEntry(kind: .macNote, from: "Notes", to: "N1")) == MacUndoResult(ok: true))
        #expect(await reverseMacChange(UndoEntry(kind: .fileMove, from: "/a", to: "/b")).ok == false)
        #expect(bridge.calls.count == 1)
    }

    /// Mail can open a draft and nothing else: no script anywhere sends.
    @Test func nothingSends() {
        for script in SCRIPTS.all {
            #expect(!Rx("\\.send\\s*\\(|\\bsend\\b", "i").test(script.body), "\(script.name) must not send")
        }
        #expect(SCRIPTS.mailDraft.contains("visible: true"))
    }

    /// The real bridge, with scripts that touch no app.
    @Test func osascriptRunsAScriptAndReportsAFailure() async throws {
        let bridge = OsascriptBridge()
        #expect(try await bridge.jxa("return input.a + 1", ["a": 1]) == 2)
        #expect(try await bridge.jxa("return { text: input.words.join(' '), nothing: undefined }", ["words": ["a", "b"]]) == ["text": "a b"])
        #expect(try await bridge.jxa("return undefined", [:]) == .null)
        do {
            _ = try await bridge.jxa("throw new Error('deliberate failure')", [:])
            Issue.record("a failing script should throw")
        } catch let error as ScriptError {
            #expect(error.message.contains("deliberate failure"))
        }
    }
}

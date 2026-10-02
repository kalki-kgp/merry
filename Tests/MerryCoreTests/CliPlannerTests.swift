import Testing
@testable import MerryCore

/// The coding-app planners against what the reference builds, sends and reads,
/// with stand-in executables in place of every CLI.
@Suite(.serialized) struct CliPlannerTests {
    let fixture = Fixture.load("cli-planners")

    private func task(_ request: String = "Do the thing.") -> TaskState { TaskState(request: request) }
    private func reply(_ text: String, input: Int = 3, output: Int = 2) -> String {
        resultEnvelope(["result": .string(text), "inputTokens": JSON(input), "outputTokens": JSON(output)])
    }

    // MARK: Parity

    @Test func promptsAreIdentical() async {
        #expect(fixture.list("prompts").count == 4)
        for row in fixture.list("prompts") {
            let problems = await replayPrompts(row, fixture: fixture)
            #expect(problems.isEmpty, "\(problems.prefix(4).joined(separator: "\n"))")
        }
    }

    @Test func claudeCodeOneCallPerStep() async {
        for row in fixture.list("claudeRuns") {
            let problems = await replayClaudeRun(row, fixture: fixture)
            #expect(problems.isEmpty, "\(problems.prefix(4).joined(separator: "\n"))")
        }
    }

    @Test func claudeCodeStreamSession() async {
        #expect(fixture.list("claudeStreams").count == 3)
        for row in fixture.list("claudeStreams") {
            let problems = await replayClaudeStream(row, fixture: fixture)
            #expect(problems.isEmpty, "\(problems.prefix(4).joined(separator: "\n"))")
        }
    }

    @Test func codexAndOpenCodeOneCallPerStep() async {
        #expect(fixture.list("oneShot").count == 4)
        for row in fixture.list("oneShot") {
            let problems = await replayOneShot(row, fixture: fixture)
            #expect(problems.isEmpty, "\(problems.prefix(4).joined(separator: "\n"))")
        }
    }

    @Test func labelsMatch() {
        for app in CodingApp.allCases { #expect(CODING_APP_LABELS[app] == fixture["labels"]!.str(app.rawValue)) }
    }

    @Test func catalogListingsMatch() {
        #expect(fixture.list("catalogs").count == 25)
        for row in fixture.list("catalogs") {
            let name = "\(row.str("kind")) \(row.str("name"))"
            let run = simulateListing(row)
            let difference = JSON.array(run.requests).firstDifference(from: row["requests"]!)
            #expect(difference == nil, "\(name) requests: \(difference ?? "")")
            if let wanted = row["catalog"] {
                guard let catalog = run.catalog else { Issue.record("\(name): \(run.error ?? "no catalog")"); continue }
                let d = encodedJSON(catalog).firstDifference(from: wanted)
                #expect(d == nil, "\(name): \(d ?? "")")
                #expect(catalog.models.map(\.id) == wanted.list("models").map { $0.str("id") }, "\(name) order")
            } else {
                #expect(run.error == row.str("error"), "\(name)")
            }
            if row.str("kind") == "claude" { #expect(claudeDiscoveryArgs == row.strings("args"), "\(name) args") }
        }
    }

    @Test func codexCatalogThroughAStandIn() async {
        for row in fixture.list("catalogs") where row.str("kind") == "codex" {
            let standIn = codexRpcStandIn(row)
            let name = "codex \(row.str("name"))"
            do {
                let catalog = try await discoverCodexCatalog(standIn.bin, standIn.dir, timeoutMs: 5000)
                let d = encodedJSON(catalog).firstDifference(from: row["catalog"] ?? .null)
                #expect(d == nil, "\(name): \(d ?? "")")
            } catch {
                #expect(messageOf(error) == row.optStr("error"), "\(name)")
            }
            #expect(standIn.args("args") == row.strings("args"), "\(name) args")
            let asked = (standIn.read("requests") ?? "").split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
            let d = JSON.array(asked).firstDifference(from: row["requests"]!)
            #expect(d == nil, "\(name) requests: \(d ?? "")")
        }
    }

    @Test func claudeCatalogThroughAStandIn() async {
        for row in fixture.list("catalogs") where row.str("kind") == "claude" && row["env"]!.objectValue!.isEmpty {
            let standIn = StandIn.oneShot()
            armOneShot(standIn, replies: [], rpc: row["rpc"])
            let name = "claude \(row.str("name"))"
            do {
                let catalog = try await withEnvironment(["CLAUDE_CODE_USE_BEDROCK": nil, "CLAUDE_CODE_USE_VERTEX": nil, "CLAUDE_CODE_USE_FOUNDRY": nil]) {
                    try await discoverClaudeModels(standIn.bin, standIn.dir, timeoutMs: 5000)
                }
                let d = encodedJSON(catalog).firstDifference(from: row["catalog"] ?? .null)
                #expect(d == nil, "\(name): \(d ?? "")")
            } catch {
                #expect(messageOf(error) == row.optStr("error"), "\(name)")
            }
        }
    }

    @Test func modelChecksThroughStandIns() async {
        #expect(fixture.list("checks").count == 16)
        for (i, row) in fixture.list("checks").enumerated() {
            let standIn = StandIn.oneShot()
            armOneShot(standIn, replies: row.list("replies"), rpc: row["rpc"])
            let app = CodingApp(rawValue: row.str("app"))!
            let check = await withEnvironment(["MERRY_CLAUDE_BIN": standIn.bin, "MERRY_CODEX_BIN": standIn.bin, "MERRY_OPENCODE_BIN": standIn.bin]) {
                await checkCodingModel(app, row.str("model"))
            }
            let d = encodedJSON(check).firstDifference(from: row["check"]!)
            #expect(d == nil, "check \(i) \(row.str("app")) \(row.str("model")): \(d ?? "")")
            var calls: [JSON] = []
            for n in 0..<standIn.count(suffix: ".args") {
                let args = (standIn.args("\(n).args") ?? []).map { Rx("^.*merry-model-check-[^/]*").replaceFirst($0, "<dir>") }
                calls.append(["args": JSON(args), "stdin": JSON(standIn.read("\(n).stdin") ?? ""), "config": JSON(standIn.read("\(n).config"))])
            }
            let c = JSON.array(calls).firstDifference(from: row["calls"]!)
            #expect(c == nil, "check \(i) calls: \(c ?? "")")
        }
    }

    // MARK: The persistent session

    @Test func restartsAndReplaysWhenTheProcessStops() async throws {
        let standIn = StandIn.stream()
        standIn.write("0.reply", reply("{\"text\":\"one\"}"))
        standIn.write("0.mode", "exit-after")
        standIn.write("1.reply", reply("{\"text\":\"two\"}"))
        standIn.write("2.reply", reply("{\"text\":\"three\"}"))
        let planner = ClaudeCodePlanner(ClaudeCodeOptions(bin: standIn.bin, model: "sonnet", timeoutMs: 10_000))
        defer { planner.dispose() }
        planner.seed(task: task("First request."), droppedPaths: [])
        #expect(try await planner.propose(tools: []).text == "one")
        // The stand-in has exited; the planner must notice, start another, and catch it up.
        _ = await eventually { !planner.holdsConversation() }
        planner.addNote("second step")
        #expect(try await planner.propose(tools: []).text == "two")
        planner.addNote("third step")
        #expect(try await planner.propose(tools: []).text == "three")

        #expect(standIn.count(suffix: ".launch") == 2)
        #expect(standIn.read("served") == "0\n1\n1\n")
        let lines = (standIn.read("lines") ?? "").split(separator: "\n").map { (try? JSON.parse(String($0)))?["message"]?.str("content") ?? "" }
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("<user_request>\nFirst request.\n</user_request>"))
        #expect(lines[1].hasPrefix("This task is already under way. Here is the conversation so far, as context rather than a new request:\n<earlier>\n<merry>\n<user_request>\nFirst request."))
        #expect(lines[1].contains("<you>\n{\"text\":\"one\"}\n</you>\n</earlier>\n\nThe next message:\n\n<system_note>second step</system_note>"))
        // The new process holds the conversation, so the third message is sent bare.
        #expect(lines[2].hasPrefix("<system_note>third step</system_note>"))
    }

    @Test func aProcessThatFailsReportsWhatItSaid() async {
        let standIn = StandIn.stream()
        standIn.write("0.reply", "unused")
        standIn.write("0.mode", "die")
        let planner = ClaudeCodePlanner(ClaudeCodeOptions(bin: standIn.bin, timeoutMs: 10_000))
        defer { planner.dispose() }
        planner.seed(task: task(), droppedPaths: [])
        do { _ = try await planner.propose(tools: []); Issue.record("should have failed") } catch {
            #expect(messageOf(error) == "fatal: model overloaded")
        }
    }

    @Test func aSilentProcessTimesOutAndIsKilled() async {
        let standIn = StandIn.stream()
        let planner = ClaudeCodePlanner(ClaudeCodeOptions(bin: standIn.bin, timeoutMs: 1500))
        planner.seed(task: task(), droppedPaths: [])
        do { _ = try await planner.propose(tools: []); Issue.record("should have timed out") } catch {
            #expect(messageOf(error) == "Claude Code took longer than 2s to answer")
        }
        let pid = Int32((standIn.read("0.pid") ?? "").jsTrimmed) ?? 0
        #expect(pid > 0)
        #expect(await eventually { !processIsAlive(pid) })
        #expect(!planner.holdsConversation())
    }

    @Test func anErrorEnvelopeIsThrown() async {
        let standIn = StandIn.stream()
        standIn.write("0.reply", "{\"type\":\"result\",\"is_error\":true,\"result\":\"Credit balance is too low\"}")
        standIn.write("1.reply", "{\"type\":\"result\",\"is_error\":true}")
        let planner = ClaudeCodePlanner(ClaudeCodeOptions(bin: standIn.bin, timeoutMs: 10_000))
        defer { planner.dispose() }
        planner.seed(task: task(), droppedPaths: [])
        for wanted in ["Credit balance is too low", "Claude Code reported an error"] {
            do { _ = try await planner.propose(tools: []); Issue.record("should have failed") } catch { #expect(messageOf(error) == wanted) }
        }
        #expect(standIn.count(suffix: ".launch") == 1)
    }

    @Test func tiersKeepTheChosenModelAndTheSameProcess() async throws {
        let standIn = StandIn.stream()
        standIn.write("0.reply", reply("{\"text\":\"a\"}"))
        standIn.write("1.reply", reply("{\"text\":\"b\"}"))
        standIn.write("2.reply", reply("{\"text\":\"c\"}"))
        let planner = ClaudeCodePlanner(ClaudeCodeOptions(bin: standIn.bin, model: "opus", timeoutMs: 10_000))
        defer { planner.dispose() }
        #expect(planner.quickSwapsModel == false)
        planner.seed(task: task(), droppedPaths: [])
        _ = try await planner.propose(tools: [])
        planner.setTier(.quick)
        #expect(planner.holdsConversation())
        _ = try await planner.propose(tools: [])
        planner.setTier(.full)
        _ = try await planner.propose(tools: [])
        #expect(standIn.count(suffix: ".launch") == 1)
        let args = standIn.args("0.launch") ?? []
        #expect(args[args.firstIndex(of: "--model")! + 1] == "opus")
        for pair in [("--tools", ""), ("--allowed-tools", ""), ("--setting-sources", "")] {
            #expect(args[args.firstIndex(of: pair.0)! + 1] == pair.1)
        }
        #expect(args.contains("--strict-mcp-config") && args.suffix(2) == ["--system-prompt", SYSTEM_PROMPT])
    }

    @Test func streamSessionRefusesASecondStepInFlightAndASendAfterClose() async throws {
        let standIn = StandIn.stream()
        let session = try StreamSession(model: "sonnet", bin: standIn.bin, args: [], env: Exec.environment())
        async let first: JSON = session.send("one", timeoutMs: 5000)
        #expect(await eventually { standIn.read("lines") != nil })
        do { _ = try await session.send("two", timeoutMs: 5000); Issue.record("should refuse") } catch {
            #expect(messageOf(error) == "a planning step is already in flight")
        }
        session.close()
        do { _ = try await first; Issue.record("should fail") } catch {
            #expect(messageOf(error).hasPrefix("Claude Code stopped (exit "))
        }
        #expect(!session.alive)
        do { _ = try await session.send("three", timeoutMs: 5000); Issue.record("should refuse") } catch {
            #expect(messageOf(error) == "Claude Code is not running")
        }
    }

    @Test func prewarmedProcessIsTakenByTheNextTask() async throws {
        let standIn = StandIn.stream()
        standIn.write("0.reply", reply("{\"text\":\"warm\"}"))
        try await withEnvironment(["MERRY_CLAUDE_BIN": standIn.bin]) {
            #expect(claudeCodeAvailable())
            let found = try resolveBin()
            #expect(found == standIn.bin)
            prewarmClaudeCode("warm-model", "warm-model")
            #expect(await eventually { standIn.count(suffix: ".pid") == 1 })
            prewarmClaudeCode(["other-model"])
            #expect(await eventually { standIn.count(suffix: ".pid") == 2 })
            prewarmClaudeCode("warm-model")
            #expect(standIn.count(suffix: ".launch") == 2)
            let pids = (0..<2).compactMap { Int32((standIn.read("\($0).pid") ?? "").jsTrimmed) }

            let planner = ClaudeCodePlanner(ClaudeCodeOptions(model: "warm-model", timeoutMs: 10_000))
            planner.seed(task: task(), droppedPaths: [])
            let proposal = try await planner.propose(tools: [])
            #expect(proposal.text == "warm")
            // It answered from the waiting process rather than starting a third.
            #expect(standIn.count(suffix: ".launch") == 2)
            planner.dispose()
            disposeWarmClaudeCode()
            for pid in pids { #expect(await eventually { !processIsAlive(pid) }) }
        }
    }

    // MARK: One call per step

    @Test func codexWithoutAReplyFileAndAFailingCall() async {
        let standIn = StandIn.oneShot()
        standIn.write("0.stdout", "it printed but wrote nothing")
        standIn.write("1.stderr", "  Not logged in. Run codex login.  \n")
        standIn.write("1.exit", "1")
        standIn.write("2.exit", "3")
        let planner = CodexPlanner("", bin: standIn.bin)
        defer { planner.dispose() }
        planner.seed(task: task(), droppedPaths: [])
        for wanted in ["Codex finished without a reply.", "Not logged in. Run codex login.", "Codex stopped (exit 3)"] {
            do { _ = try await planner.propose(tools: []); Issue.record("should have failed") } catch { #expect(messageOf(error) == wanted) }
        }
    }

    @Test func aSlowCallIsKilled() async {
        let standIn = StandIn.silent()
        let planner = OpenCodePlanner("p/m", bin: standIn.bin, timeoutMs: 600)
        defer { planner.dispose() }
        planner.seed(task: task(), droppedPaths: [])
        do { _ = try await planner.propose(tools: []); Issue.record("should have timed out") } catch {
            #expect(messageOf(error) == "OpenCode took longer than 1s to answer")
        }
        let pid = Int32((standIn.read("pid") ?? "").jsTrimmed) ?? 0
        #expect(pid > 0)
        #expect(await eventually { !processIsAlive(pid) })
    }

    @Test func aMissingBinaryIsReported() async {
        do { _ = try await runOnce("/nonexistent/merry-no-such-app", [], cwd: Path.tmp, timeoutMs: 1000, label: "Nothing"); Issue.record("should fail") } catch {
            #expect(messageOf(error) == "spawn /nonexistent/merry-no-such-app ENOENT")
            #expect(modelCheckFailure(messageOf(error)).message == "The coding app could not be started. Check its installation, then retry.")
        }
        do { _ = try await discoverCodexCatalog("/nonexistent/merry-no-such-app", Path.tmp); Issue.record("should fail") } catch {
            #expect(messageOf(error) == "Couldn’t start Codex. Check its installation.")
        }
        let folder = StandIn.silent()
        do { _ = try await discoverOpenCodeModels("/nonexistent/merry-no-such-app", folder.dir); Issue.record("should fail") } catch {
            #expect(messageOf(error) == "Couldn’t start OpenCode.")
        }
    }

    @Test func aListingThatNeverAnswersTimesOut() async {
        let standIn = StandIn.silent()
        do { _ = try await discoverClaudeModels(standIn.bin, standIn.dir, timeoutMs: 1500); Issue.record("should time out") } catch {
            #expect(messageOf(error) == "Claude Code took too long to list models. Try Refresh or enter a model ID.")
        }
        let pid = Int32((standIn.read("pid") ?? "").jsTrimmed) ?? 0
        #expect(pid > 0)
        #expect(await eventually { !processIsAlive(pid) })
    }

    // MARK: Finding the apps

    @Test func binariesResolveFromTheOverrideAndCreatePlanners() async {
        let standIn = StandIn.oneShot()
        await withEnvironment(["MERRY_CLAUDE_BIN": standIn.bin, "MERRY_CODEX_BIN": standIn.bin, "MERRY_OPENCODE_BIN": standIn.bin]) {
            #expect((try? resolveCodex()) == standIn.bin)
            #expect((try? resolveOpenCode()) == standIn.bin)
            #expect(codingAppStatus() == [
                CodingAppStatus(id: .claudeCode, label: "Claude Code", available: true),
                CodingAppStatus(id: .codex, label: "Codex", available: true),
                CodingAppStatus(id: .opencode, label: "OpenCode", available: true)
            ])
            #expect(codingAppAvailable(.codex))
        }
        do { _ = try resolveBinary("merry-no-such-app-zz", "MERRY_NO_SUCH_BIN", "Nothing"); Issue.record("should fail") } catch {
            #expect(messageOf(error) == "I could not find Nothing on this Mac. Install it, or add an Anthropic key with /keys.")
        }
        var config = ModelConfig()
        config.codex = "gpt-x"; config.opencode = "p/m"; config.claudeCode = "opus"
        let planners = [createCodingAppPlanner(.claudeCode, config), createCodingAppPlanner(.codex, config), createCodingAppPlanner(.opencode, config)]
        #expect(planners[0] is ClaudeCodePlanner && planners[1] is CodexPlanner && planners[2] is OpenCodePlanner)
        for planner in planners { planner.dispose() }
    }

    // MARK: OpenCode's catalog

    @Test(.enabled(if: StandIn.hasPython)) func openCodeCatalogFromItsLocalServer() async throws {
        let row = Fixture.load("model-pure").list("providers")[2]
        let standIn = StandIn.openCodeServer()
        standIn.write("provider.json", row["input"]!.stringify())
        standIn.write("config.json", "{\"model\":\"anthropic/a\"}")
        let catalog = try await discoverOpenCodeModels(standIn.bin, standIn.dir, timeoutMs: 10_000)
        let wanted = try parseOpenCodeProviders(row["input"]!, "anthropic/a")
        #expect(catalog == wanted)
        #expect(catalog.defaultModel == "anthropic/a")
        #expect(standIn.args("serve.args") == ["serve", "--hostname", "127.0.0.1", "--port", "0"])
        #expect(standIn.read("serve.config") == "{\"permission\":{\"*\":\"deny\"}}")
        let hits = (standIn.read("hits") ?? "").split(separator: "\n").map(String.init).sorted()
        #expect(hits == ["/config \(standIn.dir)", "/provider \(standIn.dir)"])
        let pid = Int32((standIn.read("pid") ?? "").jsTrimmed) ?? 0
        #expect(await eventually { !processIsAlive(pid) })
    }

    @Test(.enabled(if: StandIn.hasPython)) func openCodeCatalogWithoutAConfigOrProviders() async throws {
        let standIn = StandIn.openCodeServer()
        standIn.write("provider.json", "{\"all\":[],\"connected\":[]}")
        let catalog = try await discoverOpenCodeModels(standIn.bin, standIn.dir, timeoutMs: 10_000)
        #expect(catalog.connection == "OpenCode · no connected providers" && catalog.defaultModel == nil)

        let broken = StandIn.openCodeServer()
        do { _ = try await discoverOpenCodeModels(broken.bin, broken.dir, timeoutMs: 10_000); Issue.record("should fail") } catch {
            #expect(messageOf(error) == "Couldn’t read OpenCode providers.")
        }
    }

    @Test(.enabled(if: StandIn.hasPython)) func codingModelsFallsBackToTheModelList() async throws {
        let standIn = StandIn.openCodeServer()
        standIn.write("no-serve", "")
        standIn.write("models.txt", "anthropic/claude-sonnet-5\n{\"name\":\"Claude Sonnet 5\",\"cost\":{\"input\":0,\"output\":0}}\n")
        let catalog = try await withEnvironment(["MERRY_OPENCODE_BIN": standIn.bin]) { try await codingModels(.opencode, refresh: true) }
        #expect(catalog.connection == "OpenCode · connection details unavailable")
        #expect(catalog.note == "Your OpenCode version lists models without connection details. Check a model before using it. Update OpenCode for provider recommendations.")
        #expect(catalog.models.map(\.label) == ["Claude Sonnet 5 · anthropic/claude-sonnet-5"] && catalog.models[0].free == true)

        let codex = codexRpcStandIn(fixture.list("catalogs")[1])
        let listed = try await withEnvironment(["MERRY_CODEX_BIN": codex.bin]) { try await codingModels(.codex) }
        #expect(listed.connection == "Codex · API billing" && listed.models.map(\.id) == ["o9"])
    }
}

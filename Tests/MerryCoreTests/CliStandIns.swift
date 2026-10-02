import Foundation
@testable import MerryCore

// Stand-ins for the coding apps' CLIs: small scripts written into a temp
// folder that speak the same protocol on stdin and stdout. No test starts a
// real `claude`, `codex` or `opencode`.

/// A scratch folder holding one stand-in and everything it logs.
final class StandIn: @unchecked Sendable {
    let dir: String
    let bin: String

    private init(_ script: String, interpreter: String = "/bin/sh") {
        dir = Path.join(Path.tmp, "merry-standin-" + newId())
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        bin = Path.join(dir, "standin")
        let text = "#!\(interpreter)\nDIR='\(dir)'\n" + script
        try! text.write(toFile: bin, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ name: String, _ text: String) {
        try! text.write(toFile: Path.join(dir, name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: Path.join(dir, name)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// An argument list a stand-in saved, one NUL after each argument.
    func args(_ name: String) -> [String]? {
        guard let text = read(name) else { return nil }
        var parts = text.components(separatedBy: "\0")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    func count(suffix: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(suffix) }.count
    }

    /// Claude Code's stream mode: a process that stays open and answers each
    /// line on stdin with a result line. `<n>.reply` holds the nth answer and
    /// `<n>.mode` may say "die" (fail instead) or "exit-after" (answer, then stop).
    static func stream() -> StandIn {
        StandIn(#"""
        launch=$(ls "$DIR" | grep -c '\.launch$')
        for a in "$@"; do printf '%s\0' "$a"; done > "$DIR/$launch.launch"
        printf '%s|%s\n' "${CLAUDE_CODE_ENTRYPOINT-unset}" "${MAX_THINKING_TOKENS-unset}" > "$DIR/$launch.env"
        pwd -P > "$DIR/$launch.cwd"
        echo $$ > "$DIR/$launch.pid"
        while IFS= read -r line; do
          n=$(cat "$DIR/count" 2>/dev/null || echo 0)
          echo $((n+1)) > "$DIR/count"
          printf '%s\n' "$line" >> "$DIR/lines"
          printf '%s\n' "$launch" >> "$DIR/served"
          [ -f "$DIR/$n.reply" ] || continue
          mode=$(cat "$DIR/$n.mode" 2>/dev/null)
          if [ "$mode" = "die" ]; then echo "fatal: model overloaded" >&2; exit 7; fi
          printf '{"type":"system","subtype":"init"}\nnoise that is not json\n{"type":"assistant","message":{}}\n'
          cat "$DIR/$n.reply"; printf '\n'
          if [ "$mode" = "exit-after" ]; then exit 0; fi
        done
        """#)
    }

    /// One call, one answer: Codex, OpenCode and the model checks. Call n
    /// saves its arguments, stdin and any opencode.json, then answers from
    /// `<n>.file` (copied to the `-o` path), `<n>.stdout`, `<n>.stderr`, `<n>.exit`.
    /// Asked for a model list (`--input-format`), it answers from `discovery` or fails.
    static func oneShot() -> StandIn {
        StandIn(#"""
        case " $* " in *" --input-format "*)
          [ -f "$DIR/discovery" ] || exit 1
          IFS= read -r line
          printf '%s\n' "$line" > "$DIR/discovery.request"
          id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
          sed "s/<id>/$id/" "$DIR/discovery"
          cat > /dev/null
          exit 0;;
        esac
        n=$(ls "$DIR" | grep -c '\.args$')
        for a in "$@"; do printf '%s\0' "$a"; done > "$DIR/$n.args"
        cat > "$DIR/$n.stdin"
        [ -f opencode.json ] && cp opencode.json "$DIR/$n.config"
        out=""; prev=""
        for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
        [ -n "$out" ] && [ -f "$DIR/$n.file" ] && cp "$DIR/$n.file" "$out"
        [ -f "$DIR/$n.stderr" ] && cat "$DIR/$n.stderr" >&2
        [ -f "$DIR/$n.stdout" ] && cat "$DIR/$n.stdout"
        [ -f "$DIR/$n.exit" ] && exit "$(cat "$DIR/$n.exit")"
        exit 0
        """#)
    }

    /// A line-per-request control protocol: request n is answered with line n
    /// of `replies` (an empty line answers nothing, "EXIT" stops).
    static func rpc() -> StandIn {
        StandIn(#"""
        for a in "$@"; do printf '%s\0' "$a"; done > "$DIR/args"
        [ -f "$DIR/noise" ] && cat "$DIR/noise"
        n=0
        while IFS= read -r line; do
          n=$((n+1))
          printf '%s\n' "$line" >> "$DIR/requests"
          reply=$(sed -n "${n}p" "$DIR/replies")
          [ "$reply" = "EXIT" ] && exit 0
          [ -n "$reply" ] && printf '%s\n' "$reply"
        done
        """#)
    }

    /// Something that never answers and never reads.
    static func silent() -> StandIn {
        StandIn("echo $$ > \"$DIR/pid\"\nexec sleep 30\n")
    }

    /// OpenCode's `serve`: a local HTTP server that announces its port, and
    /// answers /provider and /config to the right password only.
    static func openCodeServer() -> StandIn {
        StandIn(#"""
        import base64, http.server, json, os, sys
        if sys.argv[1:2] != ['serve']:
            sys.stdout.write(open(DIR + '/models.txt').read() if os.path.exists(DIR + '/models.txt') else '')
            sys.exit(0 if os.path.exists(DIR + '/models.txt') else 1)
        if os.path.exists(DIR + '/no-serve'):
            sys.exit(1)
        open(DIR + '/serve.args', 'w').write('\0'.join(sys.argv[1:]))
        open(DIR + '/serve.config', 'w').write(open('opencode.json').read())
        expected = 'Basic ' + base64.b64encode((os.environ['OPENCODE_SERVER_USERNAME'] + ':' + os.environ['OPENCODE_SERVER_PASSWORD']).encode()).decode()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                name = self.path.strip('/')
                path = DIR + '/' + name + '.json'
                with open(DIR + '/hits', 'a') as hits: hits.write(self.path + ' ' + str(self.headers.get('x-opencode-directory')) + '\n')
                if self.headers.get('Authorization') != expected:
                    self.send_response(401); self.end_headers(); return
                if not os.path.exists(path):
                    self.send_response(404); self.end_headers(); return
                body = open(path, 'rb').read()
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers()
                self.wfile.write(body)
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        open(DIR + '/pid', 'w').write(str(os.getpid()))
        print('Warning: something first', flush=True)
        print('opencode server listening on http://127.0.0.1:%d' % server.server_address[1], flush=True)
        server.serve_forever()
        """#, interpreter: "/usr/bin/python3")
    }

    static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }
}

/// Whether a process id still names a running process.
func processIsAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

/// Waits, without blocking a thread, until `condition` holds or the time runs out.
func eventually(timeoutMs: Int = 3000, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

func withEnvironment<T>(_ values: [String: String?], _ body: () async throws -> T) async rethrows -> T {
    var saved: [String: String?] = [:]
    for (key, value) in values {
        saved[key] = getenv(key).map { String(cString: $0) }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
    defer {
        for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
    }
    return try await body()
}

func markPrompt(_ text: String) -> String { text.replacingOccurrences(of: SYSTEM_PROMPT, with: "<<SYSTEM_PROMPT>>") }

/// A result line as Claude Code prints it, for one scripted reply.
func resultEnvelope(_ reply: JSON) -> String {
    let envelope: JSON = [
        "type": "result", "is_error": false, "result": .string(reply.str("result")),
        "usage": ["input_tokens": reply["inputTokens"] ?? 0, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 7, "output_tokens": reply["outputTokens"] ?? 0]
    ]
    return envelope.stringify()
}

/// A planner whose app is a script of replies, for checking the prompts alone.
final class ScriptedPlanner: CliPlanner, @unchecked Sendable {
    private let inline: Bool
    private let holds: Bool
    private let lock = NSLock()
    private var replies: [CliReply] = []
    private var messages: [String] = []

    init(inline: Bool, holds: Bool) {
        self.inline = inline
        self.holds = holds
        super.init()
    }

    override var label: String { "Scripted" }
    override var inlineInstructions: Bool { inline }
    override func holdsConversation() -> Bool { holds }

    func feed(_ next: [CliReply]) { lock.withLock { replies = next; messages = [] } }
    var sent: [String] { lock.withLock { messages } }

    override func exchange(_ message: String) async throws -> CliReply {
        try lock.withLock {
            messages.append(message)
            guard !replies.isEmpty else { throw MerryError("no scripted reply left") }
            return replies.removeFirst()
        }
    }
}

/// Runs a fixture's ops against a planner. `feed` hands a propose its replies;
/// `sent` reports what the app was sent for it, in the fixture's shape.
func driveCliOps(_ ops: [JSON], planner: CliPlanner, fixture: JSON, name: String, feed: (JSON) -> Void, sent: () async -> JSON) async -> [String] {
    LocalTime.use(timeZone: "Asia/Kolkata")
    let fixedNow = fixture.num("now")
    let home = fixture.str("home")
    planner.now = { JSDate(fixedNow) }
    planner.home = { home }
    var problems: [String] = []
    for (index, op) in ops.enumerated() {
        let at = "\(name) op \(index)"
        switch op.str("op") {
        case "seed":
            let a = op["authorization"] ?? .null
            planner.seed(task: TaskState(request: op.str("request"), authorization: Authorization(readRoots: a.strings("readRoots"), writeRoots: a.strings("writeRoots"), apps: a.strings("apps"))), droppedPaths: op.strings("droppedPaths"))
        case "addToolResults":
            planner.addToolResults(op.list("results").map { ToolResultInput(callId: $0.str("callId"), content: $0.str("content"), isError: $0.flag("isError")) })
        case "addNote":
            planner.addNote(op.str("note"))
        case "propose":
            feed(op)
            do {
                let proposal = try await planner.propose(tools: fixture["toolSets"]!.list(op.str("toolSet")))
                if let wanted = op["proposal"] {
                    if let d = proposalJSON(proposal).firstDifference(from: wanted) { problems.append("\(at) proposal: \(d)") }
                } else {
                    problems.append("\(at): succeeded, expected error \(op.str("error"))")
                }
            } catch {
                if op["error"] == nil { problems.append("\(at): threw \(messageOf(error))") }
                else if messageOf(error) != op.str("error") { problems.append("\(at): error \(messageOf(error)), expected \(op.str("error"))") }
            }
            if let d = await sent().firstDifference(from: op["sent"] ?? .null) { problems.append("\(at) sent: \(d)") }
        default:
            problems.append("\(at): unknown op")
        }
    }
    return problems
}

func cliReplies(_ op: JSON) -> [CliReply] {
    op.list("replies").map { CliReply(result: $0.str("result"), inputTokens: $0.int("inputTokens"), outputTokens: $0.int("outputTokens")) }
}

/// The prompts CliPlanner builds, against the reference's for the same conversation.
func replayPrompts(_ row: JSON, fixture: JSON) async -> [String] {
    let planner = ScriptedPlanner(inline: row.flag("inline"), holds: row.flag("holds"))
    return await driveCliOps(row.list("ops"), planner: planner, fixture: fixture, name: row.str("name"),
                             feed: { planner.feed(cliReplies($0)) },
                             sent: { .array(planner.sent.map { .string(markPrompt($0)) }) })
}

/// Claude Code with the injected one-call runner.
func replayClaudeRun(_ row: JSON, fixture: JSON) async -> [String] {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var replies: [JSON] = []
        var calls: [JSON] = []
    }
    let state = Calls()
    let planner = ClaudeCodePlanner(ClaudeCodeOptions(model: row.optStr("model"), run: { args, input in
        state.lock.withLock {
            state.calls.append(["args": JSON(args.map(markPrompt)), "input": .string(input)])
            return resultEnvelope(state.replies.removeFirst())
        }
    }))
    return await driveCliOps(row.list("ops"), planner: planner, fixture: fixture, name: "claude run \(row.optStr("model") ?? "default")",
                             feed: { op in state.lock.withLock { state.replies = op.list("replies"); state.calls = [] } },
                             sent: { .array(state.lock.withLock { state.calls }) })
}

/// Claude Code's long-lived stream, through a stand-in executable: the same
/// lines on stdin as the reference writes, and one process for the whole task.
func replayClaudeStream(_ row: JSON, fixture: JSON) async -> [String] {
    let standIn = StandIn.stream()
    let model = row.optStr("model")
    let planner = ClaudeCodePlanner(ClaudeCodeOptions(bin: standIn.bin, model: model, timeoutMs: 10_000))
    var served = 0
    var from = 0
    func lines() -> [String] { (standIn.read("lines") ?? "").split(separator: "\n").map(String.init) }
    var problems = await driveCliOps(row.list("ops"), planner: planner, fixture: fixture, name: "claude stream \(model ?? "default")", feed: { op in
        from = lines().count
        for reply in op.list("replies") {
            standIn.write("\(served).reply", resultEnvelope(reply))
            served += 1
        }
    }, sent: {
        .array(lines().dropFirst(from).map { line in
            guard var message = try? JSON.parse(line) else { return .string(line) }
            if var inner = message["message"] {
                inner["content"] = .string(markPrompt(inner.str("content")))
                message["message"] = inner
            }
            return message
        })
    })
    let spawn = row.list("spawns")[0]
    if row.list("spawns").count != 1 || standIn.count(suffix: ".launch") != 1 { problems.append("expected one process for the whole task, got \(standIn.count(suffix: ".launch"))") }
    if standIn.args("0.launch")?.map(markPrompt) != spawn.strings("args") { problems.append("launch args \(standIn.args("0.launch")?.map(markPrompt) ?? [])") }
    if claudeCliArgs(model ?? "sonnet").map(markPrompt) != spawn.strings("args") { problems.append("claudeCliArgs differ") }
    let env = claudeCliEnv(model ?? "sonnet")
    if env["CLAUDE_CODE_ENTRYPOINT"] != spawn["env"]?.optStr("CLAUDE_CODE_ENTRYPOINT") || env["MAX_THINKING_TOKENS"] != spawn["env"]?.optStr("MAX_THINKING_TOKENS") { problems.append("claudeCliEnv differs") }
    let wantedEnv = "\(spawn["env"]!.str("CLAUDE_CODE_ENTRYPOINT"))|\(spawn["env"]!.optStr("MAX_THINKING_TOKENS") ?? "unset")\n"
    if standIn.read("0.env") != wantedEnv { problems.append("process env \(standIn.read("0.env") ?? "")") }
    // A neutral folder, not wherever the app happens to be.
    let cwd = (standIn.read("0.cwd") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if cwd != (realpath(Path.tmp, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? "") { problems.append("cwd \(cwd)") }
    let pid = Int32((standIn.read("0.pid") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    if !processIsAlive(pid) { problems.append("the process should still be running before dispose") }
    planner.dispose()
    if !(await eventually { !processIsAlive(pid) }) { problems.append("dispose left the process running") }
    return problems
}

/// Codex and OpenCode through a stand-in: arguments, stdin, the config file, the replies.
func replayOneShot(_ row: JSON, fixture: JSON) async -> [String] {
    let standIn = StandIn.oneShot()
    let app = row.str("app"), model = row.str("model")
    let planner: CliPlanner = app == "codex" ? CodexPlanner(model, bin: standIn.bin) : OpenCodePlanner(model, bin: standIn.bin)
    var queued = 0
    var from = 0
    var scratch = ""
    func clean(_ text: String) -> String { markPrompt(text).replacingOccurrences(of: scratch, with: "<dir>") }
    var problems = await driveCliOps(row.list("ops"), planner: planner, fixture: fixture, name: "\(app) \(model)", feed: { op in
        from = standIn.count(suffix: ".args")
        for reply in op.list("replies") {
            if app == "codex" {
                standIn.write("\(queued).file", reply.str("result"))
                standIn.write("\(queued).stdout", "progress noise\n")
            } else {
                standIn.write("\(queued).stdout", reply.str("result"))
            }
            queued += 1
        }
    }, sent: {
        var out: [JSON] = []
        for n in from..<standIn.count(suffix: ".args") {
            let args = standIn.args("\(n).args") ?? []
            if scratch.isEmpty, let at = args.firstIndex(of: "-o"), at + 1 < args.count { scratch = Path.dirname(args[at + 1]) }
            out.append(["args": JSON(args.map(clean)), "stdin": .string(clean(standIn.read("\(n).stdin") ?? "")), "config": JSON(standIn.read("\(n).config"))])
        }
        return .array(out)
    })
    if planner.label != row.str("label") { problems.append("label \(planner.label)") }
    let pureArgs = app == "codex" ? CodexPlanner.arguments(model: model, out: "<dir>/reply.txt") : OpenCodePlanner.arguments(model: model, message: "MESSAGE")
    let firstSent = row.list("ops").first { $0.str("op") == "propose" }!.list("sent")[0].strings("args")
    let wantedArgs = app == "codex" ? firstSent : firstSent.dropLast() + ["MESSAGE"]
    if pureArgs != Array(wantedArgs) { problems.append("arguments(model:) \(pureArgs)") }
    planner.dispose()
    return problems
}

/// Feeds a listing the answers a stand-in app would give, by method, and
/// returns what it asked and what it concluded.
func simulateListing(_ row: JSON) -> (requests: [JSON], catalog: CodingModelCatalog?, error: String?) {
    let rpc = row["rpc"] ?? .null
    let label = row.str("kind") == "codex" ? "Codex" : "Claude Code"
    var environment: [String: String] = [:]
    for key in row["env"]?.objectValue?.keys ?? [] { environment[key] = row["env"]!.str(key) }
    let listing: ModelListing = row.str("kind") == "codex" ? CodexListing() : ClaudeListing(requestId: "<id>", environment: environment)
    var responses: [String: [JSON]] = [:]
    for key in rpc["responses"]?.objectValue?.keys ?? [] { responses[key] = rpc["responses"]!.list(key) }
    var requests: [JSON] = []
    var inbox: [JSON] = rpc.strings("noise").compactMap { strictJSON($0) }
    var outbox = listing.open()
    let unreadable = "Couldn’t read \(label) models. Check your login or update the app."
    let stopped = "\(label) stopped before listing models. Update it or enter a model ID."
    while true {
        for request in outbox {
            requests.append(request)
            if request.str("type") == "control_request" {
                if rpc["claude"]?.stringValue == "exit" { return (requests, nil, stopped) }
                if let answer = rpc["claude"]?.objectValue {
                    inbox.append(["type": "control_response", "response": .object(JSONObject([("request_id", request["request_id"]!)]).merging(answer))])
                }
            } else if let id = request["id"] {
                var queue = responses[request.str("method")] ?? []
                if queue.isEmpty { continue }
                let next = queue.removeFirst()
                responses[request.str("method")] = queue
                if next.stringValue == "exit" { return (requests, nil, stopped) }
                inbox.append(.object(JSONObject([("id", id)]).merging(next.objectValue ?? JSONObject())))
            }
        }
        outbox = []
        if inbox.isEmpty { return (requests, nil, "nothing left to say") }
        let message = inbox.removeFirst()
        do {
            let step = try listing.receive(message)
            if let catalog = step.catalog { return (requests, catalog, nil) }
            outbox = step.send
        } catch {
            return (requests, nil, unreadable)
        }
    }
}

/// A Codex app-server stand-in for one fixture row: one reply line per request.
func codexRpcStandIn(_ row: JSON) -> StandIn {
    let standIn = StandIn.rpc()
    let rpc = row["rpc"] ?? .null
    var responses: [String: [JSON]] = [:]
    for key in rpc["responses"]?.objectValue?.keys ?? [] { responses[key] = rpc["responses"]!.list(key) }
    var lines: [String] = []
    for request in row.list("requests") {
        guard let id = request["id"] else { lines.append(""); continue }
        var queue = responses[request.str("method")] ?? []
        if queue.isEmpty { lines.append(""); continue }
        let next = queue.removeFirst()
        responses[request.str("method")] = queue
        lines.append(next.stringValue == "exit" ? "EXIT" : JSON.object(JSONObject([("id", id)]).merging(next.objectValue ?? JSONObject())).stringify())
    }
    standIn.write("replies", lines.joined(separator: "\n") + "\n")
    if !rpc.strings("noise").isEmpty { standIn.write("noise", rpc.strings("noise").joined(separator: "\n") + "\n") }
    return standIn
}

/// Arms a one-shot stand-in with a fixture row's replies.
func armOneShot(_ standIn: StandIn, replies: [JSON], rpc: JSON?) {
    for (n, reply) in replies.enumerated() {
        if let text = reply.optStr("file") { standIn.write("\(n).file", text) }
        if let text = reply.optStr("stdout") { standIn.write("\(n).stdout", text) }
        if let text = reply.optStr("stderr") { standIn.write("\(n).stderr", text) }
        if let code = reply.optInt("exit") { standIn.write("\(n).exit", String(code)) }
    }
    if let answer = rpc?["claude"]?.objectValue {
        let line: JSON = ["type": "control_response", "response": .object(JSONObject([("request_id", "<id>")]).merging(answer))]
        standIn.write("discovery", line.stringify() + "\n")
    }
}

func encodedJSON<T: Encodable>(_ value: T) -> JSON { JSON.encode(value) }

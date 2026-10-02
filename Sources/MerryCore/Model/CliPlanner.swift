import Foundation

// Planning through a coding app already installed on this Mac (Claude Code,
// Codex or OpenCode), using the login that is already there.
//
// Every one of them is an agent with tools of its own. Here it is only asked
// to answer: it proposes Merry's tool calls as JSON, and Merry's own loop still
// does every check, execution, verification and undo. What differs between
// the apps is only how a message gets to them and back, which is all a
// subclass supplies.
//
// Each person uses the coding app and connection installed on their own machine.

public struct CliReply: Sendable {
    public var result: String
    public var inputTokens: Int
    public var outputTokens: Int
    public init(result: String, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.result = result; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

let REPLY_CONTRACT = """
Reply with ONE JSON object and nothing else. No prose around it, no markdown fence:

{"text": "<see below>",
 "calls": [{"name": "<tool name>", "input": { ... }}]}

"text" is shown to the user. When the request is a question or conversation that needs no tool, put your complete answer in "text", written to the user in plain words, and send no calls. Never describe what you are doing instead of answering ("Answering directly", "No actions needed"). When you are calling tools, "text" may be a short line about the step, or empty.

Propose one step at a time unless several calls are genuinely independent. Use only the tools listed above, with exactly those input fields. If the task is finished, call finish. If you need the user, call ask_user.
"""

/// Said to apps whose own tools cannot be switched off: they answer, Merry acts.
let ANSWER_ONLY = "You are only planning. Do not run commands, read files or browse yourself, even if you are able to: Merry runs every tool listed here and sends you the results."

/// How much of the transcript is replayed to a model that has not seen it.
let REPLAY_BUDGET = 60_000

open class CliPlanner: PlannerLike, @unchecked Sendable {
    /// What the app is called, in errors the user reads.
    open var label: String { "" }
    /// Merry's instructions go in the first message, for apps with no system prompt option.
    open var inlineInstructions: Bool { true }

    private let state = NSLock()
    private var seed_: [String] = []
    private var pending: [String] = []
    /// Tools already described in this conversation, so later turns send only new ones.
    private var described = Set<String>()
    /// Everything said so far in this task, Merry's messages and the replies.
    /// Merry keeps it rather than the app, so no app has to save the
    /// conversation to disk, and a new process or model picks up where the
    /// last one left off.
    private var transcript: [String] = []

    /// Read when a task is seeded and when a call id is minted. Tests pin them.
    var now: @Sendable () -> JSDate = { JSDate() }
    var home: @Sendable () -> String = { ProcessInfo.processInfo.environment["HOME"] ?? Path.home }

    public init() {}

    /// Sends one message and waits for the reply.
    open func exchange(_ message: String) async throws -> CliReply {
        throw MerryError("\(label) cannot be reached.")
    }

    /// Whether the next message reaches a process that has already seen this conversation.
    open func holdsConversation() -> Bool { false }

    open var quickSwapsModel: Bool { false }
    open func setTier(_ tier: PlannerTier) {}
    open func dispose() {}

    public func seed(task: TaskState, droppedPaths: [String]) {
        let context = seedContext(task: task, droppedPaths: droppedPaths, today: now().toDateString(), home: home())
        state.withLock { seed_ = context }
    }

    public func addToolResults(_ results: [ToolResultInput]) {
        state.withLock {
            for r in results {
                pending.append("<tool_result call=\"\(r.callId)\"\(r.isError ? " error=\"true\"" : "")>\n\(clip(r.content))\n</tool_result>")
            }
        }
    }

    public func addNote(_ note: String) {
        state.withLock { pending.append("<system_note>\(note)</system_note>") }
    }

    public func propose(tools: [JSON]) async throws -> PlannerProposal {
        let prompt: String = state.withLock {
            let first = transcript.isEmpty
            var parts: [String] = []
            let fresh = tools.filter { !described.contains($0.str("name")) }
            for t in fresh { described.insert(t.str("name")) }
            if first {
                if inlineInstructions { parts.append("<merry_instructions>\n\(SYSTEM_PROMPT)\n\n\(ANSWER_ONLY)\n</merry_instructions>") }
                parts.append(contentsOf: seed_)
                parts.append("Tools you may call:\n\(tools.map(describeTool).joined(separator: "\n\n"))")
            } else {
                // The menu can grow mid-task when the first approach stalls.
                if !fresh.isEmpty { parts.append("More tools are now available:\n\(fresh.map(describeTool).joined(separator: "\n\n"))") }
                if pending.isEmpty && fresh.isEmpty { parts.append("Continue.") }
            }
            parts.append(contentsOf: pending)
            pending = []
            parts.append(REPLY_CONTRACT)
            return parts.joined(separator: "\n\n")
        }

        var raw = try await ask(prompt)
        var parsed = parseProposal(raw.result, now: now().time)
        if parsed == nil {
            // One nudge before giving up. Models occasionally wrap the object in
            // prose despite the contract.
            let retry = try await ask("That was not parseable. Send the JSON object only, nothing else.")
            raw = CliReply(result: retry.result, inputTokens: raw.inputTokens + retry.inputTokens, outputTokens: raw.outputTokens + retry.outputTokens)
            parsed = parseProposal(retry.result, now: now().time)
        }
        guard let parsed else {
            throw MerryError("\(label) did not return a usable proposal. Try again, or switch to an API key.")
        }

        return PlannerProposal(
            calls: parsed.calls,
            text: parsed.text,
            // The loop only distinguishes tool_use from everything else.
            stopReason: parsed.calls.isEmpty ? "end_turn" : "tool_use",
            // CLI costs are not tracked here. Calls can consume included quota or
            // incur provider charges; the picker explains that the dollar cap does
            // not cover this route. Step and wall-clock limits still bound tasks.
            usd: 0,
            inputTokens: raw.inputTokens,
            outputTokens: raw.outputTokens
        )
    }

    /// One round trip, replaying the conversation first to a process that has not seen it.
    private func ask(_ prompt: String) async throws -> CliReply {
        let held = holdsConversation()
        let message: String = state.withLock { !held && !transcript.isEmpty ? "\(replay(transcript))\n\n\(prompt)" : prompt }
        let reply = try await exchange(message)
        state.withLock { transcript.append(contentsOf: ["<merry>\n\(prompt)\n</merry>", "<you>\n\(reply.result)\n</you>"]) }
        return reply
    }
}

/// The conversation so far, for a model meeting it partway through. The first
/// message (the request, and the tools) is always kept; the middle is what
/// gives way when a long task outgrows the budget.
func replay(_ transcript: [String]) -> String {
    let first = transcript[0]
    let rest = Array(transcript.dropFirst())
    var kept: [String] = []
    var size = first.jsLength
    var i = rest.count - 1
    while i >= 0, size + rest[i].jsLength < REPLAY_BUDGET {
        kept.insert(rest[i], at: 0)
        size += rest[i].jsLength
        i -= 1
    }
    let skipped = rest.count - kept.count
    return "This task is already under way. Here is the conversation so far, as context rather than a new request:\n" +
        "<earlier>\n\(first)\n\(skipped > 0 ? "[\(skipped) earlier messages left out]\n" : "")\(kept.joined(separator: "\n"))\n</earlier>\n\nThe next message:"
}

// MARK: - Parsing

public struct ParsedProposal: Sendable {
    public var text: String
    public var calls: [PlannerProposal.Call]
}

/// Pulls the proposal out of whatever the model actually said. Public so the
/// awkward cases (a fenced block, a sentence in front, a single call instead
/// of an array) are covered by tests rather than by hope.
public func parseProposal(_ reply: String, now: Double = nowMs()) -> ParsedProposal? {
    guard let body = extractObject(reply), let raw = strictJSON(body), raw.objectValue != nil else { return nil }

    let list: [JSON]
    if let array = raw["calls"]?.arrayValue { list = array } else if let one = raw["calls"], one.jsTruthy { list = [one] } else { list = [] }
    var calls: [PlannerProposal.Call] = []
    let stamp = String(Int64(now), radix: 36)
    for entry in list {
        guard entry.objectValue != nil, let name = entry["name"]?.stringValue, !name.isEmpty else { continue }
        let input = JSON.present(entry["input"]) ?? .object(JSONObject())
        calls.append(.init(id: "cc_\(calls.count)_\(stamp)", name: name, input: input))
    }
    let text = raw["text"]?.stringValue?.jsTrimmed ?? ""
    // A reply with neither a call nor a word is not a proposal.
    if calls.isEmpty && text.isEmpty { return nil }
    return ParsedProposal(text: text, calls: calls)
}

/// `JSON.parse`: nil for anything JavaScript would refuse.
func strictJSON(_ text: String) -> JSON? {
    let data = Data(text.utf8)
    guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
    return try? JSON.parse(data)
}

/// Finds the outermost JSON object, ignoring fences, terminal colours and surrounding prose.
private func extractObject(_ reply: String) -> String? {
    let text = Rx("```(?:json)?", "i").replaceAll(Rx("\\u001b\\[[0-9;]*m").replaceAll(reply, ""), "").jsTrimmed
    let units = Array(text.utf16)
    guard let start = units.firstIndex(of: 0x7B) else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    for i in start..<units.count {
        let ch = units[i]
        if escaped { escaped = false; continue }
        if ch == 0x5C { escaped = true; continue }
        if ch == 0x22 { inString.toggle() }
        if inString { continue }
        if ch == 0x7B {
            depth += 1
        } else if ch == 0x7D {
            depth -= 1
            if depth == 0 { return String(decoding: units[start...i], as: UTF16.self) }
        }
    }
    return nil
}

private func describeTool(_ tool: JSON) -> String {
    "- \(tool.str("name")): \(tool.str("description"))\n  input: \((tool["input_schema"] ?? .null).stringify())"
}

public func clip(_ text: String, _ max: Int = 4000) -> String {
    text.jsLength > max ? "\(text.jsSlice(0, max))\n…[truncated]" : text
}

// MARK: - Finding and running the apps

private let foundLock = NSLock()
private nonisolated(unsafe) var found: [String: String] = [:]

private func liveEnv(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    let text = String(cString: value)
    return text.isEmpty ? nil : text
}

/// Finds a coding app's binary. An app launched from Finder inherits almost
/// no PATH, so looking it up the way a shell would is not optional here.
public func resolveBinary(_ name: String, _ envOverride: String, _ label: String, _ extra: [String] = []) throws -> String {
    let fm = FileManager.default
    func remember(_ path: String) -> String {
        foundLock.withLock { found[name] = path }
        return path
    }
    let fromEnv = liveEnv(envOverride)
    if let cached = foundLock.withLock({ found[name] }), fm.fileExists(atPath: cached), fromEnv == nil { return cached }
    if let fromEnv, fm.fileExists(atPath: fromEnv) { return remember(fromEnv) }
    if let path = loginShellLookup(name), fm.fileExists(atPath: path) { return remember(path) }
    // Fall through to the usual install locations.
    let home = liveEnv("HOME") ?? ""
    let candidates = [
        Path.join(home, ".local/bin", name),
        Path.join("/opt/homebrew/bin", name),
        Path.join("/usr/local/bin", name),
        Path.join(home, ".\(name)/bin", name),
        Path.join(home, ".npm-global/bin", name),
        Path.join(home, ".bun/bin", name)
    ] + extra
    for candidate in candidates where fm.fileExists(atPath: candidate) { return remember(candidate) }
    if let path = Exec.which(name) { return remember(path) }
    throw MerryError("I could not find \(label) on this Mac. Install it, or add an Anthropic key with /keys.")
}

/// `command -v name` in a login shell, which reads the PATH the person's
/// profile sets up. Gives up after a few seconds rather than hang on a slow profile.
private func loginShellLookup(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", "command -v \(name)"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    guard (try? process.run()) != nil else { return nil }
    if done.wait(timeout: .now() + 5) == .timedOut {
        process.terminate()
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).jsTrimmed
    return text.isEmpty ? nil : text
}

/// Runs one CLI call to completion: the message on stdin or as an argument,
/// stdout back. A call that outlives the timeout is killed rather than left
/// holding the task.
public func runOnce(_ bin: String, _ args: [String], cwd: String, input: String? = nil, timeoutMs: Int, label: String) async throws -> String {
    let run = OnceRun()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            run.start(bin, args, cwd: cwd, input: input, timeoutMs: timeoutMs, label: label, continuation)
        }
    } onCancel: {
        run.cancel()
    }
}

private final class OnceRun: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var errText = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var child: CliProcess?
    private var timer: DispatchWorkItem?
    private var cancelled = false

    private func settle(_ result: Result<String, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        timer?.cancel()
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = child
        lock.unlock()
        running?.kill()
        settle(.failure(CancellationError()))
    }

    func start(_ bin: String, _ args: [String], cwd: String, input: String?, timeoutMs: Int, label: String, _ continuation: CheckedContinuation<String, Error>) {
        lock.withLock { self.continuation = continuation }
        let child: CliProcess
        do {
            child = try CliProcess(
                bin: bin, args: args, cwd: cwd, env: Exec.environment(),
                onStdout: { [self] data in lock.withLock { out.append(data) } },
                onStderr: { [self] data in lock.withLock { errText = (errText + String(decoding: data, as: UTF8.self)).jsSlice(-2000) } },
                onClose: { [self] code in
                    if code == 0 {
                        settle(.success(lock.withLock { String(decoding: out, as: UTF8.self) }))
                    } else {
                        let said = lock.withLock { errText }.jsTrimmed.jsSlice(-400)
                        settle(.failure(MerryError(said.isEmpty ? "\(label) stopped (exit \(code.map(String.init) ?? "unknown"))" : said)))
                    }
                }
            )
        } catch {
            settle(.failure(error))
            return
        }
        let work = DispatchWorkItem { [self] in
            child.kill()
            settle(.failure(MerryError("\(label) took longer than \(Int((Double(timeoutMs) / 1000).rounded()))s to answer")))
        }
        let alreadyCancelled: Bool = lock.withLock {
            self.child = child
            timer = work
            return cancelled
        }
        if alreadyCancelled { child.kill(); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: work)
        child.end(input ?? "")
    }
}

/// A child process with pipes on all three streams, the shape Node's `spawn`
/// gives the reference. Output arrives through callbacks on one serial queue,
/// so no thread ever sits blocked on a read; `onClose` comes last, after the
/// process has exited and what it wrote has been delivered.
///
/// A child lives no longer than the app: every one still running is ended
/// when the app exits normally, and each of these CLIs stops by itself when
/// its stdin closes, which is what happens if the app dies any other way.
final class CliProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let events = DispatchQueue(label: "merry.cli.events")
    private let writes = DispatchQueue(label: "merry.cli.stdin")
    private let lock = NSLock()
    private var inputClosed = false
    private var openStreams = 2
    private var exitCode: Int32??
    private var closed = false
    private let onClose: @Sendable (Int32?) -> Void

    /// `onClose` receives the exit code, or nil when a signal ended the process.
    init(
        bin: String, args: [String], cwd: String, env: [String: String],
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (Int32?) -> Void
    ) throws {
        self.onClose = onClose
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        // A closed pipe after the process died must not take the app down with it.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        for (pipe, deliver) in [(out, onStdout), (err, onStderr)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self, events] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    events.async { self?.streamEnded() }
                } else {
                    events.async { deliver(data) }
                }
            }
        }
        process.terminationHandler = { [weak self, events] p in
            let code: Int32? = p.terminationReason == .exit ? p.terminationStatus : nil
            events.async { self?.exited(code) }
            // A grandchild holding a pipe open must not hold the result hostage.
            events.asyncAfter(deadline: .now() + .milliseconds(300)) { self?.finish(force: true) }
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            // Worded as Node words it, which the model check reads for "ENOENT".
            throw MerryError("spawn \(bin) ENOENT")
        }
        CliProcess.track(self)
    }

    var isRunning: Bool { process.isRunning }

    private func streamEnded() {
        lock.withLock { openStreams -= 1 }
        finish(force: false)
    }

    private func exited(_ code: Int32?) {
        lock.withLock { exitCode = .some(code) }
        finish(force: false)
    }

    private func finish(force: Bool) {
        let code: Int32?? = lock.withLock {
            guard !closed, let exitCode, force || openStreams <= 0 else { return nil }
            closed = true
            return exitCode
        }
        guard let code else { return }
        CliProcess.untrack(self)
        onClose(code)
    }

    /// Writes to the child's stdin. Never blocks the caller, and a child that
    /// has gone away just loses the bytes.
    func write(_ text: String) {
        let handle = stdin.fileHandleForWriting
        writes.async { [self] in
            if lock.withLock({ inputClosed }) { return }
            CliProcess.writeAll(handle.fileDescriptor, Array(text.utf8))
        }
    }

    /// Writes the last of the input and closes stdin.
    func end(_ text: String = "") {
        if !text.isEmpty { write(text) }
        let handle = stdin.fileHandleForWriting
        writes.async { [self] in
            let already: Bool = lock.withLock { let was = inputClosed; inputClosed = true; return was }
            if !already { try? handle.close() }
        }
    }

    func kill() {
        if process.isRunning { process.terminate() }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            sent += n
        }
    }

    // MARK: Ending with the app

    private static let registry = NSLock()
    private nonisolated(unsafe) static var live: [ObjectIdentifier: CliProcess] = [:]
    private nonisolated(unsafe) static var hooked = false

    private static func track(_ child: CliProcess) {
        registry.lock(); defer { registry.unlock() }
        live[ObjectIdentifier(child)] = child
        if !hooked {
            hooked = true
            atexit { CliProcess.killAll() }
        }
    }

    private static func untrack(_ child: CliProcess) {
        registry.withLock { _ = live.removeValue(forKey: ObjectIdentifier(child)) }
    }

    static func killAll() {
        let all = registry.withLock { Array(live.values) }
        for child in all { child.kill() }
    }
}

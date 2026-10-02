import Foundation

// Planning through the Claude Code CLI on this Mac (`claude -p`), with every
// Claude Code tool denied, so it can only answer. The shared behaviour (the
// reply contract, the transcript, parsing) lives in CliPlanner; this is the
// transport and a process that stays open for the whole task.
// The selected model is honored for both answers and tasks.

public struct ClaudeCodeOptions: Sendable {
    /// Overrides binary discovery.
    public var bin: String?
    /// A Claude Code model alias or exact model ID selected by the person.
    public var model: String?
    public var timeoutMs: Int?
    /// Injected in tests so the suite never shells out to a real CLI. When set,
    /// each step is one CLI call, with the conversation replayed each time.
    public var run: (@Sendable (_ args: [String], _ input: String) async throws -> String)?

    public init(bin: String? = nil, model: String? = nil, timeoutMs: Int? = nil, run: (@Sendable ([String], String) async throws -> String)? = nil) {
        self.bin = bin; self.model = model; self.timeoutMs = timeoutMs; self.run = run
    }
}

public final class ClaudeCodePlanner: CliPlanner, @unchecked Sendable {
    public override var label: String { "Claude Code" }
    /// Merry's prompt goes in as Claude Code's system prompt instead.
    public override var inlineInstructions: Bool { false }
    public override var quickSwapsModel: Bool { false }

    private let options: ClaudeCodeOptions
    private let model: String
    private let timeoutMs: Int
    private let lock = NSLock()
    /// One long-lived CLI process for the whole task; see StreamSession.
    private var stream: StreamSession?

    public init(_ options: ClaudeCodeOptions = ClaudeCodeOptions()) {
        self.options = options
        self.model = options.model ?? "sonnet"
        self.timeoutMs = options.timeoutMs ?? 180_000
        super.init()
    }

    /// Ends the CLI process. The runner calls this when the task is over.
    public override func dispose() {
        let session: StreamSession? = lock.withLock { let s = stream; stream = nil; return s }
        session?.close()
    }

    /// Honor the model the person selected, including for short answers.
    private var activeModel: String { model }

    public override func holdsConversation() -> Bool {
        if options.run != nil { return false }
        guard let stream = lock.withLock({ stream }) else { return false }
        return stream.alive && stream.model == activeModel
    }

    /// The CLI process for this task, started on first use, or taken from the
    /// one started ahead of time. A model change starts a new process, since a
    /// running one keeps the model it started with; the transcript catches it up.
    private func streamFor() throws -> StreamSession {
        let model = activeModel
        lock.lock(); defer { lock.unlock() }
        if let stream, stream.model == model, stream.alive { return stream }
        stream?.close()
        stream = nil
        if options.bin == nil, let warmed = takeWarm(model) {
            stream = warmed
            return warmed
        }
        let session = try StreamSession(model: model, bin: try options.bin ?? resolveBin(), args: claudeCliArgs(model), env: claudeCliEnv(model))
        stream = session
        return session
    }

    public override func exchange(_ message: String) async throws -> CliReply {
        let envelope: JSON
        if let run = options.run {
            let stdout = try await run(["-p", "--output-format", "json", "--model", activeModel] + claudeCommonArgs(), message)
            guard let parsed = strictJSON(stdout) else {
                throw MerryError("Claude Code returned something unreadable: \(clip(stdout, 200))")
            }
            envelope = parsed
        } else {
            envelope = try await streamFor().send(message, timeoutMs: timeoutMs)
        }
        if envelope["is_error"]?.jsTruthy == true {
            throw MerryError(JSON.present(envelope["result"])?.jsString ?? "Claude Code reported an error")
        }
        let usage = envelope["usage"] ?? .null
        func count(_ key: String) -> Int { usage[key]?.doubleValue.map { Int($0) } ?? 0 }
        return CliReply(
            result: JSON.present(envelope["result"])?.jsString ?? "",
            inputTokens: count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens"),
            outputTokens: count("output_tokens")
        )
    }
}

// MARK: - The CLI itself

/// Flags every planning call shares: Claude Code as a pure answerer.
func claudeCommonArgs() -> [String] {
    [
        // Claude Code's own tools are not loaded at all, and none is permitted:
        // this process only ever answers. Not loading them also keeps their
        // definitions out of every prompt.
        "--tools",
        "",
        "--allowed-tools",
        "",
        // Nothing from the user's MCP servers, settings, hooks or skills joins
        // the conversation.
        "--strict-mcp-config",
        "--setting-sources",
        "",
        "--disable-slash-commands",
        // Merry keeps each task's conversation itself, in its own history. Left
        // to its defaults the CLI would also write a transcript of every Merry
        // request under ~/.claude/projects, where deleting it in Merry cannot reach.
        "--no-session-persistence",
        // Merry's prompt replaces Claude Code's coding-agent prompt rather than
        // being appended to it. That prompt is tens of thousands of tokens about
        // writing software; replacing it takes a trivial step from about four
        // seconds to about one and a half.
        "--system-prompt",
        SYSTEM_PROMPT
    ]
}

/// Arguments for one long-lived CLI session.
func claudeCliArgs(_ model: String) -> [String] {
    ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", model] + claudeCommonArgs()
}

func claudeCliEnv(_ model: String) -> [String: String] {
    var env = Exec.environment(adding: ["CLAUDE_CODE_ENTRYPOINT": "merry"])
    // Choosing one tool call does not need a chain of thought, and on the
    // quick model thinking roughly doubles the time a step takes.
    if model == "haiku" { env["MAX_THINKING_TOKENS"] = "0" }
    return env
}

// One process started ahead of time. Starting the CLI costs about two seconds,
// more than a short answer takes, so the next task's process is started
// while the person is still reading the last answer, and sits waiting on stdin.
private let warmLock = NSLock()
private nonisolated(unsafe) var warm: [String: StreamSession] = [:]

/// Starts a process for the next task on each model, unless a live one is already waiting.
public func prewarmClaudeCode(_ models: String...) {
    prewarmClaudeCode(models)
}

public func prewarmClaudeCode(_ models: [String]) {
    for model in models.unique {
        if warmLock.withLock({ warm[model]?.alive }) == true { continue }
        // No CLI to warm: the planner reports that properly when it is needed.
        guard let bin = try? resolveBin(), let session = try? StreamSession(model: model, bin: bin, args: claudeCliArgs(model), env: claudeCliEnv(model)) else { continue }
        let replaced: StreamSession? = warmLock.withLock { let old = warm[model]; warm[model] = session; return old }
        replaced?.close()
    }
}

/// Hands over the waiting process for this model, if it is still alive.
private func takeWarm(_ model: String) -> StreamSession? {
    let taken = warmLock.withLock { warm.removeValue(forKey: model) }
    return taken?.alive == true ? taken : nil
}

/// Ends the waiting processes, e.g. when the runtime shuts down.
public func disposeWarmClaudeCode() {
    let sessions: [StreamSession] = warmLock.withLock { let all = Array(warm.values); warm.removeAll(); return all }
    for session in sessions { session.close() }
}

/// One Claude Code process kept open for a whole task, fed one user message
/// per planning step over stream-json.
///
/// Starting the CLI costs about two seconds every time. A task takes several
/// steps, so starting it once instead of once per step is most of the
/// difference between a step taking four seconds and taking one.
public final class StreamSession: @unchecked Sendable {
    public let model: String
    private let lock = NSLock()
    private var buffer = Data()
    private var stderr = ""
    private var pending: (continuation: CheckedContinuation<JSON, Error>, timer: DispatchWorkItem)?
    private var alive_ = true
    private var child: CliProcess!

    /// False once the process has stopped or been closed.
    public var alive: Bool { lock.withLock { alive_ } && child.isRunning }

    /// Starts `bin` in a neutral directory: the planner must not pick up the
    /// CLAUDE.md or settings of whatever project the user happens to be sitting in.
    public init(model: String, bin: String, args: [String], env: [String: String]) throws {
        self.model = model
        child = try CliProcess(
            bin: bin, args: args, cwd: Path.tmp, env: env,
            onStdout: { [weak self] data in self?.read(data) },
            onStderr: { [weak self] data in
                guard let self else { return }
                self.lock.withLock { self.stderr = (self.stderr + String(decoding: data, as: UTF8.self)).jsSlice(-2000) }
            },
            onClose: { [weak self] code in
                guard let self else { return }
                self.lock.withLock { self.alive_ = false }
                self.fail(self.said("Claude Code stopped (exit \(code.map(String.init) ?? "unknown"))"))
            }
        )
    }

    deinit { child?.kill() }

    /// What the process wrote to stderr, or `fallback` when it said nothing.
    private func said(_ fallback: String) -> MerryError {
        let text = lock.withLock { stderr }.jsTrimmed.jsSlice(-400)
        return MerryError(text.isEmpty ? fallback : text)
    }

    /// Sends one user message and waits for the result that answers it.
    public func send(_ text: String, timeoutMs: Int) async throws -> JSON {
        if !alive { throw said("Claude Code is not running") }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, Error>) in
            let timer = DispatchWorkItem { [weak self] in
                self?.fail(MerryError("Claude Code took longer than \(Int((Double(timeoutMs) / 1000).rounded()))s to answer"))
                self?.close()
            }
            let refused: String? = lock.withLock {
                if !alive_ { return "Claude Code is not running" }
                if pending != nil { return "a planning step is already in flight" }
                pending = (continuation, timer)
                return nil
            }
            if let refused {
                continuation.resume(throwing: MerryError(refused))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timer)
            let line: JSON = ["type": "user", "message": ["role": "user", "content": .string(text)]]
            child.write(line.stringify() + "\n")
        }
    }

    public func close() {
        lock.withLock { alive_ = false }
        child.end()
        child.kill()
    }

    private func read(_ chunk: Data) {
        var results: [JSON] = []
        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).jsTrimmed
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.isEmpty { continue }
            guard let message = strictJSON(line) else { continue }
            // Everything before the result (system init, assistant turns) is
            // progress; the result carries the same envelope as --output-format json.
            if message["type"]?.stringValue == "result" { results.append(message) }
        }
        lock.unlock()
        for message in results {
            let waiting = lock.withLock { let p = pending; pending = nil; return p }
            guard let waiting else { continue }
            waiting.timer.cancel()
            waiting.continuation.resume(returning: message)
        }
    }

    private func fail(_ error: Error) {
        let waiting = lock.withLock { let p = pending; pending = nil; return p }
        guard let waiting else { return }
        waiting.timer.cancel()
        waiting.continuation.resume(throwing: error)
    }
}

/// Finds the `claude` binary.
public func resolveBin() throws -> String {
    try resolveBinary("claude", "MERRY_CLAUDE_BIN", "Claude Code", [Path.join(ProcessInfo.processInfo.environment["HOME"] ?? "", ".claude/local/claude")])
}

/// True when the CLI is present, used to offer the option only when it works.
public func claudeCodeAvailable() -> Bool {
    (try? resolveBin()) != nil
}

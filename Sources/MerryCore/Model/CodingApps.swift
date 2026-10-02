import Foundation

// Codex and OpenCode, as planners.
//
// Neither keeps a process open between messages the way Claude Code's
// stream mode does, so each step is one call with the conversation replayed
// from Merry's own transcript. Each runs in a scratch folder of its own, so
// no project's instructions or settings join in.

private let TIMEOUT_MS = 180_000

/// A folder of its own for one task, removed when the task ends.
func scratchFolder(_ prefix: String) -> String {
    let dir = Path.join(Path.tmp, prefix + String(newId().replacingOccurrences(of: "-", with: "").prefix(6)))
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// `codex exec`, read-only and ephemeral. Codex has no switch for its own
/// tools, so its sandbox is read-only and it is told it only plans; it never
/// saves the session (`--ephemeral`), and its final message is read from the
/// file `-o` writes rather than parsed out of its progress output.
public final class CodexPlanner: CliPlanner, @unchecked Sendable {
    public override var label: String { "Codex" }
    private let dir = scratchFolder("merry-codex-")
    private let model: String
    private let bin: String?
    private let timeoutMs: Int

    /// `bin` overrides binary discovery; `timeoutMs` the three minutes a step may take.
    public init(_ model: String = "", bin: String? = nil, timeoutMs: Int? = nil) {
        self.model = model
        self.bin = bin
        self.timeoutMs = timeoutMs ?? TIMEOUT_MS
        super.init()
    }

    public override func holdsConversation() -> Bool { false }

    static func arguments(model: String, out: String) -> [String] {
        ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "-o", out] + (model.isEmpty ? [] : ["-m", model]) + ["-"]
    }

    public override func exchange(_ message: String) async throws -> CliReply {
        let out = Path.join(dir, "reply.txt")
        try? FileManager.default.removeItem(atPath: out)
        _ = try await runOnce(try bin ?? resolveCodex(), CodexPlanner.arguments(model: model, out: out), cwd: dir, input: message, timeoutMs: timeoutMs, label: "Codex")
        guard let data = FileManager.default.contents(atPath: out) else {
            throw MerryError("Codex finished without a reply.")
        }
        return CliReply(result: String(decoding: data, as: UTF8.self), inputTokens: 0, outputTokens: 0)
    }

    public override func dispose() {
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// `opencode run`, in a folder whose opencode.json denies every tool, so it
/// can only answer.
public final class OpenCodePlanner: CliPlanner, @unchecked Sendable {
    public override var label: String { "OpenCode" }
    private let dir = scratchFolder("merry-opencode-")
    private let model: String
    private let bin: String?
    private let timeoutMs: Int

    /// `bin` overrides binary discovery; `timeoutMs` the three minutes a step may take.
    public init(_ model: String = "", bin: String? = nil, timeoutMs: Int? = nil) {
        self.model = model
        self.bin = bin
        self.timeoutMs = timeoutMs ?? TIMEOUT_MS
        super.init()
        let config: JSON = ["$schema": "https://opencode.ai/config.json", "permission": ["*": "deny"]]
        try? config.stringify(indent: 2).write(toFile: Path.join(dir, "opencode.json"), atomically: true, encoding: .utf8)
    }

    public override func holdsConversation() -> Bool { false }

    static func arguments(model: String, message: String) -> [String] {
        ["run"] + (model.isEmpty ? [] : ["-m", model]) + [message]
    }

    public override func exchange(_ message: String) async throws -> CliReply {
        let result = try await runOnce(try bin ?? resolveOpenCode(), OpenCodePlanner.arguments(model: model, message: message), cwd: dir, timeoutMs: timeoutMs, label: "OpenCode")
        return CliReply(result: result, inputTokens: 0, outputTokens: 0)
    }

    public override func dispose() {
        try? FileManager.default.removeItem(atPath: dir)
    }
}

public func resolveCodex() throws -> String {
    try resolveBinary("codex", "MERRY_CODEX_BIN", "Codex")
}

public func resolveOpenCode() throws -> String {
    try resolveBinary("opencode", "MERRY_OPENCODE_BIN", "OpenCode", [Path.join(ProcessInfo.processInfo.environment["HOME"] ?? "", ".opencode/bin/opencode")])
}

public let CODING_APP_LABELS: [CodingApp: String] = [.claudeCode: "Claude Code", .codex: "Codex", .opencode: "OpenCode"]

/// Which coding apps are on this Mac.
public func codingAppStatus() -> [CodingAppStatus] {
    [
        CodingAppStatus(id: .claudeCode, label: CODING_APP_LABELS[.claudeCode]!, available: claudeCodeAvailable()),
        CodingAppStatus(id: .codex, label: CODING_APP_LABELS[.codex]!, available: (try? resolveCodex()) != nil),
        CodingAppStatus(id: .opencode, label: CODING_APP_LABELS[.opencode]!, available: (try? resolveOpenCode()) != nil)
    ]
}

public func codingAppAvailable(_ app: CodingApp) -> Bool {
    codingAppStatus().first { $0.id == app }?.available ?? false
}

/// The planner for a coding app, with the model the user chose for it.
public func createCodingAppPlanner(_ app: CodingApp, _ model: ModelConfig) -> PlannerLike {
    switch app {
    case .codex: return CodexPlanner(model.codex)
    case .opencode: return OpenCodePlanner(model.opencode)
    case .claudeCode: return ClaudeCodePlanner(ClaudeCodeOptions(model: model.claudeCode))
    }
}

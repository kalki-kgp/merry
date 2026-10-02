import Foundation

// A workflow is a task shape we understand well enough to run without a
// planning model: local code enumerates the options, and Jev makes the
// judgment calls between them.
//
// The rule that keeps this honest: a workflow may only ever ask Jev to choose
// between alternatives that local code has already constructed. If a step
// needs a value invented (a sentence, a novel path, an unfamiliar plan), it
// does not belong in a workflow, and the task goes to the planner instead.

/// What came of running a tool through the full validate → verify → undo path.
public struct WorkflowRun: Sendable {
    public var ok: Bool
    public var result: JSON?
    public var error: String?
    public init(ok: Bool, result: JSON? = nil, error: String? = nil) { self.ok = ok; self.result = result; self.error = error }
}

/// What a workflow may do with memory. Everything is a no-op when memory is off.
public struct MemoryAccess: Sendable {
    public var enabled: Bool
    /// Whether Merry may learn from what the user does, not only from what they say.
    public var learn: Bool
    public var all: @Sendable () -> [Memory]
    /// Saves (or folds into an existing one). Returns nil when refused.
    public var keep: @Sendable (Memory) -> Memory?
    public var forget: @Sendable ([String]) -> Void
    /// Marks a memory as used for this task, and shows it in the result.
    public var used: @Sendable (Memory) -> Evidence

    public init(enabled: Bool = false, learn: Bool = false, all: @escaping @Sendable () -> [Memory] = { [] },
                keep: @escaping @Sendable (Memory) -> Memory? = { _ in nil }, forget: @escaping @Sendable ([String]) -> Void = { _ in },
                used: @escaping @Sendable (Memory) -> Evidence = { .text("From memory", $0.text) }) {
        self.enabled = enabled; self.learn = learn; self.all = all; self.keep = keep; self.forget = forget; self.used = used
    }
}

public struct WorkflowContext: Sendable {
    public var task: @Sendable () -> TaskState
    /// Runs a registered tool through the full validate → verify → undo path.
    public var run: @Sendable (String, JSON) async throws -> WorkflowRun
    /// Poses declared questions to Jev. Returns nil when Jev is unavailable.
    public var ask: @Sendable (String, JSON, [(String, JevQuestion)]) async -> [String: JevAnswer]?
    /// Pauses for the user; same mechanism the planner path uses.
    public var askUser: @Sendable (QuestionDraft) async throws -> UserAnswer
    public var progress: @Sendable (String) -> Void
    public var log: @Sendable (LogEntry.Level, String, JSON?) -> Void
    public var checkpoint: @Sendable () async throws -> Void
    /// Folders this task may already work in, from drops or prior grants.
    public var authorizedRoots: @Sendable () -> [String]
    /// How the request was read: kind, size, time, place. Computed once.
    public var understanding: @Sendable () -> Understanding
    public var memory: MemoryAccess

    public init(
        task: @escaping @Sendable () -> TaskState,
        run: @escaping @Sendable (String, JSON) async throws -> WorkflowRun,
        ask: @escaping @Sendable (String, JSON, [(String, JevQuestion)]) async -> [String: JevAnswer]? = { _, _, _ in nil },
        askUser: @escaping @Sendable (QuestionDraft) async throws -> UserAnswer = { _ in UserAnswer() },
        progress: @escaping @Sendable (String) -> Void = { _ in },
        log: @escaping @Sendable (LogEntry.Level, String, JSON?) -> Void = { _, _, _ in },
        checkpoint: @escaping @Sendable () async throws -> Void = {},
        authorizedRoots: @escaping @Sendable () -> [String] = { [] },
        understanding: @escaping @Sendable () -> Understanding = { fallbackUnderstanding() },
        memory: MemoryAccess = MemoryAccess()
    ) {
        self.task = task; self.run = run; self.ask = ask; self.askUser = askUser; self.progress = progress; self.log = log
        self.checkpoint = checkpoint; self.authorizedRoots = authorizedRoots; self.understanding = understanding; self.memory = memory
    }

    public func log(_ level: LogEntry.Level, _ message: String) { log(level, message, nil) }
}

public struct WorkflowResult: Sendable {
    public var success: Bool
    public var headline: String
    public var evidence: [Evidence]
    /// Set when the workflow declined to handle the request after all.
    public var handoffToPlanner: String?
    public var unresolved: String?

    public init(success: Bool, headline: String, evidence: [Evidence] = [], handoffToPlanner: String? = nil, unresolved: String? = nil) {
        self.success = success; self.headline = headline; self.evidence = evidence; self.handoffToPlanner = handoffToPlanner; self.unresolved = unresolved
    }
}

public struct Workflow: Sendable {
    public var id: String
    /// Shown to Jev as a routing option; written as a description of the job.
    public var description: String
    /// Which routes this workflow may run on.
    ///
    /// Keyword matching alone is not enough to claim a request: "open youtube
    /// and search for a good video" matches the file-finder's keywords, and
    /// without this gate it searched the Downloads folder for a video. The
    /// route, decided by local rules, or by Jev when they are unsure, has the
    /// final say over what kind of work a request is.
    public var routes: [String]
    /// A cheap local check that this workflow could plausibly apply, used to
    /// narrow the routing choices before Jev sees them.
    public var plausible: @Sendable (_ request: String, _ droppedPaths: [String]) -> Bool
    public var run: @Sendable (_ request: String, _ droppedPaths: [String], _ ctx: WorkflowContext) async throws -> WorkflowResult

    public init(id: String, description: String, routes: [String],
                plausible: @escaping @Sendable (String, [String]) -> Bool,
                run: @escaping @Sendable (String, [String], WorkflowContext) async throws -> WorkflowResult) {
        self.id = id; self.description = description; self.routes = routes; self.plausible = plausible; self.run = run
    }
}

func plural(_ n: Int, _ word: String, _ ending: String = "s") -> String { n == 1 ? word : word + ending }

/// The task was stopped by the person. It unwinds the loop from wherever it is.
public struct CancelledError: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "task cancelled" }
}

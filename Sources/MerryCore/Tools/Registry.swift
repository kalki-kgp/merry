import Foundation

/// Merry's own browser, separate from the one the person uses. It has its own
/// profile and its own logins. Declared here so tools depend on what a browser
/// can do, not on how it is built; the app supplies a WebKit one.
public protocol BrowserSession: AnyObject, Sendable {
    var isOpen: Bool { get }
    func close() async

    /// Loads a URL, opening the browser window if needed. `waitUntil` is
    /// "load", "domcontentloaded" or "networkidle".
    func navigate(_ url: String, waitUntil: String, timeoutMs: Int) async throws -> BrowserNavigation
    func currentURL() async throws -> String
    func title() async throws -> String
    /// Evaluates a JavaScript expression in the page and returns its JSON value.
    func evaluate(_ script: String) async throws -> JSON
    /// Waits for a navigation that is under way to reach DOM-ready. Returns
    /// quietly when nothing is loading or the wait runs out.
    func waitForLoad(timeoutMs: Int) async
    /// Attaches a local file to the file input carrying this reference.
    func setInputFiles(ref: String, path: String, timeoutMs: Int) async throws
    /// Clicks the referenced element and waits for the download it starts.
    /// The file lands in `saveTo` when given, else the browser's own folder.
    func download(clickingRef ref: String, saveTo: String?, timeoutMs: Int) async throws -> BrowserDownload
}

public struct BrowserNavigation: Sendable {
    public var url: String
    public var status: Int?
    public var title: String
    public init(url: String, status: Int?, title: String) { self.url = url; self.status = status; self.title = title }
}

public struct BrowserDownload: Sendable {
    public var path: String
    public var suggestedFilename: String
    public init(path: String, suggestedFilename: String) { self.path = path; self.suggestedFilename = suggestedFilename }
}

/// A browser that cannot be opened. Used in tests and when no window server exists.
public final class NoBrowser: BrowserSession {
    public init() {}
    public var isOpen: Bool { false }
    public func close() async {}
    private var unavailable: MerryError { MerryError("Merry's browser is not available here.") }
    public func navigate(_ url: String, waitUntil: String, timeoutMs: Int) async throws -> BrowserNavigation { throw unavailable }
    public func currentURL() async throws -> String { throw unavailable }
    public func title() async throws -> String { throw unavailable }
    public func evaluate(_ script: String) async throws -> JSON { throw unavailable }
    public func waitForLoad(timeoutMs: Int) async {}
    public func setInputFiles(ref: String, path: String, timeoutMs: Int) async throws { throw unavailable }
    public func download(clickingRef ref: String, saveTo: String?, timeoutMs: Int) async throws -> BrowserDownload { throw unavailable }
}

/// What a tool needs from the world. Handing tools a context (rather than
/// letting them reach for globals) is what makes them testable and keeps the
/// privileged surface enumerable.
public struct ToolContext: Sendable {
    /// The task as it stands right now.
    public var task: @Sendable () -> TaskState
    public var os: OsAdapter
    public var browser: BrowserSession
    /// Merry's own workspace. Takes a request matching `BrainSchema.request`. Absent when unavailable.
    public var brain: (@Sendable (JSON) async throws -> BrainSnapshot)?
    public var log: @Sendable (LogEntry.Level, String, JSON?) -> Void
    /// Short line for the pet's speech bubble.
    public var progress: @Sendable (String) -> Void
    /// Records an observation on the task and returns it.
    public var observe: @Sendable (_ kind: String, _ summary: String, _ data: JSON, _ staleAfterMs: Double) -> Observation
    /// Suspends the loop until the user answers.
    public var ask: @Sendable (QuestionDraft) async throws -> UserAnswer
    /// Throws if the task has been cancelled; waits while paused.
    public var checkpoint: @Sendable () async throws -> Void
    /// Claims the exclusive desktop-control session for GUI automation.
    public var claimDesktop: @Sendable (String) async throws -> Void
    public var releaseDesktop: @Sendable () -> Void
    /// Keeps a memory for future tasks. Absent when memory is off.
    public var remember: (@Sendable (_ text: String, _ about: [String], _ toldByUser: Bool) -> (saved: Bool, reason: String?))?

    public init(
        task: @escaping @Sendable () -> TaskState,
        os: OsAdapter,
        browser: BrowserSession,
        brain: (@Sendable (JSON) async throws -> BrainSnapshot)? = nil,
        log: @escaping @Sendable (LogEntry.Level, String, JSON?) -> Void = { _, _, _ in },
        progress: @escaping @Sendable (String) -> Void = { _ in },
        observe: @escaping @Sendable (String, String, JSON, Double) -> Observation = { kind, summary, data, stale in
            Observation(id: newId(), kind: kind, summary: summary, data: data, observedAt: nowMs(), staleAfterMs: stale)
        },
        ask: @escaping @Sendable (QuestionDraft) async throws -> UserAnswer = { _ in UserAnswer() },
        checkpoint: @escaping @Sendable () async throws -> Void = {},
        claimDesktop: @escaping @Sendable (String) async throws -> Void = { _ in },
        releaseDesktop: @escaping @Sendable () -> Void = {},
        remember: (@Sendable (String, [String], Bool) -> (saved: Bool, reason: String?))? = nil
    ) {
        self.task = task; self.os = os; self.browser = browser; self.brain = brain; self.log = log; self.progress = progress
        self.observe = observe; self.ask = ask; self.checkpoint = checkpoint; self.claimDesktop = claimDesktop
        self.releaseDesktop = releaseDesktop; self.remember = remember
    }

    public func log(_ level: LogEntry.Level, _ message: String) { log(level, message, nil) }
}

public struct ToolOutcome: Sendable {
    public var result: JSON
    /// Reversible effects produced by this call.
    public var undo: [UndoEntry]
    /// Things the user can click through in the result panel.
    public var evidence: [Evidence]
    /// Set when the tool cannot tell whether the effect landed (a form submit
    /// that timed out). The loop treats these as unsafe to retry blindly.
    public var uncertain: Bool

    public init(_ result: JSON, undo: [UndoEntry] = [], evidence: [Evidence] = [], uncertain: Bool = false) {
        self.result = result; self.undo = undo; self.evidence = evidence; self.uncertain = uncertain
    }
}

/// One thing Merry can do. Inputs reach `scopes`, `confirm`, `precondition`,
/// `execute` and `verify` already parsed through `input`, so defaults are
/// filled in and the shape is guaranteed.
public struct ToolDefinition: Sendable {
    public var name: String
    /// Shown to the planning model. Written for a reader who cannot see the code.
    public var description: String
    public var input: Schema
    /// Capability name gating this tool, e.g. "files.move".
    public var capability: String
    /// True when the tool drives the user's real screen, keyboard or mouse.
    public var exclusiveDesktop: Bool
    /// Scopes derived from the concrete input, checked before execution.
    public var scopes: @Sendable (JSON) -> [ScopeRequest]
    /// For inputs no folder grant can make safe (a command that runs code): a
    /// plain description of exactly what will happen. The user is asked every
    /// time, whatever the task has already been allowed.
    public var confirm: (@Sendable (JSON) -> String?)?
    /// Cheap checks that make failure legible before anything is changed.
    public var precondition: (@Sendable (JSON, ToolContext) async throws -> Void)?
    public var execute: @Sendable (JSON, ToolContext) async throws -> ToolOutcome
    /// Independent confirmation that the effect actually happened. A tool
    /// without a verifier can never complete a task on its own.
    public var verify: (@Sendable (JSON, ToolOutcome, ToolContext) async throws -> VerificationResult)?

    public init(
        name: String,
        description: String,
        capability: String,
        input: Schema,
        exclusiveDesktop: Bool = false,
        scopes: @escaping @Sendable (JSON) -> [ScopeRequest] = { _ in [] },
        confirm: (@Sendable (JSON) -> String?)? = nil,
        precondition: (@Sendable (JSON, ToolContext) async throws -> Void)? = nil,
        execute: @escaping @Sendable (JSON, ToolContext) async throws -> ToolOutcome,
        verify: (@Sendable (JSON, ToolOutcome, ToolContext) async throws -> VerificationResult)? = nil
    ) {
        self.name = name; self.description = description; self.capability = capability; self.input = input
        self.exclusiveDesktop = exclusiveDesktop; self.scopes = scopes; self.confirm = confirm
        self.precondition = precondition; self.execute = execute; self.verify = verify
    }
}

public final class ToolRegistry: @unchecked Sendable {
    private var order: [String] = []
    private var tools: [String: ToolDefinition] = [:]

    public init() {}

    public init(_ tools: [ToolDefinition]) { registerAll(tools) }

    public func register(_ tool: ToolDefinition) {
        precondition(tools[tool.name] == nil, "duplicate tool: \(tool.name)")
        tools[tool.name] = tool
        order.append(tool.name)
    }

    public func registerAll(_ list: [ToolDefinition]) {
        for t in list { register(t) }
    }

    public func get(_ name: String) -> ToolDefinition? { tools[name] }
    public func has(_ name: String) -> Bool { tools[name] != nil }

    /// Tools offered for one task. Availability is scoped deliberately: a task
    /// that only sorts files is never shown the browser tools.
    public func forTask(_ allowedCapabilities: [String]) -> [ToolDefinition] {
        all().filter { t in
            allowedCapabilities.contains { c in c == t.capability || c == "*" || t.capability.hasPrefix("\(c).") }
        }
    }

    /// Every tool, in the order it was registered.
    public func all() -> [ToolDefinition] { order.map { tools[$0]! } }

    /// The tool-use schema sent to the planning model.
    public func toModelSchema(_ tools: [ToolDefinition]) -> [JSON] {
        tools.map { ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.input.jsonSchema()] }
    }
}

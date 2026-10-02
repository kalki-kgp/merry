import Foundation

// Core domain types, shared by the runtime, the stores and the interface.
// Field names match the reference's JSON so saved tasks read the same way.

/// Runtime state of the pet. The sprite is driven from this, never faked.
public enum PetState: String, Codable, Sendable {
    case idle, listening, thinking, working, waiting, finished, failed
}

public enum TaskStatus: String, Codable, Sendable {
    case pending, observing, planning
    case awaitingUser = "awaiting_user"
    case executing, verifying, paused, succeeded, failed, cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

/// What the user has authorized for one task. This is *task authorization*,
/// deliberately separate from OS-level permission grants. A tool call is only
/// executed when it falls inside this grant.
public struct Authorization: Codable, Equatable, Sendable {
    /// Absolute directory paths the task may read.
    public var readRoots: [String] = []
    /// Absolute directory paths the task may create, move and rename inside.
    public var writeRoots: [String] = []
    /// App names the task may drive.
    public var apps: [String] = []
    /// Origins the managed browser may visit, or ["*"] once the user opts in.
    public var origins: [String] = []
    /// Capability names the task may use without a further prompt.
    public var capabilities: [String] = []

    public init(readRoots: [String] = [], writeRoots: [String] = [], apps: [String] = [], origins: [String] = [], capabilities: [String] = []) {
        self.readRoots = readRoots; self.writeRoots = writeRoots; self.apps = apps; self.origins = origins; self.capabilities = capabilities
    }
}

/// A grant the user approved: any subset of an authorization.
public struct AuthorizationGrant: Codable, Equatable, Sendable {
    public var readRoots: [String]?
    public var writeRoots: [String]?
    public var apps: [String]?
    public var origins: [String]?
    public var capabilities: [String]?

    public init(readRoots: [String]? = nil, writeRoots: [String]? = nil, apps: [String]? = nil, origins: [String]? = nil, capabilities: [String]? = nil) {
        self.readRoots = readRoots; self.writeRoots = writeRoots; self.apps = apps; self.origins = origins; self.capabilities = capabilities
    }
}

/// Hard bounds enforced by local code, never by the model.
public struct TaskLimits: Codable, Equatable, Sendable {
    public var maxSteps = 40
    public var maxWallClockMs: Double = 10 * 60 * 1000
    public var maxUsd = 1.5
    public var maxConsecutiveFailures = 3

    public init(maxSteps: Int = 40, maxWallClockMs: Double = 10 * 60 * 1000, maxUsd: Double = 1.5, maxConsecutiveFailures: Int = 3) {
        self.maxSteps = maxSteps; self.maxWallClockMs = maxWallClockMs; self.maxUsd = maxUsd; self.maxConsecutiveFailures = maxConsecutiveFailures
    }
}

/// A timestamped fact the runtime gathered about the machine.
public struct Observation: Codable, Sendable {
    public var id: String
    /// files | window | page | screen | user
    public var kind: String
    /// Human summary shown in the activity log.
    public var summary: String
    /// Structured payload the model may read. Kept small on purpose.
    public var data: JSON
    public var observedAt: Double
    /// Milliseconds after which this observation must be refreshed before use.
    public var staleAfterMs: Double

    public init(id: String, kind: String, summary: String, data: JSON, observedAt: Double, staleAfterMs: Double) {
        self.id = id; self.kind = kind; self.summary = summary; self.data = data; self.observedAt = observedAt; self.staleAfterMs = staleAfterMs
    }

    public func isStale(now: Double = nowMs()) -> Bool { now - observedAt > staleAfterMs }
}

public struct PlanStep: Codable, Sendable {
    public var id: String
    public var description: String
    /// pending | active | done | skipped | failed
    public var status: String
}

public struct VerificationResult: Codable, Equatable, Sendable {
    public var verified: Bool
    public var method: String
    public var detail: String

    public init(verified: Bool, method: String, detail: String) {
        self.verified = verified; self.method = method; self.detail = detail
    }
}

/// A reversible effect. Recorded only for operations that can genuinely be
/// reversed; there is no universal undo.
public struct UndoEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fileMove = "file.move"
        case fileRename = "file.rename"
        case folderCreate = "folder.create"
        case macEvent = "mac.event"
        case macReminder = "mac.reminder"
        case macNote = "mac.note"
        case macSetting = "mac.setting"

        public var isMac: Bool { rawValue.hasPrefix("mac.") }
    }

    public struct Payload: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public var kind: Kind
    /// Enough to reverse the operation and to detect conflicts. For app items
    /// `from` is the app and `to` is the id it gave the item; for a setting,
    /// `from` names the setting and `to` holds its previous value.
    public var payload: Payload
    public var reversed: Bool?

    public init(kind: Kind, from: String, to: String) {
        self.kind = kind; self.payload = Payload(from: from, to: to)
    }
}

/// One executed tool call and what actually happened.
public struct ActionRecord: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case success, failure, uncertain }

    public var id: String
    public var step: Int
    public var tool: String
    public var input: JSON
    public var startedAt: Double
    public var finishedAt: Double?
    public var outcome: Outcome
    /// Present on success.
    public var result: JSON?
    /// Present on failure.
    public var error: String?
    /// Result of the tool's own verification pass.
    public var verification: VerificationResult?
    /// Set when the action is reversible; consumed by the undo system.
    public var undo: UndoEntry?

    public init(id: String, step: Int, tool: String, input: JSON, startedAt: Double, outcome: Outcome) {
        self.id = id; self.step = step; self.tool = tool; self.input = input; self.startedAt = startedAt; self.outcome = outcome
    }
}

/// Something Merry knows about the person, kept on this Mac.
///
/// Told memories are things they said. Learned ones come from what they do: a
/// choice they made, like which calendar standups go on. Either kind reaches a
/// task only when it is relevant to that task.
public struct Memory: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var decision: String
        public var value: String
        public init(decision: String, value: String) { self.decision = decision; self.value = value }
    }

    public var id: String
    /// One plain sentence, the way the person would say it.
    public var text: String
    /// fact | preference | choice
    public var kind: String
    /// Words that make it relevant: names, places, apps, topics. Lower case.
    public var keys: [String]
    /// For a learned default: which decision it answers, and with what.
    public var choice: Choice?
    /// told | learned
    public var source: String
    /// Times it was seen or confirmed.
    public var evidence: Int
    public var createdAt: Double
    public var updatedAt: Double
    public var lastUsedAt: Double?
    public var uses: Int

    public init(id: String, text: String, kind: String, keys: [String], choice: Choice? = nil, source: String, evidence: Int, createdAt: Double, updatedAt: Double, lastUsedAt: Double? = nil, uses: Int = 0) {
        self.id = id; self.text = text; self.kind = kind; self.keys = keys; self.choice = choice; self.source = source
        self.evidence = evidence; self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastUsedAt = lastUsedAt; self.uses = uses
    }

    // `lastUsedAt` is written as null rather than left out, as the reference does.
    enum CodingKeys: String, CodingKey { case id, text, kind, keys, choice, source, evidence, createdAt, updatedAt, lastUsedAt, uses }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(text, forKey: .text); try c.encode(kind, forKey: .kind); try c.encode(keys, forKey: .keys)
        try c.encodeIfPresent(choice, forKey: .choice); try c.encode(source, forKey: .source); try c.encode(evidence, forKey: .evidence)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt); try c.encode(lastUsedAt, forKey: .lastUsedAt); try c.encode(uses, forKey: .uses)
    }
}

public struct CostRecord: Codable, Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var usd = 0.0
    public var calls = 0
    public init(inputTokens: Int = 0, outputTokens: Int = 0, usd: Double = 0, calls: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.usd = usd; self.calls = calls
    }
}

public struct FileOp: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var kind: String
    public init(from: String, to: String, kind: String) { self.from = from; self.to = to; self.kind = kind }
}

public struct PreviewPayload: Codable, Equatable, Sendable {
    public var title: String
    /// Proposed file operations, shown as a before/after list.
    public var fileOps: [FileOp]?
    public var note: String?
    public init(title: String, fileOps: [FileOp]? = nil, note: String? = nil) { self.title = title; self.fileOps = fileOps; self.note = note }
}

public struct QuestionOption: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?
    public init(id: String, label: String, detail: String? = nil) { self.id = id; self.label = label; self.detail = detail }
}

public struct UserQuestion: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case ambiguous, authorization, blocked }

    public var id: String
    /// Why the runtime stopped: an ambiguity, or an authorization gap.
    public var reason: Reason
    public var prompt: String
    public var options: [QuestionOption]?
    /// A preview of the change being proposed, when there is one.
    public var preview: PreviewPayload?
    /// Free text is accepted when true.
    public var allowFreeText: Bool

    public init(id: String, reason: Reason, prompt: String, options: [QuestionOption]? = nil, preview: PreviewPayload? = nil, allowFreeText: Bool) {
        self.id = id; self.reason = reason; self.prompt = prompt; self.options = options; self.preview = preview; self.allowFreeText = allowFreeText
    }
}

/// A question before it has been given an id: what tools and workflows pose.
public struct QuestionDraft: Sendable {
    public var reason: UserQuestion.Reason
    public var prompt: String
    public var options: [QuestionOption]?
    public var preview: PreviewPayload?
    public var allowFreeText: Bool

    public init(reason: UserQuestion.Reason, prompt: String, allowFreeText: Bool, options: [QuestionOption]? = nil, preview: PreviewPayload? = nil) {
        self.reason = reason; self.prompt = prompt; self.options = options; self.preview = preview; self.allowFreeText = allowFreeText
    }
}

/// What the person answered: a chosen option, free text, or both.
public struct UserAnswer: Sendable, Equatable {
    public var optionId: String?
    public var text: String?
    public init(optionId: String? = nil, text: String? = nil) { self.optionId = optionId; self.text = text }
}

public struct Evidence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case path, url, text }
    public var kind: Kind
    public var label: String
    public var value: String
    public init(kind: Kind, label: String, value: String) { self.kind = kind; self.label = label; self.value = value }
    public static func path(_ label: String, _ value: String) -> Evidence { Evidence(kind: .path, label: label, value: value) }
    public static func url(_ label: String, _ value: String) -> Evidence { Evidence(kind: .url, label: label, value: value) }
    public static func text(_ label: String, _ value: String) -> Evidence { Evidence(kind: .text, label: label, value: value) }
}

public struct TaskSummary: Codable, Equatable, Sendable {
    public var headline: String
    /// Evidence the user can click through: folders, files, URLs.
    public var evidence: [Evidence]
    public var undoable: Bool
    public init(headline: String, evidence: [Evidence] = [], undoable: Bool = false) {
        self.headline = headline; self.evidence = evidence; self.undoable = undoable
    }
}

public struct TaskState: Codable, Sendable {
    public var id: String
    /// Verbatim user instruction.
    public var request: String
    /// The restatement of the outcome, confirmed against the request.
    public var outcome: String
    public var status: TaskStatus
    public var petState: PetState
    public var authorization: Authorization
    public var limits: TaskLimits
    public var observations: [Observation]
    public var plan: [PlanStep]
    public var actions: [ActionRecord]
    public var cost: CostRecord
    /// Criteria the verifier checks before the task may be called complete.
    public var completionCriteria: [String]
    /// Short status line shown in the pet's speech bubble.
    public var statusLine: String
    public var createdAt: Double
    public var updatedAt: Double
    /// The turn this one replied to, so a conversation can be put back together.
    public var replyTo: String?
    /// The chat this turn belongs to: the id of its first turn. Absent means it started one.
    public var conversationId: String?
    /// Set when status is awaiting_user.
    public var question: UserQuestion?
    /// Set when status is terminal.
    public var summary: TaskSummary?
    public var error: String?
    /// Paths dropped onto the pet or attached in the panel for this task.
    public var droppedPaths: [String]?
    /// What kind of work the request was read as: files, apps, browser, desktop, mixed or unclear.
    public var route: String?

    public init(id: String = UUID().uuidString.lowercased(), request: String, authorization: Authorization = Authorization(), limits: TaskLimits = TaskLimits(), now: Double = nowMs()) {
        self.id = id
        self.request = request
        self.outcome = ""
        self.status = .pending
        self.petState = .thinking
        self.authorization = authorization
        self.limits = limits
        self.observations = []
        self.plan = []
        self.actions = []
        self.cost = CostRecord()
        self.completionCriteria = []
        self.statusLine = "Getting started"
        self.createdAt = now
        self.updatedAt = now
    }
}

/// OS-level permission grants, distinct from per-task authorization.
public enum OsPermission: String, Codable, Sendable {
    case accessibility
    case screenRecording = "screen-recording"
    case automation
    case fullDisk = "full-disk"
}

public struct PermissionStatus: Codable, Equatable, Sendable {
    public var permission: OsPermission
    public var granted: Bool
    /// Why Merry needs it, shown verbatim in the interface.
    public var purpose: String
    public init(permission: OsPermission, granted: Bool, purpose: String) {
        self.permission = permission; self.granted = granted; self.purpose = purpose
    }
}

/// A new random id, in the lower-case form `crypto.randomUUID()` gives.
public func newId() -> String { UUID().uuidString.lowercased() }

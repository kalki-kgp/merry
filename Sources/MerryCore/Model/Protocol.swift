import Foundation

// What the interface, the stores and the runtime say to each other.

public struct LogEntry: Codable, Sendable {
    public enum Level: String, Codable, Sendable { case debug, info, warn, error }
    public var taskId: String
    public var at: Double
    public var level: Level
    /// Which subsystem produced this: "loop", "tool:files_move", "model", …
    public var source: String
    public var message: String
    public var data: JSON?

    public init(taskId: String, at: Double = nowMs(), level: Level, source: String, message: String, data: JSON? = nil) {
        self.taskId = taskId; self.at = at; self.level = level; self.source = source; self.message = message; self.data = data
    }
}

/// The exchange immediately before this one, when it was recent enough to matter.
public struct PreviousTurn: Codable, Sendable {
    public struct Earlier: Codable, Sendable {
        public var request: String
        public var headline: String
        public init(request: String, headline: String) { self.request = request; self.headline = headline }
    }
    public var request: String
    public var headline: String
    public var secondsAgo: Int
    /// The person chose to reply in this conversation, rather than it being recent.
    public var explicit: Bool?
    /// Turns before that one in the same chat, oldest first.
    public var earlier: [Earlier]?

    public init(request: String, headline: String, secondsAgo: Int, explicit: Bool? = nil, earlier: [Earlier]? = nil) {
        self.request = request; self.headline = headline; self.secondsAgo = secondsAgo; self.explicit = explicit; self.earlier = earlier
    }
}

/// The window that was frontmost before Merry's own panel took focus.
public struct FrontWindow: Codable, Equatable, Sendable {
    public var pid: Int
    public var name: String
    public var title: String
    public init(pid: Int, name: String, title: String) { self.pid = pid; self.name = name; self.title = title }
}

/// The coding apps on this Mac that Merry can plan through, using their own login.
public enum CodingApp: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case opencode
}

public struct ModelConfig: Codable, Equatable, Sendable {
    /// Planning model, called through the Anthropic API.
    public var planner = "claude-sonnet-5-5"
    /// Jev model id, called through the TypeSafe AI API.
    public var jev = "jev-latest"
    /// Model alias used when planning through the local Claude Code CLI.
    public var claudeCode = "sonnet"
    /// Codex model; empty means whatever Codex is configured to use.
    public var codex = ""
    /// OpenCode model as provider/model; empty means its configured default.
    public var opencode = ""
    public var maxTokens = 16000

    public init() {}
}

public struct CodingAppStatus: Codable, Equatable, Sendable {
    public var id: CodingApp
    public var label: String
    public var available: Bool
    public init(id: CodingApp, label: String, available: Bool) { self.id = id; self.label = label; self.available = available }
}

public struct CodingModel: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// Only true when the CLI explicitly reports zero input and output prices.
    public var free: Bool?
    public var recommended: Bool?
    public var recommendation: String?
    public var description: String?
    public var resolvedModel: String?
    /// listed | unavailable | verified. Listed is not a guarantee of entitlement or remaining quota.
    public var access: String?
    public var reason: String?
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct CodingModelCatalog: Codable, Equatable, Sendable {
    public var models: [CodingModel]
    public var note: String
    public var connection: String?
    public var defaultModel: String?
    public init(models: [CodingModel], note: String, connection: String? = nil, defaultModel: String? = nil) {
        self.models = models; self.note = note; self.connection = connection; self.defaultModel = defaultModel
    }
}

public struct CodingModelCheck: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    /// Only definitive access failures disable a choice; network errors can be retried.
    public var unavailable: Bool?
    public var resolvedModel: String?
    public init(ok: Bool, message: String, unavailable: Bool? = nil, resolvedModel: String? = nil) {
        self.ok = ok; self.message = message; self.unavailable = unavailable; self.resolvedModel = resolvedModel
    }
}

/// Model ids are passed as a single argv value, never as shell code.
public func validCodingModel(_ value: String) -> Bool {
    Rx("^(?!-)[A-Za-z0-9._/:@#\\[\\]+-]{0,256}$").test(value)
}

/// A memory was saved, forgotten or used by a task. The host persists it.
public enum MemoryEvent: Sendable {
    case save(memory: Memory, replaces: String?)
    case forget(ids: [String])
    case used(ids: [String])
}

/// One measured path, with what it cost in time and money.
public struct BenchRow: Codable, Equatable, Sendable {
    public var group: String
    public var label: String
    public var ms: Double
    public var detail: String
    public var usd: Double?
    public init(group: String, label: String, ms: Double, detail: String, usd: Double? = nil) {
        self.group = group; self.label = label; self.ms = ms; self.detail = detail; self.usd = usd
    }
}

public struct UndoReport: Codable, Equatable, Sendable {
    public struct Skipped: Codable, Equatable, Sendable {
        public var path: String
        public var reason: String
        public init(path: String, reason: String) { self.path = path; self.reason = reason }
    }
    public var reversed = 0
    public var skipped: [Skipped] = []
    public init() {}
}

public struct TaskSummaryRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var request: String
    public var status: TaskStatus
    public var headline: String
    public var createdAt: Double
    public var undoable: Bool
    /// How many turns the chat has. A History row is a chat, not a single message.
    public var turns: Int
}

/// Where a permission lives, which is also how onboarding groups them.
public enum SetupGroup: String, Codable, Sendable { case control, apps, browsers, folders, alerts }

/// `asked` is for the one macOS answer Merry cannot read back (notifications):
/// the question was put, and the person can see whether it arrived.
public enum SetupStatus: String, Codable, Sendable {
    case granted, denied
    case notAsked = "not-asked"
    case asked
    case notInstalled = "not-installed"
    case unknown
}

/// One thing Merry can be allowed to do on this Mac.
public struct SetupItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var group: SetupGroup
    public var label: String
    /// What it unlocks, in one plain sentence.
    public var purpose: String
    public var status: SetupStatus
    /// A step the person takes themselves, outside macOS's own permission dialogs.
    public var hint: String?
    public init(id: String, group: SetupGroup, label: String, purpose: String, status: SetupStatus, hint: String? = nil) {
        self.id = id; self.group = group; self.label = label; self.purpose = purpose; self.status = status; self.hint = hint
    }
}

public enum PetMode: String, Codable, Sendable { case ondemand, peek, menubar, desktop }

public struct Settings: Codable, Equatable, Sendable {
    /// The first-run setup has been finished or skipped.
    public var onboarded = false
    public var launchAtLogin = false
    /// Global shortcut, written like "Command+Shift+Space".
    public var shortcut = "Command+Shift+Space"
    /// An explicitly chosen shortcut survives default shortcut migrations.
    public var shortcutChosen: Bool?
    /// Per-task spend ceiling in USD.
    public var maxUsdPerTask = 1.5
    /// Whether Jev (fast structured decisions) is enabled.
    public var jevEnabled = true
    /// Handle known task shapes with code plus Jev, with no planning model call.
    public var workflowsFirst = true
    /// Ask before every action, even inside an existing authorization.
    public var confirmEveryAction = false
    /// Little unprompted remarks from the pet.
    public var chatty = true
    public var petMode: PetMode = .ondemand
    /// The person picked petMode themselves; until then the default applies.
    public var petModeChosen: Bool?
    /// Plan with a coding app on this Mac instead of an Anthropic API key. The
    /// name is kept from when Claude Code was the only one.
    public var useClaudeCode = false
    public var codingApp: CodingApp = .claudeCode
    public var claudeCodeModel = "sonnet"
    public var codexModel = ""
    public var opencodeModel = ""
    public var petX: Double = -1
    public var petY: Double = -1
    /// Where the user last left the panel; -1 means it has never been placed.
    public var panelX: Double = -1
    public var panelY: Double = -1
    /// Whether the panel floats above other applications.
    public var panelPinned = false
    /// Remember things about the person across tasks.
    public var memoryEnabled = true
    /// Also learn from what they do, not only from what they say.
    public var memoryLearn = true

    public init() {}

    // Decoding fills anything a saved copy lacks from the defaults, so a
    // setting added later never invalidates what was saved before it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = Settings()
        onboarded = get(.onboarded, d.onboarded)
        launchAtLogin = get(.launchAtLogin, d.launchAtLogin)
        shortcut = get(.shortcut, d.shortcut)
        shortcutChosen = try? c.decodeIfPresent(Bool.self, forKey: .shortcutChosen)
        maxUsdPerTask = get(.maxUsdPerTask, d.maxUsdPerTask)
        jevEnabled = get(.jevEnabled, d.jevEnabled)
        workflowsFirst = get(.workflowsFirst, d.workflowsFirst)
        confirmEveryAction = get(.confirmEveryAction, d.confirmEveryAction)
        chatty = get(.chatty, d.chatty)
        petMode = get(.petMode, d.petMode)
        petModeChosen = try? c.decodeIfPresent(Bool.self, forKey: .petModeChosen)
        useClaudeCode = get(.useClaudeCode, d.useClaudeCode)
        codingApp = get(.codingApp, d.codingApp)
        claudeCodeModel = get(.claudeCodeModel, d.claudeCodeModel)
        codexModel = get(.codexModel, d.codexModel)
        opencodeModel = get(.opencodeModel, d.opencodeModel)
        petX = get(.petX, d.petX)
        petY = get(.petY, d.petY)
        panelX = get(.panelX, d.panelX)
        panelY = get(.panelY, d.panelY)
        panelPinned = get(.panelPinned, d.panelPinned)
        memoryEnabled = get(.memoryEnabled, d.memoryEnabled)
        memoryLearn = get(.memoryLearn, d.memoryLearn)
    }
}

/// Things to do with the pet from its menu.
public enum PetPlay: String, Sendable { case dance, nap, wake, surprise }

// MARK: - Interface requests

public struct StartTaskRequest: Sendable {
    public var request: String
    /// Paths dropped onto the pet, which seed the task's authorization.
    public var droppedPaths: [String]
    /// Set when the request came from "help me with this window".
    public var includeFrontWindow: Bool
    /// The turn this message replies to. `.reply(id)` continues that
    /// conversation, `.newChat` starts a new one, and `.unspecified` lets a
    /// recent answer be assumed as context.
    public var followUp: FollowUp

    public enum FollowUp: Sendable, Equatable {
        case unspecified
        case newChat
        case reply(String)
    }

    public init(request: String, droppedPaths: [String] = [], includeFrontWindow: Bool = false, followUp: FollowUp = .unspecified) {
        self.request = request; self.droppedPaths = droppedPaths; self.includeFrontWindow = includeFrontWindow; self.followUp = followUp
    }
}

/// An answer to a question a task is waiting on.
public struct AnswerPayload: Sendable {
    public var questionId: String
    /// Id of the chosen option, or nil when answering with free text.
    public var optionId: String?
    public var text: String?
    /// User approval of an authorization expansion, when one was requested.
    public var grant: AuthorizationGrant?

    public init(questionId: String, optionId: String?, text: String? = nil, grant: AuthorizationGrant? = nil) {
        self.questionId = questionId; self.optionId = optionId; self.text = text; self.grant = grant
    }
}

/// What the panel window is currently doing, as the interface needs to know it.
public struct PanelState: Equatable, Sendable {
    /// Collapsed to the island at the top of the screen.
    public var docked: Bool
    /// Floating above other applications.
    public var pinned: Bool
    public init(docked: Bool = false, pinned: Bool = false) { self.docked = docked; self.pinned = pinned }
}

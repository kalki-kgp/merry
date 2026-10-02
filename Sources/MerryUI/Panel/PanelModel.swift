import Combine
import Foundation
import MerryCore

/// Everything Merry can be told to do that isn't a task.
public struct PanelCommand: Equatable, Sendable {
    public var name: String
    public var hint: String

    public static let all: [PanelCommand] = [
        PanelCommand(name: "new", hint: "Start a new chat"),
        PanelCommand(name: "workspace", hint: "Notes, reminders, projects and timers"),
        PanelCommand(name: "undo", hint: "Undo file changes"),
        PanelCommand(name: "steps", hint: "Task details"),
        PanelCommand(name: "past", hint: "History"),
        PanelCommand(name: "stop", hint: "Stop task"),
        PanelCommand(name: "center", hint: "Move the panel back to the middle"),
        PanelCommand(name: "keys", hint: "Connections"),
        PanelCommand(name: "tune", hint: "Settings"),
        PanelCommand(name: "setup", hint: "Permissions and first-run setup"),
        PanelCommand(name: "bench", hint: "Diagnostics"),
        PanelCommand(name: "help", hint: "Shortcuts")
    ]

    /// What the palette offers for a draft: nothing unless it starts with a slash.
    public nonisolated static func matches(_ text: String) -> [PanelCommand] {
        guard text.hasPrefix("/") else { return [] }
        let query = text.jsSlice(1).jsTrimmed.lowercased()
        return all.filter { $0.name.hasPrefix(query) }
    }
}

/// The panel's state and everything it does with it: which page is showing,
/// the chat on screen, what is attached, and how task updates thread together.
@MainActor
public final class PanelModel: ObservableObject {
    public enum Page: String, CaseIterable, Sendable {
        case brain, home, steps, past, keys, tune, help, bench

        public var title: String {
            switch self {
            case .brain: return "Workspace"
            case .home: return "Merry"
            case .past: return "History"
            case .steps: return "Steps"
            case .tune: return "Settings"
            case .keys: return "Connections"
            case .help: return "Shortcuts"
            case .bench: return "Diagnostics"
            }
        }
    }

    /// A request to place in the composer. The id makes the same text seed twice.
    public struct Seed: Equatable, Sendable {
        public var text: String
        public var id: Int
    }

    public struct Idea: Equatable, Sendable {
        public var title: String
        public var prompt: String
        public var hint: String
    }

    /// Workspace at a glance: the timer if one is running, else what's waiting.
    public enum WorkspaceBadge: Equatable, Sendable {
        case timer(BrainTimer)
        case due(Int)
        case kept(Int)
        case hint
    }

    /// A finished chat left this long is put away: the next summon opens on a fresh launcher.
    public static let staleChatMs: Double = 10 * 60 * 1000
    /// How many earlier turns a conversation keeps on screen.
    public static let maxTurns = 8
    public static let ideas: [Idea] = [
        Idea(title: "Find", prompt: "Find ", hint: "a file, by name or what’s in it"),
        Idea(title: "Organize", prompt: "Organize my Downloads folder", hint: "a messy folder"),
        Idea(title: "Rename", prompt: "Rename these files consistently", hint: "files to one pattern")
    ]

    @Published public var view: Page = .home {
        didSet { if view != oldValue { confirmClear = false; confirmDelete = false } }
    }
    @Published public var task: TaskState? {
        didSet { if task?.id != oldValue?.id || task?.question?.id != oldValue?.question?.id { confirmClear = false; confirmDelete = false } }
    }
    /// Earlier turns of this conversation, oldest first.
    @Published public var thread: [TaskState] = [] {
        didSet { if thread.count != oldValue.count { confirmClear = false; confirmDelete = false } }
    }
    @Published public var logs: [LogEntry] = []
    @Published public var dropped: [String] = []
    @Published public var history: [TaskSummaryRow] = []
    @Published public var hasKey: Bool?
    @Published public var petState: PetState = .idle
    @Published public var front: FrontWindow?
    @Published public var desktopActive = false
    @Published public var aside: String?
    @Published public var blind = false
    @Published public var bench: [BenchRow] = []
    @Published public var benching = false
    @Published public var draft = ""
    @Published public var seed: Seed?
    @Published public var dragging = false
    @Published public var confirmClear = false
    @Published public var confirmDelete = false
    @Published public var panel = PanelState()
    /// First-run setup, or /setup: shown in place of everything else until it is finished or skipped.
    @Published public var welcome = false
    @Published public var brain = BrainSnapshot()
    /// Bumped whenever the composer should take the cursor.
    @Published public private(set) var focusTick = 0

    public let bridge: MerryBridge
    private let now: () -> Double
    private var sending = false
    private var brainChanged = false
    private var seedCounter = 0
    private var subscriptions: Set<AnyCancellable> = []

    public init(bridge: MerryBridge, now: @escaping () -> Double = { nowMs() }) {
        self.bridge = bridge
        self.now = now
        welcome = !bridge.getSettings().onboarded
        panel = bridge.getPanelState()
        front = bridge.getFrontWindow()

        let events = bridge.events
        events.brainOpen.sink { [weak self] in self?.view = .brain }.store(in: &subscriptions)
        events.brainChanged.sink { [weak self] snapshot in self?.brainChanged = true; self?.brain = snapshot }.store(in: &subscriptions)
        events.historyDeleted.sink { [weak self] ids in self?.forget(ids) }.store(in: &subscriptions)
        events.taskUpdate.sink { [weak self] task in self?.receive(task) }.store(in: &subscriptions)
        events.log.sink { [weak self] entry in
            guard let self else { return }
            self.logs = Array(self.logs.suffix(199)) + [entry]
        }.store(in: &subscriptions)
        events.droppedPaths.sink { [weak self] paths in self?.dropped = paths; self?.view = .home }.store(in: &subscriptions)
        events.petState.sink { [weak self] state in self?.petState = state }.store(in: &subscriptions)
        events.seed.sink { [weak self] text in self?.view = .home; self?.plant(text) }.store(in: &subscriptions)
        events.panelState.sink { [weak self] state in self?.panel = state }.store(in: &subscriptions)
        events.desktopSession.sink { [weak self] active in self?.desktopActive = active }.store(in: &subscriptions)
        events.focusInput.sink { [weak self] in self?.summoned() }.store(in: &subscriptions)
    }

    /// What the panel asks for when it first appears.
    public func load() async {
        let snapshot = await bridge.getBrain()
        if !brainChanged { brain = snapshot }
        await refreshSetup()
        front = bridge.getFrontWindow()
        await refreshHistory()
    }

    // MARK: - Derived

    public var running: Bool { task.map { !$0.status.isTerminal } ?? false }

    /// A chat is on screen: the bar names it, and the reply box under it continues it.
    public var chatting: Bool { view == .home && task != nil }

    /// A plain answer: nothing was done, so there is no outcome to badge.
    public var isChat: Bool {
        guard let task else { return false }
        return task.status == .succeeded && task.actions.isEmpty && (task.summary?.evidence.isEmpty ?? true)
    }

    /// How the creature reacts to a half-typed request.
    public nonisolated static func moodForDraft(_ text: String, fallback: Mood) -> Mood {
        let t = text.jsTrimmed.lowercased()
        if t.isEmpty { return fallback }
        if t.hasPrefix("/") { return .wink }
        if Rx("^(find|where|search|look for|locate)\\b").test(t) { return .curious }
        if Rx("\\b(please|thanks|thank you|love)\\b").test(t) { return .happy }
        return .listening
    }

    public var homeMood: Mood { PanelModel.moodForDraft(draft, fallback: Mood.forState(petState)) }

    public var barMood: Mood {
        if let task, view == .home, draft.isEmpty { return Mood.forState(task.petState) }
        return homeMood
    }

    public var islandMood: Mood {
        if let task, !running { return Mood.forState(task.petState) }
        return Mood.forState(petState)
    }

    public var placeholder: String {
        if let question = task?.question { return question.allowFreeText ? "Your answer…" : "Choose an option above" }
        if running { return "Merry is working…" }
        if !dropped.isEmpty { return "What should I do with these?" }
        return chatting ? "Reply to Merry…" : "Ask Merry anything…"
    }

    /// One line for the island: what is happening, or how it ended.
    public var islandLine: String {
        if running, let task {
            if task.status == .awaitingUser { return "Needs your answer" }
            return task.statusLine.isEmpty ? "Working" : task.statusLine
        }
        if let summary = task?.summary { return Markdown.plainText(summary.headline) }
        return "Merry"
    }

    /// People repeat themselves: the last few things that worked, one tap away.
    public var again: [TaskSummaryRow] {
        var order: [String] = []
        var latest: [String: TaskSummaryRow] = [:]
        for row in history where row.status == .succeeded {
            let key = row.request.jsTrimmed.lowercased()
            if latest[key] == nil { order.append(key) }
            latest[key] = row
        }
        return order.prefix(3).compactMap { latest[$0] }
    }

    public var workspaceBadge: WorkspaceBadge {
        if let timer = brain.timer { return .timer(timer) }
        let due = brain.dueItems(now: now()).count
        if due > 0 { return .due(due) }
        let kept = brain.items.filter { $0.status == "open" }.count
        return kept > 0 ? .kept(kept) : .hint
    }

    /// The turn a chat is named after: its first.
    public var chatRoot: TaskState? { thread.first ?? task }

    /// A chat's name: the first line of what was asked.
    public var chatTitle: String { PanelModel.firstLine(chatRoot?.request ?? "") }

    public var messageCount: String { "\(thread.count + 1) \(thread.isEmpty ? "message" : "messages")" }

    public var chatAge: String { PanelModel.since(chatRoot?.createdAt ?? now(), now: now()) }

    public var taskLogs: [LogEntry] {
        guard let task else { return [] }
        return logs.filter { $0.taskId == task.id }
    }

    public nonisolated static func firstLine(_ text: String) -> String { (text.jsSplit("\n").first ?? "").jsTrimmed }

    /// When a chat started, the way a person would say it.
    public nonisolated static func since(_ at: Double, now: Double) -> String {
        let m = Int(((now - at) / 60000).rounded(.down))
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return h < 24 ? "\(h)h ago" : JSDate(at).format("MMM d")
    }

    /// A History row's age, shorter still.
    public nonisolated static func relative(_ at: Double, now: Double) -> String {
        let minutes = max(0, Int(((now - at) / 60000).rounded(.down)))
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return JSDate(at).format("MMM d")
    }

    /// How long the task took, the way a person would say it.
    public nonisolated static func took(_ task: TaskState) -> String {
        let s = max(0, Int(((task.updatedAt - task.createdAt) / 1000).rounded()))
        return s < 1 ? "instantly" : s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    /// Time since a moment, as the status bar shows it.
    public nonisolated static func elapsed(since: Double, now: Double) -> String {
        let s = max(0, Int(((now - since) / 1000).rounded(.down)))
        return s < 60 ? "\(s)s" : "\(s / 60):\(String(s % 60).jsPadStart(2, "0"))"
    }

    /// A countdown as the workspace badge and the island show it.
    public nonisolated static func timerText(_ timer: BrainTimer, now: Double) -> String {
        let clock = DotText.clock(timer.remaining(now: now))
        return timer.status == "paused" ? "\(clock) paused" : clock
    }

    /// The panel is as tall as what it has to say, in steps of 20 so it does not shimmer.
    public nonisolated static func panelHeight(content: CGFloat, chrome: CGFloat) -> CGFloat {
        ((content + chrome) / 20).rounded(.up) * 20
    }

    /// Minimized, the window is the island: its narrow layout says nothing
    /// about how tall the panel should be.
    public func reportHeight(content: CGFloat, chrome: CGFloat) {
        if panel.docked || welcome { return }
        bridge.resizePanel(height: PanelModel.panelHeight(content: content, chrome: chrome))
    }

    // MARK: - Refreshing

    public func refreshHistory() async { history = await bridge.listHistory(limit: 25) }

    public func refreshSetup() async {
        async let ready = bridge.canWork()
        async let permissions = bridge.getPermissions()
        hasKey = await ready
        blind = await permissions.contains { $0.permission == .accessibility && !$0.granted }
    }

    public func reportError(_ error: Error) { aside = messageOf(error) }

    /// The window came forward.
    public func onFocus() {
        Task { await refreshSetup() }
        front = bridge.getFrontWindow()
    }

    /// Summoned again long after a chat ended: open on a clean launcher, as
    /// Spotlight would. The chat is still one click away in History.
    public func summoned() {
        onFocus()
        if let last = task, last.status.isTerminal, now() - last.updatedAt > PanelModel.staleChatMs {
            task = nil; thread = []; logs = []
        }
        focusTick += 1
    }

    // MARK: - Task updates

    /// One place for task updates. A turn that replies to the one on screen
    /// pushes it up into the chat; any other new turn is a new chat.
    public func receive(_ t: TaskState) {
        // A late update for an earlier turn refreshes it in place.
        if let index = thread.firstIndex(where: { $0.id == t.id }) { thread[index] = t; return }
        let prev = task
        // The reply to startTask can arrive after the runtime's first update.
        if let prev, prev.id == t.id, t.updatedAt < prev.updatedAt { return }
        if let prev, prev.id != t.id {
            thread = t.replyTo == prev.id ? Array((thread + [prev]).suffix(PanelModel.maxTurns)) : []
        }
        task = t
        if t.status.isTerminal { Task { await refreshHistory() } }
    }

    private func forget(_ ids: [String]) {
        history.removeAll { ids.contains($0.id) }
        thread.removeAll { ids.contains($0.id) }
        if let current = task, ids.contains(current.id) { task = nil }
        logs.removeAll { ids.contains($0.taskId) }
    }

    // MARK: - Sending

    public func answer(_ question: UserQuestion, optionId: String?, text: String? = nil) async throws {
        guard let task else { return }
        try await bridge.answerQuestion(taskId: task.id, answer: AnswerPayload(questionId: question.id, optionId: optionId, text: text))
    }

    /// Sends a message. `followUp` is the turn it replies to (the reply box
    /// passes the chat's latest turn), or nil to start a new chat.
    public func send(_ text: String, withFront: Bool, followUp: String?) async throws {
        if sending { return }
        sending = true
        defer { sending = false }
        aside = nil
        if let question = task?.question, question.allowFreeText {
            try await answer(question, optionId: nil, text: text)
            view = .home
            return
        }
        if running { throw MerryError("Finish or stop the current task first.") }
        let request = StartTaskRequest(request: text, droppedPaths: dropped, includeFrontWindow: withFront, followUp: followUp.map { .reply($0) } ?? .newChat)
        let started = try await bridge.startTask(request)
        dropped = []
        logs = []
        seed = nil
        view = .home
        receive(started)
    }

    /// The failed or stopped request again, without the clarifications it gathered.
    public func retry() async {
        guard let task else { return }
        do { try await send(task.request.jsSplit("\n\nClarification:")[0], withFront: false, followUp: task.replyTo) } catch { reportError(error) }
    }

    /// The option a digit key picks, when a question is on screen.
    public func numberOption(_ n: Int) -> QuestionOption? {
        guard let question = task?.question, view == .home else { return nil }
        let options = question.options ?? [QuestionOption(id: "ok", label: "Go ahead")]
        return n >= 1 && n <= options.count ? options[n - 1] : nil
    }

    /// Returns true when the digit was consumed by picking an answer.
    @discardableResult
    public func answerNumber(_ n: Int) -> Bool {
        guard let question = task?.question, let option = numberOption(n) else { return false }
        Task { do { try await answer(question, optionId: option.id) } catch { reportError(error) } }
        return true
    }

    // MARK: - Commands

    public func command(_ name: String) async {
        aside = nil
        do {
            switch name {
            case "new": newChat()
            case "setup": welcome = true
            case "workspace": view = .brain
            case "undo":
                let rows = await bridge.listHistory(limit: 25)
                let current = task.flatMap { $0.summary?.undoable == true ? $0.id : nil }
                guard let target = current ?? rows.first(where: { $0.undoable })?.id else { aside = "No file changes to undo yet."; return }
                let report = try await bridge.undoTask(target)
                aside = "Restored \(report.reversed) item\(report.reversed == 1 ? "" : "s")."
                    + (report.skipped.isEmpty ? "" : " \(report.skipped.count) skipped: \(report.skipped[0].reason)")
                await refreshHistory()
            case "stop":
                if let task, running { bridge.cancelTask(task.id) }
            case "bench":
                bench = []; benching = true; view = .bench
                defer { benching = false }
                bench = try await bridge.runBench()
            case "past":
                await refreshHistory()
                view = .past
            case "center": bridge.centerPanel()
            case "steps": view = .steps
            case "keys": view = .keys
            case "tune": view = .tune
            default: view = .help
            }
        } catch { reportError(error) }
    }

    /// Puts the current chat away and opens the launcher. It stays in History.
    public func newChat() {
        if running { aside = "Merry is still working. Stop the task to start a new chat."; return }
        task = nil; thread = []; logs = []; aside = nil; seed = nil; confirmDelete = false
        view = .home
        focusTick += 1
    }

    /// Suggestions are new intents, so they start a new chat rather than replying.
    public func compose(_ text: String) {
        if !running { newChat() }
        view = .home
        plant(text)
    }

    private func plant(_ text: String) {
        seedCounter += 1
        seed = Seed(text: text, id: seedCounter)
    }

    public func openTask(_ id: String) async {
        if running, id != task?.id { aside = "Finish or stop your current task before opening another."; return }
        guard let t = await bridge.getTask(id) else { return }
        // Put the conversation back together from the turns each one replied to.
        var turns: [TaskState] = []
        var at = t.replyTo
        while let earlierId = at, turns.count < PanelModel.maxTurns {
            guard let earlier = await bridge.getTask(earlierId) else { break }
            turns.insert(earlier, at: 0)
            at = earlier.replyTo
        }
        thread = turns; task = t; view = .home
    }

    public func deleteTask(_ id: String) async throws {
        try await bridge.deleteTask(id)
        history.removeAll { $0.id == id }
        thread.removeAll { $0.id == id }
        if task?.id == id { task = nil; logs = [] }
    }

    /// Deleting from the chat header removes the whole conversation, not one turn of it.
    public func deleteChat() async throws {
        guard let current = task else { return }
        let turns = thread + [current]
        for turn in turns { try await bridge.deleteTask(turn.id) }
        let ids = Set(turns.map(\.id))
        history.removeAll { ids.contains($0.id) }
        task = nil; thread = []; logs = []; confirmDelete = false
    }

    public func undoFromHistory(_ id: String) async throws -> UndoReport {
        let report = try await bridge.undoTask(id)
        await refreshHistory()
        return report
    }

    public func clearHistory() async {
        do {
            try await bridge.clearHistory()
            await refreshHistory()
            confirmClear = false
        } catch { reportError(error) }
    }

    // MARK: - Attachments

    public func addDropped(_ paths: [String]) {
        dropped = Array((dropped + paths).unique.prefix(200))
    }

    public func attach() async {
        addDropped(await bridge.choosePaths())
    }

    /// Files let go of over the panel.
    public func drop(_ paths: [String]) {
        dragging = false
        let real = paths.filter { !$0.isEmpty }
        if real.isEmpty { return }
        addDropped(real)
        view = .home
    }

    // MARK: - Leaving

    /// Esc: back to the chat from any other page, and away from there.
    public func escape() {
        if view == .home { bridge.closePanel() } else { view = .home }
    }

    /// The first-run tour finished or was skipped; `prompt` is a request it suggested trying.
    public func finishWelcome(_ prompt: String?) {
        welcome = false
        Task { await refreshSetup() }
        if let prompt, !prompt.isEmpty { compose(prompt) } else { focusTick += 1 }
    }
}

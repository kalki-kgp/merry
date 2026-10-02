import AppKit
import Foundation
import MerryCore

/// A bridge with canned answers and no effects. Views are built and checked
/// against it, the way the reference's interface checks ran against a fake
/// bridge; it also records what was asked of it so tests can assert on that.
@MainActor
public final class PreviewBridge: MerryBridge {
    public let events = BridgeEvents()

    public var brain = BrainSnapshot()
    public var tasks: [String: TaskState] = [:]
    public var history: [TaskSummaryRow] = []
    public var permissions: [PermissionStatus] = [
        PermissionStatus(permission: .accessibility, granted: false, purpose: "Lets Merry read window contents and press buttons in apps, instead of guessing from pixels."),
        PermissionStatus(permission: .screenRecording, granted: false, purpose: "Lets Merry take a picture of a specific window when an app exposes no readable controls.")
    ]
    public var setup: [SetupItem] = []
    public var apiKey = false
    public var jevKey = false
    public var apps: [CodingAppStatus] = [
        CodingAppStatus(id: .claudeCode, label: "Claude Code", available: true),
        CodingAppStatus(id: .codex, label: "Codex", available: false),
        CodingAppStatus(id: .opencode, label: "OpenCode", available: false)
    ]
    public var catalog = CodingModelCatalog(models: [CodingModel(id: "sonnet", label: "Sonnet"), CodingModel(id: "opus", label: "Opus"), CodingModel(id: "haiku", label: "Haiku")], note: "")
    public var modelCheck = CodingModelCheck(ok: true, message: "This model answered.")
    public var bench: [BenchRow] = []
    public var settings = Settings()
    public var memories: [Memory] = []
    public var panel = PanelState()
    public var frontWindow: FrontWindow?
    public var canUninstall = false
    public var pickedPaths: [String] = []
    public var undoReport = UndoReport()
    /// When set, the next call that can fail throws this.
    public var failure: String?

    /// Every call made, by name, in order.
    public private(set) var calls: [String] = []
    public private(set) var started: [StartTaskRequest] = []
    public private(set) var answers: [AnswerPayload] = []
    public private(set) var brainRequests: [JSON] = []
    public private(set) var opened: [String] = []
    public private(set) var composed: [String] = []

    public init() {}

    private func note(_ call: String) { calls.append(call) }
    private func failIfAsked() throws {
        if let failure { self.failure = nil; throw MerryError(failure) }
    }

    public func getBrain() async -> BrainSnapshot { note("getBrain"); return brain }
    public func brainRequest(_ request: JSON) async throws -> BrainSnapshot {
        note("brainRequest"); brainRequests.append(request); try failIfAsked()
        events.brainChanged.send(brain)
        return brain
    }
    public func openBrain() { note("openBrain"); events.brainOpen.send() }

    public func startTask(_ request: StartTaskRequest) async throws -> TaskState {
        note("startTask"); try failIfAsked()
        started.append(request)
        var task = TaskState(request: request.request)
        if case .reply(let id) = request.followUp { task.replyTo = id }
        tasks[task.id] = task
        return task
    }
    public func pauseTask(_ taskId: String) { note("pauseTask") }
    public func resumeTask(_ taskId: String) { note("resumeTask") }
    public func cancelTask(_ taskId: String) { note("cancelTask") }
    public func answerQuestion(taskId: String, answer: AnswerPayload) async throws { note("answerQuestion"); try failIfAsked(); answers.append(answer) }
    public func undoTask(_ taskId: String) async throws -> UndoReport { note("undoTask"); try failIfAsked(); return undoReport }
    public func getTask(_ taskId: String) async -> TaskState? { note("getTask"); return tasks[taskId] }
    public func deleteTask(_ taskId: String) async throws {
        note("deleteTask"); try failIfAsked()
        tasks[taskId] = nil
        history.removeAll { $0.id == taskId }
        events.historyDeleted.send([taskId])
    }
    public func clearHistory() async throws { note("clearHistory"); try failIfAsked(); let ids = history.map(\.id); history = []; events.historyDeleted.send(ids) }
    public func listHistory(limit: Int) async -> [TaskSummaryRow] { note("listHistory"); return Array(history.prefix(limit)) }
    public func choosePaths() async -> [String] { note("choosePaths"); return pickedPaths }

    public func getPermissions() async -> [PermissionStatus] { note("getPermissions"); return permissions }
    public func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus {
        note("requestPermission:\(permission.rawValue)"); try failIfAsked()
        return permissions.first { $0.permission == permission } ?? PermissionStatus(permission: permission, granted: false, purpose: "")
    }
    public func getSetup() async -> [SetupItem] { note("getSetup"); return setup }
    public func requestSetup(_ id: String) async throws -> SetupItem {
        note("requestSetup:\(id)"); try failIfAsked()
        guard let index = setup.firstIndex(where: { $0.id == id }) else { throw MerryError("Unknown permission.") }
        setup[index].status = .granted
        return setup[index]
    }
    public func openSetupSettings(_ id: String) async { note("openSetupSettings:\(id)") }

    public func setApiKey(_ key: String) async -> Bool { note("setApiKey"); apiKey = !key.jsTrimmed.isEmpty; return true }
    public func hasApiKey() async -> Bool { apiKey }
    public func setJevKey(_ key: String) async -> Bool { note("setJevKey"); jevKey = !key.jsTrimmed.isEmpty; return true }
    public func hasJevKey() async -> Bool { jevKey }
    public func codingApps() async -> [CodingAppStatus] { apps }
    public func codingModels(_ app: CodingApp, refresh: Bool) async throws -> CodingModelCatalog { note("codingModels:\(app.rawValue)"); try failIfAsked(); return catalog }
    public func checkCodingModel(_ app: CodingApp, model: String) async throws -> CodingModelCheck { note("checkCodingModel:\(app.rawValue):\(model)"); try failIfAsked(); return modelCheck }
    public func canWork() async -> Bool { apiKey || jevKey || (settings.useClaudeCode && apps.contains { $0.id == settings.codingApp && $0.available }) }
    public func runBench() async throws -> [BenchRow] { note("runBench"); try failIfAsked(); return bench }

    public func getSettings() -> Settings { settings }
    public func setSettings(_ change: (inout Settings) -> Void) async throws -> Settings {
        note("setSettings"); try failIfAsked()
        change(&settings)
        events.settingsChanged.send(settings)
        return settings
    }
    public func canUninstallApp() -> Bool { canUninstall }
    public func uninstallApp() async throws -> Bool { note("uninstallApp"); try failIfAsked(); return false }

    public func revealPath(_ path: String) throws { note("revealPath"); try failIfAsked(); opened.append(path) }
    public func openPath(_ path: String) async throws { note("openPath"); try failIfAsked(); opened.append(path) }
    public func openUrl(_ url: String) async throws { note("openUrl"); try failIfAsked(); opened.append(url) }

    public func resizePanel(height: CGFloat) { note("resizePanel") }
    public func closePanel() { note("closePanel") }
    public func centerPanel() { note("centerPanel") }
    public func minimizePanel() { note("minimizePanel"); panel.docked.toggle(); events.panelState.send(panel) }
    public func pinPanel(_ pinned: Bool) { note("pinPanel"); panel.pinned = pinned; events.panelState.send(panel) }
    public func getPanelState() -> PanelState { panel }

    public func petCompose(_ text: String) { note("petCompose"); composed.append(text) }
    public func showPetMenu(napping: Bool) { note("showPetMenu") }
    public func petClicked(pressedAt: Date?) { note("petClicked") }
    public func setPetInteractive(_ interactive: Bool) { note("setPetInteractive:\(interactive)") }
    public func setPetHitRects(_ rects: [CGRect]) {}
    public func dragPet(dx: CGFloat, dy: CGFloat) { note("dragPet") }
    public func reportDroppedPaths(_ paths: [String]) { note("reportDroppedPaths"); events.droppedPaths.send(paths) }

    public func listMemories() async -> [Memory] { memories }
    public func deleteMemory(_ id: String) async -> [Memory] { note("deleteMemory"); memories.removeAll { $0.id == id }; return memories }
    public func clearMemories() async -> [Memory] { note("clearMemories"); memories = []; return memories }

    public func stopDesktopSession() { note("stopDesktopSession") }
    public func getFrontWindow() -> FrontWindow? { frontWindow }
}

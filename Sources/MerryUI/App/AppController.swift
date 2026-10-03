import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import MerryCore

/// The app itself: it owns the stores, the windows, the menu bar item and the
/// shortcut, starts tasks and relays what they report. It is also the bridge
/// the views talk to. Nothing here runs the agent loop or calls a model; that
/// is `TaskRunner`, which works off the main thread.
@MainActor
public final class AppController: NSObject, MerryBridge, NSApplicationDelegate {
    public let events = BridgeEvents()

    /// Where history, the workspace and settings are kept.
    public static var dataDirectory: String {
        Path.join(Path.home, "Library", "Application Support", "merry")
    }
    private static let keychainService = "app.merry.pet"

    private var store: Store!
    private var brain: BrainStore!
    private var secrets: Secrets!
    private var setup: Setup!
    private var uninstaller: AppUninstaller!
    private var desktopSession: DesktopSession!
    private let os = MacOsAdapter()
    private var browser: WebBrowser!
    private let registry = ToolRegistry(allTools())

    private var settings = MerryCore.Settings()
    private var currentTask: TaskState?
    private var runner: TaskRunner?
    private var pet: PetWindowController!
    private var panel: PanelWindowController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var stopHotKey: HotKey?
    private var indicator: NSPanel?
    private var brainClock: Timer?
    private var asleep = false
    private var locked = false
    private var measuring = false
    private var quitting = false
    private var checkingModels = Set<CodingApp>()

    /// The window the user was in just before Merry's panel took focus.
    /// Captured eagerly because once the panel is open, asking is too late.
    private var lastFrontWindow: FrontWindow?

    public override init() { super.init() }

    // MARK: - Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store(directory: Self.dataDirectory)
            brain = try BrainStore(directory: Self.dataDirectory)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Merry couldn’t open its data"
            alert.informativeText = messageOf(error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        secrets = Secrets(service: Self.keychainService)
        settings = store.loadSettings()
        // A desktop pet lives on the desktop until the person says otherwise.
        if settings.petModeChosen != true { settings.petMode = .desktop }
        // Persist migrations so an older preference cannot reappear after an update.
        try? store.saveSettings(settings)

        browser = WebBrowser(downloadsFolder: Path.join(Self.dataDirectory, "downloads"), log: { [weak self] level, message in
            Task { @MainActor in self?.record(LogEntry(taskId: "runtime", level: level, source: "browser", message: message)) }
        })
        setup = Setup(os: os, store: store, notify: { [weak self] in
            await self?.notify(title: "Merry", body: "This is how I’ll tap you on the shoulder for reminders.", silent: true, onClick: nil)
        }, openURL: { url in
            await MainActor.run { if let target = URL(string: url) { NSWorkspace.shared.open(target) } }
        })
        desktopSession = DesktopSession(hooks: .init(
            showIndicator: { [weak self] reason in Task { @MainActor in self?.showIndicator(reason) } },
            hideIndicator: { [weak self] in Task { @MainActor in self?.hideIndicator() } },
            registerStopShortcut: { [weak self] in Task { @MainActor in self?.registerStopShortcut() } },
            unregisterStopShortcut: { [weak self] in Task { @MainActor in self?.stopHotKey?.unregister(); self?.stopHotKey = nil } }
        ))
        desktopSession.onChanged = { [weak self] active in Task { @MainActor in self?.events.desktopSession.send(active) } }
        desktopSession.onStopRequested = { [weak self] _ in Task { @MainActor in self?.runner?.cancel() } }
        uninstaller = AppUninstaller(deps: uninstallDeps())

        if let interrupted = try? store.recoverInterruptedTasks(), let first = interrupted.first {
            try? store.appendLog(LogEntry(taskId: first, level: .warn, source: "recovery",
                                          message: "\(interrupted.count) task(s) were interrupted by a quit or crash and were not resumed automatically."))
        }

        pet = PetWindowController(bridge: self, savedX: settings.petX, savedY: settings.petY, mode: { [weak self] in self?.settings.petMode ?? .ondemand },
                                  showAtStart: settings.petMode == .desktop)
        pet.onMoved = { [weak self] x, y in self?.save { $0.petX = x; $0.petY = y } }

        let saved = settings.panelX >= 0 && settings.panelY >= 0 ? CGPoint(x: settings.panelX, y: settings.panelY) : nil
        panel = PanelWindowController(content: PanelView(bridge: self), savedPosition: saved, pinned: settings.panelPinned)
        panel.window.onCancel = { [weak self] in self?.hidePanel() }
        panel.floatsForSetup = !settings.onboarded
        panel.onFocusChange = { [weak self] focused in self?.panelFocusChanged(focused) }
        panel.onMoved = { [weak self] origin in self?.save { $0.panelX = origin.x; $0.panelY = origin.y } }

        createStatusItem()
        if !registerShortcut(settings.shortcut) {
            NSLog("Could not register the global shortcut %@; it may be taken.", settings.shortcut)
        }

        brainClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickBrain() } }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = true } }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = false; self?.tickBrain() } }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = false; self?.tickBrain() } }

        broadcastBrain()
        tickBrain()
        // First run: open straight onto setup rather than waiting to be found.
        if !settings.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showPanelWithoutToggling() }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Reopening the app means "show me", never "put it away".
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanelWithoutToggling()
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        hotKey?.unregister()
        desktopSession?.dispose()
        runner?.cancel()
        disposeWarmClaudeCode()
        brainClock?.invalidate()
        brain?.close()
        store?.close()
    }

    // MARK: - Settings

    private func save(_ change: (inout MerryCore.Settings) -> Void) {
        change(&settings)
        try? store.saveSettings(settings)
    }

    public func getSettings() -> MerryCore.Settings { settings }

    public func setSettings(_ change: (inout MerryCore.Settings) -> Void) async throws -> MerryCore.Settings {
        var next = settings
        change(&next)
        let before = settings

        if next.launchAtLogin != before.launchAtLogin {
            guard isInstalledApp else {
                throw MerryError("Open at login is available in an installed Merry build. During development, keep Merry running for reminders.")
            }
            do {
                if next.launchAtLogin { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            } catch {
                throw MerryError("Couldn’t change the login setting: \(messageOf(error))")
            }
        }
        if next.petMode != before.petMode { next.petModeChosen = true }
        // A model name ends up as a command-line argument: it may only look like one.
        next.claudeCodeModel = next.claudeCodeModel.jsTrimmed
        next.codexModel = next.codexModel.jsTrimmed
        next.opencodeModel = next.opencodeModel.jsTrimmed
        for model in [next.claudeCodeModel, next.codexModel, next.opencodeModel] where !validCodingModel(model) || model.contains("\n") {
            throw MerryError("That does not look like a model name.")
        }
        if next.claudeCodeModel.isEmpty { throw MerryError("Choose a Claude Code model.") }
        if next.shortcut != before.shortcut {
            if !Rx("^[A-Za-z0-9+]{1,60}$").test(next.shortcut) || next.shortcut.contains("\n") { throw MerryError("That is not a shortcut.") }
            if Rx("^(Command|CommandOrControl|CmdOrCtrl|Cmd)\\+Space$").test(next.shortcut) {
                throw MerryError("⌘ Command + Space opens Spotlight. Pick another. ⌘ Command + ⇧ Shift + Space is the default.")
            }
            next.shortcutChosen = true
        }

        settings = next
        try? store.saveSettings(settings)
        // A key another app holds falls back to a free one, which is saved: report that one.
        if settings.shortcut != before.shortcut { registerShortcut(settings.shortcut) }
        if settings.petMode != before.petMode {
            broadcastBrain()
            pet.presence.update()
            statusItem.button?.title = ""
        }
        panel.floatsForSetup = !settings.onboarded
        events.settingsChanged.send(settings)
        return settings
    }

    private var isInstalledApp: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    // MARK: - Broadcasts

    private func setPetState(_ state: PetState) {
        events.petState.send(state)
        pet?.presence.setState(state)
        // What the menu bar says next to Merry's face while it works, when there is no pet to say it.
        let titles: [PetState: String] = [.thinking: "Thinking", .working: "Working", .waiting: "Needs you"]
        statusItem?.button?.title = settings.petMode == .menubar ? (titles[state].map { " \($0)" } ?? "") : ""
    }

    private func broadcastBrain() {
        let snapshot = brain.snapshot()
        // A running timer or a due reminder is shown on the pet, so it comes out for them.
        pet?.presence.setBrain(snapshot)
        events.brainChanged.send(snapshot)
    }

    private func record(_ entry: LogEntry) {
        if store.isDeleted(entry.taskId) { return }
        try? store.appendLog(entry)
        events.log.send(entry)
    }

    // MARK: - Task lifecycle

    /// How long a finished task stays available as context for the next
    /// message. Long enough that a follow-up lands in the same conversation,
    /// short enough that tomorrow's request is not coloured by yesterday's.
    private static let followUpWindowMs = 10.0 * 60 * 1000
    /// How many turns before the one replied to are given to the model as well.
    private static let earlierTurns = 5
    private var lastFinished: (id: String, request: String, headline: String, at: Double)?

    /// Whether any planning route at all is configured.
    public func canWork() async -> Bool {
        secrets.hasApiKey() || secrets.hasJevKey() || (settings.useClaudeCode && codingAppAvailable(settings.codingApp))
    }

    /// What this message follows. A reply names its turn, so it is context
    /// however long ago that was; a new chat has none; anything else falls back
    /// to the follow-up window.
    private func previousTurn(_ followUp: StartTaskRequest.FollowUp) -> PreviousTurn? {
        switch followUp {
        case .newChat:
            return nil
        case .reply(let id):
            let thread = (try? store.conversationOf(id)) ?? []
            guard let at = thread.firstIndex(where: { $0.id == id }) else { return nil }
            let said: (TaskState) -> String = { $0.summary?.headline ?? $0.error ?? $0.statusLine }
            let prior = thread[at]
            return PreviousTurn(
                request: prior.request, headline: said(prior),
                secondsAgo: max(0, Int(((nowMs() - prior.updatedAt) / 1000).rounded())), explicit: true,
                // The rest of the chat up to that turn, so a reply has the whole thread.
                earlier: thread[max(0, at - Self.earlierTurns)..<at].map { PreviousTurn.Earlier(request: $0.request, headline: said($0)) }
            )
        case .unspecified:
            guard let last = lastFinished else { return nil }
            let elapsed = nowMs() - last.at
            if elapsed > Self.followUpWindowMs { return nil }
            return PreviousTurn(request: last.request, headline: last.headline, secondsAgo: Int((elapsed / 1000).rounded()))
        }
    }

    public func startTask(_ request: StartTaskRequest) async throws -> TaskState {
        let text = request.request.jsTrimmed
        if text.isEmpty { throw MerryError("a request is required") }
        if uninstaller.inProgress { throw MerryError("Finish or cancel uninstalling Merry before starting a task.") }
        // A missing Anthropic key is not fatal: the Jev-only workflows can
        // still run, a coding app can stand in for the planner, and the
        // runner reports clearly if a request needs something not configured.
        if settings.useClaudeCode && !codingAppAvailable(settings.codingApp) {
            throw MerryError("Your selected coding app is no longer installed. Choose an installed app in Settings.")
        }
        if measuring { throw MerryError("Wait for the measurement to finish before starting a task.") }
        if let currentTask, !currentTask.status.isTerminal { throw MerryError("A task is already running.") }

        // Dropping files onto the pet is itself an act of authorization: it
        // names exactly what the user means. Nothing else is granted up front;
        // anything wider has to be asked for, in context, while the task runs.
        let dropped = Array(request.droppedPaths.prefix(200)).map(normalizePath)
        var auth = Authorization(capabilities: ["user.interact", "files.read"])
        for path in dropped {
            auth.readRoots.append(path)
            auth.writeRoots.append(path)
            // A dropped file implies its folder is the working area.
            auth.readRoots.append(Path.dirname(path))
        }
        var limits = TaskLimits()
        limits.maxUsd = settings.maxUsdPerTask
        var task = TaskState(request: text.jsSlice(0, 4000), authorization: auth, limits: limits)
        task.droppedPaths = dropped

        let previous = previousTurn(request.followUp)
        if case .reply(let id) = request.followUp, previous != nil {
            task.replyTo = id
            task.conversationId = (try? store.getTask(id))?.conversationId ?? id
        }
        currentTask = task
        try? store.saveTask(task)
        setPetState(.thinking)

        var model = ModelConfig()
        model.claudeCode = settings.claudeCodeModel
        model.codex = settings.codexModel
        model.opencode = settings.opencodeModel

        var deps = RunnerDeps(os: os, browser: browser, registry: registry)
        let brainStore = brain!
        deps.brain = { [weak self] input in
            let snapshot = try brainStore.request(input)
            await self?.workspaceChanged()
            return snapshot
        }
        deps.model = model
        deps.apiKey = secrets.getApiKey()
        deps.jevEnabled = settings.jevEnabled
        deps.jevApiKey = secrets.getJevKey()
        deps.workflowsEnabled = settings.workflowsFirst
        deps.droppedPaths = dropped
        deps.frontWindow = request.includeFrontWindow ? lastFrontWindow : nil
        deps.previousApp = lastFrontWindow?.name
        deps.prefetchContext = true
        deps.memories = settings.memoryEnabled ? ((try? store.listMemories()) ?? []) : []
        deps.memoryEnabled = settings.memoryEnabled
        deps.memoryLearn = settings.memoryEnabled && settings.memoryLearn
        deps.previousTurn = previous
        deps.confirmEveryAction = settings.confirmEveryAction
        if settings.useClaudeCode {
            let app = settings.codingApp
            let chosen = model
            deps.createPlanner = { createCodingAppPlanner(app, chosen) }
            deps.plannerRoute = .app(app)
            // Start the selected Claude Code model while the request is being read.
            if app == .claudeCode { prewarmClaudeCode(model.claudeCode) }
        } else if deps.apiKey != nil {
            deps.plannerRoute = .api
        }

        let session = desktopSession!
        let hooks = RunnerHooks(
            // The loop reports from its own thread; the queue keeps its updates in order.
            onUpdate: { [weak self] state in DispatchQueue.main.async { MainActor.assumeIsolated { self?.taskUpdated(state) } } },
            onPetState: { [weak self] state in DispatchQueue.main.async { MainActor.assumeIsolated { self?.setPetState(state) } } },
            onLog: { [weak self] entry in DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(entry) } } },
            claimDesktop: { [weak self] taskId, reason in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.record(LogEntry(taskId: taskId, level: .info, source: "desktop", message: "taking control: \(reason)"))
                } }
                try session.claim(taskId, reason: reason)
            },
            releaseDesktop: { taskId in session.release(taskId) },
            onMemory: { [weak self] event in DispatchQueue.main.async { MainActor.assumeIsolated { self?.memoryChanged(event) } } }
        )
        let runner = TaskRunner(task: task, deps: deps, hooks: hooks)
        self.runner = runner
        let claudeCode = settings.useClaudeCode && settings.codingApp == .claudeCode
        Task.detached(priority: .userInitiated) {
            await runner.run()
            // Ready for the next message before it is typed.
            if claudeCode { prewarmClaudeCode(model.claudeCode) }
        }
        return task
    }

    private func taskUpdated(_ task: TaskState) {
        if store.isDeleted(task.id) { return }
        let finished = task.status == .succeeded || task.status == .failed
        let finishedNow = finished && (try? store.getTask(task.id))?.status != task.status
        currentTask = task
        if finished, let summary = task.summary {
            lastFinished = (task.id, task.request, summary.headline, nowMs())
        }
        try? store.saveTask(task)
        events.taskUpdate.send(task)
        // With no pet on the desktop, a result nobody is looking at arrives as a notification.
        if finishedNow, settings.petMode == .menubar, !panel.isVisible, let summary = task.summary {
            Task { await notify(title: task.status == .succeeded ? "Merry is done" : "Merry couldn’t finish", body: plainHeadline(summary.headline), silent: false) { [weak self] in self?.showPanelWithoutToggling() } }
        }
        // A task that is waiting on an answer must not wait invisibly: the
        // panel hides itself when focus leaves, so bring it back when a
        // question appears.
        if task.question != nil, !panel.isVisible { showPanelWithoutToggling() }
    }

    /// A result headline as notification text: markdown marks dropped, one short paragraph.
    private func plainHeadline(_ markdown: String) -> String {
        var text = Rx("[*_`#>]").replaceAll(markdown, "")
        text = Rx("\\[([^\\]]+)\\]\\([^)]*\\)").replaceAll(text, "$1")
        text = Rx("\\s+").replaceAll(text, " ").jsTrimmed
        return text.jsLength > 180 ? "\(text.jsSlice(0, 177))…" : text
    }

    private func memoryChanged(_ event: MemoryEvent) {
        switch event {
        case .save(let memory, let replaces): try? store.saveMemory(memory, replaces: replaces)
        case .forget(let ids): try? store.deleteMemories(ids)
        case .used(let ids): try? store.markMemoriesUsed(ids)
        }
        events.memoriesChanged.send((try? store.listMemories()) ?? [])
    }

    public func pauseTask(_ taskId: String) { if currentTask?.id == taskId { runner?.pause() } }
    public func resumeTask(_ taskId: String) { if currentTask?.id == taskId { runner?.resume() } }
    public func cancelTask(_ taskId: String) { if currentTask?.id == taskId { runner?.cancel() } }

    public func answerQuestion(taskId: String, answer: AnswerPayload) async throws {
        if taskId.isEmpty || answer.questionId.isEmpty { throw MerryError("taskId and questionId are required") }
        guard currentTask?.id == taskId else { return }
        var payload = answer
        payload.text = answer.text.map { $0.jsSlice(0, 4000) }
        runner?.answer(payload)
    }

    public func undoTask(_ taskId: String) async throws -> UndoReport {
        await MerryCore.undoTask(store: store, taskId: taskId) { entry in
            let result = await reverseMacChange(entry)
            return (result.ok, result.reason ?? "")
        }
    }

    public func getTask(_ taskId: String) async -> TaskState? { try? store.getTask(taskId) }

    public func listHistory(limit: Int) async -> [TaskSummaryRow] { (try? store.listTasks(limit: min(limit, 100))) ?? [] }

    private func forget(_ ids: [String]) {
        if let last = lastFinished, ids.contains(last.id) { lastFinished = nil }
        if let current = currentTask, ids.contains(current.id) { currentTask = nil; setPetState(.idle) }
        events.historyDeleted.send(ids)
    }

    public func deleteTask(_ taskId: String) async throws {
        if taskId.jsTrimmed.isEmpty { throw MerryError("A task ID is required.") }
        if let current = currentTask, current.id == taskId, !current.status.isTerminal { throw MerryError("Stop this task before deleting it.") }
        // A History row is a chat, so deleting it deletes every turn of it.
        forget(try store.deleteConversation(taskId))
    }

    public func clearHistory() async throws { forget(try store.clearHistory()) }

    public func choosePaths() async -> [String] {
        // The picker takes focus from the panel; that is not the user leaving.
        panelDialogOpen = true
        defer { panelDialogOpen = false; panel.focus() }
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.prompt = "Attach"
        NSApp.activate()
        return picker.runModal() == .OK ? picker.urls.map(\.path) : []
    }

    // MARK: - Workspace

    public func getBrain() async -> BrainSnapshot { brain.snapshot() }

    private func workspaceChanged() {
        broadcastBrain()
        tickBrain()
    }

    public func brainRequest(_ request: JSON) async throws -> BrainSnapshot {
        let result = try brain.request(request)
        broadcastBrain()
        tickBrain()
        return result
    }

    public func openBrain() {
        showPanelWithoutToggling()
        events.brainOpen.send()
    }

    private func tickBrain() {
        if quitting || asleep || locked { return }
        guard brain.hasDue() else { return }
        let (_, alerts) = brain.tick()
        guard let first = alerts.first else { return }
        broadcastBrain()
        Task {
            await notify(title: first.timer ? "Time’s up" : "Merry reminder", body: alerts.count == 1 ? first.title : "\(first.title) + \(alerts.count - 1) more", silent: false) { [weak self] in self?.openBrain() }
        }
    }

    // MARK: - Notifications

    private var notificationActions: [String: () -> Void] = [:]
    private var notificationsReady = false

    private func notify(title: String, body: String, silent: Bool, onClick: (() -> Void)?) async {
        // Notifications belong to an app bundle; run bare from the build folder there is nothing to post them as.
        guard Bundle.main.bundleIdentifier != nil, isInstalledApp else { return }
        let center = UNUserNotificationCenter.current()
        if !notificationsReady {
            notificationsReady = true
            center.delegate = self
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !silent { content.sound = .default }
        let id = newId()
        if let onClick { notificationActions[id] = onClick }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Permissions

    public func getPermissions() async -> [PermissionStatus] { (try? await os.getPermissions()) ?? [] }
    public func requestPermission(_ permission: OsPermission) async throws -> PermissionStatus { try await os.requestPermission(permission) }
    public func getSetup() async -> [SetupItem] { await setup.list() }

    public func requestSetup(_ id: String) async throws -> SetupItem {
        guard Setup.isSetupId(id) else { throw MerryError("Unknown permission.") }
        // A system dialog takes focus from the panel; that is not the person leaving.
        panelDialogOpen = true
        defer { panelDialogOpen = false }
        return try await setup.request(id)
    }

    public func openSetupSettings(_ id: String) async {
        guard Setup.isSetupId(id) else { return }
        try? await setup.openSettings(id)
    }

    // MARK: - Connections

    public func setApiKey(_ key: String) async -> Bool { secrets.setApiKey(key) }
    public func hasApiKey() async -> Bool { secrets.hasApiKey() }
    public func setJevKey(_ key: String) async -> Bool { secrets.setJevKey(key) }
    public func hasJevKey() async -> Bool { secrets.hasJevKey() }
    public func codingApps() async -> [CodingAppStatus] { codingAppStatus() }
    public func codingModels(_ app: CodingApp, refresh: Bool) async throws -> CodingModelCatalog { try await MerryCore.codingModels(app, refresh: refresh) }

    public func checkCodingModel(_ app: CodingApp, model: String) async throws -> CodingModelCheck {
        let wanted = model.jsTrimmed
        if wanted.isEmpty || !validCodingModel(wanted) || wanted.contains("\n") { throw MerryError("Invalid model ID.") }
        if checkingModels.contains(app) { return CodingModelCheck(ok: false, message: "An access check is already running for this app. Wait a moment and retry.") }
        checkingModels.insert(app)
        defer { checkingModels.remove(app) }
        return await MerryCore.checkCodingModel(app, wanted)
    }

    /// One measurement pass of every route a request can take.
    public func runBench() async throws -> [BenchRow] {
        if measuring || (currentTask.map { !$0.status.isTerminal } ?? false) { throw MerryError("Finish the current work before measuring.") }
        measuring = true
        defer { measuring = false }
        return await MerryCore.runBench(jevApiKey: secrets.getJevKey(), model: ModelConfig())
    }

    // MARK: - Uninstall

    public func canUninstallApp() -> Bool { uninstaller.available }
    public func uninstallApp() async throws -> Bool { try await uninstaller.uninstall() }

    private func uninstallDeps() -> UninstallDeps {
        UninstallDeps(
            executable: { Bundle.main.executablePath ?? "" },
            packaged: { Bundle.main.bundlePath.hasSuffix(".app") },
            confirm: { [weak self] in await self?.confirmUninstall() ?? false },
            loginEnabled: { SMAppService.mainApp.status == .enabled },
            setLoginEnabled: { [weak self] value in
                if value { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                Task { @MainActor in self?.save { $0.launchAtLogin = value } }
            },
            stopWork: { [weak self] in await self?.stopForUninstall() },
            trash: { bundle in try FileManager.default.trashItem(at: URL(fileURLWithPath: bundle), resultingItemURL: nil) },
            quit: { Task { @MainActor in NSApp.terminate(nil) } }
        )
    }

    private func confirmUninstall() -> Bool {
        panelDialogOpen = true
        defer { panelDialogOpen = false }
        let alert = NSAlert()
        alert.messageText = "Move Merry to Trash?"
        alert.informativeText = "Merry will stop, including running tasks, timers and reminders, and will no longer open at login. Your saved history and settings stay on this Mac."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func stopForUninstall() {
        runner?.cancel()
        guard var task = currentTask, !task.status.isTerminal else { return }
        task.status = .cancelled
        task.statusLine = "Stopped for uninstall"
        task.summary = TaskSummary(headline: "Stopped for uninstall", evidence: [], undoable: !((try? store.undoableActions(task.id)) ?? []).isEmpty)
        currentTask = task
        try? store.saveTask(task)
        events.taskUpdate.send(task)
        desktopSession.release(task.id)
        setPetState(.idle)
    }

    // MARK: - Opening things

    // Path-taking operations are constrained: documents and folders open, but
    // anything that would run (an app, a script, an installer) is only
    // revealed in Finder, so a result link can never launch code.

    public func revealPath(_ path: String) throws {
        let full = normalizePath(path)
        guard FileManager.default.fileExists(atPath: full) else { throw MerryError("that path no longer exists") }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
    }

    public func openPath(_ path: String) async throws {
        let full = normalizePath(path)
        guard FileManager.default.fileExists(atPath: full) else { throw MerryError("that path no longer exists") }
        if wouldLaunch(full) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
            return
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: full)) { throw MerryError("Couldn’t open \(Path.basename(full)).") }
    }

    public func openUrl(_ url: String) async throws {
        guard let target = URL(string: try externalWebUrl(url)) else { throw MerryError("Invalid URL") }
        NSWorkspace.shared.open(target)
    }

    // MARK: - The panel

    /// When the panel gained and lost focus. A click on the pet reaches Merry
    /// while focus is already changing hands, so asking "is the panel
    /// focused?" when the click arrives can give the wrong answer. Asking what
    /// it was just before the button went down gives the real one.
    private var panelFocusLog: [(at: Double, focused: Bool)] = []
    /// Set while a native dialog owned by the panel is open.
    private var panelDialogOpen = false
    private var blurTimer: Timer?

    private func panelFocusChanged(_ focused: Bool) {
        panelFocusLog.append((nowMs(), focused))
        if panelFocusLog.count > 40 { panelFocusLog.removeFirst() }
        guard !focused else { return }
        blurTimer?.invalidate()
        // A short grace: focus can flicker away and straight back during a
        // click on the pet or while macOS hands activation around.
        blurTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.putAwayAfterBlur() } }
    }

    private func panelFocused(at time: Double) -> Bool {
        panelFocusLog.last { $0.at <= time }?.focused ?? false
    }

    private var taskIsRunning: Bool { currentTask.map { !$0.status.isTerminal } ?? false }

    /// Clicking somewhere else leaves the panel where it is. It goes away
    /// when it is closed: the red button, Esc, or the shortcut.
    private func putAwayAfterBlur() { blurTimer = nil }

    private func togglePanel(focusInput: Bool = true, pressedAt: Date? = nil) {
        let inUse = pressedAt.map { panelFocused(at: $0.timeIntervalSince1970 * 1000 - 20) } ?? panel.isFocused
        // Whatever you were in before this click is "the previous app",
        // whether the panel was hidden or just behind it.
        if !panel.isVisible || !inUse { captureFrontWindow() }
        if panel.isVisible {
            // Docked, the panel is the island: the shortcut should open it out,
            // not put it away. Open but behind whatever you were working in is
            // not "open" to you either. It only goes away when you are using it.
            if panel.isDocked || !inUse {
                showPanel()
                if focusInput { events.focusInput.send() }
                return
            }
            hidePanel()
            if !taskIsRunning { setPetState(.idle) }
            return
        }
        showPanel()
        if focusInput { events.focusInput.send() }
    }

    /// Shows the panel without toggling it closed if it is already open.
    private func showPanelWithoutToggling() {
        if !panel.isVisible { captureFrontWindow() }
        showPanel()
    }

    /// Brings the panel forward, open and where the user left it.
    ///
    /// A panel that re-centres itself every time it appears cannot be put
    /// anywhere, so the pet only decides the placement until the user first
    /// drags the window; after that the saved position is the only thing consulted.
    private func showPanel() {
        if panel.isDocked {
            // Opening from the menu bar or the shortcut means the user wants
            // the panel, not the island they tucked away.
            panel.toggleDock()
            broadcastPanelState()
        } else if settings.panelX < 0 || settings.panelY < 0 {
            panel.positionNear(pet: pet.frame)
        } else if !panel.isVisible {
            panel.placeOnActiveDisplay(saved: CGPoint(x: settings.panelX, y: settings.panelY))
        }
        panel.show()
        pet.presence.setPanelOpen(true)
        pet.presence.reveal()
        // The pet looks up when the panel is open and nothing is running.
        if !taskIsRunning { setPetState(.listening) }
    }

    /// Puts the panel away. A hidden panel is never a docked one.
    private func hidePanel() {
        panel.hide()
        panelFocusLog.append((nowMs(), false))
        pet.presence.setPanelOpen(false)
        broadcastPanelState()
    }

    private func broadcastPanelState() { events.panelState.send(getPanelState()) }

    public func resizePanel(height: CGFloat) { panel?.resize(height: height + PanelView.titleStrip) }

    public func closePanel() {
        hidePanel()
        if !taskIsRunning { setPetState(.idle) }
    }

    public func centerPanel() {
        if panel.isDocked { panel.toggleDock(); broadcastPanelState() }
        if !panel.isVisible { showPanel() }
        panel.center()
        save { $0.panelX = -1; $0.panelY = -1 }
    }

    public func minimizePanel() {
        panel.toggleDock()
        broadcastPanelState()
        // Coming back from the island means "I want to type": hand over focus.
        if !panel.isDocked {
            panel.focus()
            events.focusInput.send()
        }
    }

    public func pinPanel(_ pinned: Bool) {
        panel.setPinned(pinned)
        save { $0.panelPinned = pinned }
        broadcastPanelState()
    }

    // Views ask for this while they are being built, before their window exists.
    public func getPanelState() -> PanelState { PanelState(docked: panel?.isDocked ?? false, pinned: panel?.isPinned ?? settings.panelPinned) }

    /// Remembers what the user was looking at, so "help me with this window"
    /// means their window rather than Merry's own panel. Failures are silent:
    /// this is a convenience, and Accessibility may simply not be granted.
    private func captureFrontWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = Int(front.processIdentifier)
        let name = front.localizedName ?? ""
        lastFrontWindow = FrontWindow(pid: pid, name: name, title: "")
        Task {
            let title = (try? await os.inspectWindow(pid: pid, maxDepth: nil, maxNodes: 1))?.title ?? ""
            if lastFrontWindow?.pid == pid { lastFrontWindow = FrontWindow(pid: pid, name: name, title: title) }
        }
    }

    public func getFrontWindow() -> FrontWindow? { lastFrontWindow }

    // MARK: - The pet

    public func petCompose(_ text: String) {
        showPanelWithoutToggling()
        // Empty means "just open": never wipe a half-typed draft.
        if !text.isEmpty { events.seed.send(text.jsSlice(0, 500)) }
        events.focusInput.send()
    }

    public func showPetMenu(napping: Bool) {
        pet.showMenu(napping: napping, onOpen: { [weak self] in self?.showPanelWithoutToggling() }, onHide: { [weak self] in self?.setPetMode(.menubar) })
    }

    public func petClicked(pressedAt: Date?) {
        let recent = pressedAt.flatMap { abs($0.timeIntervalSinceNow) < 5 ? $0 : nil }
        togglePanel(focusInput: true, pressedAt: recent)
    }

    public func setPetInteractive(_ interactive: Bool) { pet?.setInteractive(interactive) }
    public func setPetHitRects(_ rects: [CGRect]) { pet?.setHitRects(rects) }
    public func dragPet(dx: CGFloat, dy: CGFloat) { if dx.isFinite && dy.isFinite { pet.drag(dx: dx, dy: dy) } }

    public func reportDroppedPaths(_ paths: [String]) {
        let list = Array(paths.prefix(200))
        if list.isEmpty { return }
        showPanelWithoutToggling()
        events.droppedPaths.send(list)
    }

    // MARK: - Memory

    public func listMemories() async -> [Memory] { (try? store.listMemories()) ?? [] }

    public func deleteMemory(_ id: String) async -> [Memory] {
        try? store.deleteMemories([id])
        let all = (try? store.listMemories()) ?? []
        events.memoriesChanged.send(all)
        return all
    }

    public func clearMemories() async -> [Memory] {
        try? store.clearMemories()
        events.memoriesChanged.send([])
        return []
    }

    // MARK: - Driving the screen

    public func stopDesktopSession() { runner?.cancel() }

    private func registerStopShortcut() {
        guard stopHotKey == nil else { return }
        stopHotKey = HotKey(accelerator: DesktopSession.stopAccelerator) { [weak self] in self?.desktopSession.requestStop() }
    }

    /// While Merry borrows the screen it must be visible and interruptible.
    private func showIndicator(_ reason: String) {
        hideIndicator()
        let size = NSSize(width: 360, height: 34)
        let area = ScreenSpace.primaryWorkArea
        let frame = ScreenSpace.toAppKit(CGRect(x: area.minX + ((area.width - size.width) / 2).rounded(), y: area.minY + 12, width: size.width, height: size.height))
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView:
            HStack(spacing: 10) {
                Text(verbatim: reason.isEmpty ? "Merry is using your screen" : reason).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "⌘⇧Esc to stop").font(Chrome.mono(11)).foregroundStyle(Chrome.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(width: size.width, height: size.height)
            .background(WindowGlass(cornerRadius: 17))
        )
        window.orderFrontRegardless()
        indicator = window
    }

    private func hideIndicator() {
        indicator?.orderOut(nil)
        indicator = nil
    }

    // MARK: - Shortcut and menu bar

    /// Merry opens with one chord, from anywhere. If another app already holds
    /// the chosen key, the next free one is used and saved, so the key shown in
    /// the menu and in setup is always the one that works.
    private static let shortcutFallbacks = ["Command+Shift+Space", "Alt+Shift+Space", "CommandOrControl+Shift+K"]

    @discardableResult
    private func registerShortcut(_ accelerator: String) -> Bool {
        hotKey?.unregister()
        hotKey = nil
        for key in [accelerator] + Self.shortcutFallbacks.filter({ $0 != accelerator }) {
            guard let made = HotKey(accelerator: key, handler: { [weak self] in self?.togglePanel() }) else { continue }
            hotKey = made
            if key != accelerator {
                NSLog("The shortcut %@ is taken by another app; using %@ instead.", accelerator, key)
                save { $0.shortcut = key }
            }
            return key == accelerator
        }
        return false
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = MerryResources.menuBarImage()
        button.imagePosition = .imageLeading
        button.toolTip = "Merry: click to open, right-click for more"
        button.target = self
        button.action = #selector(statusItemClicked)
        // One click opens Merry; the menu is for the other button.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
            add("Open Merry", #selector(menuOpen))
            add("Workspace & timers", #selector(menuWorkspace))
            if settings.petMode == .desktop { add("Hide the pet", #selector(menuHidePet)) } else { add("Show the pet", #selector(menuShowPet)) }
            add("Center the panel", #selector(menuCenter))
            menu.addItem(.separator())
            add("Stop current task", #selector(menuStop))
            menu.addItem(.separator())
            add("Uninstall Merry…", #selector(menuUninstall))
            add("Quit Merry", #selector(menuQuit))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePanel()
    }

    @objc private func menuOpen() { togglePanel() }
    @objc private func menuWorkspace() { openBrain() }
    @objc private func menuShowPet() { setPetMode(.desktop) }
    @objc private func menuHidePet() { setPetMode(.menubar) }

    /// Puts the pet on the desktop, or takes it off, and remembers the choice.
    private func setPetMode(_ mode: PetMode) {
        save { $0.petMode = mode; $0.petModeChosen = true }
        if mode == .desktop { pet.recentre(); pet.presence.reveal() }
        broadcastBrain()
        pet.presence.update()
        statusItem.button?.title = ""
        events.settingsChanged.send(settings)
    }
    @objc private func menuCenter() { centerPanel() }
    @objc private func menuStop() { runner?.cancel() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuUninstall() {
        showPanel()
        Task {
            do { _ = try await uninstaller.uninstall() } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Couldn’t uninstall Merry"
                alert.informativeText = messageOf(error)
                alert.runModal()
            }
        }
    }
}

extension AppController: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            notificationActions[id]?()
            notificationActions[id] = nil
        }
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

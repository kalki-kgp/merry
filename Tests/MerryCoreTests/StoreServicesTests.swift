import Testing
@testable import MerryCore

// MARK: - Settings

@Test func savedSettingsMigrateLikeTheOriginal() {
    let rows = Fixture.load("stores-misc").list("settings")
    #expect(rows.count > 35)
    let known = Set(JSON.encode(Settings()).objectValue?.keys ?? []).union(["shortcutChosen", "petModeChosen"])
    for row in rows {
        let raw = row.optStr("raw")
        let got = JSON.encode(settingsFromSaved(raw))
        // The reference carries unknown saved keys along untouched; a typed value has no room for them.
        var expected = JSONObject()
        for (key, value) in row["settings"]!.objectValue!.pairs where known.contains(key) { expected[key] = value }
        #expect(got.firstDifference(from: .object(expected)) == nil, "\(raw ?? "null")")
    }
}

@Test func settingsLoadAndSaveThroughTheStore() throws {
    let store = try Store.inMemory()
    defer { store.close() }
    #expect(store.loadSettings() == Settings())
    var settings = Settings()
    settings.onboarded = true
    settings.shortcut = "Alt+Space"
    settings.shortcutChosen = true
    settings.petMode = .desktop
    settings.codingApp = .codex
    settings.panelX = 412.5
    try store.saveSettings(settings)
    // petMode was not marked as chosen, so the default applies again.
    var expected = settings
    expected.petMode = .ondemand
    #expect(store.loadSettings() == expected)
    settings.petModeChosen = true
    try store.saveSettings(settings)
    #expect(store.loadSettings() == settings)
    #expect(try JSON.parse(try #require(try store.getSetting("settings"))).str("shortcut") == "Alt+Space")
    try store.setSetting("settings", "{broken")
    #expect(store.loadSettings() == Settings())
}

// MARK: - Uninstall

@Test func installedBundleIsFoundLikeTheOriginal() {
    let rows = Fixture.load("stores-misc").list("bundles")
    #expect(rows.count > 60)
    for row in rows {
        #expect(installedAppBundle(executable: row.str("executable"), packaged: row.flag("packaged")) == row.optStr("bundle"), "\(row.str("executable")) packaged=\(row.flag("packaged"))")
    }
}

private struct TrashFailed: Error {}

private func uninstallDeps(
    executable: String = "/Applications/Merry.app/Contents/MacOS/Merry", packaged: Bool = true,
    confirm: @escaping @Sendable () async -> Bool = { true }, loginEnabled: Bool = true,
    trash: @escaping @Sendable (String) async throws -> Void = { _ in }, events: Recorder<String>
) -> UninstallDeps {
    UninstallDeps(
        executable: { executable }, packaged: { packaged }, confirm: confirm,
        loginEnabled: { loginEnabled }, setLoginEnabled: { events.add("login=\($0)") },
        stopWork: { events.add("stop") }, trash: { events.add("trash \($0)"); try await trash($0) }, quit: { events.add("quit") }
    )
}

@Test func uninstallTrashesTheBundleAndQuits() async throws {
    let events = Recorder<String>()
    let uninstaller = AppUninstaller(deps: uninstallDeps(events: events))
    #expect(uninstaller.available)
    #expect(try await uninstaller.uninstall())
    #expect(events.values == ["login=false", "stop", "trash /Applications/Merry.app", "quit"])
    #expect(!uninstaller.inProgress)
}

@Test func uninstallDoesNothingWhenNotConfirmed() async throws {
    let events = Recorder<String>()
    let uninstaller = AppUninstaller(deps: uninstallDeps(confirm: { false }, events: events))
    #expect(try await uninstaller.uninstall() == false)
    #expect(events.values.isEmpty)
    #expect(!uninstaller.inProgress)
}

@Test func uninstallRestoresTheLoginItemWhenTrashFails() async {
    for wasEnabled in [true, false] {
        let events = Recorder<String>()
        let uninstaller = AppUninstaller(deps: uninstallDeps(loginEnabled: wasEnabled, trash: { _ in throw TrashFailed() }, events: events))
        await #expect(throws: TrashFailed.self) { try await uninstaller.uninstall() }
        #expect(events.values == ["login=false", "stop", "trash /Applications/Merry.app", "login=\(wasEnabled)"])
        #expect(!uninstaller.inProgress)
    }
}

@Test func uninstallIsOnlyOfferedInTheInstalledApp() async {
    let events = Recorder<String>()
    for deps in [uninstallDeps(packaged: false, events: events), uninstallDeps(executable: "/Users/someone/merry/.build/debug/Merry", events: events)] {
        let uninstaller = AppUninstaller(deps: deps)
        #expect(!uninstaller.available)
        do {
            _ = try await uninstaller.uninstall()
            Issue.record("should have refused")
        } catch {
            #expect(messageOf(error) == "Uninstall is available in the installed Merry app.")
        }
    }
    #expect(events.values.isEmpty)
}

@Test func uninstallRefusesToRunTwiceAtOnce() async throws {
    let events = Recorder<String>()
    let asked = AsyncStream<Void>.makeStream()
    let answer = AsyncStream<Bool>.makeStream()
    let uninstaller = AppUninstaller(deps: uninstallDeps(confirm: {
        asked.continuation.yield()
        for await value in answer.stream { return value }
        return false
    }, events: events))

    let first = Task { try await uninstaller.uninstall() }
    for await _ in asked.stream { break }
    #expect(uninstaller.inProgress)
    do {
        _ = try await uninstaller.uninstall()
        Issue.record("a second uninstall should have been refused")
    } catch {
        #expect(messageOf(error) == "Merry is already being uninstalled.")
    }
    answer.continuation.yield(true)
    #expect(try await first.value)
    #expect(events.values == ["login=false", "stop", "trash /Applications/Merry.app", "quit"])
    #expect(!uninstaller.inProgress)
}

// MARK: - Undo

/// A store holding one task whose actions carry the given undo entries, oldest first.
private func storeWithUndo(_ entries: [(id: String, undo: UndoEntry)], failed: Set<String> = []) throws -> Store {
    let store = try Store.inMemory()
    var task = TaskState(id: "task", request: "Tidy", now: 1000)
    task.status = .succeeded
    task.actions = entries.enumerated().map { index, entry in
        var action = ActionRecord(id: entry.id, step: index + 1, tool: "files_move", input: [:], startedAt: 2000 + Double(index), outcome: failed.contains(entry.id) ? .failure : .success)
        action.undo = entry.undo
        return action
    }
    try store.saveTask(task)
    return store
}

private let noMac: (UndoEntry) async -> (ok: Bool, reason: String) = { _ in (false, "no app changes in this test") }

@Test func undoMovesAFileBackOnce() async throws {
    let dir = Scratch.directory("undo")
    defer { Scratch.remove(dir) }
    let from = Path.join(dir, "Downloads", "deep", "report.pdf"), to = Path.join(dir, "Sorted", "report.pdf")
    Scratch.write(to, "contents")
    let store = try storeWithUndo([("move", UndoEntry(kind: .fileMove, from: from, to: to))])
    defer { store.close() }

    var report = await undoTask(store: store, taskId: "task", reverseMac: noMac)
    #expect(report.reversed == 1 && report.skipped.isEmpty)
    // The folder it came from no longer existed and was put back too.
    #expect(Scratch.read(from) == "contents")
    #expect(!Scratch.exists(to))
    #expect(try store.undoableActions("task").isEmpty)
    #expect(try store.listTasks().first?.undoable == false)

    // Not applied twice: a second undo has nothing left to do, even if the file is moved again.
    Scratch.move(from, to)
    report = await undoTask(store: store, taskId: "task", reverseMac: noMac)
    #expect(report == UndoReport())
    #expect(Scratch.exists(to) && !Scratch.exists(from))
}

@Test func undoRefusesWhenTheWorldHasMovedOn() async throws {
    let dir = Scratch.directory("undo")
    defer { Scratch.remove(dir) }
    let p = { (name: String) in Path.join(dir, name) }
    // Something now occupies the original path.
    Scratch.write(p("out/occupied.txt"), "merry's")
    Scratch.write(p("in/occupied.txt"), "someone else's")
    // The person has since moved the file away.
    Scratch.write(p("elsewhere/gone.txt"))
    // A rename, and a plain move, that can still be reversed.
    Scratch.write(p("out/new-name.txt"), "renamed")
    Scratch.write(p("out/fine.txt"), "fine")
    let store = try storeWithUndo([
        ("occupied", UndoEntry(kind: .fileMove, from: p("in/occupied.txt"), to: p("out/occupied.txt"))),
        ("gone", UndoEntry(kind: .fileMove, from: p("in/gone.txt"), to: p("out/gone.txt"))),
        ("rename", UndoEntry(kind: .fileRename, from: p("out/old-name.txt"), to: p("out/new-name.txt"))),
        ("failed", UndoEntry(kind: .fileMove, from: p("in/never.txt"), to: p("out/fine.txt"))),
        ("fine", UndoEntry(kind: .fileMove, from: p("in/fine.txt"), to: p("out/fine.txt")))
    ], failed: ["failed"])
    defer { store.close() }

    let report = await undoTask(store: store, taskId: "task", reverseMac: noMac)
    #expect(report.reversed == 2)
    // Newest first.
    #expect(report.skipped == [
        .init(path: p("out/gone.txt"), reason: "the file is no longer where Merry put it"),
        .init(path: p("in/occupied.txt"), reason: "something else now occupies the original path")
    ])
    #expect(Scratch.read(p("in/occupied.txt")) == "someone else's")
    #expect(Scratch.read(p("out/occupied.txt")) == "merry's")
    #expect(Scratch.exists(p("elsewhere/gone.txt")) && !Scratch.exists(p("in/gone.txt")))
    #expect(Scratch.read(p("out/old-name.txt")) == "renamed")
    #expect(Scratch.exists(p("in/fine.txt")) && !Scratch.exists(p("in/never.txt")))
    // What was skipped can be tried again later; what was reversed cannot.
    #expect(try store.undoableActions("task").map(\.id) == ["gone", "occupied"])
}

@Test func undoOnlyRemovesFoldersThatAreStillEmpty() async throws {
    let dir = Scratch.directory("undo")
    defer { Scratch.remove(dir) }
    let p = { (name: String) in Path.join(dir, name) }
    Scratch.mkdir(p("empty"))
    Scratch.write(p("full/kept.txt"), "keep me")
    Scratch.write(p("full/.hidden"), "and me")
    let store = try storeWithUndo([
        ("empty", UndoEntry(kind: .folderCreate, from: "", to: p("empty"))),
        ("full", UndoEntry(kind: .folderCreate, from: "", to: p("full"))),
        ("missing", UndoEntry(kind: .folderCreate, from: "", to: p("missing")))
    ])
    defer { store.close() }

    let report = await undoTask(store: store, taskId: "task", reverseMac: noMac)
    #expect(report.reversed == 1)
    #expect(report.skipped == [
        .init(path: p("missing"), reason: "folder is already gone"),
        .init(path: p("full"), reason: "folder is not empty (2 items)")
    ])
    #expect(!Scratch.exists(p("empty")))
    #expect(Scratch.read(p("full/kept.txt")) == "keep me")
    // Already gone counts as dealt with; the folder holding files stays on the list.
    #expect(try store.undoableActions("task").map(\.id) == ["full"])
}

@Test func undoMovesFilesOutBeforeRemovingTheFolderMadeForThem() async throws {
    let dir = Scratch.directory("undo")
    defer { Scratch.remove(dir) }
    let p = { (name: String) in Path.join(dir, name) }
    Scratch.write(p("Sorted/a.txt"))
    let store = try storeWithUndo([
        ("folder", UndoEntry(kind: .folderCreate, from: "", to: p("Sorted"))),
        ("move", UndoEntry(kind: .fileMove, from: p("a.txt"), to: p("Sorted/a.txt")))
    ])
    defer { store.close() }
    let report = await undoTask(store: store, taskId: "task", reverseMac: noMac)
    #expect(report.reversed == 2 && report.skipped.isEmpty)
    #expect(Scratch.exists(p("a.txt")) && !Scratch.exists(p("Sorted")))
}

@Test func undoSendsAppChangesThroughTheGivenReversal() async throws {
    let store = try storeWithUndo([
        ("event", UndoEntry(kind: .macEvent, from: "Calendar", to: "EVENT-1")),
        ("reminder", UndoEntry(kind: .macReminder, from: "Reminders", to: "REM-2")),
        ("note", UndoEntry(kind: .macNote, from: "Notes", to: "NOTE-3")),
        ("setting", UndoEntry(kind: .macSetting, from: "dark", to: "true"))
    ])
    defer { store.close() }
    let seen = Recorder<UndoEntry>()
    let report = await undoTask(store: store, taskId: "task") { entry in
        seen.add(entry)
        switch entry.kind {
        case .macReminder: return (false, "the reminder is already gone")
        case .macNote: return (false, "Notes did not answer")
        default: return (true, "")
        }
    }
    #expect(seen.values.map(\.kind) == [.macSetting, .macNote, .macReminder, .macEvent])
    #expect(seen.values.map(\.payload.to) == ["true", "NOTE-3", "REM-2", "EVENT-1"])
    #expect(report.reversed == 2)
    #expect(report.skipped == [
        .init(path: "Notes: NOTE-3", reason: "Notes did not answer"),
        .init(path: "Reminders: REM-2", reason: "the reminder is already gone")
    ])
    // Already gone is as good as reversed; a refusal can be tried again.
    #expect(try store.undoableActions("task").map(\.id) == ["note"])
    #expect(await undoTask(store: store, taskId: "nobody", reverseMac: noMac) == UndoReport())
}

// MARK: - Setup

@Test func setupListsWhatIsInstalledWithItsStatus() async throws {
    let rig = try SetupRig()
    defer { rig.close() }
    rig.os.grant(.accessibility, true)
    rig.os.grant(.screenRecording, false)
    rig.os.set("com.apple.iCal", .granted)
    rig.os.set("com.apple.reminders", .denied)
    rig.os.set("com.apple.Notes", .notRunning)
    rig.os.set("com.apple.mail", .notAsked)
    rig.os.set("com.apple.finder", .unknown)
    rig.os.set("com.apple.Safari", .granted)
    rig.os.set("com.google.Chrome", .notRunning)
    // System Events, Arc, Brave and Edge are not installed.

    let items = await rig.setup.list()
    #expect(items.map(\.id) == ["accessibility", "screen-recording", "app:com.apple.iCal", "app:com.apple.reminders", "app:com.apple.Notes", "app:com.apple.mail", "app:com.apple.finder", "app:com.google.Chrome", "app:com.apple.Safari", "folder:Desktop", "folder:Documents", "folder:Downloads", "notifications"])
    #expect(items.map(\.status) == [.granted, .notAsked, .granted, .denied, .notAsked, .notAsked, .notAsked, .notAsked, .granted, .notAsked, .notAsked, .notAsked, .notAsked])
    #expect(items.map(\.group) == [.control, .control, .apps, .apps, .apps, .apps, .apps, .browsers, .browsers, .folders, .folders, .folders, .alerts])
    #expect(items[0] == SetupItem(id: "accessibility", group: .control, label: "Accessibility", purpose: "Read what is in app windows, press their buttons, and see the text you have selected.", status: .granted))
    #expect(items[4].hint == nil)
    #expect(items[7].hint == "To read and click in pages, also turn on View → Developer → Allow JavaScript from Apple Events in this browser.")
    #expect(items[8].hint == "To read and click in pages, also turn on Safari → Settings → Advanced → Show features for web developers, then Develop → Allow JavaScript from Apple Events.")
    // Reading statuses never asks for anything.
    #expect(rig.os.calls.isEmpty && rig.notified.values.isEmpty && rig.opened.values.isEmpty)
    // Definite answers are remembered for when the app is closed.
    #expect(rig.answers() == ["app:com.apple.iCal": "granted", "app:com.apple.reminders": "denied", "app:com.apple.Safari": "granted"])

    rig.os.set("com.apple.iCal", .notRunning)
    rig.os.set("com.apple.reminders", .notRunning)
    rig.os.set("com.apple.Safari", .notInstalled)
    let later = await rig.setup.list()
    #expect(later.first { $0.id == "app:com.apple.iCal" }?.status == .granted)
    #expect(later.first { $0.id == "app:com.apple.reminders" }?.status == .denied)
    #expect(!later.contains { $0.id == "app:com.apple.Safari" })
    // An app that was removed loses its remembered answer.
    #expect(rig.answers() == ["app:com.apple.iCal": "granted", "app:com.apple.reminders": "denied"])

    rig.os.fail(true)
    let broken = await rig.setup.list()
    #expect(broken.filter { $0.group != .folders && $0.group != .alerts }.allSatisfy { $0.status == .unknown })
    #expect(broken.count == 17)
}

@Test func setupRequestsOneThingAtATime() async throws {
    let rig = try SetupRig()
    defer { rig.close() }

    // Control: the adapter opens the pane, and the status is read back.
    #expect(try await rig.setup.request("accessibility").status == .notAsked)
    rig.os.grant(.screenRecording, true)
    #expect(try await rig.setup.request("screen-recording").status == .granted)

    // Apps: asking is what prompts, and a definite answer is remembered.
    rig.os.set("com.apple.Notes", .notAsked)
    rig.os.whenAsked("com.apple.Notes", .granted)
    #expect(try await rig.setup.request("app:com.apple.Notes") == SetupItem(id: "app:com.apple.Notes", group: .apps, label: "Notes", purpose: "Search, read and save notes.", status: .granted))
    rig.os.set("com.apple.mail", .notAsked)
    rig.os.whenAsked("com.apple.mail", .denied)
    #expect(try await rig.setup.request("app:com.apple.mail").status == .denied)
    rig.os.set("com.apple.finder", .notRunning)
    #expect(try await rig.setup.request("app:com.apple.finder").status == .unknown)
    #expect(try await rig.setup.request("app:com.brave.Browser").status == .notInstalled)
    rig.os.set("com.apple.iCal", .notAsked)
    #expect(try await rig.setup.request("app:com.apple.iCal").status == .notAsked)
    #expect(rig.os.calls == ["request accessibility", "request screen-recording", "ask com.apple.Notes", "ask com.apple.mail", "ask com.apple.finder", "ask com.brave.Browser", "ask com.apple.iCal"])
    #expect(rig.answers() == ["app:com.apple.Notes": "granted", "app:com.apple.mail": "denied"])

    // Folders: reading the folder is the question, and the result is the answer.
    Scratch.mkdir(Path.join(rig.home, "Desktop"))
    Scratch.mkdir(Path.join(rig.home, "Documents"))
    Scratch.chmod(Path.join(rig.home, "Documents"), 0o000)
    defer { Scratch.chmod(Path.join(rig.home, "Documents"), 0o755) }
    #expect(try await rig.setup.request("folder:Desktop").status == .granted)
    if !Scratch.isRoot { #expect(try await rig.setup.request("folder:Documents").status == .denied) }
    // A folder that is not there is neither a yes nor a no.
    #expect(try await rig.setup.request("folder:Downloads").status == .unknown)

    // Notifications: the first one shown is the question; the answer cannot be read back.
    #expect(rig.notified.values.isEmpty)
    #expect(try await rig.setup.request("notifications").status == .asked)
    #expect(rig.notified.values == [true])
    #expect(Setup.notificationBody == "This is how I’ll tap you on the shoulder for reminders.")

    let statuses = Dictionary(uniqueKeysWithValues: await rig.setup.list().map { ($0.id, $0.status) })
    #expect(statuses["folder:Desktop"] == .granted)
    #expect(statuses["folder:Downloads"] == .unknown)
    #expect(statuses["notifications"] == .asked)
    #expect(statuses["app:com.apple.Notes"] == .granted)

    do {
        _ = try await rig.setup.request("app:com.example.nope")
        Issue.record("an unknown item should be refused")
    } catch {
        #expect(messageOf(error) == "Unknown setup item: app:com.example.nope")
    }
}

@Test func setupOpensTheRightSettingsPane() async throws {
    let rig = try SetupRig()
    defer { rig.close() }
    for id in ["accessibility", "screen-recording", "app:com.apple.Notes", "app:com.apple.Safari", "folder:Downloads", "notifications"] {
        try await rig.setup.openSettings(id)
    }
    #expect(rig.opened.values == [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    ])
    do {
        try await rig.setup.openSettings("x-apple.systempreferences:evil")
        Issue.record("an unknown item should be refused")
    } catch {
        #expect(messageOf(error) == "Unknown setup item: x-apple.systempreferences:evil")
    }
    #expect(rig.opened.values.count == 6)
    #expect(isSetupId("notifications") && isSetupId("folder:Desktop") && Setup.isSetupId("app:com.apple.iCal"))
    #expect(!isSetupId("folder:Movies") && !isSetupId("") && !isSetupId(nil))
}

// MARK: - Secrets

@Test func secretsLiveInTheKeychainWithEnvironmentFallbacks() {
    let keychain = MemoryKeychain()
    let secrets = Secrets(service: "app.merry.tests", keychain: keychain, environment: { [:] })
    #expect(secrets.available)
    #expect(secrets.getApiKey() == nil && !secrets.hasApiKey() && secrets.getJevKey() == nil && !secrets.hasJevKey())

    #expect(secrets.setApiKey("  sk-ant-123  \n"))
    #expect(secrets.getApiKey() == "sk-ant-123" && secrets.hasApiKey())
    // A separate provider needs a separate credential.
    #expect(!secrets.hasJevKey())
    #expect(secrets.setJevKey("ts-456"))
    #expect(secrets.getJevKey() == "ts-456" && secrets.getApiKey() == "sk-ant-123")
    #expect(keychain.read(service: "app.merry.tests", account: "anthropic_api_key") == "sk-ant-123")
    #expect(keychain.read(service: "app.merry.tests", account: "typesafe_api_key") == "ts-456")
    #expect(keychain.read(service: "another.app", account: "anthropic_api_key") == nil)

    #expect(secrets.setApiKey("sk-ant-new"))
    #expect(secrets.getApiKey() == "sk-ant-new")
    // An empty string clears.
    #expect(secrets.setApiKey("   "))
    #expect(secrets.getApiKey() == nil && !secrets.hasApiKey() && secrets.hasJevKey())
    #expect(secrets.setJevKey(""))
    #expect(!secrets.hasJevKey())
}

@Test func secretsFallBackToTheEnvironment() {
    let keychain = MemoryKeychain()
    let secrets = Secrets(service: "app.merry.tests", keychain: keychain, environment: { ["ANTHROPIC_API_KEY": "env-anthropic", "TYPESAFE_API_KEY": "env-typesafe", "OTHER": "x"] })
    #expect(secrets.getApiKey() == "env-anthropic" && secrets.getJevKey() == "env-typesafe" && secrets.hasApiKey() && secrets.hasJevKey())
    // A stored key wins over the environment.
    #expect(secrets.setApiKey("stored"))
    #expect(secrets.getApiKey() == "stored" && secrets.getJevKey() == "env-typesafe")

    // Without a keychain nothing can be stored or read, but clearing still succeeds.
    keychain.available = false
    #expect(!secrets.available)
    #expect(secrets.getApiKey() == "env-anthropic")
    #expect(!secrets.setJevKey("cannot store"))
    #expect(secrets.getJevKey() == "env-typesafe")
    #expect(secrets.setApiKey(""))
    keychain.available = true
    #expect(secrets.getApiKey() == "env-anthropic")

    let empty = Secrets(service: "app.merry.tests", keychain: MemoryKeychain(), environment: { ["ANTHROPIC_API_KEY": ""] })
    #expect(empty.getApiKey() == "" && !empty.hasApiKey())
}

// MARK: - Desktop session

@Test func desktopSessionIsHeldByOneTaskAtATime() throws {
    let events = Recorder<String>()
    let session = DesktopSession(hooks: .init(
        showIndicator: { events.add("show \($0)") }, hideIndicator: { events.add("hide") },
        registerStopShortcut: { events.add("register") }, unregisterStopShortcut: { events.add("unregister") }
    ))
    session.onChanged = { events.add("changed \($0)") }
    session.onStopRequested = { events.add("stop \($0 ?? "nil")") }
    #expect(!session.isActive && session.activeTaskId == nil)

    try session.claim("one", reason: "Clicking in Notes")
    #expect(session.isActive && session.activeTaskId == "one")
    #expect(events.values == ["show Clicking in Notes", "register", "changed true"])
    // Claiming again by the holder changes nothing.
    try session.claim("one", reason: "Still clicking")
    #expect(events.values.count == 3)

    do {
        try session.claim("two", reason: "Me too")
        Issue.record("a second task should be refused")
    } catch {
        #expect(messageOf(error) == "another task is already controlling the desktop")
    }
    #expect(session.activeTaskId == "one")
    // Only the holder can let go.
    session.release("two")
    #expect(session.activeTaskId == "one" && events.values.count == 3)

    session.requestStop()
    #expect(events.values.last == "stop one")
    session.release("one")
    #expect(!session.isActive)
    #expect(events.values.suffix(3) == ["hide", "unregister", "changed false"])

    try session.claim("two", reason: "Now me")
    #expect(session.activeTaskId == "two")
    session.dispose()
    #expect(!session.isActive)
    #expect(events.values.suffix(5) == ["show Now me", "register", "changed true", "hide", "unregister"])
    session.requestStop()
    #expect(events.values.last == "stop nil")
    #expect(DesktopSession.stopAccelerator == "CommandOrControl+Shift+Escape")
}

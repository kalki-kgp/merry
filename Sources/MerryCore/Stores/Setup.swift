import Foundation

// Everything Merry can be allowed to do on this Mac, in one list.
//
// Onboarding walks through it and Settings shows it again. Reading a status
// never triggers a macOS prompt; `request` is the only thing that does, and
// only for the one item the person chose.

private struct SetupDefinition: Sendable {
    var id: String
    var group: SetupGroup
    var label: String
    var purpose: String
    var hint: String?
    /// For apps and browsers: the bundle id Apple Events are addressed to.
    var bundleId: String?
    /// For folders: the name under the home folder.
    var folder: String?

    init(_ id: String, _ group: SetupGroup, _ label: String, bundleId: String? = nil, folder: String? = nil, purpose: String, hint: String? = nil) {
        self.id = id; self.group = group; self.label = label; self.purpose = purpose; self.hint = hint; self.bundleId = bundleId; self.folder = folder
    }
}

private let jsFromAppleEvents = "To read and click in pages, also turn on View → Developer → Allow JavaScript from Apple Events in this browser."

private let definitions: [SetupDefinition] = [
    .init("accessibility", .control, "Accessibility", purpose: "Read what is in app windows, press their buttons, and see the text you have selected."),
    .init("screen-recording", .control, "Screen Recording", purpose: "Look at one window when an app has no readable controls. Only when a task needs it; nothing is recorded or kept."),
    .init("app:com.apple.iCal", .apps, "Calendar", bundleId: "com.apple.iCal", purpose: "Read your agenda, find free time, and add events you ask for."),
    .init("app:com.apple.reminders", .apps, "Reminders", bundleId: "com.apple.reminders", purpose: "List, add and complete reminders."),
    .init("app:com.apple.Notes", .apps, "Notes", bundleId: "com.apple.Notes", purpose: "Search, read and save notes."),
    .init("app:com.apple.mail", .apps, "Mail", bundleId: "com.apple.mail", purpose: "Open drafts for you to check and send. Merry never sends mail itself."),
    .init("app:com.apple.finder", .apps, "Finder", bundleId: "com.apple.finder", purpose: "See which files you have selected, so “these” means them."),
    .init("app:com.apple.systemevents", .apps, "System Events", bundleId: "com.apple.systemevents", purpose: "See which apps are open, switch dark mode, and read your selection."),
    .init("app:com.google.Chrome", .browsers, "Google Chrome", bundleId: "com.google.Chrome", purpose: "See your open tabs, read the page you are on, and open new tabs.", hint: jsFromAppleEvents),
    .init("app:com.apple.Safari", .browsers, "Safari", bundleId: "com.apple.Safari", purpose: "See your open tabs, read the page you are on, and open new tabs.", hint: "To read and click in pages, also turn on Safari → Settings → Advanced → Show features for web developers, then Develop → Allow JavaScript from Apple Events."),
    .init("app:company.thebrowser.Browser", .browsers, "Arc", bundleId: "company.thebrowser.Browser", purpose: "See your open tabs, read the page you are on, and open new tabs.", hint: jsFromAppleEvents),
    .init("app:com.brave.Browser", .browsers, "Brave", bundleId: "com.brave.Browser", purpose: "See your open tabs, read the page you are on, and open new tabs.", hint: jsFromAppleEvents),
    .init("app:com.microsoft.edgemac", .browsers, "Microsoft Edge", bundleId: "com.microsoft.edgemac", purpose: "See your open tabs, read the page you are on, and open new tabs.", hint: jsFromAppleEvents),
    .init("folder:Desktop", .folders, "Desktop", folder: "Desktop", purpose: "Find, tidy and rename files on your Desktop when you ask."),
    .init("folder:Documents", .folders, "Documents", folder: "Documents", purpose: "Find, tidy and rename files in Documents when you ask."),
    .init("folder:Downloads", .folders, "Downloads", folder: "Downloads", purpose: "Find, tidy and rename files in Downloads when you ask."),
    .init("notifications", .alerts, "Notifications", purpose: "Tap you on the shoulder for reminders and when a focus timer ends.")
]

/// Where each answer can be changed later. Fixed addresses, never built from input.
private func settingsPane(_ def: SetupDefinition) -> String {
    if def.id == "accessibility" { return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" }
    if def.id == "screen-recording" { return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" }
    switch def.group {
    case .control: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case .apps, .browsers: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    case .folders: return "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    case .alerts: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    }
}

private let answersKey = "setup_answers"

public final class Setup: @unchecked Sendable {
    private let os: OsAdapter
    private let store: Store
    private let notify: @Sendable () async -> Void
    private let openURL: @Sendable (String) async -> Void
    private let home: @Sendable () -> String
    /// Statuses are read side by side; remembering one is a read-then-write.
    private let lock = NSLock()

    /// - Parameters:
    ///   - notify: shows the first notification, which is what makes macOS ask
    ///     ("Merry" / `Setup.notificationBody`, silent). Do nothing where notifications are unsupported.
    ///   - openURL: opens a System Settings pane.
    ///   - home: the folder Desktop, Documents and Downloads are looked for in.
    public init(os: OsAdapter, store: Store, notify: @escaping @Sendable () async -> Void, openURL: @escaping @Sendable (String) async -> Void, home: @escaping @Sendable () -> String = { Path.home }) {
        self.home = home
        self.os = os
        self.store = store
        self.notify = notify
        self.openURL = openURL
    }

    /// What the first notification says.
    public static let notificationTitle = "Merry"
    public static let notificationBody = "This is how I’ll tap you on the shoulder for reminders."

    public static func isSetupId(_ id: String?) -> Bool {
        guard let id else { return false }
        return definitions.contains { $0.id == id }
    }

    /// The whole list with current answers. Apps and browsers that are not installed are left out.
    public func list() async -> [SetupItem] {
        let items = await withTaskGroup(of: (Int, SetupItem).self) { group -> [SetupItem] in
            for (index, def) in definitions.enumerated() {
                group.addTask { (index, await self.status(def)) }
            }
            var found: [(Int, SetupItem)] = []
            for await pair in group { found.append(pair) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return items.filter { $0.status != .notInstalled }
    }

    /// Asks for one item and reports where it landed.
    public func request(_ id: String) async throws -> SetupItem {
        guard let def = definitions.first(where: { $0.id == id }) else { throw MerryError("Unknown setup item: \(id)") }
        if def.id == "accessibility" || def.id == "screen-recording" {
            // Both are switched on in System Settings; the adapter opens the pane.
            _ = try await os.requestPermission(def.id == "accessibility" ? .accessibility : .screenRecording)
            return await status(def)
        }
        if let bundleId = def.bundleId {
            let status = try await os.automationPermission(bundleId: bundleId, ask: true)
            if status == .granted { remember(def.id, .granted) }
            if status == .denied { remember(def.id, .denied) }
            return item(def, status == .notRunning ? .unknown : setupStatus(status))
        }
        if let folder = def.folder {
            // Reading the folder is what makes macOS ask; the answer is the result.
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: Path.join(home(), folder))
                remember(def.id, .granted)
            } catch {
                remember(def.id, isPermissionError(error) ? .denied : .unknown)
            }
            return await status(def)
        }
        // Notifications: the first one shown is what makes macOS ask.
        await notify()
        remember(def.id, .asked)
        return await status(def)
    }

    public func openSettings(_ id: String) async throws {
        guard let def = definitions.first(where: { $0.id == id }) else { throw MerryError("Unknown setup item: \(id)") }
        await openURL(settingsPane(def))
    }

    private func status(_ def: SetupDefinition) async -> SetupItem {
        do {
            if def.id == "accessibility" || def.id == "screen-recording" {
                let perms = try await os.getPermissions()
                let granted = perms.first { $0.permission.rawValue == def.id }?.granted ?? false
                return item(def, granted ? .granted : .notAsked)
            }
            if let bundleId = def.bundleId {
                let status = try await os.automationPermission(bundleId: bundleId, ask: false)
                if status == .granted || status == .denied || status == .notInstalled {
                    remember(def.id, status == .notInstalled ? nil : setupStatus(status))
                    return item(def, setupStatus(status))
                }
                // macOS only answers for an app that is open; otherwise use the last answer seen.
                return item(def, answers()[def.id] ?? .notAsked)
            }
            return item(def, answers()[def.id] ?? .notAsked)
        } catch {
            return item(def, .unknown)
        }
    }

    private func setupStatus(_ status: AutomationStatus) -> SetupStatus {
        switch status {
        case .granted: return .granted
        case .denied: return .denied
        case .notAsked: return .notAsked
        case .notInstalled: return .notInstalled
        case .notRunning, .unknown: return .unknown
        }
    }

    private func item(_ def: SetupDefinition, _ status: SetupStatus) -> SetupItem {
        SetupItem(id: def.id, group: def.group, label: def.label, purpose: def.purpose, status: status, hint: (def.hint ?? "").isEmpty ? nil : def.hint)
    }

    /// EPERM or EACCES, however Foundation chose to wrap it.
    private func isPermissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain, e.code == Int(EPERM) || e.code == Int(EACCES) { return true }
            if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoPermissionError { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func answers() -> [String: SetupStatus] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: SetupStatus] = [:]
        for (key, value) in readAnswers().pairs { out[key] = value.stringValue.flatMap(SetupStatus.init(rawValue:)) }
        return out
    }

    /// Call with the lock held.
    private func readAnswers() -> JSONObject {
        guard let text = try? store.getSetting(answersKey), let parsed = try? JSON.parse(text), case .object(let object) = parsed else { return JSONObject() }
        return object
    }

    private func remember(_ id: String, _ status: SetupStatus?) {
        lock.lock(); defer { lock.unlock() }
        var answers = readAnswers()
        if answers[id]?.stringValue == status?.rawValue { return }
        answers[id] = status.map { .string($0.rawValue) }
        try? store.setSetting(answersKey, JSON.object(answers).stringify())
    }
}

public func isSetupId(_ id: String?) -> Bool { Setup.isSetupId(id) }

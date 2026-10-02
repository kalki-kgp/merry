import Combine
import SwiftUI
import MerryCore

/// Keys, habits and permissions: the only settings there are, written as
/// things Merry is or isn't allowed to do rather than as a preferences screen.
@MainActor
public final class TuneModel: ObservableObject {
    public enum Provider: String, Sendable { case anthropic, jev }

    @Published public private(set) var settings: MerryCore.Settings { didSet { syncPicker() } }
    @Published public var anthropic = ""
    @Published public var jev = ""
    @Published public private(set) var hasAnthropic = false
    @Published public private(set) var hasJev = false
    @Published public private(set) var apps: [CodingAppStatus] = []
    @Published public private(set) var note: String?
    @Published public private(set) var saving = false
    @Published public private(set) var error: String?
    @Published public private(set) var canUninstall = false
    @Published public private(set) var uninstalling = false
    @Published public private(set) var memories: [Memory] = []
    @Published public var confirmingForget = false
    /// The model picker for the coding app in use, when planning goes through one.
    @Published public private(set) var picker: ModelPickerModel?

    public let setup: SetupModel
    public let keysOnly: Bool
    private let bridge: MerryBridge
    private let onKeyChange: () -> Void
    private var listening: AnyCancellable?

    public init(bridge: MerryBridge, keysOnly: Bool = false, onKeyChange: @escaping () -> Void = {}) {
        self.bridge = bridge
        self.keysOnly = keysOnly
        self.onKeyChange = onKeyChange
        self.setup = SetupModel(bridge: bridge)
        self.settings = bridge.getSettings()
        syncPicker()
        if !keysOnly {
            listening = bridge.events.memoriesChanged.sink { [weak self] in self?.memories = $0 }
        }
    }

    private func syncPicker() {
        let next = reconciledPicker(picker, settings: settings, bridge: bridge) { [weak self] app, model in
            guard let self else { return }
            self.settings = try await self.bridge.setSettings { $0[keyPath: codingModelSetting(app)] = model }
            self.onKeyChange()
        }
        if next !== picker { picker = next }
    }

    public func refresh() async {
        settings = bridge.getSettings()
        if !keysOnly { canUninstall = bridge.canUninstallApp() }
        hasAnthropic = await bridge.hasApiKey()
        hasJev = await bridge.hasJevKey()
        apps = await bridge.codingApps()
        onKeyChange()
    }

    public func loadMemories() async { memories = await bridge.listMemories() }

    public func save(_ which: Provider) async {
        saving = true; error = nil
        defer { saving = false }
        let value = (which == .anthropic ? anthropic : jev).jsTrimmed
        let ok = which == .anthropic ? await bridge.setApiKey(value) : await bridge.setJevKey(value)
        guard ok else { error = "This Mac couldn’t save the key to Keychain. Please try again."; return }
        if which == .anthropic { anthropic = "" } else { jev = "" }
        note = "Saved securely in your macOS Keychain."
        await refresh()
    }

    public func update(_ change: (inout MerryCore.Settings) -> Void) async {
        do {
            settings = try await bridge.setSettings(change)
            onKeyChange()
        } catch {
            let said = messageOf(error)
            self.error = said.isEmpty ? "Couldn’t update settings." : said
        }
    }

    public func detectApps() async { apps = await bridge.codingApps() }

    /// Whether the "plan with a coding app" rows have anything to offer.
    public var offersCodingApps: Bool { apps.contains { $0.available } || settings.useClaudeCode }

    /// The coding apps that can be picked: the ones found on this Mac, plus
    /// the saved one if it has since gone missing.
    public var codingAppOptions: [(value: CodingApp, title: String)] {
        apps.filter { $0.available || $0.id == settings.codingApp }
            .map { ($0.id, $0.label + ($0.available ? "" : " (not installed)")) }
    }

    public func setPlanWithCodingApp(_ on: Bool) async {
        let current = settings.codingApp
        let app = apps.first { $0.id == current && $0.available }?.id ?? apps.first { $0.available }?.id ?? current
        await update { $0.useClaudeCode = on; $0.codingApp = app }
    }

    public func chooseCodingApp(_ app: CodingApp) async {
        guard apps.contains(where: { $0.id == app && $0.available }) else { return }
        await update { $0.codingApp = app }
    }

    /// Takes what was typed in the budget field; returns what the field should show.
    public func commitBudget(_ text: String) async -> String {
        if let value = Double(text.jsTrimmed), value.isFinite, value >= 0.1 {
            if value != settings.maxUsdPerTask { await update { $0.maxUsdPerTask = value } }
        }
        return Self.budgetText(settings.maxUsdPerTask)
    }

    public static func budgetText(_ value: Double) -> String { JSON.number(value).stringify() }

    public func uninstall() async {
        uninstalling = true; error = nil
        defer { uninstalling = false }
        do { _ = try await bridge.uninstallApp() } catch {
            let said = messageOf(error)
            self.error = said.isEmpty ? "Couldn’t uninstall Merry. You can quit it and move Merry.app to Trash in Finder." : said
        }
    }

    public var told: [Memory] { memories.filter { $0.source == "told" } }
    public var learned: [Memory] { memories.filter { $0.source == "learned" } }

    public func forget(_ id: String) async { memories = await bridge.deleteMemory(id) }

    public func forgetEverything() async {
        memories = await bridge.clearMemories()
        confirmingForget = false
    }
}

/// Keys, habits and permissions. `keysOnly` is what /keys shows.
public struct TuneView: View {
    @StateObject private var model: TuneModel
    private let onSetup: () -> Void
    private let expandAll: Bool
    /// Off in snapshots: an offscreen scroll view paints its own backing.
    private let scrolls: Bool

    public init(bridge: MerryBridge, keysOnly: Bool = false, onKeyChange: @escaping () -> Void = {}, onSetup: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: TuneModel(bridge: bridge, keysOnly: keysOnly, onKeyChange: onKeyChange))
        self.onSetup = onSetup
        self.expandAll = false
        self.scrolls = true
    }

    /// For previews: a ready model, optionally with every section open.
    init(model: TuneModel, expandAll: Bool = false, scrolls: Bool = false, onSetup: @escaping () -> Void = {}) {
        self.scrolls = scrolls
        _model = StateObject(wrappedValue: model)
        self.onSetup = onSetup
        self.expandAll = expandAll
    }

    public var body: some View {
        Group {
            let page = TunePage(model: model, setup: model.setup, expandAll: expandAll, onSetup: onSetup)
            if scrolls { ScrollView { page } } else { page.frame(maxHeight: .infinity, alignment: .top) }
        }
        .task {
            await model.refresh()
            if !model.keysOnly { await model.loadMemories() }
        }
        .modifier(SetupWatcher(setup: model.setup, poll: !model.keysOnly))
    }
}

private struct TunePage: View {
    @ObservedObject var model: TuneModel
    @ObservedObject var setup: SetupModel
    let expandAll: Bool
    let onSetup: () -> Void

    @State private var permissionsOpen: Bool?
    @State private var memoryOpen: Bool?
    @State private var preferencesOpen = false
    @State private var privacyOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if let error = model.error { SettingsNote(error, tone: .bad).padding(.horizontal, 4) }
            connections
            if !model.keysOnly {
                permissions
                memory
                preferences
                privacy
                uninstall
            }
        }
        .padding(Chrome.contentHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Connections

    private var connections: some View {
        ChromeSection(title: "Connections", trailing: AnyView(
            SettingsButton(symbol: Icon.search.rawValue, title: "Detect installed apps", help: "Detect installed apps") { Task { await model.detectApps() } }
        )) {
            ChromeCard {
                keyRow("Anthropic", symbol: "key.fill", hue: 1, text: $model.anthropic, has: model.hasAnthropic, which: .anthropic)
                ChromeRowDivider(inset: 50)
                keyRow("TypeSafe", symbol: "bolt.fill", hue: 2, text: $model.jev, has: model.hasJev, which: .jev)
                if model.offersCodingApps {
                    ChromeRowDivider(inset: 50)
                    ChromeRow(title: "Plan with a coding app on this Mac") {
                        IconTile(symbol: "terminal.fill", hue: 0)
                    } control: {
                        SettingsSwitch(isOn: Binding(get: { model.settings.useClaudeCode }, set: { on in Task { await model.setPlanWithCodingApp(on) } }))
                    }
                    if model.settings.useClaudeCode {
                        ChromeRowDivider(inset: 50)
                        ChromeRow(title: "Coding app") {
                            Color.clear.frame(width: 26, height: 26)
                        } control: {
                            SettingsPicker(options: model.codingAppOptions, selection: Binding(get: { model.settings.codingApp }, set: { app in Task { await model.chooseCodingApp(app) } }))
                        }
                        if let picker = model.picker {
                            ChromeRowDivider(inset: 12)
                            ModelPickerView(model: picker).id(picker.app)
                        }
                    }
                }
            }
            if model.note != nil { SettingsNote("Saved to Keychain.", tone: .ok).padding(.horizontal, 4) }
        }
    }

    private func keyRow(_ name: String, symbol: String, hue: Int, text: Binding<String>, has: Bool, which: TuneModel.Provider) -> some View {
        let filled = !text.wrappedValue.jsTrimmed.isEmpty
        return ChromeRow(title: name) {
            IconTile(symbol: symbol, hue: hue)
        } control: {
            HStack(spacing: 8) {
                SettingsField(text: text, placeholder: has ? "Connected" : "API key", secure: true) {
                    if filled && !model.saving { Task { await model.save(which) } }
                }
                .frame(width: 280)
                .accessibilityLabel(Text(verbatim: name))
                SettingsButton(symbol: Icon.check.rawValue, title: "Save", help: "Save", isEnabled: filled && !model.saving) { Task { await model.save(which) } }
            }
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        let open = Binding(
            get: { expandAll || (permissionsOpen ?? setup.items.contains { $0.status != .granted && $0.group == .control }) },
            set: { permissionsOpen = $0 }
        )
        return SettingsDisclosure(title: "Permissions · \(setup.grantedCount) of \(setup.items.count) allowed", isOpen: open) {
            if let error = setup.error { SettingsNote(error, tone: .bad).padding(.horizontal, 4) }
            SetupList(items: setup.items, busy: setup.busy, onRequest: { id in Task { await setup.request(id) } }, onOpenSettings: { id in Task { await setup.openSettings(id) } })
            SettingsButton(symbol: Icon.arrow.rawValue, title: "Run setup again", help: "Run setup again", action: onSetup)
        }
    }

    // MARK: Memory

    private var memory: some View {
        let count = model.memories.count
        let open = Binding(get: { expandAll || (memoryOpen ?? (count > 0 && count <= 8)) }, set: { memoryOpen = $0 })
        return SettingsDisclosure(title: "Memory" + (count > 0 ? " · \(count)" : ""), isOpen: open) {
            ChromeCard {
                ChromeRow(title: "Remember things about me") {
                    SettingsSwitch(isOn: Binding(get: { model.settings.memoryEnabled }, set: { on in Task { await model.update { $0.memoryEnabled = on } } }))
                }
                ChromeRowDivider(inset: 12)
                ChromeRow(title: "Learn from what I do") {
                    SettingsSwitch(isOn: Binding(get: { model.settings.memoryEnabled && model.settings.memoryLearn }, set: { on in Task { await model.update { $0.memoryLearn = on } } }))
                        .disabled(!model.settings.memoryEnabled)
                }
            }
            if count == 0 {
                SettingsNote("Nothing yet.").padding(.horizontal, 4)
            } else {
                memoryGroup("You told me", model.told)
                memoryGroup("I picked up", model.learned)
                HStack(spacing: 10) {
                    if model.confirmingForget {
                        Text(verbatim: "Forget all \(count)?").font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                        SettingsButton(symbol: Icon.trash.rawValue, title: "Forget everything", help: "Forget everything", isDestructive: true) { Task { await model.forgetEverything() } }
                        SettingsButton(symbol: Icon.close.rawValue, title: "Keep", help: "Keep") { model.confirmingForget = false }
                    } else {
                        SettingsButton(symbol: Icon.trash.rawValue, title: "Forget everything", help: "Forget everything") { model.confirmingForget = true }
                    }
                }
            }
            SettingsNote("Kept only on this Mac.").padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func memoryGroup(_ label: String, _ items: [Memory]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption(label).padding(.horizontal, 4)
                ChromeCard {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, memory in
                        if index > 0 { ChromeRowDivider(inset: 12) }
                        HStack(alignment: .center, spacing: 12) {
                            Text(verbatim: memory.text)
                                .font(.system(size: 13))
                                .foregroundStyle(Chrome.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(memory.uses > 0 ? "Used \(memory.uses) time\(memory.uses == 1 ? "" : "s")" : "Not used yet")
                            Spacer(minLength: 12)
                            SettingsButton(symbol: Icon.trash.rawValue, title: "Forget", help: "Forget: \(memory.text)") { Task { await model.forget(memory.id) } }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, Chrome.rowControlTrailingPadding)
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    // MARK: Preferences

    private func toggle(_ title: String, _ path: WritableKeyPath<MerryCore.Settings, Bool>) -> some View {
        ChromeRow(title: title) {
            SettingsSwitch(isOn: Binding(get: { model.settings[keyPath: path] }, set: { on in Task { await model.update { $0[keyPath: path] = on } } }))
        }
    }

    private var preferences: some View {
        SettingsDisclosure(title: "Preferences", isOpen: Binding(get: { expandAll || preferencesOpen }, set: { preferencesOpen = $0 })) {
            ChromeCard {
                toggle("Open Merry at login for reminders", \.launchAtLogin)
                ChromeRowDivider(inset: 12)
                toggle("Fast file workflows", \.workflowsFirst)
                ChromeRowDivider(inset: 12)
                toggle("Jev decisions", \.jevEnabled)
                ChromeRowDivider(inset: 12)
                toggle("Little chats from Merry", \.chatty)
                ChromeRowDivider(inset: 12)
                toggle("Confirm every action", \.confirmEveryAction)
                ChromeRowDivider(inset: 12)
                ChromeRow(title: "Budget / task ($)") { BudgetField(model: model) }
                ChromeRowDivider(inset: 12)
                ChromeRow(title: "Open Merry") {
                    ShortcutRecorder(value: model.settings.shortcut) { shortcut in Task { await model.update { $0.shortcut = shortcut } } }
                }
                ChromeRowDivider(inset: 12)
                ChromeRow(title: "The pet") {
                    SettingsPicker(options: TuneView.petModes, selection: Binding(get: { model.settings.petMode }, set: { mode in Task { await model.update { $0.petMode = mode } } }))
                        .accessibilityLabel(Text(verbatim: "Where the pet lives"))
                }
            }
        }
    }

    // MARK: Privacy, uninstall

    private var privacy: some View {
        SettingsDisclosure(title: "Privacy & connections", isOpen: Binding(get: { expandAll || privacyOpen }, set: { privacyOpen = $0 })) {
            SettingsNote("History stays on this Mac.").padding(.horizontal, 4)
            SettingsNote("Anthropic handles open-ended tasks.").padding(.horizontal, 4)
        }
    }

    private var uninstall: some View {
        ChromeSection(title: "Uninstall") {
            ChromeCard {
                ChromeRow(title: "Uninstall Merry", detail: model.canUninstall ? "Moves Merry to Trash and turns off opening at login." : "Available in the installed Merry app.") {
                    SettingsButton(symbol: Icon.trash.rawValue, title: model.uninstalling ? "Uninstalling…" : "Uninstall Merry…", help: "Uninstall Merry…",
                                     isEnabled: model.canUninstall && !model.uninstalling, isDestructive: true) { Task { await model.uninstall() } }
                }
            }
        }
    }
}

extension TuneView {
    /// Where the pet can live, in the order the reference offers them.
    static let petModes: [(value: PetMode, title: String)] = [
        (.ondemand, "When called, working, timing, or reminding me"),
        (.desktop, "Always on the desktop"),
        (.peek, "Only while working (peeks from the corner)"),
        (.menubar, "Menu bar only")
    ]
}

/// The spend limit: taken when the field is left or Return is pressed, and put
/// back to what is saved when it is not a number of at least 0.1.
private struct BudgetField: View {
    @ObservedObject var model: TuneModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettingsField(text: $text, placeholder: "") { commit() }
            .frame(width: 80)
            .focused($focused)
            .onAppear { text = TuneModel.budgetText(model.settings.maxUsdPerTask) }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: model.settings.maxUsdPerTask) { _, value in if !focused { text = TuneModel.budgetText(value) } }
    }

    private func commit() {
        let typed = text
        Task { text = await model.commitBudget(typed) }
    }
}

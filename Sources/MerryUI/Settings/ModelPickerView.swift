import SwiftUI
import MerryCore

/// Which setting holds each coding app's chosen model. Each is saved separately.
public func codingModelSetting(_ app: CodingApp) -> WritableKeyPath<MerryCore.Settings, String> {
    switch app {
    case .claudeCode: return \.claudeCodeModel
    case .codex: return \.codexModel
    case .opencode: return \.opencodeModel
    }
}

/// Choosing is a draft; an explicit check confirms access before replacing the saved model.
@MainActor
public final class ModelPickerModel: ObservableObject {
    public struct Access: Equatable, Sendable {
        /// verified | unavailable
        public var access: String
        public var reason: String
    }

    /// One line of the list of choices.
    public struct Row: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        /// Why it cannot be chosen, when it cannot.
        public var reason: String?
        public var disabled: Bool
    }

    public let app: CodingApp
    @Published public private(set) var catalog: CodingModelCatalog?
    @Published public private(set) var loading = true
    @Published public private(set) var error = ""
    @Published public var search = ""
    @Published public var freeOnly = false
    @Published public private(set) var custom = false
    @Published public private(set) var choice: String
    @Published public var draft: String { didSet { if draft != oldValue { feedback = "" } } }
    @Published public private(set) var checking = false
    @Published public private(set) var feedback = ""
    @Published public private(set) var failed = false
    @Published public private(set) var checks: [String: Access] = [:]
    /// The model that is saved, as the settings have it.
    @Published public private(set) var value: String

    private let loadCatalog: (Bool) async throws -> CodingModelCatalog
    private let check: (String) async throws -> CodingModelCheck
    private let save: (String) async throws -> Void
    private var alive = true
    private var busy = false
    private var loadToken = 0
    private var loadedOnce = false

    public init(
        app: CodingApp, value: String,
        loadCatalog: @escaping (Bool) async throws -> CodingModelCatalog,
        check: @escaping (String) async throws -> CodingModelCheck,
        save: @escaping (String) async throws -> Void
    ) {
        self.app = app; self.value = value; self.choice = value; self.draft = value
        self.loadCatalog = loadCatalog; self.check = check; self.save = save
    }

    /// `save` stores the model under this app's own setting and tells the owner.
    public convenience init(bridge: MerryBridge, app: CodingApp, value: String, save: @escaping (String) async throws -> Void) {
        self.init(
            app: app, value: value,
            loadCatalog: { [weak bridge] refresh in
                guard let bridge else { throw MerryError("") }
                return try await bridge.codingModels(app, refresh: refresh)
            },
            check: { [weak bridge] model in
                guard let bridge else { throw MerryError("") }
                return try await bridge.checkCodingModel(app, model: model)
            },
            save: save
        )
    }

    public var name: String { app == .codex ? "Codex" : app == .opencode ? "OpenCode" : "Claude Code" }

    /// The owner's saved model changed (or was confirmed): the draft follows it.
    public func setValue(_ next: String) {
        guard next != value else { return }
        value = next; choice = next; draft = next
    }

    /// The picker is no longer shown for this app; anything still in flight is dropped.
    public func retire() { alive = false; loadToken += 1 }

    public func loadIfNeeded() async { if !loadedOnce { await load(refresh: false) } }

    public func load(refresh: Bool) async {
        loadedOnce = true
        loadToken += 1
        let token = loadToken
        loading = true; error = ""; catalog = nil; checks = [:]; feedback = ""
        do {
            let next = try await loadCatalog(refresh)
            guard token == loadToken else { return }
            catalog = next
        } catch {
            guard token == loadToken else { return }
            self.error = "Couldn’t load \(name) models. Check its installation and login, then refresh, or enter a model ID."
        }
        loading = false
    }

    public var models: [CodingModel] {
        (catalog?.models ?? []).map { model in
            guard let seen = checks[model.id] else { return model }
            var merged = model
            merged.access = seen.access; merged.reason = seen.reason
            return merged
        }
    }

    public var recommended: CodingModel? { models.first { $0.recommended == true && $0.access != "unavailable" } }
    public var pending: String { custom ? draft.jsTrimmed : choice }
    public var selected: CodingModel? { models.first { $0.id == pending } }

    public var access: Access? {
        if let seen = checks[pending] { return seen }
        guard let selected, let access = selected.access else { return nil }
        return Access(access: access, reason: selected.reason ?? "")
    }

    public var isUnavailable: Bool { access?.access == "unavailable" }

    public var visible: [CodingModel] {
        let needle = search.lowercased().jsTrimmed
        return models.filter { model in
            (!freeOnly || model.free == true) && (needle.isEmpty || "\(model.label) \(model.id)".lowercased().contains(needle))
        }
    }

    public var keepChoice: Bool { !choice.isEmpty && !visible.contains { $0.id == choice } }

    public var valid: Bool {
        validCodingModel(pending) && (app != .opencode || pending.isEmpty || (pending.contains("/") && !pending.hasPrefix("/") && !pending.hasSuffix("/")))
    }

    public func label(_ model: CodingModel) -> String {
        let state = model.access == "unavailable" ? " · Unavailable" : model.access == "verified" ? " · Access checked" : model.recommended == true ? " · Recommended" : ""
        return "\(model.label)\(model.free == true ? " · Free" : "")\(state)"
    }

    public var defaultTitle: String { "Use configured default" + ((catalog?.defaultModel).map { $0.isEmpty ? "" : " · \($0)" } ?? "") }

    /// The choices, in the order they are listed.
    public var rows: [Row] {
        var out: [Row] = []
        if app != .claudeCode { out.append(Row(id: "", title: defaultTitle, reason: nil, disabled: false)) }
        if keepChoice {
            let known = models.first { $0.id == choice }
            out.append(Row(id: choice, title: "\(known?.label ?? choice) · \(choice == value ? "saved choice" : "pending choice")",
                           reason: known?.access == "unavailable" ? known?.reason : nil, disabled: known?.access == "unavailable"))
        }
        for model in visible {
            out.append(Row(id: model.id, title: label(model), reason: model.access == "unavailable" ? model.reason : nil, disabled: model.access == "unavailable"))
        }
        return out
    }

    /// What to say under the list when there is nothing in it, or nil.
    public var listStatus: (text: String, isError: Bool)? {
        if loading { return ("Loading \(name) models…", false) }
        if !error.isEmpty { return (error, true) }
        if models.isEmpty { return ("No models were listed. Set up \(name), refresh, or enter a model ID.", false) }
        if visible.isEmpty { return (freeOnly ? "No matching models with confirmed free pricing." : "No matching models.", false) }
        return nil
    }

    public var invalidMessage: String? {
        guard custom, !pending.isEmpty, !valid else { return nil }
        return app == .opencode ? "Use a provider/model ID without spaces." : "Use an exact model ID without spaces (up to 256 characters)."
    }

    public var canApply: Bool {
        !(checking || !valid || isUnavailable || (custom && pending.isEmpty) || (pending.isEmpty && app == .claudeCode))
    }

    public var applyTitle: String { checking ? "Checking access…" : pending.isEmpty ? "Use configured default" : "Check & use model" }

    /// The check's own message, unless the "unavailable" line already says the same thing.
    public var shownFeedback: String? {
        guard !feedback.isEmpty, !(failed && isUnavailable && feedback == access?.reason) else { return nil }
        return feedback
    }

    public func choose(_ id: String) {
        guard !busy else { return }
        if rows.first(where: { $0.id == id })?.disabled == true { return }
        choice = id; custom = false; feedback = ""
    }

    public func toggleCustom() {
        guard !checking else { return }
        custom.toggle(); feedback = ""
    }

    public func checkAndSave() async {
        guard !busy, valid, !isUnavailable else { return }
        let model = pending
        let original = value
        busy = true; checking = true; feedback = ""; failed = false
        defer {
            busy = false
            if alive { checking = false }
        }
        do {
            if !model.isEmpty {
                let result = try await check(model)
                guard alive, value == original else { return }
                if !result.ok {
                    failed = true; feedback = result.message
                    if result.unavailable == true { checks[model] = Access(access: "unavailable", reason: result.message) }
                    return
                }
                checks[model] = Access(access: "verified", reason: result.message)
            }
            guard alive, value == original else { return }
            try await save(model)
            guard alive else { return }
            setValue(model)
            choice = model
            feedback = model.isEmpty ? "Merry will use your coding app’s configured default." : "Access checked and model saved for Merry."
        } catch {
            if alive { failed = true; feedback = "Couldn’t check or save this model. Your previous choice is still selected. Please retry." }
        }
    }
}

/// Keeps the picker a settings owner shows in step with its settings: one per
/// coding app, replaced (and the old one dropped) when the app changes, gone
/// when planning does not go through a coding app.
@MainActor
func reconciledPicker(_ current: ModelPickerModel?, settings: MerryCore.Settings?, bridge: MerryBridge, save: @escaping (CodingApp, String) async throws -> Void) -> ModelPickerModel? {
    guard let settings, settings.useClaudeCode else {
        current?.retire()
        return nil
    }
    let app = settings.codingApp
    let value = settings[keyPath: codingModelSetting(app)]
    if let current, current.app == app {
        current.setValue(value)
        return current
    }
    current?.retire()
    return ModelPickerModel(bridge: bridge, app: app, value: value) { model in try await save(app, model) }
}

/// The model a coding app plans with: its current catalog, a recommendation,
/// what is unavailable and why, and a check before anything is saved.
struct ModelPickerView: View {
    @ObservedObject var model: ModelPickerModel

    var body: some View {
        let name = model.name
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "Model · \(name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.primaryText)
                Spacer()
                SettingsButton(symbol: "arrow.clockwise", title: "Refresh models", help: "Refresh models", isEnabled: !model.loading && !model.checking) {
                    Task { await model.load(refresh: true) }
                }
            }
            if let connection = model.catalog?.connection, !connection.isEmpty {
                // First letters only, as CSS capitalises: "ChatGPT" keeps its capitals.
                Text(verbatim: connection.split(separator: " ", omittingEmptySubsequences: false).map { String($0).capitalizedFirst }.joined(separator: " ")).font(.system(size: 12)).foregroundStyle(Chrome.lime)
            }
            if let recommended = model.recommended {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Recommended · \(recommended.label)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Chrome.primaryText)
                        Text(verbatim: recommended.recommendation.flatMap { $0.isEmpty ? nil : $0 } ?? "\(name) recommends this model for your connection.")
                            .font(.system(size: 12)).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    SettingsButton(symbol: Icon.spark.rawValue, title: "Choose recommended", help: "Choose recommended", isEnabled: !model.checking) { model.choose(recommended.id) }
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Chrome.lime.opacity(0.35), lineWidth: 1))
            }
            SettingsField(text: $model.search, placeholder: "Search models", mono: false)
                .accessibilityLabel(Text(verbatim: "Search \(name) models"))
            if model.app == .opencode {
                HStack {
                    Text(verbatim: "Show free models only").font(.system(size: 13)).foregroundStyle(Chrome.primaryText)
                    Spacer()
                    SettingsSwitch(isOn: $model.freeOnly)
                }
            }
            choices
            if let status = model.listStatus { SettingsNote(status.text, tone: status.isError ? .bad : .dim) }
            if let description = model.selected?.description, !description.isEmpty { SettingsNote(description) }
            SettingsButton(symbol: Icon.rename.rawValue, title: "Enter a model ID", help: "Enter a model ID", isEnabled: !model.checking) { model.toggleCustom() }
            if model.custom {
                SettingsField(text: $model.draft, placeholder: model.app == .opencode ? "provider/model" : "Exact model ID", readOnly: model.checking) {
                    if !model.draft.jsTrimmed.isEmpty { Task { await model.checkAndSave() } }
                }
                .accessibilityLabel(Text(verbatim: "Custom \(name) model ID"))
            }
            if let invalid = model.invalidMessage { SettingsNote(invalid, tone: .bad) }
            if model.isUnavailable, let access = model.access { SettingsNote("\(access.reason) Refresh models after your access changes.", tone: .bad) }
            HStack(spacing: 10) {
                SettingsButton(symbol: Icon.check.rawValue, title: model.applyTitle, help: model.applyTitle, isEnabled: model.canApply) {
                    Task { await model.checkAndSave() }
                }
                Text(verbatim: "Saved: \(model.value.isEmpty ? "configured default" : model.value)")
                    .font(.system(size: 11)).foregroundStyle(Chrome.secondaryText).lineLimit(2)
            }
            if let feedback = model.shownFeedback { SettingsNote(feedback, tone: model.failed ? .bad : .ok) }
            if !model.pending.isEmpty { SettingsNote("Checking sends one short test reply.") }
            SettingsNote(model.catalog?.note.isEmpty == false ? model.catalog!.note : "Uses your existing connection.")
            SettingsNote("Coding-app charges are handled by your provider.")
            if model.app == .opencode { SettingsNote("Model choices are saved for Merry.") }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(name) model selection"))
        .task(id: ObjectIdentifier(model)) { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var choices: some View {
        let rows = model.rows
        if !rows.isEmpty {
            let list = VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { ChromeRowDivider(inset: 34) }
                    ModelChoiceRow(row: row, isChosen: row.id == model.choice && !model.custom, isBusy: model.checking) { model.choose(row.id) }
                }
            }
            Group {
                if rows.count > 7 {
                    ScrollView { list }.frame(height: 7 * 36)
                } else {
                    list
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(Text(verbatim: "\(model.name) model"))
        }
    }
}

private struct ModelChoiceRow: View {
    let row: ModelPickerModel.Row
    let isChosen: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: Icon.check.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.lime)
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title).font(.system(size: 12.5)).foregroundStyle(Chrome.primaryText).lineLimit(1)
                    if let reason = row.reason, !reason.isEmpty {
                        Text(verbatim: reason).font(.system(size: 11)).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .padding(.vertical, row.reason == nil ? 0 : 6)
            .background(isHovering && !row.disabled ? Chrome.overlay(0.05) : Color.clear)
            .contentShape(.rect)
            .opacity(row.disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(row.disabled || isBusy)
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

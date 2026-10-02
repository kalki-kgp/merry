import AppKit
import SwiftUI
import MerryCore

/// One card of the tour: one thing Merry can do.
public struct TourCard: Equatable, Identifiable, Sendable {
    public var id: String
    public var say: String
    public var mood: Mood
    var icon: Icon
    public var line: String
    /// Something you could type, in your own words.
    public var example: String?
    /// The permissions this card's feature uses.
    public var asks: [String]
}

/// First run: a quick tour, one thing Merry can do per card. Each card says it
/// in a line, shows a request you could type, and asks for exactly the
/// permissions that thing needs, right there. Every card can be skipped; the
/// whole tour is a minute, not a setup wizard.
@MainActor
public final class WelcomeModel: ObservableObject {
    public static let cards: [TourCard] = [
        TourCard(id: "hello", say: "Hi, I’m Merry.", mood: .wave, icon: .spark, line: "I do real work on your Mac when you ask, and only then. Here’s what I can do, one thing at a time.", asks: []),
        TourCard(id: "think", say: "How should I think?", mood: .curious, icon: .spark, line: "Pick what I plan with. You can change it any time in Settings.", asks: []),
        TourCard(id: "files", say: "Files.", mood: .happy, icon: .folder, line: "Find anything, tidy a messy folder, rename a batch to one pattern. You see a preview first, and every move can be undone.", example: "Organize my Downloads folder", asks: ["folder:Downloads", "folder:Desktop", "folder:Documents"]),
        TourCard(id: "day", say: "Your day.", mood: .listening, icon: .clock, line: "Calendar, reminders and notes, through the apps you already use. Mail only ever becomes a draft for you to send.", example: "Remind me to call mom tomorrow at 7", asks: ["app:com.apple.iCal", "app:com.apple.reminders", "app:com.apple.Notes", "app:com.apple.mail"]),
        TourCard(id: "web", say: "The web.", mood: .reading, icon: .search, line: "Read the page you’re on, open tabs, and work on sites in your own browser while you watch. I ask before anything that sends, posts or buys.", example: "Summarize this page", asks: ["app:com.google.Chrome", "app:com.apple.Safari", "app:company.thebrowser.Browser", "app:com.brave.Browser", "app:com.microsoft.edgemac"]),
        TourCard(id: "apps", say: "Other apps.", mood: .determined, icon: .screen, line: "Read windows and press buttons in other apps, and use whatever you’ve selected. I never move your mouse or type for you.", example: "Explain the error I just selected", asks: ["accessibility", "screen-recording", "app:com.apple.finder", "app:com.apple.systemevents"]),
        TourCard(id: "keep", say: "Remember & remind.", mood: .love, icon: .list, line: "Notes, tasks and a focus timer live with me. Tell me things once and I’ll remember them, only on this Mac.", example: "Start a 25 minute focus timer", asks: ["notifications"]),
        TourCard(id: "done", say: "That’s it.", mood: .celebrate, icon: .check, line: "", asks: [])
    ]

    public static let tryThese = ["Organize my Downloads folder", "What’s on my calendar tomorrow?", "Remind me to stretch in 30 minutes"]

    /// A first run opens on the tour; once finished or skipped it does not come back by itself.
    public static func shouldShow(_ settings: MerryCore.Settings) -> Bool { !settings.onboarded }

    public enum Key: Sendable { case left, right, enter }

    @Published public private(set) var index = 0 { didSet { if index != oldValue { error = nil } } }
    @Published public private(set) var settings: MerryCore.Settings? { didSet { syncPicker() } }
    @Published public private(set) var apps: [CodingAppStatus] = []
    @Published public private(set) var hasKey = false
    @Published public var key = ""
    @Published public private(set) var hasJev = false
    @Published public var jev = ""
    /// The API key choice was picked, before any key is saved.
    @Published public private(set) var useKey = false
    @Published public private(set) var error: String?
    @Published public private(set) var picker: ModelPickerModel?

    public let setup: SetupModel
    private let bridge: MerryBridge
    private let onDone: (String?) -> Void

    public init(bridge: MerryBridge, onDone: @escaping (String?) -> Void = { _ in }) {
        self.bridge = bridge
        self.onDone = onDone
        self.setup = SetupModel(bridge: bridge)
    }

    public var card: TourCard { Self.cards[index] }
    public var isLast: Bool { index == Self.cards.count - 1 }

    public func next() { if !isLast { index += 1 } }
    public func back() { if index > 0 { index -= 1 } }
    public func go(to card: Int) { if Self.cards.indices.contains(card) { index = card } }

    /// Enter moves on and arrows step, so the tour can be read without the
    /// mouse. `editing` is true while a field has the keys, or a shortcut is
    /// being recorded. Returns whether the key was used.
    @discardableResult
    public func handle(_ key: Key, editing: Bool) -> Bool {
        guard !editing else { return false }
        switch key {
        case .right: next(); return true
        case .enter:
            guard !isLast else { return false }
            next(); return true
        case .left:
            guard index > 0 else { return false }
            back(); return true
        }
    }

    /// Reads what is already set up. Asks macOS for nothing.
    public func load() async {
        settings = bridge.getSettings()
        apps = await bridge.codingApps()
        hasKey = await bridge.hasApiKey()
        hasJev = await bridge.hasJevKey()
    }

    private func syncPicker() {
        let next = reconciledPicker(picker, settings: settings, bridge: bridge) { [weak self] app, model in
            guard let self else { return }
            self.settings = try await self.bridge.setSettings { $0[keyPath: codingModelSetting(app)] = model }
        }
        if next !== picker { picker = next }
    }

    public func update(_ change: (inout MerryCore.Settings) -> Void) async {
        do { settings = try await bridge.setSettings(change) } catch {
            let said = messageOf(error)
            self.error = said.isEmpty ? "Couldn’t save that." : said
        }
    }

    public func detectApps() async { apps = await bridge.codingApps() }

    /// Whether planning goes through this coding app.
    public func isOn(_ app: CodingApp) -> Bool { settings?.useClaudeCode == true && settings?.codingApp == app }
    public var keyChoiceIsOn: Bool { settings?.useClaudeCode == false && (hasKey || useKey) }

    /// Picking a coding app switches planning to it. One that is not installed cannot be picked.
    public func chooseApp(_ app: CodingApp) async {
        guard apps.contains(where: { $0.id == app && $0.available }) else { return }
        useKey = false
        await update { $0.useClaudeCode = true; $0.codingApp = app }
    }

    public func chooseKey() async {
        useKey = true
        await update { $0.useClaudeCode = false }
    }

    public func saveKey() async {
        guard await bridge.setApiKey(key.jsTrimmed) else { error = "This Mac couldn’t save the key to Keychain."; return }
        key = ""; hasKey = true
        await update { $0.useClaudeCode = false }
    }

    public func saveJev() async {
        guard await bridge.setJevKey(jev.jsTrimmed) else { error = "This Mac couldn’t save the key to Keychain."; return }
        jev = ""; hasJev = true
    }

    public func finish(_ compose: String? = nil) async {
        // Setup can be rerun with /setup, so a failed save does not hold the person here.
        _ = try? await bridge.setSettings { $0.onboarded = true }
        onDone(compose)
    }

    /// The permissions this card's feature uses, of those this Mac has.
    public var items: [SetupItem] { setup.items.filter { card.asks.contains($0.id) } }
    public var pending: [SetupItem] { items.filter(SetupModel.asksInPlace) }

    public var thinking: String? {
        guard let settings else { return nil }
        if settings.useClaudeCode { return apps.first { $0.id == settings.codingApp }?.label ?? "a coding app" }
        return hasKey ? "Claude Sonnet 5.5" : nil
    }

    public func allowCard() async {
        for item in pending { await setup.request(item.id) }
    }

    public var thinksWithLine: String { thinking ?? "Nothing yet. Files, reminders, calendar and notes only" }
    public var jevLine: String { hasJev ? "On" : "Off, using my own rules" }
    public var allowedLine: String { "\(setup.grantedCount) of \(setup.items.count) permissions" }

    /// How tall the panel should be for a page of this height: as tall as the
    /// card, since a one-line card should not sit in a tall empty window.
    public static func panelHeight(content: CGFloat) -> CGFloat {
        min(640, max(300, (content / 20).rounded(.up) * 20))
    }
}

/// The one-minute tour shown on first run and by /setup. `onDone` is given a
/// request to put in the composer, when the person picked one to try.
public struct WelcomeView: View {
    @StateObject private var model: WelcomeModel
    private let bridge: MerryBridge
    /// Off in snapshots: an offscreen scroll view paints its own backing.
    private var scrolls = true

    public init(bridge: MerryBridge, onDone: @escaping (String?) -> Void) {
        _model = StateObject(wrappedValue: WelcomeModel(bridge: bridge, onDone: onDone))
        self.bridge = bridge
    }

    /// For previews: opens on a given card.
    init(bridge: MerryBridge, startAt index: Int) {
        let model = WelcomeModel(bridge: bridge)
        model.go(to: index)
        _model = StateObject(wrappedValue: model)
        self.bridge = bridge
        self.scrolls = false
    }

    public var body: some View {
        WelcomePage(model: model, setup: model.setup, bridge: bridge, scrolls: scrolls)
            .task { await model.load() }
            .modifier(SetupWatcher(setup: model.setup, poll: true))
    }
}

private struct WelcomeHeights: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct WelcomePage: View {
    @ObservedObject var model: WelcomeModel
    @ObservedObject var setup: SetupModel
    let bridge: MerryBridge
    let scrolls: Bool

    @State private var window: NSWindow?
    @State private var monitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barHeight: CGFloat = 70
    private static let navHeight: CGFloat = 52

    var body: some View {
        let card = model.card
        VStack(spacing: 0) {
            bar(card)
            let content = page(card)
                    .padding(.horizontal, Chrome.contentHorizontalPadding)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in Color.clear.preference(key: WelcomeHeights.self, value: proxy.size.height) })
                    .id(card.id)
                    .transition(reduceMotion ? .identity : .softAppear)
            if scrolls { ScrollView { content } } else { Color.clear.overlay(alignment: .top) { content }.clipped() }
            nav
        }
        .onPreferenceChange(WelcomeHeights.self) { height in
            guard height > 0 else { return }
            bridge.resizePanel(height: WelcomeModel.panelHeight(content: height + Self.barHeight + Self.navHeight))
        }
        .background(SettingsWindowReader { found in Task { @MainActor in window = found } }.frame(width: 0, height: 0))
        .onAppear(perform: listen)
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let key: WelcomeModel.Key
            switch event.keyCode {
            case 123: key = .left
            case 124: key = .right
            case 36, 76: key = .enter
            default: return event
            }
            let editing = window.firstResponder is NSText || ShortcutRecorder.isRecordingAnywhere
            return model.handle(key, editing: editing) ? nil : event
        }
    }

    // MARK: Bar and navigation

    private func bar(_ card: TourCard) -> some View {
        let count = WelcomeModel.cards.count
        return HStack(spacing: 10) {
            SpriteView(state: .idle, mood: card.mood, size: 46)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: card.say).font(.system(size: 18, weight: .semibold)).foregroundStyle(Chrome.primaryText)
                Text(verbatim: "\(model.index + 1) of \(count)").font(Chrome.mono(10.5)).foregroundStyle(Chrome.tertiaryText)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(WelcomeModel.cards.enumerated()), id: \.element.id) { i, each in
                    Button { model.go(to: i) } label: {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(i <= model.index ? Chrome.lime.opacity(i == model.index ? 1 : 0.45) : Chrome.overlay(0.1))
                            .frame(width: 6, height: 6)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Go to \(each.say)"))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "Card \(model.index + 1) of \(count)"))
        }
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .frame(height: Self.barHeight)
    }

    private var nav: some View {
        HStack(spacing: 6) {
            if model.index > 0 {
                SettingsButton(symbol: Icon.back.rawValue, title: "Back", help: "Back") { model.back() }
            } else {
                skip
            }
            Spacer()
            if !model.isLast && model.index > 0 { skip }
            if model.isLast {
                SettingsPrimaryButton(title: "Start using Merry") { Task { await model.finish() } }
            } else {
                SettingsPrimaryButton(title: model.index == 0 ? "Show me" : "Next", symbol: Icon.arrow.rawValue) { model.next() }
            }
        }
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .frame(height: Self.navHeight)
    }

    private var skip: some View {
        SettingsButton(symbol: "forward.end", title: "Skip tour", help: "Skip tour") { Task { await model.finish() } }
    }

    // MARK: The card

    @ViewBuilder
    private func page(_ card: TourCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.error { SettingsNote(error, tone: .bad) }
            if !card.line.isEmpty { lead(card.line) }

            if card.id == "hello" {
                if let settings = model.settings {
                    ChromeCard {
                        HStack(spacing: 10) {
                            Text(verbatim: "Open me from anywhere").font(.system(size: 13)).foregroundStyle(Chrome.primaryText)
                            ShortcutRecorder(value: settings.shortcut) { shortcut in Task { await model.update { $0.shortcut = shortcut } } }
                            Text(verbatim: "or click my face in the menu bar").font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                note("That’s me on your desktop, too. Drag me anywhere, drop files on me, right-click me to play. If I’m ever in the way, Settings → The pet can tuck me into the corner or the menu bar.")
            }

            if card.id == "think", let settings = model.settings { think(settings) }

            if let example = card.example {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsCaption("Try saying").padding(.horizontal, 2)
                    Text(verbatim: example)
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous).fill(Chrome.overlay(0.08)))
                }
            }

            let items = model.items
            if !items.isEmpty {
                let pending = model.pending
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(verbatim: items.count == 1 ? "Needs" : "Needs your OK for").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if pending.count > 1 {
                            SettingsButton(symbol: Icon.check.rawValue, title: "Allow all \(pending.count)", help: "Allow all \(pending.count)", isEnabled: setup.busy == nil) { Task { await model.allowCard() } }
                        }
                    }
                    .frame(minHeight: 30)
                    .padding(.horizontal, 4)
                    if let error = setup.error { SettingsNote(error, tone: .bad) }
                    SetupList(items: items, busy: setup.busy, onRequest: { id in Task { await setup.request(id) } }, onOpenSettings: { id in Task { await setup.openSettings(id) } }, flat: true)
                }
            }

            if card.id == "done" { done }
        }
    }

    private func lead(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(Chrome.primaryText.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: How should I think?

    @ViewBuilder
    private func think(_ settings: MerryCore.Settings) -> some View {
        VStack(spacing: 6) {
            ForEach(model.apps, id: \.id) { app in
                WelcomeChoice(title: app.label, detail: app.available ? "Found on this Mac. Uses your existing connection and its usage limits." : "Not installed on this Mac.",
                              isOn: model.isOn(app.id), isEnabled: app.available) { Task { await model.chooseApp(app.id) } }
            }
            WelcomeChoice(title: "Anthropic API key", detail: "Claude Sonnet 5.5. You pay Anthropic per use; each task stops at $\(settings.maxUsdPerTask.toFixed(2)).",
                          isOn: model.keyChoiceIsOn, isEnabled: true) { Task { await model.chooseKey() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "What Merry thinks with"))

        SettingsButton(symbol: Icon.search.rawValue, title: "Detect installed apps", help: "Detect installed apps") { Task { await model.detectApps() } }

        if let picker = model.picker {
            ChromeCard { ModelPickerView(model: picker).id(picker.app) }
        }
        if !settings.useClaudeCode && (model.useKey || model.hasKey) {
            keyCard("Anthropic", text: $model.key, placeholder: model.hasKey ? "Saved in Keychain" : "sk-ant-…") { Task { await model.saveKey() } }
        }
        if !settings.useClaudeCode && model.useKey && !model.hasKey {
            SettingsButton(symbol: Icon.arrow.rawValue, title: "Get a key from the Anthropic Console", help: "Get a key from the Anthropic Console") {
                Task { try? await bridge.openUrl("https://console.anthropic.com/settings/keys") }
            }
        }
        if model.thinking == nil {
            note("Or skip this: finding, tidying and renaming files, reminders, calendar and notes work without either.")
        }

        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(verbatim: "Jev · optional").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            note("A TypeSafe key lets Jev make the quick calls (which folder, which calendar, which way to rename) in about a tenth of a second, for a fraction of a cent. Without it I use my own rules.")
            keyCard("TypeSafe", text: $model.jev, placeholder: model.hasJev ? "Saved in Keychain" : "TypeSafe API key") { Task { await model.saveJev() } }
        }
    }

    private func keyCard(_ name: String, text: Binding<String>, placeholder: String, save: @escaping () -> Void) -> some View {
        let filled = !text.wrappedValue.jsTrimmed.isEmpty
        return ChromeCard {
            ChromeRow(title: name) {
                HStack(spacing: 8) {
                    SettingsField(text: text, placeholder: placeholder, secure: true) { if filled { save() } }
                        .frame(width: 320)
                        .accessibilityLabel(Text(verbatim: name))
                    SettingsButton(symbol: Icon.check.rawValue, title: "Save", help: "Save", isEnabled: filled, action: save)
                }
            }
        }
    }

    // MARK: That's it

    @ViewBuilder
    private var done: some View {
        ChromeCard {
            summary("Thinks with", model.thinksWithLine)
            ChromeRowDivider(inset: 12)
            summary("Jev", model.jevLine)
            ChromeRowDivider(inset: 12)
            summary("Allowed", model.allowedLine)
        }
        HStack(spacing: 6) {
            Text(verbatim: "Press")
            ShortcutKeys(accelerator: model.settings?.shortcut ?? "Command+Shift+Space")
            Text(verbatim: "and ask. A few to start with:")
        }
        .font(.system(size: 14))
        .foregroundStyle(Chrome.primaryText.opacity(0.85))
        ChromeCard {
            ForEach(Array(WelcomeModel.tryThese.enumerated()), id: \.offset) { index, request in
                if index > 0 { ChromeRowDivider(inset: 50) }
                WelcomeTryRow(title: request) { Task { await model.finish(request) } }
            }
        }
        HStack(spacing: 5) {
            Text(verbatim: "Type")
            Text(verbatim: "/setup")
                .font(Chrome.mono(10))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Chrome.overlay(0.1)))
            Text(verbatim: "to see this again. Permissions live in Settings.")
        }
        .font(.system(size: 12))
        .foregroundStyle(Chrome.secondaryText)
    }

    private func summary(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            SettingsCaption(label).frame(width: 96, alignment: .leading)
            Text(verbatim: value).font(.system(size: 13, weight: .medium)).foregroundStyle(Chrome.primaryText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// One way for Merry to think, picked like a radio button.
private struct WelcomeChoice: View {
    let title: String
    let detail: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Chrome.lime : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isOn ? Chrome.lime : Chrome.overlay(0.2), lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Chrome.primaryText)
                    Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous).fill(isOn ? Chrome.lime.opacity(0.1) : Chrome.overlay(isHovering && isEnabled ? 0.08 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous).strokeBorder(isOn ? Chrome.lime.opacity(0.35) : Color.clear, lineWidth: 1))
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct WelcomeTryRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ChromeRow(title: title) {
                IconTile(symbol: Icon.arrow.rawValue, hue: 4)
            } control: {
                EmptyView()
            }
            .background(isHovering ? Chrome.overlay(0.05) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
    }
}

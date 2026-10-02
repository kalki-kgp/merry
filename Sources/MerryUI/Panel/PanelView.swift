import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MerryCore

/// The panel: a command bar first and a companion second. One glass surface
/// holding the bar, the workspace under it, and a status bar; minimized, the
/// same surface is the island.
public struct PanelView: View {
    static let width: CGFloat = 640
    static let islandSize = CGSize(width: 300, height: 46)

    @StateObject private var model: PanelModel
    /// Opens History with one row's delete confirmation showing; for previews.
    private var deletingRow: String?

    @State private var contentHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @State private var dockHeight: CGFloat = 0
    @State private var statusHeight: CGFloat = 0
    @State private var paletteHeight: CGFloat = 0
    @State private var scroll = ScrollPosition(edge: .top)
    @Environment(\.flatGlass) private var flatGlass

    public init(bridge: MerryBridge) {
        _model = StateObject(wrappedValue: PanelModel(bridge: bridge))
    }

    init(model: PanelModel, deletingRow: String? = nil) {
        _model = StateObject(wrappedValue: model)
        self.deletingRow = deletingRow
    }

    private var bridge: MerryBridge { model.bridge }
    private var docked: Bool { model.panel.docked }
    private var onboarding: Bool { model.welcome && !docked }

    public var body: some View {
        Group {
            if onboarding {
                WelcomeView(bridge: bridge) { model.finishWelcome($0) }
                    .frame(width: PanelView.width)
            } else {
                panel
                    .frame(width: PanelView.width)
                    .opacity(docked ? 0 : 1)
                    .allowsHitTesting(!docked)
                    .accessibilityHidden(docked)
            }
        }
        .frame(minWidth: 0, idealWidth: docked ? PanelView.islandSize.width : PanelView.width, maxWidth: .infinity,
               minHeight: 0, idealHeight: docked ? PanelView.islandSize.height : nil, maxHeight: .infinity, alignment: .top)
        .overlay { if docked { island } }
        .overlay { if model.dragging && !docked { dropOverlay } }
        .background { WindowGlass(cornerRadius: docked ? Chrome.islandCornerRadius : Chrome.windowCornerRadius) }
        .background {
            // ⌘N, wherever the cursor is.
            Button("New chat") { model.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onExitCommand { model.escape() }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dragging) { providers in
            PanelView.paths(from: providers) { model.drop($0) }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.onFocus() }
        .task { await model.load() }
        .onChange(of: heightKey, initial: true) { report() }
        .onChange(of: scrollKey, initial: true) {
            // A new turn lands at the bottom of the chat, the way a reply does anywhere else.
            scroll.scrollTo(edge: model.view == .home && !model.thread.isEmpty ? .bottom : .top)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Height

    private var heightKey: [CGFloat] {
        [contentHeight, barHeight, dockHeight, statusHeight, paletteHeight, docked ? 1 : 0, model.welcome ? 1 : 0]
    }

    private var scrollKey: String {
        "\(model.view.rawValue)|\(model.task?.id ?? "")|\(model.task?.question?.id ?? "")|\(model.thread.count)"
    }

    /// What the open palette needs under (or over) the composer.
    private var paletteRoom: CGFloat { paletteHeight > 0 ? paletteHeight + 12 : 0 }

    // The panel is as tall as what it has to say: a one-line answer does not
    // need a tall window, and a long preview should not have to scroll early.
    // The fixed parts are measured directly: mid-animation the window height
    // is not the panel's height, so it cannot be used to work them out.
    private func report() {
        guard contentHeight > 0, barHeight > 0, statusHeight > 0 else { return }
        model.reportHeight(content: max(contentHeight, paletteRoom), chrome: barHeight + (model.chatting ? dockHeight : 0) + statusHeight)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            bar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                .zIndex(2)
            ScrollView {
                workspace
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollPosition($scroll)
            .frame(minHeight: paletteRoom > 0 ? paletteRoom : nil)
            if model.chatting {
                composer(.reply)
                    .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                    .zIndex(2)
            }
            statusBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusHeight = $0 }
        }
    }

    private var bar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.view = .home } label: {
                SpriteView(state: model.petState, mood: model.barMood, size: 46)
                    .frame(width: 50)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Home")
            .accessibilityLabel(Text(verbatim: "Merry home"))

            if model.chatting, let task = model.task {
                chatHead(task)
            } else {
                composer(.launcher)
            }
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.overlay(0.07)).frame(height: 1) }
    }

    private func chatHead(_ task: TaskState) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.chatTitle).font(.system(size: 16, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Chrome.primaryText)
                Group {
                    if model.running {
                        Text(verbatim: "\(task.status == .awaitingUser ? "Needs your answer" : "Merry is on it") · \(model.messageCount)")
                    } else {
                        Text(verbatim: "\(model.messageCount) · \(model.chatAge)")
                    }
                }
                .font(Chrome.mono(10.5)).foregroundStyle(Chrome.tertiaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .help(model.chatRoot?.request ?? "")

            if flatGlass {
                PanelIconButton(icon: .trash, help: "Delete conversation") { model.confirmDelete.toggle() }
                    .disabled(model.running)
            } else {
                ChromeCircleButton(symbol: Icon.trash.rawValue, help: "Delete conversation") { model.confirmDelete.toggle() }
                    .disabled(model.running)
                    .opacity(model.running ? 0.4 : 1)
            }
            NewChatButton(running: model.running, flat: flatGlass) { model.newChat() }
        }
    }

    /// The launcher in the bar starts a new chat; the reply box continues this one.
    private func composer(_ variant: PromptView.Variant) -> some View {
        let followUp = variant == .reply ? model.task?.id : nil
        return PromptView(
            variant: variant,
            placeholder: model.placeholder,
            busy: model.running,
            canAnswer: model.task?.question?.allowFreeText ?? false,
            seed: model.seed,
            dropped: model.dropped,
            front: variant == .launcher ? model.front : nil,
            focusTick: model.focusTick,
            onClearDropped: { model.dropped = [] },
            onAttach: { Task { await model.attach() } },
            onSend: { text, withFront in try await model.send(text, withFront: withFront, followUp: followUp) },
            onCommand: { name in Task { await model.command(name) } },
            onNumber: { model.answerNumber($0) },
            onEscape: { model.escape() },
            onDraft: { model.draft = $0 },
            onPaletteHeight: { paletteHeight = $0 }
        )
        .id(variant)
    }

    // MARK: - Workspace

    @ViewBuilder
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.desktopActive {
                HStack(spacing: 9) {
                    DotGlyphView(kind: .working, color: Chrome.amber)
                    Text(verbatim: "Merry is acting for you").font(.system(size: 12)).foregroundStyle(Color(hex: "#ffd79a"))
                    Spacer()
                    QuietButton(title: "Stop", tint: Chrome.amber, filled: false) { bridge.stopDesktopSession() }
                }
                .padding(.leading, 12).padding(.trailing, 4).frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Chrome.amber.opacity(0.08)))
            }
            if let aside = model.aside {
                HStack(spacing: 9) {
                    Text(verbatim: aside).font(.system(size: 12)).foregroundStyle(Color(hex: "#ffd79a"))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PanelIconButton(icon: .close, help: "Dismiss message", size: 11) { model.aside = nil }
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Chrome.amber.opacity(0.08)))
            }
            if model.view == .home && !model.dropped.isEmpty {
                FlowLayout(spacing: 6) {
                    QuietButton(title: "Keep with Merry") { model.compose("Save these for later") }
                    QuietButton(title: "Extract tasks") { model.compose("Read these documents and propose tasks for my Merry workspace, keeping the source links.") }
                    QuietButton(title: "Prepare copies") { model.compose("Prepare PDF copies of these files under 2 MB each.") }
                }
                .accessibilityLabel(Text(verbatim: "Use attached files"))
            }
            if model.view == .home && model.task == nil { home }
            if model.chatting, let task = model.task { chat(task) }
            if model.view != .home && model.view != .brain { pageHeading }
            if model.view == .past && model.confirmClear {
                ConfirmBar(text: "Delete finished tasks and undo history? Files stay.", confirm: "Delete all", cancelLabel: "Cancel clear history",
                           onConfirm: { Task { await model.clearHistory() } }, onCancel: { model.confirmClear = false })
            }
            page
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChromeCard {
                HomeRow(icon: .list, hue: 5, title: "Workspace", label: "Your workspace", action: { model.view = .brain }) { hovering in
                    WorkspaceBadgeView(badge: model.workspaceBadge, hovering: hovering)
                }
                ForEach(Array(PanelModel.ideas.enumerated()), id: \.element.title) { index, idea in
                    ChromeRowDivider(inset: 50)
                    HomeRow(icon: [Icon.search, .folder, .rename][index], hue: [2, 1, 3][index], title: idea.title, label: idea.title, action: { model.compose(idea.prompt) }) { hovering in
                        RowHint(text: idea.hint, hovering: hovering)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))

            let again = model.again
            if !again.isEmpty {
                ChromeSection(title: "Recent") {
                    ChromeCard {
                        ForEach(Array(again.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { ChromeRowDivider(inset: 50) }
                            HomeRow(icon: .clock, hue: 8, title: PanelModel.firstLine(row.request), label: row.request, quiet: true, action: { model.compose(row.request) }) { _ in EmptyView() }
                                .help(row.request)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))
                }
            }
        }
    }

    private func chat(_ task: TaskState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.confirmDelete {
                ConfirmBar(text: "Delete this conversation and its undo history? Files stay.", confirm: "Delete", cancelLabel: "Cancel deletion",
                           onConfirm: { Task { do { try await model.deleteChat() } catch { model.reportError(error) } } },
                           onCancel: { model.confirmDelete = false })
                    .padding(.bottom, 12)
            }
            ForEach(model.thread, id: \.id) { turn in
                VStack(alignment: .leading, spacing: 12) {
                    AskedBubble(text: turn.request, past: true)
                    VStack(alignment: .leading, spacing: 8) {
                        SaysHead(past: true) { EmptyView() }
                        MarkdownView(turn.summary?.headline ?? turn.error ?? turn.statusLine) { url in Task { try? await bridge.openUrl(url) } }
                            .foregroundStyle(Chrome.primaryText.opacity(0.72))
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.bottom, 22)
            }
            ReplyView(bridge: bridge, task: task, badge: !model.isChat,
                      onRetry: { Task { await model.retry() } },
                      onAnswer: { question, optionId in try await model.answer(question, optionId: optionId) },
                      onSteps: { model.view = .steps },
                      onWorkspace: { model.view = .brain })
                .id(task.id)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var pageHeading: some View {
        HStack(spacing: 6) {
            PanelIconButton(icon: .back, help: "Back home", size: 13) { model.view = .home }
            Text(verbatim: model.view.title).font(.system(size: 17, weight: .semibold))
            Spacer()
            if model.view == .past && model.history.contains(where: { $0.status.isTerminal }) {
                QuietButton(title: "Clear", filled: false) { model.confirmClear.toggle() }
            }
        }
        .padding(.leading, -2)
    }

    @ViewBuilder
    private var page: some View {
        switch model.view {
        case .home: EmptyView()
        case .brain:
            BrainView(bridge: bridge, state: model.brain, onCompose: { model.compose($0) }, onBack: { model.view = .home })
        case .steps:
            StepsView(task: model.task, logs: model.taskLogs)
        case .past:
            PastView(rows: model.history, deleting: deletingRow,
                     onOpen: { id in Task { await model.openTask(id) } },
                     onUndo: { try await model.undoFromHistory($0) },
                     onDelete: { try await model.deleteTask($0) })
        case .keys, .tune:
            TuneView(bridge: bridge, keysOnly: model.view == .keys,
                     onKeyChange: { Task { await model.refreshSetup() } },
                     onSetup: { model.welcome = true })
        case .bench:
            BenchView(rows: model.bench, running: model.benching)
        case .help:
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Files · Mac apps · Browser").font(.system(size: 12)).foregroundStyle(Chrome.secondaryText).padding(.horizontal, 4)
                if model.blind {
                    Button { model.welcome = true } label: {
                        Text(verbatim: "Enable app control →").font(.system(size: 12, weight: .semibold)).foregroundStyle(Chrome.lime)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 4)
                }
                ChromeCard {
                    ForEach(Array(PanelCommand.all.enumerated()), id: \.element.name) { index, command in
                        if index > 0 { ChromeRowDivider(inset: 12) }
                        HelpRow(command: command) { Task { await model.command(command.name) } }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            statusNow
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                PanelIconButton(icon: .list, help: "Workspace", selected: model.view == .brain) { model.view = .brain }
                PanelIconButton(icon: .clock, help: "History", selected: model.view == .past) { Task { await model.command("past") } }
                PanelIconButton(icon: .settings, help: model.hasKey == false ? "Settings · connect a model for app and browser tasks" : "Settings",
                                label: "Settings", selected: model.view == .tune, tint: model.hasKey == false ? Chrome.amber : nil) { model.view = .tune }
                PanelIconButton(icon: .help, help: "Help", selected: model.view == .help) { model.view = .help }
                Rectangle().fill(Chrome.overlay(0.11)).frame(width: 1, height: 16).padding(.horizontal, 6)
                PanelIconButton(icon: .pin,
                                help: model.panel.pinned ? "Keep in front: on. Merry stays open when you click elsewhere" : "Keep in front: off. Merry tucks away when you click elsewhere",
                                label: "Keep in front", selected: model.panel.pinned, tint: model.panel.pinned ? Chrome.lime : nil) { bridge.pinPanel(!model.panel.pinned) }
                PanelIconButton(icon: .minimize, help: "Minimize to the island", label: "Minimize to island") { bridge.minimizePanel() }
                PanelIconButton(icon: .close, help: "Hide (Esc)", label: "Hide Merry", size: 12) { bridge.closePanel() }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Chrome.overlay(0.07)).frame(height: 1) }
    }

    @ViewBuilder
    private var statusNow: some View {
        if model.running, let task = model.task {
            let status = StatusMark.forTask(task.status)
            if model.view == .home {
                StatusView(kind: status.kind, label: status.label) { ElapsedText(since: task.createdAt) }
            } else {
                // Away from the task, the status is also the way back to it.
                Button { model.view = .home } label: {
                    HStack(spacing: 10) {
                        StatusView(kind: status.kind, label: status.label) { ElapsedText(since: task.createdAt) }
                        Text(verbatim: task.status == .awaitingUser ? "Your input needed" : (task.statusLine.isEmpty ? "Task in progress" : task.statusLine))
                            .font(.system(size: 12)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                        Icon.arrow.image(size: 10).foregroundStyle(Chrome.secondaryText)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(task.status == .awaitingUser ? "Your input needed" : "Task in progress"), back to the task"))
            }
        } else if model.desktopActive {
            StatusView(kind: .working, label: "Driving")
        } else if model.chatting {
            hints([("↵", "Reply"), ("⌘N", "New chat"), ("/", "Commands")])
        } else {
            hints([("↵", "Ask"), ("/", "Commands")] + (model.front.map { [("⌥↵", "With \($0.name)")] } ?? []))
        }
    }

    /// Quiet, useful: what the keys do, not a logo.
    private func hints(_ items: [(String, String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Text(verbatim: "·").foregroundStyle(Chrome.tertiaryText).padding(.horizontal, 2) }
                Kbd(item.0)
                Text(verbatim: item.1).foregroundStyle(Chrome.tertiaryText).lineLimit(1)
            }
        }
        .font(.system(size: 11.5))
        .accessibilityHidden(true)
    }

    // MARK: - Island and drop

    /// Minimized: one line of what is happening, and a click to open back out.
    private var island: some View {
        Button { bridge.minimizePanel() } label: {
            HStack(spacing: 10) {
                SpriteView(state: model.petState, mood: model.islandMood, size: 32, quiet: true)
                    .frame(width: 34, height: 32)
                Group {
                    if !model.running, let timer = model.brain.timer {
                        HStack(spacing: 0) {
                            Text(verbatim: "\(timer.label) · ")
                            Group {
                                if timer.status == "ringing" { Text(verbatim: "time’s up") } else { TimerText(timer: timer) }
                            }
                            .font(Chrome.mono(11.5)).monospacedDigit().foregroundStyle(Chrome.lime)
                        }
                    } else {
                        Text(verbatim: model.islandLine)
                    }
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Chrome.primaryText).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.running { IslandWave() } else { Icon.expand.image(size: 11).foregroundStyle(Chrome.tertiaryText) }
            }
            .padding(.leading, 8).padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open Merry")
        .accessibilityLabel(Text(verbatim: "Open Merry"))
    }

    private var dropOverlay: some View {
        VStack(spacing: 10) {
            Icon.attach.image(size: 26)
            Text(verbatim: "Drop files").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Chrome.lime)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: "#101012").opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Chrome.lime, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .padding(6)
        .allowsHitTesting(false)
    }

    /// The file paths in a drop, in the order they were dropped.
    static func paths(from providers: [NSItemProvider], done: @escaping @MainActor ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var found: [Int: String] = [:]
        for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); found[index] = url.path; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let paths = found.sorted { $0.key < $1.key }.map(\.value)
            MainActor.assumeIsolated { done(paths) }
        }
    }
}

// MARK: - Pieces

/// An offscreen capture cannot draw interactive glass; snapshots ask for a flat stand-in.
private struct FlatGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var flatGlass: Bool {
        get { self[FlatGlassKey.self] }
        set { self[FlatGlassKey.self] = newValue }
    }
}

private struct GlassCapsule: ViewModifier {
    var flat: Bool
    func body(content: Content) -> some View {
        if flat { content.background(Capsule(style: .continuous).fill(Chrome.overlay(0.08))) } else { content.chromeGlassCapsule() }
    }
}

/// The way out of a chat.
private struct NewChatButton: View {
    var running: Bool
    var flat = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon.compose.image(size: 11, weight: .semibold)
                Text(verbatim: "New chat").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(verbatim: "⌘N").font(Chrome.mono(9.5)).foregroundStyle(hovering ? Chrome.lime : Chrome.secondaryText)
            }
            .foregroundStyle(running ? Chrome.primaryText.opacity(0.32) : (hovering ? Chrome.lime : Chrome.primaryText.opacity(0.92)))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .fixedSize()
        .modifier(GlassCapsule(flat: flat))
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
        .help(running ? "Merry is still working" : "Start a new chat (⌘N)")
        .accessibilityLabel(Text(verbatim: "New chat"))
    }
}

/// A row on the launcher: something to open, or something to ask for.
private struct HomeRow<Trailing: View>: View {
    var icon: Icon
    var hue: Int
    var title: String
    var label: String
    var quiet = false
    var action: () -> Void
    @ViewBuilder var trailing: (Bool) -> Trailing

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChromeRow(title: title) {
                IconTile(symbol: icon.rawValue, hue: hue)
            } control: {
                trailing(hovering)
            }
            .lineLimit(1)
            .opacity(quiet && !hovering ? 0.85 : 1)
            .background(hovering ? Chrome.overlay(0.05) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// What a row is for, said only when the cursor is on it.
private struct RowHint: View {
    var text: String
    var hovering: Bool

    var body: some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Chrome.tertiaryText).lineLimit(1)
            .opacity(hovering ? 1 : 0)
            .offset(x: hovering ? 0 : -4)
            .padding(.trailing, 4)
            .accessibilityHidden(true)
    }
}

/// Workspace at a glance: the timer if one is running, else what's waiting.
private struct WorkspaceBadgeView: View {
    var badge: PanelModel.WorkspaceBadge
    var hovering: Bool

    var body: some View {
        switch badge {
        case .timer(let timer):
            pill(timer.status == "paused" ? Chrome.amber : Chrome.lime) { TimerText(timer: timer) }
        case .due(let count):
            pill(Chrome.amber) { Text(verbatim: "\(count) due") }
        case .kept(let count):
            pill(Chrome.secondaryText) { Text(verbatim: "\(count) kept") }
        case .hint:
            RowHint(text: "notes, reminders, focus timer", hovering: hovering)
        }
    }

    private func pill<Content: View>(_ color: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(color).lineLimit(1)
            .padding(.trailing, 6)
    }
}

private struct HelpRow: View {
    var command: PanelCommand
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(verbatim: "/\(command.name)").font(Chrome.mono(12, weight: .semibold)).foregroundStyle(Chrome.lime)
                    .frame(width: 86, alignment: .leading)
                Text(verbatim: command.hint).font(.system(size: 13)).foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(hovering ? Chrome.overlay(0.05) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }
}

import AppKit
import SwiftUI
import MerryCore

/// Keeps the permission list current. macOS answers some of these in System
/// MerryCore.Settings, away from Merry, so while it is on screen the list re-reads itself.
@MainActor
public final class SetupModel: ObservableObject {
    @Published public private(set) var items: [SetupItem] = []
    /// The id being asked for right now.
    @Published public private(set) var busy: String?
    @Published public private(set) var error: String?

    private let bridge: MerryBridge
    /// Whether the list can be seen; a hidden panel does not keep re-reading.
    var isOnScreen: () -> Bool = { true }

    public init(bridge: MerryBridge) { self.bridge = bridge }

    public static let groupTitles: [SetupGroup: String] = [
        .control: "Seeing and using apps",
        .apps: "Mac apps",
        .browsers: "Your browsers",
        .folders: "Folders",
        .alerts: "Alerts"
    ]

    public static let order: [SetupGroup] = [.control, .apps, .browsers, .folders, .alerts]

    public static func statusLabel(_ status: SetupStatus) -> String {
        switch status {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notAsked, .unknown: return "Not yet"
        case .asked: return "Sent"
        case .notInstalled: return "Not installed"
        }
    }

    /// Items the one-tap "Allow all" may cover: each shows macOS's own dialog in place.
    public static func asksInPlace(_ item: SetupItem) -> Bool {
        item.group != .control && (item.status == .notAsked || item.status == .unknown)
    }

    public var grantedCount: Int { items.filter { $0.status == .granted }.count }

    /// Reads every permission. Never prompts.
    public func refresh() async { items = await bridge.getSetup() }

    /// Re-reads every 2.5 seconds until the surrounding task is cancelled.
    public func watch() async {
        await refresh()
        while !Task.isCancelled {
            guard (try? await Task.sleep(nanoseconds: 2_500_000_000)) != nil else { return }
            if isOnScreen() { await refresh() }
        }
    }

    public func request(_ id: String) async {
        busy = id; error = nil
        defer { busy = nil }
        do {
            let next = try await bridge.requestSetup(id)
            items = items.map { $0.id == id ? next : $0 }
        } catch {
            let said = messageOf(error)
            self.error = said.isEmpty ? "macOS didn’t answer. Try again." : said
        }
    }

    public func requestAll() async {
        // One at a time: macOS shows one permission dialog at a time anyway.
        for item in items.filter(Self.asksInPlace) { await request(item.id) }
        await refresh()
    }

    public func openSettings(_ id: String) async { await bridge.openSetupSettings(id) }
}

/// Every permission, grouped, each with its status and the one action that changes it.
struct SetupList: View {
    let items: [SetupItem]
    let busy: String?
    let onRequest: (String) -> Void
    let onOpenSettings: (String) -> Void
    var groups: [SetupGroup] = SetupModel.order
    /// One list with no group headings, for a short set that already has its own heading.
    var flat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if flat {
                if !items.isEmpty { card(items) }
            } else {
                ForEach(groups, id: \.self) { group in
                    let rows = items.filter { $0.group == group }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsCaption(SetupModel.groupTitles[group] ?? "").padding(.horizontal, 4)
                            card(rows)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text(verbatim: SetupModel.groupTitles[group] ?? ""))
                    }
                }
            }
        }
    }

    private func card(_ rows: [SetupItem]) -> some View {
        ChromeCard {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ChromeRowDivider(inset: 12) }
                row(item)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SetupItem) -> some View {
        let asking = busy == item.id
        VStack(alignment: .leading, spacing: 0) {
            ChromeRow(title: item.label, detail: item.purpose) {
                HStack(spacing: 10) {
                    // An Allow button already says it has not been allowed yet.
                    if asking || !(item.status == .notAsked || item.status == .unknown) {
                        Text(verbatim: asking ? "Asking" : SetupModel.statusLabel(item.status))
                            .font(Chrome.mono(11))
                            .foregroundStyle(!asking && item.status == .denied ? Chrome.red : Chrome.secondaryText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if item.status == .granted {
                        EmptyView()
                    } else if item.status == .denied {
                        SettingsButton(symbol: Icon.settings.rawValue, title: "Settings", help: "Open System Settings for \(item.label)") { onOpenSettings(item.id) }
                    } else {
                        SettingsButton(symbol: Icon.check.rawValue, title: item.group == .alerts ? "Try it" : "Allow", help: "Allow \(item.label)", isEnabled: busy == nil) { onRequest(item.id) }
                    }
                }
            }
            if let hint = item.hint, !hint.isEmpty, item.status == .granted {
                Text(verbatim: hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }
        }
    }
}

/// Runs a `SetupModel` for as long as a view is on screen: reads once, then
/// keeps reading, and reads again the moment the panel regains focus.
struct SetupWatcher: ViewModifier {
    let setup: SetupModel
    let poll: Bool
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(SettingsWindowReader { found in
                Task { @MainActor in
                    window = found
                    setup.isOnScreen = { [weak found] in found.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? true }
                }
            }.frame(width: 0, height: 0))
            .task { if poll { await setup.watch() } else { await setup.refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard poll, let window, (note.object as? NSWindow) === window else { return }
                Task { await setup.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard poll else { return }
                Task { await setup.refresh() }
            }
    }
}

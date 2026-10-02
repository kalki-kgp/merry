import SwiftUI
import MerryCore

/// Screens of this area that can be rendered with `Merry --snapshot`.
@MainActor
enum SettingsScreens {
    private static let scriptHint = "To read and click in pages, also turn on View → Developer → Allow JavaScript from Apple Events in this browser."

    /// Every permission, as the app lists them, in a mix of states.
    static func setupItems(allGranted: Bool = false) -> [SetupItem] {
        let tabs = "See your open tabs, read the page you are on, and open new tabs."
        let items = [
            SetupItem(id: "accessibility", group: .control, label: "Accessibility", purpose: "Read what is in app windows, press their buttons, and see the text you have selected.", status: .granted),
            SetupItem(id: "screen-recording", group: .control, label: "Screen Recording", purpose: "Look at one window when an app has no readable controls. Only when a task needs it; nothing is recorded or kept.", status: .denied),
            SetupItem(id: "app:com.apple.iCal", group: .apps, label: "Calendar", purpose: "Read your agenda, find free time, and add events you ask for.", status: .granted),
            SetupItem(id: "app:com.apple.reminders", group: .apps, label: "Reminders", purpose: "List, add and complete reminders.", status: .notAsked),
            SetupItem(id: "app:com.apple.Notes", group: .apps, label: "Notes", purpose: "Search, read and save notes.", status: .notAsked),
            SetupItem(id: "app:com.apple.mail", group: .apps, label: "Mail", purpose: "Open drafts for you to check and send. Merry never sends mail itself.", status: .denied),
            SetupItem(id: "app:com.apple.finder", group: .apps, label: "Finder", purpose: "See which files you have selected, so “these” means them.", status: .granted),
            SetupItem(id: "app:com.apple.systemevents", group: .apps, label: "System Events", purpose: "See which apps are open, switch dark mode, and read your selection.", status: .unknown),
            SetupItem(id: "app:com.google.Chrome", group: .browsers, label: "Google Chrome", purpose: tabs, status: .granted, hint: scriptHint),
            SetupItem(id: "app:com.apple.Safari", group: .browsers, label: "Safari", purpose: tabs, status: .notAsked, hint: "To read and click in pages, also turn on Safari → Settings → Advanced → Show features for web developers, then Develop → Allow JavaScript from Apple Events."),
            SetupItem(id: "app:company.thebrowser.Browser", group: .browsers, label: "Arc", purpose: tabs, status: .notInstalled, hint: scriptHint),
            SetupItem(id: "folder:Desktop", group: .folders, label: "Desktop", purpose: "Find, tidy and rename files on your Desktop when you ask.", status: .granted),
            SetupItem(id: "folder:Documents", group: .folders, label: "Documents", purpose: "Find, tidy and rename files in Documents when you ask.", status: .notAsked),
            SetupItem(id: "folder:Downloads", group: .folders, label: "Downloads", purpose: "Find, tidy and rename files in Downloads when you ask.", status: .notAsked),
            SetupItem(id: "notifications", group: .alerts, label: "Notifications", purpose: "Tap you on the shoulder for reminders and when a focus timer ends.", status: .asked)
        ]
        return allGranted ? items.map { var item = $0; item.status = .granted; return item } : items
    }

    static func memories() -> [Memory] {
        func memory(_ id: String, _ text: String, _ source: String, uses: Int) -> Memory {
            Memory(id: id, text: text, kind: source == "told" ? "fact" : "choice", keys: [], source: source, evidence: 1, createdAt: 1_790_000_000_000, updatedAt: 1_790_000_000_000, uses: uses)
        }
        return [
            memory("m1", "My manager is Priya Raman.", "told", uses: 4),
            memory("m2", "I work from the Hyderabad office on Tuesdays and Thursdays.", "told", uses: 1),
            memory("m3", "Invoices go in Documents/Finance, one folder per month.", "told", uses: 0),
            memory("m4", "Standups go on the Work calendar.", "learned", uses: 6),
            memory("m5", "Screenshots are renamed by date, then app.", "learned", uses: 2)
        ]
    }

    /// A Codex catalog with a recommendation and a model this plan cannot use.
    static func codexCatalog() -> CodingModelCatalog {
        var recommended = CodingModel(id: "gpt-5.2-codex", label: "GPT-5.2 Codex")
        recommended.recommended = true
        recommended.recommendation = "Best for everyday planning on your Plus plan."
        recommended.description = "Balanced speed and reasoning for multi-step work."
        var fast = CodingModel(id: "gpt-5.2-codex-mini", label: "GPT-5.2 Codex Mini")
        fast.description = "Faster and lighter on your usage limits."
        var pro = CodingModel(id: "gpt-5.2-pro", label: "GPT-5.2 Pro")
        pro.access = "unavailable"
        pro.reason = "Your Plus plan does not include this model."
        let older = CodingModel(id: "gpt-5.1-codex", label: "GPT-5.1 Codex")
        return CodingModelCatalog(models: [recommended, fast, pro, older], note: "Codex uses your ChatGPT sign-in.", connection: "ChatGPT plus plan", defaultModel: "gpt-5.2-codex")
    }

    static func bridge(app: CodingApp? = .codex, setup: [SetupItem]? = nil, memories: [Memory] = []) -> PreviewBridge {
        let bridge = PreviewBridge()
        bridge.apiKey = true
        bridge.jevKey = false
        bridge.apps = [
            CodingAppStatus(id: .claudeCode, label: "Claude Code", available: true),
            CodingAppStatus(id: .codex, label: "Codex", available: true),
            CodingAppStatus(id: .opencode, label: "OpenCode", available: false)
        ]
        bridge.catalog = codexCatalog()
        bridge.setup = setup ?? setupItems()
        bridge.memories = memories
        bridge.settings.onboarded = true
        if let app {
            bridge.settings.useClaudeCode = true
            bridge.settings.codingApp = app
        }
        return bridge
    }

    static let benchRows: [BenchRow] = [
        BenchRow(group: "On this Mac", label: "Find a file by name", ms: 0.4, detail: "Spotlight index"),
        BenchRow(group: "On this Mac", label: "List a folder of 400 files", ms: 12, detail: "no model"),
        BenchRow(group: "On this Mac", label: "Read the front window", ms: 148, detail: "Accessibility"),
        BenchRow(group: "Over the network", label: "Jev decision", ms: 96, detail: "jev-latest", usd: 0.000004),
        BenchRow(group: "Over the network", label: "Planner, first step", ms: 2340, detail: "claude-sonnet-5-5", usd: 0.004212),
        BenchRow(group: "Coding app", label: "Codex, first reply", ms: 4810, detail: "your ChatGPT plan")
    ]

    /// The panel is 640 wide. Data arrives after the first layout, so a screen
    /// that loads anything says how tall it is.
    private static func page<V: View>(_ view: V, height: CGFloat? = nil) -> some View {
        view.environment(\.settingsFlatGlass, true).frame(width: 640, height: height, alignment: .top)
    }

    static func register() {
        Snapshot.register("settings") {
            page(TuneView(model: TuneModel(bridge: bridge(memories: memories())), expandAll: true), height: 2880)
        }
        Snapshot.register("settings-keys") {
            page(TuneView(model: TuneModel(bridge: bridge(app: nil), keysOnly: true)), height: 200)
        }
        Snapshot.register("settings-model-picker") {
            page(TuneView(model: TuneModel(bridge: bridge(), keysOnly: true)), height: 760)
        }
        Snapshot.register("settings-model-failed") {
            let bridge = bridge()
            bridge.settings.codexModel = "gpt-5.2-codex"
            bridge.modelCheck = CodingModelCheck(ok: false, message: "Codex could not reach this model: your usage limit resets at 6:00 PM.")
            let model = TuneModel(bridge: bridge, keysOnly: true)
            Task { @MainActor in
                guard let picker = model.picker else { return }
                await picker.loadIfNeeded()
                picker.choose("gpt-5.2-codex-mini")
                await picker.checkAndSave()
            }
            return page(TuneView(model: model), height: 800)
        }
        Snapshot.register("settings-memory") {
            page(TuneView(model: TuneModel(bridge: bridge(app: nil, setup: setupItems(allGranted: true), memories: memories()))), height: 700)
        }
        Snapshot.register("settings-permissions") {
            page(TuneView(model: TuneModel(bridge: bridge(app: nil))), height: 1500)
        }
        for (index, card) in WelcomeModel.cards.enumerated() {
            Snapshot.register("welcome-\(card.id)") {
                page(WelcomeView(bridge: bridge(app: card.id == "done" ? .claudeCode : nil), startAt: index), height: card.id == "think" ? 640 : card.id == "done" ? 520 : card.id == "web" ? 600 : 460)
            }
        }
        Snapshot.register("welcome-think-app") {
            page(WelcomeView(bridge: bridge(app: .codex), startAt: 1), height: 640)
        }
        Snapshot.register("bench") { page(BenchView(rows: benchRows, running: false)) }
        Snapshot.register("bench-running") { page(BenchView(rows: [], running: true)) }
    }
}

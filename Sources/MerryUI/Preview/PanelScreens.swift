import SwiftUI
import MerryCore

/// Canned panel data, shared by the snapshot screens and the tests.
@MainActor
enum PanelPreview {
    static let home = "/Users/mira"

    private static func decode<T: Decodable>(_ fields: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(T.self, from: data)
    }

    /// A History row. The type has no public initializer, so it is decoded.
    static func row(_ id: String, _ request: String, status: TaskStatus = .succeeded, headline: String = "", createdAt: Double, undoable: Bool = false, turns: Int = 1) -> TaskSummaryRow {
        decode(["id": id, "request": request, "status": status.rawValue, "headline": headline, "createdAt": createdAt, "undoable": undoable, "turns": turns])
    }

    static func step(_ id: String, _ description: String, _ status: String) -> PlanStep {
        decode(["id": id, "description": description, "status": status])
    }

    static func action(_ step: Int, _ tool: String, at: Double, took: Double, outcome: ActionRecord.Outcome = .success, detail: String? = nil, verified: Bool = true, error: String? = nil) -> ActionRecord {
        var record = ActionRecord(id: "a\(step)", step: step, tool: tool, input: .null, startedAt: at, outcome: outcome)
        record.finishedAt = at + took
        if let detail { record.verification = VerificationResult(verified: verified, method: "stat", detail: detail) }
        record.error = error
        return record
    }

    static func task(_ id: String, _ request: String, status: TaskStatus, line: String = "", ago: Double, took: Double = 0, now: Double, replyTo: String? = nil) -> TaskState {
        var task = TaskState(id: id, request: request, now: now - ago)
        task.status = status
        task.statusLine = line
        task.updatedAt = now - ago + took
        task.replyTo = replyTo
        switch status {
        case .succeeded: task.petState = .finished
        case .failed, .cancelled: task.petState = .failed
        case .awaitingUser: task.petState = .waiting
        case .planning, .pending: task.petState = .thinking
        default: task.petState = .working
        }
        return task
    }

    static func bridge() -> PreviewBridge {
        let bridge = PreviewBridge()
        bridge.settings.onboarded = true
        bridge.apiKey = true
        bridge.permissions = bridge.permissions.map { PermissionStatus(permission: $0.permission, granted: true, purpose: $0.purpose) }
        return bridge
    }

    static func history(now: Double) -> [TaskSummaryRow] {
        [
            row("h1", "Organize my Downloads folder", headline: "Sorted 212 files into 6 folders.", createdAt: now - 4 * 60_000, undoable: true),
            row("h2", "What changed in the Q3 budget sheet since Monday?", headline: "Three rows changed.", createdAt: now - 38 * 60_000, turns: 3),
            row("h3", "Rename these files consistently", headline: "Renamed 14 screenshots.", createdAt: now - 2 * 3_600_000, undoable: true),
            row("h4", "Find the lease agreement PDF", headline: "Found it in Documents/Home.", createdAt: now - 5 * 3_600_000),
            row("h5", "Book a table at Olive for Friday 8pm", status: .failed, headline: "The booking page needs a login.", createdAt: now - 26 * 3_600_000),
            row("h6", "Organize my Downloads folder", headline: "Sorted 96 files.", createdAt: now - 3 * 86_400_000),
            row("h7", "Summarize the notes from Thursday’s standup", status: .cancelled, headline: "", createdAt: now - 6 * 86_400_000, turns: 2)
        ]
    }

    static func brain(now: Double, timer: Bool = false) -> BrainSnapshot {
        func item(_ id: String, _ kind: String, _ title: String, due: Double? = nil) -> BrainItem {
            decode(["kind": kind, "title": title, "body": "", "projectId": NSNull(), "dueAt": due ?? NSNull(), "repeat": "none", "estimateMinutes": NSNull(),
                    "sources": [Any](), "id": id, "status": "open", "createdAt": now - 86_400_000, "updatedAt": now - 86_400_000,
                    "notifiedAt": NSNull(), "acknowledgedAt": NSNull(), "checks": [String]()])
        }
        var snapshot = BrainSnapshot(items: [
            item("b1", "reminder", "Send the signed lease back", due: now - 20 * 60_000),
            item("b2", "reminder", "Call the dentist", due: now - 5 * 60_000),
            item("b3", "note", "Wi-Fi password for the studio"),
            item("b4", "task", "Draft the October invoice")
        ])
        if timer {
            snapshot.timer = BrainTimer(id: "t1", label: "Invoice draft", durationMs: 25 * 60_000, remainingMs: 17 * 60_000 + 24_000, endsAt: now + 17 * 60_000 + 24_000, status: "running", notifiedAt: nil)
        }
        return snapshot
    }

    static func running(now: Double) -> TaskState {
        var task = task("run", "Organize my Downloads folder", status: .executing, line: "Moving 212 files into folders by type", ago: 42_000, took: 41_000, now: now)
        task.plan = [
            step("p1", "Look at what is in Downloads", "done"),
            step("p2", "Group the files by type and month", "done"),
            step("p3", "Move each group into its folder", "active"),
            step("p4", "Check every file arrived", "pending")
        ]
        task.actions = [action(1, "files_list", at: now - 40_000, took: 310, detail: "212 files listed")]
        return task
    }

    static func question(now: Double) -> TaskState {
        var task = task("ask", "Rename these files consistently", status: .awaitingUser, line: "Waiting for your answer", ago: 18_000, took: 17_000, now: now)
        let folder = "\(home)/Desktop/Screenshots"
        let stamps = ["09.14.02", "09.14.48", "09.31.10", "10.02.57", "10.03.21", "11.47.09", "12.20.33", "13.05.40", "14.18.12", "14.18.55", "15.42.06", "16.09.31", "17.30.44", "18.02.19"]
        let ops = stamps.enumerated().map { index, stamp in
            FileOp(from: "\(folder)/Screenshot 2026-10-01 at \(stamp).png", to: "\(folder)/2026-10-01 screenshot \(String(index + 1).jsPadStart(2, "0")).png", kind: "rename")
        }
        task.question = UserQuestion(
            id: "q1", reason: .ambiguous,
            prompt: "I’d give these 14 screenshots one pattern: the date, then a number in the order they were taken. Go ahead?",
            options: [QuestionOption(id: "ok", label: "Rename them"), QuestionOption(id: "keep-time", label: "Keep the time in the name"), QuestionOption(id: "no", label: "Leave them")],
            preview: PreviewPayload(title: "14 files will be renamed", fileOps: ops, note: "Nothing moves out of Screenshots. You can undo this afterwards."),
            allowFreeText: true)
        return task
    }

    static func authorization(now: Double) -> TaskState {
        var task = task("auth", "Tidy up my Desktop", status: .awaitingUser, line: "Waiting for your answer", ago: 9_000, took: 8_000, now: now)
        task.question = UserQuestion(
            id: "q2", reason: .authorization,
            prompt: "To tidy your Desktop I need to create folders and move files inside ~/Desktop. Allow that for this task?",
            options: [QuestionOption(id: "allow", label: "Allow for this task", detail: "Only ~/Desktop, only until this task ends"), QuestionOption(id: "deny", label: "Not now")],
            allowFreeText: false)
        return task
    }

    static func done(now: Double) -> TaskState {
        var task = task("done", "Organize my Downloads folder", status: .succeeded, line: "Done", ago: 4 * 60_000, took: 47_000, now: now)
        task.actions = [
            action(1, "files_list", at: now - 239_000, took: 310, detail: "212 files listed"),
            action(2, "files_make_folder", at: now - 236_000, took: 120, detail: "6 folders exist"),
            action(3, "files_move", at: now - 231_000, took: 18_400, detail: "210 of 210 files are at their new paths"),
            action(4, "files_move", at: now - 212_000, took: 900, outcome: .failure, error: "invoice-draft.pdf is open in Preview"),
            action(5, "files_list", at: now - 205_000, took: 280, outcome: .uncertain),
            action(6, "brain_save", at: now - 200_000, took: 60, detail: "Note saved")
        ]
        task.observations = [
            Observation(id: "o1", kind: "files", summary: "Downloads: 212 files, 1.8 GB, oldest from March", data: .null, observedAt: now - 239_000, staleAfterMs: 60_000),
            Observation(id: "o2", kind: "window", summary: "Preview has invoice-draft.pdf open", data: .null, observedAt: now - 212_000, staleAfterMs: 60_000)
        ]
        task.summary = TaskSummary(
            headline: "Sorted **210 files** in Downloads into six folders by type. Two PDFs were open in Preview, so I left those where they are.",
            evidence: [
                .path("Downloads", "\(home)/Downloads"),
                .url("How Merry sorts files", "https://merry.example/help/organize"),
                .text("Left alone", "invoice-draft.pdf and lease-2026.pdf are open in Preview."),
                .text("Merry workspace", "Saved a note of what moved where")
            ],
            undoable: true)
        return task
    }

    static func failed(now: Double) -> TaskState {
        var task = task("fail", "Book a table at Olive for Friday 8pm", status: .failed, line: "Stopped at the booking page", ago: 90_000, took: 31_000, now: now)
        task.error = "The booking page asks for a login, and I can’t sign in for you. Open it in your browser, sign in, and try again."
        task.actions = [action(1, "browser_open", at: now - 88_000, took: 2_400, detail: "Page loaded")]
        return task
    }

    static func chat(now: Double) -> (thread: [TaskState], task: TaskState) {
        var first = task("c1", "What changed in the Q3 budget sheet since Monday?", status: .succeeded, ago: 38 * 60_000, took: 9_000, now: now)
        first.summary = TaskSummary(headline: "Three rows changed: **Travel** went up by ₹18,000, **Software** dropped the unused Figma seats, and a new **Contractors** row was added on Tuesday.")
        var second = task("c2", "Who added the contractors row?", status: .succeeded, ago: 36 * 60_000, took: 4_000, now: now, replyTo: "c1")
        second.summary = TaskSummary(headline: "Anika added it on Tuesday at 4:12 pm.")
        var third = task("c3", "Draft a short note to her asking what it covers", status: .succeeded, ago: 35 * 60_000, took: 6_000, now: now, replyTo: "c2")
        third.summary = TaskSummary(headline: """
        Here’s a short one:

        > Hi Anika, I saw the new Contractors row in the Q3 sheet. Could you tell me what it covers and whether it runs past September?

        Two things you may want to add:

        - **Amount**: whether the ₹2.4 lakh is a cap or an estimate
        - **Owner**: who signs off on the invoices
        """)
        return ([first, second], third)
    }

    static func logs(now: Double) -> [LogEntry] {
        [
            LogEntry(taskId: "done", at: now - 239_000, level: .info, source: "loop", message: "route: files"),
            LogEntry(taskId: "done", at: now - 236_000, level: .info, source: "tool:files_make_folder", message: "created 6 folders"),
            LogEntry(taskId: "done", at: now - 212_000, level: .warn, source: "tool:files_move", message: "skipped 2 files that are open")
        ]
    }

    static func model(_ bridge: PreviewBridge, now: Double) -> PanelModel {
        let model = PanelModel(bridge: bridge, now: { now })
        // What `load()` will find, already in place for the first layout.
        model.history = bridge.history
        model.brain = bridge.brain
        model.hasKey = true
        return model
    }
}

/// The panel at the height it would ask its window for.
private struct PanelSnapshot: View {
    var model: PanelModel
    var deletingRow: String?
    var height: CGFloat?

    var body: some View {
        PanelHeight(fixed: height) { PanelView(model: model, deletingRow: deletingRow).environment(\.flatGlass, true) }
    }
}

private struct PanelHeight: Layout {
    var fixed: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(.unspecified)
        if natural.height <= PanelView.islandSize.height { return natural }
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: PanelView.width, height: nil))
        let height = fixed ?? min(660, max(120, PanelModel.panelHeight(content: ideal.height, chrome: 0)))
        return CGSize(width: PanelView.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Screens of this area that can be rendered with `Merry --snapshot`.
@MainActor
enum PanelScreens {
    static func register() {
        let now = nowMs()

        func screen(_ name: String, height: CGFloat? = nil, deletingRow: String? = nil, _ setup: @escaping (PreviewBridge) -> Void = { _ in }, _ arrange: @escaping (PanelModel) -> Void = { _ in }) {
            Snapshot.register(name) {
                let bridge = PanelPreview.bridge()
                setup(bridge)
                let model = PanelPreview.model(bridge, now: now)
                arrange(model)
                return PanelSnapshot(model: model, deletingRow: deletingRow, height: height)
            }
        }

        screen("panel-home")
        screen("panel-home-recents", { bridge in
            bridge.history = PanelPreview.history(now: now)
            bridge.brain = PanelPreview.brain(now: now)
            bridge.frontWindow = FrontWindow(pid: 412, name: "Safari", title: "Olive — Reservations")
        })
        screen("panel-home-timer", { bridge in
            bridge.history = PanelPreview.history(now: now)
            bridge.brain = PanelPreview.brain(now: now, timer: true)
        })
        screen("panel-home-files", { _ in }, { model in
            model.dropped = (1...7).map { "\(PanelPreview.home)/Downloads/receipt-2026-0\($0).pdf" }
        })
        screen("panel-running", { _ in }, { model in
            model.petState = .working
            model.task = PanelPreview.running(now: now)
        })
        screen("panel-question", { _ in }, { model in
            model.petState = .waiting
            model.task = PanelPreview.question(now: now)
        })
        screen("panel-authorization", { _ in }, { model in
            model.petState = .waiting
            model.task = PanelPreview.authorization(now: now)
        })
        screen("panel-done", { _ in }, { model in
            model.petState = .finished
            model.task = PanelPreview.done(now: now)
        })
        screen("panel-failed", { _ in }, { model in
            model.petState = .failed
            model.task = PanelPreview.failed(now: now)
        })
        screen("panel-chat", { _ in }, { model in
            let chat = PanelPreview.chat(now: now)
            model.thread = chat.thread
            model.task = chat.task
        })
        screen("panel-steps", { _ in }, { model in
            model.task = PanelPreview.done(now: now)
            model.logs = PanelPreview.logs(now: now)
            model.view = .steps
        })
        screen("panel-history", deletingRow: "h2", { bridge in
            bridge.history = PanelPreview.history(now: now)
        }, { model in
            model.view = .past
        })
        screen("panel-help", { bridge in
            bridge.permissions = bridge.permissions.map { PermissionStatus(permission: $0.permission, granted: false, purpose: $0.purpose) }
        }, { model in
            model.blind = true
            model.view = .help
        })
        screen("panel-palette", height: 460, { _ in }, { model in
            model.seed = PanelModel.Seed(text: "/", id: 1)
        })
        screen("panel-drop", { bridge in
            bridge.history = PanelPreview.history(now: now)
        }, { model in
            model.dragging = true
        })
        screen("island-idle", { bridge in bridge.panel.docked = true })
        screen("island-working", { bridge in bridge.panel.docked = true }, { model in
            model.petState = .working
            model.task = PanelPreview.running(now: now)
        })
        screen("island-timer", { bridge in
            bridge.panel.docked = true
            bridge.brain = PanelPreview.brain(now: now, timer: true)
        })
    }
}

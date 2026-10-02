import SwiftUI
import MerryCore

/// A workspace with something of every kind in it, for previews and tests.
@MainActor
enum BrainSamples {
    /// Friday 2 October 2026, 14:30 local time.
    static var now: Double { at(14, 30) }

    static func at(_ hours: Int, _ minutes: Int, day: Int = 0) -> Double {
        JSDate(year: 2026, month: 9, day: 2 + day, hours: hours, minutes: minutes).time
    }

    static func item(_ id: String, _ kind: String, _ title: String, body: String = "", projectId: String? = nil, dueAt: Double? = nil,
                     repeats: String = "none", estimate: Int? = nil, sources: [BrainSource] = [], status: String = "open",
                     updatedAt: Double = 1000, notifiedAt: Double? = nil, acknowledgedAt: Double? = nil, checks: [String] = []) -> BrainItem {
        let json: JSON = [
            "kind": .string(kind), "title": .string(title), "body": .string(body), "projectId": JSON(projectId), "dueAt": JSON(dueAt),
            "repeat": .string(repeats), "estimateMinutes": JSON(estimate),
            "sources": .array(sources.map { ["kind": .string($0.kind), "label": .string($0.label), "value": .string($0.value)] }),
            "id": .string(id), "status": .string(status), "createdAt": 1000, "updatedAt": .number(updatedAt),
            "notifiedAt": JSON(notifiedAt), "acknowledgedAt": JSON(acknowledgedAt), "checks": JSON(checks)
        ]
        // The shape is fixed above, so this cannot fail.
        return try! JSONDecoder().decode(BrainItem.self, from: Data(json.stringify().utf8))
    }

    static func timer(_ status: String, remainingMs: Double = 25 * 60000, endsAt: Double? = nil, label: String = "Deep work") -> BrainTimer {
        BrainTimer(id: "timer", label: label, durationMs: 25 * 60000, remainingMs: remainingMs, endsAt: endsAt, status: status, notifiedAt: status == "ringing" ? now : nil)
    }

    static var project: BrainItem { item("p1", "project", "Merry native port", body: "Swift rewrite of the Electron app, one area at a time.", updatedAt: 9000) }

    static var tracker: BrainItem {
        item("k1", "tracker", "Read 20 pages", updatedAt: 1500, checks: ["2026-09-26", "2026-09-28", "2026-09-30", "2026-10-01", "2026-10-02"])
    }

    static var projectItems: [BrainItem] {
        [
            project,
            item("t1", "task", "Port the workspace page", body: "Timer card, list, editor, tests.", projectId: "p1", estimate: 50,
                 sources: [BrainSource(kind: "url", label: "github.com", value: "https://github.com/kalki-kgp/merry"),
                           BrainSource(kind: "path", label: "Brain.tsx", value: "/Users/k/Developer/merry/src/renderer/src/components/Brain.tsx")], updatedAt: 8000),
            item("t2", "task", "Review the panel merge", projectId: "p1", dueAt: at(18, 15), updatedAt: 7000),
            item("n2", "note", "Glass renders flat in snapshots", body: "It needs a live window to refract.", projectId: "p1", updatedAt: 3900),
            item("s1", "session", "Workspace port, day two", body: "Left off at the editor. Next: the tests.", projectId: "p1",
                 sources: [BrainSource(kind: "path", label: "BrainView.swift", value: "/Users/k/Developer/merry/Sources/MerryUI/Brain/BrainView.swift")], updatedAt: 2000)
        ]
    }

    static var everything: BrainSnapshot {
        BrainSnapshot(items: projectItems + [
            item("t3", "task", "Water the plants", updatedAt: 6800),
            item("t4", "task", "File the expense report", status: "done", updatedAt: 6000),
            item("r1", "reminder", "Call Aai", dueAt: at(9, 30), repeats: "weekly", updatedAt: 5000, notifiedAt: at(9, 30)),
            item("r3", "reminder", "Take a walk", dueAt: at(17, 0), repeats: "daily", updatedAt: 4800),
            item("r4", "reminder", "Pay rent", dueAt: at(10, 0, day: 1), updatedAt: 4700),
            item("r5", "reminder", "Renew passport", dueAt: at(11, 5, day: 40), updatedAt: 4600),
            item("n1", "note", "Wi-Fi at the office", body: "Guest network changes every Monday.\nAsk the front desk.", updatedAt: 4000),
            item("b1", "bookmark", "Liquid Glass notes", sources: [BrainSource(kind: "url", label: "developer.apple.com", value: "https://developer.apple.com/documentation/")], updatedAt: 3000),
            tracker,
            item("k2", "tracker", "Stretch", updatedAt: 1400, checks: ["2026-10-01"]),
            item("a1", "note", "Old flat checklist", status: "archived", updatedAt: 900)
        ])
    }

    /// One of every kind, put away.
    static var archived: BrainSnapshot {
        BrainSnapshot(items: everything.items.filter { ["p1", "t1", "r4", "n1", "b1", "s1", "k1"].contains($0.id) }.map { item in
            var copy = item
            copy.status = "archived"
            copy.projectId = nil
            return copy
        })
    }
}

/// Screens of this area that can be rendered with `Merry --snapshot`.
@MainActor
enum BrainScreens {
    static func page(_ state: BrainSnapshot, prepare: ((BrainModel) -> Void)? = nil) -> some View {
        let bridge = PreviewBridge()
        bridge.brain = state
        return BrainView(bridge: bridge, state: state, now: BrainSamples.now, prepare: prepare, onCompose: { _ in }, onBack: {})
            // The panel's own padding around its scrolling content.
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 12, trailing: 10))
            // Tinted glass captures as a white sheet offscreen, so the glass controls are drawn flat here.
            .environment(\.brainFlatGlass, true)
            .frame(width: 640)
    }

    static func register() {
        let s = BrainSamples.self
        Snapshot.register("brain-empty") { page(BrainSnapshot()) }
        Snapshot.register("brain-mixed") { page(s.everything) }
        Snapshot.register("brain-search") { page(s.everything) { $0.query = "port" } }
        Snapshot.register("brain-archive") { page(s.archived) { $0.tab = .archive } }
        Snapshot.register("brain-reminders") { page(s.everything) { $0.tab = .reminder } }
        Snapshot.register("brain-tasks") { page(s.everything) { $0.tab = .task } }
        Snapshot.register("brain-timer-running") { page(BrainSnapshot(items: s.everything.items, timer: s.timer("running", endsAt: s.now + 17 * 60000 + 42000))) }
        Snapshot.register("brain-timer-paused") { page(BrainSnapshot(timer: s.timer("paused", remainingMs: 7 * 60000 + 5000))) }
        Snapshot.register("brain-timer-ringing") { page(BrainSnapshot(timer: s.timer("ringing", remainingMs: 0))) }
        Snapshot.register("brain-due") { page(BrainSnapshot(items: [s.item("r1", "reminder", "Call Aai", body: "She asked about the Diwali tickets.", dueAt: s.at(14, 10), repeats: "weekly", notifiedAt: s.at(14, 10))])) }
        Snapshot.register("brain-editor") {
            page(BrainSnapshot(items: [s.project])) {
                $0.tab = .reminder
                $0.beginNew()
                $0.editing?.title = "Pay rent"
                $0.editing?.body = "Transfer before noon so it clears the same day."
                $0.editing?.due = BrainModel.localTime(s.at(10, 0, day: 1))
                $0.editing?.repeats = "weekly"
            }
        }
        Snapshot.register("brain-editor-task") {
            page(s.everything) {
                $0.tab = .task
                $0.beginEdit(s.projectItems[1])
                $0.editing?.error = "Use an http or https link."
            }
        }
        Snapshot.register("brain-tracker") { page(BrainSnapshot(items: [s.tracker, s.item("k2", "tracker", "Stretch", checks: ["2026-10-01"])])) { $0.tab = .tracker } }
        Snapshot.register("brain-project") { page(BrainSnapshot(items: s.projectItems)) { $0.tab = .project } }
        Snapshot.register("brain-project-items") { page(s.everything) { $0.viewProject(s.project) } }
        Snapshot.register("brain-error") { page(s.everything) { $0.error = "This item no longer exists." } }
    }
}

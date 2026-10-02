import Combine
import Foundation
import MerryCore

/// A section of the workspace: Today, one kind of thing, or the archive.
enum BrainTab: String, CaseIterable, Hashable, Sendable {
    case today, note, task, reminder, project, bookmark, session, tracker, archive

    var name: String {
        switch self {
        case .today: return "Today"
        case .note: return "Notes"
        case .task: return "Tasks"
        case .reminder: return "Reminders"
        case .project: return "Projects"
        case .bookmark: return "Saved"
        case .session: return "Sessions"
        case .tracker: return "Trackers"
        case .archive: return "Archive"
        }
    }

    /// The kinds an item can be, in the order the page lists them.
    static let kinds: [BrainTab] = [.note, .task, .reminder, .project, .bookmark, .session, .tracker]

    /// What an empty section offers to do instead: a sentence to hand Merry.
    var starters: [(label: String, prompt: String)] {
        switch self {
        case .today: return [("Remind me…", "Remind me to "), ("Add a task", "Add a task: "), ("Track a habit", "Track reading daily")]
        case .note: return [("Write a note", "Note: ")]
        case .task: return [("Add a task", "Add a task: ")]
        case .reminder: return [("Remind me…", "Remind me to ")]
        case .project: return [("Start a project", "Start a project called ")]
        case .bookmark: return [("Save a link", "Save this link for later: ")]
        case .session: return [("Save where I am", "Save where I am. My next step is ")]
        case .tracker: return [("Track a habit", "Track reading daily")]
        case .archive: return []
        }
    }
}

struct BrainSection: Equatable {
    var tab: BrainTab
    var name: String
    var count: Int
}

struct BrainGroup: Equatable {
    /// Empty for the plain list.
    var label: String
    var items: [BrainItem]
}

/// One day of a tracker's last week.
struct BrainDay: Equatable {
    var key: String
    var letter: String
    var checked: Bool
    var isToday: Bool
}

/// The extra things a row offers under its text.
enum BrainMore: Equatable {
    case viewProject, saveSession, resume, snooze, dismiss

    var label: String {
        switch self {
        case .viewProject: return "View project"
        case .saveSession: return "Save a session"
        case .resume: return "Resume with Merry"
        case .snooze: return "In 10 min"
        case .dismiss: return "Dismiss alert"
        }
    }
}

/// What the editor holds while something is being written or changed.
struct BrainDraft: Equatable {
    /// The item being changed; nil for a new one.
    var id: String?
    var kind: String
    var title = ""
    var body = ""
    var projectId: String?
    var repeats = "none"
    /// The estimate as typed; empty for none.
    var estimate = ""
    var sources: [BrainSource] = []
    /// The reminder time as `yyyy-MM-ddTHH:mm` in local time; empty for none.
    var due = ""
    var url = ""
    var busy = false
    var error = ""
}

/// The workspace page's state and rules, apart from how it is drawn.
@MainActor
final class BrainModel: ObservableObject {
    /// The locale dates are shown in. Tests pin it; the zone is `LocalTime`'s.
    static var locale: Locale = .autoupdatingCurrent
    static let presets = [15, 25, 50]
    /// Groups read top to bottom in this order; unnamed is the plain list.
    static let groupOrder = ["Overdue", "Later today", "Tasks", "Habits", "", "Done"]

    let bridge: MerryBridge

    @Published var state: BrainSnapshot {
        // With nothing kept there are no sections to pick from, so land back on Today.
        didSet { if state.items.isEmpty, tab != .today { tab = .today } }
    }
    @Published var tab: BrainTab = .today
    @Published var query = ""
    /// The project the list is narrowed to; empty for all of them.
    @Published var project = ""
    @Published var editing: BrainDraft?
    @Published var error = ""
    @Published var busy = false

    /// The idle timer's duration as typed, and its label.
    @Published var minutesText = "25"
    @Published var label = "Focus time"

    init(bridge: MerryBridge, state: BrainSnapshot = BrainSnapshot()) {
        self.bridge = bridge
        self.state = state
    }

    // MARK: - What is shown

    var projects: [BrainItem] { state.items.filter { $0.kind == "project" && $0.status == "open" } }
    var searching: Bool { !query.jsTrimmed.isEmpty }
    /// Groups already say what things are; only a flat mixed list needs the kind spelled out.
    var mixed: Bool { tab == .archive || searching }
    var openCount: Int { state.items.filter { $0.status == "open" }.count }

    func due(now: Double) -> [BrainItem] { state.dueItems(now: now) }

    func dueNotice(now: Double) -> String? {
        let n = due(now: now).count
        return n > 0 ? "\(n) reminder\(n == 1 ? "" : "s") waiting" : nil
    }

    static func endOfDay(_ now: Double) -> Double { JSDate(now).with { $0.setHours(23, 59, 59, 999) }.time }
    static func startOfDay(_ ms: Double) -> Double { JSDate(ms).with { $0.setHours(0, 0, 0, 0) }.time }

    func isToday(_ i: BrainItem, now: Double) -> Bool {
        i.status == "open" && (i.kind == "task" || i.kind == "tracker" || (i.dueAt != nil && i.dueAt! <= Self.endOfDay(now)))
    }

    func count(_ key: BrainTab, now: Double) -> Int {
        state.items.filter { i in
            switch key {
            case .archive: return i.status == "archived"
            case .today: return isToday(i, now: now)
            default: return i.status == "open" && i.kind == key.rawValue
            }
        }.count
    }

    /// Only sections with something in them: nine tabs for an empty workspace is a form, not a place.
    func sections(now: Double) -> [BrainSection] {
        BrainTab.allCases.map { BrainSection(tab: $0, name: $0.name, count: count($0, now: now)) }.filter { section in
            let key = section.tab
            return key == .today || key == tab || section.count > 0
                || (key != .archive && state.items.contains { $0.kind == key.rawValue && $0.status != "archived" })
        }
    }

    func isSelected(_ key: BrainTab) -> Bool { tab == key && !searching }

    func visible(now: Double) -> [BrainItem] {
        let needle = query.jsTrimmed.lowercased()
        let kept = state.items.filter { i in
            if tab == .archive ? i.status != "archived" : i.status == "archived" { return false }
            if !project.isEmpty, i.projectId != project, i.id != project { return false }
            if searching { return "\(i.title) \(i.body) \(i.sources.map(\.label).joined(separator: " "))".lowercased().contains(needle) }
            if tab == .today { return isToday(i, now: now) }
            return tab == .archive || i.kind == tab.rawValue
        }
        // Done last, then soonest first, then most recently touched; otherwise the order they came in.
        return kept.enumerated().sorted { a, b in
            let doneA = a.element.status == "done", doneB = b.element.status == "done"
            if doneA != doneB { return !doneA }
            let dueA = a.element.dueAt ?? .infinity, dueB = b.element.dueAt ?? .infinity
            if dueA != dueB { return dueA < dueB }
            if a.element.updatedAt != b.element.updatedAt { return a.element.updatedAt > b.element.updatedAt }
            return a.offset < b.offset
        }.map(\.element)
    }

    func groupOf(_ i: BrainItem, now: Double) -> String {
        if tab == .archive || searching { return "" }
        if i.status == "done" { return "Done" }
        if let due = i.dueAt, due <= now { return "Overdue" }
        if tab != .today { return "" }
        if let due = i.dueAt, due <= Self.endOfDay(now) { return "Later today" }
        return i.kind == "tracker" ? "Habits" : "Tasks"
    }

    func groups(now: Double) -> [BrainGroup] {
        let shown = visible(now: now)
        return Self.groupOrder.map { label in BrainGroup(label: label, items: shown.filter { groupOf($0, now: now) == label }) }
            .filter { !$0.items.isEmpty }
    }

    /// "Fri, Oct 2", and how many things are open when any are.
    func headerDate(now: Double) -> String { Self.format(now, "EEEdMMM") }

    // MARK: - A row

    func isOverdue(_ i: BrainItem, now: Double) -> Bool { i.status == "open" && i.dueAt != nil && i.dueAt! <= now }
    func isCheckable(_ i: BrainItem) -> Bool { i.kind == "task" || i.kind == "reminder" }
    func checkLabel(_ i: BrainItem) -> String { "\(i.status == "done" ? "Reopen" : "Complete") \(i.title)" }
    func archiveLabel(_ i: BrainItem) -> String { i.status == "archived" ? "Restore" : "Archive" }
    func kindLabel(_ i: BrainItem) -> String { i.kind == "bookmark" ? "saved" : i.kind }
    func doneToday(_ i: BrainItem, now: Double) -> Bool { i.checks.contains(dayKey(now)) }
    func checkInLabel(_ i: BrainItem, now: Double) -> String { doneToday(i, now: now) ? "Done today" : "Check in today" }

    func projectName(_ i: BrainItem) -> String? {
        guard let id = i.projectId, !id.isEmpty else { return nil }
        return state.items.first { $0.id == id }?.title
    }

    static func icon(_ kind: String) -> Icon {
        switch kind {
        case "task": return .check
        case "reminder": return .clock
        case "project": return .folder
        case "bookmark": return .pin
        case "session": return .expand
        case "tracker": return .spark
        default: return .rename
        }
    }

    /// When it is due, and how often: "Today 9:30 AM · weekly".
    func dueText(_ i: BrainItem, now: Double) -> String? {
        guard let due = i.dueAt else { return nil }
        return Self.dateLabel(due, now: now) + (i.repeat != "none" ? " · \(i.repeat)" : "")
    }

    func estimateText(_ i: BrainItem) -> String? {
        guard let minutes = i.estimateMinutes, minutes != 0 else { return nil }
        return "\(minutes) min"
    }

    func sourceLabel(_ source: BrainSource) -> String { source.label.isEmpty ? source.value : source.label }

    /// The last seven days, today last.
    func days(_ i: BrainItem, now: Double) -> [BrainDay] {
        (0..<7).map { n in
            let d = JSDate(now).with { $0.setDate($0.day - 6 + n) }
            let key = dayKey(d.time)
            return BrainDay(key: key, letter: Self.format(d.time, "EEEEE"), checked: i.checks.contains(key), isToday: n == 6)
        }
    }

    func more(_ i: BrainItem, now: Double) -> [BrainMore] {
        var out: [BrainMore] = []
        if i.kind == "project" { out += [.viewProject, .saveSession] }
        if i.kind == "session" { out.append(.resume) }
        if isOverdue(i, now: now) {
            out.append(.snooze)
            if i.acknowledgedAt == nil { out.append(.dismiss) }
        }
        return out
    }

    /// The sentence a row hands Merry, for the two offers that are requests rather than actions.
    func prompt(_ more: BrainMore, _ i: BrainItem) -> String? {
        switch more {
        case .saveSession: return "Save where I am with project \"\(i.title)\". My next step is "
        case .resume: return "Help me resume the saved Merry session \"\(i.title)\" (id \(i.id)). Show its next steps and saved sources."
        default: return nil
        }
    }

    // MARK: - Nothing to show

    func showsEmpty(now: Double) -> Bool { visible(now: now).isEmpty && editing == nil }
    var emptyMood: Mood { searching ? .curious : .reading }
    var emptyTitle: String {
        searching ? "Nothing matched that." : tab == .today ? "Room to think." : tab == .archive ? "Nothing archived." : "Nothing here yet."
    }
    var emptyDetail: String {
        searching ? "Try a title, a phrase, or another project." : tab == .archive ? "Archived things wait here until you need them again." : "Add something, or just tell Merry to keep it."
    }
    var starters: [(label: String, prompt: String)] { searching ? [] : tab.starters }

    // MARK: - Moving around

    func select(_ key: BrainTab) {
        tab = key
        query = ""
        editing = nil
    }

    func review() {
        tab = .today
        query = ""
        project = ""
    }

    func viewProject(_ i: BrainItem) {
        project = i.id
        tab = .today
    }

    /// Escape in the search field clears it; with nothing typed the key is left alone.
    func clearSearch() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }

    // MARK: - Actions

    func act(_ request: JSON) async {
        busy = true
        error = ""
        do { _ = try await bridge.brainRequest(request) } catch { self.error = Self.message(error, or: "Could not save that.") }
        busy = false
    }

    func toggleDone(_ i: BrainItem) async { await act(["op": .string(i.status == "done" ? "reopen" : "complete"), "id": .string(i.id)]) }
    func toggleArchive(_ i: BrainItem) async { await act(["op": .string(i.status == "archived" ? "reopen" : "archive"), "id": .string(i.id)]) }
    func checkIn(_ i: BrainItem) async { await act(["op": "check", "id": .string(i.id)]) }
    func snooze(_ i: BrainItem) async { await act(["op": "snooze", "id": .string(i.id), "minutes": 10]) }
    func acknowledge(_ i: BrainItem) async { await act(["op": "acknowledge", "id": .string(i.id)]) }

    func open(_ source: BrainSource) async {
        do {
            if source.kind == "url" { try await bridge.openUrl(source.value) } else { try await bridge.openPath(source.value) }
        } catch { self.error = Self.message(error, or: "Could not open source.") }
    }

    private static func message(_ error: Error, or fallback: String) -> String {
        let text = messageOf(error)
        return text.isEmpty ? fallback : text
    }

    // MARK: - The focus timer

    /// The typed duration, read the way `Number(input.value)` reads it.
    var minutes: Double { Self.number(minutesText) }
    var canStart: Bool { minutes >= 1 && minutes <= 1440 && !label.jsTrimmed.isEmpty }
    /// What the idle clock shows.
    var idleMs: Double { (minutes.isFinite ? minutes : 0) * 60000 }

    func choose(preset: Int) { minutesText = String(preset) }
    func isChosen(preset: Int) -> Bool { minutes == Double(preset) }

    func startTimer() async {
        guard canStart else { return }
        await act(["op": "timer", "action": "start", "minutes": .number(minutes), "label": .string(label)])
    }

    /// The timer's main button: pause while it runs, resume when paused, finish once it rings.
    static func timerAction(_ timer: BrainTimer) -> String { timer.status == "running" ? "pause" : timer.status == "paused" ? "resume" : "cancel" }
    static func timerButton(_ timer: BrainTimer) -> String { timer.status == "running" ? "Pause" : timer.status == "paused" ? "Resume" : "Finish" }
    static func timerLine(_ timer: BrainTimer) -> String {
        timer.status == "ringing" ? "Time’s up. Take a breath." : timer.status == "paused" ? "Paused · pick up when you’re ready" : "On Merry’s screen until it’s done"
    }
    /// on | paused | ringing
    static func timerTone(_ timer: BrainTimer) -> String { timer.status == "running" ? "on" : timer.status }
    static func timerProgress(_ timer: BrainTimer, now: Double) -> Double {
        timer.durationMs > 0 ? min(1, max(0, 1 - timer.remaining(now: now) / timer.durationMs)) : 0
    }
    /// The clock as its dots spell it: "24:59", or "1h05" past an hour.
    static func timerText(_ timer: BrainTimer, now: Double) -> String { DotText.clock(timer.remaining(now: now)) }

    func timerAct(_ timer: BrainTimer) async { await act(["op": "timer", "action": .string(Self.timerAction(timer))]) }
    func cancelTimer() async { await act(["op": "timer", "action": "cancel"]) }

    // MARK: - The editor

    /// A fresh draft of the section's kind. One already being written is left as it is.
    func beginNew() {
        if let editing, editing.id == nil { return }
        editing = BrainDraft(id: nil, kind: tab == .today || tab == .archive ? "note" : tab.rawValue, projectId: project.isEmpty ? nil : project)
    }

    func beginEdit(_ i: BrainItem) {
        if editing?.id == i.id { return }
        editing = BrainDraft(id: i.id, kind: i.kind, title: i.title, body: i.body, projectId: i.projectId, repeats: i.repeat,
                             estimate: i.estimateMinutes.map(String.init) ?? "", sources: i.sources, due: Self.localTime(i.dueAt))
    }

    func cancelEdit() { editing = nil }

    var canSave: Bool {
        guard let editing else { return false }
        return !editing.busy && !editing.title.jsTrimmed.isEmpty
    }

    func bodyPlaceholder(_ kind: String) -> String {
        kind == "session" ? "Where you left off. What comes next." : "Notes, details, or a next step…"
    }

    func removeSource(at index: Int) {
        guard let sources = editing?.sources, sources.indices.contains(index) else { return }
        editing?.sources.remove(at: index)
    }

    func addFiles() async {
        let paths = await bridge.choosePaths()
        editing?.sources += paths.map { BrainSource(kind: "path", label: $0.jsSplit("/").last ?? "", value: $0) }
    }

    /// The fields of a draft as the store takes them. Throws what the editor shows.
    static func fields(_ draft: BrainDraft) throws -> JSON {
        var sources = draft.sources
        if !draft.url.jsTrimmed.isEmpty { sources.append(try linkSource(draft.url)) }
        var dueAt: Double?
        if !draft.due.isEmpty {
            guard let date = JSDate(iso: draft.due), date.time.isFinite else { throw MerryError("Choose a valid date and time.") }
            dueAt = date.time
        }
        return [
            "kind": .string(draft.kind),
            "title": .string(draft.title),
            "body": .string(draft.body),
            "sources": .array(sources.map { ["kind": .string($0.kind), "label": .string($0.label), "value": .string($0.value)] }),
            "projectId": draft.kind == "project" ? .null : JSON(draft.projectId),
            "dueAt": JSON(dueAt),
            "repeat": .string(draft.repeats),
            "estimateMinutes": JSON(estimate(draft.estimate))
        ]
    }

    static func request(_ draft: BrainDraft) throws -> JSON {
        let item = try fields(draft)
        if let id = draft.id { return ["op": "update", "id": .string(id), "changes": item] }
        return ["op": "create", "item": item]
    }

    func save() async {
        guard let draft = editing, canSave else { return }
        editing?.busy = true
        editing?.error = ""
        do {
            _ = try await bridge.brainRequest(try Self.request(draft))
            editing = nil
        } catch {
            guard editing?.id == draft.id else { return }
            editing?.error = Self.message(error, or: "Could not save.")
            editing?.busy = false
        }
    }

    /// A typed link as a source: its host for a label, its normal form for a value.
    static func linkSource(_ text: String) throws -> BrainSource {
        let trimmed = text.jsTrimmed
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(), !scheme.isEmpty else {
            throw MerryError("Please enter a URL.")
        }
        guard scheme == "http" || scheme == "https" else { throw MerryError("Use an http or https link.") }
        guard let host = parts.host?.lowercased(), !host.isEmpty, let href = try? externalWebUrl(trimmed) else {
            throw MerryError("Please enter a URL.")
        }
        return BrainSource(kind: "url", label: host, value: href)
    }

    private static func estimate(_ text: String) -> Double? {
        let trimmed = text.jsTrimmed
        guard !trimmed.isEmpty else { return nil }
        let value = number(trimmed)
        return value.isNaN ? nil : value
    }

    /// `Number(text)` for what a number field can hold.
    static func number(_ text: String) -> Double {
        let trimmed = text.jsTrimmed
        if trimmed.isEmpty { return 0 }
        guard Rx("^[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?$").test(trimmed) else { return .nan }
        return Double(trimmed) ?? .nan
    }

    // MARK: - Dates

    /// A moment as the editor's date field holds it: `yyyy-MM-ddTHH:mm`, local time.
    static func localTime(_ ms: Double?) -> String {
        guard let ms, ms != 0 else { return "" }
        return JSDate(ms).format("yyyy-MM-dd'T'HH:mm")
    }

    /// What the editor's date field holds, as a moment. nil for empty or unreadable text.
    static func parseLocalTime(_ text: String) -> Double? { text.isEmpty ? nil : JSDate(iso: text)?.time }

    /// Times near now read as a person would say them; the rest as a date.
    static func dateLabel(_ ms: Double, now: Double) -> String {
        let time = format(ms, "jmm")
        let days = ((startOfDay(ms) - startOfDay(now)) / 86_400_000).rounded()
        if days == 0 { return "Today \(time)" }
        if days == 1 { return "Tomorrow \(time)" }
        if days == -1 { return "Yesterday \(time)" }
        // Joined by hand: asked for both at once, Foundation writes "Oct 3 at 10:00 AM".
        return "\(format(ms, "MMMd")), \(time)"
    }

    private static var formatters: [String: DateFormatter] = [:]

    /// A moment in the reader's locale and `LocalTime`'s zone, from a format skeleton.
    static func format(_ ms: Double, _ skeleton: String) -> String {
        let zone = LocalTime.calendar.timeZone
        let key = "\(skeleton)|\(locale.identifier)|\(zone.identifier)"
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate(skeleton)
            formatters[key] = formatter
        }
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// The workspace as the rest of the app last reported it: what is kept, and
/// the timer. Loads once, then follows every change.
@MainActor
public final class BrainFeed: ObservableObject {
    @Published public private(set) var state = BrainSnapshot()
    private var changed = false
    private var subscription: AnyCancellable?

    public init(bridge: MerryBridge) {
        subscription = bridge.events.brainChanged.sink { [weak self] snapshot in
            self?.changed = true
            self?.state = snapshot
        }
        Task { [weak self, bridge] in
            let snapshot = await bridge.getBrain()
            // A change that arrived while loading is newer than what was loaded.
            if let self, !self.changed { self.state = snapshot }
        }
    }
}

/// The time, once a second, for as long as something is watching it.
@MainActor
public final class BrainClock: ObservableObject {
    @Published public private(set) var now: Double
    private let fixed: Bool
    private var watchers = 0
    private var timer: Timer?

    public init() {
        now = nowMs()
        fixed = false
    }

    /// A clock stopped at one moment, for previews and tests.
    public init(fixed now: Double) {
        self.now = now
        fixed = true
    }

    public var isTicking: Bool { timer != nil }

    public func start() {
        watchers += 1
        guard !fixed, timer == nil else { return }
        now = nowMs()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.now = nowMs()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

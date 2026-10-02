import Testing
import MerryCore
@testable import MerryUI

@MainActor @Suite(.serialized) struct BrainModelTests {
    let bridge = PreviewBridge()
    let now: Double

    init() {
        BrainSupport.pin()
        now = BrainSamples.now
    }

    private func model(_ given: BrainSnapshot? = nil) -> BrainModel {
        let state = given ?? BrainSamples.everything
        bridge.brain = state
        return BrainModel(bridge: bridge, state: state)
    }

    private func item(_ id: String) -> BrainItem { BrainSamples.everything.items.first { $0.id == id }! }

    // MARK: - Against the reference's own rendering

    @Test func thePageShowsWhatTheOriginalShows() {
        for page in Fixture.load("brain-page").list("pages") {
            let name = page.str("name"), now = page.num("now"), want = page["page"]!
            let state = BrainSupport.snapshot(page["state"]!)
            let m = model(state)

            #expect(m.due(now: now).map(\.id) == page.strings("due"), "due: \(name)")
            #expect(m.headerDate(now: now) + (m.openCount > 0 ? " | \(m.openCount) open" : "") == want.str("date"), "date: \(name)")
            #expect((m.dueNotice(now: now) ?? "") == want.str("due"), "notice: \(name)")
            #expect(!state.items.isEmpty == want.flag("hasBar"), "bar: \(name)")
            if want.flag("hasBar") {
                let tabs = m.sections(now: now).map { "\($0.name)/\($0.count)/\(m.isSelected($0.tab))" }
                #expect(tabs == want.list("tabs").map { "\($0.str("name"))/\($0.int("n"))/\($0.flag("pressed"))" }, "tabs: \(name)")
            }

            let groups = m.groups(now: now)
            #expect(groups.map(\.label) == want.list("groups").map { $0.str("label") }, "groups: \(name)")
            for (group, wantGroup) in zip(groups, want.list("groups")) {
                #expect(group.items.count == wantGroup.int("count"))
                #expect(group.items.map(\.title) == wantGroup.list("rows").map { $0.str("title") }, "order in \(group.label): \(name)")
                for (i, row) in zip(group.items, wantGroup.list("rows")) {
                    let where_ = "\(i.title): \(name)"
                    #expect(i.kind == row.str("kind"))
                    #expect((i.status == "done") == row.flag("done"), "done \(where_)")
                    #expect(m.isOverdue(i, now: now) == row.flag("overdue"), "overdue \(where_)")
                    #expect((m.isCheckable(i) ? m.checkLabel(i) : "") == row.str("check"), "check \(where_)")
                    #expect((m.mixed ? m.kindLabel(i) : "") == row.str("kindLabel"))
                    #expect(m.archiveLabel(i) == row.str("archive"))
                    #expect(i.body == row.str("body"))
                    // Which kind of space sits before AM is the formatter's business, not the page's.
                    let thin: (String) -> String = { $0.replacingOccurrences(of: "\u{202F}", with: " ") }
                    #expect([m.dueText(i, now: now), m.projectName(i), m.estimateText(i)].compactMap { $0 }.map(thin) == row.strings("meta").map(thin), "meta \(where_)")
                    #expect((i.dueAt != nil && m.isOverdue(i, now: now)) == row.flag("warn"))
                    #expect(i.sources.map { "\(m.sourceLabel($0))|\($0.value)" } == row.list("sources").map { "\($0.str("label"))|\($0.str("title"))" })
                    let days = i.kind == "tracker" ? m.days(i, now: now).map { "\($0.key) \($0.letter) \($0.checked) \($0.isToday)" } : []
                    #expect(days == row.list("days").map { "\($0.str("key")) \($0.str("letter")) \($0.flag("checked")) \($0.flag("today"))" }, "days \(where_)")
                    if let check = row["checkIn"], !check.isNull {
                        #expect(m.doneToday(i, now: now) == check.flag("pressed"))
                        #expect(m.checkInLabel(i, now: now) == check.str("label"))
                    }
                    #expect(m.more(i, now: now).map(\.label) == row.strings("more"), "more \(where_)")
                }
            }

            if let empty = want["empty"], !empty.isNull {
                #expect(m.showsEmpty(now: now), "empty: \(name)")
                #expect(m.emptyTitle == empty.str("title"))
                #expect(m.emptyDetail == empty.str("detail"))
                #expect(m.starters.map(\.label) == empty.strings("starters"))
            } else {
                #expect(!m.showsEmpty(now: now), "not empty: \(name)")
            }

            let focus = want["focus"]!
            if let timer = state.timer {
                #expect(timer.status == focus.str("status"))
                #expect(BrainModel.timerTone(timer) == focus.str("tone"))
                #expect(BrainModel.timerText(timer, now: now) == focus.str("clock"), "clock: \(name)")
                #expect(abs(BrainModel.timerProgress(timer, now: now) - focus.num("progress")) < 1e-9, "progress: \(name)")
                #expect(timer.label == focus.str("label"))
                #expect(BrainModel.timerLine(timer) == focus.str("line"))
                #expect(BrainModel.timerButton(timer) == focus.str("button"))
                #expect((timer.status != "ringing") == focus.flag("cancel"))
            } else {
                #expect(focus.str("status") == "idle" && focus.str("tone") == "idle")
                #expect(DotText.clock(m.idleMs) == focus.str("clock"))
            }
        }
    }

    @Test func timerTextAndDayKeysMatch() {
        let fixture = Fixture.load("brain-page")
        for row in fixture.list("timers") {
            let timer = BrainSupport.timer(row["timer"]!), now = row.num("now")
            #expect(timer.remaining(now: now) == row.num("remaining"))
            #expect(timer.label(now: now) == row.str("label"))
            #expect(BrainModel.timerText(timer, now: now) == row.str("clock"))
        }
        for row in fixture.list("days") { #expect(dayKey(row.num("ms")) == row.str("key")) }
    }

    // MARK: - Sections, filters and groups

    @Test func eachSectionListsItsOwnKind() {
        let m = model()
        m.select(.reminder)
        #expect(m.groups(now: now).map(\.label) == ["Overdue", ""])
        #expect(m.groups(now: now).map { $0.items.map(\.id) } == [["r1"], ["r3", "r4", "r5"]])
        m.select(.task)
        #expect(m.groups(now: now).map(\.label) == ["", "Done"])
        #expect(m.groups(now: now).map { $0.items.map(\.id) } == [["t2", "t1", "t3"], ["t4"]])
        m.select(.archive)
        #expect(m.mixed)
        #expect(m.groups(now: now).map { $0.items.map(\.id) } == [["a1"]])
        #expect(m.archiveLabel(m.visible(now: now)[0]) == "Restore")
        m.select(.session)
        #expect(m.more(m.visible(now: now)[0], now: now) == [.resume])
        #expect(m.prompt(.resume, item("s1")) == "Help me resume the saved Merry session \"Workspace port, day two\" (id s1). Show its next steps and saved sources.")
        #expect(m.prompt(.saveSession, item("p1")) == "Save where I am with project \"Merry native port\". My next step is ")
    }

    @Test func searchAndProjectNarrowTheList() {
        let m = model()
        m.query = "  PORT "
        #expect(m.searching && m.mixed && !m.isSelected(.today))
        #expect(m.groups(now: now).map(\.label) == [""])
        // Open things first, soonest first; "File the expense report" is done, so it comes last.
        #expect(m.visible(now: now).map(\.id) == ["r5", "p1", "t1", "s1", "t4"])
        m.query = "brainview.swift"
        #expect(m.visible(now: now).map(\.id) == ["s1"])
        m.query = "zzz"
        #expect(m.showsEmpty(now: now) && m.emptyTitle == "Nothing matched that." && m.emptyDetail == "Try a title, a phrase, or another project." && m.starters.isEmpty)
        #expect(m.emptyMood == .curious)
        #expect(m.clearSearch() && m.query.isEmpty && !m.clearSearch())

        m.viewProject(item("p1"))
        #expect(m.tab == .today && m.project == "p1")
        #expect(m.visible(now: now).map(\.id) == ["t2", "t1"])
        m.select(.project)
        #expect(m.visible(now: now).map(\.id) == ["p1"])
        m.review()
        #expect(m.tab == .today && m.project.isEmpty && m.query.isEmpty)
    }

    @Test func emptySectionsOfferSomethingToSay() {
        let m = model(BrainSnapshot(items: [BrainSamples.item("n", "note", "Only a note")]))
        m.select(.tracker)
        #expect(m.sections(now: now).map(\.tab) == [.today, .note, .tracker])
        #expect(m.emptyTitle == "Nothing here yet." && m.starters.map(\.prompt) == ["Track reading daily"])
        m.select(.archive)
        #expect(m.emptyTitle == "Nothing archived." && m.emptyDetail == "Archived things wait here until you need them again." && m.starters.isEmpty)
        m.select(.today)
        #expect(m.starters.map(\.prompt) == ["Remind me to ", "Add a task: ", "Track reading daily"])
        m.select(.note)
        // With nothing kept there are no sections to pick from.
        m.state = BrainSnapshot()
        #expect(m.tab == .today)
    }

    @Test func dueMeansOpenPastItsTimeAndNotAcknowledged() {
        let s = BrainSamples.self
        let m = model(BrainSnapshot(items: [
            s.item("a", "reminder", "Past", dueAt: now - 1),
            s.item("b", "reminder", "Exactly now", dueAt: now),
            s.item("c", "reminder", "Soon", dueAt: now + 1),
            s.item("d", "reminder", "Seen", dueAt: now - 5, acknowledgedAt: now - 4),
            s.item("e", "task", "Done", dueAt: now - 9, status: "done"),
            s.item("f", "task", "Oldest", dueAt: now - 99)
        ]))
        #expect(m.due(now: now).map(\.id) == ["f", "a", "b"])
        #expect(m.dueNotice(now: now) == "3 reminders waiting")
        #expect(m.more(m.state.items[3], now: now) == [.snooze])
        #expect(m.more(m.state.items[0], now: now) == [.snooze, .dismiss])
        #expect(!m.isOverdue(m.state.items[4], now: now))
        m.state = BrainSnapshot(items: [m.state.items[0]])
        #expect(m.dueNotice(now: now) == "1 reminder waiting")
        #expect(m.dueNotice(now: now - 2) == nil)
    }

    // MARK: - Requests

    @Test func rowActionsSendTheOriginalsRequests() async {
        let m = model()
        await m.toggleDone(item("t1"))
        #expect(bridge.brainRequests.last == ["op": "complete", "id": "t1"])
        await m.toggleDone(item("t4"))
        #expect(bridge.brainRequests.last == ["op": "reopen", "id": "t4"])
        await m.toggleArchive(item("n1"))
        #expect(bridge.brainRequests.last == ["op": "archive", "id": "n1"])
        await m.toggleArchive(item("a1"))
        #expect(bridge.brainRequests.last == ["op": "reopen", "id": "a1"])
        await m.checkIn(item("k1"))
        #expect(bridge.brainRequests.last == ["op": "check", "id": "k1"])
        await m.snooze(item("r1"))
        #expect(bridge.brainRequests.last == ["op": "snooze", "id": "r1", "minutes": 10])
        await m.acknowledge(item("r1"))
        #expect(bridge.brainRequests.last == ["op": "acknowledge", "id": "r1"])
        #expect(bridge.brainRequests.count == 7 && !m.busy && m.error.isEmpty)
        for request in bridge.brainRequests { #expect((try? BrainSchema.request.parse(request)) != nil, "\(request)") }
    }

    @Test func theTimerSendsTheOriginalsRequests() async {
        let m = model(BrainSnapshot())
        #expect(m.canStart && m.minutes == 25 && m.isChosen(preset: 25) && m.idleMs == 1_500_000)
        await m.startTimer()
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "start", "minutes": 25, "label": "Focus time"])
        m.choose(preset: 50)
        m.label = " Write "
        await m.startTimer()
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "start", "minutes": 50, "label": " Write "])
        m.minutesText = "7.5"
        #expect(!m.isChosen(preset: 50))
        await m.startTimer()
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "start", "minutes": 7.5, "label": " Write "])
        for request in bridge.brainRequests { #expect((try? BrainSchema.request.parse(request)) != nil) }

        // Out of range, or with no label, Start does nothing.
        for (text, label) in [("0", "x"), ("", "x"), ("1441", "x"), ("0.5", "x"), ("25", "   ")] {
            m.minutesText = text
            m.label = label
            #expect(!m.canStart, "\(text) \(label)")
            await m.startTimer()
        }
        #expect(bridge.brainRequests.count == 3)
        m.minutesText = ""
        #expect(m.idleMs == 0)

        await m.timerAct(BrainSamples.timer("running", endsAt: now + 1000))
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "pause"])
        await m.timerAct(BrainSamples.timer("paused"))
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "resume"])
        await m.timerAct(BrainSamples.timer("ringing"))
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "cancel"])
        await m.cancelTimer()
        #expect(bridge.brainRequests.last == ["op": "timer", "action": "cancel"])
        #expect(bridge.brainRequests.count == 7)
    }

    @Test func timerTextFollowsTheClock() {
        let running = BrainSamples.timer("running", endsAt: now + 17 * 60000 + 42000)
        #expect(BrainModel.timerText(running, now: now) == "17:42")
        #expect(BrainModel.timerText(running, now: now + 1) == "17:42")
        #expect(BrainModel.timerText(running, now: now + 1000) == "17:41")
        #expect(BrainModel.timerText(running, now: now + 3_600_000) == "00:00")
        #expect(BrainModel.timerText(BrainSamples.timer("paused", remainingMs: 61_001), now: now) == "01:02")
        #expect(BrainModel.timerText(BrainSamples.timer("ringing", remainingMs: 5000), now: now) == "00:00")
        var long = BrainSamples.timer("paused", remainingMs: 3_900_000)
        long.durationMs = 2 * 3_600_000
        #expect(BrainModel.timerText(long, now: now) == "1h05")
        #expect(BrainModel.timerProgress(long, now: now) == 1 - 3_900_000.0 / 7_200_000.0)
        #expect(BrainModel.timerLine(running) == "On Merry’s screen until it’s done")
        #expect(BrainModel.timerLine(long) == "Paused · pick up when you’re ready")
    }

    // MARK: - The editor

    @Test func aNewReminderIsCreatedWithItsLocalTime() async {
        let m = model()
        m.select(.reminder)
        m.project = "p1"
        m.beginNew()
        #expect(m.editing == BrainDraft(id: nil, kind: "reminder", projectId: "p1"))
        #expect(!m.canSave)
        m.editing?.title = " Pay rent "
        m.editing?.due = "2026-10-03T10:00"
        m.editing?.repeats = "weekly"
        m.editing?.url = " https://Example.com/pay?x=1 "
        // Pressing New again leaves what is being written alone.
        m.beginNew()
        #expect(m.editing?.title == " Pay rent " && m.canSave)
        await m.save()
        let due = BrainSamples.at(10, 0, day: 1)
        #expect(BrainSupport.isoUTC(due) == "2026-10-03T04:30:00.000Z")
        #expect(bridge.brainRequests.last == ["op": "create", "item": [
            "kind": "reminder", "title": " Pay rent ", "body": "",
            "sources": [["kind": "url", "label": "example.com", "value": "https://example.com/pay?x=1"]],
            "projectId": "p1", "dueAt": .number(due), "repeat": "weekly", "estimateMinutes": nil
        ]])
        #expect((try? BrainSchema.request.parse(bridge.brainRequests.last!)) != nil)
        #expect(m.editing == nil)
    }

    @Test func anExistingItemIsUpdatedWithAllItsFields() async {
        let m = model()
        m.beginEdit(item("t1"))
        #expect(m.editing?.estimate == "50" && m.editing?.sources.count == 2 && m.editing?.due == "")
        m.editing?.title = "Port the page"
        m.editing?.estimate = "45"
        m.removeSource(at: 0)
        bridge.pickedPaths = ["/Users/k/notes/plan.md", "/tmp/a b.txt"]
        await m.addFiles()
        // Editing the same row again keeps the draft; another row replaces it.
        m.beginEdit(item("t1"))
        #expect(m.editing?.title == "Port the page")
        await m.save()
        #expect(bridge.brainRequests.last == ["op": "update", "id": "t1", "changes": [
            "kind": "task", "title": "Port the page", "body": "Timer card, list, editor, tests.",
            "sources": [
                ["kind": "path", "label": "Brain.tsx", "value": "/Users/k/Developer/merry/src/renderer/src/components/Brain.tsx"],
                ["kind": "path", "label": "plan.md", "value": "/Users/k/notes/plan.md"],
                ["kind": "path", "label": "a b.txt", "value": "/tmp/a b.txt"]
            ],
            "projectId": "p1", "dueAt": nil, "repeat": "none", "estimateMinutes": 45
        ]])
        #expect((try? BrainSchema.request.parse(bridge.brainRequests.last!)) != nil)

        // A project has no project of its own, whatever the draft held.
        m.beginEdit(item("t2"))
        m.editing?.kind = "project"
        await m.save()
        #expect(bridge.brainRequests.last?["changes"]?["projectId"] == .null)
        #expect(bridge.brainRequests.last?["changes"]?["dueAt"] == .number(BrainSamples.at(18, 15)))

        m.beginEdit(item("n1"))
        m.select(.task)
        #expect(m.editing == nil)
        m.select(.archive)
        m.beginNew()
        #expect(m.editing?.kind == "note" && m.editing?.projectId == nil)
        m.cancelEdit()
        #expect(m.editing == nil)
    }

    @Test func datesRoundTripInLocalTime() {
        #expect(BrainModel.localTime(nil) == "" && BrainModel.localTime(0) == "")
        for (text, utc) in [("2026-10-02T14:30", "2026-10-02T09:00:00.000Z"), ("2026-01-01T00:00", "2025-12-31T18:30:00.000Z"),
                            ("2024-02-29T23:59", "2024-02-29T18:29:00.000Z"), ("2026-12-31T05:29", "2026-12-30T23:59:00.000Z")] {
            let ms = BrainModel.parseLocalTime(text)
            #expect(ms.map(BrainSupport.isoUTC) == utc, "\(text)")
            #expect(BrainModel.localTime(ms) == text)
        }
        // Seconds are dropped going out, as the field has none.
        #expect(BrainModel.localTime(BrainSamples.at(9, 5) + 59_999) == "2026-10-02T09:05")
        #expect(BrainModel.parseLocalTime("") == nil && BrainModel.parseLocalTime("tomorrow") == nil)

        #expect(BrainModel.dateLabel(BrainSamples.at(9, 5), now: now) == "Today 9:05\u{202F}AM")
        #expect(BrainModel.dateLabel(BrainSamples.at(0, 0, day: 1), now: now) == "Tomorrow 12:00\u{202F}AM")
        #expect(BrainModel.dateLabel(BrainSamples.at(23, 59, day: -1), now: now) == "Yesterday 11:59\u{202F}PM")
        #expect(BrainModel.dateLabel(BrainSamples.at(8, 0, day: 2), now: now) == "Oct 4, 8:00\u{202F}AM")
    }

    @Test func theEditorSaysWhatIsWrong() async {
        let m = model()
        m.beginNew()
        m.editing?.title = "Link"
        m.editing?.url = "ftp://example.com/file"
        await m.save()
        #expect(m.editing?.error == "Use an http or https link." && m.editing?.busy == false)
        m.editing?.url = "not a link"
        await m.save()
        #expect(m.editing?.error == "Please enter a URL.")
        m.editing?.url = ""
        m.editing?.due = "2026-13-45T99:99x"
        await m.save()
        #expect(m.editing?.error == "Choose a valid date and time.")
        #expect(bridge.brainRequests.isEmpty)

        // What the store refuses is shown in the editor, which stays open.
        m.editing?.due = ""
        m.editing?.repeats = "daily"
        bridge.failure = "A repeating reminder needs a due time."
        await m.save()
        #expect(m.editing?.error == "A repeating reminder needs a due time." && m.editing?.busy == false && m.error.isEmpty)
        await m.save()
        #expect(m.editing == nil && bridge.brainRequests.count == 2)

        m.beginNew()
        m.editing?.title = "   "
        await m.save()
        #expect(m.editing != nil && bridge.brainRequests.count == 2)
    }

    // MARK: - Errors and sources

    @Test func failuresAreShownAndClearedByTheNextAction() async {
        let m = model()
        bridge.failure = "This item no longer exists."
        await m.toggleDone(item("t1"))
        #expect(m.error == "This item no longer exists." && !m.busy)
        await m.toggleDone(item("t1"))
        #expect(m.error.isEmpty)
        bridge.failure = "Finish or cancel the current timer first."
        await m.startTimer()
        #expect(m.error == "Finish or cancel the current timer first.")
    }

    @Test func sourcesOpenThroughTheBridge() async {
        let m = model()
        await m.open(BrainSource(kind: "url", label: "github.com", value: "https://github.com/kalki-kgp/merry"))
        await m.open(BrainSource(kind: "path", label: "", value: "/Users/k/a.pdf"))
        #expect(bridge.opened == ["https://github.com/kalki-kgp/merry", "/Users/k/a.pdf"])
        #expect(Array(bridge.calls.suffix(2)) == ["openUrl", "openPath"])
        bridge.failure = "Only HTTP and HTTPS links can be opened."
        await m.open(BrainSource(kind: "url", label: "x", value: "file:///etc/passwd"))
        #expect(m.error == "Only HTTP and HTTPS links can be opened.")
    }

    // MARK: - The clock and the feed

    @Test func theClockTicksOnlyWhileWatched() {
        let clock = BrainClock()
        #expect(!clock.isTicking)
        clock.start(); clock.start()
        #expect(clock.isTicking)
        clock.stop()
        #expect(clock.isTicking)
        clock.stop()
        #expect(!clock.isTicking)
        let fixed = BrainClock(fixed: 42)
        fixed.start()
        #expect(!fixed.isTicking && fixed.now == 42)
    }

    @Test func theFeedLoadsThenFollowsChanges() async {
        bridge.brain = BrainSamples.everything
        let feed = BrainFeed(bridge: bridge)
        await BrainSupport.settle()
        #expect(feed.state == BrainSamples.everything)
        bridge.events.brainChanged.send(BrainSnapshot())
        #expect(feed.state == BrainSnapshot())
    }
}

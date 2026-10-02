import Testing
import MerryCore
@testable import MerryUI

@MainActor
private final class Clock {
    var now: Double = 1_800_000_000_000
}

@MainActor
private func make(_ setup: (PreviewBridge) -> Void = { _ in }) -> (PanelModel, PreviewBridge, Clock) {
    let bridge = PanelPreview.bridge()
    setup(bridge)
    let clock = Clock()
    return (PanelModel(bridge: bridge, now: { clock.now }), bridge, clock)
}

/// Lets the model's unstructured follow-up work (history refreshes, answers) land.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func turn(_ id: String, _ request: String = "do it", status: TaskStatus = .succeeded, replyTo: String? = nil, updatedAt: Double = 1_800_000_000_000) -> TaskState {
    var task = TaskState(id: id, request: request, now: updatedAt)
    task.status = status
    task.replyTo = replyTo
    return task
}

private func question(free: Bool, options: [QuestionOption]? = nil) -> UserQuestion {
    UserQuestion(id: "q", reason: .ambiguous, prompt: "Which one?", options: options, allowFreeText: free)
}

@MainActor
@Suite struct PanelModelTests {
    // MARK: Threading

    @Test func aReplyPushesTheTurnOnScreenIntoTheChat() {
        let (model, _, _) = make()
        model.receive(turn("a"))
        #expect(model.task?.id == "a" && model.thread.isEmpty)
        model.receive(turn("b", replyTo: "a"))
        #expect(model.task?.id == "b" && model.thread.map(\.id) == ["a"])
        model.receive(turn("c", replyTo: "b"))
        #expect(model.thread.map(\.id) == ["a", "b"])
    }

    @Test func anyOtherNewTurnIsANewChat() {
        let (model, _, _) = make()
        model.receive(turn("a"))
        model.receive(turn("b", replyTo: "a"))
        model.receive(turn("x"))
        #expect(model.task?.id == "x" && model.thread.isEmpty)
        // Replying to something that is not on screen is a new chat too.
        model.receive(turn("y", replyTo: "a"))
        #expect(model.task?.id == "y" && model.thread.isEmpty)
    }

    @Test func aLateUpdateForAnEarlierTurnRefreshesItInPlace() {
        let (model, _, _) = make()
        model.receive(turn("a"))
        model.receive(turn("b", replyTo: "a"))
        var late = turn("a")
        late.statusLine = "refreshed"
        model.receive(late)
        #expect(model.task?.id == "b")
        #expect(model.thread.map(\.statusLine) == ["refreshed"])
    }

    @Test func anOlderUpdateOfTheSameTurnIsIgnored() {
        let (model, _, _) = make()
        var fresh = turn("a", status: .executing, updatedAt: 2_000)
        fresh.statusLine = "fresh"
        model.receive(fresh)
        var stale = turn("a", status: .pending, updatedAt: 1_000)
        stale.statusLine = "stale"
        model.receive(stale)
        #expect(model.task?.statusLine == "fresh")
        var newer = turn("a", status: .succeeded, updatedAt: 3_000)
        newer.statusLine = "newer"
        model.receive(newer)
        #expect(model.task?.statusLine == "newer")
    }

    @Test func aChatKeepsEightEarlierTurns() {
        let (model, _, _) = make()
        #expect(PanelModel.maxTurns == 8)
        model.receive(turn("t0"))
        for i in 1...11 { model.receive(turn("t\(i)", replyTo: "t\(i - 1)")) }
        #expect(model.task?.id == "t11")
        #expect(model.thread.map(\.id) == (3...10).map { "t\($0)" })
    }

    @Test func aFinishedTurnRefreshesHistory() async {
        let (model, bridge, clock) = make()
        bridge.history = [PanelPreview.row("a", "do it", createdAt: clock.now)]
        model.receive(turn("a", status: .executing))
        await settle()
        #expect(model.history.isEmpty)
        model.receive(turn("a", status: .succeeded, updatedAt: clock.now + 1))
        await settle()
        #expect(model.history.map(\.id) == ["a"])
    }

    // MARK: Sending

    @Test func theLauncherStartsANewChatAndTheReplyBoxContinuesOne() async throws {
        let (model, bridge, _) = make()
        model.dropped = ["/tmp/a.pdf"]
        model.aside = "old"
        model.view = .help
        try await model.send("Sort these", withFront: true, followUp: nil)
        #expect(bridge.started.count == 1)
        #expect(bridge.started[0].request == "Sort these")
        #expect(bridge.started[0].droppedPaths == ["/tmp/a.pdf"])
        #expect(bridge.started[0].includeFrontWindow)
        #expect(bridge.started[0].followUp == .newChat)
        #expect(model.dropped.isEmpty && model.aside == nil && model.view == .home && model.seed == nil)
        #expect(model.task?.request == "Sort these")

        var done = model.task!
        done.status = .succeeded
        done.updatedAt += 1
        model.receive(done)
        try await model.send("And the rest", withFront: false, followUp: done.id)
        #expect(bridge.started[1].followUp == .reply(done.id))
        #expect(model.thread.map(\.id) == [done.id])
        #expect(model.task?.request == "And the rest")
    }

    @Test func aFreeTextQuestionIsAnsweredInsteadOfStartingATask() async throws {
        let (model, bridge, _) = make()
        var waiting = turn("a", status: .awaitingUser)
        waiting.question = question(free: true)
        model.task = waiting
        model.view = .steps
        try await model.send("the blue one", withFront: false, followUp: "a")
        #expect(bridge.started.isEmpty)
        #expect(bridge.answers.count == 1)
        #expect(bridge.answers[0].questionId == "q" && bridge.answers[0].optionId == nil && bridge.answers[0].text == "the blue one")
        #expect(model.view == .home)
    }

    @Test func aRunningTaskRefusesANewRequest() async {
        let (model, bridge, _) = make()
        model.task = turn("a", status: .executing)
        await #expect(throws: MerryError.self) { try await model.send("another", withFront: false, followUp: nil) }
        do { try await model.send("another", withFront: false, followUp: nil) } catch {
            #expect(messageOf(error) == "Finish or stop the current task first.")
        }
        #expect(bridge.started.isEmpty)
        // A question that only takes options is still a running task.
        var waiting = turn("a", status: .awaitingUser)
        waiting.question = question(free: false)
        model.task = waiting
        await #expect(throws: MerryError.self) { try await model.send("another", withFront: false, followUp: nil) }
        #expect(bridge.answers.isEmpty)
    }

    @Test func aFailedSendKeepsTheAttachments() async {
        let (model, bridge, _) = make()
        model.dropped = ["/tmp/a.pdf", "/tmp/b.pdf"]
        bridge.failure = "The model is offline."
        do {
            try await model.send("Sort these", withFront: false, followUp: nil)
            Issue.record("the send should have failed")
        } catch { #expect(messageOf(error) == "The model is offline.") }
        #expect(model.dropped == ["/tmp/a.pdf", "/tmp/b.pdf"])
        #expect(model.task == nil)
        // And the lock is released: the next try goes through.
        try? await model.send("Sort these", withFront: false, followUp: nil)
        #expect(bridge.started.count == 1 && model.dropped.isEmpty)
    }

    @Test func retryDropsTheClarificationsAndKeepsTheThread() async {
        let (model, bridge, _) = make()
        model.task = turn("b", "Book a table\n\nClarification: for four", status: .failed, replyTo: "a")
        await model.retry()
        #expect(bridge.started.map(\.request) == ["Book a table"])
        #expect(bridge.started[0].followUp == .reply("a"))
        model.task = turn("c", "Find it", status: .cancelled)
        await model.retry()
        #expect(bridge.started[1].followUp == .newChat)
    }

    @Test func digitsPickNumberedOptions() async {
        let (model, bridge, _) = make()
        #expect(!model.answerNumber(1))
        var waiting = turn("a", status: .awaitingUser)
        waiting.question = question(free: false, options: [QuestionOption(id: "x", label: "X"), QuestionOption(id: "y", label: "Y")])
        model.task = waiting
        #expect(model.numberOption(2)?.id == "y")
        #expect(model.numberOption(3) == nil && !model.answerNumber(3))
        #expect(model.answerNumber(2))
        await settle()
        #expect(bridge.answers.map(\.optionId) == ["y"])
        // Away from the chat, a digit is just a digit.
        model.view = .help
        #expect(!model.answerNumber(1))
        // A question without options offers one: go ahead.
        model.view = .home
        waiting.question = question(free: false)
        model.task = waiting
        #expect(model.numberOption(1)?.id == "ok" && model.numberOption(2) == nil)
    }

    // MARK: Commands

    @Test func everyCommandDoesItsJob() async {
        let (model, bridge, _) = make()
        #expect(PanelCommand.all.map(\.name) == ["new", "workspace", "undo", "steps", "past", "stop", "center", "keys", "tune", "setup", "bench", "help"])

        model.aside = "old"
        await model.command("workspace")
        #expect(model.view == .brain && model.aside == nil)
        await model.command("steps"); #expect(model.view == .steps)
        await model.command("keys"); #expect(model.view == .keys)
        await model.command("tune"); #expect(model.view == .tune)
        await model.command("help"); #expect(model.view == .help)
        await model.command("nonsense"); #expect(model.view == .help)

        bridge.history = [PanelPreview.row("h", "old", createdAt: 1)]
        await model.command("past")
        #expect(model.view == .past && model.history.map(\.id) == ["h"])

        await model.command("center")
        #expect(bridge.calls.contains("centerPanel"))

        #expect(!model.welcome)
        await model.command("setup")
        #expect(model.welcome)

        bridge.bench = [BenchRow(group: "Local", label: "Spotlight", ms: 12, detail: "mdfind")]
        await model.command("bench")
        #expect(model.view == .bench && model.bench == bridge.bench && !model.benching)
        bridge.failure = "No route."
        await model.command("bench")
        #expect(model.bench.isEmpty && !model.benching && model.aside == "No route.")

        // Stop only means something while a task runs.
        await model.command("stop")
        #expect(!bridge.calls.contains("cancelTask"))
        model.task = turn("a", status: .executing)
        await model.command("stop")
        #expect(bridge.calls.contains("cancelTask"))

        // New chat is refused while it works, then puts the chat away.
        await model.command("new")
        #expect(model.task != nil && model.aside == "Merry is still working. Stop the task to start a new chat.")
        model.task = turn("a")
        model.thread = [turn("z")]
        model.view = .steps
        let tick = model.focusTick
        await model.command("new")
        #expect(model.task == nil && model.thread.isEmpty && model.view == .home && model.aside == nil && model.focusTick == tick + 1)
    }

    @Test func undoPicksATargetAndSaysWhatHappened() async {
        let (model, bridge, _) = make()
        await model.command("undo")
        #expect(model.aside == "No file changes to undo yet.")
        #expect(!bridge.calls.contains("undoTask"))

        // Nothing on screen: the most recent undoable chat in History.
        bridge.history = [PanelPreview.row("h1", "plain", createdAt: 2), PanelPreview.row("h2", "moved", createdAt: 1, undoable: true)]
        bridge.undoReport.reversed = 1
        await model.command("undo")
        #expect(bridge.calls.filter { $0 == "undoTask" }.count == 1)
        #expect(model.aside == "Restored 1 item.")
        #expect(model.history.count == 2)

        // The task on screen wins when it can be undone, even with nothing in History.
        bridge.history = []
        var done = turn("a")
        done.summary = TaskSummary(headline: "Moved", undoable: true)
        model.task = done
        bridge.undoReport.reversed = 3
        bridge.undoReport.skipped = [.init(path: "/a", reason: "it changed since"), .init(path: "/b", reason: "gone")]
        await model.command("undo")
        #expect(bridge.calls.filter { $0 == "undoTask" }.count == 2)
        #expect(model.aside == "Restored 3 items. 2 skipped: it changed since")

        bridge.failure = "The undo log is locked."
        await model.command("undo")
        #expect(model.aside == "The undo log is locked.")
    }

    // MARK: Opening and deleting

    @Test func openingATaskRebuildsItsConversation() async {
        let (model, bridge, _) = make()
        bridge.tasks = ["a": turn("a"), "b": turn("b", replyTo: "a"), "c": turn("c", replyTo: "b"), "d": turn("d", replyTo: "missing")]
        model.view = .past
        await model.openTask("c")
        #expect(model.task?.id == "c" && model.thread.map(\.id) == ["a", "b"] && model.view == .home)
        // A broken chain stops where it breaks.
        await model.openTask("d")
        #expect(model.task?.id == "d" && model.thread.isEmpty)
        // Unknown: nothing changes.
        await model.openTask("nope")
        #expect(model.task?.id == "d")
        // A long chat keeps the eight turns before the one opened.
        for i in 0...12 { bridge.tasks["n\(i)"] = turn("n\(i)", replyTo: i == 0 ? nil : "n\(i - 1)") }
        await model.openTask("n12")
        #expect(model.thread.map(\.id) == (4...11).map { "n\($0)" })
    }

    @Test func anotherTaskCannotBeOpenedWhileOneRuns() async {
        let (model, bridge, _) = make()
        bridge.tasks = ["a": turn("a"), "r": turn("r", status: .executing)]
        model.task = turn("r", status: .executing)
        await model.openTask("a")
        #expect(model.task?.id == "r" && model.aside == "Finish or stop your current task before opening another.")
        model.aside = nil
        model.view = .past
        await model.openTask("r")
        #expect(model.aside == nil && model.view == .home)
    }

    @Test func deletingARowOrAWholeChat() async throws {
        let (model, bridge, _) = make()
        bridge.history = [PanelPreview.row("a", "one", createdAt: 1), PanelPreview.row("x", "other", createdAt: 2)]
        await model.refreshHistory()
        model.thread = [turn("a"), turn("b", replyTo: "a")]
        model.task = turn("c", replyTo: "b")
        model.logs = [LogEntry(taskId: "c", level: .info, source: "loop", message: "hi")]

        try await model.deleteTask("x")
        #expect(model.history.map(\.id) == ["a"] && model.task?.id == "c" && model.thread.count == 2)
        try await model.deleteTask("a")
        #expect(model.thread.map(\.id) == ["b"] && model.task?.id == "c")

        model.confirmDelete = true
        try await model.deleteChat()
        #expect(bridge.calls.filter { $0 == "deleteTask" }.count == 4)
        #expect(model.task == nil && model.thread.isEmpty && model.logs.isEmpty && !model.confirmDelete)

        // Deleting the turn on screen clears it and its log.
        model.task = turn("z")
        model.logs = [LogEntry(taskId: "z", level: .info, source: "loop", message: "hi")]
        try await model.deleteTask("z")
        #expect(model.task == nil && model.logs.isEmpty)

        // A failure leaves everything where it was.
        model.task = turn("k")
        bridge.failure = "Stop the task first."
        await #expect(throws: MerryError.self) { try await model.deleteChat() }
        #expect(model.task?.id == "k")
    }

    @Test func deletionsElsewhereAreForgottenHereToo() async {
        let (model, bridge, _) = make()
        bridge.history = [PanelPreview.row("a", "one", createdAt: 1), PanelPreview.row("b", "two", createdAt: 2)]
        await model.refreshHistory()
        model.thread = [turn("a")]
        model.task = turn("b", replyTo: "a")
        model.logs = [LogEntry(taskId: "b", level: .info, source: "loop", message: "hi"), LogEntry(taskId: "other", level: .info, source: "loop", message: "hi")]
        bridge.events.historyDeleted.send(["a", "b"])
        #expect(model.history.isEmpty && model.thread.isEmpty && model.task == nil && model.logs.map(\.taskId) == ["other"])

        bridge.history = [PanelPreview.row("c", "three", createdAt: 3)]
        await model.refreshHistory()
        model.confirmClear = true
        await model.clearHistory()
        #expect(model.history.isEmpty && !model.confirmClear)
    }

    // MARK: Summoning

    @Test func aChatLeftTenMinutesIsPutAwayOnTheNextSummon() async {
        let (model, bridge, clock) = make()
        #expect(PanelModel.staleChatMs == 600_000)
        model.task = turn("a", updatedAt: clock.now)
        model.thread = [turn("z")]
        clock.now += 600_000
        bridge.events.focusInput.send()
        #expect(model.task?.id == "a")
        #expect(model.focusTick == 1)
        clock.now += 1
        bridge.events.focusInput.send()
        #expect(model.task == nil && model.thread.isEmpty && model.logs.isEmpty)

        // A task still running is never put away.
        model.task = turn("r", status: .awaitingUser, updatedAt: clock.now)
        clock.now += 3_600_000
        model.summoned()
        #expect(model.task?.id == "r")
    }

    @Test func comingForwardRechecksWhatMerryCanDo() async {
        let (model, bridge, _) = make { bridge in
            bridge.apiKey = false
            bridge.permissions[0].granted = false
        }
        #expect(model.hasKey == nil)
        bridge.frontWindow = FrontWindow(pid: 1, name: "Safari", title: "Olive")
        model.summoned()
        #expect(model.front?.name == "Safari")
        await settle()
        #expect(model.hasKey == false && model.blind)
        bridge.apiKey = true
        bridge.permissions[0].granted = true
        await model.refreshSetup()
        #expect(model.hasKey == true && !model.blind)
    }

    // MARK: Derived

    @Test func theFaceReactsToAHalfTypedRequest() {
        #expect(PanelModel.moodForDraft("", fallback: .proud) == .proud)
        #expect(PanelModel.moodForDraft("   ", fallback: .idle) == .idle)
        #expect(PanelModel.moodForDraft("/he", fallback: .idle) == .wink)
        #expect(PanelModel.moodForDraft("Find my lease", fallback: .idle) == .curious)
        #expect(PanelModel.moodForDraft("look for the pdf", fallback: .idle) == .curious)
        #expect(PanelModel.moodForDraft("finder window", fallback: .idle) == .listening)
        #expect(PanelModel.moodForDraft("tidy this please", fallback: .idle) == .happy)
        #expect(PanelModel.moodForDraft("Thank You", fallback: .idle) == .happy)
        #expect(PanelModel.moodForDraft("rename these", fallback: .idle) == .listening)

        let (model, _, _) = make()
        model.petState = .working
        #expect(model.barMood == .working)
        var failed = turn("a", status: .failed)
        failed.petState = .failed
        model.task = failed
        #expect(model.barMood == .sad && model.islandMood == .sad)
        model.draft = "find"
        #expect(model.barMood == .curious)
        model.draft = ""
        model.view = .help
        #expect(model.barMood == .working)
        model.task = turn("r", status: .executing)
        #expect(model.islandMood == .working)
    }

    @Test func thePlaceholderSaysWhatTheFieldIsFor() {
        let (model, _, _) = make()
        #expect(model.placeholder == "Ask Merry anything…")
        model.dropped = ["/tmp/a"]
        #expect(model.placeholder == "What should I do with these?")
        model.dropped = []
        model.task = turn("a")
        #expect(model.chatting && model.placeholder == "Reply to Merry…")
        model.view = .help
        #expect(!model.chatting && model.placeholder == "Ask Merry anything…")
        model.task = turn("a", status: .executing)
        #expect(model.placeholder == "Merry is working…")
        var waiting = turn("a", status: .awaitingUser)
        waiting.question = question(free: true)
        model.task = waiting
        #expect(model.placeholder == "Your answer…")
        waiting.question = question(free: false)
        model.task = waiting
        #expect(model.placeholder == "Choose an option above")
    }

    @Test func theIslandSaysOneLine() {
        let (model, _, _) = make()
        #expect(model.islandLine == "Merry")
        var running = turn("a", status: .executing)
        running.statusLine = "Moving 12 files"
        model.task = running
        #expect(model.islandLine == "Moving 12 files")
        running.statusLine = ""
        model.task = running
        #expect(model.islandLine == "Working")
        running.status = .awaitingUser
        running.statusLine = "anything"
        model.task = running
        #expect(model.islandLine == "Needs your answer")
        var done = turn("a")
        done.summary = TaskSummary(headline: "Sorted **210 files**\ninto `six` folders.")
        model.task = done
        #expect(model.islandLine == "Sorted 210 files into six folders.")
        model.task = turn("a", status: .failed)
        #expect(model.islandLine == "Merry")
    }

    @Test func aPlainAnswerHasNoOutcomeToBadge() {
        let (model, _, _) = make()
        #expect(!model.isChat)
        var done = turn("a")
        done.summary = TaskSummary(headline: "Four.")
        model.task = done
        #expect(model.isChat)
        done.summary = TaskSummary(headline: "Here.", evidence: [.path("Downloads", "/tmp")])
        model.task = done
        #expect(!model.isChat)
        done.summary = TaskSummary(headline: "Four.")
        done.actions = [PanelPreview.action(1, "files_list", at: 0, took: 1)]
        model.task = done
        #expect(!model.isChat)
        model.task = turn("a", status: .failed)
        #expect(!model.isChat)
    }

    @Test func recentIsTheLastThreeDistinctRequestsThatWorked() {
        let (model, _, _) = make()
        model.history = [
            PanelPreview.row("1", "Organize my Downloads folder", createdAt: 9),
            PanelPreview.row("2", "Book a table", status: .failed, createdAt: 8),
            PanelPreview.row("3", "Find the lease", createdAt: 7),
            PanelPreview.row("4", "  organize my downloads FOLDER ", createdAt: 6),
            PanelPreview.row("5", "Rename these", createdAt: 5),
            PanelPreview.row("6", "Something older", createdAt: 4)
        ]
        // As a JavaScript Map does it: first-seen order, last-seen value.
        #expect(model.again.map(\.id) == ["4", "3", "5"])
        model.history = []
        #expect(model.again.isEmpty)
    }

    @Test func theChatHeaderNamesTheConversation() {
        let (model, _, clock) = make()
        model.task = turn("a", "  Sort the receipts \nby month", updatedAt: clock.now - 5 * 60_000)
        #expect(model.chatTitle == "Sort the receipts" && model.messageCount == "1 message" && model.chatAge == "5m ago")
        model.thread = [turn("z", "First question", updatedAt: clock.now - 3 * 3_600_000)]
        #expect(model.chatTitle == "First question" && model.messageCount == "2 messages" && model.chatAge == "3h ago")
    }

    @Test func timesReadTheWayAPersonWouldSayThem() {
        LocalTime.use(timeZone: "Asia/Kolkata")
        let now: Double = 1_790_000_000_000
        #expect(PanelModel.since(now - 59_000, now: now) == "just now")
        #expect(PanelModel.since(now - 60_000, now: now) == "1m ago")
        #expect(PanelModel.since(now - 59 * 60_000, now: now) == "59m ago")
        #expect(PanelModel.since(now - 23 * 3_600_000, now: now) == "23h ago")
        #expect(PanelModel.since(now - 24 * 3_600_000, now: now) == JSDate(now - 24 * 3_600_000).format("MMM d"))
        #expect(PanelModel.relative(now + 5_000, now: now) == "Now")
        #expect(PanelModel.relative(now - 90_000, now: now) == "1m")
        #expect(PanelModel.relative(now - 2 * 3_600_000, now: now) == "2h")
        #expect(PanelModel.relative(now - 1440 * 60_000, now: now) == JSDate(now - 1440 * 60_000).format("MMM d"))

        var task = turn("a", updatedAt: 0)
        task.updatedAt = 400
        #expect(PanelModel.took(task) == "instantly")
        task.updatedAt = 47_400
        #expect(PanelModel.took(task) == "47s")
        task.updatedAt = 125_000
        #expect(PanelModel.took(task) == "2m 5s")

        #expect(PanelModel.elapsed(since: now - 9_900, now: now) == "9s")
        #expect(PanelModel.elapsed(since: now - 65_000, now: now) == "1:05")
        #expect(PanelModel.elapsed(since: now + 5_000, now: now) == "0s")

        let timer = BrainTimer(id: "t", label: "Focus", durationMs: 1_500_000, remainingMs: 600_000, endsAt: now + 61_000, status: "running", notifiedAt: nil)
        #expect(PanelModel.timerText(timer, now: now) == "01:01")
        var paused = timer
        paused.status = "paused"
        #expect(PanelModel.timerText(paused, now: now) == "10:00 paused")
    }

    @Test func theWorkspaceRowShowsWhatIsWaiting() {
        let (model, _, clock) = make()
        #expect(model.workspaceBadge == .hint)
        model.brain = PanelPreview.brain(now: clock.now)
        #expect(model.workspaceBadge == .due(2))
        clock.now -= 3_600_000
        #expect(model.workspaceBadge == .kept(4))
        clock.now += 3_600_000
        model.brain = PanelPreview.brain(now: clock.now, timer: true)
        if case .timer(let timer) = model.workspaceBadge { #expect(timer.label == "Invoice draft") } else { Issue.record("expected the timer") }
    }

    // MARK: Height

    @Test func theHeightIsRoundedUpToTwenty() {
        #expect(PanelModel.panelHeight(content: 100, chrome: 100) == 200)
        #expect(PanelModel.panelHeight(content: 100.5, chrome: 100) == 220)
        #expect(PanelModel.panelHeight(content: 181, chrome: 108) == 300)
        #expect(PanelModel.panelHeight(content: 0, chrome: 0) == 0)
        #expect(PanelModel.panelHeight(content: 1, chrome: 0) == 20)
    }

    @Test func theHeightIsOnlyReportedForTheOpenPanel() {
        let (model, bridge, _) = make()
        model.reportHeight(content: 181, chrome: 108)
        #expect(bridge.calls.filter { $0 == "resizePanel" }.count == 1)
        bridge.minimizePanel()
        #expect(model.panel.docked)
        model.reportHeight(content: 181, chrome: 108)
        bridge.minimizePanel()
        model.welcome = true
        model.reportHeight(content: 181, chrome: 108)
        #expect(bridge.calls.filter { $0 == "resizePanel" }.count == 1)
    }

    // MARK: Everything else it is told

    @Test func firstRunShowsTheTourUntilItIsFinished() async {
        let bridge = PreviewBridge()
        let model = PanelModel(bridge: bridge)
        #expect(model.welcome)
        model.finishWelcome("Find my lease")
        #expect(!model.welcome && model.seed?.text == "Find my lease" && model.view == .home)
        model.welcome = true
        let tick = model.focusTick
        model.finishWelcome(nil)
        #expect(!model.welcome && model.focusTick == tick + 1)
        await settle()
    }

    @Test func eventsLandWhereTheyBelong() async {
        let (model, bridge, _) = make()
        model.view = .help
        bridge.events.droppedPaths.send(["/tmp/a", "/tmp/b"])
        #expect(model.dropped == ["/tmp/a", "/tmp/b"] && model.view == .home)

        model.view = .past
        bridge.events.seed.send("Find ")
        let first = model.seed
        #expect(first?.text == "Find " && model.view == .home)
        bridge.events.seed.send("Find ")
        #expect(model.seed?.text == "Find " && model.seed != first)

        bridge.openBrain()
        #expect(model.view == .brain)
        bridge.events.petState.send(.waiting)
        #expect(model.petState == .waiting)
        bridge.events.desktopSession.send(true)
        #expect(model.desktopActive)
        bridge.pinPanel(true)
        #expect(model.panel.pinned)
        bridge.events.taskUpdate.send(turn("a", status: .executing))
        #expect(model.task?.id == "a")

        for i in 0..<230 { bridge.events.log.send(LogEntry(taskId: i % 2 == 0 ? "a" : "b", level: .info, source: "loop", message: "\(i)")) }
        #expect(model.logs.count == 200 && model.logs.last?.message == "229" && model.logs.first?.message == "30")
        #expect(model.taskLogs.count == 100)

        // A workspace change that arrives before the first load is not overwritten by it.
        var changed = BrainSnapshot()
        changed.timer = BrainTimer(id: "t", label: "Focus", durationMs: 1, remainingMs: 1, endsAt: nil, status: "paused", notifiedAt: nil)
        bridge.events.brainChanged.send(changed)
        await model.load()
        #expect(model.brain.timer?.label == "Focus")
    }

    @Test func suggestionsStartANewChatUnlessOneIsRunning() {
        let (model, _, _) = make()
        model.task = turn("a")
        model.thread = [turn("z")]
        model.view = .brain
        model.compose("Organize my Downloads folder")
        #expect(model.task == nil && model.thread.isEmpty && model.view == .home && model.seed?.text == "Organize my Downloads folder")

        model.task = turn("r", status: .executing)
        model.compose("Find ")
        #expect(model.task?.id == "r" && model.seed?.text == "Find " && model.aside == nil)
    }

    @Test func attachmentsAreDistinctAndCapped() async {
        let (model, bridge, _) = make()
        bridge.pickedPaths = ["/tmp/a", "/tmp/b"]
        await model.attach()
        bridge.pickedPaths = ["/tmp/b", "/tmp/c"]
        await model.attach()
        #expect(model.dropped == ["/tmp/a", "/tmp/b", "/tmp/c"])
        model.addDropped((0..<300).map { "/tmp/f\($0)" })
        #expect(model.dropped.count == 200)

        model.dropped = []
        model.view = .help
        model.dragging = true
        model.drop(["", "/tmp/x"])
        #expect(model.dropped == ["/tmp/x"] && model.view == .home && !model.dragging)
        model.view = .help
        model.drop([])
        #expect(model.view == .help)
    }

    @Test func escapeGoesBackThenAway() {
        let (model, bridge, _) = make()
        model.view = .past
        model.escape()
        #expect(model.view == .home && !bridge.calls.contains("closePanel"))
        model.escape()
        #expect(bridge.calls.contains("closePanel"))
    }

    @Test func confirmationsCloseWhenThePageChanges() {
        let (model, _, _) = make()
        model.view = .past
        model.confirmClear = true
        model.view = .home
        #expect(!model.confirmClear)
        model.task = turn("a")
        model.confirmDelete = true
        var same = turn("a")
        same.statusLine = "still here"
        model.task = same
        #expect(model.confirmDelete)
        model.task = turn("b")
        #expect(!model.confirmDelete)
        model.confirmDelete = true
        model.thread = [turn("z")]
        #expect(!model.confirmDelete)
    }

    // MARK: The composer's pure parts

    @Test func thePaletteMatchesByPrefix() {
        #expect(PanelCommand.matches("find").isEmpty)
        #expect(PanelCommand.matches("/").count == 12)
        #expect(PanelCommand.matches("/s").map(\.name) == ["steps", "stop", "setup"])
        #expect(PanelCommand.matches("/ST ").map(\.name) == ["steps", "stop"])
        #expect(PanelCommand.matches("/zzz").isEmpty)
        #expect(PromptView.paletteHeight(0) == 0)
        #expect(PromptView.paletteHeight(2) == 72)
        #expect(PromptView.paletteHeight(12) == 280)
        #expect(PromptView.maxLength == 4000)
    }

    @Test func pathsAndRowsReadAsTheOriginalWroteThem() {
        #expect(PanelPaths.basename("/Users/mira/Downloads/a.pdf") == "a.pdf")
        #expect(PanelPaths.basename("/Users/mira/Downloads/") == "Downloads")
        #expect(PanelPaths.basename("/") == "/")
        #expect(PanelPaths.dirname("/a/b/c") == "/a/b")
        #expect(PanelPaths.dirname("/a") == "/" && PanelPaths.dirname("a") == "/")
        #expect(PanelPaths.shortenPath("/Users/mira/Downloads/2026/a.pdf", home: "/Users/mira") == "~/Downloads/2026/a.pdf")
        #expect(PanelPaths.shortenPath("/Users/mira/Downloads/2026/10/a.pdf", home: "/Users/mira") == "~/Downloads/…/10/a.pdf")

        #expect(AskView.destination(FileOp(from: "/a/b/x.png", to: "/a/b/y.png", kind: "move")) == "y.png")
        #expect(AskView.destination(FileOp(from: "/a/b/x.png", to: "/a/c/x.png", kind: "move")) == "/a/c/x.png")
        #expect(AskView.destination(FileOp(from: "/a/b/x.png", to: "/a/c/y.png", kind: "rename")) == "y.png")

        #expect(StepsView.mark(.success) == "✓" && StepsView.mark(.failure) == "✕" && StepsView.mark(.uncertain) == "?")
        #expect(StepsView.duration(PanelPreview.action(1, "files_move", at: 1_000, took: 18_440)) == "18.4s")
        let one = PanelPreview.row("a", "x", createdAt: 0)
        let many = PanelPreview.row("b", "x", createdAt: 0, turns: 3)
        #expect(PastView.confirmText(one) == "Delete this chat and its undo history? Files stay.")
        #expect(PastView.confirmText(many) == "Delete this chat (3 messages) and its undo history? Files stay.")
        var report = UndoReport()
        report.reversed = 4
        #expect(PastView.undoNote(report) == "4 restored")
        report.skipped = [.init(path: "/a", reason: "gone")]
        #expect(PastView.undoNote(report) == "4 restored · 1 skipped")
    }

    @Test func everyPanelScreenIsRegistered() {
        PanelScreens.register()
        for name in ["panel-home", "panel-home-recents", "panel-home-files", "panel-running", "panel-question", "panel-authorization", "panel-done",
                     "panel-failed", "panel-chat", "panel-steps", "panel-history", "panel-help", "panel-palette", "island-idle", "island-working", "island-timer"] {
            #expect(Snapshot.screens[name] != nil, "\(name)")
        }
    }
}

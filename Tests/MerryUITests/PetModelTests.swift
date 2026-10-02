import Testing
import MerryCore
@testable import MerryUI

@Suite struct PetLogicTests {
    private func mood(dropping: Bool = false, dragging: Bool = false, dancing: Bool = false, flash: PetFlash? = nil, asleep: Bool = false,
                      state: PetState = .idle, straining: Bool = false, settled: Bool = false, hovered: Bool = false) -> Mood {
        PetLogic.mood(dropping: dropping, dragging: dragging, dancing: dancing, flash: flash, now: 1000, asleep: asleep,
                      state: state, straining: straining, settled: settled, hovered: hovered)
    }

    @Test func moodPrecedence() {
        let flash = PetFlash(mood: .oops, until: 2000)
        // Each line beats everything below it.
        #expect(mood(dropping: true, dragging: true, dancing: true, flash: flash, asleep: true) == .excited)
        #expect(mood(dragging: true, dancing: true, flash: flash, asleep: true) == .dizzy)
        #expect(mood(dancing: true, flash: flash, asleep: true) == .music)
        #expect(mood(flash: flash, asleep: true, hovered: true) == .oops)
        #expect(mood(asleep: true, hovered: true) == .sleepy)
        #expect(mood(state: .working, straining: true, hovered: true) == .straining)
        #expect(mood(hovered: true) == .happy)
        #expect(mood() == .idle)
    }

    @Test func aFlashThatHasRunOutIsIgnored() {
        #expect(mood(flash: PetFlash(mood: .oops, until: 1000)) == .idle)
        #expect(mood(flash: PetFlash(mood: .oops, until: 1001)) == .oops)
    }

    @Test func sleepOnlyShowsWhileIdleAndStrainOnlyWhileWorking() {
        #expect(mood(asleep: true, state: .working) == .working)
        #expect(mood(asleep: true, state: .thinking) == .thinking)
        #expect(mood(state: .thinking, straining: true) == .thinking)
    }

    @Test func theRuntimeStatePicksTheRest() {
        for state in [PetState.idle, .listening, .thinking, .working, .waiting, .finished, .failed] {
            #expect(mood(state: state) == Mood.forState(state))
        }
        // Celebration and sulking wear off.
        #expect(mood(state: .finished, settled: true) == .idle)
        #expect(mood(state: .failed, settled: true) == .idle)
        #expect(mood(state: .working, settled: true) == .working)
    }

    @Test func hoveringIsHappyOnlyWhenThereIsNothingElseToShow() {
        #expect(mood(state: .finished, hovered: true) == .happy)
        #expect(mood(state: .failed, hovered: true) == .sad)
        #expect(mood(state: .failed, settled: true, hovered: true) == .happy)
        for state in [PetState.listening, .thinking, .working, .waiting] {
            #expect(mood(state: state, hovered: true) == Mood.forState(state))
        }
    }

    @Test func eyesFollowTheCursorEasingOffWithDistance() {
        #expect(PetLogic.look(dx: 0, dy: 0) == Look(x: 0, y: 0))
        #expect(PetLogic.look(dx: 70, dy: 0) == Look(x: 0.5, y: 0))
        #expect(PetLogic.look(dx: 0, dy: -140) == Look(x: 0, y: -1))
        // Far away it is a full glance in that direction, never more.
        let far = PetLogic.look(dx: 3000, dy: 4000)
        #expect(abs(far.x - 0.6) < 1e-9 && abs(far.y - 0.8) < 1e-9)
        let near = PetLogic.look(dx: -30, dy: 40)
        #expect(abs(near.x + 0.6 * 50 / 140) < 1e-9 && abs(near.y - 0.8 * 50 / 140) < 1e-9)
    }

    // MARK: The bubble

    private func input(_ change: (inout PetLogic.BubbleInput) -> Void) -> PetBubble? {
        var i = PetLogic.BubbleInput()
        i.now = 1_000_000
        change(&i)
        return PetLogic.bubble(i)
    }

    @Test func bubbleTextPrecedence() {
        let chat = Line("Hi.", .shy)
        let timer = petTimer("running", endsAt: 1_000_000 + 65_000)
        let due = petReminder("r", title: "Call the dentist", dueAt: 999_000)
        func all(_ i: inout PetLogic.BubbleInput) {
            i.alertError = "Could not update reminder."; i.timer = timer; i.due = due; i.hovered = true
            i.undoNote = "Sorry. Moved 3 back where they were."; i.chat = chat; i.bubble = "Working"
        }
        #expect(input { all(&$0) }?.text == "Could not update reminder.")
        #expect(input { all(&$0); $0.alertError = nil }?.text == "Call the dentist")
        #expect(input { all(&$0); $0.alertError = nil; $0.due = nil }?.text == "Deep work · 01:05 left")
        #expect(input { all(&$0); $0.alertError = nil; $0.due = nil; $0.hovered = false }?.text == "Sorry. Moved 3 back where they were.")
        #expect(input { all(&$0); $0.alertError = nil; $0.due = nil; $0.timer = nil; $0.undoNote = nil }?.text == "Hi.")
        #expect(input { $0.bubble = "Working" }?.text == "Working")
        #expect(input { _ in } == nil)
        #expect(input { $0.bubble = "" } == nil)
        // While a file hovers over it there is no bubble at all.
        #expect(input { all(&$0); $0.dropping = true } == nil)
    }

    @Test func aRingingTimerBeatsADueReminderAndAQuestionBeatsBoth() {
        let ringing = petTimer("ringing")
        let due = petReminder("r", title: "Call", dueAt: 1)
        let rung = input { $0.timer = ringing; $0.due = due }
        #expect(rung?.text == "Time’s up: Deep work." && rung?.tone == .reminder && rung?.buttons == [.done])
        let reminder = input { $0.due = due }
        #expect(reminder?.tone == .reminder && reminder?.buttons == [.done, .snooze])
        #expect(reminder?.buttons.map(\.label) == ["Done", "10 min"])
        let asking = input { $0.timer = ringing; $0.due = due; $0.taskStatus = .awaitingUser; $0.bubble = "Which one?" }
        #expect(asking?.text == "Which one?" && asking?.tone == .ask && asking?.buttons == [.answer])
    }

    @Test func peekSaysWhatTheTimerIsFor() {
        let paused = input { $0.timer = petTimer("paused"); $0.hovered = true }
        #expect(paused?.text == "Deep work · paused" && paused?.tone == .peek && paused?.buttons == [])
        #expect(input { $0.timer = petTimer("paused") } == nil)
        #expect(input { $0.timer = petTimer("ringing"); $0.hovered = true }?.tone == .reminder)
        let hours = input { $0.timer = petTimer("running", endsAt: 1_000_000 + 1_400_000); $0.hovered = true }
        #expect(hours?.text == "Deep work · 23:20 left")
    }

    @Test func tones() {
        #expect(input { $0.bubble = "x" }?.tone == .plain)
        #expect(input { $0.bubble = "x"; $0.taskStatus = .executing }?.tone == .plain)
        #expect(input { $0.bubble = "x"; $0.taskStatus = .awaitingUser }?.tone == .ask)
        #expect(input { $0.bubble = "x"; $0.taskStatus = .succeeded }?.tone == .good)
        #expect(input { $0.bubble = "x"; $0.taskStatus = .failed }?.tone == .bad)
        #expect(input { $0.bubble = "x"; $0.taskStatus = .cancelled }?.tone == .plain)
        #expect(input { $0.bubble = "x"; $0.taskStatus = .failed; $0.chat = Line("Sorry", .nervous) }?.tone == .chat)
        // An undo note takes the task's tone back from the chat.
        #expect(input { $0.undoNote = "n"; $0.taskStatus = .succeeded; $0.chat = Line("Hi", .shy) }?.tone == .good)
    }

    @Test func thePulseShowsOnlyBesideAStatusLineWhileWorking() {
        #expect(input { $0.bubble = "Moving"; $0.working = true }?.pulse == true)
        #expect(input { $0.bubble = "Moving" }?.pulse == false)
        #expect(input { $0.bubble = "Moving"; $0.working = true; $0.chat = Line("On it.", .determined) }?.pulse == false)
        #expect(input { $0.bubble = "Moving"; $0.working = true; $0.timer = petTimer("paused"); $0.hovered = true }?.pulse == false)
        #expect(input { $0.bubble = "Moving"; $0.working = true; $0.due = petReminder("r", title: "t", dueAt: 1) }?.pulse == false)
    }

    @Test func buttons() {
        let offer = Line("Tidy?", .curious, action: .init(label: "Sure", compose: "Organize my Downloads folder"))
        #expect(input { $0.chat = offer }?.buttons == [.line("Sure")])
        #expect(input { $0.chat = Line("Hi", .shy) }?.buttons == [])
        #expect(input { $0.chat = offer; $0.undoNote = "n" }?.buttons == [])
        #expect(input { $0.chat = offer; $0.due = petReminder("r", title: "t", dueAt: 1) }?.buttons == [.done, .snooze])
        #expect(input { $0.bubble = "Done"; $0.taskStatus = .succeeded; $0.undoable = true }?.buttons == [.undo])
        #expect(input { $0.bubble = "Done"; $0.taskStatus = .succeeded }?.buttons == [])
        // Undoable only counts once the task is over.
        #expect(input { $0.bubble = "Going"; $0.taskStatus = .executing; $0.undoable = true }?.buttons == [])
        #expect(input { $0.bubble = "Done"; $0.taskStatus = .succeeded; $0.undoable = true; $0.chat = Line("Hi", .shy) }?.buttons == [])
        #expect(input { $0.bubble = "Done"; $0.taskStatus = .succeeded; $0.undoable = true; $0.undoNote = "n" }?.buttons == [])
        #expect(input { $0.bubble = "Done"; $0.taskStatus = .succeeded; $0.undoable = true; $0.timer = petTimer("paused"); $0.hovered = true }?.buttons == [])
    }

    @Test func theKeyChangesWithWhatItSays() {
        #expect(input { $0.bubble = "x" }?.key == "status")
        #expect(input { $0.bubble = "x"; $0.chat = Line("Hi.", .shy) }?.key == "Hi.")
    }

    // MARK: Clicks and rubbing

    @Test func clickCounting() {
        var clicks: [Double] = []
        #expect(PetLogic.click(&clicks, now: 0, asleep: false) == .open)
        #expect(PetLogic.click(&clicks, now: 200, asleep: false) == .ignored)
        #expect(PetLogic.click(&clicks, now: 400, asleep: false) == .petted)
        #expect(PetLogic.click(&clicks, now: 600, asleep: false) == .ignored)
        #expect(PetLogic.click(&clicks, now: 800, asleep: false) == .ignored)
        #expect(PetLogic.click(&clicks, now: 1000, asleep: false) == .tickled)
        // Being tickled starts the count again.
        #expect(clicks.isEmpty)
        #expect(PetLogic.click(&clicks, now: 1100, asleep: false) == .open)
    }

    @Test func clicksMoreThanASecondAndAHalfApartAreSeparate() {
        var clicks: [Double] = []
        #expect(PetLogic.click(&clicks, now: 0, asleep: false) == .open)
        #expect(PetLogic.click(&clicks, now: 1500, asleep: false) == .open)
        #expect(PetLogic.click(&clicks, now: 2999, asleep: false) == .ignored)
        #expect(PetLogic.click(&clicks, now: 4498, asleep: false) == .ignored)
        #expect(clicks == [2999, 4498])
    }

    @Test func aClickWakesANapInsteadOfOpening() {
        var clicks: [Double] = []
        #expect(PetLogic.click(&clicks, now: 0, asleep: true) == .wake)
        #expect(PetLogic.click(&clicks, now: 100, asleep: true) == .wake)
        // Affection still counts in its sleep.
        #expect(PetLogic.click(&clicks, now: 200, asleep: true) == .petted)
    }

    @Test func rubbingBackAndForthIsPetting() {
        var rub = RubDetector()
        var now = 10_000.0
        var petted: [Bool] = []
        // Right, then four changes of direction.
        for x in [100.0, 120, 100, 120, 100, 120] { petted.append(rub.notice(x: x, now: now)); now += 100 }
        #expect(petted == [false, false, false, false, false, true])
        // Not again for four seconds, however much it is rubbed.
        for i in 0..<20 { let again = rub.notice(x: i % 2 == 0 ? 100 : 120, now: now); #expect(!again); now += 100 }
        now += 2000
        var again = false
        for i in 0..<6 where rub.notice(x: i % 2 == 0 ? 100 : 120, now: now + Double(i) * 100) { again = true }
        #expect(again)
    }

    @Test func slowOrTinyMovementIsNotPetting() {
        var rub = RubDetector()
        // Turns too far apart fall out of the window.
        var now = 10_000.0
        for x in [100.0, 120, 100, 120, 100, 120, 100, 120] { let petted = rub.notice(x: x, now: now); #expect(!petted); now += 1400 }
        // Jitter under three points is ignored altogether.
        var still = RubDetector()
        for i in 0..<40 { let petted = still.notice(x: i % 2 == 0 ? 100 : 102, now: 10_000 + Double(i) * 50); #expect(!petted) }
        #expect(still.turns.isEmpty)
        // One long sweep has no turns in it.
        var sweep = RubDetector()
        for i in 0..<40 { let petted = sweep.notice(x: Double(i) * 5, now: 10_000 + Double(i) * 20); #expect(!petted) }
    }

    // MARK: Geometry

    @Test func burstsFlyOutInARing() {
        let first = PetLogic.particle(0, of: 8)
        #expect(abs(first.dx) < 1e-9 && abs(first.dy - (-34 - 14)) < 1e-9 && first.spin == 0 && first.delayMs == 0)
        let second = PetLogic.particle(2, of: 8)
        // A quarter turn on: straight right, 34 + (74 % 30) = 48 out, lifted 14.
        #expect(abs(second.dx - 48) < 1e-9 && abs(second.dy + 14) < 1e-9 && second.spin == 94 && second.delayMs == 60)
        #expect(PetLogic.particle(5, of: 9).spin == Double((5 * 47) % 160))
        #expect(PetLogic.particle(4, of: 9).delayMs == 30)
        #expect(PetLayout.burstOrigin == petPoint(130, 144))
    }

    @Test func cubicBezierMatchesCSS() {
        let ease = CubicBezier(0.42, 0, 0.58, 1)
        #expect(ease(0) == 0 && ease(1) == 1)
        #expect(abs(ease(0.5) - 0.5) < 1e-4)
        #expect(abs(ease(0.25) - 0.1291) < 1e-3)
        let linear = CubicBezier(0, 0, 1, 1)
        #expect(abs(linear(0.3) - 0.3) < 1e-5)
        // The bubble's entrance overshoots.
        #expect((1...19).contains { CubicBezier(0.3, 1.3, 0.5, 1)(Double($0) / 20) > 1 })
    }
}

@MainActor
@Suite(.serialized) struct PetModelTests {
    @Test func aHelloWhenItArrives() {
        let rig = PetRig(hour: 10)
        #expect(rig.model.bubbleContent == nil && rig.model.mood == .idle)
        rig.advance(1399)
        #expect(rig.model.chat == nil)
        rig.advance(1)
        #expect(rig.model.chat?.text == "Morning. Give me a shout when there’s work.")
        #expect(rig.model.mood == .wave && rig.model.bubbleContent?.tone == .chat)
        rig.advance(3200)
        #expect(rig.model.mood == .idle)
        rig.advance(999)
        #expect(rig.model.chat != nil)
        rig.advance(1)
        #expect(rig.model.chat == nil && rig.model.bubbleContent == nil)
    }

    @Test func notChattyItOnlyMakesTheFace() {
        let rig = PetRig(start: false)
        rig.bridge.settings.chatty = false
        rig.model.start()
        rig.advance(1400)
        #expect(rig.model.chat == nil && rig.model.mood == .wave)
        rig.advance(2500)
        #expect(rig.model.mood == .idle)
        // Turning it back on is heard without a restart.
        var settings = rig.bridge.settings
        settings.chatty = true
        rig.events.settingsChanged.send(settings)
        rig.model.say(Line("Hi.", .shy))
        #expect(rig.model.chat?.text == "Hi.")
    }

    @Test func aRunningTimerKeepsItQuietButNotSilentOnWhatMatters() {
        let rig = PetRig()
        rig.events.brainChanged.send(BrainSnapshot(timer: petTimer("running", endsAt: rig.clock.now + 600_000)))
        rig.model.say(Line("Hi.", .shy))
        #expect(rig.model.chat == nil && rig.model.mood == .shy)
        rig.model.say(Line("Sorry about that.", .nervous), 7000, optional: false)
        #expect(rig.model.chat?.text == "Sorry about that.")
    }

    @Test func aNewJobIsAcknowledgedThenTheStatusLineTakesOver() {
        let rig = PetRig().pastHello()
        rig.events.petState.send(.working)
        rig.events.taskUpdate.send(rig.task(.executing, line: "Moving 14 files"))
        #expect(rig.model.chat?.mood == .determined)
        #expect(["Right away.", "Consider it handled.", "I’ve got this one."].contains(rig.model.chat?.text ?? ""))
        #expect(rig.model.bubbleContent?.pulse == false)
        rig.advance(2000)
        let bubble = rig.model.bubbleContent
        #expect(bubble?.text == "Moving 14 files" && bubble?.pulse == true && bubble?.tone == .plain && bubble?.buttons == [])
        // The same job again says nothing new.
        rig.events.taskUpdate.send(rig.task(.verifying, line: "Checking"))
        #expect(rig.model.chat == nil && rig.model.bubbleContent?.text == "Checking")
        rig.events.taskUpdate.send(rig.task(.verifying, line: ""))
        #expect(rig.model.bubbleContent == nil)
    }

    @Test func aResultStaysWithUndoThenGoes() {
        let rig = PetRig().pastHello()
        rig.events.petState.send(.working)
        rig.events.taskUpdate.send(rig.task(.executing))
        var done = rig.task(.succeeded, line: "Done")
        done.summary = TaskSummary(headline: "Sorted **14 files** into `Documents`.", undoable: true)
        rig.events.petState.send(.finished)
        rig.events.taskUpdate.send(done)
        let bubble = rig.model.bubbleContent
        #expect(bubble?.text == "Sorted 14 files into Documents." && bubble?.tone == .good && bubble?.buttons == [.undo])
        #expect(rig.model.chat == nil && rig.model.mood == .proud)
        rig.advance(11_999)
        #expect(rig.model.bubble != nil)
        rig.advance(1)
        #expect(rig.model.bubble == nil)
    }

    @Test func aResultWithoutUndoGoesSooner() {
        let rig = PetRig().pastHello()
        var done = rig.task(.succeeded, line: "All good")
        rig.events.taskUpdate.send(done)
        #expect(rig.model.bubbleContent?.text == "All good" && rig.model.chat == nil)
        rig.advance(7000)
        #expect(rig.model.bubble == nil)
        // A result that needed many actions is a party.
        done.id = "t2"
        done.actions = (0..<8).map { ActionRecord(id: "a\($0)", step: $0, tool: "files_move", input: .null, startedAt: 0, outcome: .success) }
        rig.events.taskUpdate.send(rig.task(.executing, id: "t2"))
        rig.events.taskUpdate.send(done)
        #expect(rig.model.mood == .celebrate && rig.model.bursts.last?.count == 18 && rig.model.bursts.last?.kind == .sparks)
        rig.advance(1300)
        #expect(rig.model.bursts.isEmpty)
    }

    @Test func aFailureOffersToShowWhatWentWrongEvenWhenQuiet() {
        let rig = PetRig(start: false)
        rig.bridge.settings.chatty = false
        rig.model.start()
        rig.events.petState.send(.failed)
        rig.events.taskUpdate.send(rig.task(.failed, line: "Couldn’t reach that folder."))
        #expect(rig.model.bubbleContent?.tone == .bad && rig.model.mood == .sad)
        rig.advance(3500)
        let bubble = rig.model.bubbleContent
        #expect(bubble?.text == "That didn’t go to plan. Want the details?" && bubble?.buttons == [.line("Show me")] && bubble?.tone == .chat)
        rig.model.press(.line("Show me"))
        #expect(rig.bridge.composed == [""] && rig.model.chat == nil)
    }

    @Test func anOfferOnlyPutsWordsInTheComposer() {
        let rig = PetRig()
        rig.model.say(Line("Shall I sort out your Downloads?", .curious, action: .init(label: "Sure", compose: "Organize my Downloads folder")))
        rig.model.press(.line("Sure"))
        #expect(rig.bridge.composed == ["Organize my Downloads folder"] && rig.bridge.started.isEmpty)
    }

    @Test func waitingOnAnAnswerGetsOneNudge() {
        let rig = PetRig().pastHello()
        var asking = rig.task(.awaitingUser, line: "Which folder?")
        asking.question = UserQuestion(id: "q1", reason: .ambiguous, prompt: "Which folder?", allowFreeText: true)
        rig.events.petState.send(.waiting)
        rig.events.taskUpdate.send(asking)
        rig.advance(2000)
        #expect(rig.model.bubbleContent?.buttons == [.answer] && rig.model.bubbleContent?.tone == .ask)
        rig.model.press(.answer)
        #expect(rig.bridge.composed == [""])
        rig.advance(27_999)
        #expect(rig.model.chat == nil)
        rig.advance(1)
        #expect(["Take your time. I’m not going anywhere.", "Ready when you are."].contains(rig.model.chat?.text ?? ""))
        #expect(rig.model.bubbleContent?.buttons == [.line("Answer")])
        // Only once for this task, even with a second question; and no check-ins while it waits.
        rig.advance(6000)
        asking.question?.id = "q2"
        rig.events.taskUpdate.send(asking)
        rig.advance(120_000)
        #expect(rig.model.chat == nil)
    }

    @Test func aKindWordEveryTwentyFourSecondsDuringALongJob() {
        let rig = PetRig().pastHello()
        rig.events.petState.send(.working)
        rig.events.taskUpdate.send(rig.task(.executing))
        rig.advance(23_999)
        #expect(rig.model.chat == nil)
        rig.advance(1)
        #expect(rig.model.chat?.text == "Not done yet. Thanks for being patient.")
        rig.advance(4200)
        #expect(rig.model.chat == nil)
        rig.advance(24_000 - 4200)
        #expect(rig.model.chat?.text == "Slow going, but I’m still on it.")
        // Over: no more.
        rig.events.taskUpdate.send(rig.task(.cancelled, line: "Stopped"))
        rig.advance(60_000)
        #expect(rig.model.chat == nil)
    }

    @Test func checkInsCountRealSteps() {
        let rig = PetRig().pastHello()
        var task = rig.task(.executing)
        task.plan = petPlan(["done", "active", "pending"])
        rig.events.taskUpdate.send(task)
        rig.advance(24_000)
        #expect(rig.model.chat?.text == "1 of 3 steps down. Trotting on.")
    }

    @Test func longJobsShowEffortAndResultsSettle() {
        let rig = PetRig().pastHello()
        rig.events.petState.send(.working)
        rig.events.taskUpdate.send(rig.task(.executing))
        rig.advance(24_999)
        #expect(!rig.model.straining)
        rig.advance(1)
        #expect(rig.model.straining)
        rig.advance(3200)
        #expect(rig.model.mood == .straining)
        rig.events.petState.send(.finished)
        #expect(!rig.model.straining && !rig.model.settled && rig.model.mood == .proud)
        rig.advance(6000)
        #expect(rig.model.settled && rig.model.mood == .idle)
        rig.events.petState.send(.idle)
        #expect(!rig.model.settled)
    }

    @Test func leftAloneForThreeMinutesItYawnsAndDozes() {
        let rig = PetRig()
        rig.advance(180_000)
        #expect(!rig.model.asleep && rig.model.chat?.text != "Counting myself to sleep…")
        rig.advance(5000)
        #expect(rig.model.chat?.text == "Counting myself to sleep…" && !rig.model.asleep)
        rig.advance(2600)
        #expect(rig.model.asleep)
        rig.advance(4000)
        #expect(rig.model.mood == .sleepy)
        // The cursor coming close wakes it with a start, then a word.
        rig.events.cursor.send(petPoint(20, 30))
        #expect(!rig.model.asleep && rig.model.mood == .surprised)
        rig.advance(700)
        #expect(["Oh! You’re back.", "Awake. Totally awake."].contains(rig.model.chat?.text ?? ""))
    }

    @Test func stirringDuringTheYawnKeepsItAwake() {
        let rig = PetRig()
        rig.advance(185_000)
        #expect(rig.model.chat?.text == "Counting myself to sleep…")
        rig.advance(1000)
        rig.events.cursor.send(petPoint(10, 10))
        rig.advance(10_000)
        #expect(!rig.model.asleep)
    }

    @Test func itDoesNotDozeWhileBusyOrWhileHovered() {
        let busy = PetRig()
        busy.events.petState.send(.waiting)
        busy.advance(400_000)
        #expect(!busy.model.asleep)
        let hovered = PetRig()
        hovered.model.mouseMoved(local: PetRig.centre, screen: petPoint(500, 500), primaryDown: false)
        #expect(hovered.model.hovered)
        hovered.advance(400_000)
        #expect(!hovered.model.asleep)
    }

    @Test func aChosenNapLastsUntilItIsWoken() {
        let rig = PetRig()
        rig.advance(6000)
        rig.events.petPlay.send(.nap)
        #expect(rig.model.chat?.text == "Nap time. Zzz." && !rig.model.asleep)
        rig.advance(900)
        #expect(rig.model.asleep)
        rig.events.cursor.send(petPoint(5, 5))
        #expect(rig.model.asleep)
        rig.advance(5000)
        // A click wakes it, without also opening the panel.
        rig.click()
        #expect(!rig.model.asleep && rig.model.chat?.text == "Just a bit longer?" && rig.calls("petClicked") == 0)
        rig.advance(2000)
        rig.click()
        #expect(rig.calls("petClicked") == 1)
    }

    @Test func idleRemarksComeOnlyWhileThePersonIsAround() {
        let around = PetRig(hour: 10)
        var said: [String] = []
        for minute in 0..<14 {
            // Near enough to keep it awake, and a different spot each time.
            around.events.cursor.send(petPoint(Double(minute), 40))
            for _ in 0..<12 {
                around.advance(5000)
                if let text = around.model.chat?.text, said.last != text { said.append(text) }
            }
        }
        #expect(said == ["Morning. Give me a shout when there’s work.", "Where do we start today?", "Shall I sort out your Downloads?"])

        let away = PetRig(hour: 10)
        away.events.petPlay.send(.wake)
        away.advance(10_000)
        var remarks = 0
        for _ in 0..<200 {
            away.advance(5000)
            if let text = away.model.chat?.text, text != "Counting myself to sleep…" { remarks += 1 }
        }
        #expect(remarks == 0)
    }

    @Test func noRemarksWhileThereIsWork() {
        let rig = PetRig()
        rig.events.petState.send(.waiting)
        for minute in 0..<14 { rig.events.cursor.send(petPoint(Double(minute), 40)); rig.advance(60_000) }
        #expect(rig.model.chat == nil)
    }

    @Test func hoveringForAMomentGetsAShyHelloButNotOften() {
        let rig = PetRig()
        rig.advance(10_000)
        rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(500, 500), primaryDown: false)
        #expect(rig.model.mood == .happy)
        rig.advance(2499)
        #expect(rig.model.chat == nil)
        rig.advance(1)
        #expect(["Hey.", "Oh, it’s you."].contains(rig.model.chat?.text ?? ""))
        rig.advance(2200)
        rig.model.mouseLeft(primaryDown: false)
        #expect(!rig.model.hovered)
        rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(500, 500), primaryDown: false)
        rig.advance(10_000)
        #expect(rig.model.chat == nil)
        // Beside the creature is not on it.
        rig.model.mouseMoved(local: petPoint(60, 140), screen: petPoint(430, 500), primaryDown: false)
        #expect(!rig.model.hovered)
    }

    @Test func aSingleClickOpensThePanelOrTheWorkspaceWhenATimerRuns() {
        let rig = PetRig().pastHello()
        rig.click()
        #expect(rig.calls("petClicked") == 1 && rig.calls("openBrain") == 0)
        #expect(rig.bridge.calls.filter { $0.hasPrefix("setPetInteractive") } == ["setPetInteractive:true", "setPetInteractive:false"])
        rig.advance(2000)
        rig.events.brainChanged.send(BrainSnapshot(timer: petTimer("running", endsAt: rig.clock.now + 600_000)))
        rig.click()
        #expect(rig.calls("petClicked") == 1 && rig.calls("openBrain") == 1)
    }

    @Test func threeQuickClicksPetItAndSixTickle() {
        let rig = PetRig().pastHello()
        for _ in 0..<3 { rig.click(); rig.advance(150) }
        #expect(rig.calls("petClicked") == 1)
        #expect(["Mmm. Right there.", "Wool’s extra fluffy today.", "Best shepherd ever."].contains(rig.model.chat?.text ?? ""))
        #expect(rig.model.bursts.last?.kind == .hearts && rig.model.bursts.last?.count == 9 && rig.model.bursts.last?.color == "#ff6fa8")
        #expect(rig.model.hops == 1)
        for _ in 0..<3 { rig.click(); rig.advance(150) }
        #expect(["Ha! Not the wool!", "Stop, stop, I’m ticklish.", "Baa-ha-ha."].contains(rig.model.chat?.text ?? ""))
        #expect(rig.model.bursts.last?.kind == .sparks && rig.model.bursts.last?.count == 10 && rig.model.hops == 2)
        #expect(rig.calls("petClicked") == 1)
    }

    @Test func aPressOnTheBubbleIsNotAClickOnThePet() {
        let rig = PetRig()
        rig.model.say(Line("Hi.", .shy))
        rig.model.layout(bubble: petRect(90, 52, 80, 38))
        rig.model.mouseDown(local: petPoint(100, 60), screen: petPoint(500, 400))
        rig.model.mouseUp(local: petPoint(100, 60))
        #expect(rig.calls("petClicked") == 0 && rig.calls("setPetInteractive:true") == 0)
    }

    @Test func rubbingTheCursorOverItIsPetting() {
        let rig = PetRig()
        for (i, x) in [100.0, 130, 100, 130, 100, 130, 100].enumerated() {
            rig.model.mouseMoved(local: petPoint(x, 140), screen: petPoint(400 + x, 500), primaryDown: false)
            rig.advance(100)
            _ = i
        }
        #expect(["Mmm. Right there.", "Wool’s extra fluffy today.", "Best shepherd ever."].contains(rig.model.chat?.text ?? ""))
        #expect(rig.model.bursts.count == 1 && rig.model.bursts[0].kind == .hearts && rig.model.hops == 1)
    }

    @Test func aGentleCarryMovesItWithoutMakingItDizzy() {
        let rig = PetRig().pastHello()
        rig.model.mouseDown(local: PetRig.centre, screen: petPoint(500, 500))
        // Under the threshold nothing moves.
        rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(502, 502), primaryDown: true)
        #expect(rig.calls("dragPet") == 0 && rig.model.chat == nil)
        for i in 1...10 { rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(502 + Double(i) * 6, 502), primaryDown: true) }
        #expect(rig.calls("dragPet") == 10 && !rig.model.dragging)
        #expect(["Up we go!", "Hey, where to?"].contains(rig.model.chat?.text ?? ""))
        rig.model.mouseUp(local: PetRig.centre)
        #expect(["Good pasture.", "I like it here."].contains(rig.model.chat?.text ?? ""))
        #expect(rig.model.hops == 1 && rig.calls("petClicked") == 0)
        #expect(rig.bridge.calls.last { $0.hasPrefix("setPetInteractive") } == "setPetInteractive:false")
    }

    @Test func aRealShakeMakesItDizzy() {
        let rig = PetRig().pastHello()
        rig.model.mouseDown(local: PetRig.centre, screen: petPoint(500, 500))
        var x = 500.0
        // 40 points a move: the smoothed speed passes 9 on the second.
        x += 40; rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(x, 500), primaryDown: true)
        #expect(!rig.model.dragging)
        x -= 40; rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(x, 500), primaryDown: true)
        #expect(rig.model.dragging && rig.model.mood == .dizzy)
        rig.model.mouseUp(local: PetRig.centre)
        #expect(!rig.model.dragging)
        #expect(["Oof. Give me a second.", "Everything’s wobbling."].contains(rig.model.chat?.text ?? ""))
    }

    @Test func aDragWhoseReleaseWasNeverSeenStillEnds() {
        // The watchdog: quiet for two and a half seconds.
        let quiet = PetRig()
        quiet.model.mouseDown(local: PetRig.centre, screen: petPoint(500, 500))
        quiet.model.mouseMoved(local: PetRig.centre, screen: petPoint(560, 500), primaryDown: true)
        quiet.model.mouseMoved(local: PetRig.centre, screen: petPoint(500, 500), primaryDown: true)
        #expect(quiet.model.dragging)
        quiet.advance(2499)
        #expect(quiet.model.dragging)
        quiet.advance(1)
        #expect(!quiet.model.dragging && quiet.model.hops == 1)
        #expect(quiet.bridge.calls.last { $0.hasPrefix("setPetInteractive") } == "setPetInteractive:false")
        // A later release is then nothing at all.
        quiet.model.mouseUp(local: PetRig.centre)
        #expect(quiet.calls("petClicked") == 0)

        // A move that arrives with the button already up.
        let late = PetRig()
        late.model.mouseDown(local: PetRig.centre, screen: petPoint(500, 500))
        late.model.mouseMoved(local: PetRig.centre, screen: petPoint(520, 500), primaryDown: true)
        late.model.mouseMoved(local: PetRig.centre, screen: petPoint(900, 500), primaryDown: false)
        #expect(late.calls("dragPet") == 1 && late.model.hops == 1)
        #expect(late.bridge.calls.last { $0.hasPrefix("setPetInteractive") } == "setPetInteractive:false")

        // Leaving the window with the button up.
        let left = PetRig()
        left.model.mouseDown(local: PetRig.centre, screen: petPoint(500, 500))
        left.model.mouseLeft(primaryDown: true)
        #expect(left.calls("setPetInteractive:false") == 0)
        left.model.mouseLeft(primaryDown: false)
        #expect(left.calls("setPetInteractive:false") == 1 && left.model.hops == 0)
    }

    @Test func droppedFilesAreEatenAndReported() {
        let rig = PetRig().pastHello()
        var dropped: [[String]] = []
        let watch = rig.events.droppedPaths.sink { dropped.append($0) }
        defer { watch.cancel() }
        rig.model.say(Line("Hi.", .shy))
        rig.model.dragEntered()
        rig.model.dragOver()
        #expect(rig.model.dropping && rig.model.mood == .excited && rig.model.bubbleContent == nil)
        #expect(rig.calls("setPetInteractive:true") == 1)
        rig.model.drop(["/tmp/a.pdf", "", "/tmp/b.pdf", "/tmp/c.pdf"])
        #expect(!rig.model.dropping && dropped == [["/tmp/a.pdf", "/tmp/b.pdf", "/tmp/c.pdf"]])
        #expect(rig.model.chat?.text == "3 of them! What’s the plan?")
        #expect(rig.calls("setPetInteractive:false") == 1)
        rig.advance(900)
        #expect(rig.model.chat?.text == "A proper feast. Thank you." && rig.model.bursts.last?.count == 16 && rig.model.hops == 1)

        let leaving = PetRig()
        leaving.model.dragEntered()
        leaving.model.dragOver()
        leaving.model.dragLeft()
        #expect(!leaving.model.dropping && leaving.calls("setPetInteractive:false") == 1)
        leaving.model.drop([])
        #expect(leaving.calls("reportDroppedPaths") == 0 && leaving.model.chat == nil)
    }

    @Test func undoPutsThingsBackAndSaysSo() async {
        let rig = PetRig().pastHello()
        var done = rig.task(.succeeded, line: "Done")
        done.summary = TaskSummary(headline: "Moved 3 files.", undoable: true)
        rig.events.taskUpdate.send(done)
        rig.bridge.undoReport.reversed = 3
        await rig.model.undo()
        let bubble = rig.model.bubbleContent
        #expect(bubble?.text == "Sorry. Moved 3 back where they were." && bubble?.buttons == [] && rig.model.mood == .oops)
        #expect(rig.model.task?.summary?.undoable == false)
        rig.advance(3500)
        #expect(rig.model.bubbleContent == nil && rig.model.undoNote == nil)
    }

    @Test func aFailedUndoSaysWhy() async {
        let rig = PetRig().pastHello()
        var done = rig.task(.succeeded, line: "Done")
        done.summary = TaskSummary(headline: "Moved 3 files.", undoable: true)
        rig.events.taskUpdate.send(done)
        rig.bridge.failure = "That file has changed since."
        await rig.model.undo()
        #expect(rig.model.bubbleContent?.text == "That file has changed since.")
        #expect(rig.model.task?.summary?.undoable == true)
    }

    @Test func aDueReminderCanBeDoneOrSnoozed() async {
        let rig = PetRig().pastHello()
        rig.bridge.brain = BrainSnapshot(items: [petReminder("r1", title: "Call the dentist", dueAt: rig.clock.now - 1000)])
        rig.events.brainChanged.send(rig.bridge.brain)
        #expect(rig.model.bubbleContent?.text == "Call the dentist" && rig.model.bubbleContent?.buttons == [.done, .snooze])
        await rig.model.alertAction(.done)
        await rig.model.alertAction(.snooze)
        #expect(rig.bridge.brainRequests.map { $0.stringify() } == [
            #"{"op":"complete","id":"r1"}"#, #"{"op":"snooze","id":"r1","minutes":10}"#
        ])
        rig.bridge.failure = "The workspace is locked."
        await rig.model.alertAction(.done)
        #expect(rig.model.bubbleContent?.text == "The workspace is locked." && rig.model.bubbleContent?.tone == .reminder)
        await rig.model.alertAction(.done)
        #expect(rig.model.alertError == nil)
    }

    @Test func aReminderBecomesDueAsTheClockTicks() {
        let rig = PetRig()
        rig.events.brainChanged.send(BrainSnapshot(items: [petReminder("r1", title: "Stand up", dueAt: rig.clock.now + 2500)]))
        rig.advance(1400 + 4200)
        #expect(rig.model.bubbleContent?.text == "Stand up")
    }

    @Test func aRingingTimerIsCancelledByDone() async {
        let rig = PetRig().pastHello()
        rig.events.brainChanged.send(BrainSnapshot(items: [petReminder("r1", title: "Call", dueAt: rig.clock.now - 1)], timer: petTimer("ringing")))
        #expect(rig.model.bubbleContent?.text == "Time’s up: Deep work." && rig.model.spriteTimer?.status == "ringing")
        await rig.model.alertAction(.done)
        #expect(rig.bridge.brainRequests.map { $0.stringify() } == [#"{"op":"timer","action":"cancel"}"#])
    }

    @Test func hoveringTheTimerSaysWhatItIsFor() {
        let rig = PetRig().pastHello()
        rig.events.brainChanged.send(BrainSnapshot(timer: petTimer("running", endsAt: rig.clock.now + 600_000)))
        #expect(rig.model.bubbleContent == nil)
        #expect(rig.model.spriteTimer?.remainingMs == 600_000 && rig.model.spriteTimer?.progress == 0.4)
        rig.model.mouseMoved(local: PetRig.centre, screen: petPoint(500, 500), primaryDown: false)
        #expect(rig.model.bubbleContent?.text == "Deep work · 10:00 left" && rig.model.bubbleContent?.tone == .peek)
        rig.advance(5000)
        #expect(rig.model.bubbleContent?.text == "Deep work · 09:55 left")
    }

    @Test func theBrainIsLoadedWhenItStarts() async {
        let rig = PetRig(start: false)
        rig.bridge.brain = BrainSnapshot(timer: petTimer("paused"))
        rig.model.start()
        await rig.settle()
        #expect(rig.model.brain.timer?.status == "paused" && rig.calls("getBrain") == 1)
    }

    @Test func playingFromTheMenu() {
        let rig = PetRig().pastHello()
        rig.events.petPlay.send(.dance)
        #expect(rig.model.dancing && rig.model.mood == .music && rig.model.chat?.text == "Hoof it!" && rig.model.bursts.last?.count == 16)
        rig.advance(2100)
        #expect(rig.model.bursts.last?.color == "#e1ff77" && rig.model.bursts.last?.count == 12)
        rig.advance(2200)
        #expect(!rig.model.dancing && rig.model.chat?.text == "Smooth as ever." && rig.model.hops == 1)
        rig.advance(3000)
        // Surprises come in turn; some bring sparks or hearts.
        var said: [String] = []
        for _ in 0..<8 { rig.events.petPlay.send(.surprise); said.append(rig.model.chat?.text ?? ""); rig.advance(1400) }
        #expect(said == Personality.surprises.map(\.text) + [Personality.surprises[0].text])
        #expect(rig.model.hops == 9)
    }

    @Test func surprisesBringTheirOwnBursts() {
        let rig = PetRig().pastHello()
        rig.events.petPlay.send(.surprise)
        rig.events.petPlay.send(.surprise)
        #expect(rig.model.bursts.isEmpty)
        rig.events.petPlay.send(.surprise)
        #expect(rig.model.bursts.last?.kind == .sparks && rig.model.bursts.last?.color == "#ffe066")
        rig.events.petPlay.send(.surprise)
        #expect(rig.model.bursts.last?.kind == .hearts && rig.model.bursts.last?.count == 7)
    }

    @Test func reducedMotionMeansNoHopsAndNoBursts() {
        let rig = PetRig()
        rig.model.reduceMotion = true
        for _ in 0..<3 { rig.click(); rig.advance(100) }
        rig.events.petPlay.send(.dance)
        #expect(rig.model.hops == 0 && rig.model.bursts.isEmpty && rig.model.chat != nil)
    }

    @Test func atMostFourBurstsAtOnce() {
        let rig = PetRig()
        for _ in 0..<6 { rig.events.petPlay.send(.dance) }
        #expect(rig.model.bursts.count == 4)
    }

    @Test func itSlidesInAndOutWhenTold() {
        let rig = PetRig()
        #expect(rig.model.presence == nil)
        rig.events.petPresence.send(true)
        #expect(rig.model.presence == .arriving)
        rig.events.petPresence.send(false)
        #expect(rig.model.presence == .leaving)
    }

    @Test func deletedHistoryClearsTheBubble() {
        let rig = PetRig().pastHello()
        rig.events.taskUpdate.send(rig.task(.succeeded, line: "Done"))
        rig.events.historyDeleted.send(["t1"])
        #expect(rig.model.bubbleContent == nil && rig.model.task == nil)
    }

    @Test func theEyesFollowTheCursor() {
        let rig = PetRig()
        rig.events.cursor.send(petPoint(70, 0))
        #expect(rig.model.look == Look(x: 0.5, y: 0))
        rig.events.cursor.send(petPoint(0, 0))
        #expect(rig.model.look == Look())
    }

    @Test func rightClickAsksForTheMenu() {
        let rig = PetRig()
        rig.model.contextMenu()
        #expect(rig.calls("showPetMenu") == 1)
    }

    @Test func aBubbleButtonFiresOnReleaseInsideIt() {
        let rig = PetRig().pastHello()
        rig.model.say(Line("Shall I sort out your Downloads?", .curious, action: .init(label: "Sure", compose: "Organize my Downloads folder")), 60_000)
        let button = petRect(180, 52, 44, 22)
        rig.model.layout(bubble: petRect(24, 34, 212, 56), buttons: [0: button])
        // Down and up on it.
        rig.model.mouseDown(local: petPoint(200, 60), screen: petPoint(600, 400))
        #expect(rig.model.pressedButton == 0 && rig.bridge.composed.isEmpty)
        // Sliding off lets go of it; back on takes it again.
        rig.model.mouseMoved(local: petPoint(100, 60), screen: petPoint(500, 400), primaryDown: true)
        #expect(rig.model.pressedButton == nil)
        rig.model.mouseMoved(local: petPoint(200, 60), screen: petPoint(600, 400), primaryDown: true)
        #expect(rig.model.pressedButton == 0)
        rig.model.mouseUp(local: petPoint(200, 60))
        #expect(rig.model.pressedButton == nil && rig.bridge.composed == ["Organize my Downloads folder"])
        #expect(rig.calls("petClicked") == 0 && rig.calls("dragPet") == 0)
        // Released somewhere else: nothing.
        rig.model.say(Line("Again?", .curious, action: .init(label: "Sure", compose: "x")), 60_000)
        rig.model.mouseDown(local: petPoint(200, 60), screen: petPoint(600, 400))
        rig.model.mouseUp(local: petPoint(60, 60))
        #expect(rig.bridge.composed.count == 1)
    }

    @Test func everyClickInTheWindowReachesTheCatcher() {
        let rig = PetRig()
        rig.model.say(Line("Shall I sort out your Downloads?", .curious, action: .init(label: "Sure", compose: "x")), 60_000)
        // The creature, the empty air beside it, the bubble's lettering and its button.
        for point in [petPoint(130, 140), petPoint(10, 180), petPoint(60, 60), petPoint(213, 63)] {
            #expect(petViewUnder(rig.model, point) == "catcher")
        }
    }
}

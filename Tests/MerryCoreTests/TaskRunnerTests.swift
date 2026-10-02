import Testing
@testable import MerryCore

// The loop, driven by a scripted planner through the real runner, the real
// tools and the real filesystem, in a scratch folder.

@Test func aSumIsAnsweredWithoutAnyModel() async throws {
    let bench = try RunnerBench()
    let planner = ForbiddenPlanner()
    let done = await bench.make(bench.task("12 * (3 + 4)"), bench.deps(planner: planner)).run()
    #expect(done.status == .succeeded)
    #expect(done.summary?.headline == "12 * (3 + 4) = 84")
    #expect(planner.timesAsked == 0 && done.cost.usd == 0)
}

@Test func aFullOrganiseRunMovesVerifiesAndRecordsUndo() async throws {
    let bench = try RunnerBench(answers: [RunnerBench.option("approve")])
    bench.write("a.pdf"); bench.write("b.pdf"); bench.write("keep.txt")
    let r = bench.root
    let planner = StepPlanner([
        StepPlanner.call("report_progress", ["line": "Looking"]),
        StepPlanner.call("files_list", ["path": .string(r)]),
        StepPlanner.call("show_preview", ["title": "Move PDFs", "fileOps": [
            ["from": .string("\(r)/a.pdf"), "to": .string("\(r)/Docs/a.pdf"), "kind": "move"],
            ["from": .string("\(r)/b.pdf"), "to": .string("\(r)/Docs/b.pdf"), "kind": "move"]
        ]]),
        StepPlanner.call("files_create_folder", ["path": .string("\(r)/Docs")]),
        StepPlanner.calls([
            ("files_move", ["from": .string("\(r)/a.pdf"), "to": .string("\(r)/Docs/a.pdf")]),
            ("files_move", ["from": .string("\(r)/b.pdf"), "to": .string("\(r)/Docs/b.pdf")])
        ]),
        StepPlanner.finish("Moved 2 files into Docs")
    ])
    let runner = bench.make(bench.task("put the pdfs in a Docs folder using the planner please now"), bench.deps(planner: planner) { $0.workflowsEnabled = false })
    let done = await runner.run()

    #expect(done.status == .succeeded, "\(done.error ?? "") \(planner.allResults.map(\.content))")
    #expect(done.summary?.headline == "Moved 2 files into Docs")
    #expect(bench.exists("Docs/a.pdf") && bench.exists("Docs/b.pdf") && bench.exists("keep.txt") && !bench.exists("a.pdf"))
    let moves = done.actions.filter { $0.tool == "files_move" }
    #expect(moves.count == 2 && moves.allSatisfy { $0.verification?.verified == true })
    #expect(runner.undoEntries.count == 3)
    #expect(done.summary?.undoable == true)
    #expect(done.cost.calls == 6)
}

@Test func aRejectedPreviewIsEnforcedInCode() async throws {
    let bench = try RunnerBench(answers: [RunnerBench.option("reject")])
    bench.write("a.pdf")
    let r = bench.root
    // The model ignores the refusal and tries the move anyway.
    let planner = StepPlanner([
        StepPlanner.call("show_preview", ["title": "Move", "fileOps": [["from": .string("\(r)/a.pdf"), "to": .string("\(r)/Docs/a.pdf"), "kind": "move"]]]),
        StepPlanner.call("files_move", ["from": .string("\(r)/a.pdf"), "to": .string("\(r)/Docs/a.pdf")]),
        StepPlanner.finish("Nothing moved", success: false)
    ])
    let done = await bench.make(bench.task("move it with the planner please right now"), bench.deps(planner: planner) { $0.workflowsEnabled = false }).run()
    #expect(bench.exists("a.pdf") && !bench.exists("Docs/a.pdf"))
    #expect(planner.allResults.contains { $0.isError && $0.content.contains("the user declined moving a.pdf") })
    #expect(!done.actions.contains { $0.tool == "files_move" })
}

@Test func workOutsideTheGrantAsksAndProceedsOnlyWhenAllowed() async throws {
    for (answer, moved) in [("allow", true), ("deny", false)] {
        let bench = try RunnerBench(answers: [RunnerBench.option(answer)])
        bench.write("in/a.txt"); bench.write("out/.keep")
        let r = bench.root
        let planner = StepPlanner([
            StepPlanner.call("files_move", ["from": .string("\(r)/in/a.txt"), "to": .string("\(r)/out/a.txt")]),
            StepPlanner.finish("Done")
        ])
        let done = await bench.make(bench.task("move a with the planner please right now", allow: false), bench.deps(planner: planner) { $0.workflowsEnabled = false }).run()
        #expect(bench.askedQuestions.first?.reason == .authorization)
        #expect(bench.exists("out/a.txt") == moved, "answer \(answer)")
        if !moved { #expect(planner.allResults.first?.content.contains("declined to authorize") == true) }
        #expect(done.status == .succeeded)
    }
}

@Test func aProtectedPathIsRefusedWithoutAsking() async throws {
    let bench = try RunnerBench()
    let planner = StepPlanner([
        StepPlanner.call("files_create_folder", ["path": "/System/Library/Merry"]),
        StepPlanner.finish("Blocked", success: false)
    ])
    _ = await bench.make(bench.task("make a folder there with the planner please now"), bench.deps(planner: planner) { $0.workflowsEnabled = false }).run()
    #expect(bench.askedQuestions.isEmpty)
    #expect(planner.allResults.first?.content.hasPrefix("Refused: ") == true)
}

@Test func badInputAndUnknownToolsDoNotRunOrCrash() async throws {
    let bench = try RunnerBench()
    let planner = StepPlanner([
        StepPlanner.call("files_move", ["from": 12]),
        StepPlanner.call("files_teleport", [:]),
        StepPlanner.finish("Could not", success: false)
    ])
    let done = await bench.make(bench.task("do something odd with the planner right now"), bench.deps(planner: planner) { $0.workflowsEnabled = false }).run()
    let results = planner.allResults
    #expect(results[0].isError && results[0].content.hasPrefix("Invalid input for files_move: "))
    #expect(results[1].content == "No tool named \"files_teleport\" is available for this task.")
    #expect(done.status == .failed && done.actions.filter { $0.tool != "finish" }.isEmpty)
}

@Test func stepAndSpendingLimitsEndTheTaskWithAReason() async throws {
    let bench = try RunnerBench()
    let steps = await bench.make(bench.task("keep going with the planner for a long time", limits: TaskLimits(maxSteps: 4)), bench.deps(planner: StepPlanner([])) { $0.workflowsEnabled = false }).run()
    #expect(steps.status == .failed && steps.summary?.headline == "Reached the 4-step limit for one task without finishing.")

    let spend = await bench.make(bench.task("keep going with the planner for a long time", limits: TaskLimits(maxUsd: 0.025)), bench.deps(planner: StepPlanner([])) { $0.workflowsEnabled = false }).run()
    #expect(spend.status == .failed && spend.summary?.headline == "Reached the $0.03 spending limit for one task." || spend.summary?.headline == "Reached the $0.02 spending limit for one task.")
}

@Test func cancellingMidTaskStopsBeforeTheNextAction() async throws {
    let bench = try RunnerBench()
    bench.write("a.txt"); bench.write("b.txt"); bench.write("moved/.keep")
    let r = bench.root
    let planner = StepPlanner([
        StepPlanner.call("files_move", ["from": .string("\(r)/a.txt"), "to": .string("\(r)/moved/a.txt")]),
        StepPlanner.call("files_move", ["from": .string("\(r)/b.txt"), "to": .string("\(r)/moved/b.txt")]),
        StepPlanner.finish("Done")
    ])
    let box = RunnerBox()
    planner.onPropose = { index in if index == 2 { box.runner?.cancel() } }
    let runner = bench.make(bench.task("move both with the planner please right now"), bench.deps(planner: planner) { $0.workflowsEnabled = false })
    box.runner = runner
    let done = await runner.run()
    #expect(done.status == .cancelled && done.summary?.headline == "Stopped before finishing")
    #expect(bench.exists("moved/a.txt") && bench.exists("b.txt") && !bench.exists("moved/b.txt"))
    // What did happen is still undoable.
    #expect(done.summary?.undoable == true && !runner.undoEntries.isEmpty)
}

@Test func aProseReplyIsTheAnswerAndNarrationIsSentBackOnce() async throws {
    let bench = try RunnerBench()
    let planner = StepPlanner([StepPlanner.say("Answering directly, no actions needed."), StepPlanner.say("Yes, it is on Friday.")])
    let done = await bench.make(bench.task("is the offsite this week or the next one"), bench.deps(planner: planner) { $0.workflowsEnabled = false }).run()
    #expect(done.status == .succeeded && done.summary?.headline == "Yes, it is on Friday.")
    #expect(planner.allNotes.contains { $0.hasPrefix("That describes what you are doing") })
}

@Test func aRefusalEndsTheTaskInsteadOfBurningSteps() async throws {
    let bench = try RunnerBench()
    let planner = StepPlanner([PlannerProposal(stopReason: "refusal", refusal: "cyber")])
    let done = await bench.make(bench.task("do the thing the model will not do today"), bench.deps(planner: planner) { $0.workflowsEnabled = false }).run()
    #expect(done.status == .failed && done.summary?.headline == "The model declined to help with this one")
    #expect(planner.proposalCount == 1)
}

// Planner-free workflows: real files, no Jev, and a planner that fails the test if it is ever asked.

@Test func aFolderIsOrganisedByTypeWithoutThePlanner() async throws {
    let bench = try RunnerBench(answers: [RunnerBench.option("approve")])
    for name in ["report.pdf", "notes.txt", "photo.png", "shot.jpg", "sums.xlsx"] { bench.write("inbox/\(name)") }
    let folder = "\(bench.root)/inbox"
    let planner = ForbiddenPlanner()
    let done = await bench.make(bench.task("organize this folder"), bench.deps(planner: planner, dropped: [folder])).run()
    #expect(done.status == .succeeded, "\(done.error ?? "") \(done.summary?.headline ?? "")")
    #expect(done.summary?.headline == "Sorted 5 files into 3 folders.")
    #expect(bench.exists("inbox/Documents/report.pdf") && bench.exists("inbox/Images/photo.png") && bench.exists("inbox/Spreadsheets/sums.xlsx"))
    #expect(planner.timesAsked == 0 && done.cost.usd == 0)
    #expect(bench.askedQuestions.first?.preview?.fileOps?.count == 5)
}

@Test func cancellingTheWorkflowPreviewMovesNothing() async throws {
    let bench = try RunnerBench(answers: [RunnerBench.option("reject")])
    for name in ["report.pdf", "photo.png"] { bench.write("inbox/\(name)") }
    let done = await bench.make(bench.task("organize this folder"), bench.deps(planner: ForbiddenPlanner(), dropped: ["\(bench.root)/inbox"])).run()
    #expect(done.status == .failed && done.summary?.headline == "Cancelled. Nothing was moved.")
    #expect(bench.exists("inbox/report.pdf") && !bench.exists("inbox/Documents"))
}

@Test func renamingAppliesTheSchemeAndVerifiesEachRename() async throws {
    let bench = try RunnerBench(answers: [RunnerBench.option("approve")])
    // Nothing dropped: the folder the task is already allowed in is the one meant.
    for name in ["Quarterly Report FINAL.pdf", "meetingNotes.TXT", "already-fine.md"] { bench.write(name) }
    let done = await bench.make(bench.task("rename these files consistently"), bench.deps(planner: ForbiddenPlanner())).run()
    #expect(done.summary?.headline == "Renamed 2 files to the \"kebab\" pattern.", "\(done.summary?.headline ?? "") \(done.error ?? "")")
    #expect(bench.exists("quarterly-report-final.pdf") && bench.exists("meeting-notes.txt") && bench.exists("already-fine.md"))
    #expect(done.actions.filter { $0.tool == "files_rename" }.allSatisfy { $0.verification?.verified == true })
}

@Test func withNoModelAtAllAnOpenEndedRequestSaysWhatMerryCanDo() async throws {
    let bench = try RunnerBench()
    let done = await bench.make(bench.task("write me a poem about the sea and the stars"), bench.deps(planner: nil)).run()
    #expect(done.status == .failed)
    #expect(done.summary?.headline.contains("organising a folder, finding a file, or renaming files consistently") == true)
}

@Test func memoryIsToldListedAndForgottenWithoutAModel() async throws {
    let bench = try RunnerBench()
    let events = MemoryEventLog()
    func run(_ request: String, _ memories: [Memory]) async -> TaskState {
        var deps = bench.deps(planner: ForbiddenPlanner()) { $0.memoryEnabled = true; $0.memoryLearn = true; $0.memories = memories }
        deps.workflowsEnabled = true
        let runner = TaskRunner(task: bench.task(request), deps: deps, hooks: RunnerHooks(onMemory: { events.add($0) }))
        return await runner.run()
    }
    let told = await run("remember that my manager is Priya", [])
    #expect(told.summary?.headline == "Got it. I'll remember that.")
    guard case .save(let memory, _)? = events.all.first else { Issue.record("nothing was saved"); return }
    #expect(memory.source == "told")

    let secret = await run("remember that my password is hunter2-AbC9", [])
    #expect(secret.status == .failed && secret.summary?.headline.hasPrefix("I don't keep ") == true)

    let listed = await run("what do you remember about me", [memory])
    #expect(listed.summary?.headline == "I remember 1 thing. Say \"forget …\" to drop one.")

    let forgotten = await run("forget that my manager is Priya", [memory])
    #expect(forgotten.summary?.headline == "Forgotten.")
    #expect(events.all.contains { if case .forget(let ids) = $0 { return ids == [memory.id] }; return false })
}

final class MemoryEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MemoryEvent] = []
    func add(_ event: MemoryEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [MemoryEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

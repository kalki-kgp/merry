import Testing
@testable import MerryCore

/// Runs one recorded call against the Swift store and returns what the
/// reference would have returned, as JSON.
private func perform(_ store: Store, _ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "saveTask":
        try store.saveTask(try args["task"]!.decode(TaskState.self)); return .null
    case "getTask":
        return try store.getTask(args.str("id")).map { JSON.encode($0) } ?? .null
    case "isDeleted":
        return .bool(store.isDeleted(args.str("id")))
    case "deleteTask":
        try store.deleteTask(args.str("id")); return .null
    case "conversationOf":
        return .array(try store.conversationOf(args.str("id")).map { JSON.encode($0) })
    case "deleteConversation":
        return JSON(try store.deleteConversation(args.str("id")))
    case "clearHistory":
        return JSON(try store.clearHistory())
    case "listTasks":
        return JSON.encode(try args.optInt("limit").map { try store.listTasks(limit: $0) } ?? store.listTasks())
    case "undoableActions":
        return .array(try store.undoableActions(args.str("taskId")).map { ["id": .string($0.id), "undo": JSON.encode($0.undo)] })
    case "markReversed":
        try store.markReversed(args.str("actionId")); return .null
    case "appendLog":
        // Built by hand: data that is null is still data, which decoding an optional cannot tell from none.
        let e = args["entry"]!
        try store.appendLog(LogEntry(taskId: e.str("taskId"), at: e.num("at"), level: LogEntry.Level(rawValue: e.str("level"))!, source: e.str("source"), message: e.str("message"), data: e["data"]))
        return .null
    case "getLogs":
        return JSON.encode(try args.optInt("limit").map { try store.getLogs(args.str("taskId"), limit: $0) } ?? store.getLogs(args.str("taskId")))
    case "listMemories":
        return JSON.encode(try store.listMemories())
    case "saveMemory":
        try store.saveMemory(try args["memory"]!.decode(Memory.self), replaces: args.optStr("replaces")); return .null
    case "deleteMemories":
        try store.deleteMemories(args.strings("ids")); return .null
    case "clearMemories":
        try store.clearMemories(); return .null
    case "markMemoriesUsed":
        try store.markMemoriesUsed(args.strings("ids"), now: args.num("now")); return .null
    case "getSetting":
        return JSON(try store.getSetting(args.str("key")))
    case "setSetting":
        try store.setSetting(args.str("key"), args.str("value")); return .null
    case "recoverInterruptedTasks":
        return JSON(try store.recoverInterruptedTasks())
    default:
        throw MerryError("unknown step \(op)")
    }
}

private func replay(_ store: Store) {
    let steps = Fixture.load("store").list("steps")
    #expect(steps.count > 140)
    for (index, step) in steps.enumerated() {
        let op = step.str("op")
        let label = "step \(index) \(op) \(step["args"]?.stringify().prefix(120) ?? "")"
        do {
            let got = try perform(store, op, step["args"] ?? .null)
            if let expected = step["result"] {
                #expect(got.firstDifference(from: expected) == nil, "\(label)")
            } else {
                Issue.record("\(label) should fail with \(step.str("error"))")
            }
        } catch {
            #expect(step.optStr("error") == messageOf(error), "\(label)")
        }
    }
}

/// Replays the session recorded from the reference Store.
@Test func storeMatchesTheOriginalOnDisk() throws {
    let dir = Scratch.directory("store")
    defer { Scratch.remove(dir) }
    let store = try Store(directory: Path.join(dir, "nested", "data"))
    defer { store.close() }
    replay(store)
    #expect(Scratch.exists(Path.join(dir, "nested", "data", "merry.db")))
}

@Test func storeMatchesTheOriginalInMemory() throws {
    let store = try Store.inMemory()
    defer { store.close() }
    replay(store)
}

private func sampleTask(_ id: String, status: TaskStatus = .succeeded, at: Double = 1000) -> TaskState {
    var task = TaskState(id: id, request: "Request \(id)", now: at)
    task.status = status
    return task
}

@Test func everyTaskFieldSurvivesStorage() throws {
    let store = try Store.inMemory()
    defer { store.close() }
    var task = TaskState(id: "full", request: "Do “everything” / 最終 😀", authorization: Authorization(readRoots: ["/a"], writeRoots: ["/b"], apps: ["Notes"], origins: ["*"], capabilities: ["files.read"]), limits: TaskLimits(maxSteps: 7, maxWallClockMs: 1234, maxUsd: 0.25, maxConsecutiveFailures: 2), now: 1790000000123)
    task.outcome = "An outcome"
    task.status = .awaitingUser
    task.petState = .waiting
    task.observations = [Observation(id: "o", kind: "page", summary: "Saw it", data: ["url": "https://example.com/a/b", "n": 1.25, "list": [1, nil, true, "x"], "deep": ["k": ["v": []]]], observedAt: 5, staleAfterMs: 6)]
    task.plan = try JSON.parse(#"[{"id":"p1","description":"First","status":"done"}]"#).decode([PlanStep].self)
    var action = ActionRecord(id: "act", step: 3, tool: "files_move", input: ["from": "/x", "to": "/y"], startedAt: 10, outcome: .uncertain)
    action.finishedAt = 11
    action.result = ["moved": 1, "note": nil]
    action.error = "half"
    action.verification = VerificationResult(verified: false, method: "stat", detail: "missing")
    action.undo = UndoEntry(kind: .fileRename, from: "/x", to: "/y")
    task.actions = [action, ActionRecord(id: "act2", step: 4, tool: "user_ask", input: .null, startedAt: 12, outcome: .failure)]
    task.cost = CostRecord(inputTokens: 10, outputTokens: 20, usd: 0.1 + 0.2, calls: 3)
    task.completionCriteria = ["a", "b"]
    task.statusLine = "Waiting"
    task.updatedAt = 1790000000999
    task.replyTo = "earlier"
    task.conversationId = "earlier"
    task.question = UserQuestion(id: "q", reason: .authorization, prompt: "May I?", options: [QuestionOption(id: "y", label: "Yes", detail: "Go on"), QuestionOption(id: "n", label: "No")], preview: PreviewPayload(title: "Moves", fileOps: [FileOp(from: "/x", to: "/y", kind: "move")], note: "Careful"), allowFreeText: true)
    task.summary = TaskSummary(headline: "So far", evidence: [.path("Folder", "/y"), .url("Page", "https://example.com"), .text("Note", "n")], undoable: true)
    task.error = "An error"
    task.droppedPaths = ["/dropped/one"]
    task.route = "mixed"

    try store.saveTask(task)
    let back = try #require(try store.getTask("full"))
    #expect(JSON.encode(back).firstDifference(from: JSON.encode(task)) == nil)
    #expect(JSON.encode(back).objectValue?.count == 22)
    #expect(back.cost.usd == 0.1 + 0.2)
    #expect(try store.undoableActions("full").map(\.undo) == [UndoEntry(kind: .fileRename, from: "/x", to: "/y")])
    #expect(try store.listTasks() == [TaskSummaryRow(id: "full", request: task.request, status: .awaitingUser, headline: "So far", createdAt: 1790000000123, undoable: true, turns: 1)])
}

@Test func storeKeepsItsDataBetweenRuns() throws {
    let dir = Scratch.directory("store")
    defer { Scratch.remove(dir) }
    var store = try Store(directory: dir)
    var task = sampleTask("t", status: .executing)
    var action = ActionRecord(id: "a", step: 1, tool: "files_move", input: [:], startedAt: 5, outcome: .success)
    action.undo = UndoEntry(kind: .fileMove, from: "/from", to: "/to")
    task.actions = [action]
    try store.saveTask(task)
    try store.setSetting("k", "v")
    try store.appendLog(LogEntry(taskId: "t", at: 1, level: .info, source: "loop", message: "hello"))
    try store.saveMemory(Memory(id: "m", text: "A fact", kind: "fact", keys: ["a"], source: "told", evidence: 1, createdAt: 1, updatedAt: 1))
    store.close()

    // A second launch finds the task still running: it crashed, so it is recorded as interrupted.
    store = try Store(directory: dir)
    defer { store.close() }
    #expect(try store.getSetting("k") == "v")
    #expect(try store.getLogs("t").map(\.message) == ["hello"])
    #expect(try store.listMemories().map(\.id) == ["m"])
    #expect(try store.recoverInterruptedTasks() == ["t"])
    let recovered = try #require(try store.getTask("t"))
    #expect(recovered.status == .failed)
    #expect(recovered.error == "Merry quit while this task was running. Nothing was resumed automatically.")
    #expect(recovered.statusLine == "Interrupted")
    #expect(recovered.summary == TaskSummary(headline: "Interrupted when Merry quit", evidence: [], undoable: true))
    // The undo record written before the crash is still usable.
    #expect(try store.undoableActions("t").map(\.id) == ["a"])
}

@Test func storeUsesTheSamePragmasAndSchema() throws {
    let dir = Scratch.directory("store")
    defer { Scratch.remove(dir) }
    let store = try Store(directory: dir)
    store.close()
    let db = try SQLiteDatabase(path: Path.join(dir, "merry.db"))
    defer { db.close() }
    #expect(try db.get("PRAGMA journal_mode")?[0] == .text("wal"))
    let tables = try db.all("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").compactMap { $0[0].string }
    #expect(tables == ["actions", "logs", "memories", "settings", "tasks"])
    let indexes = try db.all("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name").compactMap { $0[0].string }
    #expect(indexes == ["actions_task", "logs_task", "tasks_conversation"])
    #expect(try db.all("PRAGMA table_info(tasks)").compactMap { $0[1].string } == ["id", "request", "status", "headline", "created_at", "updated_at", "state_json", "conversation_id"])
}

@Test func olderDatabasesGainTheConversationColumn() throws {
    let dir = Scratch.directory("store")
    defer { Scratch.remove(dir) }
    let old = sampleTask("old", at: 500)
    do {
        let db = try SQLiteDatabase(path: Path.join(dir, "merry.db"))
        try db.exec("CREATE TABLE tasks (id TEXT PRIMARY KEY, request TEXT NOT NULL, status TEXT NOT NULL, headline TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, state_json TEXT NOT NULL)")
        try db.run("INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?)", [.text("old"), .text(old.request), .text("succeeded"), .null, .number(500), .number(500), .text(try StoredJSON.encode(old))])
        db.close()
    }
    let store = try Store(directory: dir)
    defer { store.close() }
    // Rows from before chats existed are each a chat of their own.
    #expect(try store.conversationOf("old").map(\.id) == ["old"])
    #expect(try store.listTasks().map(\.turns) == [1])
    var reply = sampleTask("reply", at: 900)
    reply.conversationId = "old"
    try store.saveTask(reply)
    #expect(try store.listTasks() == [TaskSummaryRow(id: "reply", request: "Request old", status: .succeeded, headline: "", createdAt: 900, undoable: false, turns: 2)])
}

@Test func storeIsSafeToUseFromSeveralThreads() async throws {
    let store = try Store.inMemory()
    defer { store.close() }
    await withTaskGroup(of: Void.self) { group in
        for worker in 0..<8 {
            group.addTask {
                for i in 0..<40 {
                    let id = "w\(worker)-\(i)"
                    try? store.saveTask(sampleTask(id, at: Double(worker * 1000 + i)))
                    try? store.appendLog(LogEntry(taskId: id, at: 1, level: .debug, source: "test", message: "m"))
                    try? store.setSetting("k\(worker)", "\(i)")
                    _ = try? store.listTasks(limit: 5)
                    _ = try? store.getTask(id)
                }
            }
        }
    }
    #expect(try store.listTasks(limit: 1000).count == 320)
    #expect(try store.clearHistory().count == 320)
    #expect(try store.listTasks().isEmpty)
}

@Test func sqliteWrapperBindsAndReadsEveryType() throws {
    let db = try SQLiteDatabase(path: ":memory:")
    defer { db.close() }
    try db.exec("CREATE TABLE t (i INTEGER, r REAL, s TEXT, n TEXT)")
    let text = "quote ' and \"double\" — 😀\nline\u{0}after nul"
    try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.integer(9007199254740993), .real(1.5), .text(text), .null])
    #expect(try db.get("SELECT i, r, s, n FROM t") == [.integer(9007199254740993), .real(1.5), .text(text), .null])
    // A whole JavaScript number lands in an INTEGER column as an integer.
    try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.number(42), .number(42), .text(""), .text("x")])
    #expect(try db.all("SELECT typeof(i), typeof(r), s FROM t WHERE n = 'x'") == [[.text("integer"), .text("real"), .text("")]])
    #expect(throws: SQLiteError.self) { try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.null]) }
    #expect(throws: SQLiteError.self) { try db.exec("NOT SQL") }
    // A failed transaction leaves nothing behind.
    #expect(throws: MerryError.self) {
        try db.transaction {
            try db.run("DELETE FROM t")
            throw MerryError("stop")
        }
    }
    #expect(try db.get("SELECT COUNT(*) FROM t")?[0].int == 2)
    let statement = try db.prepare("SELECT COUNT(*) FROM t WHERE s = ?")
    #expect(try statement.all([.text("")]) == [[.integer(1)]])
    #expect(try statement.all([.text(text)]) == [[.integer(1)]])
    db.close()
    #expect(throws: SQLiteError.self) { try statement.all([.text("")]) }
    #expect(throws: SQLiteError.self) { try db.exec("SELECT 1") }
}

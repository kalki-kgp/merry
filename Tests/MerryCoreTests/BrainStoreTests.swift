import Testing
@testable import MerryCore

/// Replays the session recorded from the reference BrainStore: every snapshot
/// and every error message has to come out the same.
@Test func brainStoreMatchesTheOriginal() throws {
    LocalTime.use(timeZone: "Asia/Kolkata")
    let fixture = Fixture.load("brain-store")
    let dir = Scratch.directory("brain")
    defer { Scratch.remove(dir) }
    let ids = IdSequence()
    let store = try BrainStore(directory: dir, newId: { ids.next() })
    defer { store.close() }

    let steps = fixture.list("steps")
    #expect(steps.count > 200)
    for (index, step) in steps.enumerated() {
        let op = step.str("op")
        let now = step.num("now")
        let label = "step \(index) \(op) \(step["raw"]?.stringify().prefix(160) ?? "")"
        switch op {
        case "snapshot":
            #expect(JSON.encode(store.snapshot()).firstDifference(from: step["result"]!) == nil, "\(label)")
        case "hasDue":
            #expect(store.hasDue(now: now) == step.flag("result"), "\(label)")
        case "tick":
            let (state, alerts) = store.tick(now: now)
            let got: JSON = ["state": JSON.encode(state), "alerts": JSON.encode(alerts)]
            #expect(got.firstDifference(from: step["result"]!) == nil, "\(label)")
        case "request":
            do {
                let snapshot = try store.request(step["raw"] ?? .null, now: now)
                if let expected = step["result"] {
                    #expect(JSON.encode(snapshot).firstDifference(from: expected) == nil, "\(label)")
                } else {
                    Issue.record("\(label) should fail with \(step.optStr("error") ?? "a schema error")")
                }
            } catch let error as SchemaError {
                #expect(step.flag("invalid"), "\(label) was refused by the schema: \(error)")
            } catch {
                #expect(step.optStr("error") == messageOf(error), "\(label)")
            }
        default:
            Issue.record("unknown step \(op)")
        }
    }
    #expect(ids.count == fixture.int("ids"))
}

@Test func brainStoreKeepsWhatItWasGivenAcrossRestarts() throws {
    let dir = Scratch.directory("brain")
    defer { Scratch.remove(dir) }
    let ids = IdSequence()
    var store = try BrainStore(directory: dir, newId: { ids.next() })
    try store.request(["op": "create", "item": ["kind": "reminder", "title": "Stand up", "dueAt": 5000]], now: 1000)
    try store.request(["op": "timer", "action": "start", "minutes": 1], now: 1000)
    #expect(store.tick(now: 5000).alerts == [BrainAlert(id: "id-1", title: "Stand up", timer: false)])
    store.close()

    // The claim was written down, so a restart does not announce it again.
    store = try BrainStore(directory: dir, newId: { ids.next() })
    defer { store.close() }
    #expect(Scratch.exists(Path.join(dir, "brain.db")))
    let state = store.snapshot()
    #expect(state.items.map(\.title) == ["Stand up"])
    #expect(state.items.first?.notifiedAt == 5000)
    #expect(state.timer?.endsAt == 61000)
    #expect(!store.hasDue(now: 6000))
    #expect(store.tick(now: 6000).alerts.isEmpty)
    #expect(store.hasDue(now: 61000))
    #expect(store.tick(now: 61000).alerts == [BrainAlert(id: "id-2", title: "Focus time", timer: true)])
}

@Test func brainRowsAreStoredWithExplicitNulls() throws {
    let dir = Scratch.directory("brain")
    defer { Scratch.remove(dir) }
    let store = try BrainStore(directory: dir, newId: { "only" })
    try store.request(["op": "create", "item": ["kind": "note", "title": "Plain"]], now: 1000)
    store.close()

    // The pending-items index and the due query read these fields with json_extract.
    let db = try SQLiteDatabase(path: Path.join(dir, "brain.db"))
    defer { db.close() }
    let row = try #require(try db.get("SELECT data, json_type(data, '$.dueAt'), json_type(data, '$.notifiedAt'), json_type(data, '$.acknowledgedAt'), json_type(data, '$.projectId'), json_extract(data, '$.status') FROM items WHERE id = ?", [.text("only")]))
    #expect(row[1...4].allSatisfy { $0 == .text("null") })
    #expect(row[5] == .text("open"))
    let stored = try JSON.parse(row[0].string ?? "")
    #expect(stored.objectValue?.keys.sorted() == ["acknowledgedAt", "body", "checks", "createdAt", "dueAt", "estimateMinutes", "id", "kind", "notifiedAt", "projectId", "repeat", "sources", "status", "title", "updatedAt"])
}

@Test func inMemoryBrainStoreWorks() throws {
    let store = try BrainStore.inMemory(newId: { "x" })
    defer { store.close() }
    #expect(store.snapshot() == BrainSnapshot())
    let after = try store.request(["op": "create", "item": ["kind": "task", "title": "One"]], now: 10)
    #expect(after.items.map(\.id) == ["x"])
    #expect(throws: SchemaError.self) { try store.request(["op": "nope"]) }
}

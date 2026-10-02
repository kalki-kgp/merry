import Foundation

/// A reminder or timer whose moment has come and that should be announced once.
public struct BrainAlert: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var timer: Bool
    public init(id: String, title: String, timer: Bool) { self.id = id; self.title = title; self.timer = timer }
}

/// Main-process ownership keeps reminders alive when a model or runtime stops.
public final class BrainStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let makeId: @Sendable () -> String
    private let lock = NSRecursiveLock()

    /// Opens `brain.db` in the data folder, creating both if needed.
    public convenience init(directory: String, newId makeId: @escaping @Sendable () -> String = { newId() }) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try self.init(path: Path.join(directory, "brain.db"), makeId: makeId)
    }

    /// A private database that lives only as long as the store, for tests.
    public static func inMemory(newId makeId: @escaping @Sendable () -> String = { newId() }) throws -> BrainStore {
        try BrainStore(path: ":memory:", makeId: makeId)
    }

    private init(path: String, makeId: @escaping @Sendable () -> String) throws {
        self.makeId = makeId
        db = try SQLiteDatabase(path: path)
        try db.exec("""
            PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;
                  CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, data TEXT NOT NULL);
                  CREATE INDEX IF NOT EXISTS pending_items ON items(json_extract(data, '$.dueAt'))
                    WHERE json_extract(data, '$.status')='open' AND json_extract(data, '$.notifiedAt') IS NULL AND json_extract(data, '$.acknowledgedAt') IS NULL;
                  CREATE TABLE IF NOT EXISTS timer (id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL);
            """)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func read() throws -> BrainSnapshot {
        let items = try db.all("SELECT data FROM items").map { try StoredJSON.decode(BrainItem.self, from: $0[0].string ?? "") }
        let timer = try db.get("SELECT data FROM timer WHERE id=1").map { try StoredJSON.decode(BrainTimer.self, from: $0[0].string ?? "") }
        // Newest change first; items changed at the same moment keep their stored order.
        let sorted = items.enumerated().sorted { a, b in
            a.element.updatedAt != b.element.updatedAt ? a.element.updatedAt > b.element.updatedAt : a.offset < b.offset
        }.map(\.element)
        return BrainSnapshot(items: sorted, timer: timer)
    }

    /// Everything kept, newest change first. An unreadable database reads as empty.
    public func snapshot() -> BrainSnapshot {
        locked { (try? read()) ?? BrainSnapshot() }
    }

    private func save(_ item: BrainItem) throws {
        try db.run("INSERT INTO items VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", [.text(item.id), .text(try StoredJSON.encode(item))])
    }

    private func saveTimer(_ timer: BrainTimer?) throws {
        if let timer {
            try db.run("INSERT INTO timer VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", [.text(try StoredJSON.encode(timer))])
        } else {
            try db.exec("DELETE FROM timer")
        }
    }

    private func validate(_ item: BrainItem, _ state: BrainSnapshot) throws {
        let projectId = item.projectId ?? ""
        if !projectId.isEmpty && !state.items.contains(where: { $0.id == projectId && $0.kind == "project" }) { throw MerryError("Choose an existing project.") }
        if item.kind == "project" && !projectId.isEmpty { throw MerryError("Projects cannot be nested.") }
        if item.repeat != "none" && item.dueAt == nil { throw MerryError("A repeating reminder needs a due time.") }
        for source in item.sources {
            if source.kind == "url" { _ = try externalWebUrl(source.value) }
            else if !Path.isAbsolute(source.value) { throw MerryError("Saved files need an absolute path.") }
        }
    }

    /// Carries out one request and returns what is kept afterwards (or, for
    /// `list`, the matching part of it). Throws `SchemaError` for a malformed
    /// request and `MerryError` with the reference's wording for a refused one.
    @discardableResult
    public func request(_ raw: JSON, now: Double = nowMs()) throws -> BrainSnapshot {
        try locked {
            let req = try BrainSchema.request.parse(raw)
            let state = try read()
            let op = req.str("op")
            if op == "list" {
                let words = req.optStr("query").map { Rx("\\s+").split($0.lowercased()).filter { !$0.isEmpty } } ?? []
                let id = req.optStr("id") ?? "", kind = req.optStr("kind") ?? "", projectId = req.optStr("projectId") ?? ""
                var out = state
                out.items = state.items.filter { i in
                    guard id.isEmpty || i.id == id, kind.isEmpty || i.kind == kind, projectId.isEmpty || i.projectId == projectId || i.id == projectId else { return false }
                    let text = "\(i.title) \(i.body) \(i.sources.map(\.label).joined(separator: " "))".lowercased()
                    return words.allSatisfy { text.contains($0) }
                }
                return out
            }
            if op == "timer" {
                var timer = state.timer
                let action = req.str("action")
                if action == "start" {
                    guard let minutes = req.optNum("minutes"), minutes != 0 else { throw MerryError("Choose a timer duration.") }
                    if timer != nil { throw MerryError("Finish or cancel the current timer first.") }
                    let durationMs = (minutes * 60000).rounded()
                    timer = BrainTimer(id: makeId(), label: req.optStr("label") ?? "Focus time", durationMs: durationMs, remainingMs: durationMs, endsAt: now + durationMs, status: "running", notifiedAt: nil)
                } else if action == "cancel" {
                    timer = nil
                } else {
                    guard var current = timer else { throw MerryError("There is no timer running.") }
                    if action == "pause" && current.status == "running" {
                        let remainingMs = current.remaining(now: now)
                        if remainingMs > 0 {
                            current.remainingMs = remainingMs; current.endsAt = nil; current.status = "paused"
                        } else {
                            current.remainingMs = 0; current.status = "ringing"
                        }
                    } else if action == "resume" && current.status == "paused" {
                        current.endsAt = now + current.remainingMs; current.status = "running"
                    }
                    timer = current
                }
                try saveTimer(timer)
            } else if op == "create" {
                var fields = req["item"]?.objectValue ?? JSONObject()
                fields["id"] = .string(makeId())
                fields["status"] = "open"
                fields["createdAt"] = .number(now)
                fields["updatedAt"] = .number(now)
                fields["notifiedAt"] = .null
                fields["acknowledgedAt"] = .null
                fields["checks"] = []
                let item = try JSON.object(fields).decode(BrainItem.self)
                try validate(item, state)
                try save(item)
            } else {
                let id = req.str("id")
                guard let old = state.items.first(where: { $0.id == id }) else { throw MerryError("This item no longer exists.") }
                var item = old
                item.updatedAt = now
                if op == "update" {
                    let changes = req["changes"]?.objectValue ?? JSONObject()
                    if old.kind == "project", let kind = changes["kind"]?.stringValue, !kind.isEmpty, kind != "project", state.items.contains(where: { $0.projectId == old.id }) {
                        throw MerryError("Move this project’s items before changing its type.")
                    }
                    // A change of null is a change; only a key that is absent leaves the field alone.
                    let merged = (JSON.encode(item).objectValue ?? JSONObject()).merging(changes)
                    item = try JSON.object(merged).decode(BrainItem.self)
                    if changes.has("dueAt") { item.notifiedAt = nil; item.acknowledgedAt = nil }
                } else if op == "complete" {
                    if item.repeat != "none", let dueAt = item.dueAt, item.status == "open" {
                        var next = JSDate(dueAt)
                        // Calendar days preserve local clock time through daylight-saving changes.
                        repeat { next.setDate(next.day + (item.repeat == "daily" ? 1 : 7)) } while next.time <= now
                        item.dueAt = next.time; item.notifiedAt = nil; item.acknowledgedAt = nil
                    } else {
                        item.status = "done"
                    }
                } else if op == "reopen" {
                    item.status = "open"; item.notifiedAt = nil; item.acknowledgedAt = nil
                } else if op == "archive" {
                    item.status = "archived"
                } else if op == "acknowledge" {
                    item.acknowledgedAt = now
                } else if op == "snooze" {
                    item.dueAt = now + req.num("minutes") * 60000; item.notifiedAt = nil; item.acknowledgedAt = nil; item.status = "open"
                } else if op == "check" {
                    if item.kind != "tracker" { throw MerryError("Only trackers have daily check-ins.") }
                    let day = dayKey(now)
                    item.checks = item.checks.contains(day) ? item.checks.filter { $0 != day } : item.checks + [day]
                }
                try validate(item, state)
                try save(item)
            }
            return try read()
        }
    }

    /// Whether anything is waiting to be announced. Cheap enough to ask often.
    public func hasDue(now: Double = nowMs()) -> Bool {
        locked {
            let item = try? db.get("SELECT 1 FROM items WHERE json_extract(data, '$.status')='open' AND json_extract(data, '$.notifiedAt') IS NULL AND json_extract(data, '$.acknowledgedAt') IS NULL AND json_extract(data, '$.dueAt') <= ? LIMIT 1", [.number(now)])
            let timer = try? db.get("SELECT 1 FROM timer WHERE json_extract(data, '$.notifiedAt') IS NULL AND (json_extract(data, '$.status')='ringing' OR (json_extract(data, '$.status')='running' AND json_extract(data, '$.endsAt') <= ?))", [.number(now)])
            return item != nil || timer != nil
        }
    }

    /// One delivery per due occurrence; persisted claims prevent repeat alerts after restart.
    public func tick(now: Double = nowMs()) -> (state: BrainSnapshot, alerts: [BrainAlert]) {
        locked {
            guard let before = try? read() else { return (BrainSnapshot(), []) }
            var state = before
            var alerts: [BrainAlert] = []
            do {
                try db.transaction {
                    for index in state.items.indices {
                        var item = state.items[index]
                        guard item.status == "open", let dueAt = item.dueAt, dueAt <= now, item.notifiedAt == nil, item.acknowledgedAt == nil else { continue }
                        item.notifiedAt = now
                        try save(item)
                        state.items[index] = item
                        alerts.append(BrainAlert(id: item.id, title: item.title, timer: false))
                    }
                    if var timer = state.timer, (timer.status == "running" && (timer.endsAt ?? 0) <= now) || timer.status == "ringing", timer.notifiedAt == nil {
                        timer.status = "ringing"; timer.remainingMs = 0; timer.notifiedAt = now
                        try saveTimer(timer)
                        state.timer = timer
                        alerts.append(BrainAlert(id: timer.id, title: timer.label, timer: true))
                    }
                }
            } catch {
                // Nothing was claimed, so nothing may be announced.
                return (before, [])
            }
            return (state, alerts)
        }
    }

    public func close() {
        locked { db.close() }
    }
}

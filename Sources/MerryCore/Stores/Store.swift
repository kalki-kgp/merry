import Foundation

/// Typed models are stored the way `JSON.stringify` stored them.
enum StoredJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

/// Local persistence. Everything Merry knows about a task stays on this machine;
/// nothing here is synced anywhere.
public final class Store: @unchecked Sendable {
    private let db: SQLiteDatabase
    private var deletedTasks = Set<String>()
    /// The store is used from the interface and from the task loop. Recursive,
    /// because the composite operations call the simple ones.
    private let lock = NSRecursiveLock()

    /// Opens `merry.db` in the data folder, creating both if needed.
    public convenience init(directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try self.init(path: Path.join(directory, "merry.db"))
    }

    /// A private database that lives only as long as the store, for tests.
    public static func inMemory() throws -> Store { try Store(path: ":memory:") }

    private init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("PRAGMA foreign_keys = ON")
        try db.exec("PRAGMA secure_delete = ON")
        try migrate()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func migrate() throws {
        try db.exec("""
              CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                request TEXT NOT NULL,
                status TEXT NOT NULL,
                headline TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                state_json TEXT NOT NULL
              );
              CREATE TABLE IF NOT EXISTS actions (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                step INTEGER NOT NULL,
                tool TEXT NOT NULL,
                input_json TEXT NOT NULL,
                outcome TEXT NOT NULL,
                error TEXT,
                started_at INTEGER NOT NULL,
                finished_at INTEGER,
                verification_json TEXT,
                undo_json TEXT,
                reversed INTEGER NOT NULL DEFAULT 0
              );
              CREATE INDEX IF NOT EXISTS actions_task ON actions(task_id);
              CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                at INTEGER NOT NULL,
                level TEXT NOT NULL,
                source TEXT NOT NULL,
                message TEXT NOT NULL,
                data_json TEXT
              );
              CREATE INDEX IF NOT EXISTS logs_task ON logs(task_id);
              CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
              );
              CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                updated_at INTEGER NOT NULL,
                memory_json TEXT NOT NULL
              );
            """)
        // Chats: every turn names the chat it belongs to. Rows from before this
        // column existed are each a chat of their own.
        let columns = try db.all("PRAGMA table_info(tasks)")
        if !columns.contains(where: { $0.count > 1 && $0[1].string == "conversation_id" }) {
            try db.exec("ALTER TABLE tasks ADD COLUMN conversation_id TEXT")
            try db.exec("UPDATE tasks SET conversation_id = id WHERE conversation_id IS NULL")
        }
        try db.exec("CREATE INDEX IF NOT EXISTS tasks_conversation ON tasks(conversation_id, created_at)")
    }

    public func saveTask(_ task: TaskState) throws {
        try locked {
            if deletedTasks.contains(task.id) { return }
            try db.run(
                """
                INSERT INTO tasks (id, request, status, headline, created_at, updated_at, state_json, conversation_id)
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                         ON CONFLICT(id) DO UPDATE SET
                           status = excluded.status,
                           headline = excluded.headline,
                           updated_at = excluded.updated_at,
                           state_json = excluded.state_json
                """,
                [
                    .text(task.id),
                    .text(task.request),
                    .text(task.status.rawValue),
                    .optional(task.summary?.headline),
                    .number(task.createdAt),
                    .number(task.updatedAt),
                    .text(try StoredJSON.encode(task)),
                    .text(task.conversationId ?? task.id)
                ]
            )

            // Actions are written individually so undo survives a crash mid-task.
            let stmt = try db.prepare(
                """
                INSERT INTO actions (id, task_id, step, tool, input_json, outcome, error, started_at, finished_at, verification_json, undo_json)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                       ON CONFLICT(id) DO UPDATE SET
                         outcome = excluded.outcome,
                         error = excluded.error,
                         finished_at = excluded.finished_at,
                         verification_json = excluded.verification_json,
                         undo_json = excluded.undo_json
                """
            )
            defer { stmt.finalize() }
            for a in task.actions {
                try stmt.run([
                    .text(a.id),
                    .text(task.id),
                    .number(a.step),
                    .text(a.tool),
                    .text(a.input.stringify()),
                    .text(a.outcome.rawValue),
                    .optional(a.error),
                    .number(a.startedAt),
                    .optional(a.finishedAt),
                    .optional(try a.verification.map { try StoredJSON.encode($0) }),
                    .optional(try a.undo.map { try StoredJSON.encode($0) })
                ])
            }
        }
    }

    public func getTask(_ id: String) throws -> TaskState? {
        try locked {
            guard let row = try db.get("SELECT state_json FROM tasks WHERE id = ?", [.text(id)]), let text = row[0].string else { return nil }
            return try StoredJSON.decode(TaskState.self, from: text)
        }
    }

    public func isDeleted(_ id: String) -> Bool { locked { deletedTasks.contains(id) } }

    /// Remove task data, logs, and undo records. Never operate on user files.
    public func deleteTask(_ id: String) throws {
        try locked {
            if let task = try getTask(id), !task.status.isTerminal { throw MerryError("Stop this task before deleting it.") }
            try db.transaction {
                try db.run("DELETE FROM logs WHERE task_id = ?", [.text(id)])
                try db.run("DELETE FROM tasks WHERE id = ?", [.text(id)])
            }
            deletedTasks.insert(id)
        }
    }

    /// Every turn of the chat this turn belongs to, oldest first.
    public func conversationOf(_ id: String) throws -> [TaskState] {
        try locked {
            let rows = try db.all(
                """
                SELECT state_json FROM tasks
                         WHERE conversation_id = (SELECT conversation_id FROM tasks WHERE id = ?)
                         ORDER BY created_at ASC
                """,
                [.text(id)]
            )
            return try rows.map { try StoredJSON.decode(TaskState.self, from: $0[0].string ?? "") }
        }
    }

    /// Deletes a whole chat, every turn of it, and returns the ids removed.
    @discardableResult
    public func deleteConversation(_ id: String) throws -> [String] {
        try locked {
            let turns = try conversationOf(id)
            if turns.contains(where: { !$0.status.isTerminal }) { throw MerryError("Stop this task before deleting it.") }
            for t in turns { try deleteTask(t.id) }
            return turns.map(\.id)
        }
    }

    @discardableResult
    public func clearHistory() throws -> [String] {
        try locked {
            let ids = try db.all("SELECT id FROM tasks WHERE status IN ('succeeded', 'failed', 'cancelled')").compactMap { $0[0].string }
            for id in ids { try deleteTask(id) }
            return ids
        }
    }

    public func listTasks(limit: Int = 25) throws -> [TaskSummaryRow] {
        try locked {
            let rows = try db.all(
                // One row per chat: named by how it began, showing how it stands now.
                """
                SELECT t.id, first.request AS request, t.status, t.headline, t.created_at, c.turns,
                                (SELECT COUNT(*) FROM actions a WHERE a.task_id = t.id AND a.undo_json IS NOT NULL AND a.reversed = 0) AS undoable
                         FROM (SELECT conversation_id, MIN(created_at) AS started, MAX(created_at) AS latest, COUNT(*) AS turns
                               FROM tasks GROUP BY conversation_id) c
                         JOIN tasks t ON t.conversation_id = c.conversation_id AND t.created_at = c.latest
                         JOIN tasks first ON first.conversation_id = c.conversation_id AND first.created_at = c.started
                         GROUP BY c.conversation_id
                         ORDER BY t.created_at DESC LIMIT ?
                """,
                [.number(limit)]
            )
            return rows.map { r in
                TaskSummaryRow(
                    id: r[0].string ?? "",
                    request: r[1].string ?? "",
                    status: TaskStatus(rawValue: r[2].string ?? "") ?? .failed,
                    headline: r[3].string ?? "",
                    createdAt: r[4].double ?? 0,
                    undoable: (r[6].int ?? 0) > 0,
                    turns: r[5].int ?? 0
                )
            }
        }
    }

    /// Reversible actions for a task, newest first: undo runs in reverse order.
    public func undoableActions(_ taskId: String) throws -> [(id: String, undo: UndoEntry)] {
        try locked {
            let rows = try db.all(
                """
                SELECT id, undo_json FROM actions
                         WHERE task_id = ? AND undo_json IS NOT NULL AND reversed = 0 AND outcome != 'failure'
                         ORDER BY started_at DESC
                """,
                [.text(taskId)]
            )
            return try rows.map { (id: $0[0].string ?? "", undo: try StoredJSON.decode(UndoEntry.self, from: $0[1].string ?? "")) }
        }
    }

    public func markReversed(_ actionId: String) throws {
        try locked { try db.run("UPDATE actions SET reversed = 1 WHERE id = ?", [.text(actionId)]) }
    }

    public func appendLog(_ entry: LogEntry) throws {
        try locked {
            if deletedTasks.contains(entry.taskId) { return }
            try db.run(
                "INSERT INTO logs (task_id, at, level, source, message, data_json) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(entry.taskId),
                    .number(entry.at),
                    .text(entry.level.rawValue),
                    .text(entry.source),
                    .text(entry.message),
                    .optional(entry.data?.stringify())
                ]
            )
        }
    }

    public func getLogs(_ taskId: String, limit: Int = 200) throws -> [LogEntry] {
        try locked {
            let rows = try db.all(
                "SELECT task_id, at, level, source, message, data_json FROM logs WHERE task_id = ? ORDER BY at ASC LIMIT ?",
                [.text(taskId), .number(limit)]
            )
            return try rows.map { r in
                var data: JSON?
                if let text = r[5].string, !text.isEmpty { data = try JSON.parse(text) }
                return LogEntry(
                    taskId: r[0].string ?? "",
                    at: r[1].double ?? 0,
                    level: LogEntry.Level(rawValue: r[2].string ?? "") ?? .info,
                    source: r[3].string ?? "",
                    message: r[4].string ?? "",
                    data: data
                )
            }
        }
    }

    /* ---------------------------------------------------------------- *
     * Memory: what Merry knows about the person. Only on this Mac.
     * ---------------------------------------------------------------- */

    public func listMemories() throws -> [Memory] {
        try locked {
            try db.all("SELECT memory_json FROM memories ORDER BY updated_at DESC LIMIT 1000")
                .map { try StoredJSON.decode(Memory.self, from: $0[0].string ?? "") }
        }
    }

    public func saveMemory(_ memory: Memory, replaces: String? = nil) throws {
        try locked {
            try db.transaction {
                if let replaces, !replaces.isEmpty, replaces != memory.id { try db.run("DELETE FROM memories WHERE id = ?", [.text(replaces)]) }
                try db.run(
                    "INSERT INTO memories (id, updated_at, memory_json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, memory_json = excluded.memory_json",
                    [.text(memory.id), .number(memory.updatedAt), .text(try StoredJSON.encode(memory))]
                )
            }
        }
    }

    public func deleteMemories(_ ids: [String]) throws {
        try locked {
            let stmt = try db.prepare("DELETE FROM memories WHERE id = ?")
            defer { stmt.finalize() }
            try db.transaction { for id in ids { try stmt.run([.text(id)]) } }
        }
    }

    public func clearMemories() throws {
        try locked { try db.run("DELETE FROM memories") }
    }

    /// Counts a use, so the memories that keep helping rank first.
    public func markMemoriesUsed(_ ids: [String], now: Double = nowMs()) throws {
        try locked {
            for var m in try listMemories() where ids.contains(m.id) {
                m.uses += 1
                m.lastUsedAt = now
                try saveMemory(m)
            }
        }
    }

    public func getSetting(_ key: String) throws -> String? {
        try locked { try db.get("SELECT value FROM settings WHERE key = ?", [.text(key)])?[0].string }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try locked {
            try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
        }
    }

    /// Called at startup. A task still marked as running means we crashed or were
    /// force-quit; it is recorded as interrupted rather than silently resumed,
    /// because blindly repeating half-finished actions is how duplicates happen.
    @discardableResult
    public func recoverInterruptedTasks() throws -> [String] {
        try locked {
            let running = ["pending", "observing", "planning", "executing", "verifying", "awaiting_user", "paused"]
            let placeholders = running.map { _ in "?" }.joined(separator: ",")
            let rows = try db.all("SELECT id, state_json FROM tasks WHERE status IN (\(placeholders))", running.map(SQLiteValue.text))

            for row in rows {
                var task = try StoredJSON.decode(TaskState.self, from: row[1].string ?? "")
                task.status = .failed
                task.error = "Merry quit while this task was running. Nothing was resumed automatically."
                task.statusLine = "Interrupted"
                task.summary = TaskSummary(
                    headline: "Interrupted when Merry quit",
                    evidence: task.summary?.evidence ?? [],
                    undoable: try !undoableActions(task.id).isEmpty
                )
                try saveTask(task)
            }
            return rows.compactMap { $0[0].string }
        }
    }

    public func close() {
        locked { db.close() }
    }
}

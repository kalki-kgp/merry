import Foundation
import SQLite3

/// A value bound to a statement or read from a column.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var double: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .real(let d): return d
        default: return nil
        }
    }
    public var int: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .real(let d): return d.isFinite && abs(d) < 9.2e18 ? Int(d) : nil
        default: return nil
        }
    }
    public var isNull: Bool { self == .null }

    /// A number the way the reference bound it: JavaScript numbers are doubles,
    /// and a column with INTEGER affinity stores a whole one as an integer.
    public static func number(_ n: Double) -> SQLiteValue { .real(n) }
    public static func number(_ n: Int) -> SQLiteValue { .real(Double(n)) }
    public static func optional(_ s: String?) -> SQLiteValue { s.map(SQLiteValue.text) ?? .null }
    public static func optional(_ n: Double?) -> SQLiteValue { n.map(SQLiteValue.real) ?? .null }
}

public struct SQLiteError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// SQLite wants to know it must copy bound text, because the Swift string
/// does not outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One connection to a database file. Not thread-safe on its own: the store
/// that owns it serialises access.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens (creating if needed) the database at `path`; ":memory:" gives a private in-memory one.
    public init(path: String) throws {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database file"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { close() }

    public var isOpen: Bool { handle != nil }

    private func open() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is not open") }
        return handle
    }

    fileprivate func failure(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is not open")
    }

    /// Runs one or more statements that take no parameters and whose rows nobody reads.
    public func exec(_ sql: String) throws {
        let db = try open()
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        let db = try open()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure(code)
        }
        return SQLiteStatement(statement, database: self)
    }

    /// Prepares, binds, runs to completion and finalises.
    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.run(values)
    }

    /// Every row of a query.
    public func all(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        return try statement.all(values)
    }

    /// The first row of a query, if there is one.
    public func get(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteValue]? {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(values)
        return try statement.step() ? statement.row() : nil
    }

    /// Runs `body` inside BEGIN IMMEDIATE … COMMIT, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func close() {
        guard let db = handle else { return }
        handle = nil
        // Finalise anything still open, so the close cannot be refused.
        while let leftover = sqlite3_next_stmt(db, nil) { sqlite3_finalize(leftover) }
        sqlite3_close_v2(db)
    }
}

/// A prepared statement. Finalised when it goes away, or earlier by `finalize()`.
public final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let database: SQLiteDatabase

    fileprivate init(_ handle: OpaquePointer, database: SQLiteDatabase) {
        self.handle = handle
        self.database = database
    }

    deinit { finalize() }

    public func finalize() {
        // A closed database has already finalised its statements.
        if let handle, database.isOpen { sqlite3_finalize(handle) }
        handle = nil
    }

    private func open() throws -> OpaquePointer {
        guard let handle, database.isOpen else { throw SQLiteError(code: SQLITE_MISUSE, message: "statement has been finalized") }
        return handle
    }

    /// Resets the statement and binds `values` to its parameters in order.
    public func bind(_ values: [SQLiteValue]) throws {
        let statement = try open()
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard values.count == expected else {
            throw SQLiteError(code: SQLITE_RANGE, message: "statement takes \(expected) parameters, \(values.count) given")
        }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let n): code = sqlite3_bind_int64(statement, index, n)
            case .real(let d): code = sqlite3_bind_double(statement, index, d)
            case .text(let s): code = sqlite3_bind_text(statement, index, s, Int32(s.utf8.count), SQLITE_TRANSIENT)
            }
            if code != SQLITE_OK { throw database.failure(code) }
        }
    }

    /// Advances to the next row. False once there are no more.
    public func step() throws -> Bool {
        let statement = try open()
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        let error = database.failure(code)
        sqlite3_reset(statement)
        throw error
    }

    /// The current row's columns.
    public func row() throws -> [SQLiteValue] {
        let statement = try open()
        return (0..<sqlite3_column_count(statement)).map { i in
            switch sqlite3_column_type(statement, i) {
            case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, i))
            case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, i))
            case SQLITE_NULL: return .null
            default:
                // Blobs are never stored here; anything else reads as text.
                guard let text = sqlite3_column_text(statement, i) else { return .null }
                return .text(String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self))
            }
        }
    }

    /// Binds, runs to completion, and leaves the statement ready to be used again.
    public func run(_ values: [SQLiteValue] = []) throws {
        try bind(values)
        while try step() {}
        if let handle { sqlite3_reset(handle) }
    }

    public func all(_ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try bind(values)
        var rows: [[SQLiteValue]] = []
        while try step() { rows.append(try row()) }
        if let handle { sqlite3_reset(handle) }
        return rows
    }
}

import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// A deliberately small SQLite wrapper. Everything the app persists goes
// through this file, so it favors explicit, boring behavior: every statement
// is checked, every transaction either commits or rolls back, and nothing is
// ever silently dropped.

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DatabaseError: Error, CustomStringConvertible, Equatable {
    public var code: Int32
    public var message: String
    public var sql: String?

    public init(code: Int32, message: String, sql: String? = nil) {
        self.code = code
        self.message = message
        self.sql = sql
    }

    public var description: String {
        if let sql {
            return "SQLite error \(code): \(message) — \(sql)"
        }
        return "SQLite error \(code): \(message)"
    }

    /// Primary result code (strips extended code bits).
    public var primaryCode: Int32 { code & 0xFF }

    public var isCorruption: Bool {
        primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
    }
}

public enum DatabaseValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public protocol DatabaseValueConvertible {
    var databaseValue: DatabaseValue { get }
}

extension DatabaseValue: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { self }
}

extension Int: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .integer(Int64(self)) }
}

extension Int64: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .integer(self) }
}

extension Double: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { isFinite ? .real(self) : .null }
}

extension Bool: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .integer(self ? 1 : 0) }
}

extension String: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .text(self) }
}

extension Date: DatabaseValueConvertible {
    /// Stored at millisecond precision, the same precision exports use, so a
    /// backup → restore round trip reproduces every timestamp exactly.
    public var databaseValue: DatabaseValue {
        .real((timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

extension UUID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .text(uuidString) }
}

extension Data: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { .blob(self) }
}

extension Optional: DatabaseValueConvertible where Wrapped: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        switch self {
        case .none: return .null
        case .some(let wrapped): return wrapped.databaseValue
        }
    }
}

/// One result row. Column lookup is by name; unknown columns read as NULL.
public struct Row {
    let columnIndex: [String: Int]
    public let values: [DatabaseValue]

    public subscript(_ column: String) -> DatabaseValue {
        guard let index = columnIndex[column], index < values.count else { return .null }
        return values[index]
    }

    public func isNull(_ column: String) -> Bool {
        if case .null = self[column] { return true }
        return false
    }

    public func string(_ column: String) -> String? {
        switch self[column] {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .blob(let data): return String(data: data, encoding: .utf8)
        case .null: return nil
        }
    }

    public func int(_ column: String) -> Int? {
        switch self[column] {
        case .integer(let value): return Int(value)
        case .real(let value): return value.isFinite ? Int(value) : nil
        case .text(let value): return Int(value)
        default: return nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch self[column] {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    public func bool(_ column: String) -> Bool {
        (int(column) ?? 0) != 0
    }

    public func date(_ column: String) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }

    public func uuid(_ column: String) -> UUID? {
        string(column).flatMap(UUID.init(uuidString:))
    }

    public func data(_ column: String) -> Data? {
        switch self[column] {
        case .blob(let data): return data
        case .text(let value): return Data(value.utf8)
        default: return nil
        }
    }
}

/// A single SQLite connection. Not thread-safe on its own: always use it
/// through `DatabaseQueue`, which serializes access.
public final class Connection {
    private(set) var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]
    private var transactionDepth = 0
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        var flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError(code: rc, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 10_000)
    }

    deinit {
        close()
    }

    public func close() {
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        statementCache.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    public var isOpen: Bool { handle != nil }

    /// True when no transaction is open.
    public var isAutocommit: Bool {
        guard let handle else { return true }
        return sqlite3_get_autocommit(handle) != 0
    }

    public var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    private func currentError(_ code: Int32, sql: String?) -> DatabaseError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed"
        return DatabaseError(code: code, message: message, sql: sql)
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else {
            throw DatabaseError(code: SQLITE_MISUSE, message: "Database is closed")
        }
        return handle
    }

    /// Runs one or more SQL statements that take no arguments.
    public func execute(_ sql: String) throws {
        let db = try requireHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw DatabaseError(code: rc, message: message, sql: sql)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        let db = try requireHandle()
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw currentError(rc, sql: sql)
        }
        statementCache[sql] = statement
        return statement
    }

    /// Drops cached prepared statements (used after the whole database file is
    /// replaced by a restore).
    public func clearStatementCache() {
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        statementCache.removeAll()
    }

    private func bind(_ arguments: [DatabaseValueConvertible], to statement: OpaquePointer, sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == arguments.count else {
            throw DatabaseError(
                code: SQLITE_MISUSE,
                message: "Expected \(expected) arguments but got \(arguments.count)",
                sql: sql
            )
        }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch argument.databaseValue {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .integer(let value):
                rc = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                rc = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                let byteCount = Int32(value.utf8.count)
                rc = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, byteCount, transientDestructor)
                }
            case .blob(let value):
                if value.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    rc = value.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
                    }
                }
            }
            guard rc == SQLITE_OK else { throw currentError(rc, sql: sql) }
        }
    }

    private func columnValue(_ statement: OpaquePointer, _ index: Int32) -> DatabaseValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .text("") }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }

    /// Runs a single statement, discarding any result rows.
    public func run(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws {
        let statement = try prepare(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(arguments, to: statement, sql: sql)
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW {
            rc = sqlite3_step(statement)
        }
        guard rc == SQLITE_DONE else { throw currentError(rc, sql: sql) }
    }

    /// Runs a single statement and returns every result row.
    public func query(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> [Row] {
        let statement = try prepare(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(arguments, to: statement, sql: sql)
        let columnCount = Int(sqlite3_column_count(statement))
        var columnIndex: [String: Int] = [:]
        for column in 0..<columnCount {
            if let name = sqlite3_column_name(statement, Int32(column)) {
                columnIndex[String(cString: name)] = column
            }
        }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw currentError(rc, sql: sql) }
            var values: [DatabaseValue] = []
            values.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                values.append(columnValue(statement, Int32(column)))
            }
            rows.append(Row(columnIndex: columnIndex, values: values))
        }
        return rows
    }

    public func queryOne(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> Row? {
        try query(sql, arguments).first
    }

    /// First column of the first row, if any.
    public func scalar(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> DatabaseValue {
        guard let row = try query(sql, arguments).first, let first = row.values.first else { return .null }
        return first
    }

    public func scalarInt(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> Int {
        switch try scalar(sql, arguments) {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value) ?? 0
        default: return 0
        }
    }

    public func userVersion() throws -> Int {
        try scalarInt("PRAGMA user_version")
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    public func tableExists(_ name: String) throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) > 0
    }

    /// Runs `body` inside a transaction (or a savepoint when nested). Commits
    /// when it returns, rolls back when it throws.
    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
        let depth = transactionDepth
        let savepoint = "forge_sp_\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth = depth + 1
        defer { transactionDepth = depth }
        do {
            let result = try body()
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            if depth == 0 {
                if !isAutocommit {
                    try? execute("ROLLBACK")
                }
            } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    /// Returns "ok" rows from PRAGMA quick_check / integrity_check.
    public func integrityProblems(full: Bool = false) throws -> [String] {
        let rows = try query(full ? "PRAGMA integrity_check" : "PRAGMA quick_check")
        let messages = rows.compactMap { $0.values.first }.compactMap { value -> String? in
            if case .text(let text) = value { return text }
            return nil
        }
        return messages.filter { $0.lowercased() != "ok" }
    }

    /// Copies the entire contents of `source` into this connection's main
    /// database using SQLite's online backup API.
    public func replaceContents(from source: Connection) throws {
        let destination = try requireHandle()
        let sourceHandle = try source.requireHandle()
        guard let backup = sqlite3_backup_init(destination, "main", sourceHandle, "main") else {
            throw currentError(sqlite3_errcode(destination), sql: "backup")
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, -1)
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        let finish = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE, finish == SQLITE_OK else {
            throw currentError(finish != SQLITE_OK ? finish : rc, sql: "backup")
        }
        clearStatementCache()
    }
}

/// Serializes all access to one connection on a private queue. Reads and
/// writes are synchronous: the data sizes in this app are small, and
/// synchronous writes mean that when a save call returns, the data is on disk.
public final class DatabaseQueue: @unchecked Sendable {
    public let path: String
    private let connection: Connection
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    public init(path: String) throws {
        self.path = path
        self.connection = try Connection(path: path)
        self.queue = DispatchQueue(label: "forge.database", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: 1)
        try configure()
    }

    private func configure() throws {
        try connection.execute("PRAGMA foreign_keys = ON")
        let mode = try connection.scalar("PRAGMA journal_mode = WAL")
        if case .text(let value) = mode, value.lowercased() != "wal" {
            // Some file systems can't do WAL; the rollback journal is still
            // fully durable, just slower.
            try connection.execute("PRAGMA journal_mode = DELETE")
        }
        // FULL syncs the WAL on every commit: a saved set survives even a
        // power loss or OS crash, not just an app crash.
        try connection.execute("PRAGMA synchronous = FULL")
    }

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// Runs `block` with exclusive access to the connection, outside of any
    /// transaction. Use for reads and for statements such as VACUUM that
    /// can't run in a transaction.
    public func read<T>(_ block: (Connection) throws -> T) throws -> T {
        if isOnQueue { return try block(connection) }
        return try queue.sync { try block(connection) }
    }

    /// Runs `block` in a transaction; everything commits or nothing does.
    public func write<T>(_ block: (Connection) throws -> T) throws -> T {
        if isOnQueue {
            return try connection.inTransaction { try block(connection) }
        }
        return try queue.sync {
            try connection.inTransaction { try block(connection) }
        }
    }

    public func close() {
        if isOnQueue {
            connection.close()
        } else {
            queue.sync { connection.close() }
        }
    }

    public func checkpoint() {
        _ = try? read { db in
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}

extension DatabaseError: LocalizedError {
    public var errorDescription: String? { message }
}

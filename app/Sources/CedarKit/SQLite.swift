import Foundation
import SQLite3

/// A value bound to or read from a statement.
public enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null

    public var int: Int64? { if case .int(let v) = self { return v }; if case .double(let d) = self { return Int64(d) }; return nil }
    public var double: Double? { if case .double(let v) = self { return v }; if case .int(let i) = self { return Double(i) }; return nil }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
    public var blob: Data? { if case .blob(let v) = self { return v }; return nil }
}

public struct SQLError: Error, CustomStringConvertible { public let description: String }

/// A SQLite connection in WAL mode. Calls are serialized by a lock.
public final class Database {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw SQLError(description: "can't open \(path)") }
        sqlite3_busy_timeout(handle, 30_000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close_v2(handle) }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs statements that return no rows.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLError(description: message) }
    }

    /// Runs one statement and returns its rows.
    @discardableResult
    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw SQLError(description: message + " in: " + sql) }
        defer { sqlite3_finalize(st) }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(st, n, v)
            case .double(let v): sqlite3_bind_double(st, n, v)
            case .text(let v): sqlite3_bind_text(st, n, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(st, n)
            }
        }
        var rows: [[SQLValue]] = []
        let columns = sqlite3_column_count(st)
        while true {
            let code = sqlite3_step(st)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw SQLError(description: message + " in: " + sql) }
            var row: [SQLValue] = []
            row.reserveCapacity(Int(columns))
            for c in 0..<columns {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(st, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(st, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(st, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(st, c))
                    row.append(.blob(n > 0 ? Data(bytes: sqlite3_column_blob(st, c), count: n) : Data()))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs `body` in a transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

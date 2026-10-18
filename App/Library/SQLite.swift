import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite library. Not thread-safe by itself: owned by the
/// `LibraryDatabase` actor.
final class SQLiteDatabase {
    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null

        init(_ string: String?) { self = string.map(Value.text) ?? .null }
        init(_ int: Int?) { self = int.map { .int(Int64($0)) } ?? .null }
        init(_ double: Double?) { self = double.map(Value.double) ?? .null }
        init(_ float: Float?) { self = float.map { .double(Double($0)) } ?? .null }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else { throw Failure(description: "Cannot open \(path)") }
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }

    /// Runs `sql` with `values` bound, returning every row as column values.
    @discardableResult
    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var rows: [[Value]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(handle))) }
            let count = sqlite3_column_count(statement)
            rows.append((0..<count).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    .blob(Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))))
                default: .null
                }
            })
        }
        return rows
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
}

extension SQLiteDatabase.Value {
    var string: String? { if case .text(let v) = self { v } else { nil } }
    var int: Int? {
        switch self {
        case .int(let v): Int(v)
        case .double(let v): Int(v)
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
}

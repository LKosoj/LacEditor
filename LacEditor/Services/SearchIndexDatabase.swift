import Foundation
import SQLite3

enum SearchIndexError: Error, Equatable {
    /// Режим недоступен (нет FTS5 и т. п.); строка — причина для диагностики.
    case unavailable(String)
    case sqlite(code: Int32, message: String)
    case corrupt

    /// База повреждена или это не база SQLite: индекс — производные данные, его можно пересоздать.
    var isCorruption: Bool {
        switch self {
        case .corrupt: true
        case let .sqlite(code, _): code == SQLITE_CORRUPT || code == SQLITE_NOTADB
        case .unavailable: false
        }
    }
}

/// SQLite копирует переданную строку сразу, поэтому Swift-строку можно освобождать после вызова.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Тонкая обёртка над C API SQLite. Не потокобезопасна сама по себе: пользоваться только внутри одного владельца (актора).
final class SearchDatabase {
    /// Тестовый хук: подменяет результат проверки FTS5 (nil — настоящая проверка).
    static var fts5Override: Bool?

    private var handle: OpaquePointer?

    convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    /// `path` может быть и специальным именем SQLite (`:memory:`).
    init(path: String) throws {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2"
            if let opened { sqlite3_close_v2(opened) }
            throw SearchIndexError.sqlite(code: code, message: message)
        }
        handle = opened
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    func exec(_ sql: String) throws {
        guard let handle else { throw SearchIndexError.unavailable("closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard code == SQLITE_OK else {
            throw SearchIndexError.sqlite(code: code, message: errorMessage.map { String(cString: $0) } ?? "")
        }
    }

    func prepare(_ sql: String) throws -> SearchStatement {
        guard let handle else { throw SearchIndexError.unavailable("closed") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw SearchIndexError.sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SearchStatement(statement: statement, database: handle)
    }

    /// Проверка во время выполнения: сборка SQLite может быть без FTS5.
    static func fts5Available() -> Bool {
        if let fts5Override { return fts5Override }
        guard let database = try? SearchDatabase(path: ":memory:") else { return false }
        guard (try? database.exec("CREATE VIRTUAL TABLE temp.fts5_probe USING fts5(x)")) != nil else { return false }
        try? database.exec("DROP TABLE temp.fts5_probe")
        return true
    }
}

final class SearchStatement {
    private var statement: OpaquePointer?
    private let database: OpaquePointer

    fileprivate init(statement: OpaquePointer, database: OpaquePointer) {
        self.statement = statement
        self.database = database
    }

    deinit {
        if let statement { sqlite3_finalize(statement) }
    }

    func bind(_ index: Int32, text: String) throws {
        try check(sqlite3_bind_text(statement, index, text, -1, sqliteTransient))
    }

    func bind(_ index: Int32, int value: Int64) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ index: Int32, double value: Double) throws {
        try check(sqlite3_bind_double(statement, index, value))
    }

    /// true — есть строка, false — SQLITE_DONE.
    func step() throws -> Bool {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SearchIndexError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw SearchIndexError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
    }
}

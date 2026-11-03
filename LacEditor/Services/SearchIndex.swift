import Foundation

struct SearchIndexHit: Equatable, Identifiable, Sendable {
    var id: String { "\(path):\(line)" }
    let path: String          // относительный путь от корня
    let line: Int
    let endLine: Int
    let title: String
    let text: String          // исходный текст фрагмента
    let score: Double         // больше = лучше
    let isLive: Bool          // из несохранённого открытого документа

    func url(in root: URL) -> URL { root.appendingPathComponent(path) }
}

struct SearchIndexFileStamp: Equatable, Sendable {
    var mtime: Double
    var size: Int64
}

struct SearchIndexStats: Equatable, Sendable {
    var files: Int
    var chunks: Int
    var tokens: Int
}

/// Полнотекстовый индекс папки (SQLite FTS5, ранжирование bm25). Это производные данные: файл можно удалить и построить заново.
/// Один актор на корень папки; тяжёлая работа (чтение, нарезка) делается снаружи, сюда приходят короткие вызовы.
actor SearchIndex {
    static let schemaVersion = 2
    /// Вес заголовка 3, текста 1. Первые пять колонок (path, line, endline, title, raw) не индексируются.
    private static let rank = "bm25(chunks,0,0,0,0,0,3.0,1.0)"
    private static let titleWeight = 3.0

    nonisolated let root: URL
    private let databaseURL: URL
    private var database: SearchDatabase?
    private var nextRowID: Int64 = 1

    init(databaseURL: URL, root: URL) {
        self.databaseURL = databaseURL
        self.root = root
    }

    /// Открывает базу, проверяет FTS5 и версию схемы; при порче или чужой версии создаёт файл заново.
    func prepare() throws {
        _ = try openedDatabase()
    }

    func fileStamps() throws -> [String: SearchIndexFileStamp] {
        try perform { db in
            let statement = try db.prepare("SELECT path, mtime, size FROM files")
            var result: [String: SearchIndexFileStamp] = [:]
            while try statement.step() {
                result[statement.text(0)] = SearchIndexFileStamp(mtime: statement.double(1), size: statement.int(2))
            }
            return result
        }
    }

    /// false — в индексе уже запись, сделанная после начала чтения этого файла (поздний писатель), ничего не изменено.
    /// Даты файлов не сравниваются: файл, заменённый версией со старой датой (`cp -p`, `rsync -t`), должен обновиться.
    /// `readStarted` — время начала чтения файла (`timeIntervalSince1970`).
    func replace(path: String, stamp: SearchIndexFileStamp, chunks: [SearchChunk], readStarted: Double) throws -> Bool {
        let start = nextRowID
        let outcome: (written: Bool, nextRowID: Int64) = try perform { db in
            try db.exec("BEGIN IMMEDIATE")
            do {
                let existing = try Self.record(of: path, in: db)
                if let existing, existing.written > readStarted {
                    try db.exec("ROLLBACK")
                    return (false, start)
                }
                if let existing { try Self.deleteRows(existing.first, existing.last, in: db) }
                var rowID = start
                var tokens = 0
                let insert = try db.prepare("INSERT INTO chunks(rowid, path, line, endline, title, raw, heading, body) VALUES (?,?,?,?,?,?,?,?)")
                for chunk in chunks {
                    insert.reset()
                    try insert.bind(1, int: rowID)
                    try insert.bind(2, text: path)
                    try insert.bind(3, int: Int64(chunk.line))
                    try insert.bind(4, int: Int64(chunk.endLine))
                    try insert.bind(5, text: chunk.title)
                    try insert.bind(6, text: chunk.raw)
                    try insert.bind(7, text: chunk.heading)
                    try insert.bind(8, text: chunk.body)
                    _ = try insert.step()
                    rowID += 1
                    tokens += chunk.tokenCount
                }
                let file = try db.prepare("INSERT OR REPLACE INTO files(path, mtime, size, chunk_count, token_count, first_rowid, last_rowid, written) VALUES (?,?,?,?,?,?,?,?)")
                try file.bind(1, text: path)
                try file.bind(2, double: stamp.mtime)
                try file.bind(3, int: stamp.size)
                try file.bind(4, int: Int64(chunks.count))
                try file.bind(5, int: Int64(tokens))
                try file.bind(6, int: start)
                try file.bind(7, int: rowID - 1)
                try file.bind(8, double: Date().timeIntervalSince1970)
                _ = try file.step()
                try db.exec("COMMIT")
                return (true, rowID)
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
        if outcome.written { nextRowID = outcome.nextRowID }
        return outcome.written
    }

    func remove(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try perform { db in
            try db.exec("BEGIN IMMEDIATE")
            do {
                for path in paths {
                    if let existing = try Self.record(of: path, in: db) { try Self.deleteRows(existing.first, existing.last, in: db) }
                    let statement = try db.prepare("DELETE FROM files WHERE path = ?")
                    try statement.bind(1, text: path)
                    _ = try statement.step()
                }
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
    }

    func stats() throws -> SearchIndexStats {
        try perform { db in
            let statement = try db.prepare("SELECT count(*), coalesce(sum(chunk_count), 0), coalesce(sum(token_count), 0) FROM files")
            guard try statement.step() else { return SearchIndexStats(files: 0, chunks: 0, tokens: 0) }
            return SearchIndexStats(files: Int(statement.int(0)), chunks: Int(statement.int(1)), tokens: Int(statement.int(2)))
        }
    }

    /// Контракт для этапа 9: запрос из слов без учёта несохранённых документов.
    func search(_ query: String, limit: Int) async throws -> [SearchIndexHit] {
        try await search(SearchQuery(text: query), limit: limit, live: [])
    }

    func search(_ query: SearchQuery, limit: Int, live: [SearchLiveDocument]) async throws -> [SearchIndexHit] {
        guard !query.isEmpty, limit > 0 else { return [] }
        return try perform { db in
            let excluded = live.map(\.path)
            // Сначала все слова сразу; если ничего нет, а слов больше одного, — любое из слов.
            var joiner = SearchQuery.Joiner.and
            var hits = try Self.indexHits(query, joiner: joiner, excluding: excluded, limit: limit, in: db)
            var liveHits = try Self.liveHits(query, joiner: joiner, live: live, in: db)
            if hits.isEmpty, liveHits.isEmpty, query.terms.count > 1 {
                joiner = .or
                hits = try Self.indexHits(query, joiner: joiner, excluding: excluded, limit: limit, in: db)
                liveHits = try Self.liveHits(query, joiner: joiner, live: live, in: db)
            }
            let merged = (hits + liveHits).sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path
            }
            return Array(merged.prefix(limit))
        }
    }

    /// Закрывает базу и удаляет файл вместе с `-wal` и `-shm`.
    func destroy() throws {
        database = nil
        nextRowID = 1
        removeFiles()
    }

    // MARK: База

    private func openedDatabase() throws -> SearchDatabase {
        if let database { return database }
        guard SearchDatabase.fts5Available() else { throw SearchIndexError.unavailable("FTS5") }
        if let opened = try openChecked() { return opened }
        // Порча в файле или в самой таблице FTS: удаляем файлы и открываем заново, иначе каждый поиск падал бы.
        removeFiles()
        let fresh = try open()
        nextRowID = try Self.maxRowID(in: fresh) + 1
        database = fresh
        return fresh
    }

    /// `nil` — база повреждена; её соединение к этому моменту уже закрыто, и файлы можно удалять,
    /// не рискуя, что закрытие старого соединения удалит `-wal` новой базы.
    private func openChecked() throws -> SearchDatabase? {
        do {
            let db = try open()
            nextRowID = try Self.maxRowID(in: db) + 1
            database = db
            return db
        } catch let error as SearchIndexError where error.isCorruption {
            return nil
        }
    }

    private static func maxRowID(in db: SearchDatabase) throws -> Int64 {
        let statement = try db.prepare("SELECT coalesce(max(rowid), 0) FROM chunks")
        return try statement.step() ? statement.int(0) : 0
    }

    private func open() throws -> SearchDatabase {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SearchDatabase(url: databaseURL)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        let version = try Self.userVersion(db)
        // Чужая версия схемы считается порчей: индекс просто строится заново.
        guard version == 0 || version == Self.schemaVersion else { throw SearchIndexError.corrupt }
        try db.exec("""
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL, chunk_count INTEGER NOT NULL, \
            token_count INTEGER NOT NULL, first_rowid INTEGER NOT NULL, last_rowid INTEGER NOT NULL, written REAL NOT NULL) WITHOUT ROWID
            """)
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID")
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(path UNINDEXED, line UNINDEXED, endline UNINDEXED, title UNINDEXED, \
            raw UNINDEXED, heading, body, tokenize='unicode61 remove_diacritics 2')
            """)
        if version == 0 { try db.exec("PRAGMA user_version = \(Self.schemaVersion)") }
        return db
    }

    private static func userVersion(_ db: SearchDatabase) throws -> Int64 {
        let statement = try db.prepare("PRAGMA user_version")
        return try statement.step() ? statement.int(0) : 0
    }

    private func removeFiles() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    /// Выполняет работу с базой; при порче файл удаляется, а следующий вызов создаст базу заново.
    private func perform<T>(_ body: (SearchDatabase) throws -> T) throws -> T {
        // Соединение не держится в локальной переменной: при порче оно должно закрыться до удаления файлов.
        do { return try body(openedDatabase()) }
        catch let error as SearchIndexError where error.isCorruption {
            database = nil
            removeFiles()
            throw error
        }
    }

    private static func record(of path: String, in db: SearchDatabase) throws -> (written: Double, first: Int64, last: Int64)? {
        let statement = try db.prepare("SELECT written, first_rowid, last_rowid FROM files WHERE path = ?")
        try statement.bind(1, text: path)
        guard try statement.step() else { return nil }
        return (statement.double(0), statement.int(1), statement.int(2))
    }

    /// Удаление по диапазону rowid: по UNINDEXED-колонке FTS5 пришлось бы просматривать всю таблицу.
    private static func deleteRows(_ first: Int64, _ last: Int64, in db: SearchDatabase) throws {
        guard first <= last else { return }
        let statement = try db.prepare("DELETE FROM chunks WHERE rowid BETWEEN ? AND ?")
        try statement.bind(1, int: first)
        try statement.bind(2, int: last)
        _ = try statement.step()
    }

    // MARK: Поиск

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func indexHits(_ query: SearchQuery, joiner: SearchQuery.Joiner, excluding: [String], limit: Int,
                                  in db: SearchDatabase) throws -> [SearchIndexHit] {
        var sql = "SELECT path, line, endline, title, raw, -\(rank) FROM chunks WHERE chunks MATCH ?"
        if !excluding.isEmpty { sql += " AND path NOT IN (\(placeholders(excluding.count)))" }
        sql += " ORDER BY \(rank) LIMIT ?"
        let statement = try db.prepare(sql)
        var position: Int32 = 1
        try statement.bind(position, text: query.matchExpression(joiner: joiner))
        for path in excluding {
            position += 1
            try statement.bind(position, text: path)
        }
        try statement.bind(position + 1, int: Int64(limit))
        var hits: [SearchIndexHit] = []
        while try statement.step() {
            hits.append(SearchIndexHit(path: statement.text(0), line: Int(statement.int(1)), endLine: Int(statement.int(2)),
                                       title: statement.text(3), text: statement.text(4), score: statement.double(5), isLive: false))
        }
        return hits
    }

    /// Свой bm25 для открытых документов (k1 = 1,2; b = 0,75). Статистика корпуса берётся из индекса без путей этих документов.
    private static func liveHits(_ query: SearchQuery, joiner: SearchQuery.Joiner, live: [SearchLiveDocument],
                                 in db: SearchDatabase) throws -> [SearchIndexHit] {
        let chunks = live.flatMap { document in document.chunks.map { (document.path, $0) } }
        guard !chunks.isEmpty else { return [] }
        let excluded = live.map(\.path)
        var indexChunks = 0, indexTokens = 0
        do {
            let statement = try db.prepare("SELECT coalesce(sum(chunk_count), 0), coalesce(sum(token_count), 0) FROM files WHERE path NOT IN (\(placeholders(excluded.count)))")
            for (offset, path) in excluded.enumerated() { try statement.bind(Int32(offset + 1), text: path) }
            if try statement.step() { indexChunks = Int(statement.int(0)); indexTokens = Int(statement.int(1)) }
        }
        let liveTokens = chunks.reduce(0) { $0 + $1.1.tokenCount }
        let total = Double(indexChunks + chunks.count)
        let averageLength = max(Double(indexTokens + liveTokens) / max(total, 1), 1)

        let terms = query.matchedTerms
        var idf: [String: Double] = [:]
        for term in terms {
            var documents = chunks.filter { Self.contains($0.1, term: term) }.count
            let statement = try db.prepare("SELECT count(*) FROM chunks WHERE chunks MATCH ? AND path NOT IN (\(placeholders(excluded.count)))")
            try statement.bind(1, text: SearchQuery.quote(term))
            for (offset, path) in excluded.enumerated() { try statement.bind(Int32(offset + 2), text: path) }
            if try statement.step() { documents += Int(statement.int(0)) }
            idf[term] = max(log((total - Double(documents) + 0.5) / (Double(documents) + 0.5)), 1e-6)
        }

        var hits: [SearchIndexHit] = []
        for (path, chunk) in chunks {
            let body = chunk.body.split(separator: " ").map(String.init)
            let heading = chunk.heading.split(separator: " ").map(String.init)
            var found = Set<String>()
            var score = 0.0
            for term in terms {
                let frequency = Double(body.filter { $0 == term }.count) + titleWeight * Double(heading.filter { $0 == term }.count)
                guard frequency > 0 else { continue }
                found.insert(term)
                let length = Double(chunk.tokenCount)
                score += (idf[term] ?? 1e-6) * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
            // Те же правила, что у выражения MATCH: (все слова запроса) ИЛИ слово расширения; в режиме OR — любое слово.
            let matches: Bool
            switch joiner {
            case .and: matches = query.terms.allSatisfy { found.contains($0) } || query.expansion.contains { found.contains($0) }
            case .or: matches = !found.isEmpty
            }
            guard matches else { continue }
            hits.append(SearchIndexHit(path: path, line: chunk.line, endLine: chunk.endLine, title: chunk.title,
                                       text: chunk.raw, score: score, isLive: true))
        }
        return hits
    }

    private static func contains(_ chunk: SearchChunk, term: String) -> Bool {
        chunk.body.split(separator: " ").contains { $0 == term } || chunk.heading.split(separator: " ").contains { $0 == term }
    }
}

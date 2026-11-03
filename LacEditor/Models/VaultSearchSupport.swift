import Foundation

/// Режим поиска в боковой панели хранилища: «Текст», «Теги» и «По словам» здесь не нужны (на диске только открытые заметки).
enum VaultSearchMode: Equatable, Sendable {
    /// Поиск сервера (QMD): по смыслу и по тексту, нужна связь.
    case server
    /// Только по именам и путям заметок из каталога в памяти: работает без сети.
    case names
}

/// Одна найденная заметка. `folderTrail` — папки через « › », `name` — имя без `.md`.
struct VaultSearchResult: Identifiable, Equatable, Sendable {
    let path: String
    let title: String
    let snippet: String?
    let folderTrail: String
    let name: String

    var id: String { path }

    /// «projects › npd › status»; у заметки в корне — только имя.
    var displayTrail: String { folderTrail.isEmpty ? name : folderTrail + VaultSearchSupport.trailSeparator + name }
}

/// Что показывать в области результатов.
enum VaultSearchPhase: Equatable, Sendable {
    /// Поле пустое.
    case idle
    /// Ждём конец ввода: прежние результаты остаются на месте.
    case waiting
    /// Запрос ушёл на сервер.
    case loading
    case results
    case empty
    /// Сервер ответил 503: поиск (QMD) не работает.
    case unavailable
    case offline
    /// Иная ошибка: текст уже на языке интерфейса.
    case failed(String)
}

/// Чистая логика поиска хранилища: нормализация запроса, проверка ответа сервера, ранжирование имён.
enum VaultSearchSupport {
    /// Сервер отдаёт не больше стольких результатов; ровно столько — признак, что есть и другие.
    static let serverLimit = 20
    /// Сколько строк показываем в режиме «Имена».
    static let namesLimit = 100
    /// Длиннее сервер отвечает 400.
    static let maxQueryLength = 200
    static let trailSeparator = " › "

    /// Управляющие символы и переводы строк становятся пробелом, подряд идущие пробелы схлопываются, длина — не больше 200.
    static func normalizedQuery(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace { scalars.append(" "); pendingSpace = false }
            scalars.append(scalar)
        }
        let limited = String(String.UnicodeScalarView(scalars.prefix(maxQueryLength)))
        return limited.trimmingCharacters(in: .whitespaces)
    }

    /// Результаты сервера: небезопасные пути и скрытые разделы отбрасываются молча, повторы по пути убираются.
    static func results(from hits: [VaultSearchHit], hidden: Set<String> = []) -> [VaultSearchResult] {
        var seen = Set<String>()
        var result: [VaultSearchResult] = []
        for hit in hits {
            guard let path = VaultPath.validated(hit.path), !isHidden(path, hidden), seen.insert(path).inserted else { continue }
            let snippet = hit.snippet?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(make(path: path, title: hit.title, snippet: snippet?.isEmpty == false ? snippet : nil))
        }
        return result
    }

    /// Состояние по ошибке запроса; nil — отмена, её пользователю не показывают.
    static func phase(for error: Error) -> VaultSearchPhase? {
        if error is CancellationError { return nil }
        if let error = error as? VaultClientError {
            switch error {
            case .searchUnavailable: return .unavailable
            case .offline, .timeout: return .offline
            default: return .failed(error.userMessage)
            }
        }
        return .failed(error.localizedDescription)
    }

    /// Диапазоны (UTF-16) слов запроса в тексте: без учёта регистра и диакритики, пересекающиеся склеиваются.
    static func highlightRanges(in text: String, query: String) -> [NSRange] {
        let ns = text as NSString
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        var ranges: [NSRange] = []
        for word in words {
            var location = 0
            while location < ns.length {
                let found = ns.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: NSRange(location: location, length: ns.length - location))
                if found.location == NSNotFound || found.length == 0 { break }
                ranges.append(found)
                location = NSMaxRange(found)
            }
        }
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Режим «Имена»: порядок как у быстрого открытия (точное имя, затем подстрока пути, затем подпоследовательность),
    /// внутри одного ранга — порядок каталога. `total` — сколько всего совпало (показано не больше `limit`).
    static func rankNames(query: String, paths: [String], limit: Int = namesLimit,
                          isCancelled: () -> Bool = { false }) throws -> (results: [VaultSearchResult], total: Int) {
        let matcher = FolderSearchService.NameQuery(query, caseSensitive: false)
        var ranked: [(path: String, rank: Int, index: Int)] = []
        for (index, path) in paths.enumerated() {
            if let rank = try matcher.rank(path: path, name: VaultPresentation.displayName(ofPath: path), isCancelled: isCancelled) {
                ranked.append((path, rank, index))
            }
        }
        ranked.sort { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }
        let results = ranked.prefix(limit).map { make(path: $0.path, title: nil, snippet: nil) }
        return (results, ranked.count)
    }

    /// Первый компонент пути входит в список скрытых разделов (сравнение точное, как отдаёт сервер).
    static func isHidden(_ path: String, _ hidden: Set<String>) -> Bool {
        guard !hidden.isEmpty else { return false }
        let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return hidden.contains(first)
    }

    private static func make(path: String, title: String?, snippet: String?) -> VaultSearchResult {
        let name = VaultPresentation.displayName(ofPath: path)
        let folders = path.split(separator: "/").dropLast().map(String.init)
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VaultSearchResult(path: path, title: cleanTitle?.isEmpty == false ? cleanTitle! : name, snippet: snippet,
                                 folderTrail: folders.joined(separator: trailSeparator), name: name)
    }
}

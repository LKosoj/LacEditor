import Foundation

/// Поиск по всем открытым документам: считает совпадения по снимкам текста и выбирает следующее/предыдущее.
/// Документы определяются по `documentID`, адрес файла не нужен: несохранённые вкладки участвуют так же.
enum OpenDocumentsSearchService {
    enum SkipReason: Equatable, Sendable { case opening, largeFile, readingMode, protectedPage, busy, changed }

    /// Документ глазами поиска. `snapshot == nil`, если документ пропущен до чтения текста.
    struct Source: Sendable {
        let documentID: UUID
        let title: String
        let snapshot: DocumentTextSnapshot?
        let skip: SkipReason?
    }

    struct DocumentMatches: Sendable, Equatable {
        let documentID: UUID
        let title: String
        let revision: UInt
        let ranges: [NSRange]          // только документы хотя бы с одним совпадением
    }

    struct Skipped: Sendable, Equatable {
        let documentID: UUID
        let title: String
        let reason: SkipReason
    }

    struct Result: Sendable, Equatable {
        let order: [UUID]              // все просмотренные документы в порядке вкладок
        let revisions: [UUID: UInt]    // версия текста каждого просмотренного документа
        let documents: [DocumentMatches]
        let skipped: [Skipped]
        var matchCount: Int { documents.reduce(0) { $0 + $1.ranges.count } }
    }

    struct Position: Equatable, Sendable {
        let documentID: UUID
        let range: NSRange
    }

    /// Бросает `TextSearchService.SearchError.invalidPattern` и `CancellationError`.
    static func search(sources: [Source], query: String, options: TextSearchService.Options,
                       isCancelled: () -> Bool = { false }) throws -> Result {
        if !query.isEmpty, !options.isPlain { _ = try TextSearchService.regularExpression(query: query, options: options) }
        var order: [UUID] = []
        var revisions: [UUID: UInt] = [:]
        var documents: [DocumentMatches] = []
        var skipped: [Skipped] = []
        for source in sources {
            if isCancelled() { throw CancellationError() }
            guard source.skip == nil, let snapshot = source.snapshot else {
                skipped.append(Skipped(documentID: source.documentID, title: source.title, reason: source.skip ?? .busy))
                continue
            }
            let ranges = try TextSearchService.allRanges(in: snapshot.text, query: query, options: options, isCancelled: isCancelled)
            // allRanges при отмене возвращает пустой список: частичный результат не нужен.
            if isCancelled() { throw CancellationError() }
            order.append(source.documentID)
            revisions[source.documentID] = snapshot.revision
            if !ranges.isEmpty {
                documents.append(DocumentMatches(documentID: source.documentID, title: source.title,
                                                 revision: snapshot.revision, ranges: ranges))
            }
        }
        return Result(order: order, revisions: revisions, documents: documents, skipped: skipped)
    }

    /// Следующее/предыдущее совпадение с переходом между документами и кругом (после последнего — первое).
    /// `from.documentID` может быть вне `order` (закрыт): тогда идём с начала (вперёд) или с конца (назад).
    static func step(in result: Result, from: Position, backwards: Bool) -> Position? {
        let order = result.order
        guard !order.isEmpty, !result.documents.isEmpty else { return nil }
        let byID = Dictionary(result.documents.map { ($0.documentID, $0.ranges) }, uniquingKeysWith: { first, _ in first })
        let current = order.firstIndex(of: from.documentID)

        if !backwards {
            if let current, let ranges = byID[order[current]],
               let range = ranges.first(where: { $0.location >= NSMaxRange(from.range) }) {
                return Position(documentID: order[current], range: range)
            }
            let start = current.map { $0 + 1 } ?? 0
            // Последний шаг круга — снова текущий документ с его первым совпадением.
            for offset in 0..<order.count {
                let id = order[(start + offset) % order.count]
                if let range = byID[id]?.first { return Position(documentID: id, range: range) }
            }
            return nil
        }

        if let current, let ranges = byID[order[current]],
           let range = ranges.last(where: { NSMaxRange($0) <= from.range.location }) {
            return Position(documentID: order[current], range: range)
        }
        let start = current.map { $0 - 1 } ?? order.count - 1
        for offset in 0..<order.count {
            let id = order[((start - offset) % order.count + order.count) % order.count]
            if let range = byID[id]?.last { return Position(documentID: id, range: range) }
        }
        return nil
    }

    /// Извлечение по всем непропущенным документам: к каждой записи добавляется «имя:строка: ».
    /// Порядок — порядок вкладок, внутри документа — порядок текста.
    static func extract(sources: [Source], request: MatchExtractionService.Request,
                        isCancelled: () -> Bool = { false }) throws -> (records: [MatchExtractionService.Record], skipped: [Skipped]) {
        if !request.query.isEmpty, !request.options.isPlain {
            _ = try TextSearchService.regularExpression(query: request.query, options: request.options)
        }
        var records: [MatchExtractionService.Record] = []
        var skipped: [Skipped] = []
        for source in sources {
            if isCancelled() { throw CancellationError() }
            guard source.skip == nil, let snapshot = source.snapshot else {
                skipped.append(Skipped(documentID: source.documentID, title: source.title, reason: source.skip ?? .busy))
                continue
            }
            for record in try MatchExtractionService.records(in: snapshot.text, request: request, isCancelled: isCancelled) {
                records.append(.init(line: record.line, text: "\(source.title):\(record.line): \(record.text)"))
            }
        }
        return (records, skipped)
    }
}

import Foundation

extension OpenDocumentsSearchService.SkipReason {
    /// Причина пропуска для пользователя; ветки по тексту не выбираются.
    var localizedText: String {
        switch self {
        case .opening: L10n.tr("正在打开")
        case .largeFile: L10n.tr("大文件")
        case .readingMode: L10n.tr("阅读模式下无法修改")
        case .protectedPage: L10n.tr("受服务器保护的页面已跳过")
        case .busy: L10n.tr("无法修改已打开的文档")
        case .changed: L10n.tr("文档已变化")
        }
    }
}

extension OpenDocumentsSearchService.Skipped {
    /// «имя (причина)» для счётчика и итогов.
    var localizedTitle: String { L10n.tr("%@（%@）", title, reason.localizedText) }
}

/// Поиск и замена по открытым документам. Зависимости передаются замыканиями (окна и редакторы — у вызывающего),
/// поэтому контроллер проверяется без окон. Состояния для экрана он не хранит: результат возвращается вызывающему.
@MainActor
final class OpenDocumentsSearchController {
    struct ReplaceSummary: Equatable {
        let matchCount: Int
        let documentCount: Int
    }

    struct ReplacedItem: Equatable {
        let title: String
        let count: Int
    }

    struct ReplaceReport: Equatable {
        var replaced: [ReplacedItem]
        var skipped: [OpenDocumentsSearchService.Skipped]
        var replacedCount: Int { replaced.reduce(0) { $0 + $1.count } }
    }

    private let sources: (_ forReplace: Bool) -> [OpenDocumentsSearchService.Source]
    private let revealMatch: (_ position: OpenDocumentsSearchService.Position, _ revision: UInt, _ focusEditor: Bool) -> Bool
    private let replace: (_ documentID: UUID, _ revision: UInt, _ request: FolderReplaceService.Request) async -> FolderReplaceService.Outcome
    private let confirmReplace: (ReplaceSummary) -> Bool

    init(sources: @escaping (_ forReplace: Bool) -> [OpenDocumentsSearchService.Source],
         reveal: @escaping (_ position: OpenDocumentsSearchService.Position, _ revision: UInt, _ focusEditor: Bool) -> Bool,
         replace: @escaping (_ documentID: UUID, _ revision: UInt, _ request: FolderReplaceService.Request) async -> FolderReplaceService.Outcome,
         confirmReplace: @escaping (ReplaceSummary) -> Bool) {
        self.sources = sources
        self.revealMatch = reveal
        self.replace = replace
        self.confirmReplace = confirmReplace
    }

    /// Снимки собираются на главном потоке, подсчёт идёт в отменяемой фоновой задаче.
    func search(query: String, options: TextSearchService.Options) async throws -> OpenDocumentsSearchService.Result {
        try await compute(sources: sources(false), query: query, options: options)
    }

    func step(from: OpenDocumentsSearchService.Position, backwards: Bool, query: String, options: TextSearchService.Options)
        async throws -> (target: OpenDocumentsSearchService.Position?, revision: UInt?, result: OpenDocumentsSearchService.Result) {
        let result = try await compute(sources: sources(false), query: query, options: options)
        let target = OpenDocumentsSearchService.step(in: result, from: from, backwards: backwards)
        return (target, target.flatMap { result.revisions[$0.documentID] }, result)
    }

    func reveal(_ position: OpenDocumentsSearchService.Position, revision: UInt, focusEditor: Bool) -> Bool {
        revealMatch(position, revision, focusEditor)
    }

    func extract(request: MatchExtractionService.Request) async throws
        -> (records: [MatchExtractionService.Record], skipped: [OpenDocumentsSearchService.Skipped]) {
        let snapshots = self.sources(false)
        let worker = Task.detached(priority: .userInitiated) {
            try OpenDocumentsSearchService.extract(sources: snapshots, request: request, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// nil — пользователь отказался. Документы идут по очереди; отмена останавливает следующие,
    /// уже выполненные остаются, запущенный документ не прерывается.
    func replaceAll(request: FolderReplaceService.Request) async throws -> ReplaceReport? {
        let result = try await compute(sources: sources(true), query: request.query, options: request.options)
        guard !result.documents.isEmpty else { return ReplaceReport(replaced: [], skipped: result.skipped) }
        guard confirmReplace(ReplaceSummary(matchCount: result.matchCount, documentCount: result.documents.count)) else { return nil }
        var report = ReplaceReport(replaced: [], skipped: result.skipped)
        for document in result.documents {
            if Task.isCancelled { break }
            switch await replace(document.documentID, document.revision, request) {
            case let .replaced(count):
                report.replaced.append(ReplacedItem(title: document.title, count: count))
            case .skipped(.changed):
                report.skipped.append(.init(documentID: document.documentID, title: document.title, reason: .changed))
            case .skipped:
                // Занят, не открылся в редакторе и прочие причины, которые сюда не приходят.
                report.skipped.append(.init(documentID: document.documentID, title: document.title, reason: .busy))
            }
        }
        return report
    }

    private func compute(sources: [OpenDocumentsSearchService.Source], query: String, options: TextSearchService.Options)
        async throws -> OpenDocumentsSearchService.Result {
        let worker = Task.detached(priority: .userInitiated) {
            try OpenDocumentsSearchService.search(sources: sources, query: query, options: options, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

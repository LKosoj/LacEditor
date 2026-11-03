import Foundation

/// Одна уникальная ссылка `[[цель#раздел|текст]]` в тексте открытой заметки.
struct VaultOutgoingLink: Equatable, Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        /// Путь на сервере.
        case resolved(path: String)
        case ambiguous(paths: [String])
        case missing(suggestedPath: String)
        /// Каталог ещё грузится, решение отложено.
        case checking
    }

    /// «цель#раздел» в нижнем регистре: одна строка на уникальную цель.
    var id: String
    var target: String
    var heading: String?
    /// Для показа: имя без расширения и пути.
    var title: String
    /// Сколько раз ссылка встречается.
    var count: Int
    /// Первое вхождение (для «Показать в тексте»), UTF-16.
    var firstRange: NSRange
    var status: Status
}

/// Ссылки «отсюда» для правой панели хранилища. Диск и сеть не трогает.
enum VaultLinks {
    /// Ссылки из текста в порядке первого вхождения. Пустая цель (`[[#Заголовок]]`) — эта же заметка, не показывается.
    /// Пока список заметок загружен не полностью, не найденная ссылка отдаётся как `.checking`: иначе при запуске были бы ложные ошибки.
    static func outgoing(in text: String, resolver: MarkdownWikiLinkResolver, isCatalogComplete: Bool,
                         isCancelled: @escaping () -> Bool = { false }) -> [VaultOutgoingLink] {
        let found = MarkdownWikiLinkExtractor.links(in: text, isCancelled: isCancelled)
        if isCancelled() { return [] }
        var order: [String] = []
        var byID: [String: VaultOutgoingLink] = [:]
        for link in found {
            let target = link.target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let heading = link.heading?.trimmingCharacters(in: .whitespaces)
            let id = MarkdownWikiLinkResolver.fold(target) + "#" + MarkdownWikiLinkResolver.fold(heading ?? "")
            if var existing = byID[id] {
                existing.count += 1
                byID[id] = existing
                continue
            }
            order.append(id)
            byID[id] = VaultOutgoingLink(
                id: id, target: target, heading: heading?.isEmpty == true ? nil : heading, title: title(of: target), count: 1,
                firstRange: link.range, status: status(of: target, resolver: resolver, isCatalogComplete: isCatalogComplete))
        }
        return order.compactMap { byID[$0] }
    }

    private static func status(of target: String, resolver: MarkdownWikiLinkResolver, isCatalogComplete: Bool) -> VaultOutgoingLink.Status {
        switch resolver.resolve(target: target) {
        case .currentDocument, .invalid:
            return isCatalogComplete ? .missing(suggestedPath: target) : .checking
        case let .file(path):
            return .resolved(path: path)
        case let .ambiguous(paths):
            return .ambiguous(paths: paths)
        case let .missing(suggested):
            return isCatalogComplete ? .missing(suggestedPath: suggested) : .checking
        }
    }

    private static func title(of target: String) -> String {
        stem((target as NSString).lastPathComponent)
    }

    private static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? (name as NSString).deletingPathExtension : name
    }

    /// Резолвер для хранилища: база — условный `file:///vault` (нужна только как признак «база есть»; адреса из него не строятся).
    static func resolver(paths: [String], token: UInt) -> MarkdownWikiLinkResolver {
        MarkdownWikiLinkResolver(base: URL(string: "file:///vault"), paths: paths, token: token)
    }

    /// До `limit` ближайших имён: ранг `FolderSearchService.NameQuery` (имя совпало, путь содержит, буквы идут подряд с пропусками),
    /// затем разница длин имён, затем путь. Ловит пропущенные буквы и обрезанные названия; перестановки и лишние буквы — нет.
    static func similar(to target: String, in paths: [String], limit: Int = 5, isCancelled: () -> Bool = { false }) -> [String] {
        let query = title(of: target)
        guard !query.isEmpty, limit > 0 else { return [] }
        let matcher = FolderSearchService.NameQuery(query, caseSensitive: false)
        var ranked: [(rank: Int, difference: Int, path: String)] = []
        for path in paths {
            if isCancelled() { return [] }
            let name = stem((path as NSString).lastPathComponent)
            guard let rank = try? matcher.rank(path: path, name: name, isCancelled: isCancelled) else { continue }
            ranked.append((rank, abs(name.count - query.count), path))
        }
        ranked.sort { ($0.rank, $0.difference, $0.path) < ($1.rank, $1.difference, $1.path) }
        return ranked.prefix(limit).map(\.path)
    }
}

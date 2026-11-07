import Foundation

/// Общие запросы к модели документа (U7.0): плоские списки заголовков, ссылок, wiki-ссылок, формул и оглавления
/// в порядке документа, в позициях UTF-16 исходника. AppKit и cmark не нужны.
/// Правила отбора те же, что у полей `MarkdownPresentation` (`tableOfContents`, `wikiLinks` и др.): не берём узлы без подтверждённой позиции (`isUnreliable`),
/// узлы в таблицах и определениях сносок (где это было нужно), а также всё, что пересекает неподтверждённый HTML (`blockedHTML`)
/// или закрыто медиа (`overlapsMedia`, как в `MarkdownPresentationBuilder+Filter`).
struct MarkdownDocumentQueries: Equatable, Sendable {
    /// Что собирать: обход считает только запрошенное.
    struct Want: OptionSet, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let wikiLinks = Want(rawValue: 1 << 0)
        static let links = Want(rawValue: 1 << 1)
        static let headings = Want(rawValue: 1 << 2)
        static let formulas = Want(rawValue: 1 << 3)
        static let tableOfContents = Want(rawValue: 1 << 4)
        static let headingMarkers = Want(rawValue: 1 << 5)
        static let emoji = Want(rawValue: 1 << 6)
        static let all: Want = [.wikiLinks, .links, .headings, .formulas, .tableOfContents, .headingMarkers, .emoji]
    }

    /// Ссылка с разметкой: `markers[1]` — хвост `](…)` у `[текст](адрес)`; у других форм (ссылочная, автоссылка, `<a href>`) маркеров нет.
    struct LinkEntry: Equatable, Sendable {
        var link: MarkdownLink
        var markers: [NSRange]
        var form: MarkdownInlineNode.Link.Form
    }

    var wikiLinks: [MarkdownWikiLink] = []
    var linkEntries: [LinkEntry] = []
    var headings: [MarkdownHeading] = []
    var formulas: [MarkdownFormula] = []
    var inlineFormulas: [MarkdownFormula] = []
    var tableOfContentsRanges: [NSRange] = []
    var headingMarkerRanges: [NSRange] = []
    var emojiCandidates: [MarkdownEmojiCandidate] = []
    var emojiCompletionRanges: [NSRange] = []

    static let empty = MarkdownDocumentQueries()
}

// MARK: - Значения из узлов (общие с MarkdownPresentationBuilder: правила отбора в одном месте)

extension MarkdownDocumentQueries.LinkEntry {
    /// `nil` — позиция не подтверждена или диапазон пуст. Маркеры отдаются только у `[текст](адрес)`: у остальных форм скобок для скрытия нет.
    init?(node: MarkdownInlineNode, _ link: MarkdownInlineNode.Link) {
        guard !node.isUnreliable, node.range.length > 0 else { return nil }
        self.init(link: MarkdownLink(range: node.range, url: link.url), markers: link.form == .inline ? node.markerRanges : [], form: link.form)
    }
}

extension MarkdownFormula {
    /// Формула в строке; `nil` — позиция не подтверждена.
    init?(node: MarkdownInlineNode, source: String) {
        guard !node.isUnreliable else { return nil }
        self.init(range: node.range, source: source)
    }

    /// Блок `$$…$$`; `nil` — позиция не подтверждена.
    init?(block: MarkdownBlockNode, source: String) {
        guard !block.isUnreliable else { return nil }
        self.init(range: block.range, source: source)
    }
}

extension MarkdownHeading {
    /// Заголовок без подтверждённой позиции остаётся в оглавлении якорем нулевой длины в начале строки;
    /// оформление (`plainTextRange`, `uppercaseRuns`) у него не передаётся.
    init(block: MarkdownBlockNode, _ heading: MarkdownBlockNode.Heading, plainTextRange: NSRange? = nil, uppercaseRuns: [UppercaseRun]? = nil) {
        let range = block.isUnreliable ? NSRange(location: block.range.location, length: 0) : block.range
        self.init(level: heading.level, title: heading.title, range: range, emoji: heading.emoji,
                  plainTextRange: block.isUnreliable ? nil : plainTextRange, uppercaseRuns: block.isUnreliable ? nil : uppercaseRuns,
                  isTopLevel: heading.isTopLevel)
    }
}

extension MarkdownBlockNode.HTMLBlock.Kind {
    /// Блок занимает рамку медиа (audio, iframe, подтверждённый twitter): картинки, формулы и эмодзи под ним не показываются.
    /// У twitter рамка строится, только если адрес разбирается как `URL` (как `MarkdownHTMLMediaService.twitterFrame`).
    var isMediaFrame: Bool {
        switch self {
        case .media, .iframe: return true
        case .twitter(let widget): return URL(string: widget.iframeURL) != nil
        default: return false
        }
    }
}

extension MarkdownInlineNode {
    /// Строчный audio или iframe: рамка медиа.
    var isMediaFrame: Bool {
        switch kind {
        case .media, .iframe: return true
        default: return false
        }
    }
}

/// Отсортированные диапазоны для вопроса «пересекает ли что-то из них этот диапазон» (двоичный поиск по префиксным максимумам концов).
struct MarkdownSortedRanges: Sendable {
    private let ranges: [NSRange]
    private let ends: [Int]

    init(_ source: [NSRange]) {
        var sorted = source
        if !zip(sorted, sorted.dropFirst()).allSatisfy({ $0.location <= $1.location }) { sorted.sort { $0.location < $1.location } }
        var maximumEnd = 0
        ranges = sorted
        ends = sorted.map { maximumEnd = max(maximumEnd, NSMaxRange($0)); return maximumEnd }
    }

    var isEmpty: Bool { ranges.isEmpty }

    /// При отмене отвечает `true` (всё считается закрытым, результат выбрасывается по отмене).
    func overlaps(_ range: NSRange, isCancelled: () -> Bool = { false }) -> Bool {
        if isCancelled() { return true }
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].location < NSMaxRange(range) { low = middle + 1 } else { high = middle }
        }
        return low > 0 && ends[low - 1] > range.location
    }
}

extension MarkdownDocumentModel {
    /// Один обход модели. `nil` — отмена.
    func queries(_ want: MarkdownDocumentQueries.Want = .all, isCancelled: @escaping () -> Bool = { false }) -> MarkdownDocumentQueries? {
        var walk = MarkdownDocumentQueryWalk(model: self, want: want, isCancelled: isCancelled)
        return walk.run()
    }

    // Каждое свойство ниже — отдельный полный обход модели. Нужно несколько полей — зови `queries([...])` один раз.

    /// `[[…]]` без `![[…]]`; вне таблиц и определений сносок.
    var wikiLinks: [MarkdownWikiLink] { queries(.wikiLinks)?.wikiLinks ?? [] }
    /// Все ссылки: `[текст](адрес)`, ссылочная форма, автоссылка, `<a href>`.
    var linkEntries: [MarkdownDocumentQueries.LinkEntry] { queries(.links)?.linkEntries ?? [] }
    /// Заголовки вне таблиц, картинок и определений сносок; заголовок без подтверждённой позиции — якорь нулевой длины в начале строки.
    var headings: [MarkdownHeading] { queries(.headings)?.headings ?? [] }
    var formulas: [MarkdownFormula] { queries(.formulas)?.formulas ?? [] }
    var inlineFormulas: [MarkdownFormula] { queries(.formulas)?.inlineFormulas ?? [] }
    var tableOfContentsRanges: [NSRange] { queries(.tableOfContents)?.tableOfContentsRanges ?? [] }
    /// Первый маркер (`##`) у ATX-заголовков с подтверждённой позицией.
    var headingMarkerRanges: [NSRange] { queries(.headingMarkers)?.headingMarkerRanges ?? [] }
}

extension MarkdownDocumentParser {
    /// Разбор для потребителей без отмены: при `nil` (отмена или сбой) — пустая модель.
    /// Вызывающий сам проверяет `isCancelled()` после вызова.
    static func parseOrEmpty(_ text: String, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(), includes: MarkdownDocumentModel.Includes = [],
                             isCancelled: @escaping () -> Bool = { false }) -> MarkdownDocumentModel {
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: false, detectsFrontMatter: true)
        if let model = parse(text, options: options, isCancelled: isCancelled) { return model }
        return MarkdownDocumentModel(revision: nil, textLength: 0, options: options, blocks: [], frontMatter: nil, unreliableRanges: [],
                                     headingIDs: [], namedAnchors: [], footnotes: [], looseIndents: [], smartReplacements: [],
                                     fence: nil, emoji: nil, readableText: nil, blockIndex: nil, elements: nil)
    }
}

// MARK: - Значения из узлов (их же использует MarkdownPresentationBuilder)

extension MarkdownWikiLink {
    init(node: MarkdownInlineNode, _ wiki: MarkdownInlineNode.WikiLink) {
        self.init(range: node.range, displayRange: wiki.displayRange, target: wiki.target, heading: wiki.heading,
                  alias: wiki.alias, markerRanges: node.markerRanges)
    }
}

// MARK: - Обход

private struct MarkdownDocumentQueryWalk {
    let model: MarkdownDocumentModel
    let want: MarkdownDocumentQueries.Want
    let isCancelled: () -> Bool
    var result = MarkdownDocumentQueries()
    var cancelled = false
    /// Диапазоны audio/iframe: ими закрыты формулы в строке и эмодзи (как в `applyingDisplayFilter`).
    var mediaRanges: [NSRange] = []
    /// Первый маркер ATX-заголовка и диапазон самого заголовка: `blockedHTML` отсеивает по заголовку.
    var headingMarkers: [(heading: NSRange, marker: NSRange)] = []

    init(model: MarkdownDocumentModel, want: MarkdownDocumentQueries.Want, isCancelled: @escaping () -> Bool) {
        self.model = model
        self.want = want
        self.isCancelled = isCancelled
    }

    mutating func run() -> MarkdownDocumentQueries? {
        if want.contains(.emoji), let emoji = model.emoji {
            result.emojiCandidates = emoji.candidates
            result.emojiCompletionRanges = emoji.completionRanges
        }
        walk(model.blocks, unsupported: false)
        if cancelled || isCancelled() { return nil }
        return finish()
    }

    private mutating func stop() -> Bool {
        if !cancelled && isCancelled() { cancelled = true }
        return cancelled
    }

    private mutating func walk(_ blocks: [MarkdownBlockNode], unsupported: Bool) {
        for block in blocks {
            if stop() { return }
            visit(block, unsupported: unsupported)
        }
    }

    private mutating func visit(_ block: MarkdownBlockNode, unsupported: Bool) {
        var inner = unsupported
        switch block.kind {
        case .heading(let heading):
            if want.contains(.headings) || want.contains(.headingMarkers), !unsupported, !heading.inUnsupportedContainer { addHeading(block, heading) }
        case .mathBlock(let source):
            if want.contains(.formulas), let formula = MarkdownFormula(block: block, source: source) { result.formulas.append(formula) }
        case .tableOfContents:
            if want.contains(.tableOfContents), !unsupported, !block.isUnreliable { result.tableOfContentsRanges.append(block.range) }
        case .footnoteDefinition:
            inner = true
        case .html(let html):
            if !unsupported, !block.isUnreliable, html.kind.isMediaFrame { mediaRanges.append(block.range) }
        case .table(let table):
            // Таблица внутри определения сноски builder не оформляет и в ячейки не заходит. У самой таблицы своих `inlines` и `children` нет.
            if !unsupported {
                for row in table.rows {
                    for cell in row.cells { walk(cell.inlines, unsupported: true) }
                }
            }
            return
        default:
            break
        }
        walk(block.inlines, unsupported: inner)
        walk(block.children, unsupported: inner)
    }

    private mutating func addHeading(_ block: MarkdownBlockNode, _ heading: MarkdownBlockNode.Heading) {
        if want.contains(.headings) {
            result.headings.append(MarkdownHeading(block: block, heading))
        }
        if want.contains(.headingMarkers), !block.isUnreliable, heading.style == .atx, let marker = block.markerRanges.first {
            headingMarkers.append((block.range, marker))
        }
    }

    private mutating func walk(_ nodes: [MarkdownInlineNode], unsupported: Bool) {
        for node in nodes {
            if stop() { return }
            visit(node, unsupported: unsupported)
            walk(node.children, unsupported: unsupported)
        }
    }

    private mutating func visit(_ node: MarkdownInlineNode, unsupported: Bool) {
        switch node.kind {
        case .link(let link):
            if want.contains(.links), let entry = MarkdownDocumentQueries.LinkEntry(node: node, link) { result.linkEntries.append(entry) }
        case .wikiLink(let wiki):
            if want.contains(.wikiLinks), !unsupported, !node.isUnreliable { result.wikiLinks.append(MarkdownWikiLink(node: node, wiki)) }
        case .formula(let source):
            if want.contains(.formulas), let formula = MarkdownFormula(node: node, source: source) { result.inlineFormulas.append(formula) }
        default:
            if node.isMediaFrame, !unsupported, !node.isUnreliable { mediaRanges.append(node.range) }
        }
    }

    // MARK: Отсев

    /// Отсев показа: сначала перекрытие медиа, потом `blockedHTML` (порядок как в `applyingDisplayFilter`).
    private mutating func finish() -> MarkdownDocumentQueries? {
        var out = result
        if !mediaRanges.isEmpty {
            let media = MarkdownSortedRanges(mediaRanges)
            out.inlineFormulas = out.inlineFormulas.filter { !media.overlaps($0.range) }
            out.emojiCandidates = out.emojiCandidates.filter { !media.overlaps($0.range) }
        }
        let blockedHTML = model.blockedHTML
        var markers = headingMarkers
        if !blockedHTML.isEmpty {
            let blockedSet = MarkdownSortedRanges(blockedHTML)
            func blocked(_ range: NSRange) -> Bool { blockedSet.overlaps(range) }
            out.wikiLinks.removeAll { blocked($0.range) }
            out.linkEntries.removeAll { blocked($0.link.range) }
            out.formulas.removeAll { blocked($0.range) }
            out.inlineFormulas.removeAll { blocked($0.range) }
            out.tableOfContentsRanges.removeAll { blocked($0) }
            out.emojiCandidates.removeAll { blocked($0.range) }
            out.emojiCompletionRanges.removeAll { blocked($0) }
            markers.removeAll { blocked($0.heading) }
        }
        out.headingMarkerRanges = markers.map(\.marker)
        return isCancelled() ? nil : out
    }
}

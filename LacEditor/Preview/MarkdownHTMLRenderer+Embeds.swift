import Foundation

/// Состояние страницы для встраиваний `![[заметка]]` (U3.3): настройки разбора для вложенной заметки, счётчики и кэши.
final class ObsidianPageState {
    let syntax: MarkdownSyntaxOptions
    let isVaultNote: Bool
    let provider: (any MarkdownNoteEmbedProvider)?
    /// Сколько блочных встраиваний заметок с провайдером уже выведено (порядковый номер для `maxEmbedsPerPage`).
    var number = 0
    /// Сумма прочитанных байтов (по первому чтению цели, не больше `maxNoteBytes` на заметку).
    var totalBytes = 0
    /// Прочитанные заметки по цели; `nil` в значении — заметки нет или лимит исчерпан (повторно не читается).
    var notes: [String: String?] = [:]
    /// Готовая врезка по ключу `цель + \0 + раздел`: одна и та же врезка не разбирается дважды.
    var sections: [String: String] = [:]
    /// Адрес wiki-ссылки по ключу `цель#заголовок`: на странице одна и та же ссылка ищется один раз.
    var hrefs: [String: String?] = [:]

    init(syntax: MarkdownSyntaxOptions = .init(), isVaultNote: Bool = false, provider: (any MarkdownNoteEmbedProvider)? = nil) {
        self.syntax = syntax
        self.isVaultNote = isVaultNote
        self.provider = provider
    }
}

/// Блочные встраивания (U3.3, п. 3.4 плана). Вложенная заметка разбирается своей моделью без `Includes`: это и есть «глубина 1».
extension MarkdownHTMLRenderer {
    static func writeNoteEmbedBlock(_ node: MarkdownBlockNode, _ embed: MarkdownBlockNode.NoteEmbed, _ w: Writer) {
        let state = w.obsidian
        if embed.kind == .note, state.provider != nil {
            w.cr()
            w.put(embedSection(embed, state, w))
            w.put("\n")
            return
        }
        w.cr()
        w.put("<p\(w.sp(node))>")
        if embed.kind == .note {
            writeText(w.slice(node.range), w)
        } else {
            writeFileEmbed(range: node.range, embed, isBlock: true, w)
        }
        w.put("</p>\n")
    }

    /// HTML врезки: лимиты и порядок чтения — по правилам встраивания заметок (лимиты в `MarkdownNoteEmbed`).
    private static func embedSection(_ embed: MarkdownBlockNode.NoteEmbed, _ state: ObsidianPageState, _ w: Writer) -> String {
        let number = state.number
        state.number += 1
        let outcome: MarkdownNoteEmbed.Outcome
        let key = embed.target + "\0" + (embed.heading ?? "")
        if number >= MarkdownNoteEmbed.maxEmbedsPerPage {
            outcome = .missingNote
        } else if let cached = state.sections[key] {
            return cached
        } else {
            outcome = embedOutcome(embed, state, w)
        }
        let href = state.provider?.openAddress(for: embed.target, heading: embed.heading)
            ?? w.wiki?.relativeHref(for: MarkdownWikiLink(range: NSRange(location: 0, length: 0), displayRange: NSRange(location: 0, length: 0),
                                                         target: embed.target, heading: embed.heading, alias: nil, markerRanges: []))
        let html = MarkdownNoteEmbed.blockHTML(name: embed.target, heading: embed.heading, href: href, outcome: outcome)
        if number < MarkdownNoteEmbed.maxEmbedsPerPage { state.sections[key] = html }
        return html
    }

    private static func embedOutcome(_ embed: MarkdownBlockNode.NoteEmbed, _ state: ObsidianPageState, _ w: Writer) -> MarkdownNoteEmbed.Outcome {
        let note: String?
        if let cached = state.notes[embed.target] {
            note = cached
        } else {
            var read = state.provider?.embeddedNote(for: embed.target)
            if let value = read {
                let bytes = min(value.utf8.count, MarkdownNoteEmbed.maxNoteBytes)
                if state.totalBytes + bytes > MarkdownNoteEmbed.maxTotalBytes { read = nil } else { state.totalBytes += bytes }
            }
            state.notes[embed.target] = .some(read)
            note = read
        }
        guard let note else { return .missingNote }
        var content = MarkdownNoteEmbed.body(of: note)
        if let heading = embed.heading {
            guard let section = MarkdownNoteEmbed.section(of: content, heading: heading) else { return .missingSection }
            content = section
        }
        let (limited, wasCut) = MarkdownNoteEmbed.limitedNote(content)
        // Как при разборе удобного входа: NUL заменяется на U+FFFD, срезы берутся из того же текста.
        let text = limited.utf8.contains(0) ? limited.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") : limited
        let options = MarkdownDocumentModel.Options(syntax: state.syntax, includes: [], isVaultNote: state.isVaultNote, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(text, options: options, isCancelled: { Task.isCancelled }) else { return .missingNote }
        let page = renderPage(model, text: text, darkMode: w.darkMode, forExport: w.forExport)
        return .content(html: MarkdownNoteEmbed.flatten(page.body), truncated: wasCut)
    }
}

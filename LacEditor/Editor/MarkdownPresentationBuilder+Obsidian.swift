import Foundation

/// Оформление CriticMarkup, `%%`, выносок и `![[…]]` в редакторе (U5a, часть А): узлы модели → span-ы и записи wiki-ссылок.
/// Чистые функции без состояния; `Walker` из `MarkdownPresentationBuilder.swift` только вызывает их.
extension MarkdownPresentationBuilder {
    /// Правка CriticMarkup: весь `{…}` одним span-ом, цвет у «было» и «стало» общий.
    static func criticSpan(_ node: MarkdownInlineNode, kind: CriticMarkupKind) -> MarkdownPresentationSpan {
        MarkdownPresentationSpan(range: node.range, kind: .critic(kind), markerRanges: node.markerRanges)
    }

    /// Комментарий `%%…%%` (блочный и строчный): знаки `%%` — маркеры. Узлы бывают только в заметках хранилища.
    static func obsidianCommentSpan(range: NSRange, markerRanges: [NSRange]) -> MarkdownPresentationSpan {
        MarkdownPresentationSpan(range: range, kind: .obsidianComment, markerRanges: markerRanges)
    }

    /// Выноска `> [!тип]± заголовок`: подпись (знак и название типа) вместо маркера, заголовок жирным; тело остаётся цитатой.
    static func calloutSpans(_ block: MarkdownBlockNode, _ callout: MarkdownBlockNode.Callout) -> [MarkdownPresentationSpan] {
        // Неизвестный тип оформляется как `.note` с подписью самого типа (как в предпросмотре).
        let kind = callout.kind ?? .note
        let caption = callout.kind?.label ?? MarkdownCalloutRender.capitalized(callout.type)
        var spans = [MarkdownPresentationSpan(range: block.range, kind: .callout(label: kind.symbol + " " + caption, kind: kind),
                                              markerRanges: [callout.markerRange])]
        if let title = callout.titleRange, title.length > 0 {
            spans.append(MarkdownPresentationSpan(range: title, kind: .strong, markerRanges: []))
        }
        return spans
    }

    /// Встраивание `![[цель#раздел|подпись]]` как wiki-ссылка с `isEmbed`. Правила показа те же, что у `[[…]]`:
    /// видна подпись, а без неё — всё содержимое; остальное (`![[`, цель с `|`, `]]`) — маркеры. Не подтвердилось по тексту — nil.
    static func embedLink(range: NSRange, _ embed: MarkdownBlockNode.NoteEmbed, text: NSString) -> MarkdownWikiLink? {
        guard range.location >= 0, range.length >= 6, NSMaxRange(range) <= text.length,
              text.character(at: range.location) == 33, text.character(at: range.location + 1) == 91, text.character(at: range.location + 2) == 91,
              text.character(at: NSMaxRange(range) - 2) == 93, text.character(at: NSMaxRange(range) - 1) == 93 else { return nil }
        let innerStart = range.location + 3, close = NSMaxRange(range) - 2
        var pipe: Int?
        for position in innerStart..<close where text.character(at: position) == 124 { pipe = position; break }
        let displayStart = pipe.map { $0 + 1 } ?? innerStart
        var start = displayStart, end = close
        func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        let display = NSRange(location: start, length: end - start)
        // Пустая подпись после `|` — не встраивание (как `[[a|]]` у `MarkdownWikiLinkExtractor`).
        if pipe != nil, display.length == 0 { return nil }
        let opening = NSRange(location: range.location, length: display.location - range.location)
        let closing = NSRange(location: NSMaxRange(display), length: NSMaxRange(range) - NSMaxRange(display))
        return MarkdownWikiLink(range: range, displayRange: display, target: embed.target, heading: embed.heading, alias: embed.alias,
                                markerRanges: [opening, closing], isEmbed: true)
    }
}

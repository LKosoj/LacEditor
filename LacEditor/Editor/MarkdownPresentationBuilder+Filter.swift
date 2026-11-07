import Foundation

/// Отсев показа (U5.1.c): что закрыто медиа или неподтверждённым HTML, того в оформлении быть не должно.
extension MarkdownPresentationBuilder {
    /// `nil` — отмена. Порядок: перекрытие медиа → безопасные замены (`safeText`) → `blockedHTML`.
    /// `safeText` считается по полям до отсева `blockedHTML`; сами замены под `blockedHTML` убираются после.
    /// `blockedHTML` — отсортированные и слитые диапазоны неподтверждённых строчных HTML-тегов и ruby (их отдаёт ядро).
    static func applyingDisplayFilter(_ draft: Draft, blockedHTML: [NSRange], text: NSString, isCancelled: () -> Bool) -> Draft? {
        var draft = draft
        if isCancelled() { return nil }

        // Картинки, формулы в строке и эмодзи внутри audio/iframe не показываются: ими занято медиа.
        if !draft.audioBlocks.isEmpty || !draft.iframeBlocks.isEmpty {
            let media = MarkdownSortedRanges(draft.audioBlocks.map(\.range) + draft.iframeBlocks.map(\.range))
            func overlapsMedia(_ range: NSRange) -> Bool { media.overlaps(range) }
            var keptImages: [MarkdownImage] = [], keptFormulas: [MarkdownFormula] = [], keptEmoji: [MarkdownEmojiCandidate] = []
            for image in draft.images { if isCancelled() { return nil }; if !overlapsMedia(image.range) { keptImages.append(image) } }
            for formula in draft.inlineFormulas { if isCancelled() { return nil }; if !overlapsMedia(formula.range) { keptFormulas.append(formula) } }
            for candidate in draft.emojiCandidates { if isCancelled() { return nil }; if !overlapsMedia(candidate.range) { keptEmoji.append(candidate) } }
            draft.images = keptImages; draft.inlineFormulas = keptFormulas; draft.emojiCandidates = keptEmoji
        }

        // Безопасные замены: те, что не лежат внутри картинок, медиа, HTML, формул, эмодзи, таблиц и оглавления.
        if !draft.textReplacements.isEmpty {
            let blockedText = (draft.images.map(\.range) + draft.audioBlocks.map(\.range) + draft.iframeBlocks.map(\.range)
                + draft.detailsBlocks.map(\.range) + draft.htmlBlocks.map(\.range) + draft.ruby.map(\.range) + draft.diagrams.map(\.range)
                + draft.formulas.map(\.range) + draft.inlineFormulas.map(\.range) + draft.emojiCandidates.map(\.range)
                + draft.tables.map(\.range) + draft.tableOfContents).sorted { $0.location < $1.location }
            var blockedEnd = 0
            var blockedEnds: [Int] = []
            for range in blockedText {
                if isCancelled() { return nil }
                blockedEnd = max(blockedEnd, NSMaxRange(range))
                blockedEnds.append(blockedEnd)
            }
            var safeText: [MarkdownTextReplacement] = []
            for replacement in draft.textReplacements {
                if isCancelled() { return nil }
                var low = 0, high = blockedEnds.count
                while low < high {
                    let middle = (low + high) / 2
                    if blockedEnds[middle] <= replacement.range.location { low = middle + 1 } else { high = middle }
                }
                if low == blockedText.count || blockedText[low].location >= NSMaxRange(replacement.range) { safeText.append(replacement) }
            }
            safeText.sort { $0.range.location < $1.range.location }
            draft.textReplacements = safeText
        }

        // Неподтверждённый HTML: всё, что его пересекает, в оформление не попадает.
        if !blockedHTML.isEmpty {
            let blockedSet = MarkdownSortedRanges(blockedHTML)
            func blocked(_ range: NSRange) -> Bool { blockedSet.overlaps(range, isCancelled: isCancelled) }
            draft.spans.removeAll { blocked($0.range) }
            draft.links.removeAll { blocked($0.range) }
            draft.wikiLinks.removeAll { blocked($0.range) }
            draft.namedAnchors.removeAll { blocked($0.range) }
            draft.images.removeAll { blocked($0.range) }
            draft.audioBlocks.removeAll { blocked($0.range) }
            draft.iframeBlocks.removeAll { blocked($0.range) }
            draft.detailsBlocks.removeAll { blocked($0.range) }
            draft.htmlBlocks.removeAll { blocked($0.range) }
            draft.pageBreaks.removeAll { blocked($0) }
            draft.ruby.removeAll { blocked($0.range) }
            draft.diagrams.removeAll { blocked($0.range) }
            draft.formulas.removeAll { blocked($0.range) }
            draft.inlineFormulas.removeAll { blocked($0.range) }
            draft.emojiCandidates.removeAll { blocked($0.range) }
            draft.emojiCompletionRanges.removeAll { blocked($0) }
            draft.smartTextRanges.removeAll { blocked($0) }
            draft.textReplacements.removeAll { blocked($0.range) }
            draft.paragraphs.removeAll { blocked($0.range) }
            draft.completedTaskRanges.removeAll { blocked($0) }
            draft.taskCheckboxes.removeAll { blocked($0.markerRange) }
            draft.listMarkers.removeAll { blocked($0.line) }
            draft.footnotes.removeAll { blocked($0.referenceRange) || blocked($0.definitionRange) }
            draft.tableOfContents.removeAll { blocked($0) }
            draft.codeBlocks.removeAll { blocked($0.range) }
            draft.headings = draft.headings.map { heading in
                guard blocked(heading.range) else { return heading }
                return MarkdownHeading(level: heading.level, title: heading.title, range: heading.range, emoji: heading.emoji,
                    displayTitle: heading.displayTitle, number: nil, plainTextRange: nil, uppercaseRuns: nil, isTopLevel: heading.isTopLevel)
            }
            draft.tables = draft.tables.map { table in
                guard blocked(table.range) else { return table }
                let rows = table.rows.map { row in
                    MarkdownTableRow(range: row.range, cells: row.cells.map { cell in
                        guard blocked(cell.range), cell.range.location >= 0, NSMaxRange(cell.range) <= text.length else { return cell }
                        return MarkdownTableCell(range: cell.range, column: cell.column, virtualSeparators: cell.virtualSeparators,
                            displayText: text.substring(with: cell.range), displayRuns: [])
                    })
                }
                return MarkdownTable(range: table.range, delimiterRange: table.delimiterRange, alignments: table.alignments,
                    rows: rows, containerPrefix: table.containerPrefix, quoteDepth: table.quoteDepth,
                    nestedList: table.nestedList, referenceLabels: table.referenceLabels)
            }
            if isCancelled() { return nil }
        }
        return draft
    }
}

import Foundation

/// Склейка оформления для локального разбора (T5): элементы до участка берутся из прежнего оформления как есть,
/// элементы участка — из разбора фрагмента, элементы после участка — из прежнего со сдвигом.
extension MarkdownPresentation {
    /// Поле оформления, которое не удалось склеить (элемент пересекает границу участка, признак вне допущений локального разбора).
    struct Unmergeable: Error { let field: String }

    /// Все позиции сдвинуты на `delta` вправо (влево при отрицательном). Относительные диапазоны внутри элементов (эмодзи заголовка,
    /// цепочки подписи ruby, показываемый текст ячеек) не трогаются. Индекс элементов не переносится: его собирает склейка.
    func translated(by delta: Int) -> MarkdownPresentation {
        guard delta != 0 else { return self }
        func move(_ range: NSRange) -> NSRange { NSRange(location: range.location + delta, length: range.length) }
        func moved<T>(_ items: [T], _ keyPath: WritableKeyPath<T, NSRange>) -> [T] {
            items.map { item in var copy = item; copy[keyPath: keyPath] = move(item[keyPath: keyPath]); return copy }
        }
        let newSpans = spans.map { span -> MarkdownPresentationSpan in
            MarkdownPresentationSpan(range: move(span.range), kind: span.kind, markerRanges: span.markerRanges.map(move))
        }
        let newHeadings = headings.map { heading -> MarkdownHeading in
            let runs = heading.uppercaseRuns?.map { run in
                MarkdownHeading.UppercaseRun(
                    pieces: run.pieces.map { .init(sourceRange: move($0.sourceRange), text: $0.text, matchesSource: $0.matchesSource) },
                    styles: run.styles, emoji: run.emoji.map { .init(range: move($0.range), name: $0.name) }, attachment: run.attachment)
            }
            return MarkdownHeading(level: heading.level, title: heading.title, range: move(heading.range), emoji: heading.emoji, displayTitle: heading.displayTitle,
                                   number: heading.number, plainTextRange: heading.plainTextRange.map(move), uppercaseRuns: runs, isTopLevel: heading.isTopLevel)
        }
        let newImages = images.map { image -> MarkdownImage in
            var copy = image
            copy.range = move(image.range)
            copy.paragraphRange = move(image.paragraphRange)
            return copy
        }
        let newRuby = ruby.map { item -> MarkdownRuby in
            var copy = item
            copy.range = move(item.range)
            copy.baseRange = move(item.baseRange)
            copy.readingRange = move(item.readingRange)
            return copy
        }
        let newCheckboxes = taskCheckboxes.map { item -> MarkdownTaskCheckbox in
            var copy = item
            copy.markerRange = move(item.markerRange)
            copy.stateRange = move(item.stateRange)
            return copy
        }
        let newFootnotes = footnotes.map { item -> MarkdownFootnote in
            var copy = item
            copy.referenceRange = move(item.referenceRange)
            copy.definitionRange = move(item.definitionRange)
            return copy
        }
        let newTables = tables.map { table -> MarkdownTable in var copy = table; copy.shift(by: delta); return copy }
        let newCodeBlocks = codeBlocks.map { block -> MarkdownCodeBlock in
            var copy = block
            copy.range = move(block.range)
            copy.bodyRange = move(block.bodyRange)
            copy.bodySegments = block.bodySegments.map(move)
            copy.infoRange = move(block.infoRange)
            copy.fenceMarkers = block.fenceMarkers.map(move)
            return copy
        }
        let newParagraphs = paragraphs.map { item -> MarkdownParagraph in
            var copy = item
            copy.range = move(item.range)
            copy.lastLine = move(item.lastLine)
            copy.separatorAfter = item.separatorAfter.map(move)
            return copy
        }
        let newMarkers = listMarkers.map { item -> MarkdownListMarker in
            var copy = item
            copy.range = move(item.range)
            copy.line = move(item.line)
            return copy
        }
        let newWiki = wikiLinks.map { item -> MarkdownWikiLink in
            var copy = item
            copy.range = move(item.range)
            copy.displayRange = move(item.displayRange)
            copy.markerRanges = item.markerRanges.map(move)
            return copy
        }
        let newFenceLines = fenceContainerLines.map {
            MarkdownFenceContainerLine(line: move($0.line), sourcePrefix: $0.sourcePrefix, continuationPrefix: $0.continuationPrefix)
        }
        let newReadable = readableText.map { readable in
            MarkdownReadableText(sourceLength: readable.sourceLength + delta, fragments: readable.fragments.map { fragment in
                MarkdownReadableText.Fragment(sourceRange: move(fragment.sourceRange), text: fragment.text, matchesSource: fragment.matchesSource,
                                              pieces: fragment.pieces?.map { .init(sourceRange: move($0.sourceRange), text: $0.text, matchesSource: $0.matchesSource) })
            }, unsupportedRanges: readable.unsupportedRanges.map(move))
        }
        return MarkdownPresentation(
            spans: newSpans, headings: newHeadings, namedAnchors: moved(namedAnchors, \.range), images: newImages,
            audioBlocks: moved(audioBlocks, \.range), iframeBlocks: moved(iframeBlocks, \.range), detailsBlocks: moved(detailsBlocks, \.range),
            htmlBlocks: moved(htmlBlocks, \.range), pageBreaks: pageBreaks.map(move), ruby: newRuby, links: moved(links, \.range),
            diagrams: moved(diagrams, \.range), formulas: moved(formulas, \.range), inlineFormulas: moved(inlineFormulas, \.range),
            emojiCandidates: moved(emojiCandidates, \.range), emojiCandidatesIncluded: emojiCandidatesIncluded,
            emojiCompletionRanges: emojiCompletionRanges.map(move), smartTextRanges: smartTextRanges.map(move),
            smartRawHTMLRanges: smartRawHTMLRanges?.map(move), textReplacements: moved(textReplacements, \.range), paragraphs: newParagraphs,
            completedTaskRanges: completedTaskRanges.map(move), taskCheckboxes: newCheckboxes, listMarkers: newMarkers,
            looseIndents: moved(looseIndents, \.range), footnotes: newFootnotes, tableOfContents: tableOfContents.map(move), tables: newTables,
            codeBlocks: newCodeBlocks, fenceContainerLines: newFenceLines, fenceBlockedRanges: fenceBlockedRanges.map(move),
            fenceBlockedEOF: fenceBlockedEOF, fenceContextAvailable: fenceContextAvailable, readableText: newReadable)
            .withWikiLinks(newWiki).withUnreliableRanges(unreliableRanges.map(move)).withElements(elements)
    }

    /// Номера фрагментов читаемого текста для склейки: сколько их стоит до участка и в его конце в прежнем оформлении, сколько в участке во фрагменте.
    struct ReadableSlices {
        let beforeCore: Int
        let oldCoreEnd: Int
        let fragmentCore: Int
    }

    /// Новое оформление: элементы до `core` (координаты прежнего текста) — из `old`, внутри `core` — из `fragment` (координаты разобранного
    /// фрагмента, который начинается в позиции `windowStart` нового текста), после `core` — из `old` со сдвигом на `delta`.
    /// Элемент, пересекающий границу `core`, или признак, который склейка не умеет переносить, — `Unmergeable`.
    static func spliced(old: MarkdownPresentation, fragment: MarkdownPresentation, windowStart: Int, core: NSRange, delta: Int,
                        newLength: Int, endsWithLineBreak: Bool, readable: ReadableSlices?) throws -> MarkdownPresentation {
        let moved = old.translated(by: delta)
        let part = fragment.translated(by: windowStart)
        let newCore = NSRange(location: core.location, length: core.length + delta)
        // Прежний список режется на «до», «внутри» (выбрасывается) и «после» (берётся сдвинутым); список фрагмента даёт «внутри».
        func pick<T>(_ field: String, _ oldItems: [T], _ movedItems: [T], _ fragmentItems: [T], _ extent: (T) -> NSRange) throws -> [T] {
            var before: [T] = [], after: [T] = [], inside: [T] = []
            for index in oldItems.indices {
                let range = extent(oldItems[index])
                if NSMaxRange(range) <= core.location { before.append(oldItems[index]) }
                else if range.location >= NSMaxRange(core) { after.append(movedItems[index]) }
                else if range.location < core.location || NSMaxRange(range) > NSMaxRange(core) { throw Unmergeable(field: field) }
            }
            for item in fragmentItems {
                let range = extent(item)
                if NSMaxRange(range) <= newCore.location || range.location >= NSMaxRange(newCore) { continue }
                guard range.location >= newCore.location, NSMaxRange(range) <= NSMaxRange(newCore) else { throw Unmergeable(field: field) }
                inside.append(item)
            }
            return before + inside + after
        }
        func union(_ first: NSRange, _ others: [NSRange]) -> NSRange { others.reduce(first) { NSUnionRange($0, $1) } }
        // Поля, которые склейка не переносит: либо одинаковы в обоих разборах, либо локальный разбор не применяется.
        guard old.emojiCandidatesIncluded == fragment.emojiCandidatesIncluded else { throw Unmergeable(field: "emojiCandidatesIncluded") }
        guard !old.fenceBlockedEOF, !fragment.fenceBlockedEOF else { throw Unmergeable(field: "fenceBlockedEOF") }
        guard old.fenceContextAvailable, fragment.fenceContextAvailable else { throw Unmergeable(field: "fenceContextAvailable") }
        guard let rawOld = old.smartRawHTMLRanges, let rawFragment = fragment.smartRawHTMLRanges, rawOld.isEmpty, rawFragment.isEmpty else {
            throw Unmergeable(field: "smartRawHTMLRanges")
        }
        var readableText: MarkdownReadableText?
        if let readable {
            guard let oldReadable = old.readableText, let movedReadable = moved.readableText, let partReadable = part.readableText,
                  readable.beforeCore <= readable.oldCoreEnd, readable.oldCoreEnd <= oldReadable.fragments.count,
                  readable.fragmentCore <= partReadable.fragments.count else { throw Unmergeable(field: "readableText") }
            let unsupported = try pick("readableText.unsupportedRanges", oldReadable.unsupportedRanges, movedReadable.unsupportedRanges,
                                       partReadable.unsupportedRanges) { $0 }
            readableText = MarkdownReadableText(
                sourceLength: newLength,
                fragments: Array(oldReadable.fragments[..<readable.beforeCore]) + Array(partReadable.fragments[..<readable.fragmentCore])
                    + Array(movedReadable.fragments[readable.oldCoreEnd...]),
                unsupportedRanges: unsupported)
        } else if old.readableText != nil || fragment.readableText != nil {
            throw Unmergeable(field: "readableText")
        }
        let oldElements = old.elements.flattened, partElements = fragment.elements.flattened
        let elementBlocks = try pick("elements.blocks", oldElements.blocks, oldElements.blocks.map { (NSRange(location: $0.0.location + delta, length: $0.0.length), $0.1) },
                                     partElements.blocks.map { (NSRange(location: $0.0.location + windowStart, length: $0.0.length), $0.1) }) { $0.0 }
        let elementInlines = try pick("elements.inlines", oldElements.inlines, oldElements.inlines.map { (NSRange(location: $0.0.location + delta, length: $0.0.length), $0.1) },
                                      partElements.inlines.map { (NSRange(location: $0.0.location + windowStart, length: $0.0.length), $0.1) }) { $0.0 }
        let v_spans = try pick("spans", old.spans, moved.spans, part.spans) { union($0.range, $0.markerRanges) }
        // Заголовок с пустым диапазоном - запасной вариант при неподтверждённой позиции: его место зависит от всего документа.
        if old.headings.contains(where: { $0.range.length == 0 }) || part.headings.contains(where: { $0.range.length == 0 }) { throw Unmergeable(field: "headings") }
        let v_headings = try pick("headings", old.headings, moved.headings, part.headings) { $0.range }
        let v_namedAnchors = try pick("namedAnchors", old.namedAnchors, moved.namedAnchors, part.namedAnchors) { $0.range }
        let v_images = try pick("images", old.images, moved.images, part.images) { NSUnionRange($0.range, $0.paragraphRange) }
        let v_audioBlocks = try pick("audioBlocks", old.audioBlocks, moved.audioBlocks, part.audioBlocks) { $0.range }
        let v_iframeBlocks = try pick("iframeBlocks", old.iframeBlocks, moved.iframeBlocks, part.iframeBlocks) { $0.range }
        let v_detailsBlocks = try pick("detailsBlocks", old.detailsBlocks, moved.detailsBlocks, part.detailsBlocks) { $0.range }
        let v_htmlBlocks = try pick("htmlBlocks", old.htmlBlocks, moved.htmlBlocks, part.htmlBlocks) { $0.range }
        let v_pageBreaks = try pick("pageBreaks", old.pageBreaks, moved.pageBreaks, part.pageBreaks) { $0 }
        let v_ruby = try pick("ruby", old.ruby, moved.ruby, part.ruby) { $0.range }
        let v_links = try pick("links", old.links, moved.links, part.links) { $0.range }
        let v_diagrams = try pick("diagrams", old.diagrams, moved.diagrams, part.diagrams) { $0.range }
        let v_formulas = try pick("formulas", old.formulas, moved.formulas, part.formulas) { $0.range }
        let v_inlineFormulas = try pick("inlineFormulas", old.inlineFormulas, moved.inlineFormulas, part.inlineFormulas) { $0.range }
        let v_emojiCandidates = try pick("emojiCandidates", old.emojiCandidates, moved.emojiCandidates, part.emojiCandidates) { $0.range }
        let v_emojiCompletionRanges = try pick("emojiCompletionRanges", old.emojiCompletionRanges, moved.emojiCompletionRanges, part.emojiCompletionRanges) { $0 }
        let v_smartTextRanges = try pick("smartTextRanges", old.smartTextRanges, moved.smartTextRanges, part.smartTextRanges) { $0 }
        let v_textReplacements = try pick("textReplacements", old.textReplacements, moved.textReplacements, part.textReplacements) { $0.range }
        let v_paragraphs = try pick("paragraphs", old.paragraphs, moved.paragraphs, part.paragraphs) { $0.extent }
        let v_completedTaskRanges = try pick("completedTaskRanges", old.completedTaskRanges, moved.completedTaskRanges, part.completedTaskRanges) { $0 }
        let v_taskCheckboxes = try pick("taskCheckboxes", old.taskCheckboxes, moved.taskCheckboxes, part.taskCheckboxes) { NSUnionRange($0.markerRange, $0.stateRange) }
        let v_listMarkers = try pick("listMarkers", old.listMarkers, moved.listMarkers, part.listMarkers) { NSUnionRange($0.range, $0.line) }
        let v_looseIndents = try pick("looseIndents", old.looseIndents, moved.looseIndents, part.looseIndents) { $0.range }
        let v_footnotes = try pick("footnotes", old.footnotes, moved.footnotes, part.footnotes) { NSUnionRange($0.referenceRange, $0.definitionRange) }
        let v_tableOfContents = try pick("tableOfContents", old.tableOfContents, moved.tableOfContents, part.tableOfContents) { $0 }
        let v_tables = try pick("tables", old.tables, moved.tables, part.tables) { $0.range }
        let v_codeBlocks = try pick("codeBlocks", old.codeBlocks, moved.codeBlocks, part.codeBlocks) { $0.range }
        let v_fenceContainerLines = try pick("fenceContainerLines", old.fenceContainerLines, moved.fenceContainerLines, part.fenceContainerLines) { $0.line }
        let v_fenceBlockedRanges = mergedRanges(try pick("fenceBlockedRanges", old.fenceBlockedRanges, moved.fenceBlockedRanges, part.fenceBlockedRanges) { $0 })
        let v_wiki = try pick("wikiLinks", old.wikiLinks, moved.wikiLinks, part.wikiLinks) { $0.range }
        let v_unreliable = mergedRanges(try pick("unreliableRanges", old.unreliableRanges, moved.unreliableRanges, part.unreliableRanges) { $0 })
        let merged = MarkdownPresentation(
            spans: v_spans,
            headings: v_headings,
            namedAnchors: v_namedAnchors,
            images: v_images,
            audioBlocks: v_audioBlocks,
            iframeBlocks: v_iframeBlocks,
            detailsBlocks: v_detailsBlocks,
            htmlBlocks: v_htmlBlocks,
            pageBreaks: v_pageBreaks,
            ruby: v_ruby,
            links: v_links,
            diagrams: v_diagrams,
            formulas: v_formulas,
            inlineFormulas: v_inlineFormulas,
            emojiCandidates: v_emojiCandidates,
            emojiCandidatesIncluded: old.emojiCandidatesIncluded,
            emojiCompletionRanges: v_emojiCompletionRanges,
            smartTextRanges: v_smartTextRanges,
            smartRawHTMLRanges: [],
            textReplacements: v_textReplacements,
            paragraphs: v_paragraphs,
            completedTaskRanges: v_completedTaskRanges,
            taskCheckboxes: v_taskCheckboxes,
            listMarkers: v_listMarkers,
            looseIndents: v_looseIndents,
            footnotes: v_footnotes,
            tableOfContents: v_tableOfContents,
            tables: v_tables,
            codeBlocks: v_codeBlocks,
            fenceContainerLines: v_fenceContainerLines,
            fenceBlockedRanges: v_fenceBlockedRanges,
            fenceBlockedEOF: false, fenceContextAvailable: true, readableText: readableText)
            .withWikiLinks(v_wiki)
            .withUnreliableRanges(v_unreliable)
            .withElements(MarkdownElementIndex(textLength: newLength, blocks: elementBlocks, inlines: elementInlines, endsWithLineBreak: endsWithLineBreak))
        return merged
    }

    /// Поля, которые сравнивает `firstDifference`; тест сверяет список с настоящими свойствами оформления.
    static let comparedFields: [String] = [
        "spans", "headings", "namedAnchors", "images", "diagrams", "audioBlocks", "iframeBlocks", "detailsBlocks", "htmlBlocks", "pageBreaks", "ruby",
        "links", "formulas", "inlineFormulas", "emojiCandidates", "emojiCandidatesIncluded", "emojiCompletionRanges", "smartTextRanges",
        "smartRawHTMLRanges", "textReplacements", "paragraphs", "completedTaskRanges", "taskCheckboxes", "listMarkers", "looseIndents", "footnotes",
        "tableOfContents", "tables", "codeBlocks", "fenceContainerLines", "fenceBlockedRanges", "fenceBlockedEOF", "fenceContextAvailable",
        "readableText", "wikiLinks", "unreliableRanges", "elements", "spanEnds", "completedEnds", "isReadyForShift", "isTextStructureOnly",
    ]

    /// Первое расхождение двух оформлений по смыслу (имя поля и номер элемента) или nil, если они совпадают.
    /// Оба оформления должны пройти `prepareForEditing`: производные поля сравниваются тоже.
    static func firstDifference(_ left: MarkdownPresentation, _ right: MarkdownPresentation) -> String? {
        func list<T: Equatable>(_ name: String, _ first: [T], _ second: [T]) -> String? {
            for index in 0..<min(first.count, second.count) where first[index] != second[index] {
                return "\(name)[\(index)]: \(String(describing: first[index]).prefix(240)) | \(String(describing: second[index]).prefix(240))"
            }
            return first.count == second.count ? nil : "\(name).count: \(first.count) | \(second.count)"
        }
        func value<T: Equatable>(_ name: String, _ first: T, _ second: T) -> String? {
            first == second ? nil : "\(name): \(String(describing: first).prefix(240)) | \(String(describing: second).prefix(240))"
        }
        func readable() -> String? {
            switch (left.readableText, right.readableText) {
            case (nil, nil): return nil
            case let (first?, second?):
                if let difference = value("readableText.sourceLength", first.sourceLength, second.sourceLength) { return difference }
                if let difference = list("readableText.unsupportedRanges", first.unsupportedRanges, second.unsupportedRanges) { return difference }
                for index in 0..<min(first.fragments.count, second.fragments.count) {
                    let a = first.fragments[index], b = second.fragments[index]
                    if a.sourceRange != b.sourceRange || a.text != b.text || a.matchesSource != b.matchesSource || a.pieces != b.pieces {
                        return "readableText.fragments[\(index)]: \(a.sourceRange) \(a.text.debugDescription) | \(b.sourceRange) \(b.text.debugDescription)"
                    }
                }
                return value("readableText.fragments.count", first.fragments.count, second.fragments.count)
            default: return "readableText: nil | не nil"
            }
        }
        let rawLeft = left.smartRawHTMLRanges ?? [NSRange(location: -1, length: -1)]
        let rawRight = right.smartRawHTMLRanges ?? [NSRange(location: -1, length: -1)]
        let checks: [() -> String?] = [
            { list("spans", left.spans, right.spans) },
            { list("headings", left.headings, right.headings) },
            { list("namedAnchors", left.namedAnchors, right.namedAnchors) },
            { list("images", left.images, right.images) },
            { list("diagrams", left.diagrams, right.diagrams) },
            { list("audioBlocks", left.audioBlocks, right.audioBlocks) },
            { list("iframeBlocks", left.iframeBlocks, right.iframeBlocks) },
            { list("detailsBlocks", left.detailsBlocks, right.detailsBlocks) },
            { list("htmlBlocks", left.htmlBlocks, right.htmlBlocks) },
            { list("pageBreaks", left.pageBreaks, right.pageBreaks) },
            { list("ruby", left.ruby, right.ruby) },
            { list("links", left.links, right.links) },
            { list("formulas", left.formulas, right.formulas) },
            { list("inlineFormulas", left.inlineFormulas, right.inlineFormulas) },
            { list("emojiCandidates", left.emojiCandidates, right.emojiCandidates) },
            { value("emojiCandidatesIncluded", left.emojiCandidatesIncluded, right.emojiCandidatesIncluded) },
            { list("emojiCompletionRanges", left.emojiCompletionRanges, right.emojiCompletionRanges) },
            { list("smartTextRanges", left.smartTextRanges, right.smartTextRanges) },
            { value("smartRawHTMLRanges", rawLeft, rawRight) },
            { list("textReplacements", left.textReplacements, right.textReplacements) },
            { list("paragraphs", left.paragraphs, right.paragraphs) },
            { list("completedTaskRanges", left.completedTaskRanges, right.completedTaskRanges) },
            { list("taskCheckboxes", left.taskCheckboxes, right.taskCheckboxes) },
            { list("listMarkers", left.listMarkers, right.listMarkers) },
            { list("looseIndents", left.looseIndents.map { "\($0.range)\($0.replacement)" }, right.looseIndents.map { "\($0.range)\($0.replacement)" }) },
            { list("footnotes", left.footnotes, right.footnotes) },
            { list("tableOfContents", left.tableOfContents, right.tableOfContents) },
            { list("tables", left.tables, right.tables) },
            { list("codeBlocks", left.codeBlocks, right.codeBlocks) },
            { list("fenceContainerLines", left.fenceContainerLines, right.fenceContainerLines) },
            { list("fenceBlockedRanges", left.fenceBlockedRanges, right.fenceBlockedRanges) },
            { value("fenceBlockedEOF", left.fenceBlockedEOF, right.fenceBlockedEOF) },
            { value("fenceContextAvailable", left.fenceContextAvailable, right.fenceContextAvailable) },
            { readable() },
            { list("wikiLinks", left.wikiLinks, right.wikiLinks) },
            { list("unreliableRanges", left.unreliableRanges, right.unreliableRanges) },
            { value("elements", left.elements, right.elements) },
            { list("spanEnds", left.spanEnds, right.spanEnds) },
            { list("completedEnds", left.completedEnds, right.completedEnds) },
            { value("isReadyForShift", left.isReadyForShift, right.isReadyForShift) },
            { value("isTextStructureOnly", left.isTextStructureOnly, right.isTextStructureOnly) },
        ]
        for check in checks { if let difference = check() { return difference } }
        return nil
    }
}

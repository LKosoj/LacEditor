import Foundation

/// Параметры разбора, от которых зависит результат: база годится для локального разбора, только если они не изменились.
struct MarkdownParseOptions: Equatable, Sendable {
    var includeReadableText = false
    var includeEmojiCandidates = false
    var includeUppercaseRuns = false
    var includeWikiLinks = true
    var syntax = MarkdownSyntaxOptions()
    /// Заметка хранилища: `%%…%%` — комментарии. Смена типа документа сбрасывает базу (опции сравниваются).
    var isVaultNote = false
}

/// «Чистая база» локального разбора: последний полный или слитый результат без нумерации заголовков и прочей обработки контроллера,
/// текст, из которого он получен, и индекс верхнеуровневых блоков.
struct MarkdownParseBase: Sendable {
    let text: String
    let presentation: MarkdownPresentation
    let index: MarkdownBlockIndex
    let options: MarkdownParseOptions
}

/// Локальный разбор (T5): после небольшой правки заново разбирается только участок вокруг неё, остальное берётся из базы.
/// Любое сомнение (HTML, front matter, ссылки и сноски, формулы `$$`, блоки неизвестного вида, несовпавшие границы) — полный разбор.
enum MarkdownLocalParser {
    /// Короче этого документ разбирается целиком: выигрыш от участка меньше его стоимости.
    static let defaultMinimumLength = 20_000

    struct Result {
        let presentation: MarkdownPresentation
        let base: MarkdownParseBase?
        /// Модель документа — только после полного разбора (nil, если участок собран локально).
        let model: MarkdownDocumentModel?
        /// Почему разбор полный (nil — участок собран локально и сверка, если была, сошлась).
        let fallbackReason: String?
        /// Первое расхождение локального результата с полным, если сверка его нашла (результат тогда полный).
        let divergence: String?
        var usedLocal: Bool { fallbackReason == nil }
    }

    static func parse(_ text: String, options: MarkdownParseOptions, base: MarkdownParseBase?, minimumLength: Int = defaultMinimumLength,
                      verifies: Bool = false, isCancelled: @escaping () -> Bool = { false }) -> Result {
        var reason = "нет базы"
        if let base {
            if NSString(string: text).length < minimumLength { reason = "короткий документ" }
            else {
                switch attempt(text, options: options, base: base, isCancelled: isCancelled) {
                case let .local(presentation, index):
                    let newBase = MarkdownParseBase(text: text, presentation: presentation, index: index, options: options)
                    guard verifies else { return Result(presentation: presentation, base: newBase, model: nil, fallbackReason: nil, divergence: nil) }
                    let full = fullParse(text, options: options, isCancelled: isCancelled)
                    if isCancelled() { return Result(presentation: presentation, base: newBase, model: nil, fallbackReason: nil, divergence: nil) }
                    var left = presentation, right = full.presentation
                    left.prepareForEditing()
                    right.prepareForEditing()
                    if let difference = MarkdownPresentation.firstDifference(left, right) {
                        return Result(presentation: full.presentation, base: full.base, model: full.model, fallbackReason: "расхождение со сверкой", divergence: difference)
                    }
                    return Result(presentation: presentation, base: newBase, model: nil, fallbackReason: nil, divergence: nil)
                case let .full(why):
                    reason = why
                }
            }
        }
        let full = fullParse(text, options: options, isCancelled: isCancelled)
        return Result(presentation: full.presentation, base: full.base, model: full.model, fallbackReason: reason, divergence: nil)
    }

    /// Полный разбор: ядро и builder. Отмена или пустой результат ядра — пустое оформление без базы и модели.
    private static func fullParse(_ text: String, options: MarkdownParseOptions, isCancelled: @escaping () -> Bool)
        -> (presentation: MarkdownPresentation, base: MarkdownParseBase?, model: MarkdownDocumentModel?) {
        guard let model = parseModel(text, options: options, detectsFrontMatter: true, isCancelled: isCancelled) else {
            return (MarkdownPresentation(spans: []), nil, nil)
        }
        let presentation = build(model, text: text, options: options, isCancelled: isCancelled)
        let base = model.blockIndex.map { MarkdownParseBase(text: text, presentation: presentation, index: $0, options: options) }
        return (presentation, base, model)
    }

    private static func parseModel(_ text: String, options: MarkdownParseOptions, detectsFrontMatter: Bool, isCancelled: @escaping () -> Bool) -> MarkdownDocumentModel? {
        let includes = MarkdownPresentationBuilder.editorIncludes(readableText: options.includeReadableText, emojiCandidates: options.includeEmojiCandidates,
                                                                  uppercaseRuns: options.includeUppercaseRuns, wikiLinks: options.includeWikiLinks, blockIndex: true)
        return MarkdownPresentationBuilder.model(of: text, syntax: options.syntax, includes: includes, isVaultNote: options.isVaultNote,
                                                 detectsFrontMatter: detectsFrontMatter, isCancelled: isCancelled)
    }

    private static func build(_ model: MarkdownDocumentModel, text: String, options: MarkdownParseOptions, isCancelled: @escaping () -> Bool) -> MarkdownPresentation {
        MarkdownPresentationBuilder.presentation(model, of: text, readableText: options.includeReadableText, emojiCandidates: options.includeEmojiCandidates,
                                                 wikiLinks: options.includeWikiLinks, isCancelled: isCancelled)
    }

    private enum Attempt {
        case local(MarkdownPresentation, MarkdownBlockIndex)
        case full(String)
    }

    private static func attempt(_ text: String, options: MarkdownParseOptions, base: MarkdownParseBase, isCancelled: @escaping () -> Bool) -> Attempt {
        guard base.options == options else { return .full("параметры разбора изменились") }
        let index = base.index
        guard !index.hasHTML else { return .full("в документе есть HTML") }
        guard !index.hasUnconfirmedReadable else { return .full("в читаемом тексте есть узлы без подтверждённой позиции") }
        guard !index.hasFrontMatter else { return .full("в документе есть front matter") }
        // Front matter определяется по всему тексту: строка `---` или `...` внизу может закрыть шапку, начатую `---` в первой строке (BOM учитывается самим поиском).
        guard MarkdownFrontMatter.frontMatter(text) == nil else { return .full("в тексте есть front matter") }
        guard !index.blocks.isEmpty else { return .full("в базе нет блоков") }
        let old = Array(base.text.utf16), new = Array(text.utf16)
        guard old.count == index.textLength else { return .full("индекс блоков не соответствует тексту базы") }
        // Правка находится сравнением общего начала и общего конца старого и нового текста.
        let shortest = min(old.count, new.count)
        var prefix = 0
        while prefix < shortest && old[prefix] == new[prefix] { prefix += 1 }
        if prefix == old.count && prefix == new.count { return .local(base.presentation, index) }
        var suffix = 0
        while suffix < shortest - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // Определения ссылок `[имя]: адрес` разбираются во всём документе сразу: ссылка в участке зависит от определения вне его.
        func hasReferenceDefinition(_ units: [UInt16]) -> Bool {
            var index = 1
            while index < units.count { if units[index] == 0x3A && units[index - 1] == 0x5D { return true }; index += 1 }
            return false
        }
        if hasReferenceDefinition(old) || hasReferenceDefinition(new) { return .full("в документе есть «]:»") }
        let editStart = prefix, editEnd = old.count - suffix, delta = new.count - old.count
        if isCancelled() { return .full("разбор отменён") }

        // Ядро: блоки правки и по одному соседнему с каждой стороны; контекст T — следующий блок, он проверяется, но не пересобирается.
        let blocks = index.blocks
        let first = blocks.firstIndex { NSMaxRange($0.range) > editStart } ?? blocks.count
        let last = blocks.lastIndex { $0.range.location < editEnd } ?? -1
        let coreFirst = max(0, first - 1)
        let coreLast = min(blocks.count - 1, max(last, first - 1) + 1)
        guard coreFirst <= coreLast else { return .full("нет блоков вокруг правки") }
        let contextIndex = coreLast + 1 < blocks.count ? coreLast + 1 : nil
        let coreStart = coreFirst == 0 ? 0 : blocks[coreFirst].range.location
        let coreEnd = contextIndex.map { blocks[$0].range.location } ?? old.count
        let windowEnd = contextIndex.map { NSMaxRange(blocks[$0].range) } ?? old.count
        guard editStart >= coreStart, editEnd <= coreEnd else { return .full("правка вне ядра") }
        if contextIndex == nil && coreFirst == 0 { return .full("участок занимает весь документ") }
        let involved = blocks[coreFirst...(contextIndex ?? coreLast)]
        guard involved.allSatisfy({ $0.kind.isLocal }) else { return .full("рядом блок, который разбирается целиком") }

        let windowText = String(decoding: new[coreStart..<(windowEnd + delta)], as: UTF16.self)
        let oldWindowText = String(decoding: old[coreStart..<windowEnd], as: UTF16.self)
        for marker in ["]:", "[^", "$$"] where windowText.contains(marker) || oldWindowText.contains(marker) {
            return .full("в участке «\(marker)»")
        }
        // Маска критика (всегда) и `%%` (в заметке хранилища) зависит от парных знаков по всему тексту: пара может охватывать окно, не имея в нём знаков.
        // Поэтому любой открывающий знак в новом тексте целиком - полный разбор; закрывающие знаки и `%%` в старом окне ловят удаление последнего открывающего.
        func hasMaskOpener(_ units: [UInt16]) -> Bool {
            var i = 0
            while i + 1 < units.count {
                let u = units[i], n = units[i + 1]
                if u == 0x7B, i + 2 < units.count, units[i + 2] == n, n == 0x2B || n == 0x2D || n == 0x7E || n == 0x3E || n == 0x3D { return true }
                if options.isVaultNote, u == 0x25, n == 0x25 { return true }
                i += 1
            }
            return false
        }
        let maskMarkers = ["{++", "{--", "{~~", "{>>", "{==", "++}", "--}", "~~}", "<<}", "==}", "~>"] + (options.isVaultNote ? ["%%"] : [])
        if hasMaskOpener(new) || maskMarkers.contains(where: { windowText.contains($0) || oldWindowText.contains($0) }) {
            return .full("в тексте разметка критика или «%%»")
        }

        guard let fragmentModel = parseModel(windowText, options: options, detectsFrontMatter: false, isCancelled: isCancelled) else { return .full("разбор отменён") }
        let fragment = build(fragmentModel, text: windowText, options: options, isCancelled: isCancelled)
        if isCancelled() { return .full("разбор отменён") }
        guard let fragmentIndex = fragmentModel.blockIndex else { return .full("участок не разобран на блоки") }
        guard !fragmentIndex.hasHTML else { return .full("в участке HTML") }
        guard fragmentIndex.blocks.allSatisfy({ $0.kind.isLocal }) else { return .full("в участке блок, который разбирается целиком") }
        var coreBlocks = fragmentIndex.blocks
        if let contextIndex {
            let context = blocks[contextIndex]
            let expected = NSRange(location: context.range.location - coreStart + delta, length: context.range.length)
            guard let tail = coreBlocks.popLast(), tail.range == expected, tail.kind == context.kind else { return .full("граница контекста не сошлась") }
        }
        if coreFirst < first {
            let unchanged = blocks[coreFirst]
            let expected = NSRange(location: unchanged.range.location - coreStart, length: unchanged.range.length)
            guard let head = coreBlocks.first, head.range == expected, head.kind == unchanged.kind else { return .full("начало ядра не сошлось") }
        }

        let readable: MarkdownPresentation.ReadableSlices? = options.includeReadableText
            ? .init(beforeCore: coreFirst > 0 ? blocks[coreFirst - 1].readableEnd : 0, oldCoreEnd: blocks[coreLast].readableEnd,
                    fragmentCore: coreBlocks.last?.readableEnd ?? 0)
            : nil
        let lastUnit = new.last
        let merged: MarkdownPresentation
        do {
            merged = try MarkdownPresentation.spliced(
                old: base.presentation, fragment: fragment, windowStart: coreStart, core: NSRange(location: coreStart, length: coreEnd - coreStart),
                delta: delta, newLength: new.count, endsWithLineBreak: lastUnit == 0x0A || lastUnit == 0x0D, windowReachesEnd: contextIndex == nil,
                readable: readable)
        } catch let error as MarkdownPresentation.Unmergeable {
            return .full("склейка: \(error.field)")
        } catch {
            return .full("склейка не удалась")
        }
        let shifted = coreBlocks.map {
            MarkdownBlockIndex.Block(range: NSRange(location: $0.range.location + coreStart, length: $0.range.length), kind: $0.kind, readableEnd: $0.readableEnd)
        }
        let readableDelta = (coreBlocks.last?.readableEnd ?? 0) - (blocks[coreLast].readableEnd - (coreFirst > 0 ? blocks[coreFirst - 1].readableEnd : 0))
        let mergedIndex = index.replacing(coreFirst..<(coreLast + 1), with: shifted, delta: delta, readableDelta: options.includeReadableText ? readableDelta : 0)
        return .local(merged, mergedIndex)
    }
}

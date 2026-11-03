import Foundation

/// Тип выноски Obsidian. Канонические типы и синонимы Obsidian; неизвестный тип — `.note` с собственной подписью.
enum MarkdownCalloutKind: String, CaseIterable, Sendable {
    case note, abstract, info, todo, tip, success, question, warning, failure, danger, bug, example, quote

    private static let synonyms: [String: MarkdownCalloutKind] = [
        "summary": .abstract, "tldr": .abstract, "hint": .tip, "important": .tip, "check": .success, "done": .success,
        "help": .question, "faq": .question, "caution": .warning, "attention": .warning, "fail": .failure, "missing": .failure,
        "error": .danger, "cite": .quote
    ]

    /// Синонимы Obsidian (без учёта регистра): summary/tldr → abstract; hint/important → tip; check/done → success;
    /// help/faq → question; caution/attention → warning; fail/missing → failure; error → danger; cite → quote.
    static func kind(forType type: String) -> MarkdownCalloutKind? {
        let key = type.lowercased()
        return MarkdownCalloutKind(rawValue: key) ?? synonyms[key]
    }

    /// Знак (текстовый, с селектором U+FE0E там, где возможна цветная картинка); в HTML всегда `aria-hidden`.
    var symbol: String {
        switch self {
        case .note: "\u{270E}"
        case .abstract: "\u{2261}"
        case .info: "\u{24D8}"
        case .todo: "\u{2610}"
        case .tip: "\u{2726}"
        case .success: "\u{2713}"
        case .question: "?"
        case .warning: "\u{26A0}\u{FE0E}"
        case .failure: "\u{2717}"
        case .danger: "\u{26A1}\u{FE0E}"
        case .bug: "\u{2731}"
        case .example: "\u{25A4}"
        case .quote: "\u{275D}"
        }
    }

    /// Группа цвета: ссылка на уже существующие переменные `--alert-*` (note/info/todo → note; tip/abstract/success → tip;
    /// question/warning → warning; example → important; failure/danger/bug → caution; quote → нейтральная).
    var colorGroup: String {
        switch self {
        case .note, .info, .todo: "note"
        case .tip, .abstract, .success: "tip"
        case .question, .warning: "warning"
        case .example: "important"
        case .failure, .danger, .bug: "caution"
        case .quote: "quote"
        }
    }

    /// Локализованная подпись (L10n.tr, ключи с приставкой `标注·`).
    var label: String {
        switch self {
        case .note: L10n.tr("标注·笔记")
        case .abstract: L10n.tr("标注·摘要")
        case .info: L10n.tr("标注·信息")
        case .todo: L10n.tr("标注·待办")
        case .tip: L10n.tr("标注·技巧")
        case .success: L10n.tr("标注·成功")
        case .question: L10n.tr("标注·疑问")
        case .warning: L10n.tr("标注·警告")
        case .failure: L10n.tr("标注·失败")
        case .danger: L10n.tr("标注·危险")
        case .bug: L10n.tr("标注·缺陷")
        case .example: L10n.tr("标注·示例")
        case .quote: L10n.tr("标注·引文")
        }
    }
}

/// Выноски Obsidian `> [!тип]±? Заголовок` над готовым HTML cmark.
enum MarkdownCalloutRender {
    struct Marker: Equatable, Sendable {
        let type: String          // как написано, без нормализации регистра
        let fold: Fold            // .none / .open (+) / .closed (-)
        enum Fold: Equatable, Sendable { case none, open, closed }
    }

    /// Разбор начала первого абзаца цитаты: `[!тип]`, затем необязательно `+` или `-`; тип — `[A-Za-z0-9_-]+`.
    /// После маркера должен идти пробел, перевод строки, `<br` или конец текста. Возвращает маркер и длину
    /// разобранной части (в символах `Character`); nil — это не выноска.
    static func marker(in text: Substring) -> (marker: Marker, length: Int)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 4, scalars[0] == "[", scalars[1] == "!" else { return nil }
        var index = 2
        func isTypeScalar(_ scalar: Unicode.Scalar) -> Bool {
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122) || scalar == "_" || scalar == "-"
        }
        while index < scalars.count, isTypeScalar(scalars[index]) { index += 1 }
        guard index > 2, index < scalars.count, scalars[index] == "]" else { return nil }
        let type = String(String.UnicodeScalarView(scalars[2..<index]))
        index += 1
        var fold = Marker.Fold.none
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
            fold = scalars[index] == "+" ? .open : .closed
            index += 1
        }
        if index < scalars.count {
            let rest = String(String.UnicodeScalarView(scalars[index...]))
            guard rest.hasPrefix(" ") || rest.hasPrefix("\t") || rest.hasPrefix("\n") || rest.hasPrefix("\r") || rest.hasPrefix("<br") else { return nil }
        }
        return (Marker(type: type, fold: fold), index)
    }

    /// Строки-маркеры оповещений GitHub: их оформляет прежний путь, и пробелы в конце ему мешают.
    private static let githubAlertMarkers: Set<String> = Set(["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"].map { ">[!\($0)]" })

    /// До cmark: строка-маркер `> [!тип]…`, за которой идёт продолжение цитаты, получает жёсткий перенос (два пробела в конце).
    /// Без него при отключённых переносах строк cmark склеивает заголовок с текстом пробелом, и границу заголовка не найти.
    /// Число строк не меняется; код, формулы, HTML-блоки и таблицы не затрагиваются.
    static func separatingTitles(in text: String, syntax: MarkdownSyntaxOptions) -> String {
        guard text.contains("[!"), text.contains(">") else { return text }
        let source = text as NSString
        /// Начало маркера в строке и число `>` до него; nil — строка не начинается с `> [!тип]`.
        func markerLine(_ contents: NSRange) -> (marker: Int, depth: Int)? {
            var index = contents.location, depth = 0
            let end = NSMaxRange(contents)
            while index < end {
                let unit = source.character(at: index)
                if unit == 62 { depth += 1 } else if unit != 32 && unit != 9 && unit != 45 && unit != 42 && unit != 43 { break }
                index += 1
            }
            guard depth > 0, index + 2 < end, source.character(at: index) == 91, source.character(at: index + 1) == 33 else { return nil }
            return (index, depth)
        }
        func quoteDepth(_ contents: NSRange) -> Int {
            var index = contents.location, depth = 0
            while index < NSMaxRange(contents) {
                let unit = source.character(at: index)
                if unit == 62 { depth += 1 } else if unit != 32 && unit != 9 { break }
                index += 1
            }
            return depth
        }
        var candidates: [(contentsEnd: Int, location: Int)] = []
        var location = 0, previousContents: NSRange?
        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            var contentsEnd = 0
            source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: line.location, length: 0))
            let contents = NSRange(location: line.location, length: contentsEnd - line.location)
            if let found = markerLine(contents), marker(in: Substring(source.substring(with: NSRange(location: found.marker, length: contentsEnd - found.marker)))) != nil,
               previousContents.map({ quoteDepth($0) < found.depth }) ?? true,
               !source.substring(with: contents).hasSuffix("\\"), !source.substring(with: contents).hasSuffix("  "),
               !githubAlertMarkers.contains(source.substring(with: contents).replacingOccurrences(of: " ", with: "")) {
                candidates.append((contentsEnd, line.location))
            }
            previousContents = contents
            location = NSMaxRange(line)
        }
        guard !candidates.isEmpty else { return text }
        let parsed = MarkdownPresentationParser.parse(text, syntax: syntax, isCancelled: { false }).elements
        guard parsed.textLength == source.length else { return text }
        let excluded = parsed.excludedRanges(intersecting: NSRange(location: 0, length: source.length))
        let result = NSMutableString(string: text)
        for candidate in candidates.reversed() where !excluded.contains(where: { NSLocationInRange(candidate.location, $0) }) {
            result.insert("  ", at: candidate.contentsEnd)
        }
        return result as String
    }

    /// Быстрая проверка: есть ли в HTML кандидат (`<blockquote` и `[!`), чтобы не разбирать обычные страницы.
    static func mayContainCallout(_ html: String) -> Bool {
        html.contains("<blockquote") && html.contains("[!")
    }

    private struct Frame {
        let closing: String?   // nil — обычная цитата, закрывающий тег остаётся прежним
    }

    /// Заменяет цитаты-выноски на `<div|details class="lac-callout …">`. `expandCollapsed` — раскрывать свёрнутые (экспорт).
    /// Вложенность: стек по `<blockquote`/`</blockquote>`; `data-sourcepos` внешней цитаты переносится на новый элемент.
    /// Цитата, не начинающаяся с маркера, остаётся как есть. Число и порядок остальных тегов не меняются.
    static func transform(html: String, expandCollapsed: Bool) -> String {
        guard mayContainCallout(html) else { return html }
        var output = ""
        var stack: [Frame] = []
        var cursor = html.startIndex
        let openToken = "<blockquote", closeToken = "</blockquote>"
        while cursor < html.endIndex {
            let open = html.range(of: openToken, range: cursor..<html.endIndex)
            let close = html.range(of: closeToken, range: cursor..<html.endIndex)
            if let open, close == nil || open.lowerBound < close!.lowerBound {
                // `<blockquote` должно быть именно тегом, а не началом другого имени.
                guard open.upperBound < html.endIndex, html[open.upperBound] == ">" || html[open.upperBound] == " ",
                      let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else {
                    output += html[cursor..<open.upperBound]
                    cursor = open.upperBound
                    continue
                }
                output += html[cursor..<open.lowerBound]
                let attributes = String(html[open.upperBound..<tagEnd.lowerBound])
                if let callout = callout(in: html, afterTag: tagEnd.upperBound, attributes: attributes, expandCollapsed: expandCollapsed) {
                    output += callout.opening
                    stack.append(Frame(closing: callout.closing))
                    cursor = callout.resume
                } else {
                    output += html[open.lowerBound..<tagEnd.upperBound]
                    stack.append(Frame(closing: nil))
                    cursor = tagEnd.upperBound
                }
            } else if let close {
                output += html[cursor..<close.lowerBound]
                if let frame = stack.popLast(), let closing = frame.closing { output += closing } else { output += closeToken }
                cursor = close.upperBound
            } else {
                break
            }
        }
        output += html[cursor...]
        return output
    }

    /// Начало выноски, если цитата начинается с маркера: HTML открытия, закрывающая часть и место продолжения разбора.
    private static func callout(in html: String, afterTag start: String.Index, attributes: String,
                                expandCollapsed: Bool) -> (opening: String, closing: String, resume: String.Index)? {
        var index = start
        if html[index...].hasPrefix("\n") { index = html.index(after: index) }
        guard html[index...].hasPrefix("<p"), let paragraphTagEnd = html.range(of: ">", range: index..<html.endIndex) else { return nil }
        let paragraphTag = html[index..<paragraphTagEnd.lowerBound]
        guard paragraphTag == "<p" || paragraphTag.hasPrefix("<p ") else { return nil }
        guard let paragraphClose = html.range(of: "</p>", range: paragraphTagEnd.upperBound..<html.endIndex) else { return nil }
        let inner = html[paragraphTagEnd.upperBound..<paragraphClose.lowerBound]
        guard let parsed = marker(in: inner) else { return nil }
        let afterMarker = inner.index(inner.startIndex, offsetBy: parsed.length)
        let remainder = inner[afterMarker...]
        // Первая строка после маркера — заголовок пользователя; остаток абзаца идёт в тело.
        var titleHTML = Substring("")
        var bodyHTML = Substring("")
        let lineBreak = remainder.range(of: "\n")
        let hardBreak = remainder.range(of: "<br />")
        let split: Range<Substring.Index>?
        switch (lineBreak, hardBreak) {
        case let (first?, second?): split = first.lowerBound < second.lowerBound ? first : second
        case let (first?, nil): split = first
        case let (nil, second?): split = second
        default: split = nil
        }
        if let split {
            titleHTML = remainder[remainder.startIndex..<split.lowerBound]
            bodyHTML = remainder[split.upperBound...]
        } else {
            titleHTML = remainder
        }
        let title = titleHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTrimmed = bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines)

        let kind = MarkdownCalloutKind.kind(forType: parsed.marker.type)
        let visibleKind = kind ?? .note
        let label = kind?.label ?? capitalized(parsed.marker.type)
        let plainTitle = plainText(ofHTML: title)
        let ariaLabel = plainTitle.isEmpty ? label : L10n.tr("标注标签 %@：%@", label, plainTitle)
        var classes = "lac-callout lac-callout-\(visibleKind.rawValue)"
        if kind == nil { classes += " lac-callout-custom" }
        let sourcePosition = attribute("data-sourcepos", in: attributes).map { " data-sourcepos=\"\($0)\"" } ?? ""
        let titleContent = "<span class=\"lac-callout-icon\" aria-hidden=\"true\">\(visibleKind.symbol)</span>"
            + "<span class=\"lac-callout-label\">\(label)</span>"
            + (title.isEmpty ? "" : "<span class=\"lac-callout-text\">\(title)</span>")

        // Есть ли после первого абзаца что-то ещё в цитате.
        var next = paragraphClose.upperBound
        if html[next...].hasPrefix("\n") { next = html.index(after: next) }
        let hasMoreBlocks = !html[next...].hasPrefix("</blockquote>")
        let hasBody = !bodyTrimmed.isEmpty || hasMoreBlocks

        var opening: String
        var closing: String
        switch parsed.marker.fold {
        case .none:
            opening = "<div class=\"\(classes)\" role=\"note\" aria-label=\"\(ariaLabel)\"\(sourcePosition)>"
                + "<div class=\"lac-callout-title\">\(titleContent)</div>"
            closing = "</div>"
        case .open, .closed:
            let isOpen = parsed.marker.fold == .open || expandCollapsed
            opening = "<details class=\"\(classes)\"\(isOpen ? " open" : "") aria-label=\"\(ariaLabel)\"\(sourcePosition)>"
                + "<summary class=\"lac-callout-title\">\(titleContent)</summary>"
            closing = "</details>"
        }
        if hasBody {
            opening += "<div class=\"lac-callout-body\">"
            if !bodyTrimmed.isEmpty {
                let paragraphAttributes = String(paragraphTag.dropFirst(2))
                opening += "<p\(paragraphAttributes)>\(bodyTrimmed)</p>"
            }
            closing = "</div>" + closing
        }
        return (opening, closing, paragraphClose.upperBound)
    }

    /// Значение атрибута из строки атрибутов тега; nil — атрибута нет.
    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let start = attributes.range(of: " \(name)=\"") ?? attributes.range(of: "\(name)=\"") else { return nil }
        guard let end = attributes.range(of: "\"", range: start.upperBound..<attributes.endIndex) else { return nil }
        return String(attributes[start.upperBound..<end.lowerBound])
    }

    /// Тип неизвестной выноски с заглавной буквы; символы типа только `[A-Za-z0-9_-]`, поэтому экранирование не нужно.
    private static func capitalized(_ type: String) -> String {
        guard let first = type.first else { return type }
        return first.uppercased() + type.dropFirst()
    }

    /// Текст заголовка без тегов (для `aria-label`); сущности cmark остаются экранированными.
    static func plainText(ofHTML html: String) -> String {
        var result = ""
        var insideTag = false
        for character in html {
            if character == "<" { insideTag = true } else if character == ">", insideTag { insideTag = false } else if !insideTag { result.append(character) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// CSS выносок и встраиваний (как `CriticMarkupPreviewStyle.css`): светлая/тёмная тема через уже существующие переменные,
/// повышенный контраст и печать работают за счёт тех же переменных.
enum MarkdownObsidianPreviewStyle {
    static var css: String {
        var rules = ""
        for group in ["note", "tip", "warning", "important", "caution"] {
            let selectors = MarkdownCalloutKind.allCases.filter { $0.colorGroup == group }.map { ".lac-callout-\($0.rawValue)" }.joined(separator: ", ")
            rules += "      \(selectors) { --alert: var(--alert-\(group)); --alert-text: var(--alert-\(group)-text); }\n"
        }
        rules += "      .lac-callout-quote { --alert: var(--border); --alert-text: var(--secondary); }\n"
        return rules + """
              .lac-callout { margin: 1.15em 0; padding: .55em .9em; border-left: 3px solid var(--alert, var(--border)); border-radius: 0 6px 6px 0; background: color-mix(in srgb, var(--alert, var(--border)) 8%, var(--quote)); }
              .lac-callout-title { display: flex; flex-wrap: wrap; gap: .1em .5em; align-items: baseline; font-weight: 400; }
              summary.lac-callout-title { cursor: pointer; }
              summary.lac-callout-title:focus-visible { outline: 2px solid var(--lac-accent, var(--accent)); outline-offset: 2px; border-radius: 3px; }
              .lac-callout-icon { color: var(--alert-text, var(--secondary)); }
              .lac-callout-label { font-weight: 600; color: var(--alert-text, var(--secondary)); }
              .lac-callout-body { margin-top: .4em; }
              .lac-callout-body > :first-child { margin-top: 0; }
              .lac-callout-body > :last-child { margin-bottom: 0; }
              .lac-callout .lac-callout { margin: .6em 0; }
              .lac-embed { margin: 1.15em 0; border: 1px solid var(--border); border-radius: 6px; background: var(--quote); }
              .lac-embed-head { display: flex; justify-content: space-between; gap: .8em; align-items: baseline; padding: .35em .8em; border-bottom: 1px solid var(--border); font-size: .9em; }
              .lac-embed-name { font-weight: 600; }
              .lac-embed-body { padding: .1em .8em; }
              .lac-embed-note { margin: .5em .8em; color: var(--secondary); font-size: .9em; }
              .lac-embed-missing { border-style: dashed; }
              @media print {
                .lac-callout, .lac-embed-head { break-inside: avoid; }
                .lac-callout, .lac-embed { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
              }

            """
    }
}

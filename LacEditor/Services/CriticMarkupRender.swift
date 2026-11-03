import Foundation

/// Режим показа правок в предпросмотре и при выводе в PDF/HTML/PNG/печать.
enum CriticMarkupRenderMode: String, CaseIterable, Sendable {
    case show      // правки подсвечены
    case result    // все правки приняты
    case original  // все правки отклонены
}

/// CriticMarkup в предпросмотре. cmark работает в безопасном режиме и сырой `<ins>` не выводит, поэтому до cmark
/// разделители правок заменяются служебными символами (Private Use Area), а после рендера — настоящими тегами.
enum CriticMarkupRender {
    /// Результат подготовки текста. `markerBase` не nil, только если в текст вставлены служебные символы
    /// (тогда после рендера нужен `finalize` с этим же значением).
    struct Prepared {
        let text: String
        let comments: [String]
        let markerBase: UInt16?
    }

    /// Служебные символы: блок из 0x20 подряд идущих символов Private Use Area, не встречающихся в тексте пользователя.
    /// Не буквы и не цифры, поэтому не попадают в идентификаторы заголовков; в UTF-8 по 3 байта, как `{++`.
    private struct Markers {
        static let firstBase: UInt16 = 0xE010
        static let blockSize: UInt16 = 0x20
        static let end: UInt32 = 0xF8FF

        let base: UInt16
        var insOpen: UInt16 { base }
        var insClose: UInt16 { base + 1 }
        var delOpen: UInt16 { base + 2 }
        var delClose: UInt16 { base + 3 }
        var hlOpen: UInt16 { base + 4 }
        var hlClose: UInt16 { base + 5 }
        var cmOpen: UInt16 { base + 6 }
        var cmClose: UInt16 { base + 7 }
        var filler: UInt16 { base + 8 }
        var firstDigit: UInt16 { base + 0x10 }

        func contains(_ unit: UInt16) -> Bool { unit >= base && unit < base + Markers.blockSize }

        static func text(_ unit: UInt16) -> String {
            String(Character(Unicode.Scalar(unit) ?? "\u{FFFD}"))
        }

        func digits(_ number: Int) -> String {
            String(number).utf16.map { Markers.text(firstDigit + ($0 - 48)) }.joined()
        }
    }

    private enum Kind {
        case ins, del, hl

        var openTag: String {
            switch self {
            case .ins: "<ins class=\"critic-ins\">"
            case .del: "<del class=\"critic-del\">"
            case .hl: "<mark class=\"critic-hl\">"
            }
        }

        var closeTag: String {
            switch self {
            case .ins: "</ins>"
            case .del: "</del>"
            case .hl: "</mark>"
            }
        }
    }

    /// Быстрая проверка: есть ли вообще начало какой-либо правки (`{++`, `{--`, `{~~`, `{>>`, `{==`).
    static func mayContainMarkup(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            var index = 0
            let count = buffer.count
            while index + 2 < count {
                if buffer[index] == 0x7B {
                    let second = buffer[index + 1]
                    if buffer[index + 2] == second, second == 0x2B || second == 0x2D || second == 0x7E || second == 0x3E || second == 0x3D {
                        return true
                    }
                }
                index += 1
            }
            return false
        }
    }

    /// Правки текста вне кода, таблиц, формул и front matter; пусто, если разметки нет или разбор невозможен.
    static func items(in text: String, syntax: MarkdownSyntaxOptions) -> [CriticMarkupItem] {
        guard mayContainMarkup(text) else { return [] }
        let length = (text as NSString).length
        let index = MarkdownPresentationParser.parse(text, syntax: syntax, isCancelled: { false }).elements
        guard index.textLength == length else { return [] }
        let excluded = index.excludedRanges(intersecting: NSRange(location: 0, length: length))
        return CriticMarkupService.items(in: text as NSString, excluded: excluded)
    }

    /// Текст после принятия или отклонения правок и выделение в новых координатах (для оформленного копирования).
    /// Начало внутри замены переходит в начало замены, конец внутри замены — в её конец.
    static func resolved(_ text: String, accept: Bool, selection: NSRange, syntax: MarkdownSyntaxOptions) -> (text: String, selection: NSRange) {
        let found = items(in: text, syntax: syntax)
        guard !found.isEmpty else { return (text, selection) }
        let source = text as NSString
        let replacements = CriticMarkupService.resolutions(of: found, accept: accept, in: source).reversed()
        let mutable = NSMutableString(string: text)
        for replacement in replacements.reversed() { mutable.replaceCharacters(in: replacement.range, with: replacement.replacement) }
        func map(_ position: Int, isEnd: Bool) -> Int {
            var shift = 0
            for replacement in replacements {
                let range = replacement.range, newLength = (replacement.replacement as NSString).length
                if NSMaxRange(range) <= position { shift += newLength - range.length; continue }
                if range.location >= position { break }
                return range.location + shift + (isEnd ? newLength : 0)
            }
            return position + shift
        }
        let start = map(selection.location, isEnd: false), end = max(start, map(NSMaxRange(selection), isEnd: true))
        return (mutable as String, NSRange(location: start, length: end - start))
    }

    /// Подготовка текста до cmark. Число строк в `.show` сохраняется.
    /// `comments` — побочная таблица текстов комментариев (индекс = номер маркера).
    static func prepare(_ text: String, mode: CriticMarkupRenderMode, syntax: MarkdownSyntaxOptions) -> Prepared {
        let unchanged = Prepared(text: text, comments: [], markerBase: nil)
        let found = items(in: text, syntax: syntax)
        guard !found.isEmpty else { return unchanged }
        let source = text as NSString
        switch mode {
        case .result, .original:
            let mutable = NSMutableString(string: text)
            for replacement in CriticMarkupService.resolutions(of: found, accept: mode == .result, in: source) {
                mutable.replaceCharacters(in: replacement.range, with: replacement.replacement)
            }
            return Prepared(text: mutable as String, comments: [], markerBase: nil)
        case .show:
            guard let base = freeBase(in: text) else { return unchanged }
            let markers = Markers(base: base)
            var output = ""
            var comments: [String] = []
            var cursor = 0
            for item in found {
                output += source.substring(with: NSRange(location: cursor, length: item.range.location - cursor))
                let content = source.substring(with: item.content)
                switch item.kind {
                case .insertion:
                    output += Markers.text(markers.insOpen) + content + Markers.text(markers.insClose)
                case .deletion:
                    output += Markers.text(markers.delOpen) + content + Markers.text(markers.delClose)
                case .highlight:
                    output += Markers.text(markers.hlOpen) + content + Markers.text(markers.hlClose)
                case .substitution:
                    guard let separator = item.separator else { break }
                    let before = source.substring(with: NSRange(location: item.content.location, length: separator.location - item.content.location))
                    let after = source.substring(with: NSRange(location: NSMaxRange(separator), length: NSMaxRange(item.content) - NSMaxRange(separator)))
                    output += Markers.text(markers.delOpen) + before + Markers.text(markers.delClose)
                        + Markers.text(markers.insOpen) + after + Markers.text(markers.insClose)
                case .comment:
                    output += Markers.text(markers.cmOpen) + markers.digits(comments.count) + Markers.text(markers.cmClose)
                    // Каждый перевод строки внутри комментария заменяется строкой-наполнителем: число строк не меняется.
                    output += String(repeating: "\n" + Markers.text(markers.filler), count: lineBreaks(in: content))
                    comments.append(content)
                }
                cursor = NSMaxRange(item.range)
            }
            output += source.substring(from: cursor)
            return Prepared(text: output, comments: comments, markerBase: base)
        }
    }

    /// Замена служебных символов в готовом HTML на теги. Вызывается после рендера, только если `prepare` вернул `markerBase`.
    static func finalize(html: String, comments: [String], markerBase: UInt16) -> String {
        let markers = Markers(base: markerBase)
        let scalars = Array(html.unicodeScalars)
        var output = ""
        var tagStack: [String] = []
        var open: Kind?
        var openDepth = 0
        var reopen: Kind?
        var index = 0

        func kind(opening unit: UInt16) -> Kind? {
            switch unit {
            case markers.insOpen: return .ins
            case markers.delOpen: return .del
            case markers.hlOpen: return .hl
            default: return nil
            }
        }
        func kind(closing unit: UInt16) -> Kind? {
            switch unit {
            case markers.insClose: return .ins
            case markers.delClose: return .del
            case markers.hlClose: return .hl
            default: return nil
            }
        }
        func append(_ scalar: Unicode.Scalar) { output.unicodeScalars.append(scalar) }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "<" {
                // Тег целиком: маркеры внутри (href, id, alt) удаляются. Внутри атрибутов `>` экранирован как `&gt;`.
                var end = index
                while end < scalars.count, scalars[end] != ">" { end += 1 }
                let finish = min(end, scalars.count - 1)
                var tag = String.UnicodeScalarView()
                for position in index...finish where !(scalars[position].value <= 0xFFFF && markers.contains(UInt16(scalars[position].value))) {
                    tag.append(scalars[position])
                }
                index = finish + 1
                let tagText = String(tag)
                let isClosing = tagText.hasPrefix("</")
                let name = tagName(tagText, closing: isClosing)
                if isClosing, !name.isEmpty {
                    if let position = tagStack.lastIndex(of: name) {
                        // Закрывается элемент, открытый раньше правки: правку закрываем перед ним и откроем заново позже.
                        if let current = open, position < openDepth {
                            output += current.closeTag
                            reopen = current
                            open = nil
                        }
                        tagStack.removeSubrange(position...)
                    }
                    output += tagText
                } else {
                    output += tagText
                    if !name.isEmpty, !tagText.hasPrefix("<!"), !tagText.hasPrefix("<?") {
                        if !Self.voidTags.contains(name), !tagText.hasSuffix("/>") { tagStack.append(name) }
                        if let pending = reopen, Self.reopenTags.contains(name) {
                            output += pending.openTag
                            open = pending
                            openDepth = tagStack.count
                            reopen = nil
                        }
                    }
                }
                continue
            }
            index += 1
            guard scalar.value <= 0xFFFF, markers.contains(UInt16(scalar.value)) else {
                append(scalar)
                continue
            }
            let unit = UInt16(scalar.value)
            if let opening = kind(opening: unit) {
                if open == nil {
                    output += opening.openTag
                    open = opening
                    openDepth = tagStack.count
                }
                reopen = nil
            } else if let closing = kind(closing: unit) {
                if open == closing {
                    output += closing.closeTag
                    open = nil
                } else if reopen == closing {
                    reopen = nil
                }
            } else if unit == markers.cmOpen {
                var number = 0
                var valid = false
                while index < scalars.count, scalars[index].value <= 0xFFFF {
                    let next = UInt16(scalars[index].value)
                    index += 1
                    if next == markers.cmClose { break }
                    if next >= markers.firstDigit, next < markers.firstDigit + 10 {
                        number = number * 10 + Int(next - markers.firstDigit)
                        valid = true
                    } else { valid = false; break }
                }
                if valid, number < comments.count {
                    let label = attributeEscaped(commentLabel(comments[number]))
                    output += "<span class=\"critic-comment\" role=\"note\" tabindex=\"0\" aria-label=\"\(label)\" title=\"\(label)\">&#9998;</span>"
                }
            } else if unit == markers.filler {
                // Строка-наполнитель вместе с переводом строки перед ней (`<br />`, перевод строки или пробел).
                if output.hasSuffix("<br />\n") { output.removeLast(7) }
                else if output.hasSuffix("\n") || output.hasSuffix(" ") { output.removeLast() }
            }
        }
        if let current = open { output += current.closeTag }
        return output
    }

    /// Текст ярлыка комментария для VoiceOver и подсказки.
    static func commentLabel(_ raw: String) -> String {
        L10n.tr("批注：%@", raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Вспомогательное

    private static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "col", "area", "base", "wbr", "source", "track", "embed", "param"]
    /// Теги, после открытия которых правка, прерванная границей блока, открывается снова.
    private static let reopenTags: Set<String> = ["p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "dt", "dd", "summary", "figcaption", "caption",
                                                  "em", "strong", "a", "span", "sup", "sub", "b", "i", "u", "s"]

    private static func tagName(_ tag: String, closing: Bool) -> String {
        var name = ""
        for character in tag.dropFirst(closing ? 2 : 1) {
            guard character.isASCII, character.isLetter || character.isNumber else { break }
            name.append(character.lowercased())
        }
        return name
    }

    private static func attributeEscaped(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "[": result += "&#91;"
            case "]": result += "&#93;"
            case "`": result += "&#96;"
            case "\n", "\r", "\r\n": result += " "
            default: result.append(character)
            }
        }
        return result
    }

    /// Первый свободный блок служебных символов; nil, если в тексте заняты все.
    private static func freeBase(in text: String) -> UInt16? {
        var used = Set<UInt16>()
        for unit in text.utf16 {
            if unit >= Markers.firstBase, UInt32(unit) <= Markers.end { used.insert((unit - Markers.firstBase) / Markers.blockSize) }
        }
        var block: UInt16 = 0
        while UInt32(Markers.firstBase) + UInt32(block + 1) * UInt32(Markers.blockSize) <= Markers.end + 1 {
            if !used.contains(block) { return Markers.firstBase + block * Markers.blockSize }
            block += 1
        }
        return nil
    }

    /// Число переводов строки (CR, LF, CRLF) — столько строк займёт текст в исходнике.
    private static func lineBreaks(in text: String) -> Int {
        var count = 0
        var previousReturn = false
        for unit in text.utf16 {
            if unit == 10 { if !previousReturn { count += 1 } }
            else if unit == 13 { count += 1 }
            previousReturn = unit == 13
        }
        return count
    }
}

/// Цвета правок в предпросмотре: один источник для CSS и для проверки контраста.
enum CriticMarkupPreviewStyle {
    struct Pair {
        let text: String
        let background: String
        init(_ text: String, _ background: String) {
            self.text = text
            self.background = background
        }
    }

    typealias Palette = (ins: Pair, del: Pair, hl: Pair, comment: Pair)

    static let light: Palette = (ins: Pair("#303038", "#d6f1dc"), del: Pair("#303038", "#fadadd"),
                                 hl: Pair("#303038", "#fff1a8"), comment: Pair("#7a4a00", "#fbfbfb"))
    static let dark: Palette = (ins: Pair("#dddde3", "#1f4a2c"), del: Pair("#dddde3", "#5a2328"),
                                hl: Pair("#dddde3", "#5a4a10"), comment: Pair("#f0b45a", "#1b1b1b"))
    static let contrast: Palette = (ins: Pair("#1c1c22", "#c4ebcc"), del: Pair("#1c1c22", "#f5c4c8"),
                                    hl: Pair("#1c1c22", "#ffe680"), comment: Pair("#5c3a00", "#fbfbfb"))

    private static func variables(_ palette: Palette) -> String {
        "--critic-ins-fg:\(palette.ins.text);--critic-ins-bg:\(palette.ins.background);"
            + "--critic-del-fg:\(palette.del.text);--critic-del-bg:\(palette.del.background);"
            + "--critic-hl-fg:\(palette.hl.text);--critic-hl-bg:\(palette.hl.background);"
            + "--critic-comment:\(palette.comment.text)"
    }

    /// Готовый CSS-блок; вставляется в конец стилей страницы, печать (светлые цвета) задана здесь же.
    static var css: String {
        """
          :root { \(variables(light)) }
          :root[data-theme="dark"] { \(variables(dark)) }
          ins.critic-ins { background: var(--critic-ins-bg); color: var(--critic-ins-fg); text-decoration: underline; text-underline-offset: 2px; border-radius: 2px; }
          del.critic-del { background: var(--critic-del-bg); color: var(--critic-del-fg); text-decoration: line-through; border-radius: 2px; }
          mark.critic-hl { background: var(--critic-hl-bg); color: var(--critic-hl-fg); border-radius: 2px; }
          .critic-comment { color: var(--critic-comment); cursor: help; font-size: .85em; vertical-align: super; padding: 0 .2em; border-radius: 2px; }
          .critic-comment:focus { outline: 2px solid var(--critic-comment); outline-offset: 1px; }
          @media (prefers-contrast: more) {
            :root { \(variables(contrast)) }
            :root[data-theme="dark"] { \(variables(contrast)); --critic-comment: \(dark.comment.text) }
          }
          @media print {
            :root, :root[data-theme="dark"] { \(variables(light)) }
            ins.critic-ins, del.critic-del, mark.critic-hl { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
          }
        """
    }
}

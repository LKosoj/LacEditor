import Foundation

/// Режим показа правок в предпросмотре и при выводе в PDF/HTML/PNG/печать.
enum CriticMarkupRenderMode: String, CaseIterable, Sendable {
    case show      // правки подсвечены
    case result    // все правки приняты
    case original  // все правки отклонены
}

/// CriticMarkup: поиск правок и их принятие/отклонение. Вывод в HTML делает адаптер `MarkdownHTMLRenderer` по модели.
enum CriticMarkupRender {
    enum Kind {
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
        // Без `.criticMarkup` и без `isVaultNote`: зоны исключения не должны зависеть от самих правок.
        guard let index = MarkdownDocumentParser.parseOrEmpty(text, syntax: syntax, includes: [.elementIndex]).elements,
              index.textLength == length else { return [] }
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

    /// Текст ярлыка комментария для VoiceOver и подсказки.
    static func commentLabel(_ raw: String) -> String {
        L10n.tr("批注：%@", raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Вспомогательное

    static func attributeEscaped(_ value: String) -> String {
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

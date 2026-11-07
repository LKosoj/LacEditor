import Foundation

/// Выноски Obsidian `> [!тип]±? Заголовок`: разбор маркера и подписи; HTML выводит адаптер `MarkdownHTMLRenderer`.
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

    /// Тип неизвестной выноски с заглавной буквы; символы типа только `[A-Za-z0-9_-]`, поэтому экранирование не нужно.
    static func capitalized(_ type: String) -> String {
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

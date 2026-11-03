import Foundation

/// Режим экспорта в Pandoc/PDF/HTML.
enum CriticMarkupExportMode: String, CaseIterable, Sendable {
    case clean      // чистая версия: все правки приняты (по умолчанию)
    case original   // оригинал: все правки отклонены
    case tracked    // с правками: исправления и примечания Word
}

extension CriticMarkupExportMode {
    /// Режим показа в нативном выводе (PDF, HTML без стилей): чистая версия, оригинал или подсвеченные правки.
    var renderMode: CriticMarkupRenderMode {
        switch self {
        case .clean: .result
        case .original: .original
        case .tracked: .show
        }
    }
}

extension PandocExportFormat {
    /// «С правками» Pandoc умеет только для DOCX; остальные форматы оставляют разметку текстом.
    var supportsTrackedChanges: Bool { self == .docx }
}

/// CriticMarkup при экспорте через Pandoc: принятие или отклонение правок текстом либо превращение в исправления и примечания Word.
enum CriticMarkupPandoc {
    /// Текст после принятия (`accept`) или отклонения всех правок вне кода, таблиц, формул и front matter.
    static func resolved(_ text: String, accept: Bool, syntax: MarkdownSyntaxOptions) -> String {
        let found = CriticMarkupRender.items(in: text, syntax: syntax)
        guard !found.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for replacement in CriticMarkupService.resolutions(of: found, accept: accept, in: text as NSString) {
            mutable.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
        return mutable as String
    }

    /// Есть ли в тексте хотя бы одна правка вне кода (для показа переключателей в панели сохранения).
    static func hasMarkup(in text: String, syntax: MarkdownSyntaxOptions) -> Bool {
        !CriticMarkupRender.items(in: text, syntax: syntax).isEmpty
    }

    /// Текст для Pandoc по выбранному режиму. `prefix` не nil, только если вставлены токены режима «с правками»
    /// (тогда после чтения JSON нужен `apply(to:prefix:)`).
    static func source(for text: String, mode: CriticMarkupExportMode, supportsTracked: Bool,
                       syntax: MarkdownSyntaxOptions) -> (text: String, prefix: String?) {
        guard CriticMarkupRender.mayContainMarkup(text) else { return (text, nil) }
        switch mode {
        case .clean: return (resolved(text, accept: true, syntax: syntax), nil)
        case .original: return (resolved(text, accept: false, syntax: syntax), nil)
        case .tracked:
            guard supportsTracked, let tokenized = tokenize(text, syntax: syntax) else { return (text, nil) }
            return (tokenized.text, tokenized.prefix)
        }
    }

    /// Для режима «с правками»: заменить разделители токенами `prefix + вид + номер + "Z"`.
    /// Виды: `I`/`i` — вставка, `D`/`d` — удаление, `H`/`h` — выделение, `C`/`c` — комментарий (заглавная — начало, строчная — конец).
    /// Токены состоят из латиницы и цифр: Pandoc оставляет их внутри `Str`, `--` в разделителях исчезает и не портится `+smart`.
    static func tokenize(_ text: String, syntax: MarkdownSyntaxOptions) -> (text: String, prefix: String)? {
        let found = CriticMarkupRender.items(in: text, syntax: syntax)
        guard !found.isEmpty else { return nil }
        var prefix: String
        repeat { prefix = "LACCRITIC" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while text.contains(prefix)
        func token(_ kind: String, _ number: Int) -> String { prefix + kind + String(number) + "Z" }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for (number, item) in found.enumerated() {
            output += source.substring(with: NSRange(location: cursor, length: item.range.location - cursor))
            let content = source.substring(with: item.content)
            switch item.kind {
            case .insertion: output += token("I", number) + content + token("i", number)
            case .deletion: output += token("D", number) + content + token("d", number)
            case .highlight: output += token("H", number) + content + token("h", number)
            case .comment: output += token("C", number) + content + token("c", number)
            case .substitution:
                guard let separator = item.separator else { break }
                let before = source.substring(with: NSRange(location: item.content.location, length: separator.location - item.content.location))
                let after = source.substring(with: NSRange(location: NSMaxRange(separator), length: NSMaxRange(item.content) - NSMaxRange(separator)))
                output += token("D", number) + before + token("d", number) + token("I", number) + after + token("i", number)
            }
            cursor = NSMaxRange(item.range)
        }
        output += source.substring(from: cursor)
        return (output, prefix)
    }

    /// Применить `transform` к блокам дерева Pandoc (автор и дата — текущие).
    static func apply(to tree: inout [String: Any], prefix: String) {
        var blocks: Any = tree["blocks"] ?? [Any]()
        transform(json: &blocks, prefix: prefix, author: defaultAuthor, date: isoDate())
        tree["blocks"] = blocks
    }

    /// Токены → `Span` с классами `insertion`, `deletion`, `comment-start`/`comment-end` (их превращает в правки и примечания docx-писатель Pandoc)
    /// и `mark`. Правка, начало и конец которой попали в разные списки inline-узлов, теряет оформление: токены удаляются, текст остаётся.
    static func transform(json: inout Any, prefix: String, author: String, date: String) {
        let state = TransformState(prefix: prefix, author: author, date: date)
        json = state.visit(json)
    }

    static var defaultAuthor: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        let short = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty ? "Editor" : short
    }

    /// ISO 8601, UTC, без долей секунды.
    static func isoDate(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        return formatter.string(from: date)
    }

    // MARK: - Разбор дерева

    fileprivate enum Piece {
        case node(Any)
        case token(kind: Character, number: Int)
    }

    fileprivate final class TransformState {
        let prefix: String
        let author: String
        let date: String
        var nextID = 1

        init(prefix: String, author: String, date: String) {
            self.prefix = prefix
            self.author = author
            self.date = date
        }

        func visit(_ value: Any) -> Any {
            if let array = value as? [Any] {
                return group(array.map { visit($0) })
            }
            if let object = value as? [String: Any] {
                // Текст `Str` с токенами разбирается на уровне списка, в котором он лежит.
                if object["t"] as? String == "Str" { return object }
                var result: [String: Any] = [:]
                for (key, item) in object { result[key] = visit(item) }
                if object["t"] as? String == "Header" { cleanHeaderID(&result) }
                return result
            }
            if let text = value as? String, text.contains(prefix) {
                // Адреса, подписи и прочие строки вне текста: токены просто убираются.
                return pieces(of: text).reduce(into: "") { result, piece in
                    if case .node(let node) = piece, let part = (node as? [String: Any])?["c"] as? String { result += part }
                }
            }
            return value
        }

        /// Pandoc строит id заголовка из текста вместе с токенами (в нижнем регистре): токены из id убираются.
        func cleanHeaderID(_ header: inout [String: Any]) {
            guard var content = header["c"] as? [Any], content.count > 1, var attributes = content[1] as? [Any],
                  let id = attributes.first as? String else { return }
            let pattern = NSRegularExpression.escapedPattern(for: prefix) + "[idhc][0-9]+z"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
            let cleaned = expression.stringByReplacingMatches(in: id, range: NSRange(location: 0, length: (id as NSString).length), withTemplate: "")
            guard cleaned != id else { return }
            attributes[0] = cleaned
            content[1] = attributes
            header["c"] = content
        }

        /// Разбить строку на текст и токены; повреждённый токен остаётся текстом.
        func pieces(of text: String) -> [Piece] {
            let raw = text as NSString
            var result: [Piece] = []
            var cursor = 0
            func appendText(_ range: NSRange) {
                if range.length > 0 { result.append(.node(str(raw.substring(with: range)))) }
            }
            while cursor < raw.length {
                let start = raw.range(of: prefix, options: .literal, range: NSRange(location: cursor, length: raw.length - cursor))
                guard start.location != NSNotFound else { break }
                var position = NSMaxRange(start)
                var parsed: (Character, Int)?
                if position < raw.length, let kind = Unicode.Scalar(raw.character(at: position)).map({ Character($0) }), "IiDdHhCc".contains(kind) {
                    position += 1
                    var number = 0
                    var digits = 0
                    while position < raw.length, (48...57).contains(raw.character(at: position)), digits < 9 {
                        number = number * 10 + Int(raw.character(at: position) - 48)
                        position += 1
                        digits += 1
                    }
                    if digits > 0, position < raw.length, raw.character(at: position) == 90 {
                        position += 1
                        parsed = (kind, number)
                    }
                }
                guard let (kind, number) = parsed else {
                    // Не токен: префикс остаётся обычным текстом.
                    appendText(NSRange(location: cursor, length: NSMaxRange(start) - cursor))
                    cursor = NSMaxRange(start)
                    continue
                }
                appendText(NSRange(location: cursor, length: start.location - cursor))
                result.append(.token(kind: kind, number: number))
                cursor = position
            }
            appendText(NSRange(location: cursor, length: raw.length - cursor))
            return result
        }

        func str(_ text: String) -> [String: Any] { ["t": "Str", "c": text] }

        func containsToken(_ element: Any) -> Bool {
            guard let node = element as? [String: Any], node["t"] as? String == "Str", let text = node["c"] as? String else { return false }
            return text.contains(prefix)
        }

        func span(_ classes: [String], _ attributes: [[String]], _ inlines: [Any]) -> [String: Any] {
            ["t": "Span", "c": [["", classes, attributes] as [Any], inlines] as [Any]]
        }

        func isMark(_ element: Any) -> Bool {
            guard let node = element as? [String: Any], node["t"] as? String == "Span",
                  let content = node["c"] as? [Any], let attributes = content.first as? [Any], attributes.count > 1,
                  let classes = attributes[1] as? [String] else { return false }
            return classes.contains("mark")
        }

        func isBlank(_ element: Any) -> Bool {
            guard let node = element as? [String: Any], let kind = node["t"] as? String else { return false }
            return kind == "Space" || kind == "SoftBreak"
        }

        func revisionAttributes() -> [[String]] {
            let id = nextID
            nextID += 1
            return [["id", String(id)], ["author", author], ["date", date]]
        }

        /// Один проход по списку inline-узлов: пары токенов превращаются в `Span`.
        func group(_ elements: [Any]) -> [Any] {
            guard elements.contains(where: { containsToken($0) }) else { return elements }
            var flat: [Piece] = []
            for element in elements {
                if containsToken(element), let text = (element as? [String: Any])?["c"] as? String { flat.append(contentsOf: pieces(of: text)) }
                else { flat.append(.node(element)) }
            }
            var output: [Any] = []
            var stack: [(kind: Character, number: Int, start: Int)] = []
            for piece in flat {
                switch piece {
                case .node(let node):
                    output.append(node)
                case .token(let kind, let number):
                    if "IDHC".contains(kind) {
                        stack.append((kind, number, output.count))
                        continue
                    }
                    // Закрытие без пары (вложенность невозможна: сервис не разбирает вложенные правки) — токен отбрасывается.
                    guard let open = stack.last, open.number == number, open.kind == Character(kind.uppercased()) else { continue }
                    stack.removeLast()
                    let children = Array(output[open.start...])
                    output.removeSubrange(open.start...)
                    switch open.kind {
                    case "I": output.append(span(["insertion"], revisionAttributes(), children))
                    case "D": output.append(span(["deletion"], revisionAttributes(), children))
                    case "H": output.append(span(["mark"], [], children))
                    default: appendComment(children, to: &output)
                    }
                }
            }
            // Незакрытые начала: токенов в output нет, содержимое уже на месте.
            return output
        }

        /// Комментарий сразу за выделением (допускается один пробельный узел) охватывает это выделение.
        func appendComment(_ text: [Any], to output: inout [Any]) {
            var highlighted: Any?
            if let last = output.last, isMark(last) {
                highlighted = output.removeLast()
            } else if output.count >= 2, let last = output.last, isBlank(last), isMark(output[output.count - 2]) {
                output.removeLast()
                highlighted = output.removeLast()
            }
            let id = String(nextID)
            nextID += 1
            output.append(span(["comment-start"], [["id", id], ["author", author], ["date", date]], text))
            if let highlighted { output.append(highlighted) }
            output.append(span(["comment-end"], [["id", id]], []))
        }
    }
}

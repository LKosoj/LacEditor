import Foundation
import SwiftSoup
import Yams

/// Markdown → Fountain без ИИ: титульная страница из front matter, разделы, действие, распознавание «уже сценарных» строк
/// (en/ru/zh), защита `!` для прозы, которая иначе стала бы персонажем или переходом. CriticMarkup всегда «принять всё»,
/// комментарии становятся заметками `[[ ]]`.
enum FountainExportService {
    struct Options: Sendable {
        var syntax: MarkdownSyntaxOptions
        /// Текст уже без правок CriticMarkup: предпроход пропускается.
        var sourceTextIsClean: Bool = false
    }

    /// Один файл или документ на входе.
    struct Part: Sendable {
        /// Имя узла или файла; пустое — документ целиком, без собственной секции.
        var title: String
        /// Тело вместе с front matter.
        var text: String
        /// 0 — документ целиком; для проекта — глубина узла.
        var level: Int
        /// Из манифеста проекта.
        var synopsis: String?
    }

    enum WarningKind: Hashable, Sendable {
        case table, image, formula, html, codeBlock, footnote, strikethrough
        case frontMatterUnreadable, unclosedNote, unclosedBoneyard, skippedFile
        /// ИИ-результат сцены не прошёл проверку; `detail` — номер сцены.
        case aiFallback
    }

    struct Warning: Equatable, Sendable {
        let kind: WarningKind
        let count: Int
        let detail: String?
    }

    struct Result {
        var text: String
        var warnings: [Warning]
        var lint: FountainLintResult
    }

    /// Сцена проекта для ИИ-адаптации: заголовок раздела и синопсис алгоритмически, тело отдельно.
    struct Scene: Sendable {
        var header: String
        var body: String
        var warnings: [Warning]
    }

    /// Один документ: титульная страница из front matter + тело.
    static func convertDocument(_ text: String, options: Options) -> Result {
        let converter = Converter(options: options, sources: [text])
        let titlePage = titlePage(frontMatterFrom: text, titleOverride: nil)
        let unit = converter.unit(for: Part(title: "", text: text, level: 0, synopsis: nil))
        return finish(titlePage: titlePage, blocks: converter.render([unit]), converter: converter, extra: [])
    }

    /// Проект: порядок и уровни уже определены вызывающим; группы приходят как Part с пустым text.
    static func convertProject(title: String, titleFrontMatterFrom first: String?, parts: [Part], options: Options) -> Result {
        let converter = Converter(options: options, sources: parts.map(\.text))
        let titlePage = titlePage(frontMatterFrom: first, titleOverride: title)
        let units = parts.map { converter.unit(for: $0) }
        return finish(titlePage: titlePage, blocks: converter.render(units), converter: converter, extra: [])
    }

    /// Только тело сцены (без титульника) — вход для ИИ-адаптации.
    static func convertBody(_ text: String, shiftLevels: Int, options: Options) -> (text: String, warnings: [Warning]) {
        let converter = Converter(options: options, sources: [text])
        var unit = converter.unit(for: Part(title: "", text: text, level: 0, synopsis: nil))
        unit.shift = shiftLevels
        let blocks = converter.render([unit])
        return (joined(blocks), converter.warnings())
    }

    /// Сцена проекта: раздел и синопсис (алгоритмически) и тело для ИИ. Первый заголовок файла, совпадающий с названием узла, не дублируется.
    static func scene(_ part: Part, options: Options) -> Scene {
        let converter = Converter(options: options, sources: [part.text])
        var unit = converter.unit(for: part)
        let header = joined(unit.header)
        unit.header = []
        let body = joined(converter.render([unit]))
        return Scene(header: header, body: body, warnings: converter.warnings())
    }

    /// Титульная страница из front matter. `titleOverride` — название проекта вместо `title`.
    static func titlePage(frontMatterFrom text: String?, titleOverride: String?) -> (text: String, warnings: [Warning]) {
        var values: [String: String] = [:]
        var warnings: [Warning] = []
        if let text, MarkdownFrontMatter.frontMatter(text) != nil {
            do {
                if let mapping = try PandocExportService.yamlFrontMatter(text) {
                    for (key, name) in titleKeys {
                        guard values[name] == nil, let node = mapping[key] else { continue }
                        var items: [String] = []
                        if let sequence = node.sequence {
                            items = sequence.compactMap { $0.scalar?.string }
                        } else if let scalar = node.scalar {
                            items = [scalar.string]
                        }
                        let value = (name == "Title" || name == "Notes") && node.sequence == nil
                            ? items.joined(separator: "\n") : items.joined(separator: ", ")
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values[name] = value }
                    }
                }
            } catch {
                warnings.append(Warning(kind: .frontMatterUnreadable, count: 1, detail: nil))
            }
        }
        if let override = titleOverride, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["Title"] = override
        }
        var lines: [String] = []
        for name in titleNames {
            guard let value = values[name] else { continue }
            let parts = value.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
                .map { Converter.titleText($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = parts.first else { continue }
            if parts.count == 1 {
                lines.append("\(name): \(first)")
            } else {
                lines.append("\(name):")
                lines += parts.map { "   " + $0 }
            }
        }
        return (lines.joined(separator: "\n"), warnings)
    }

    /// Части проекта в порядке книги по дереву манифеста. Выключенный узел скрывает всю ветку, группа без включённых текстов пропускается.
    /// `texts` — тексты по `node.path`; текстовый узел без текста попадает в `missing`.
    static func parts(from nodes: [ManuscriptNode], texts: [String: String], level: Int = 0) -> (parts: [Part], missing: [String]) {
        var parts: [Part] = []
        var missing: [String] = []
        for node in nodes where node.include {
            if node.kind == .group {
                let inner = Self.parts(from: node.children, texts: texts, level: level + 1)
                missing += inner.missing
                guard !inner.parts.isEmpty else { continue }
                parts.append(Part(title: node.title, text: "", level: level, synopsis: node.synopsis))
                parts += inner.parts
            } else if let path = node.path {
                let name = node.title.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : node.title
                guard let text = texts[path] else { missing.append(name); continue }
                parts.append(Part(title: name, text: text, level: level, synopsis: node.synopsis))
            }
        }
        return (parts, missing)
    }

    /// Складывает одинаковые предупреждения: счётчики суммируются, пояснения склеиваются.
    static func merge(_ lists: [[Warning]]) -> [Warning] {
        var order: [WarningKind] = []
        var counts: [WarningKind: Int] = [:]
        var details: [WarningKind: [String]] = [:]
        for warning in lists.flatMap({ $0 }) {
            if counts[warning.kind] == nil { order.append(warning.kind) }
            counts[warning.kind, default: 0] += warning.count
            if let detail = warning.detail, !detail.isEmpty { details[warning.kind, default: []].append(detail) }
        }
        return order.map { Warning(kind: $0, count: counts[$0] ?? 0, detail: details[$0].map { $0.joined(separator: ", ") }) }
    }

    // MARK: Сборка

    private static let titleKeys: [(String, String)] = [
        ("title", "Title"), ("credit", "Credit"), ("author", "Author"), ("authors", "Author"), ("source", "Source"),
        ("draft", "Draft date"), ("date", "Date"), ("contact", "Contact"), ("copyright", "Copyright"), ("notes", "Notes")
    ]
    private static let titleNames = ["Title", "Credit", "Author", "Source", "Draft date", "Date", "Contact", "Copyright", "Notes"]
    private static let titleKeyExpression = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9 ]*:")

    private static func joined(_ blocks: [[String]]) -> String {
        blocks.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    private static func finish(titlePage: (text: String, warnings: [Warning]), blocks: [[String]],
                               converter: Converter, extra: [Warning]) -> Result {
        var rendered = blocks.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }
        // Без титульной страницы первая строка вида «Ключ:» была бы принята за неё.
        if titlePage.text.isEmpty, let first = rendered.first,
           titleKeyExpression.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)) != nil {
            rendered[0] = "!" + first
        }
        let parts = (titlePage.text.isEmpty ? [] : [titlePage.text]) + rendered
        let text = parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
        let lint = FountainLint.parse(text, allowsTitlePage: true)
        var lintWarnings: [Warning] = []
        for (issue, kind) in [(FountainIssueKind.unclosedNote, WarningKind.unclosedNote), (.unclosedBoneyard, .unclosedBoneyard)] {
            let count = lint.issues.filter { $0.kind == issue }.count
            if count > 0 { lintWarnings.append(Warning(kind: kind, count: count, detail: nil)) }
        }
        return Result(text: text, warnings: merge([titlePage.warnings, converter.warnings(), extra, lintWarnings]), lint: lint)
    }
}

// MARK: - Внутреннее устройство

private typealias Warning = FountainExportService.Warning
private typealias WarningKind = FountainExportService.WarningKind

private struct PLine {
    var text: String
    /// После строки жёсткий перенос (`<br>`, два пробела); иначе мягкий.
    var hard: Bool
}

private enum Piece {
    case heading(level: Int, text: String)
    /// Готовый безопасный блок.
    case literal([String])
    /// Блок действия: перед выводом проверяется `!`.
    case action([String])
    /// Абзац: строки проходят распознавание сценарных элементов.
    case paragraph([PLine])
}

private struct Unit {
    var header: [[String]]
    var pieces: [Piece]
    var shift: Int
}

private struct Block {
    var lines: [String]
    var protect: Bool
}

private struct Speech {
    var name: String
    var base: String
    var cased: Bool
    var parenthetical: String?
    var text: String
}

private final class Converter {
    static let soft = Character("\u{1F}")
    private static let tokenOpen = "\u{E010}"
    private static let tokenClose = "\u{E011}"
    private static let tokenExpression = try! NSRegularExpression(pattern: "\u{E010}([0-9]+)\u{E011}")
    private static let wikiExpression = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]|\\n]+)(?:\\|([^\\[\\]\\n]+))?\\]\\]")
    private static let centerExpression = try! NSRegularExpression(
        pattern: "^\\s*<center[^>]*>(.*?)</center>\\s*$", options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let nativeScene = try! NSRegularExpression(pattern: "^(INT|EXT|EST|INT\\.?/EXT|I/E)[. ]")
    private static let russianScene = try! NSRegularExpression(pattern: "^(ИНТ|НАТ|ЭКСТ)\\.")
    private static let chineseScene = try! NSRegularExpression(pattern: "^(内外景|内景|外景)([ .．、：:]|$)")
    private static let fixedTransitions: Set<String> = ["FADE IN:", "FADE OUT.", "ЗАТЕМНЕНИЕ.", "淡入", "淡出", "切至", "转场"]

    let options: FountainExportService.Options
    let tokensAllowed: Bool
    private var counts: [WarningKind: Int] = [:]
    private var notes: [String] = []
    /// Исходный текст разбора (для проверки, что пара тегов начинается с `<`) и определения сносок по метке.
    private var source: NSString = ""
    private var footnoteDefinitions: [String: MarkdownBlockNode] = [:]
    private var output: [Piece] = []

    init(options: FountainExportService.Options, sources: [String]) {
        self.options = options
        // Служебные символы нельзя вставлять, если они уже есть в тексте: комментарии тогда просто пропадают.
        tokensAllowed = !sources.contains { $0.contains(Self.tokenOpen) || $0.contains(Self.tokenClose) }
    }

    func warnings() -> [Warning] {
        let order: [WarningKind] = [.table, .image, .formula, .html, .codeBlock, .footnote, .strikethrough]
        return order.compactMap { kind in counts[kind].map { Warning(kind: kind, count: $0, detail: nil) } }
    }

    static func titleText(_ value: String) -> String {
        var result = value
        while result.contains("[[") { result = result.replacingOccurrences(of: "[[", with: "[ [") }
        while result.contains("]]") { result = result.replacingOccurrences(of: "]]", with: "] ]") }
        return result.replacingOccurrences(of: "/*", with: "/ *").replacingOccurrences(of: "*/", with: "* /")
    }

    // MARK: Единица вывода

    func unit(for part: FountainExportService.Part) -> Unit {
        var header: [[String]] = []
        var pieces = self.pieces(from: Self.withoutFrontMatter(part.text))
        var shift = 0
        if !part.title.isEmpty {
            let title = plainLine(part.title)
            header.append([String(repeating: "#", count: min(part.level + 1, 6)) + " " + title])
            if let synopsis = part.synopsis?.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces), !synopsis.isEmpty {
                header.append(["= " + plainLine(synopsis)])
            }
            if case let .heading(_, text)? = pieces.first,
               text.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title.trimmingCharacters(in: .whitespaces)) == .orderedSame {
                pieces.removeFirst()
                shift = part.level
            } else {
                shift = part.level + 1
            }
        }
        return Unit(header: header, pieces: pieces, shift: shift)
    }

    private static func withoutFrontMatter(_ text: String) -> String {
        guard let frontMatter = MarkdownFrontMatter.frontMatter(text) else { return text }
        return (text as NSString).substring(from: NSMaxRange(frontMatter.range))
    }

    func render(_ units: [Unit]) -> [[String]] {
        let zh = chineseNames(units)
        var blocks: [[String]] = []
        for unit in units {
            blocks += unit.header
            for piece in unit.pieces {
                switch piece {
                case let .heading(level, text):
                    let expanded = expandNotes(text)
                    guard !expanded.isEmpty else { continue }
                    blocks.append([String(repeating: "#", count: min(max(level + unit.shift, 1), 6)) + " " + expanded])
                case let .literal(lines):
                    blocks.append(lines.map(expandNotes))
                case let .action(lines):
                    blocks.append(protected(lines.map(expandNotes)))
                case let .paragraph(lines):
                    for block in paragraph(lines, chinese: zh) {
                        let expanded = block.lines.map(expandNotes)
                        blocks.append(block.protect ? protected(expanded) : expanded)
                    }
                }
            }
        }
        return blocks
    }

    /// Строка прозы, которая по правилам Fountain стала бы персонажем, переходом, секцией и т. п., помечается `!`.
    private func protected(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return lines }
        let kind = FountainLint.classifyBlock(lines)
        // Проза, уже начинающаяся с «!», иначе потеряла бы его при разборе (принудительное действие).
        let startsWithBang = FountainLint.stripNotes(lines[0]).trimmingCharacters(in: .whitespaces).hasPrefix("!")
        guard startsWithBang || (kind != .action && kind != .blank) else { return lines }
        var result = lines
        result[0] = "!" + result[0]
        return result
    }

    // MARK: Заметки (служебные символы)

    private func note(_ text: String) -> String {
        guard tokensAllowed else { return "" }
        notes.append(text)
        return Self.tokenOpen + String(notes.count - 1) + Self.tokenClose
    }

    private func expandNotes(_ line: String) -> String {
        guard line.contains(Self.tokenOpen) else { return line }
        let source = line as NSString
        var result = ""
        var cursor = 0
        for match in Self.tokenExpression.matches(in: line, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let index = Int(source.substring(with: match.range(at: 1))), notes.indices.contains(index) {
                var text = notes[index].components(separatedBy: .newlines).joined(separator: " ")
                text = Self.tokenExpression.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
                text = text.trimmingCharacters(in: .whitespaces)
                while text.contains("[[") { text = text.replacingOccurrences(of: "[[", with: "[ [") }
                while text.contains("]]") { text = text.replacingOccurrences(of: "]]", with: "] ]") }
                text = text.replacingOccurrences(of: "*/", with: "* /").replacingOccurrences(of: "/*", with: "/ *")
                if !text.isEmpty { result += "[[" + text + "]]" }
            }
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    // MARK: Разбор модели документа

    private func prepareCritic(_ body: String) -> String {
        guard !options.sourceTextIsClean else { return body }
        let items = CriticMarkupRender.items(in: body, syntax: options.syntax)
        guard !items.isEmpty else { return body }
        let source = body as NSString
        var result = ""
        var cursor = 0
        for item in items {
            result += source.substring(with: NSRange(location: cursor, length: item.range.location - cursor))
            if item.kind == .comment {
                result += note(source.substring(with: item.content))
            } else {
                result += CriticMarkupService.resolution(of: item, accept: true, in: source)
            }
            cursor = NSMaxRange(item.range)
        }
        return result + source.substring(from: cursor)
    }

    func pieces(from body: String) -> [Piece] {
        let text = prepareCritic(body).replacingOccurrences(of: String(Self.soft), with: " ")
        // Прямые кавычки сценария не превращаем в «ёлочки»: умная пунктуация выключена, остальные настройки прежние.
        let base = options.syntax
        let syntax = MarkdownSyntaxOptions(
            strictMode: base.strictMode, inlineMath: base.inlineMath, legacyInlineMath: base.legacyInlineMath, smartPunctuation: false,
            preserveEditingWhitespace: base.preserveEditingWhitespace, preserveExportWhitespace: base.preserveExportWhitespace,
            preserveEditingSoftBreaks: base.preserveEditingSoftBreaks, preserveExportSoftBreaks: base.preserveExportSoftBreaks)
        // Шапку тела уже убрал `unit(for:)`; повторно её не ищем.
        let modelOptions = MarkdownDocumentModel.Options(syntax: syntax, includes: [], isVaultNote: false, detectsFrontMatter: false)
        output = []
        if let model = MarkdownDocumentParser.parse(text, options: modelOptions) {
            self.source = text as NSString
            footnoteDefinitions = [:]
            collectFootnoteDefinitions(model.blocks)
            visit(model.blocks)
            footnoteDefinitions = [:]
        } else {
            let lines = text.components(separatedBy: .newlines).map { PLine(text: plainLine($0), hard: true) }
                .filter { !$0.text.isEmpty }
            if !lines.isEmpty { output.append(.paragraph(lines)) }
        }
        let result = output
        output = []
        return result
    }

    private func collectFootnoteDefinitions(_ blocks: [MarkdownBlockNode]) {
        for block in blocks {
            if case .footnoteDefinition(let label) = block.kind { let key = MarkdownHTMLRenderer.footnoteKey(label)
                if !key.isEmpty, footnoteDefinitions[key] == nil { footnoteDefinitions[key] = block } }
            collectFootnoteDefinitions(block.children)
        }
    }

    private func visit(_ blocks: [MarkdownBlockNode]) {
        for block in blocks { visitBlock(block) }
    }

    private func visitBlock(_ node: MarkdownBlockNode) {
        switch node.kind {
        case .heading(let heading):
            let text = flat(node.inlines)
            if let scene = sceneLine(text) {
                output.append(.literal([scene]))
            } else if !text.isEmpty {
                output.append(.heading(level: heading.level, text: text))
            }
        case .paragraph:
            paragraph(node.inlines)
        case .thematicBreak:
            output.append(.literal(["==="]))
        case .quote:
            visit(node.children)
        case .callout, .alert:
            // Маркер выноски `[!тип]` в сценарий не попадает: остаётся заголовок и содержимое.
            if !node.inlines.isEmpty { paragraph(node.inlines) }
            visit(node.children)
        case .list:
            let lines = listLines(node, indent: "")
            if !lines.isEmpty { output.append(.action(lines)) }
        case .codeBlock(let code):
            codeBlock(code.literal)
        case .mathBlock(let source):
            mathBlock(source)
        case .html(let html):
            htmlBlock(html.literal)
        case .table(let table):
            counts[.table, default: 0] += 1
            let lines = tableLines(table)
            if !lines.isEmpty { output.append(.action(lines)) }
        case .footnoteDefinition, .tableOfContents, .frontMatter, .noteEmbed, .comment:
            break
        case .listItem:
            visit(node.children)
        }
    }

    private func paragraph(_ inlines: [MarkdownInlineNode]) {
        let lines = splitLines(finalize(inlineChildren(inlines)))
        if lines.count == 1, lines[0].text.lowercased() == "[toc]" { return }
        if !lines.isEmpty { output.append(.paragraph(lines)) }
    }

    private func mathBlock(_ literal: String) {
        counts[.formula, default: 0] += 1
        let lines = literal.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { plainLine($0) }
        output.append(.action(["$$"] + lines + ["$$"]))
    }

    private func codeBlock(_ literal: String) {
        counts[.codeBlock, default: 0] += 1
        var chunk: [String] = []
        func flush() {
            if !chunk.isEmpty { output.append(.action(chunk)) }
            chunk = []
        }
        for line in literal.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { chunk.append("    " + plainLine(line)) }
        }
        flush()
    }

    private func htmlBlock(_ literal: String) {
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        if MarkdownHTMLMediaService.pageBreakStyle(literal) != nil {
            output.append(.literal(["==="]))
            return
        }
        if trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"), trimmed.components(separatedBy: "-->").count == 2 {
            output.append(.literal([boneyard(String(trimmed.dropFirst(4).dropLast(3)))]))
            return
        }
        if let match = Self.centerExpression.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
            let text = htmlText((trimmed as NSString).substring(with: match.range(at: 1)))
            if !text.isEmpty { output.append(.literal(["> " + plainLine(text) + " <"])) }
            return
        }
        counts[.html, default: 0] += 1
        let text = htmlText(literal)
        if !text.isEmpty { output.append(.action([plainLine(text)])) }
    }

    private func htmlText(_ html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body(), let text = try? body.text() else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func boneyard(_ inner: String) -> String {
        let text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*/", with: "* /").replacingOccurrences(of: "/*", with: "/ *")
        return "/* " + text + " */"
    }

    private func listLines(_ list: MarkdownBlockNode, indent: String) -> [String] {
        var result: [String] = []
        var ordered = false
        var number = 1
        if case .list(let data) = list.kind, case .ordered(let start, _) = data.marker {
            ordered = true
            number = start
        }
        for current in list.children {
            var marker = ordered ? "\(number). " : "- "
            number += 1
            if case .listItem(let item) = current.kind, let task = item.task {
                marker += task.state != 32 ? "[x] " : "[ ] "
            }
            var texts: [String] = []
            var nested: [String] = []
            for content in current.children {
                switch content.kind {
                case .paragraph:
                    texts.append(flat(content.inlines))
                case .list:
                    nested += listLines(content, indent: indent + "  ")
                case .codeBlock(let code):
                    counts[.codeBlock, default: 0] += 1
                    texts.append(plainLine(code.literal.components(separatedBy: .newlines).joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)))
                default:
                    texts.append(plainLine(plain(content)))
                }
            }
            result.append(indent + marker + texts.filter { !$0.isEmpty }.joined(separator: " "))
            result += nested
        }
        return result
    }

    private func tableLines(_ table: MarkdownBlockNode.Table) -> [String] {
        var lines: [String] = []
        for row in table.rows {
            let cells = row.cells.map { flat($0.inlines) }
            let line = cells.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    // MARK: Строчная разметка

    /// Текст узлов одной строкой (переносы заменены пробелами).
    private func flat(_ nodes: [MarkdownInlineNode]) -> String {
        finalize(inlineChildren(nodes))
            .replacingOccurrences(of: String(Self.soft), with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
    }

    private func fixBrackets(_ text: String) -> String {
        var result = text
        while result.contains("[[") { result = result.replacingOccurrences(of: "[[", with: "[ [") }
        while result.contains("]]") { result = result.replacingOccurrences(of: "]]", with: "] ]") }
        return result
    }

    /// Текст без разметки Markdown: `*` и `_` экранируются, `[[` и `]]` разводятся.
    private func plainLine(_ text: String) -> String {
        fixBrackets(esc(text))
    }

    /// Вики-ссылки превращаются в псевдоним или цель, оставшиеся `[[` и `]]` разводятся.
    private func finalize(_ raw: String) -> String {
        let source = raw as NSString
        var result = ""
        var cursor = 0
        for match in Self.wikiExpression.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let alias = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
            result += alias.trimmingCharacters(in: .whitespaces).isEmpty
                ? source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                : alias.trimmingCharacters(in: .whitespaces)
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return fixBrackets(result)
    }

    private func splitLines(_ raw: String) -> [PLine] {
        var result: [PLine] = []
        var current = ""
        func close(hard: Bool) {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result.append(PLine(text: text, hard: hard))
            } else if hard, !result.isEmpty {
                result[result.count - 1].hard = true
            }
            current = ""
        }
        for character in raw {
            if character == Self.soft { close(hard: false) } else if character == "\n" { close(hard: true) } else { current.append(character) }
        }
        close(hard: false)
        return result
    }

    private func inlineChildren(_ nodes: [MarkdownInlineNode]) -> String {
        nodes.map { inline($0) }.joined()
    }

    private static let entityExpression = try! NSRegularExpression(pattern: "&(?:#[0-9]{1,8}|#[xX][0-9a-fA-F]{1,8}|[A-Za-z][A-Za-z0-9]*);")

    /// Сущности как у cmark: только `&имя;` и `&#…;`; `&not` или `&copy` без `;` остаются текстом.
    private func entities(in text: String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in Self.entityExpression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let entity = source.substring(with: match.range)
            if entity.hasPrefix("&#") {
                // Числовая сущность как у cmark: 0, суррогаты и значения выше U+10FFFF дают U+FFFD.
                let digits = entity.dropFirst(2).dropLast()
                let hex = digits.hasPrefix("x") || digits.hasPrefix("X")
                let value = UInt32(hex ? String(digits.dropFirst()) : String(digits), radix: hex ? 16 : 10)
                result += value.flatMap { Unicode.Scalar($0) }.flatMap { $0.value == 0 ? nil : String($0) } ?? "\u{FFFD}"
            } else {
                result += (try? Entities.unescape(string: entity, strict: true)) ?? entity
            }
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    /// Дети `==…==` и `^…^` хранят сырой кусок исходника (с `\_` и `&amp;`), в отличие от обычного текста cmark, который уже разобран:
    /// снимаем экранирование и сущности, чтобы `esc` не удвоил обратную косую.
    private func decoratedText(_ nodes: [MarkdownInlineNode]) -> String {
        nodes.map { node -> String in
            guard case .text(let raw) = node.kind else { return inline(node) }
            var result = ""
            var chunk = ""
            func flush() {
                guard !chunk.isEmpty else { return }
                result += entities(in: chunk)
                chunk = ""
            }
            var iterator = raw.makeIterator()
            while let character = iterator.next() {
                if character == "\\", let next = iterator.next() {
                    if next.isASCII, next.isPunctuation || next.isSymbol {
                        flush()
                        result += String(next)
                    } else {
                        chunk.append(character)
                        chunk.append(next)
                    }
                } else {
                    chunk.append(character)
                }
            }
            flush()
            return esc(result)
        }.joined()
    }

    /// Пара HTML-тегов (`<b>…</b>`, `<mark>…</mark>`): у узла в начале стоит `<`, а не маркер Markdown.
    private func isHTMLPair(_ node: MarkdownInlineNode) -> Bool {
        switch node.kind {
        case .underline, .keyboard, .inlineStyle: return true
        case .strong, .emphasis, .strikethrough, .subscriptText, .superscriptText, .highlight:
            return node.hasHTMLTagMarker(in: source)
        default: return false
        }
    }

    private func inline(_ node: MarkdownInlineNode) -> String {
        if isHTMLPair(node) {
            let inner = inlineChildren(node.children)
            if case .underline = node.kind { return "_" + inner + "_" }
            counts[.html, default: 0] += 1
            return inner
        }
        switch node.kind {
        case .formula(let formula):
            counts[.formula, default: 0] += 1
            return esc("$" + formula + "$")
        case .text(let value), .code(let value):
            return esc(value)
        case .softBreak:
            return String(Self.soft)
        case .hardBreak:
            return "\n"
        case .emphasis:
            return mark("*", inlineChildren(node.children))
        case .strong:
            return mark("**", inlineChildren(node.children))
        case .strikethrough, .subscriptText:
            counts[.strikethrough, default: 0] += 1
            return inlineChildren(node.children)
        case .highlight:
            return "==" + decoratedText(node.children) + "=="
        case .superscriptText:
            return "^" + decoratedText(node.children) + "^"
        case .link(let link):
            let inner = inlineChildren(node.children)
            if link.form == .html {
                counts[.html, default: 0] += 1
                return inner
            }
            let address = link.url
            if address.isEmpty || isServiceAddress(address) || plain(node) == address { return inner }
            return inner + " (" + esc(address) + ")"
        case .image(let image):
            counts[.image, default: 0] += 1
            return note(imageNote(alt: image.alt, address: image.url))
        case .rawHTML(let tag):
            return inlineHTML(tag)
        case .media, .iframe, .svg:
            counts[.html, default: 0] += 1
            return ""
        case .ruby(let ruby):
            counts[.html, default: 0] += 1
            return esc(ruby.base + ruby.reading)
        case .footnoteReference(let label):
            counts[.footnote, default: 0] += 1
            guard let definition = footnoteDefinitions[MarkdownHTMLRenderer.footnoteKey(label)] else { return "" }
            return note(plain(definition))
        default:
            return inlineChildren(node.children)
        }
    }

    /// Пробелы по краям выносятся за маркеры: `* текст *` в Fountain не курсив.
    private func mark(_ marker: String, _ inner: String) -> String {
        let core = inner.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return inner }
        let lead = String(inner.prefix(while: { $0 == " " || $0 == "\t" }))
        let trail = String(inner.reversed().prefix(while: { $0 == " " || $0 == "\t" }))
        return lead + marker + core + marker + trail
    }

    private func isServiceAddress(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.hasPrefix("data:") || lower.hasPrefix("javascript:") || address.contains("#lac-media-")
    }

    private func imageNote(alt: String, address: String) -> String {
        let label = alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.tr("图片") : alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty || isServiceAddress(address) ? label : "\(label) (\(address))"
    }

    private func inlineHTML(_ tag: String) -> String {
        let lower = tag.lowercased().replacingOccurrences(of: " ", with: "")
        if lower == "<u>" || lower == "</u>" { return "_" }
        if lower == "<br>" || lower == "<br/>" { return "\n" }
        if lower.hasPrefix("<!--") {
            let inner = lower.hasSuffix("-->") ? String(tag.dropFirst(4).dropLast(3)) : String(tag.dropFirst(4))
            return boneyard(inner)
        }
        if lower.hasPrefix("<img") {
            counts[.image, default: 0] += 1
            let element = (try? SwiftSoup.parseBodyFragment(tag))?.body()?.children().first()
            let alt = (try? element?.attr("alt")) ?? ""
            let address = (try? element?.attr("src")) ?? ""
            return note(imageNote(alt: alt, address: address))
        }
        if !lower.hasPrefix("</") { counts[.html, default: 0] += 1 }
        return ""
    }

    /// Текст без разметки; блоки разделяются пробелом.
    private func plain(_ node: MarkdownInlineNode) -> String {
        plainText(of: node.children)
    }

    private func plain(_ block: MarkdownBlockNode) -> String {
        var result = ""
        func addSpace() { if !result.isEmpty, !result.hasSuffix(" ") { result += " " } }
        func walk(_ current: MarkdownBlockNode) {
            switch current.kind {
            case .paragraph, .heading:
                addSpace()
            case .codeBlock(let code):
                result += code.literal
            case .mathBlock(let source):
                result += source
            case .table(let table):
                for row in table.rows { for cell in row.cells { result += plainText(of: cell.inlines) } }
            default:
                break
            }
            result += plainText(of: current.inlines)
            for child in current.children { walk(child) }
        }
        walk(block)
        return result.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func plainText(of nodes: [MarkdownInlineNode]) -> String {
        var result = ""
        for node in nodes {
            switch node.kind {
            case .text(let value), .code(let value): result += value
            case .softBreak, .hardBreak: result += " "
            case .image(let image): result += image.alt
            default: break
            }
            result += plainText(of: node.children)
        }
        return result
    }

    // MARK: Сценарные строки

    /// Заголовок сцены: родной (`INT.`), принудительный (`.`) или русский/китайский (получает `.`). nil — не сцена.
    private func sceneLine(_ text: String) -> String? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        // Ведущая «.» принимается как принудительная сцена, только если дальше распознанный префикс сцены (`.INT. …`);
        // иначе («.NET is great», «# .NET Tips») это проза и строка идёт в защиту `!`.
        if text.hasPrefix("."), !text.hasPrefix("..") {
            let rest = String(text.dropFirst())
            let restRange = NSRange(location: 0, length: (rest as NSString).length)
            let known = Self.nativeScene.firstMatch(in: rest, range: restRange) != nil
                || Self.russianScene.firstMatch(in: rest, range: restRange) != nil
                || Self.chineseScene.firstMatch(in: rest, range: restRange) != nil
            return known ? text : nil
        }
        if Self.nativeScene.firstMatch(in: text, range: range) != nil { return text }
        if Self.russianScene.firstMatch(in: text, range: range) != nil || Self.chineseScene.firstMatch(in: text, range: range) != nil {
            return "." + text
        }
        return nil
    }

    private func transitionLine(_ text: String) -> String? {
        if FountainLint.isUppercase(text), text.hasSuffix("TO:") { return text }
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "。"))
        if Self.fixedTransitions.contains(text) || Self.fixedTransitions.contains(stripped) { return "> " + text }
        if FountainLint.isUppercase(text), text == "В:" || text.hasSuffix(" В:") { return "> " + text }
        return nil
    }

    /// Реплика `ИМЯ: текст`. Имя заглавными (любое письмо с регистром) или короткое имя без регистра после `：`.
    private func speech(_ line: String) -> Speech? {
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let isFullWidth = line[colon] == "："
        let prefix = line[..<colon].trimmingCharacters(in: .whitespaces)
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty, prefix.count <= 40, !text.hasPrefix("//") else { return nil }
        var base = prefix
        var parenthetical: String?
        if prefix.hasSuffix(")"), let open = prefix.lastIndex(of: "(") {
            parenthetical = String(prefix[prefix.index(after: open)..<prefix.index(before: prefix.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            base = String(prefix[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !base.isEmpty, base.allSatisfy({ $0.isLetter || " .-'’·・".contains($0) }) else { return nil }
        var name: String
        let cased: Bool
        if FountainLint.isUppercase(base), base.unicodeScalars.contains(where: { $0.properties.isUppercase }) {
            cased = true
            name = base
        } else if base.unicodeScalars.allSatisfy({ !$0.properties.isUppercase && !$0.properties.isLowercase }) {
            // Имя без регистра: только полноширинное двоеточие, 1–8 символов, без пробелов.
            guard isFullWidth, base.count <= 8, !base.contains(" ") else { return nil }
            cased = false
            name = "@" + base
        } else {
            return nil
        }
        if let extra = parenthetical, !extra.isEmpty {
            if FountainLint.isUppercase(extra) {
                name += " (" + extra + ")"
                parenthetical = nil
            }
        } else {
            parenthetical = nil
        }
        return Speech(name: name, base: base, cased: cased, parenthetical: parenthetical, text: text)
    }

    /// Имена без регистра, встретившиеся в экспорте не менее двух раз.
    private func chineseNames(_ units: [Unit]) -> Set<String> {
        var counts: [String: Int] = [:]
        for unit in units {
            for case let .paragraph(lines) in unit.pieces {
                for line in lines {
                    if sceneLine(line.text) != nil || transitionLine(line.text) != nil { continue }
                    if let found = speech(line.text), !found.cased { counts[found.base, default: 0] += 1 }
                }
            }
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    private func paragraph(_ lines: [PLine], chinese: Set<String>) -> [Block] {
        var blocks: [Block] = []
        var action: [PLine] = []
        var dialogue: [String]?
        func flush() {
            if !action.isEmpty { blocks.append(Block(lines: joinAction(action), protect: true)) }
            action = []
            if let dialogue { blocks.append(Block(lines: dialogue, protect: false)) }
            dialogue = nil
        }
        for line in lines {
            if let scene = sceneLine(line.text) {
                flush()
                blocks.append(Block(lines: [scene], protect: false))
            } else if let transition = transitionLine(line.text) {
                flush()
                blocks.append(Block(lines: [transition], protect: false))
            } else if let found = speech(line.text), found.cased || chinese.contains(found.base) {
                flush()
                var block = [found.name]
                if let extra = found.parenthetical { block.append("(" + extra + ")") }
                if !found.text.isEmpty { block.append(found.text) }
                dialogue = block
            } else if dialogue != nil {
                dialogue?.append(line.text)
            } else {
                action.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Мягкие переносы склеиваются пробелом (без пробела на стыке иероглифов), жёсткие остаются строками.
    private func joinAction(_ lines: [PLine]) -> [String] {
        var text = ""
        for (index, line) in lines.enumerated() {
            text += line.text
            guard index < lines.count - 1 else { break }
            if line.hard {
                text += "\n"
            } else if !(Self.isCJK(line.text.last) && Self.isCJK(lines[index + 1].text.first)) {
                text += " "
            }
        }
        return text.components(separatedBy: "\n")
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let value = character?.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0xFF00...0xFFEF).contains(value)
    }
}

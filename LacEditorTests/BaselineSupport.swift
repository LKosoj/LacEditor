import Foundation
import XCTest
@testable import LacEditor

/// Общие средства эталонов этапа 0 (U0.1, U0.2): корпус, наборы настроек, нормализация, запись и сравнение файлов.
enum BaselinePaths {
    /// Каталог исходников тестов. Ссылку стенда разворачиваем, чтобы читать и писать настоящие файлы проекта.
    static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
    }
    static var projectRoot: URL { testsDirectory.deletingLastPathComponent() }
    static let documentURL = URL(fileURLWithPath: "/lac-baseline/doc.md")
}

struct BaselineItem {
    /// Идентификатор записи, например `spec/0123`, `doc/Corpus/critic`.
    let id: String
    let section: String
    let text: String
}

enum BaselineCorpus {
    static func spec() throws -> [BaselineItem] {
        try GFMSpecReader.spec().map { BaselineItem(id: "spec/" + number($0.number), section: $0.section, text: $0.markdown) }
    }

    static func extensions() throws -> [BaselineItem] {
        try GFMSpecReader.extensions().map { BaselineItem(id: "ext/" + number($0.number), section: $0.section, text: $0.markdown) }
    }

    /// Документы: `Fixtures/MarkdownBaseline`, `Verification/Fixtures`, `Fixtures/RenderBaseline/Corpus`; по алфавиту.
    static func documents() throws -> [BaselineItem] {
        let tests = BaselinePaths.testsDirectory
        let folders: [(String, URL)] = [
            ("MarkdownBaseline", tests.appendingPathComponent("Fixtures/MarkdownBaseline", isDirectory: true)),
            ("Verification", BaselinePaths.projectRoot.appendingPathComponent("Verification/Fixtures", isDirectory: true)),
            ("Corpus", tests.appendingPathComponent("Fixtures/RenderBaseline/Corpus", isDirectory: true)),
        ]
        var items: [BaselineItem] = []
        for (label, folder) in folders {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".md") }.sorted()
            for name in names {
                let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                items.append(BaselineItem(id: "doc/\(label)/\(name.dropLast(3))", section: "", text: lf(text)))
            }
        }
        return items
    }

    /// Те же документы с `\r\n`; `\r\n` добавляет загрузчик, чтобы git не менял данные.
    static func crlfDocuments() throws -> [BaselineItem] {
        try documents().map { BaselineItem(id: $0.id + "[crlf]", section: "", text: crlf($0.text)) }
    }

    private static func number(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    /// По `unicodeScalars`: `"\r\n"` в Swift один `Character`, и `components` на Linux его не делит.
    static func lf(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" { out.append("\n"); previousCR = true; continue }
            if scalar == "\n" && previousCR { previousCR = false; continue }
            previousCR = false
            out.append(scalar)
        }
        return String(out)
    }

    static func crlf(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in lf(text).unicodeScalars {
            if scalar == "\n" { out.append("\r") }
            out.append(scalar)
        }
        return String(out)
    }
}

/// Замена случайных частей (UUID в маркерах и якорях) на номера по порядку появления в одной записи.
struct BaselineMarkers {
    private var numbers: [String: Int] = [:]
    private var counters: [String: Int] = [:]
    private static let expression = try! NSRegularExpression(
        pattern: "(LACREMOTE|LACBLOCKMEDIA|LACLOCALMEDIA|LACRAW|LACSTYLE|LACTEXT|LACCOPYMEDIA)([0-9A-F]{32})|lac-anchor-[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}")

    mutating func apply(_ text: String) -> String {
        let source = text as NSString
        var result = ""
        var last = 0
        for match in Self.expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let key = source.substring(with: match.range)
            let prefix = match.range(at: 1).location == NSNotFound ? "lac-anchor-U" : source.substring(with: match.range(at: 1))
            if numbers[key] == nil {
                numbers[key] = counters[prefix, default: 0]
                counters[prefix, default: 0] += 1
            }
            result += prefix == "lac-anchor-U" ? "lac-anchor-U\(numbers[key]!)" : "\(prefix)#\(numbers[key]!)"
            last = NSMaxRange(match.range)
        }
        return result + source.substring(from: last)
    }

    /// Номер уже встретившегося маркера; ключи словарей без маркера в теле получают номера позже.
    func isKnown(_ text: String) -> Bool {
        let source = text as NSString
        guard let match = Self.expression.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return true }
        return numbers[source.substring(with: match.range)] != nil
    }
}

enum BaselineText {
    /// Строка в кавычках; управляющие и невидимые символы записываются кодом, чтобы они были видны в diff.
    static func quoted(_ text: String) -> String { "\"" + escaped(text, keepNewlines: false) + "\"" }

    static func escaped(_ text: String, keepNewlines: Bool) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"" where !keepNewlines: out += "\\\""
            case "\\" where !keepNewlines: out += "\\\\"
            case "\n": out += keepNewlines ? "\n" : "\\n"
            case "\r": out += "\\r"
            case "\t": out += keepNewlines ? "\t" : "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029
                    || scalar.value == 0xA0 || scalar.value == 0x200B {
                    out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Тело HTML построчно: строка, начинающаяся с `=` или `\`, получает префикс `\`, чтобы заголовок записи оставался однозначным.
    static func body(_ text: String) -> String {
        var out = ""
        var line = ""
        var atLineStart = true
        func flush() {
            // Пробелы в конце строки пишутся кодом: файл эталона остаётся без хвостовых пробелов.
            var trailing = 0
            while line.unicodeScalars.last == " " { line.unicodeScalars.removeLast(); trailing += 1 }
            out += line + String(repeating: "\\u{20}", count: trailing) + "\n"
            line = ""
        }
        for scalar in text.unicodeScalars {
            if scalar == "\n" { flush(); atLineStart = true; continue }
            if atLineStart && (scalar == "=" || scalar == "\\") { line += "\\" }
            atLineStart = false
            line += escaped(String(scalar), keepNewlines: true)
        }
        if !atLineStart { flush() }
        return out
    }

    /// Сравнение строк с цифрами как числа: `#2` раньше `#10`.
    static func naturalLess(_ a: String, _ b: String) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        var i = 0, j = 0
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        while i < x.count && j < y.count {
            if isDigit(x[i]) && isDigit(y[j]) {
                var p = i, q = j
                while p < x.count && isDigit(x[p]) { p += 1 }
                while q < y.count && isDigit(y[q]) { q += 1 }
                let n = Int(String(String.UnicodeScalarView(x[i..<p]))) ?? 0, m = Int(String(String.UnicodeScalarView(y[j..<q]))) ?? 0
                if n != m { return n < m }
                i = p; j = q
            } else {
                if x[i] != y[j] { return x[i].value < y[j].value }
                i += 1; j += 1
            }
        }
        return x.count - i < y.count - j
    }
}

/// Файлы эталонов: запись по `LAC_RECORD_BASELINE=1`, иначе точное сравнение.
enum BaselineStore {
    static var isRecording: Bool { ProcessInfo.processInfo.environment["LAC_RECORD_BASELINE"] == "1" }

    static func url(_ directory: String, _ file: String) -> URL {
        return BaselinePaths.testsDirectory.appendingPathComponent("Fixtures/\(directory)/\(file)")
    }

    static func check(_ content: String, directory: String, file: String, line: UInt = #line) {
        let target = url(directory, file)
        if isRecording {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, atomically: true, encoding: .utf8)
            } catch { XCTFail("Не удалось записать эталон \(file): \(error)", line: line) }
            return
        }
        guard let expected = try? String(contentsOf: target, encoding: .utf8) else {
            XCTFail("Нет эталона \(directory)/\(file): запустите тест с LAC_RECORD_BASELINE=1", line: line)
            return
        }
        // Побайтно: сравнение String в Swift считает канонически равные последовательности одинаковыми.
        if expected.utf8.elementsEqual(content.utf8) { return }
        XCTFail("Эталон \(directory)/\(file) не совпал.\n" + difference(expected, content), line: line)
    }

    /// Первые 20 записей с отличиями и первая различающаяся строка.
    static func difference(_ expected: String, _ actual: String) -> String {
        let a = records(expected), b = records(actual)
        var changed: [String] = []
        for (id, text) in b where a[id] != text { changed.append(id) }
        for id in a.keys where b[id] == nil { changed.append(id + " (нет в результате)") }
        changed.sort()
        var report = "Отличаются записей: \(changed.count): " + changed.prefix(20).joined(separator: "; ") + "\n"
        if let id = changed.first.map({ $0.replacingOccurrences(of: " (нет в результате)", with: "") }) {
            let x = (a[id] ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            let y = (b[id] ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            for index in 0..<max(x.count, y.count) {
                let left = index < x.count ? x[index] : "<конец>", right = index < y.count ? y[index] : "<конец>"
                if left != right {
                    report += "Первая запись \(id), строка \(index + 1):\n  эталон:   \(String(left.prefix(300)))\n  результат: \(String(right.prefix(300)))"
                    break
                }
            }
        }
        return report
    }

    private static func records(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var id: String?
        var lines: [Substring] = []
        func flush() { if let id { result[id] = lines.joined(separator: "\n") } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("=== ") { flush(); id = String(line.dropFirst(4)); lines = [] } else { lines.append(line) }
        }
        flush()
        return result
    }
}

/// Провайдер встраиваний без диска: имя заметки → текст.
final class BaselineEmbedProvider: MarkdownNoteEmbedProvider, @unchecked Sendable {
    private let notes: [String: String] = [
        "note-a": "# Заметка A\n\n- первый\n- второй\n\nТекст [[x]] с **жирным**.\n",
        "Корпус": "Корпус: кириллица, 中文, 😀.\n",
        "deep": "Глубокая заметка\n\n![[note-a]]\n",
    ]
    func embeddedNote(for target: String) -> String? { notes[target] }
    func openAddress(for target: String, heading: String?) -> String? { nil }
}

/// Семь наборов настроек `renderPage`: как вызывают предпросмотр, экспорт и писательский режим.
enum BaselineSet: String, CaseIterable {
    case preview
    case previewVault = "preview-vault"
    case previewNoBreaks = "preview-nobreaks"
    case exportPDF = "export-pdf"
    case exportHTML = "export-html"
    case exportNoBreaks = "export-nobreaks"
    case writer

    var name: String { rawValue }
    /// Примеры spec и расширений идут только в наборы без возможностей, которых в spec почти нет.
    var includesSpec: Bool { self == .preview || self == .previewVault || self == .previewNoBreaks || self == .exportPDF }
    /// Темная тема нужна только встраиваниям: `embed.finalize` принимает `darkMode`.
    var hasDarkEmbeds: Bool { self == .previewVault || self == .exportNoBreaks }

    private static let wiki = MarkdownWikiLinkContext(
        resolver: MarkdownWikiLinkResolver(base: URL(fileURLWithPath: "/lac-baseline", isDirectory: true),
                                           paths: ["a.md", "sub/c.md", "x.md", "sub/x.md", "Корпус.md", "note-a.md"]),
        documentURL: BaselinePaths.documentURL)
    private static let embeds = BaselineEmbedProvider()

    func render(_ markdown: String, dark: Bool = false) -> MarkdownRenderedPage {
        let url = BaselinePaths.documentURL
        switch self {
        case .preview:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true,
                isPreview: true, highlightCode: true)
        case .previewVault:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true,
                isPreview: true, highlightCode: true, wiki: Self.wiki, critic: .show, embeds: Self.embeds, hidesObsidianComments: true)
        case .previewNoBreaks:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true,
                syntax: .init(strictMode: false, smartPunctuation: false, preserveEditingWhitespace: true, preserveEditingSoftBreaks: false),
                includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true, isPreview: true, highlightCode: true)
        case .exportPDF:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, forExport: true, includeHeadingNumbers: true, includeListStyles: true,
                staticWidgetFallback: true, highlightCode: true, wiki: Self.wiki, embeds: Self.embeds)
        case .exportHTML:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, includeHTMLMedia: true, renderEmoji: true, resolveLocalImages: false,
                documentURL: url, prepareRemoteImages: false, forExport: true, includeHeadingNumbers: true, includeListStyles: true,
                staticWidgetFallback: false, preserveRawHTMLBlocks: true, highlightCode: false, wiki: Self.wiki, critic: .result, embeds: Self.embeds)
        case .exportNoBreaks:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, syntax: .init(preserveExportWhitespace: true, preserveExportSoftBreaks: false), forExport: true,
                includeHeadingNumbers: true, includeListStyles: true, staticWidgetFallback: true, highlightCode: true,
                wiki: Self.wiki, critic: .original, embeds: Self.embeds)
        case .writer:
            return MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, highlightCode: true)
        }
    }

    /// Запись эталона: настройки, нормализованные маркеры, затем тело.
    func record(_ item: BaselineItem, dark: Bool = false) -> String {
        let page = render(item.text, dark: dark)
        var markers = BaselineMarkers()
        let body = markers.apply(page.body)
        var out = "=== \(item.id)\(dark ? "[dark]" : "")" + (item.section.isEmpty ? "" : " | \(item.section)") + "\n"
        out += "[flags] omitted=\(page.omittedHTML) whitespace=\(page.preserveWhitespace) rawFailed=\(page.rawHTMLBlockProofFailed)\n"
        if !page.headingIDs.isEmpty { out += "[headingIDs] " + page.headingIDs.sorted().map(BaselineText.quoted).joined(separator: ", ") + "\n" }
        if !page.listDepths.isEmpty { out += "[listDepths] " + page.listDepths.sorted().map(String.init).joined(separator: ", ") + "\n" }
        for formula in page.formulas { out += "[formula] display=\(formula.display) source=\(BaselineText.quoted(formula.source))\n" }
        for diagram in page.diagrams { out += "[diagram] kind=\(diagram.kind.rawValue) source=\(BaselineText.quoted(diagram.source))\n" }
        func sortedEntries<V>(_ dictionary: [String: V], _ text: (V) -> String) -> [(key: String, value: V)] {
            // Ключи с маркером из тела получают номера по телу; остальные — по значению, при равных значениях — по порядку
            // первого появления в сырых HTML-блоках (иначе порядок зависел бы от UUID).
            let unknown = dictionary.filter { !markers.isKnown($0.key) }
            let rawText = page.rawHTMLBlocks.map { $0.marker + $0.html }.joined(separator: "\n")
            func firstPosition(_ key: String) -> Int {
                rawText.range(of: key).map { rawText.distance(from: rawText.startIndex, to: $0.lowerBound) } ?? Int.max
            }
            for entry in unknown.sorted(by: {
                let (left, right) = (text($0.value), text($1.value))
                return left != right ? left < right : firstPosition($0.key) < firstPosition($1.key)
            }) { _ = markers.apply(entry.key) }
            return dictionary.map { (key: markers.apply($0.key), value: $0.value) }.sorted { BaselineText.naturalLess($0.key, $1.key) }
        }
        for entry in sortedEntries(page.remoteImageMarkers, { $0 }) { out += "[remote] \(entry.key) -> \(BaselineText.quoted(entry.value))\n" }
        for entry in sortedEntries(page.localMediaMarkers, { $0.url.path }) {
            out += "[local] \(entry.key) -> \(BaselineText.quoted(Self.stripPaths(entry.value.url.path))) fragment=\(BaselineText.quoted(entry.value.fragment))\n"
        }
        for block in page.rawHTMLBlocks { out += "[raw] \(markers.apply(block.marker)) -> \(BaselineText.quoted(markers.apply(block.html)))\n" }
        out += "--- body\n" + BaselineText.body(Self.stripPaths(body))
        return out
    }

    /// Реальные пути машины в эталон не попадают.
    static func stripPaths(_ text: String) -> String {
        text.replacingOccurrences(of: BaselinePaths.projectRoot.path, with: "$ROOT")
            .replacingOccurrences(of: NSTemporaryDirectory(), with: "$TMP/")
    }
}

/// Запись `Mirror` в текст для эталонов оформления: детерминированно (порядок Set и Dictionary — по тексту ключей).
final class BaselineDump {
    private(set) var problems: [String] = []
    /// Преобразование `NSRange` перед записью (сравнение моделей LF и CRLF со сдвигом); `nil` — как есть.
    var mapRange: ((NSRange) -> NSRange)?

    func line(_ value: Any, indent: Int = 0) -> String {
        let flat = inline(value)
        if flat.count <= 110 { return flat }
        return multiline(value, indent: indent) ?? flat
    }

    func inline(_ value: Any) -> String {
        if let range = value as? NSRange {
            let mapped = mapRange?(range) ?? range
            return "\(mapped.location)+\(mapped.length)"
        }
        if let text = value as? String { return BaselineText.quoted(text) }
        if let text = value as? Substring { return BaselineText.quoted(String(text)) }
        if let character = value as? Character { return BaselineText.quoted(String(character)) }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let integer = value as? any BinaryInteger { return "\(integer)" }
        if let number = value as? Double { return String(format: "%.6g", number) }
        if let number = value as? Float { return String(format: "%.6g", Double(number)) }
        if let url = value as? URL { return BaselineText.quoted(url.absoluteString) }
        if value is Date || value is UUID {
            problems.append("неподдерживаемый тип \(type(of: value))")
            return "<\(type(of: value))>"
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            return mirror.children.first.map { inline($0.value) } ?? "nil"
        case .enum:
            guard let payload = mirror.children.first else { return "\(value)" }
            let inner = Mirror(reflecting: payload.value).displayStyle == .tuple ? inline(payload.value) : "(" + inline(payload.value) + ")"
            return (payload.label ?? "\(value)") + inner
        case .tuple:
            return "(" + mirror.children.map { child in (child.label.map { $0.hasPrefix(".") ? "" : $0 + ":" } ?? "") + inline(child.value) }.joined(separator: ", ") + ")"
        case .set:
            return "{" + mirror.children.map { inline($0.value) }.sorted().joined(separator: ", ") + "}"
        case .dictionary:
            return "[" + dictionaryEntries(mirror).map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "]"
        default:
            break
        }
        if let items = elements(of: value) { return "[" + items.map(inline).joined(separator: ", ") + "]" }
        if mirror.displayStyle == .struct || mirror.displayStyle == .class {
            return "{" + mirror.children.map { ($0.label ?? "_") + "=" + inline($0.value) }.joined(separator: " ") + "}"
        }
        return "\(value)"
    }

    /// Длинное значение разворачивается построчно с отступом в 2 пробела.
    private func multiline(_ value: Any, indent: Int) -> String? {
        let mirror = Mirror(reflecting: value)
        let pad = String(repeating: " ", count: indent + 2)
        if mirror.displayStyle == .optional, let wrapped = mirror.children.first { return multiline(wrapped.value, indent: indent) ?? inline(wrapped.value) }
        if mirror.displayStyle == .dictionary {
            let entries = dictionaryEntries(mirror)
            return "\n" + entries.map { pad + Self.joined("\($0.0): ", $0.1) }.joined(separator: "\n")
        }
        if mirror.displayStyle == .set { return "\n" + mirror.children.map { pad + line($0.value, indent: indent + 2) }.sorted().joined(separator: "\n") }
        if let items = elements(of: value) {
            return "\n" + items.enumerated().map { pad + Self.joined("[\($0.offset)] ", line($0.element, indent: indent + 2)) }.joined(separator: "\n")
        }
        if mirror.displayStyle == .struct || mirror.displayStyle == .class {
            return "\n" + mirror.children.map { pad + Self.joined(($0.label ?? "_") + ": ", line($0.value, indent: indent + 2)) }.joined(separator: "\n")
        }
        return nil
    }

    /// Развёрнутое значение начинается с перевода строки: пробел в конце заголовка строки убирается.
    static func joined(_ head: String, _ value: String) -> String {
        value.hasPrefix("\n") ? String(head.dropLast()) + value : head + value
    }

    private func dictionaryEntries(_ mirror: Mirror) -> [(String, String)] {
        mirror.children.map { child -> (String, String) in
            let pair = Array(Mirror(reflecting: child.value).children)
            return (inline(pair[0].value), inline(pair[1].value))
        }.sorted { $0.0 < $1.0 }
    }

    /// Любая коллекция (не String): элементы идут как строки, а не внутренние поля вроде `base/baseShift`.
    private func elements(of value: Any) -> [Any]? {
        guard let collection = value as? any Collection else { return nil }
        return Self.items(collection)
    }

    private static func items<C: Collection>(_ collection: C) -> [Any] { collection.map { $0 } }
}

/// Наборы разбора оформления (U0.2).
enum PresentationBaselineSet: String, CaseIterable {
    case editor
    case editorLoose = "editor-loose"
    case editorNumbered = "editor-numbered"
    case editorMinimal = "editor-minimal"

    var name: String { rawValue }
    var includesSpec: Bool { self == .editor || self == .editorLoose }

    /// Поля, которые пишутся в эталон, в порядке записи.
    static let writtenFields = [
        "spans", "headings", "namedAnchors", "images", "diagrams", "audioBlocks", "iframeBlocks", "detailsBlocks", "htmlBlocks",
        "pageBreaks", "ruby", "links", "formulas", "inlineFormulas", "emojiCandidates", "emojiCandidatesIncluded", "emojiCompletionRanges",
        "smartTextRanges", "smartRawHTMLRanges", "textReplacements", "paragraphs", "completedTaskRanges", "taskCheckboxes", "listMarkers",
        "looseIndents", "footnotes", "tableOfContents", "tables", "codeBlocks", "fenceContainerLines", "fenceBlockedRanges",
        "fenceBlockedEOF", "fenceContextAvailable", "readableText", "wikiLinks", "unreliableRanges", "elements",
    ]
    /// Состояние для `shift`, а не результат разбора.
    static let excludedFields = ["spanEnds", "completedEnds", "isReadyForShift", "isTextStructureOnly"]

    /// Разбор через ядро и адаптер (U5.2): те же флаги, что у разбора редактора.
    func parse(_ text: String) -> MarkdownPresentation {
        let full: MarkdownDocumentModel.Includes = [.wikiLinks, .emoji, .uppercaseRuns, .readableText]
        let looseSyntax = MarkdownSyntaxOptions(strictMode: false, legacyInlineMath: true, smartPunctuation: false)
        switch self {
        case .editor: return Self.build(text, includes: full, syntax: MarkdownSyntaxOptions())
        case .editorLoose: return Self.build(text, includes: full, syntax: looseSyntax)
        case .editorNumbered: return Self.build(text, includes: full, syntax: MarkdownSyntaxOptions()).numberingHeadings(true)
        case .editorMinimal: return Self.build(text, includes: [], syntax: MarkdownSyntaxOptions())
        }
    }

    private static func build(_ text: String, includes: MarkdownDocumentModel.Includes, syntax: MarkdownSyntaxOptions) -> MarkdownPresentation {
        guard !text.utf8.contains(0) else { return MarkdownPresentation(spans: []) }
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: includes.union([.elementIndex, .editorContext]), isVaultNote: false, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(text, options: options) else { return MarkdownPresentation(spans: []) }
        let build = MarkdownPresentationBuilder.BuildOptions(includeReadableText: includes.contains(.readableText), includeEmojiCandidates: includes.contains(.emoji),
                                                             includeWikiLinks: includes.contains(.wikiLinks), syntax: syntax)
        return MarkdownPresentationBuilder.build(model, text: text as NSString, options: build)
    }

    /// Запись: заголовок, затем поля списка; пустое поле пишется как `[]`, чтобы пропажа поля была видна.
    func record(_ item: BaselineItem, dump: BaselineDump) -> String {
        let presentation = parse(item.text)
        let children = Dictionary(uniqueKeysWithValues: Mirror(reflecting: presentation).children.compactMap { child in child.label.map { ($0, child.value) } })
        var out = "=== \(item.id)" + (item.section.isEmpty ? "" : " | \(item.section)") + "\n"
        for field in Self.writtenFields {
            guard let value = children[field] else { continue }
            out += BaselineDump.joined("\(field): ", dump.line(value)) + "\n"
        }
        return out
    }
}

import AppKit
import XCTest
@testable import LacEditor

/// Эталонные документы этапа 0 (D1-D6) для baseline на Mac и для стресс-тестов скрытия глифов.
/// Fixture лежат с `\n`; `\r\n` добавляет загрузчик, чтобы `core.autocrlf` не менял данные.
enum MarkdownBaselineDocuments {
    enum Document: String, CaseIterable {
        case note, noteMedia, longText, tables, dataURI, over20MiB

        /// Имя файла при экспорте на диск: D1.md ... D6.md.
        var exportName: String { "D\(Self.allCases.firstIndex(of: self)! + 1).md" }
    }

    /// Рабочий PNG 1x1 (69 байт), как в соседних тестах изображений.
    static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    static func fixture(_ name: String) throws -> String {
        #if SWIFT_PACKAGE
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures/MarkdownBaseline"))
        #else
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MarkdownBaseline/\(name).md")
        #endif
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// CRC32 таблицей (без zlib: через SwiftPM его наличие на Mac не гарантировано).
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Рабочий PNG нужного размера: перед IEND вставляется вспомогательный чанк `laCe` с заполнителем (CRC считается честно).
    /// Размер меньше или равен размеру исходного PNG возвращает исходный PNG; промежуточные значения (меньше размера + 12) недопустимы.
    static func png(paddedTo size: Int) -> Data {
        let tiny = Data(base64Encoded: tinyPNGBase64)!
        if size <= tiny.count { return tiny }
        precondition(size >= tiny.count + 12, "чанк занимает минимум 12 байт")
        let body = tiny.prefix(tiny.count - 12)
        let iend = tiny.suffix(12)
        let fillerCount = size - tiny.count - 12
        let filler = [UInt8](unsafeUninitializedCapacity: fillerCount) { buffer, count in
            for index in 0..<fillerCount { buffer[index] = UInt8(index & 0xFF) }
            count = fillerCount
        }
        let typeAndData = Array("laCe".utf8) + filler
        var result = Data(capacity: size)
        result.append(body)
        result.append(contentsOf: bigEndian(UInt32(filler.count)))
        result.append(contentsOf: typeAndData)
        result.append(contentsOf: bigEndian(crc32(typeAndData)))
        result.append(iend)
        return result
    }

    static func note() throws -> String { crlf(try fixture("note")) }

    static func noteMedia() throws -> String { crlf(try fixture("note") + (try fixture("note-media"))) }

    static func longText() throws -> String {
        let chapter = try fixture("long-chapter")
        var text = ""
        text.reserveCapacity(chapter.utf8.count * 100 + 1_000)
        for number in 1...100 { text += chapter.replacingOccurrences(of: "{N}", with: String(number)) + "\n" }
        return crlf(text)
    }

    private static func tableText(columns: Int, rows: Int, formula: Bool = false) -> String {
        var text = "| " + (0..<columns).map { "Колонка \($0)" }.joined(separator: " | ") + " |\n"
        text += "|" + (0..<columns).map { [":--", ":-:", "--:"][$0 % 3] }.joined(separator: "|") + "|\n"
        for row in 0..<rows {
            let cells = (0..<columns).map { column in
                formula && column == 0 ? "$x_{\(row)}$" : "Ячейка \(row)-\(column) 中\(row) **b**"
            }
            text += "| " + cells.joined(separator: " | ") + " |\n"
        }
        return text + "\n"
    }

    static func tables() throws -> String {
        var text = try fixture("tables") + "\n"
        text += tableText(columns: 12, rows: 200)
        text += tableText(columns: 5, rows: 3_000)
        text += tableText(columns: 30, rows: 50)
        text += tableText(columns: 4, rows: 100, formula: true)
        return crlf(text)
    }

    /// Документ с data URI: каждому размеру из `payloadBytes` (до base64) соответствует свой блок разной формы.
    static func makeDataURIDocument(payloadBytes: [Int]) throws -> String {
        let forms: [(String) -> String] = [
            { "Абзац 中文 с картинкой ![a](\($0)) внутри строки.\n\n" },
            { "![b](\($0))\n\n" },
            { "- [ ] ![c](\($0))\n\n" },
            { "| картинка | текст |\n|---|---|\n| ![d](\($0)) | 中文 |\n\n" },
            { "<img src='\($0)' width='50%'>\n\n" },
        ]
        var text = try fixture("note") + "\n"
        text.reserveCapacity(payloadBytes.reduce(0, +) * 4 / 3 + text.utf8.count + 1_000)
        for (index, size) in payloadBytes.enumerated() {
            text += forms[index % forms.count]("data:image/png;base64," + png(paddedTo: size).base64EncodedString())
        }
        return crlf(text)
    }

    static func dataURI() throws -> String {
        try makeDataURIDocument(payloadBytes: [128 * 1_024, 256 * 1_024, 512 * 1_024, 1_048_576, 1_048_576])
    }

    /// D6 весит ~30 МБ, поэтому собирается один раз на весь прогон; `\r\n` ставится на малых кусках, а не на всей строке.
    nonisolated(unsafe) private static var over20MiBCache: String?

    static func over20MiB() throws -> String {
        if let over20MiBCache { return over20MiBCache }
        var text = crlf(try fixture("note")) + "\r\n"
        let chapter = try fixture("long-chapter")
        for number in 1...30 { text += crlf(chapter.replacingOccurrences(of: "{N}", with: String(number))) + "\r\n" }
        let address = "data:image/png;base64," + png(paddedTo: 7 * 1_048_576).base64EncodedString()
        for index in 1...3 { text += "![большая \(index)](\(address))\r\n\r\n" }
        over20MiBCache = text
        return text
    }

    static func text(_ document: Document) throws -> String {
        switch document {
        case .note: try note()
        case .noteMedia: try noteMedia()
        case .longText: try longText()
        case .tables: try tables()
        case .dataURI: try dataURI()
        case .over20MiB: try over20MiB()
        }
    }
}

@MainActor
final class MarkdownBaselineDocumentsTests: XCTestCase {
    private func assertNoBareLineFeeds(_ text: String, _ message: String) {
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), message)
        XCTAssertTrue(text.contains("\r\n"), message)
    }

    func testNoteDocumentCoversAllStage0Constructs() throws {
        let text = try MarkdownBaselineDocuments.text(.note)
        assertNoBareLineFeeds(text, "D1")
        XCTAssertGreaterThan(text.utf16.count, text.count, "в D1 есть символы длиннее одного UTF-16 (эмодзи)")
        XCTAssertTrue(text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value < 0x0500 }, "кириллица")
        XCTAssertTrue(text.contains("中文"), "CJK")
        XCTAssertTrue(text.contains("👨‍👩‍👧"), "составной эмодзи")
        let presentation = MarkdownPresentationBuilder.parse(text, includeWikiLinks: true)
        XCTAssertGreaterThanOrEqual(presentation.headings.count, 8, "заголовки")
        XCTAssertGreaterThanOrEqual(presentation.tables.count, 1, "таблица")
        XCTAssertGreaterThanOrEqual(presentation.formulas.count, 1, "блочная формула")
        XCTAssertGreaterThanOrEqual(presentation.inlineFormulas.count, 1, "строчная формула")
        XCTAssertGreaterThanOrEqual(presentation.taskCheckboxes.count, 3, "чекбоксы")
        XCTAssertGreaterThanOrEqual(presentation.listMarkers.count, 5, "маркеры списков")
        XCTAssertGreaterThanOrEqual(presentation.htmlBlocks.count, 1, "HTML-блок")
        XCTAssertGreaterThanOrEqual(presentation.detailsBlocks.count, 1, "details")
        XCTAssertGreaterThanOrEqual(presentation.ruby.count, 1, "ruby")
        XCTAssertGreaterThanOrEqual(presentation.footnotes.count, 1, "сноска")
        XCTAssertGreaterThanOrEqual(presentation.links.count, 1, "ссылки")
        XCTAssertGreaterThanOrEqual(presentation.wikiLinks.count, 1, "wiki-ссылки")
        XCTAssertGreaterThanOrEqual(presentation.codeBlocks.count, 3, "fenced code")
        XCTAssertTrue(presentation.spans.contains { if case .strong = $0.kind { return true }; return false }, "жирный")
        XCTAssertTrue(presentation.spans.contains { if case .alert = $0.kind { return true }; return false }, "callout")
        XCTAssertTrue(presentation.images.isEmpty, "в D1 нет изображений")
    }

    func testMediaNoteContainsImagesAndDiagrams() throws {
        let text = try MarkdownBaselineDocuments.text(.noteMedia)
        assertNoBareLineFeeds(text, "D2")
        XCTAssertTrue(text.contains("<iframe"), "iframe в тексте")
        let presentation = MarkdownPresentationBuilder.parse(text)
        XCTAssertGreaterThanOrEqual(presentation.images.count, 2, "локальное и удалённое изображение")
        XCTAssertEqual(presentation.diagrams.count, 3, "mermaid, flow, sequence")
        XCTAssertEqual(Set(presentation.diagrams.map(\.kind)), [.mermaid, .flow, .sequence])
        XCTAssertGreaterThanOrEqual(presentation.audioBlocks.count, 1, "audio")
    }

    func testLongTextIsLongAndNumbered() throws {
        let text = try MarkdownBaselineDocuments.text(.longText)
        assertNoBareLineFeeds(text, "D3")
        XCTAssertGreaterThanOrEqual(text.utf8.count, 1_000_000)
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "\r\n").count, 15_000)
        XCTAssertEqual(text.components(separatedBy: "## Глава ").count - 1, 100)
        XCTAssertTrue(text.contains("## Глава 100\r\n"))
        XCTAssertFalse(text.contains("{N}"))
    }

    func testTablesDocumentHasLargeTables() throws {
        let text = try MarkdownBaselineDocuments.text(.tables)
        assertNoBareLineFeeds(text, "D4")
        XCTAssertGreaterThan(text.utf8.count, 400_000)
        let presentation = MarkdownPresentationBuilder.parse(text)
        XCTAssertGreaterThanOrEqual(presentation.tables.count, 8)
        XCTAssertTrue(presentation.tables.contains { $0.rows.count >= 3_000 }, "таблица на 3000 строк")
        XCTAssertTrue(presentation.tables.contains { $0.rows.contains { $0.cells.count == 30 } }, "таблица на 30 колонок")
    }

    func testDataURIDocumentHasLargeValidPayloads() throws {
        let text = try MarkdownBaselineDocuments.text(.dataURI)
        assertNoBareLineFeeds(text, "D5")
        let prefix = "data:image/png;base64,"
        let raw = text as NSString
        var payloads: [String] = []
        var cursor = 0
        while true {
            let found = raw.range(of: prefix, options: [], range: NSRange(location: cursor, length: raw.length - cursor))
            if found.location == NSNotFound { break }
            let start = NSMaxRange(found)
            let closing = raw.rangeOfCharacter(from: CharacterSet(charactersIn: ")'"), options: [], range: NSRange(location: start, length: raw.length - start))
            let end = closing.location == NSNotFound ? raw.length : closing.location
            payloads.append(raw.substring(with: NSRange(location: start, length: end - start)))
            cursor = end
        }
        XCTAssertEqual(payloads.count, 5)
        XCTAssertGreaterThan(text.utf8.count, 3_500_000)
        XCTAssertLessThan(text.utf8.count, 6_000_000)
        let largest = try XCTUnwrap(payloads.max { $0.utf8.count < $1.utf8.count })
        let data = try XCTUnwrap(Data(base64Encoded: largest), "payload декодируется")
        XCTAssertEqual(data.count, 1_048_576)
        XCTAssertNotNil(NSImage(data: data), "большой PNG остаётся настоящим изображением")
    }

    func testOver20MiBDocumentCrossesLargeThreshold() throws {
        let text = try MarkdownBaselineDocuments.text(.over20MiB)
        let bytes = text.utf8.count
        XCTAssertGreaterThan(bytes, DocumentPerformanceProfile.largeFileByteThreshold)
        XCTAssertLessThan(bytes, DocumentPerformanceProfile.extremeFileByteThreshold)
        XCTAssertEqual(DocumentPerformanceProfile.resolve(byteCount: bytes), .large)
    }

    /// CRC32 сверяется с известным значением, а CRC чанка `laCe` в собранном PNG — с независимым пересчётом, потому что `NSImage` его не проверяет.
    func testPaddedPNGChunkChecksumIsCorrect() throws {
        XCTAssertEqual(MarkdownBaselineDocuments.crc32(Array("IEND".utf8)), 0xAE42_6082)
        let data = [UInt8](MarkdownBaselineDocuments.png(paddedTo: 1_000))
        let tiny = [UInt8](Data(base64Encoded: MarkdownBaselineDocuments.tinyPNGBase64)!)
        let chunkStart = tiny.count - 12
        func word(_ offset: Int) -> UInt32 { data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        let length = Int(word(chunkStart))
        XCTAssertEqual(length, 1_000 - tiny.count - 12)
        XCTAssertEqual(Array(data[chunkStart + 4..<chunkStart + 8]), Array("laCe".utf8))
        let typeAndData = Array(data[chunkStart + 4..<chunkStart + 8 + length])
        XCTAssertEqual(word(chunkStart + 8 + length), MarkdownBaselineDocuments.crc32(typeAndData))
    }

    func testPaddedPNGStaysDecodable() throws {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let iend: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        for size in [69, 1_000, 200_000] {
            let data = MarkdownBaselineDocuments.png(paddedTo: size)
            XCTAssertEqual(data.count, size, "размер \(size)")
            XCTAssertEqual(Array(data.prefix(8)), signature, "сигнатура \(size)")
            XCTAssertEqual(Array(data.suffix(12)), iend, "IEND \(size)")
            let image = try XCTUnwrap(NSImage(data: data), "декодирование \(size)")
            XCTAssertEqual(image.size, NSSize(width: 1, height: 1), "размер картинки \(size)")
        }
    }

    /// Пишет D1-D6 и `images/pic.png` на диск для ручного baseline на Mac.
    /// Если задана `LAC_BASELINE_EXPORT_DIR`, файлы остаются там; иначе каталог временный и удаляется.
    func testBaselineDocumentsAreWrittenToDisk() throws {
        let environmentDirectory = ProcessInfo.processInfo.environment["LAC_BASELINE_EXPORT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let directory = environmentDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("lac-baseline-\(UUID().uuidString)", isDirectory: true)
        defer { if environmentDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
        let picture = MarkdownBaselineDocuments.png(paddedTo: 69)
        try picture.write(to: directory.appendingPathComponent("images/pic.png"))
        // D6 (~30 МБ) пишется на диск только при заданной переменной окружения.
        for document in MarkdownBaselineDocuments.Document.allCases where document != .over20MiB || environmentDirectory != nil {
            let data = Data(try MarkdownBaselineDocuments.text(document).utf8)
            let url = directory.appendingPathComponent(document.exportName)
            try data.write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, data.count, document.exportName)
            XCTAssertEqual(try Data(contentsOf: url), data, document.exportName)
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("images/pic.png")), picture)
    }
}

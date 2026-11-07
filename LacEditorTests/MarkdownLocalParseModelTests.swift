import XCTest
@testable import LacEditor

/// Вход редактора «ядро → builder» (U6.0) и модель из полного разбора локального парсера (U6.1). AppKit не нужен.
final class MarkdownLocalParseModelTests: XCTestCase {
    private let options = MarkdownParseOptions(includeReadableText: true, includeEmojiCandidates: true, includeUppercaseRuns: true)

    private func prepared(_ presentation: MarkdownPresentation) -> MarkdownPresentation {
        var copy = presentation
        copy.prepareForEditing()
        return copy
    }

    private func chapters(_ count: Int, heading: (Int) -> String = { "Раздел \($0)" }) -> String {
        (0..<count).map { index in
            "# \(heading(index))\n\nАбзац **жирный** и *курсив* 😀 с `кодом` 中文.\n\n```swift\nlet x = 1\n```\n\nКонец главы.\n\n- пункт\n- [x] задача\n\n> цитата\n\n"
        }.joined()
    }

    /// Позиция внутри абзаца «Абзац» во второй половине документа (как в `testPlainEditInsideLongDocumentIsLocal`).
    private func paragraphLocation(_ text: String) -> Int {
        let ns = text as NSString
        return ns.range(of: "Абзац", options: [], range: NSRange(location: ns.length / 2, length: ns.length / 2)).location + 5
    }

    private func edit(_ text: String, at location: Int, inserting insertion: String) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: insertion)
    }

    private func assertLocalMatchesFull(_ text: String, inserting insertion: String, at location: Int, options: MarkdownParseOptions,
                                        _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        let edited = edit(text, at: location, inserting: insertion)
        let local = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
        XCTAssertTrue(local.usedLocal, "\(message): \(local.fallbackReason ?? "")", file: file, line: line)
        XCTAssertNil(local.model, "локальный разбор модель не отдаёт: \(message)", file: file, line: line)
        let full = MarkdownLocalParser.parse(edited, options: options, base: nil, minimumLength: 0)
        XCTAssertNil(MarkdownPresentation.firstDifference(prepared(local.presentation), prepared(full.presentation)), message, file: file, line: line)
        XCTAssertEqual(local.base?.index, full.base?.index, "индекс блоков: \(message)", file: file, line: line)
    }

    func testFullParseReturnsModelAndLocalParseDoesNot() {
        let text = chapters(12)
        let first = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0)
        let model = first.model
        XCTAssertNotNil(model, "полный разбор отдаёт модель")
        XCTAssertEqual(model?.textLength, (text as NSString).length)
        XCTAssertEqual(model?.blockIndex, first.base?.index)
        assertLocalMatchesFull(text, inserting: "Привет", at: paragraphLocation(text), options: options, "вставка слова посреди документа")
    }

    /// Смена типа документа (заметка хранилища) меняет опции, и база прежнего типа не годится.
    func testVaultNoteChangeResetsBase() {
        let text = chapters(12)
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        var vault = options
        vault.isVaultNote = true
        let result = MarkdownLocalParser.parse(edit(text, at: 3, inserting: "x"), options: vault, base: base, minimumLength: 0)
        XCTAssertEqual(result.fallbackReason, "параметры разбора изменились")
        XCTAssertNotNil(result.model)
    }

    /// Участок с кириллицей, CJK, эмодзи (суррогатные пары) и `\r\n` собирается локально и совпадает с полным.
    func testNonASCIIAndCRLFWindowsMatchFull() {
        let source = chapters(12).replacingOccurrences(of: "\n", with: "\r\n")
        let start = paragraphLocation(source)
        for (insertion, location) in [("中文", start), ("ж", start + 1), ("😀", start + 2), ("\r\n\r\n", start)] {
            assertLocalMatchesFull(source, inserting: insertion, at: location, options: options, "вставка \(insertion.debugDescription) в \(location)")
        }
    }

    /// Одинаковые заголовки по обе стороны правки: `id` и `-1/-2` считаются по всему документу, участок видит только своё окно.
    func testRepeatedHeadingsOnBothSidesOfEditMatchFull() {
        let source = chapters(12) { _ in "Заголовок" }
        assertLocalMatchesFull(source, inserting: "ы", at: paragraphLocation(source), options: options, "повторяющиеся заголовки")
    }

    func testPresentationOfReplacesNulKeepingPositionsAndCancelGivesEmpty() {
        let text = "а\u{0}б **жирный** 世界"
        let presentation = MarkdownPresentationBuilder.presentation(of: text)
        let strong = presentation.spans.first { $0.kind == .strong }
        XCTAssertEqual(strong?.range, NSRange(location: 4, length: 10), "позиции UTF-16 не сдвигаются после замены NUL")
        XCTAssertTrue(MarkdownPresentationBuilder.presentation(of: "# Заголовок\n\n- а", isCancelled: { true }).spans.isEmpty)
        XCTAssertFalse(MarkdownPresentationBuilder.presentation(of: "# Заголовок\n\n- а").spans.isEmpty)
    }
}

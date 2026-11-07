import Foundation
import XCTest
@testable import LacEditor

/// Умные замены модели (U2.5e): поле `smartReplacements`, флаг `editorContext`, отмена.
final class MarkdownDocumentReplacementsTests: XCTestCase {
    private func options(_ includes: MarkdownDocumentModel.Includes, syntax: MarkdownSyntaxOptions) -> MarkdownDocumentModel.Options {
        MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: false, detectsFrontMatter: true)
    }

    private func model(_ text: String, _ includes: MarkdownDocumentModel.Includes = [.editorContext], syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(),
                       file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel? {
        let result = MarkdownDocumentParser.parse(text, options: options(includes, syntax: syntax))
        if result == nil { XCTFail("разбор вернул nil", file: file, line: line) }
        return result
    }

    private func syntax(softBreaks: Bool = true, whitespace: Bool? = nil, smart: Bool? = nil) -> MarkdownSyntaxOptions {
        MarkdownSyntaxOptions(smartPunctuation: smart, preserveEditingWhitespace: whitespace, preserveEditingSoftBreaks: softBreaks)
    }

    // MARK: Особенности переносов

    private func breaks(_ list: [MarkdownTextReplacement]) -> [NSRange] { list.filter { $0.kind == .softBreak }.map(\.range).sorted { $0.location < $1.location } }

    /// У выноски заголовок и тело — разные блоки, переноса-пробела между ними в модели нет.
    func testCalloutTitleBreakIsNotInModel() {
        let syntax = syntax(softBreaks: false)
        let cases: [(String, [NSRange])] = [
            ("> [!note] Заголовок\n> тело\n> вторая\n", [NSRange(location: 26, length: 3)]),
            ("> [!custom-type]\n> тело\n> вторая\n", [NSRange(location: 23, length: 3)]),
            ("> > [!note] T\n> > тело\n> > ещё\n", [NSRange(location: 22, length: 5)]),
        ]
        for (text, newBreaks) in cases {
            XCTAssertEqual(breaks(model(text, syntax: syntax)?.smartReplacements ?? []), newBreaks, "\(text.debugDescription): в модели остаётся перенос внутри тела")
        }
    }

    /// Выноска определяется блоком модели, а не видом строки: обычная цитата со строкой `[!важно]` внутри остаётся как есть, ссылка не выноска.
    func testBracketLineInsideQuoteIsNotCallout() {
        let syntax = syntax(softBreaks: false)
        XCTAssertEqual(breaks(model("> текст\n> [!важно]\n> дальше\n", syntax: syntax)?.smartReplacements ?? []),
                       [NSRange(location: 7, length: 3), NSRange(location: 18, length: 3)], "оба переноса обычной цитаты на месте")
    }

    /// Рендер показывает любой перенос пробелом: модель отдаёт перенос перед жёстким переносом, после него и при «>» без пробела.
    func testEveryBreakIsInModel() {
        let syntax = syntax(softBreaks: false)
        let cases: [(String, NSRange)] = [
            ("а\nб  \nв\n", NSRange(location: 1, length: 1)),
            ("а  \nб\n   в\nг\n", NSRange(location: 5, length: 1)),
            ("> a\n>b\n", NSRange(location: 3, length: 2)),
        ]
        for (text, extra) in cases {
            XCTAssertTrue(breaks(model(text, syntax: syntax)?.smartReplacements ?? []).contains(extra), "\(text.debugDescription): в модели перенос \(extra) есть")
        }
    }

    // MARK: - Флаги и отмена

    func testReplacementsAreEmptyWithoutEditorContext() {
        let text = "\"Кавычки\"  и пробелы   \n"
        XCTAssertEqual(model(text, [.emoji, .readableText])?.smartReplacements, [])
        XCTAssertFalse(model(text, [.editorContext])?.smartReplacements.isEmpty ?? true, "с флагом те же входные данные дают замены")
    }

    /// Отмена на любой проверке ядра, включая проход замен, даёт nil, а не частичный список.
    func testCancellationAtAnyCheckGivesNil() {
        let text = "\"a\"  b  \n> - c\n>   d  e\n\n- [ ]  задача -- \"x\"\n  продолжение\n\nп  q\nr\n"
        let opts = options([.editorContext], syntax: syntax(softBreaks: false))
        var total = 0
        let parsed = MarkdownDocumentParser.parse(text, options: opts, isCancelled: { total += 1; return false })
        XCTAssertFalse(parsed?.smartReplacements.isEmpty ?? true, "без отмены замены есть")
        XCTAssertGreaterThan(total, 0)
        for threshold in 0..<total {
            var calls = 0
            XCTAssertNil(MarkdownDocumentParser.parse(text, options: opts, isCancelled: { calls += 1; return calls > threshold }),
                         "отмена после \(threshold) из \(total) проверок: получена частичная модель")
        }
        guard let model = parsed else { return }
        var direct = 0
        XCTAssertNotNil(MarkdownDocumentParser.smartReplacements(of: model, text: text as NSString, rawHTML: [], isCancelled: { direct += 1; return false }))
        XCTAssertGreaterThan(direct, 0)
        for threshold in 0..<direct {
            var calls = 0
            XCTAssertNil(MarkdownDocumentParser.smartReplacements(of: model, text: text as NSString, rawHTML: [], isCancelled: { calls += 1; return calls > threshold }),
                         "прямой вызов: отмена после \(threshold) из \(direct) проверок")
        }
    }

    func testCancellationReturnsNil() {
        XCTAssertNil(MarkdownDocumentParser.parse("\"a\"  b\n", options: options([.editorContext], syntax: syntax()), isCancelled: { true }))
        guard let parsed = model("\"a\"  b  \n") else { return }
        XCTAssertNil(MarkdownDocumentParser.smartReplacements(of: parsed, text: "\"a\"  b  \n" as NSString, rawHTML: [], isCancelled: { true }))
        XCTAssertNotNil(MarkdownDocumentParser.smartReplacements(of: parsed, text: "\"a\"  b  \n" as NSString, rawHTML: [], isCancelled: { false }))
    }
}

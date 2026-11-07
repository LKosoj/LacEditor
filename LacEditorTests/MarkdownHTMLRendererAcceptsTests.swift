import XCTest
@testable import LacEditor

/// Когда HTML-адаптер принимает готовую модель (например, модель редактора), а когда просит разобрать текст заново (U4.2).
final class MarkdownHTMLRendererAcceptsTests: XCTestCase {
    private let text = "# Привет 😀\r\n\r\n:smile: [[a]] {++新++}"
    private let wiki = MarkdownWikiLinkContext(
        resolver: MarkdownWikiLinkResolver(base: URL(fileURLWithPath: "/lac-accepts", isDirectory: true), paths: ["a.md"]),
        documentURL: URL(fileURLWithPath: "/lac-accepts/doc.md"))

    private func model(_ text: String, syntax: MarkdownSyntaxOptions = .init(), includes: MarkdownDocumentModel.Includes,
                       isVaultNote: Bool = false, detectsFrontMatter: Bool = true) throws -> MarkdownDocumentModel {
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: isVaultNote, detectsFrontMatter: detectsFrontMatter)
        return try XCTUnwrap(MarkdownDocumentParser.parse(text, options: options, isCancelled: { false }))
    }

    private let full: MarkdownDocumentModel.Includes = [.emoji, .wikiLinks, .noteEmbeds, .criticMarkup]

    func testAcceptsMatchingModel() throws {
        let m = try model(text, includes: full)
        XCTAssertTrue(MarkdownHTMLRenderer.accepts(m, text: text, syntax: .init(), wiki: wiki, critic: .show, documentURL: nil))
        let plain = try model(text, includes: [.emoji, .readableText, .blockIndex, .elementIndex, .editorContext, .uppercaseRuns])
        XCTAssertTrue(MarkdownHTMLRenderer.accepts(plain, text: text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "лишние флаги, не влияющие на HTML")
    }

    // Лишние .criticMarkup/.noteEmbeds/.wikiLinks меняют HTML, поэтому модель не принимается.
    func testRejectsExtraObsidianIncludes() throws {
        for extra: MarkdownDocumentModel.Includes in [.criticMarkup, .noteEmbeds, .wikiLinks] {
            let m = try model(text, includes: [.emoji, extra])
            XCTAssertFalse(MarkdownHTMLRenderer.accepts(m, text: text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "лишний флаг \(extra.rawValue) без wiki и critic")
        }
        let embedsOnly = try model(text, includes: [.emoji, .noteEmbeds, .criticMarkup])
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(embedsOnly, text: text, syntax: .init(), wiki: wiki, critic: .show, documentURL: nil), "wiki без .wikiLinks")
        let withWiki = try model(text, includes: full)
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(withWiki, text: text, syntax: .init(), wiki: wiki, critic: nil, documentURL: nil), "лишний .criticMarkup при wiki")
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(withWiki, text: text, syntax: .init(), wiki: nil, critic: .show, documentURL: nil), "лишние wiki при critic")
    }

    /// Маркеры и якоря содержат случайный UUID: перед сравнением они заменяются фиксированной строкой.
    private func normalized(_ string: String) -> String {
        var result = string
        for pattern in ["LAC[A-Z]+[0-9A-Fa-f]{32}X?", "lac-anchor-[0-9A-Fa-f-]{36}"] {
            result = result.replacingOccurrences(of: pattern, with: "ID", options: .regularExpression)
        }
        return result
    }

    private func assertSame(_ a: MarkdownRenderedPage, _ b: MarkdownRenderedPage, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(normalized(a.body), normalized(b.body), message, file: file, line: line)
        XCTAssertEqual(a.headingIDs, b.headingIDs, message, file: file, line: line)
        XCTAssertEqual(a.formulas.map { "\($0.display)|\($0.source)" }, b.formulas.map { "\($0.display)|\($0.source)" }, message, file: file, line: line)
        XCTAssertEqual(a.diagrams.map { "\($0.kind)|\($0.source)" }, b.diagrams.map { "\($0.kind)|\($0.source)" }, message, file: file, line: line)
        XCTAssertEqual(a.omittedHTML, b.omittedHTML, message, file: file, line: line)
        XCTAssertEqual(a.preserveWhitespace, b.preserveWhitespace, message, file: file, line: line)
        XCTAssertEqual(a.listDepths, b.listDepths, message, file: file, line: line)
        XCTAssertEqual(a.remoteImageMarkers.values.sorted(), b.remoteImageMarkers.values.sorted(), message, file: file, line: line)
        XCTAssertEqual(a.localMediaMarkers.values.map { "\($0.url.path)#\($0.fragment)" }.sorted(),
                       b.localMediaMarkers.values.map { "\($0.url.path)#\($0.fragment)" }.sorted(), message, file: file, line: line)
        XCTAssertEqual(a.rawHTMLBlocks.map(\.html), b.rawHTMLBlocks.map(\.html), message, file: file, line: line)
        XCTAssertEqual(a.rawHTMLBlockProofFailed, b.rawHTMLBlockProofFailed, message, file: file, line: line)
    }

    // Если accepts == true, страница по модели редактора совпадает со страницей по строке; если false, откат на строку.
    // Параметры вывода — как у предпросмотра (MarkdownPreview.swift, значение renderer по умолчанию).
    func testAcceptedEditorModelRendersSameAsString() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lac-accepts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("doc.md")
        let inputs = ["{++\"a\"++}", "{++*a*++}", "![[a|*b*]]", "[[a|*b*]]", "# Привет 😀\r\n\r\n:smile: [[a]] {++新++} ![[a]]\r\n",
                      "Ж *э* {--世界--} {~~а~>б~~} {>>😀<<}\r\n\r\n![[x.png]]",
                      "# Заголовок Ж\r\n\r\n## 世界 😀\r\n\r\nТекст $x$ и\r\n\r\n$$\r\ny = 1\r\n$$\r\n\r\n```swift\r\nlet a = 1\r\n```\r\n\r\n![a](b.png)\r\n\r\n![r](https://example.com/r.png)\r\n\r\n<div>x</div>\r\n\r\n- один\r\n  - два\r\n"]
        let wikis: [MarkdownWikiLinkContext?] = [nil, wiki]
        let critics: [CriticMarkupRenderMode?] = [nil, .show, .result, .original]
        for input in inputs {
            for w in wikis {
                for c in critics {
                    for wikiFlag in [false, true] {
                        let includes = MarkdownPresentationBuilder.editorIncludes(readableText: true, emojiCandidates: true, uppercaseRuns: true,
                                                                                  wikiLinks: wikiFlag, blockIndex: true)
                        let m = try model(input, includes: includes)
                        let message = "\(input.debugDescription) wiki=\(w != nil) critic=\(String(describing: c)) wikiFlag=\(wikiFlag)"
                        let expected = MarkdownHTMLRenderer.renderPage(input, darkMode: false, renderEmoji: true, resolveLocalImages: true, documentURL: documentURL,
                                                                       prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true,
                                                                       includeSourcePositions: true, isPreview: true, highlightCode: true, wiki: w, critic: c)
                        if MarkdownHTMLRenderer.accepts(m, text: input, syntax: .init(), wiki: w, critic: c, documentURL: documentURL) {
                            let actual = MarkdownHTMLRenderer.renderPage(m, text: input, darkMode: false, renderEmoji: true, resolveLocalImages: true, documentURL: documentURL,
                                                                         prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true,
                                                                         includeSourcePositions: true, isPreview: true, highlightCode: true, wiki: w, critic: c)
                            assertSame(actual, expected, message)
                        } else {
                            XCTAssertFalse(w != nil && c != nil && wikiFlag, "модель редактора с wiki и critic должна приниматься: " + message)
                        }
                    }
                }
            }
        }
    }

    func testRejectsMissingIncludes() throws {
        let noEmoji = try model(text, includes: [.wikiLinks, .noteEmbeds, .criticMarkup])
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(noEmoji, text: text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "нет .emoji")
        let noWiki = try model(text, includes: [.emoji, .criticMarkup])
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(noWiki, text: text, syntax: .init(), wiki: wiki, critic: nil, documentURL: nil), "нет wiki при wiki-контексте")
        let noCritic = try model(text, includes: [.emoji, .wikiLinks, .noteEmbeds])
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(noCritic, text: text, syntax: .init(), wiki: nil, critic: .show, documentURL: nil), "нет critic")
    }

    func testRejectsOtherTextSyntaxFrontMatterAndVaultNote() throws {
        let m = try model(text, includes: [.emoji])
        XCTAssertTrue(MarkdownHTMLRenderer.accepts(m, text: text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "контроль: те же настройки принимаются")
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(m, text: text + "x", syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "другая длина")
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(m, text: "a\u{0}b", syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "NUL")
        let strict = MarkdownSyntaxOptions(strictMode: false)
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(m, text: text, syntax: strict, wiki: nil, critic: nil, documentURL: nil), "другой синтаксис")
        let noFront = try model(text, includes: [.emoji], detectsFrontMatter: false)
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(noFront, text: text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "front matter")
        let vault = try model(text, includes: [.emoji], isVaultNote: true)
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(vault, text: text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil), "заметка хранилища без документа")
    }
}

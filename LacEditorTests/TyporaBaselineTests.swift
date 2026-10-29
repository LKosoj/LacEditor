import Foundation
import XCTest
@testable import LacEditor

final class TyporaBaselineTests: XCTestCase {
    private func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Verification/Fixtures/typora-baseline.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func checkRanges(_ text: String, offset: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let presentation = MarkdownPresentationParser.parse(text)
        let source = text as NSString
        let expected: [(MarkdownPresentationKind, NSRange, String, [String])] = [
            (.heading(1), NSRange(location: 0, length: 10), "# 中文 😀 e\u{301}", ["# "]),
            (.strong, NSRange(location: 18 + offset, length: 10), "**жирный**", ["**", "**"]),
            (.emphasis, NSRange(location: 31 + offset, length: 8), "*курсив*", ["*", "*"]),
            (.strikethrough, NSRange(location: 41 + offset, length: 10), "~~старое~~", ["~~", "~~"]),
            (.code, NSRange(location: 53 + offset, length: 5), "`код`", ["`", "`"]),
            (.link, NSRange(location: 61 + offset, length: 31), "[ссылка](https://example.com/a)", ["[", "](https://example.com/a)"])
        ]
        for (kind, range, fragment, markers) in expected {
            let span = try XCTUnwrap(presentation.spans.first { $0.kind == kind }, file: file, line: line)
            XCTAssertEqual(span.range, range, file: file, line: line)
            XCTAssertEqual(source.substring(with: range), fragment, file: file, line: line)
            XCTAssertEqual(span.markerRanges.map { source.substring(with: $0) }, markers, file: file, line: line)
        }
        let heading = try XCTUnwrap(presentation.headings.first, file: file, line: line)
        XCTAssertEqual(heading.title, "中文 😀 e\u{301}", file: file, line: line)
        XCTAssertEqual(heading.range, NSRange(location: 0, length: 10), file: file, line: line)
    }

    func testFixtureRangesAndCRLF() throws {
        let text = try fixture()
        try checkRanges(text, offset: 0)
        try checkRanges(text.replacingOccurrences(of: "\n", with: "\r\n"), offset: 2)
    }

    func testFixturePreviewHTML() throws {
        let text = try fixture()
        for source in [text, text.replacingOccurrences(of: "\n", with: "\r\n")] {
            let body = MarkdownRenderer.renderPage(source, darkMode: false).body
            XCTAssertTrue(body.contains("<h1>中文 😀 e\u{301}</h1>"))
            XCTAssertTrue(body.contains("<strong>жирный</strong>"))
            XCTAssertTrue(body.contains("<em>курсив</em>"))
            XCTAssertTrue(body.contains("<del>старое</del>"))
            XCTAssertTrue(body.contains("<code>код</code>"))
            XCTAssertTrue(body.contains("href=\"https://example.com/a\""))
            XCTAssertTrue(body.contains("<blockquote>"))
            XCTAssertTrue(body.contains("let value = 1"))
            XCTAssertTrue(body.contains("<ul>"))
            XCTAssertTrue(body.contains("<li>Первый</li>"))
            XCTAssertTrue(body.contains("<table>"))
            XCTAssertTrue(body.contains("<td>A</td>"))
        }
    }
}

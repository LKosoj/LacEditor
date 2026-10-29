import XCTest
@testable import LacEditor

final class UIPolishJTests: XCTestCase {
    private let key = "预览为空。在编辑器中输入 Markdown 后，内容会显示在这里。"

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("LacEditor/" + relative), encoding: .utf8)
    }

    private func html(_ markdown: String = "x", dark: Bool = false) -> String {
        MarkdownRenderer.renderPage(markdown, darkMode: dark).html
    }

    private func block(_ html: String, from marker: String) throws -> Substring {
        let range = try XCTUnwrap(html.range(of: marker))
        return html[range.upperBound...]
    }

    private func luminance(_ hex: String) -> Double {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let channels = [(value >> 16) & 255, (value >> 8) & 255, value & 255].map { part -> Double in
            let c = Double(part) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // MARK: D1

    func testAlertsGetWhitelistedClass() {
        for label in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let body = MarkdownRenderer.renderPage("> [!\(label)]\n> text\n\n<script>bad()</script>", darkMode: false).body
            XCTAssertTrue(body.contains("<aside class=\"lac-alert lac-alert-\(label.lowercased())\">"), label)
            XCTAssertFalse(body.contains("<script>"), label)
        }
        let unknown = MarkdownRenderer.renderPage("> [!UNKNOWN]\n> text", darkMode: false).body
        XCTAssertFalse(unknown.contains("<aside"))
    }

    func testAlertStylesCoverFiveKinds() {
        let page = html()
        for kind in ["note", "tip", "important", "warning", "caution"] {
            XCTAssertTrue(page.contains(".lac-alert-\(kind) {"), kind)
        }
        XCTAssertTrue(page.contains("--alert-note: #0969da"))
        XCTAssertTrue(page.contains("--alert-caution: #f85149"))
    }

    func testAlertColorsKeepContrast() {
        let lightPairs = [("#0550ae", "#0969da"), ("#116329", "#1a7f37"), ("#6639ba", "#8250df"), ("#7d4e00", "#9a6700"), ("#a40e26", "#cf222e")]
        for (text, bar) in lightPairs {
            XCTAssertGreaterThanOrEqual(contrast(text, "#f4f4f8"), 4.5, text)
            XCTAssertGreaterThanOrEqual(contrast(bar, "#fbfbfb"), 3, bar)
        }
        let darkPairs = [("#79b8ff", "#4493f8"), ("#56d364", "#3fb950"), ("#c9a8ff", "#ab7df8"), ("#e3b341", "#d29922"), ("#ff8a85", "#f85149")]
        for (text, bar) in darkPairs {
            XCTAssertGreaterThanOrEqual(contrast(text, "#222228"), 4.5, text)
            XCTAssertGreaterThanOrEqual(contrast(bar, "#1b1b1b"), 3, bar)
        }
    }

    func testBaseBlockquoteRuleStaysFirst() throws {
        let page = html()
        let start = try XCTUnwrap(page.range(of: "blockquote {"))
        let end = try XCTUnwrap(page.range(of: "}", range: start.upperBound..<page.endIndex))
        XCTAssertTrue(page[start.upperBound..<end.lowerBound].contains("color: var(--text)"))
    }

    // MARK: D2

    func testStylesCoverMarkKbdTasksAndFootnotes() {
        let page = html()
        for fragment in ["mark { background: var(--mark)", "kbd { border:", "li:has(> input[type=\"checkbox\"]) { list-style: none; }", "li > input[type=\"checkbox\"]:first-child", "section[data-footnotes]", "sup.footnote-ref", "a.footnote-backref"] {
            XCTAssertTrue(page.contains(fragment), fragment)
        }
        XCTAssertGreaterThanOrEqual(contrast("#303038", "#fff1a8"), 4.5)
        XCTAssertGreaterThanOrEqual(contrast("#dddde3", "#5a4a10"), 4.5)
    }

    // MARK: D3

    func testPreviewAccentOnlyInDecorVariables() {
        var page = MarkdownRenderer.renderPage("x", darkMode: false)
        XCTAssertNil(page.rootColorVariables["--lac-accent"])
        XCTAssertFalse(page.html.contains("--lac-accent:"))
        page.previewAccent = "rgba(1,2,3,1)"
        XCTAssertEqual(page.rootColorVariables["--lac-accent"], "rgba(1,2,3,1)")
        XCTAssertTrue(page.html.contains("--lac-accent:rgba(1,2,3,1)"))
        XCTAssertTrue(page.html.contains("var(--lac-accent, var(--accent))"))
    }

    func testPreviewAccentIsSkippedWithCustomLinkColor() {
        var page = MarkdownRenderer.renderPage("x", darkMode: false)
        var colors = MarkdownColorOverrides()
        colors.link = MarkdownSRGBColor(red: 1, green: 0, blue: 0)
        page.typography = MarkdownTypography(fontSize: 15, lineHeight: 24, lightColors: colors)
        page.previewAccent = "rgba(1,2,3,1)"
        XCTAssertNil(page.rootColorVariables["--lac-accent"])
        XCTAssertNotNil(page.rootColorVariables["--accent"])
    }

    func testPatchScriptResetsPreviewAccent() throws {
        XCTAssertTrue(try source("Preview/MarkdownPreview.swift").contains("'--lac-accent'"))
    }

    // MARK: D4, D5, D6

    func testPrintKeepsBackgrounds() throws {
        let block = try block(html(), from: "@media print {")
        XCTAssertTrue(block.contains("print-color-adjust: exact"))
        XCTAssertTrue(block.contains("-webkit-print-color-adjust: exact"))
    }

    func testNoEmptyReducedTransparencyRule() {
        XCTAssertFalse(html().contains("prefers-reduced-transparency"))
    }

    func testIncreasedContrastStrengthensAccent() throws {
        let page = html()
        let start = try XCTUnwrap(page.range(of: "@media (prefers-contrast: more) {"))
        let end = try XCTUnwrap(page.range(of: "@media print {"))
        let block = page[start.upperBound..<end.lowerBound]
        XCTAssertTrue(block.contains("--accent: #3f4490"))
        XCTAssertTrue(block.contains("--accent: #c8cbff"))
    }

    // MARK: D7

    func testEmptyHintOnlyInPreview() {
        for text in ["", "  \n\t"] {
            let body = MarkdownRenderer.renderPage(text, darkMode: false, isPreview: true).body
            XCTAssertTrue(body.contains("class=\"lac-empty\""))
            XCTAssertTrue(body.contains(L10n.tr(key)))
            XCTAssertTrue(MarkdownRenderer.renderPage(text, darkMode: false).body.isEmpty)
            XCTAssertTrue(MarkdownRenderer.renderPage(text, darkMode: false, forExport: true, isPreview: true).body.isEmpty)
        }
        XCTAssertFalse(MarkdownRenderer.renderPage("a", darkMode: false, isPreview: true).body.contains("lac-empty"))
    }

    func testRenderActorShowsEmptyHint() async {
        let coordinator = DocumentTaskCoordinator()
        let generation = coordinator.begin(.preview)
        let page = await MarkdownRenderActor().render("", darkMode: false, coordinator: coordinator, generation: generation)
        XCTAssertTrue(page?.body.contains("lac-empty") ?? false)
    }

    // MARK: D8

    private func stripped(_ body: String) -> String {
        body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    func testCodeHighlightKeepsText() {
        let literal = "let s = \"中😀 <&>\"\n"
        let body = MarkdownRenderer.renderPage("```swift\n\(literal)```", darkMode: false, highlightCode: true).body
        XCTAssertTrue(body.contains("<span class=\"tok-k\">let</span>"))
        XCTAssertEqual(stripped(body).trimmingCharacters(in: .newlines), literal.trimmingCharacters(in: .newlines))
        XCTAssertFalse(MarkdownRenderer.renderPage("```swift\n\(literal)```", darkMode: false).body.contains("tok-"))
    }

    func testCodeHighlightSkipsOtherLanguages() {
        for source in ["```mermaid\ngraph TD\n```", "```unknownlang\nlet a = 1\n```", "```\nlet a = 1\n```"] {
            XCTAssertFalse(MarkdownRenderer.renderPage(source, darkMode: false, highlightCode: true).body.contains("tok-"), source)
        }
        XCTAssertTrue(MarkdownRenderer.renderPage("```mermaid\ngraph TD\n```", darkMode: false, highlightCode: true).body.contains("language-mermaid"))
    }

    func testCodeHighlightSourcePositionsAndExport() {
        let source = "```swift\nlet a = 1\n```"
        let preview = MarkdownRenderer.renderPage(source, darkMode: false, includeSourcePositions: true, highlightCode: true).body
        XCTAssertTrue(preview.contains("<pre tabindex=\"0\""))
        XCTAssertTrue(preview.contains("data-sourcepos=\"1:1-3:3\""))
        let export = MarkdownRenderer.renderPage(source, darkMode: false, forExport: true, includeSourcePositions: true, highlightCode: true).body
        XCTAssertFalse(export.contains("data-sourcepos"))
    }

    func testCodeHighlightInsideListAndQuoteWithoutNestedSpans() {
        let nested = MarkdownRenderer.renderPage("- item\n\n  ```json\n  {\"a\": [1, true]}\n  ```\n\n> ```swift\n> let a = 1\n> ```", darkMode: false, highlightCode: true).body
        XCTAssertTrue(nested.contains("tok-"))
        XCTAssertFalse(nested.contains("</span></span>"))
        XCTAssertEqual(MarkdownRenderer.renderPage("```json\n{\"a\": 1}\n```", darkMode: false, highlightCode: true).body,
                       MarkdownRenderer.renderPage("```json\n{\"a\": 1}\n```", darkMode: false, highlightCode: true).body)
    }

    func testHighlightIsEnabledForPDFExceptPlainHTML() throws {
        XCTAssertTrue(try source("Preview/MarkdownPDFExportService.swift").contains("highlightCode: !isHTML"))
    }

    func testTokenColorsKeepContrast() {
        for (text, code) in [("#4a4f9e", "#f0f0f4"), ("#33754a", "#f0f0f4"), ("#a35016", "#f0f0f4"), ("#87479c", "#f0f0f4"), ("#556652", "#f0f0f4"),
                             ("#9eabfa", "#25252c"), ("#7ac28c", "#25252c"), ("#f09e57", "#25252c"), ("#cc96e0", "#25252c"), ("#99a89e", "#25252c")] {
            XCTAssertGreaterThanOrEqual(contrast(text, code), 4.5, text)
        }
    }
}

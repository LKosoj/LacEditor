import AppKit
import WebKit
import XCTest
@testable import LacEditor

@MainActor
private final class OverlayFixture {
    let document = EditorDocument(text: "", language: .markdown)
    let coordinator: MarkdownPreview.Coordinator
    let webView: MarkdownWebView
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        coordinator = MarkdownPreview.Coordinator(document: document, imageSession: .shared)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        MarkdownPreview.configureLinkRouting(config, coordinator: coordinator)
        webView = MarkdownWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 500), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        webView.retryLoad = { [weak coordinator] in coordinator?.retryLoadingPage() }
        window.orderFront(nil)
    }

    func waitUntil(_ condition: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = try? await webView.evaluateJavaScript(condition, in: nil, contentWorld: .defaultClient)
            if value as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Preview did not become ready: \(condition)")
        throw NSError(domain: "OverlayFixture", code: 1)
    }

    func dispose() {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.close()
    }
}

@MainActor
final class UIPolishBTests: XCTestCase {
    private let sample = "# T\n\n[a](https://example.com)\n\n> q\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"

    private func printBlock(_ html: String) throws -> Substring {
        let range = try XCTUnwrap(html.range(of: "@media print {"))
        return html[range.upperBound...]
    }

    func testLinksHaveAlwaysVisibleUnderline() {
        let html = MarkdownRenderer.render(sample, darkMode: false)
        XCTAssertTrue(html.contains("color-mix(in srgb, var(--accent)"))
        XCTAssertTrue(html.contains("a:hover, a:focus-visible"))
        XCTAssertFalse(html.contains("a:not(:hover) { text-decoration-color: transparent; }"))
    }

    func testDarkSelectionHasOwnColor() {
        XCTAssertTrue(MarkdownRenderer.render(sample, darkMode: true).contains(":root[data-theme=\"dark\"] ::selection"))
    }

    func testFontStackIncludesSystemAndCJK() {
        let html = MarkdownRenderer.render(sample, darkMode: false)
        for name in ["system-ui", "\"Hiragino Sans\"", "\"Apple SD Gothic Neo\"", "\"PingFang SC\""] {
            XCTAssertTrue(html.contains(name), name)
        }
    }

    func testBlockquoteUsesPrimaryText() throws {
        let html = MarkdownRenderer.render(sample, darkMode: false)
        let start = try XCTUnwrap(html.range(of: "blockquote {"))
        let end = try XCTUnwrap(html.range(of: "}", range: start.upperBound..<html.endIndex))
        let block = html[start.upperBound..<end.lowerBound]
        XCTAssertTrue(block.contains("color: var(--text)"))
        XCTAssertFalse(block.contains("var(--secondary)"))
    }

    func testTablesAlternateRowsAndUseTabularNumbers() {
        let html = MarkdownRenderer.render(sample, darkMode: false)
        XCTAssertTrue(html.contains("tbody tr:nth-child(even)"))
        XCTAssertTrue(html.contains("td { font-variant-numeric: tabular-nums; }"))
    }

    func testPrintStyleAvoidsBreaksAndForcesLightTheme() throws {
        let block = try printBlock(MarkdownRenderer.render(sample, darkMode: true))
        for fragment in ["break-inside: avoid", ".mermaid-diagram", "break-after: avoid", ":root[data-theme=\"dark\"]", "--page: #fff"] {
            XCTAssertTrue(block.contains(fragment), fragment)
        }
    }

    func testPrintCSSKeepsCustomContentWidth() {
        let typography = MarkdownTypography(fontSize: 15, lineHeight: 24, maximumWidth: 600)
        var page = MarkdownRenderer.renderPage("x", darkMode: false)
        page.typography = typography
        XCTAssertTrue(page.html.contains("--lac-content-width:600"))
        XCTAssertTrue(page.html.contains("--lac-print-width:min(100%,600"))
    }

    func testPrintAndPDFAlwaysUseLightTheme() {
        let info = NSPrintInfo()
        for mode in [MarkdownPDFExportService.Mode.pdf, .printJob(info)] {
            XCTAssertFalse(AppState.markdownOutputUsesDarkMode(for: mode, windowIsDark: true))
        }
        for mode in [MarkdownPDFExportService.Mode.png, .htmlPlain] {
            XCTAssertTrue(AppState.markdownOutputUsesDarkMode(for: mode, windowIsDark: true))
            XCTAssertFalse(AppState.markdownOutputUsesDarkMode(for: mode, windowIsDark: false))
        }
    }

    func testLightColorsReachPrintedPage() throws {
        var light = MarkdownColorOverrides()
        light.text = MarkdownSRGBColor(red: 0, green: 0, blue: 1)
        var dark = MarkdownColorOverrides()
        dark.text = MarkdownSRGBColor(red: 1, green: 0, blue: 0)
        let typography = MarkdownTypography(fontSize: 15, lineHeight: 24, lightColors: light, darkColors: dark)
        let useDark = AppState.markdownOutputUsesDarkMode(for: .pdf, windowIsDark: true)
        var page = MarkdownRenderer.renderPage("x", darkMode: useDark)
        page.typography = typography
        let html = page.html
        XCTAssertTrue(html.contains("data-theme=\"light\""))
        XCTAssertTrue(html.contains(try XCTUnwrap(light.cssVariables["--text"])))
        XCTAssertFalse(html.contains(try XCTUnwrap(dark.cssVariables["--text"])))
    }

    func testLoadFailureShowsMessageAndRetryRecoversPage() async throws {
        let fixture = OverlayFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "hello", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.documentElement.dataset.revision === '1'")
        fixture.coordinator.presentLoadFailure(URLError(.notConnectedToInternet))
        XCTAssertTrue(fixture.webView.isShowingLoadError)
        fixture.webView.retryLoad?()
        XCTAssertFalse(fixture.webView.isShowingLoadError)
        try await fixture.waitUntil("document.querySelector('article')?.innerText.includes('hello') === true")
        XCTAssertFalse(fixture.webView.isShowingLoadError)
    }

    func testCancelledOrInactiveFailureIsIgnored() {
        let fixture = OverlayFixture()
        defer { fixture.dispose() }
        fixture.coordinator.presentLoadFailure(URLError(.cancelled))
        XCTAssertFalse(fixture.webView.isShowingLoadError)
        fixture.coordinator.setActive(false)
        fixture.coordinator.presentLoadFailure(URLError(.timedOut))
        XCTAssertFalse(fixture.webView.isShowingLoadError)
    }

    func testLoadingIndicatorAppearsOnlyAfterDelay() async throws {
        let fixture = OverlayFixture()
        defer { fixture.dispose() }
        fixture.webView.setLoading(true)
        XCTAssertFalse(fixture.webView.isShowingLoadingIndicator)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(fixture.webView.isShowingLoadingIndicator)
        fixture.webView.setLoading(false)
        XCTAssertFalse(fixture.webView.isShowingLoadingIndicator)
        fixture.webView.setLoading(true)
        fixture.webView.setLoading(false)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(fixture.webView.isShowingLoadingIndicator)
    }

    func testRetryButtonCallsHandler() throws {
        let fixture = OverlayFixture()
        defer { fixture.dispose() }
        var called = false
        fixture.webView.retryLoad = { called = true }
        fixture.webView.showLoadError("x")
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let all = descendants(fixture.webView)
        let button = try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("重试") })
        button.performClick(nil)
        XCTAssertTrue(called)
        XCTAssertTrue(all.contains { ($0 as? NSTextField)?.stringValue == L10n.tr("无法显示预览") })
    }
}

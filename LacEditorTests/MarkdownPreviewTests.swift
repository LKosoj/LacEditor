import AppKit
import WebKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testEditsAndThemePatchExistingPageAndPreserveScroll() async throws {
        let text = String(repeating: "## 标题\n\n中英文 Mixed text，阅读与编辑。\n\n", count: 250)
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let time: Double = try await fixture.value("performance.timeOrigin")
        let _: Bool = try await fixture.value("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * .6); true")
        try await Task.sleep(for: .milliseconds(80))
        fixture.coordinator.render(markdown: text + "\n最新内容", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        let after: Double = try await fixture.value("performance.timeOrigin")
        XCTAssertEqual(time, after, "Editing must not navigate/reload the preview")
        let ratio: Double = try await fixture.value("scrollY / (document.documentElement.scrollHeight - innerHeight)")
        XCTAssertEqual(ratio, 0.6, accuracy: 0.025)
        fixture.coordinator.render(markdown: text + "\n最新内容", revision: 2, darkMode: true, immediately: true)
        try await fixture.waitUntil("document.documentElement.dataset.theme === 'dark'")
        let themed: Double = try await fixture.value("performance.timeOrigin")
        let color: String = try await fixture.value("getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(time, themed, "Appearance changes must reuse the page")
        XCTAssertEqual(color, "rgb(27, 27, 27)")
        XCTAssertFalse(fixture.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testReloadKeepsLatestContentAndScrollWithoutFurtherEdits() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: String(repeating: "段落内容\n\n", count: 300),
                                   revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let time: Double = try await fixture.value("performance.timeOrigin")
        let _: Bool = try await fixture.value("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * .45); true")
        _ = fixture.webView.reload()
        try await fixture.waitUntil("performance.timeOrigin !== \(time)")
        try await fixture.waitForRevision(1)
        let ratio: Double = try await fixture.value("scrollY / (document.documentElement.scrollHeight - innerHeight)")
        XCTAssertEqual(ratio, 0.45, accuracy: 0.025)
        let body: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(body.contains("段落内容"))
    }

    func testHiddenPreviewPausesAndOnlyLatestRevisionIsApplied() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "旧内容", revision: 1, darkMode: false, immediately: true)
        fixture.coordinator.render(markdown: "最新内容", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        fixture.coordinator.setActive(false)
        fixture.coordinator.render(markdown: "隐藏时修改", revision: 3, darkMode: false, immediately: true)
        try await Task.sleep(for: .milliseconds(300))
        let body: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(body.contains("最新内容"))
        XCTAssertFalse(body.contains("隐藏时修改"))
        fixture.coordinator.setActive(true)
        fixture.coordinator.render(markdown: "恢复后的内容", revision: 4, darkMode: false, immediately: true)
        try await fixture.waitForRevision(4)
        let resumed: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(resumed.contains("恢复后的内容"))
    }

    func testNarrowPreviewContainsWideTablesAndCode() async throws {
        let fixture = PreviewFixture(width: 240)
        defer { fixture.dispose() }
        let columns = (1...12).map { "列\($0)" }.joined(separator: " | ")
        let separator = Array(repeating: "---", count: 12).joined(separator: " | ")
        let row = Array(repeating: "字段内容", count: 12).joined(separator: " | ")
        fixture.coordinator.render(markdown: "# 中文与 English\n\n| \(columns) |\n| \(separator) |\n| \(row) |\n\n```\n\(String(repeating: "long_code_", count: 100))\n```\n\n- 一级\n  - 二级\n    - 三级",
                                   revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let pageFits: Bool = try await fixture.value("document.documentElement.scrollWidth <= innerWidth + 1")
        let tableScrolls: Bool = try await fixture.value("document.querySelector('.table-scroll').scrollWidth > document.querySelector('.table-scroll').clientWidth")
        let codeScrolls: Bool = try await fixture.value("document.querySelector('pre').scrollWidth > document.querySelector('pre').clientWidth")
        let nested: String = try await fixture.value("getComputedStyle(document.querySelector('ul ul ul')).listStyleType")
        XCTAssertTrue(pageFits)
        XCTAssertTrue(tableScrolls)
        XCTAssertTrue(codeScrolls)
        XCTAssertEqual(nested, "square")
    }
}

@MainActor
private final class PreviewFixture {
    let document = EditorDocument(text: "", language: .markdown)
    let coordinator: MarkdownPreview.Coordinator
    let webView: MarkdownWebView
    let window: NSWindow

    init(width: CGFloat = 480) {
        _ = NSApplication.shared
        coordinator = MarkdownPreview.Coordinator(document: document)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = MarkdownWebView(frame: NSRect(x: 0, y: 0, width: width, height: 500), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        webView.reloadRenderedContent = { [weak coordinator, weak webView] in
            guard let coordinator, let webView else { return }
            coordinator.reloadLastRenderedHTML(in: webView)
        }
        window.orderFront(nil)
    }

    func value<T>(_ script: String) async throws -> T {
        let value = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? T, "Unexpected JavaScript result for \(script)")
    }

    func waitForRevision(_ revision: UInt) async throws {
        try await waitUntil("document.documentElement.dataset.revision === '\(revision)'")
    }

    func waitUntil(_ condition: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ready: Bool = try? await value(condition), ready { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Preview did not become ready: \(condition)")
        throw NSError(domain: "PreviewFixture", code: 1)
    }

    func dispose() {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.reloadRenderedContent = nil
        window.contentView = nil
        window.close()
    }
}

import AppKit
import XCTest
@testable import LacEditor

/// T9: доступность оформленного Markdown. Проверяется то, что даёт наш код (роли, подписи, чтение без скрытых маркеров, устаревание элементов);
/// настоящий VoiceOver и Accessibility Inspector - только вручную на Mac. Стенд - как в `MarkdownUndoGroupTests`.
@MainActor
final class MarkdownAccessibilityTests: XCTestCase {
    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }

        func ignoredRanges() -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: shown.length)).map(\.rangeValue)
        }

        func items(_ role: NSAccessibility.Role) -> [NSAccessibilityElement] {
            (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == role }
        }
    }

    private func makeEditor(_ source: String) -> Editor {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        view.allowsUndo = true
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.attachLiveTextProvider()
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return Editor(document: document, coordinator: coordinator, view: view, window: window)
    }

    private func finish(_ editor: Editor) { editor.coordinator.updateActivity(false); editor.window.close() }

    private func waitForItems(_ editor: Editor, role: NSAccessibility.Role, count: Int) async throws {
        for _ in 0..<30 where editor.items(role).count != count { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(editor.items(role).count, count, "элементы \(role.rawValue) не появились")
    }

    func testHeadingsExposeRoleLevelAndRenderedTitle() async throws {
        let editor = makeEditor("# Первый 😀\n\ntекст\n\n### Третий **жирный** 中文\n")
        defer { finish(editor) }
        try await waitForItems(editor, role: .headingRole, count: 2)
        let headings = editor.items(.headingRole)
        XCTAssertEqual(headings[0].accessibilityLabel(), "Первый 😀")
        XCTAssertEqual(headings[0].accessibilityRoleDescription(), L10n.tr("标题 %@ 级", "1"))
        XCTAssertEqual(headings[1].accessibilityLabel(), "Третий жирный 中文", "метка без маркеров Markdown")
        XCTAssertEqual(headings[1].accessibilityRoleDescription(), L10n.tr("标题 %@ 级", "3"))
    }

    func testLinkExposesLabelAddressAndPressesOnlyWhileCurrent() async throws {
        let editor = makeEditor("Смотри [мир 😀](<https://example.com/a>) дальше")
        defer { finish(editor) }
        try await waitForItems(editor, role: .link, count: 1)
        var activated: NSRange?
        editor.view.markdownLinkActivateHandler = { activated = $0; return true }
        let link = try XCTUnwrap(editor.items(.link).first)
        XCTAssertEqual(link.accessibilityLabel(), "мир 😀")
        XCTAssertEqual(link.accessibilityValue() as? String, "https://example.com/a")
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertNotNil(activated, "нажатие должно дойти до обработчика перехода")
        // После правки текста элемент устарел: нажатие и рамка недействительны.
        activated = nil
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(link.accessibilityPerformPress())
        XCTAssertNil(activated)
        XCTAssertEqual(link.accessibilityFrame(), .zero)
    }

    func testImageLabelUsesAltThenFileNameAndNeverDataAddress() {
        func image(alt: String, url: String) -> String {
            EditorTextView.Coordinator.imageAccessibilityLabel(MarkdownImage(range: NSRange(location: 0, length: 1), paragraphRange: NSRange(location: 0, length: 1), url: url, alt: alt, title: nil))
        }
        XCTAssertEqual(image(alt: "Кот 😀", url: "media/cat.png"), "Кот 😀")
        XCTAssertEqual(image(alt: "", url: "media/кот.png"), "кот.png")
        XCTAssertEqual(image(alt: "", url: "data:image/png;base64,AAAA"), L10n.tr("图片"))
    }

    // VoiceOver читает видимый текст: скрытые «**» не попадают в `accessibilityString`, а `accessibilityValue` остаётся исходником.
    func testAccessibilityStringHidesMarkersWhileValueStaysSource() async throws {
        let source = "до **жирный** после 😀"
        let editor = makeEditor(source)
        defer { finish(editor) }
        for _ in 0..<30 where editor.ignoredRanges().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        // Каретка далеко от жирного: маркеры скрыты.
        editor.view.setSelectedRange(NSRange(location: editor.shown.length, length: 0))
        let whole = NSRange(location: 0, length: editor.shown.length)
        XCTAssertEqual(editor.view.accessibilityString(for: whole), "до жирный после 😀")
        XCTAssertEqual(editor.view.accessibilityValue() as? String, source)
        // Каретка внутри жирного раскрывает маркеры: читается то, что видно.
        editor.view.setSelectedRange(NSRange(location: editor.shown.range(of: "жирный").location + 2, length: 0))
        XCTAssertEqual(editor.view.accessibilityString(for: whole), source)
    }

    func testAccessibilityStringFallsBackDuringMarkedText() async throws {
        let editor = makeEditor("до **жирный**")
        defer { finish(editor) }
        for _ in 0..<30 where editor.ignoredRanges().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        editor.view.setSelectedRange(NSRange(location: editor.shown.length, length: 0))
        editor.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: editor.shown.length, length: 0))
        defer { editor.view.unmarkText() }
        XCTAssertNil(editor.view.accessibilityReadableText(in: NSRange(location: 0, length: 4)), "во время композиции читается исходный текст")
    }
}

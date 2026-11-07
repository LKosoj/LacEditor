import AppKit
import XCTest
@testable import LacEditor

/// Цвета правок CriticMarkup и комментариев `%%` берутся из span-ов готового разбора контроллера (U5a).
@MainActor
final class MarkdownDecorationColorsTests: XCTestCase {
    /// Версия текста, которую контроллер получает от `currentRevision`; тест двигает её, как это делает ввод.
    private var revision: UInt = 0

    private func makeFixture(source: String, url: URL?, body: (MarkdownPresentationController, NSLayoutManager, NSString, LacTextView) async throws -> Void) async throws {
        revision = 0
        _ = NSApplication.shared
        let document = url.map { EditorDocument(text: source, url: $0, language: .markdown) } ?? EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0,
                          currentRevision: { [unowned self] in self.revision }, textProvider: { storage.string })
        view.string = source
        let installed = XCTestExpectation(description: "parse installed")
        controller.parsedResultDidChange = { installed.fulfill() }
        let result = await XCTWaiter().fulfillment(of: [installed], timeout: 10)
        XCTAssertEqual(result, .completed, "разбор не установился")
        try await body(controller, layout, source as NSString, view)
        withExtendedLifetime(scroll) {}
    }

    private func foreground(_ layout: NSLayoutManager, _ location: Int) -> NSColor? {
        layout.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) as? NSColor
    }

    // Правки CriticMarkup красятся по виду, текст вне правок и код не затрагиваются; кириллица, эмодзи и CRLF не сдвигают диапазоны.
    func testCriticEditsGetKindColorsFromParsedSpans() async throws {
        let source = "Привет 😀 {++новое++} и {--старое--}\r\n\r\n`{++в коде++}` {>>заметка<<} {==важно==}"
        try await makeFixture(source: source, url: nil) { controller, layout, text, _ in
            XCTAssertTrue(controller.reapplyDecorationColors(in: NSRange(location: 0, length: text.length)))
            func color(_ marker: String) -> NSColor? { foreground(layout, text.range(of: marker).location) }
            XCTAssertEqual(color("{++новое"), NSColor.lacCriticInsertText, "вставка")
            XCTAssertEqual(color("{--старое"), NSColor.lacCriticDeleteText, "удаление")
            XCTAssertEqual(color("{>>заметка"), NSColor.lacCriticCommentText, "комментарий")
            XCTAssertEqual(color("{==важно"), NSColor.lacCriticHighlightText, "выделение")
            XCTAssertNotEqual(color("{++в коде"), NSColor.lacCriticInsertText, "в коде правка не оформляется")
            XCTAssertNotEqual(foreground(layout, 0), NSColor.lacCriticInsertText, "обычный текст")
        }
    }

    // `%%` приглушается только в заметке хранилища; в обычном документе это обычный текст.
    func testObsidianCommentColorOnlyInVaultNote() async throws {
        let source = "Текст %%скрытое 中文%% конец"
        let vaultURL = VaultStateStore.defaultRoot(vaultID: UUID()).appendingPathComponent("open/note.md")
        try await makeFixture(source: source, url: vaultURL) { controller, layout, text, _ in
            XCTAssertTrue(controller.reapplyDecorationColors(in: NSRange(location: 0, length: text.length)))
            XCTAssertEqual(foreground(layout, text.range(of: "%%скр").location), NSColor.lacCommentText)
            XCTAssertNotEqual(foreground(layout, 0), NSColor.lacCommentText)
        }
        try await makeFixture(source: source, url: URL(fileURLWithPath: "/tmp/ordinary.md")) { controller, layout, text, _ in
            XCTAssertFalse(controller.reapplyDecorationColors(in: NSRange(location: 0, length: text.length)))
            XCTAssertNotEqual(foreground(layout, text.range(of: "%%скр").location), NSColor.lacCommentText)
        }
    }

    // Сноска идёт в модели раньше основного текста: красятся все правки и комментарий независимо от порядка span-ов.
    func testFootnoteBeforeBodyDoesNotHideLaterEdits() async throws {
        let source = "%%тихо%% Текст {--б--} [^1]\n\n[^1]: {++а++}"
        let vaultURL = VaultStateStore.defaultRoot(vaultID: UUID()).appendingPathComponent("open/note.md")
        try await makeFixture(source: source, url: vaultURL) { controller, layout, text, _ in
            XCTAssertTrue(controller.reapplyDecorationColors(in: NSRange(location: 0, length: text.length)))
            XCTAssertEqual(foreground(layout, text.range(of: "{++а").location), NSColor.lacCriticInsertText, "правка в сноске")
            XCTAssertEqual(foreground(layout, text.range(of: "{--б").location), NSColor.lacCriticDeleteText, "правка в тексте")
            XCTAssertEqual(foreground(layout, text.range(of: "%%тихо").location), NSColor.lacCommentText, "комментарий")
        }
    }

    // Поздний результат: версия текста ушла вперёд, разбор устарел, красить нельзя.
    func testStaleParseDoesNotPaint() async throws {
        try await makeFixture(source: "a {++б++} c", url: nil) { controller, layout, text, _ in
            revision = 1
            XCTAssertFalse(controller.reapplyDecorationColors(in: NSRange(location: 0, length: text.length)))
            XCTAssertNil(foreground(layout, 2))
        }
    }

    // После правки, удалившей {++…++}, разбор устарел и не красит; проход подсветки снимает прежний цвет.
    func testColorIsRemovedAfterEditDeletingCriticEdit() async throws {
        try await makeFixture(source: "a {++б++} c", url: nil) { controller, layout, text, view in
            XCTAssertTrue(controller.reapplyDecorationColors(in: NSRange(location: 0, length: text.length)))
            XCTAssertNotNil(foreground(layout, 2))
            let edit = NSRange(location: 2, length: 7)
            revision += 1
            controller.beforeEdit(range: edit, replacementLength: 0, replacement: "")
            view.replaceCharacters(in: edit, with: "")
            controller.edited(revision: revision)
            let length = view.string.utf16.count
            XCTAssertFalse(controller.reapplyDecorationColors(in: NSRange(location: 0, length: length)), "разбор устарел")
            SyntaxHighlighter.apply(tokens: [], to: layout, range: NSRange(location: 0, length: length))
            XCTAssertNil(foreground(layout, 2), "цвет снят")
        }
    }

    // Во время ввода через IME (marked text) цвета не ставятся.
    func testMarkedTextBlocksPainting() async throws {
        try await makeFixture(source: "a {++б++} c", url: nil) { controller, layout, text, view in
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertFalse(controller.reapplyDecorationColors(in: NSRange(location: 0, length: view.string.utf16.count)))
            XCTAssertNil(foreground(layout, 4))
        }
    }
}

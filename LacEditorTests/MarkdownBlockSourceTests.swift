import AppKit
import AVKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import LacEditor

/// Команда «编辑源代码» в контекстном меню блоков «только просмотр» оформленного Markdown (T8b).
/// Стенд окна и поиск точки по картинке — как в `MarkdownWidthTests.testDiagramContextMenuCopiesCurrentImageAndRejectsStaleSelection`.
@MainActor
final class MarkdownBlockSourceTests: XCTestCase {
    private struct Host: View {
        let document: EditorDocument
        let sessions: EditorSessionStore
        var body: some View {
            EditorTextView(document: document, sessionStore: sessions, fontSize: 14, lineSpacing: 4,
                indentationStyle: .spaces, tabWidth: 4, wordWrap: true, showsLineNumbers: true,
                topInset: 8, isActive: true, requestTextTransformation: { _ in })
        }
    }

    @MainActor
    private struct Stand {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let layout: FoldLayoutManager
        let window: NSWindow

        func event(at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }

        /// Контекстное меню текстового вида в точке (координаты текстового вида).
        func menu(at point: NSPoint) throws -> NSMenu { try XCTUnwrap(view.menu(for: event(at: point))) }

        func editItem(in menu: NSMenu?) -> NSMenuItem? { menu?.items.first { $0.title == L10n.tr("编辑源代码") } }

        func perform(_ item: NSMenuItem) -> Bool { NSApp.sendAction(item.action!, to: item.target, from: item) }

        func center(of child: NSView) -> NSPoint { NSPoint(x: child.frame.midX, y: child.frame.midY) }
    }

    private func show(_ window: NSWindow, _ rootView: some View) {
        let size = window.contentLayoutRect.size
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setContentSize(size)
        window.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController?.view.autoresizingMask = [.width, .height]
        window.contentViewController?.view.isHidden = false
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Окно с редактором; курсор ставится в конец текста, чтобы ничего не было раскрыто.
    private func open(_ source: String, url: URL? = nil, formatted: Bool = true) async throws -> Stand {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, url: url, language: .markdown)
        document.isMarkdownFormatted = formatted
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        show(window, Host(document: document, sessions: sessions))
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView != nil && coordinator.foldLayoutManager != nil }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        return Stand(document: document, coordinator: coordinator, view: view, layout: layout, window: window)
    }

    private func close(_ stand: Stand) { stand.coordinator.updateActivity(false); stand.window.close() }

    /// Точка текстового вида над изображением или диаграммой, которая начинается в `location`.
    private func imagePoint(_ stand: Stand, location: Int) async -> NSPoint? {
        guard let container = stand.view.textContainer else { return nil }
        var hit: NSPoint?
        _ = await waitFor {
            stand.layout.ensureLayout(for: container)
            for y in stride(from: 10, through: 300, by: 10) {
                for x in stride(from: 10, through: 500, by: 20) {
                    let point = NSPoint(x: CGFloat(x), y: CGFloat(y))
                    if stand.layout.markdownImageLocation(at: point, in: container) == location {
                        hit = NSPoint(x: point.x + stand.view.textContainerOrigin.x, y: point.y + stand.view.textContainerOrigin.y)
                        return true
                    }
                }
            }
            return false
        }
        return hit
    }

    private func folder(with files: [String: Data]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    private let png = Data(base64Encoded: MarkdownBaselineDocuments.tinyPNGBase64)!

    private func wav() -> Data {
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(836); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(800); sound.append(Data(repeating: 128, count: 800))
        return sound
    }

    // Изображение: раскрыть исходник на месте нельзя, поэтому команда переключает документ в исходный вид с кареткой в начале.
    func testImageContextMenuEditSourceSwitchesToSourceModeWithCaretAtImage() async throws {
        let directory = try folder(with: ["pic.png": png])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "前言 🙂\r\n\r\n![картинка 图](pic.png)\r\n\r\n结尾\r\n"
        let stand = try await open(source, url: directory.appendingPathComponent("note.md"))
        defer { close(stand) }
        let start = (source as NSString).range(of: "![").location
        let found = await imagePoint(stand, location: start)
        let point = try XCTUnwrap(found)
        let item = try XCTUnwrap(stand.editItem(in: try stand.menu(at: point)))
        XCTAssertTrue(stand.perform(item))
        XCTAssertFalse(stand.document.isMarkdownFormatted)
        XCTAssertEqual(stand.view.selectedRange(), NSRange(location: start, length: 0))
        XCTAssertEqual(stand.view.string, source)
        XCTAssertEqual(stand.document.synchronizedSnapshot().text, source)
        XCTAssertFalse(stand.document.isDirty)
    }

    // В режиме чтения пункта нет, а меню, снятое до правки текста, после правки ничего не делает.
    func testImageEditSourceIsAbsentInReadingModeAndRejectedWhenStale() async throws {
        let directory = try folder(with: ["pic.png": png])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "前言 🙂\r\n\r\n![картинка](pic.png)\r\n\r\n结尾\r\n"
        let stand = try await open(source, url: directory.appendingPathComponent("note.md"))
        defer { close(stand) }
        let start = (source as NSString).range(of: "![").location
        let found = await imagePoint(stand, location: start)
        let point = try XCTUnwrap(found)
        let item = try XCTUnwrap(stand.editItem(in: try stand.menu(at: point)))
        stand.view.insertText("я", replacementRange: NSRange(location: 0, length: 0))
        // Вставка в начало сдвигает картинку: дальше её ищем по новому месту.
        let shifted = start + ("я" as NSString).length
        let selection = stand.view.selectedRange()
        XCTAssertTrue(stand.perform(item))
        XCTAssertTrue(stand.document.isMarkdownFormatted, "устаревший пункт не переключает вид")
        XCTAssertEqual(stand.view.selectedRange(), selection)
        // Режим чтения: картинка заново находится (раскладка могла сдвинуться), и только потом проверяется отсутствие пункта.
        stand.document.setReadingMode(true)
        let readingFound = await imagePoint(stand, location: shifted)
        let readingPoint = try XCTUnwrap(readingFound, "картинка должна остаться видимой в режиме чтения")
        XCTAssertNil(stand.editItem(in: try stand.menu(at: readingPoint)), "в режиме чтения пункта нет")
        stand.document.setReadingMode(false)
        let backFound = await imagePoint(stand, location: shifted)
        let backPoint = try XCTUnwrap(backFound)
        let back = await waitFor { stand.editItem(in: try? stand.menu(at: backPoint)) != nil }
        XCTAssertTrue(back, "после выхода из режима чтения пункт снова есть")
    }

    // Два блока подряд: после команды на первом (выделение «непрозрачное») команда на втором тоже раскрывает его, вью снимается.
    func testEditSourceRevealsTwoHTMLBlocksOneAfterAnother() async throws {
        let first = "<div><p>первый 中文</p></div>", second = "<div><p>второй 😀</p></div>"
        let source = "前言\r\n\r\n\(first)\r\n\r\n\(second)\r\n\r\n结尾\r\n"
        let stand = try await open(source)
        defer { close(stand) }
        func views() -> [MarkdownHTMLBlockView] { stand.view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.sorted { $0.frame.minY < $1.frame.minY } }
        let shown = await waitFor { views().count == 2 }
        XCTAssertTrue(shown)
        let one = views()[0], two = views()[1]
        let firstItem = try XCTUnwrap(stand.editItem(in: try stand.menu(at: stand.center(of: one))))
        XCTAssertTrue(stand.perform(firstItem))
        XCTAssertEqual(stand.view.selectedRange(), (source as NSString).range(of: first))
        let firstRemoved = await waitFor { one.superview == nil }
        XCTAssertTrue(firstRemoved)
        XCTAssertNotNil(two.superview, "второй блок остаётся оформленным")
        let secondItem = try XCTUnwrap(stand.editItem(in: try stand.menu(at: stand.center(of: two))))
        XCTAssertTrue(stand.perform(secondItem))
        XCTAssertEqual(stand.view.selectedRange(), (source as NSString).range(of: second))
        let secondRemoved = await waitFor { two.superview == nil }
        XCTAssertTrue(secondRemoved, "вью второго блока снята, виден исходный текст")
        XCTAssertEqual(stand.view.string, source)
    }

    // HTML-блок: пункт выделяет весь блок, живая вью снимается, текст не меняется.
    func testHTMLBlockContextMenuEditSourceSelectsWholeBlock() async throws {
        let block = "<div><p>中文 😀</p><p>вторая</p></div>"
        let source = "前言\r\n\r\n\(block)\r\n\r\n结尾\r\n"
        let stand = try await open(source)
        defer { close(stand) }
        let shown = await waitFor { stand.view.subviews.contains { $0 is MarkdownHTMLBlockView } }
        XCTAssertTrue(shown)
        let html = try XCTUnwrap(stand.view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first)
        let item = try XCTUnwrap(stand.editItem(in: try stand.menu(at: stand.center(of: html))))
        XCTAssertTrue(stand.perform(item))
        XCTAssertEqual(stand.view.selectedRange(), (source as NSString).range(of: block))
        let removed = await waitFor { html.superview == nil }
        XCTAssertTrue(removed)
        XCTAssertEqual(stand.view.string, source)
        XCTAssertFalse(stand.document.isDirty)
    }

    func testDetailsContextMenuEditSourceSelectsWholeBlock() async throws {
        let block = "<details>\n<summary>摘要</summary>\nтело 😀\n</details>"
        let source = "前言\n\n\(block)\n\n结尾\n"
        let stand = try await open(source)
        defer { close(stand) }
        func details() -> NSView? { stand.view.subviews.first { String(describing: type(of: $0)).contains("MarkdownDetailsView") } }
        let shown = await waitFor { details() != nil }
        XCTAssertTrue(shown)
        let view = try XCTUnwrap(details())
        let item = try XCTUnwrap(stand.editItem(in: try stand.menu(at: stand.center(of: view))))
        XCTAssertTrue(stand.perform(item))
        XCTAssertEqual(stand.view.selectedRange(), (source as NSString).range(of: block))
        let removed = await waitFor { view.superview == nil }
        XCTAssertTrue(removed)
        XCTAssertEqual(stand.view.string, source)
    }

    // Меню плеера берётся у самого AVPlayerView: правый клик по нему в тесте не воспроизвести.
    func testPlayerContextMenuEditSourceSelectsWholeBlock() async throws {
        let directory = try folder(with: ["声音.wav": wav()])
        defer { try? FileManager.default.removeItem(at: directory) }
        let block = "<audio controls>\n<source src='声音.wav'>\n</audio>"
        let source = "前言\n\n\(block)\n\n结尾\n"
        let stand = try await open(source, url: directory.appendingPathComponent("note.md"))
        defer { close(stand) }
        let shown = await waitFor { stand.view.subviews.contains { $0 is AVPlayerView } }
        XCTAssertTrue(shown)
        let player = try XCTUnwrap(stand.view.subviews.compactMap { $0 as? AVPlayerView }.first)
        let menu = player.menu(for: try stand.event(at: stand.center(of: player)))
        let item = try XCTUnwrap(stand.editItem(in: menu))
        XCTAssertTrue(stand.perform(item))
        XCTAssertEqual(stand.view.selectedRange(), (source as NSString).range(of: block))
        let removed = await waitFor { player.superview == nil }
        XCTAssertTrue(removed)
        XCTAssertEqual(stand.view.string, source)
    }

    // Меню WKWebView дополняется в `willOpenMenu`, поэтому вызываем его напрямую.
    func testIframeContextMenuEditSourceSelectsWholeBlock() async throws {
        let block = "<iframe src=\"http://127.0.0.1:9/test\" width=\"50%\" height=\"240\" title=\"Example\"></iframe>"
        let source = "前言\n\n\(block)\n\n结尾\n"
        let stand = try await open(source)
        defer { close(stand) }
        let shown = await waitFor { stand.view.subviews.contains { $0 is WKWebView } }
        XCTAssertTrue(shown)
        let web = try XCTUnwrap(stand.view.subviews.compactMap { $0 as? WKWebView }.first)
        let menu = NSMenu()
        web.willOpenMenu(menu, with: try stand.event(at: stand.center(of: web)))
        let item = try XCTUnwrap(stand.editItem(in: menu))
        XCTAssertTrue(stand.perform(item))
        XCTAssertEqual(stand.view.selectedRange(), (source as NSString).range(of: block))
        XCTAssertEqual(stand.view.string, source)
    }

    // PDF поддерживается только из `data:`; документ собирается из настоящей страницы.
    func testPDFContextMenuEditSourceSelectsWholeBlock() async throws {
        let image = try XCTUnwrap(NSImage(data: png))
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let data = try XCTUnwrap(pdf.dataRepresentation())
        let block = "<embed src=\"data:application/pdf;base64,\(data.base64EncodedString())\" type=\"application/pdf\">"
        let source = "前言\n\n\(block)\n\n结尾\n"
        let stand = try await open(source)
        defer { close(stand) }
        let shown = await waitFor { stand.view.subviews.contains { $0 is PDFView } }
        XCTAssertTrue(shown)
        let pdfView = try XCTUnwrap(stand.view.subviews.compactMap { $0 as? PDFView }.first)
        let menu = pdfView.menu(for: try stand.event(at: stand.center(of: pdfView)))
        let item = try XCTUnwrap(stand.editItem(in: menu))
        XCTAssertTrue(stand.perform(item))
        let selected = stand.view.selectedRange()
        XCTAssertEqual(selected.location, (stand.view.string as NSString).range(of: "<embed").location)
        let removed = await waitFor { pdfView.superview == nil }
        XCTAssertTrue(removed)
    }

    // Формула, диаграмма, ruby, код и встраивание заметки правятся на месте или раскрываются кликом: пункта нет нигде.
    func testEditableBlocksDoNotOfferEditSource() async throws {
        let control = "<div><p>контроль 中文</p></div>"
        let svg = "строка <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg> конец"
        let source = "\(control)\n\n\(svg)\n\n前言 $x^2$ <ruby>漢<rt>kan</rt></ruby>\n\n$$\nE=mc^2\n$$\n\n```mermaid\nflowchart TD\nA[Старт] --> B[Конец]\n```\n\n```swift\nlet x = 1\n```\n\n![[заметка]]\n\n结尾\n"
        let stand = try await open(source)
        defer { close(stand) }
        let location = (source as NSString).range(of: "```mermaid").location
        let found = await imagePoint(stand, location: location)
        XCTAssertNotNil(found, "диаграмма должна быть показана, иначе проверка ничего не доказывает")
        // Положительный контроль: HTML-блок в том же документе даёт пункт, значит сетка способна упасть.
        let controlShown = await waitFor { stand.view.subviews.contains { $0 is MarkdownHTMLBlockView } }
        XCTAssertTrue(controlShown)
        let controlView = try XCTUnwrap(stand.view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first)
        let controlPoint = stand.center(of: controlView)
        XCTAssertTrue(stand.view.diagramMenuHandler?(controlPoint).contains { $0.title == L10n.tr("编辑源代码") } == true)
        for y in stride(from: 5, through: 395, by: 10) {
            for x in stride(from: 10, through: 590, by: 20) {
                let point = NSPoint(x: x, y: y)
                if controlView.frame.contains(point) { continue }
                let titles = stand.view.diagramMenuHandler?(point).map(\.title) ?? []
                XCTAssertFalse(titles.contains(L10n.tr("编辑源代码")), "x=\(x) y=\(y)")
            }
        }
    }

    // Уровень контроллера: блок находится только под мышью, а снятая раньше правки команда устаревает.
    func testControllerFindsHTMLBlockAndRejectsStaleSource() async throws {
        let fixture = MarkdownHTMLBlockProofTests.InsertShiftFixture("intro words\n\n<div><p>中文 😀</p><p>second</p></div>\n\nend words\n", selecting: "end words")
        defer { fixture.close() }
        try await fixture.wait { !fixture.htmlViews().isEmpty }
        let html = try XCTUnwrap(fixture.htmlViews().first)
        XCTAssertNil(fixture.controller.blockSource(at: NSPoint(x: 2, y: 2)))
        let source = try XCTUnwrap(fixture.controller.blockSource(at: NSPoint(x: html.frame.midX, y: html.frame.midY)))
        XCTAssertEqual(source.action, .reveal)
        XCTAssertEqual(source.range, (fixture.storage.string as NSString).range(of: "<div><p>中文 😀</p><p>second</p></div>"))
        XCTAssertTrue(fixture.controller.isCurrentBlockSource(source))
        fixture.type(after: "intro wor")
        XCTAssertFalse(fixture.controller.isCurrentBlockSource(source))
    }
}

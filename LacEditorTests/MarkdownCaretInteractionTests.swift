import AppKit
import XCTest
@testable import LacEditor

/// Курсор, выделение и раскрытие маркеров: настоящие события мыши и команды движения на стенде координатора.
/// Стенд и ожидание разбора - как в `MarkdownEditTransactionTests`, клик с отпусканием - как в `MarkdownLinkNavigationInteractionTests`.
@MainActor
final class MarkdownCaretInteractionTests: XCTestCase {
    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let layout: FoldLayoutManager
        let container: NSTextContainer
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }
        var selection: NSRange { view.selectedRange() }

        func isHidden(_ location: Int) -> Bool { layout.isMarkdownMarkerHidden(at: location) }

        /// Точка в координатах вида: внутри глифа символа `character`, доля `fraction` от левого края по ширине.
        func point(of character: Int, fraction: CGFloat = 0.5) -> NSPoint {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: character)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return NSPoint(x: rect.minX + rect.width * fraction + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        }

        func ignoredRanges() -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: shown.length)).map(\.rangeValue)
        }
    }

    private func makeEditor(_ source: String, formatted: Bool = true, reading: Bool = false) -> Editor {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = formatted
        if reading { document.setReadingMode(true) }
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 1_000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_000), textContainer: container)
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
        return Editor(document: document, coordinator: coordinator, view: view, layout: layout, container: container, window: window)
    }

    private func waitForParse(_ editor: Editor) async throws {
        for _ in 0..<30 where editor.ignoredRanges().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(editor.ignoredRanges().isEmpty, "разбор Markdown не успел завершиться")
        editor.layout.ensureLayout(for: editor.container)
    }

    /// Клик (или протяжка) с отпусканием кнопки: цикл отслеживания внутри `mouseDown` блокирует вызов до `leftMouseUp`,
    /// поэтому отпускание кладётся в очередь наблюдателем run loop. `during` вызывается, пока кнопка ещё нажата.
    private func click(_ editor: Editor, at point: NSPoint, clickCount: Int = 1, dragTo: NSPoint? = nil, during: (() -> Void)? = nil) throws {
        let view = editor.view
        let number = editor.window.windowNumber
        func event(_ type: NSEvent.EventType, _ location: NSPoint, pressure: Float) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(location, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 1,
                clickCount: clickCount, pressure: pressure))
        }
        let down = try event(.leftMouseDown, point, pressure: 1)
        let dragged = try dragTo.map { try event(.leftMouseDragged, $0, pressure: 1) }
        let up = try event(.leftMouseUp, dragTo ?? point, pressure: 0)
        let mode = CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
        var step = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            step += 1
            if step == 1, let dragged {
                NSApp.postEvent(dragged, atStart: false)
                return
            }
            guard step <= 2 else { return }
            during?()
            NSApp.postEvent(up, atStart: false)
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode) }
        defer {
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, mode)
                CFRunLoopObserverInvalidate(observer)
            }
        }
        view.mouseDown(with: down)
    }

    private let boldSource = "**жирный** текст\r\nвторая строка 😀\r\n"

    private func finish(_ editor: Editor) { editor.coordinator.updateActivity(false); editor.window.close() }

    // MARK: Клик

    // Клик слева от первой буквы жирного слова: каретка снаружи `**` (и маркеры раскрываются).
    func testClickLeftOfBoldAtLineStartPlacesCaretBeforeMarkers() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        XCTAssertTrue(editor.isHidden(0))
        try click(editor, at: editor.point(of: 2, fraction: 0.25))
        XCTAssertEqual(editor.selection, NSRange(location: 0, length: 0))
        XCTAssertFalse(editor.isHidden(0), "каретка у границы раскрыла маркеры")
    }

    func testClickRightOfBoldAtLineEndPlacesCaretAfterClosingMarkers() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        try click(editor, at: editor.point(of: 7, fraction: 0.75))
        XCTAssertEqual(editor.selection, NSRange(location: 10, length: 0))
    }

    // Блочный префикс заголовка не inline-элемент: каретка после `## `, чтобы ввод первого символа не ломал заголовок.
    func testClickLeftOfHeadingTextPlacesCaretAfterPrefix() async throws {
        let editor = makeEditor("## Заголовок 中文\r\nтекст\r\n")
        defer { finish(editor) }
        try await waitForParse(editor)
        try click(editor, at: editor.point(of: 3, fraction: 0.25))
        XCTAssertEqual(editor.selection, NSRange(location: 3, length: 0))
    }

    func testClickInMiddleOfPlainWordIsNotMoved() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        let target = editor.shown.range(of: "строка").location
        try click(editor, at: editor.point(of: target, fraction: 0.25))
        XCTAssertEqual(editor.selection, NSRange(location: target, length: 0))
    }

    // MARK: Пока кнопка зажата

    func testDoesNotRevealWhileMouseIsDown() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        var hiddenDuringClick: Bool?
        try click(editor, at: editor.point(of: 2, fraction: 0.25)) { hiddenDuringClick = editor.isHidden(0) }
        XCTAssertEqual(hiddenDuringClick, true, "раскладка не должна меняться под рукой пользователя")
        XCTAssertFalse(editor.isHidden(0), "после отпускания маркеры раскрыты")
    }

    func testDragSelectionKeepsLayoutUntilMouseUp() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        let text = editor.shown.range(of: "текст")
        var hiddenDuringDrag: Bool?
        var yDuringDrag: CGFloat?
        let before = editor.point(of: text.location).y
        try click(editor, at: editor.point(of: 2, fraction: 0.25), dragTo: editor.point(of: text.location, fraction: 0.75)) {
            hiddenDuringDrag = editor.isHidden(0)
            yDuringDrag = editor.point(of: text.location).y
        }
        XCTAssertEqual(hiddenDuringDrag, true)
        XCTAssertEqual(yDuringDrag ?? -1, before, accuracy: 0.5, "строки не сдвигаются при протяжке")
        XCTAssertGreaterThan(editor.selection.length, 0)
        XCTAssertFalse(editor.isHidden(0), "после отпускания выделение задело элемент и раскрыло его")
    }

    // MARK: Двойной и тройной клик

    func testDoubleClickSelectsWordWithoutMarkersAndRevealsElement() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        try click(editor, at: editor.point(of: 4), clickCount: 2)
        XCTAssertEqual(editor.selection, editor.shown.range(of: "жирный"))
        XCTAssertFalse(editor.isHidden(0))
    }

    func testTripleClickSelectsWholeParagraph() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        try click(editor, at: editor.point(of: 4), clickCount: 3)
        XCTAssertEqual(editor.selection, editor.shown.paragraphRange(for: NSRange(location: 0, length: 0)))
    }

    // MARK: Клавиши

    // Стрелка вправо идёт по раскрывающимся маркерам шаг в шаг: привязка её не трогает.
    func testArrowRightStepsThroughRevealedMarkers() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        for expected in 1...4 {
            editor.view.moveRight(nil)
            XCTAssertEqual(editor.selection, NSRange(location: expected, length: 0), "шаг \(expected)")
            XCTAssertFalse(editor.isHidden(0), "шаг \(expected): элемент раскрыт")
        }
    }

    func testArrowLeftEntersBoldFromOutside() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 11, length: 0))
        editor.view.moveLeft(nil)
        XCTAssertEqual(editor.selection, NSRange(location: 10, length: 0))
        editor.view.moveLeft(nil)
        XCTAssertEqual(editor.selection, NSRange(location: 9, length: 0), "каретка идёт по видимым маркерам внутрь")
    }

    func testProgrammaticSelectionIsNotSnapped() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 0))
        editor.view.setSelectedRange(NSRange(location: 2, length: 6))
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 6))
    }

    // ↓ в строку, начинающуюся с `**`, оставляет каретку снаружи маркеров.
    func testArrowDownSettlesCaretOutsideHiddenMarkers() async throws {
        let source = "первая строка\r\n**жирный** тест\r\n## Заг\r\nконец\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let bold = editor.shown.range(of: "**жирный**").location
        let heading = editor.shown.range(of: "## ").location
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.moveDown(nil)
        XCTAssertEqual(editor.selection, NSRange(location: bold, length: 0), "строка с жирным в начале")
        editor.view.moveDown(nil)
        XCTAssertEqual(editor.selection, NSRange(location: heading + 3, length: 0), "строка заголовка: после префикса")
    }

    func testPageDownDoesNotBreakSelection() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.pageDown(nil)
        XCTAssertLessThanOrEqual(NSMaxRange(editor.selection), editor.shown.length)
        XCTAssertEqual(editor.selection.length, 0)
    }

    // MARK: Удаление у маркеров: что видно, то и удаляется

    func testBackspaceAfterClosingMarkerDeletesOneVisibleCharacter() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 10, length: 0))
        editor.view.deleteBackward(nil)
        XCTAssertEqual(editor.shown.substring(to: 15) as String, "**жирный* текст")
    }

    func testDeleteBeforeOpeningMarkerDeletesOneVisibleCharacter() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.deleteForward(nil)
        XCTAssertEqual(editor.shown.substring(to: 15) as String, "*жирный** текст")
    }

    func testBackspaceAtHeadingContentStartRemovesPrefixSpace() async throws {
        let editor = makeEditor("## Заголовок\r\nтекст\r\n")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 3, length: 0))
        editor.view.deleteBackward(nil)
        XCTAssertTrue((editor.shown as String).hasPrefix("##Заголовок"))
    }

    // MARK: Режимы без привязки

    func testReadingModeDoesNotRevealOrSnap() async throws {
        let editor = makeEditor(boldSource, reading: true)
        defer { finish(editor) }
        try await waitForParse(editor)
        XCTAssertTrue(editor.isHidden(0))
        try click(editor, at: editor.point(of: 2, fraction: 0.25))
        XCTAssertNotEqual(editor.selection, NSRange(location: 0, length: 0), "выделение для копирования точное")
        XCTAssertTrue(editor.isHidden(0), "в режиме чтения ничего не раскрывается")
    }

    // Сначала оформленный режим с готовой презентацией (привязка есть), потом source: без защиты isMarkdownFormatted клик привязался бы.
    func testSourceModeDoesNotSnap() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        XCTAssertTrue(editor.isHidden(0), "в оформленном режиме маркеры скрыты, привязка возможна")
        editor.document.isMarkdownFormatted = false
        try click(editor, at: editor.point(of: 2, fraction: 0.25))
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 0))
    }

    // MARK: Без привязки: marked text, Home/End

    // Пока идёт ввод через IME (marked text), ↓ не привязывает каретку.
    func testMarkedTextSkipsSnap() async throws {
        let source = "первая строка\r\n## Заг\r\nконец\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let heading = editor.shown.range(of: "## ").location
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.moveDown(nil)
        XCTAssertEqual(editor.selection, NSRange(location: heading + 3, length: 0), "без marked text привязка есть")
        editor.view.setSelectedRange(NSRange(location: editor.shown.length, length: 0))
        editor.view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: editor.shown.length, length: 0))
        XCTAssertTrue(editor.view.hasMarkedText())
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.moveDown(nil)
        XCTAssertNotEqual(editor.selection, NSRange(location: heading + 3, length: 0), "при marked text привязки нет")
    }

    // Home не привязывается: каретка встаёт в начало строки, а не после `## `.
    func testHomeKeepsCaretAtLineStart() async throws {
        let source = "первая строка\r\n## Заг\r\nконец\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let heading = editor.shown.range(of: "## ").location
        editor.view.setSelectedRange(NSRange(location: heading + 5, length: 0))
        editor.view.moveToBeginningOfLine(nil)
        XCTAssertEqual(editor.selection, NSRange(location: heading, length: 0))
    }

    // End не привязывается: каретка в конце строки, за закрывающими `**`.
    func testEndKeepsCaretAtLineEnd() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 4, length: 0))
        editor.view.moveToEndOfLine(nil)
        let lineEnd = editor.shown.range(of: "текст").location + 5
        XCTAssertEqual(editor.selection, NSRange(location: lineEnd, length: 0))
    }

    // MARK: Клики, на которые привязка не влияет

    func testClickInsideItalicWordIsNotMoved() async throws {
        let source = "текст *курсив* тут\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let target = editor.shown.range(of: "курсив").location + 2
        try click(editor, at: editor.point(of: target, fraction: 0.25))
        XCTAssertEqual(editor.selection, NSRange(location: target, length: 0))
        XCTAssertFalse(editor.isHidden(editor.shown.range(of: "*").location), "элемент раскрыт после отпускания")
    }

    func testClickInsideLinkTextIsNotMoved() async throws {
        let source = "см. [ссылка](https://example.com) тут\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let target = editor.shown.range(of: "ссылка").location + 3
        try click(editor, at: editor.point(of: target, fraction: 0.25))
        XCTAssertEqual(editor.selection, NSRange(location: target, length: 0))
    }

    func testClickOnTaskCheckboxTogglesItWithoutSnap() async throws {
        let source = "- [ ] задача\r\nтекст\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let box = editor.shown.range(of: "[ ]").location
        try click(editor, at: editor.point(of: box + 1))
        XCTAssertTrue(editor.view.string.contains("- [x]"), "чекбокс переключён как до T3")
    }

    // MARK: Отложенная установка разбора

    /// Ждёт условие, прокручивая run loop (для кода внутри цикла отслеживания мыши).
    private func spin(seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end, !condition() {
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    // Новый разбор, пришедший при зажатой кнопке, не меняет раскладку; после отпускания применяется.
    func testDeferredInstallAppliesAfterMouseUp() async throws {
        let editor = makeEditor("первая строка\r\n")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: editor.shown.length, length: 0))
        editor.view.insertText("**новый** хвост", replacementRange: editor.selection)
        let bold = editor.shown.range(of: "**новый**").location
        var hiddenDuringClick: Bool?
        try click(editor, at: editor.point(of: 2, fraction: 0.25)) {
            self.spin(seconds: 1.0) { editor.isHidden(bold) }
            hiddenDuringClick = editor.isHidden(bold)
        }
        XCTAssertEqual(hiddenDuringClick, false, "пока кнопка зажата, новый разбор не установлен")
        for _ in 0..<30 where !editor.isHidden(bold) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(editor.isHidden(bold), "после отпускания разбор применён")
    }

    // Правка при зажатой кнопке отменяет отложенный результат: устаревший разбор (с `**`) не ставится на текст без маркеров.
    func testDeferredInstallIsDroppedWhenRevisionChanges() async throws {
        let editor = makeEditor("первая строка\r\n")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: editor.shown.length, length: 0))
        editor.view.insertText("**новый**", replacementRange: editor.selection)
        let bold = editor.shown.range(of: "**новый**")
        try click(editor, at: editor.point(of: 2, fraction: 0.25)) {
            self.spin(seconds: 1.0) { editor.isHidden(bold.location) }
            // Маркеры заменяются буквами той же длины: устаревший разбор совпал бы по длине и скрыл бы их.
            editor.view.insertText("ххновыйхх", replacementRange: bold)
        }
        let plain = editor.shown.range(of: "ххновыйхх")
        XCTAssertEqual(plain.length, bold.length)
        XCTAssertFalse(editor.shown.contains("**"))
        for offset in 0..<plain.length {
            XCTAssertFalse(editor.isHidden(plain.location + offset), "устаревший разбор скрыл бы символ \(offset) сразу после отпускания")
        }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)) }
        for offset in 0..<plain.length {
            XCTAssertFalse(editor.isHidden(plain.location + offset), "и позже: символ \(offset)")
        }
    }

    // Клик по показанной картинке: каретка не уходит внутрь скрытого исходника (начало или конец `![](…)`), как до T3.
    func testClickOnShownImageKeepsCaretOutsideHiddenSource() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let source = "до\r\n\r\n![a](data:image/png;base64,\(png))\r\n\r\nпосле\r\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let image = editor.shown.range(of: "![a](")
        let imageSource = NSRange(location: image.location, length: editor.shown.range(of: ")\r\n\r\nпосле").location + 1 - image.location)
        for _ in 0..<50 where (editor.layout.markdownListsSnapshot["images"] ?? []).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse((editor.layout.markdownListsSnapshot["images"] ?? []).isEmpty, "картинка установлена")
        editor.layout.ensureLayout(for: editor.container)
        let rect = editor.layout.lineFragmentRect(forGlyphAt: editor.layout.glyphIndexForCharacter(at: image.location), effectiveRange: nil)
        let point = NSPoint(x: rect.minX + editor.container.lineFragmentPadding + 0.5 + editor.view.textContainerOrigin.x,
                            y: rect.minY + 0.5 + editor.view.textContainerOrigin.y)
        try click(editor, at: point)
        let caret = editor.selection
        XCTAssertEqual(caret.length, 0)
        XCTAssertFalse(NSLocationInRange(caret.location, NSRange(location: imageSource.location + 1, length: imageSource.length - 1)),
                      "каретка \(caret) внутри скрытого исходника картинки \(imageSource)")
        XCTAssertEqual(editor.view.string, source)
    }

    // MARK: Доступность

    // VoiceOver получает полный исходник и ту же каретку, что и редактор (чтение «звёздочек» - предмет T9).
    func testAccessibilitySelectedRangeMatchesSnappedCaretAndValueStaysSource() async throws {
        let editor = makeEditor(boldSource)
        defer { finish(editor) }
        try await waitForParse(editor)
        try click(editor, at: editor.point(of: 2, fraction: 0.25))
        XCTAssertEqual(editor.view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.view.accessibilityValue(), editor.view.string)
    }
}

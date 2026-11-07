import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownTableNavigationTests: XCTestCase {
    // Таблица, прервавшая абзац (ext#16): в таблицу входят только строки таблицы, абзац остаётся текстом.
    func testTableInterruptingParagraphKeepsOnlyTableLines() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["123", "| a | b |", "| - | - |", "| d | e |", "", "456", ""].joined(separator: newline)
            let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(source).tables.first, "newline \(newline.debugDescription)")
            let text = source as NSString
            XCTAssertEqual(table.range.location, text.range(of: "| a").location)
            XCTAssertEqual(table.alignments.count, 2)
            XCTAssertEqual(table.rows.count, 2)
            let d = text.range(of: "d")
            let edit = try XCTUnwrap(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: d.location, length: 0), command: .insertRowAfter))
            let result = text.replacingCharacters(in: edit.range, with: edit.replacement)
            XCTAssertTrue(result.hasPrefix("123" + newline + "| a | b |"), "абзац над таблицей не тронут")
            XCTAssertTrue(result.contains(newline + newline + "456" + newline), "абзац под таблицей не тронут")
            XCTAssertNil(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: 1, length: 0), command: .insertRowAfter),
                         "каретка в абзаце над таблицей не команда таблицы")
        }
    }

    // По GFM строка сразу под таблицей без пустой строки — ещё одна строка таблицы.
    func testLineRightBelowTableBelongsToTable() throws {
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse("123\n| a | b |\n| - | - |\n| d | e |\n456\n").tables.first)
        XCTAssertEqual(table.rows.count, 3)
    }

    // Таблица после абзаца в пункте списка (префиксы `- ` и `  ` различаются) не поддерживается: ограничение, не регрессия.
    func testTableInterruptingParagraphInQuote() throws {
        for source in ["> 123\n> | a | b |\n> | - | - |\n> | d | e |\n"] {
            let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(source).tables.first, source)
            XCTAssertEqual(table.rows.count, 2, source)
            XCTAssertEqual((source as NSString).substring(with: table.rows[0].cells[0].range).trimmingCharacters(in: .whitespaces), "a", source)
        }
    }

    // Команды таблицы не выравнивают соседние ячейки пробелами.
    func testCommandDoesNotPadOtherCells() throws {
        let source = "| 中文 | b |\n| - | - |\n| длинное слово | 😀 |"
        let text = source as NSString
        let edit = try XCTUnwrap(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: text.range(of: "b").location, length: 0), command: .insertRowAfter))
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertTrue(result.hasPrefix(source), "прежние строки не меняются")
    }

    func testCellContainingLocationHandlesPipesSeparatorAndNonASCII() throws {
        let source = "| 中文 | 😀 b |\n| --- | --- |\n| x | y |" as NSString
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(source as String).tables.first)
        let header = table.rows[0].cells
        XCTAssertEqual(table.cell(containing: header[1].range.location + 1, in: source)?.column, 1)
        let middlePipe = source.range(of: "|", range: NSRange(location: 1, length: source.length - 1)).location
        XCTAssertEqual(table.cell(containing: middlePipe, in: source)?.column, 1, "на | между ячейками — следующая")
        let separator = source.range(of: "---")
        XCTAssertEqual(table.cell(containing: separator.location, in: source)?.column, 0)
    }

    func testDisplayRangeForRawKeepsCaretAndWidensSelection() {
        let raw = "a\\|b"
        let projection = MarkdownTableCellEditor.projection(raw)
        let caret = MarkdownTableCellEditor.displayRange(forRaw: NSRange(location: 3, length: 0), in: projection)
        XCTAssertEqual(caret.length, 0)
        let all = MarkdownTableCellEditor.displayRange(forRaw: NSRange(location: 0, length: 4), in: projection)
        XCTAssertEqual(all, NSRange(location: 0, length: 3))
    }

    // Меню правого клика и кнопки края: пункты по месту ячейки, действие над кликнутой ячейкой и один undo.
    func testTableMenuAndEdgeButtonAddRowWithOneUndo() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| 中 | 😀 |\n"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); window.close() }
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        var items: [NSMenuItem] = []
        for _ in 0..<30 where items.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            let frame = try XCTUnwrap(layout.markdownTableFrame(for: cell, in: container))
            let point = NSPoint(x: frame.midX + view.textContainerOrigin.x, y: frame.midY + view.textContainerOrigin.y)
            items = view.tableMenuHandler?(point) ?? []
        }
        let submenu = try XCTUnwrap(items.first?.submenu, "подменю таблицы есть")
        let titles = submenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertTrue(titles.contains(L10n.tr("在下方插入行")))
        XCTAssertEqual(submenu.items.first { $0.title == L10n.tr("左移列") }?.isEnabled, false, "первый столбец")
        let insert = try XCTUnwrap(submenu.items.first { $0.title == L10n.tr("在下方插入行") })
        // Для заголовка при наличии строк тела вставка снизу и удаление строки недоступны (правило сервиса).
        let headerFrame = try XCTUnwrap(layout.markdownTableFrame(for: try XCTUnwrap(table.rows.first?.cells.first), in: container))
        let headerItems = view.tableMenuHandler?(NSPoint(x: headerFrame.midX + view.textContainerOrigin.x, y: headerFrame.midY + view.textContainerOrigin.y)) ?? []
        let headerMenu = try XCTUnwrap(headerItems.first?.submenu)
        XCTAssertEqual(headerMenu.items.first { $0.title == L10n.tr("在下方插入行") }?.isEnabled, false, "заголовок")
        XCTAssertEqual(headerMenu.items.first { $0.title == L10n.tr("删除行") }?.isEnabled, false, "заголовок")
        _ = insert.target?.perform(insert.action, with: insert)
        XCTAssertTrue(view.string.hasPrefix("| A | B |\n| --- | --- |\n| 中 | 😀 |\n|   |   |"), view.string)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source, "одна команда — один undo")
    }

    // MARK: Стенд и помощники

    private struct Stand {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let storage: NSTextStorage
        let layout: FoldLayoutManager
        let container: NSTextContainer
        let view: LacTextView
        let scroll: NSScrollView
        let window: NSWindow

        func close() { coordinator.updateActivity(false); window.close() }
        func children() -> [MarkdownTableCellEditor] { view.subviews.compactMap { $0 as? MarkdownTableCellEditor } }
        /// Центр ячейки в координатах окна (через рамку таблицы и сдвиг контейнера).
        func windowPoint(containerPoint: NSPoint) -> NSPoint {
            view.convert(NSPoint(x: containerPoint.x + view.textContainerOrigin.x, y: containerPoint.y + view.textContainerOrigin.y), to: nil)
        }
    }

    /// `tall`: документ выше окна и вертикально растягивается, чтобы можно было прокрутить.
    private func makeStand(_ source: String, formatted: Bool = true, tall: Bool = false) -> Stand {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = formatted
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: tall ? 100_000 : 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.allowsUndo = true
        if tall {
            view.isVerticallyResizable = true
            view.minSize = NSSize(width: 0, height: 300)
            view.maxSize = NSSize(width: 400, height: 100_000)
            container.widthTracksTextView = true
            container.heightTracksTextView = false
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return Stand(document: document, coordinator: coordinator, storage: storage, layout: layout, container: container,
                     view: view, scroll: scroll, window: window)
    }

    private func poll(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<30 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func click(_ stand: Stand, at windowPoint: NSPoint) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                     windowNumber: stand.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        stand.view.mouseDown(with: event)
    }

    private let tableSource = "Начало\r\n\r\n| Имя | 中 |\r\n| --- | --- |\r\n| Анна | 😀 |\r\n"

    // MARK: Кнопки «+» (В8)

    func testEdgeButtonsAddRowAndColumnThroughMouseDownWithOneUndo() async throws {
        let stand = makeStand(tableSource)
        defer { stand.close() }
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(tableSource).tables.first)
        let lastRowCell = try XCTUnwrap(table.rows.last?.cells.first)
        let headerCell = try XCTUnwrap(table.rows.first?.cells.last)
        for (name, cell, expectRow) in [("строка", lastRowCell, true), ("столбец", headerCell, false)] {
            stand.view.undoManager?.removeAllActions()
            var frame: NSRect?
            XCTAssertTrue(try await poll { frame = stand.layout.markdownTableFrame(for: cell, in: stand.container); return frame != nil }, name)
            let rect = try XCTUnwrap(frame)
            // Кнопка строки — под первой ячейкой последней строки, столбца — над правым краем заголовка.
            let point = expectRow ? NSPoint(x: rect.minX - 6, y: rect.maxY + 6) : NSPoint(x: rect.maxX - 6, y: rect.minY - 6)
            stand.layout.updateHoveredTable(at: point, in: stand.container)
            XCTAssertNotNil(stand.layout.tableEdgeButton(at: point, in: stand.container), "кнопка под курсором: \(name)")
            var changed = false
            for _ in 0..<30 where !changed {
                try click(stand, at: stand.windowPoint(containerPoint: point))
                changed = stand.view.string != tableSource
                if !changed { try await Task.sleep(for: .milliseconds(100)) }
            }
            XCTAssertTrue(changed, name)
            let parsed = try XCTUnwrap(MarkdownPresentationBuilder.parse(stand.view.string).tables.first)
            if expectRow { XCTAssertEqual(parsed.rows.count, 3, name) } else { XCTAssertEqual(parsed.alignments.count, 3, name) }
            XCTAssertEqual(stand.children().count, 1, "новая ячейка открыта: \(name)")
            XCTAssertTrue(NSLocationInRange(stand.view.selectedRange().location, parsed.range) ||
                          stand.view.selectedRange().location == NSMaxRange(parsed.range), "каретка в таблице: \(name)")
            try XCTUnwrap(stand.view.undoManager).undo()
            XCTAssertEqual(stand.view.string, tableSource, "одна кнопка — один undo: \(name)")
            stand.coordinator.finishTableCell()
        }
    }

    func testEdgeButtonIgnoredInSourceMode() async throws {
        let stand = makeStand(tableSource, formatted: false)
        defer { stand.close() }
        let button = FoldLayoutManager.TableEdgeButton(
            tableRange: NSRange(location: 0, length: 1), cell: MarkdownTableCell(range: NSRange(location: 0, length: 1), column: 0),
            command: .insertRowAfter, rect: .zero)
        XCTAssertEqual(stand.view.tableEdgeButtonHandler?(button), false, "исходный вид")
        XCTAssertEqual(stand.view.string, tableSource)
    }

    // MARK: Прокрутка при входе в ячейку

    private var longSource: String {
        (1...60).map { "Абзац \($0)" }.joined(separator: "\r\n\r\n") + "\r\n\r\n| Имя | 中 |\r\n| --- | --- |\r\n| Анна | 😀 |\r\n"
    }

    func testBeginTableCellKeepsScrollOriginInLongTableUnlessAsked() async throws {
        let source = longSource
        let stand = makeStand(source, tall: true)
        defer { stand.close() }
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        var frame: NSRect?
        XCTAssertTrue(try await poll { frame = stand.layout.markdownTableFrame(for: cell, in: stand.container); return frame != nil })
        let rect = try XCTUnwrap(frame).offsetBy(dx: stand.view.textContainerOrigin.x, dy: stand.view.textContainerOrigin.y)
        let clip = stand.scroll.contentView
        XCTAssertGreaterThan(rect.minY, clip.bounds.height, "таблица ниже первого экрана")
        // Клик по видимой ячейке: прокрутка не меняется.
        clip.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 100)))
        stand.scroll.reflectScrolledClipView(clip)
        let origin = clip.bounds.origin
        XCTAssertTrue(stand.coordinator.beginTableCell(cell.range, frame: rect, cell: cell))
        XCTAssertEqual(clip.bounds.origin, origin)
        stand.coordinator.finishTableCell()
        // Tab/переходы: невидимую ячейку нужно показать.
        clip.scroll(to: .zero)
        stand.scroll.reflectScrolledClipView(clip)
        XCTAssertTrue(stand.coordinator.beginTableCell(cell.range, frame: rect, cell: cell, scrollsIntoView: true))
        XCTAssertGreaterThan(clip.bounds.origin.y, 0)
    }

    // MARK: Переход к каретке (поиск, оглавление)

    func testRevealSelectionInsideCellOpensCellWithCaret() async throws {
        let stand = makeStand(tableSource)
        defer { stand.close() }
        let anna = (tableSource as NSString).range(of: "нн")
        let post = {
            NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                            object: EditorSelectionRequest(documentID: stand.document.id, range: anna))
        }
        var opened = false
        for _ in 0..<30 where !opened {
            post()
            opened = stand.children().count == 1
            if !opened { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(opened)
        let child = try XCTUnwrap(stand.children().first)
        XCTAssertTrue(child.string.contains("Анна"), child.string)
        XCTAssertEqual((child.string as NSString).substring(with: child.selectedRange()), "нн", "выделение перенесено в ячейку")
        XCTAssertEqual(stand.storage.string, tableSource, "текст не менялся")
    }

    func testRevealSelectionDoesNotOpenCellInSourceMode() async throws {
        let stand = makeStand(tableSource, formatted: false)
        defer { stand.close() }
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                        object: EditorSelectionRequest(documentID: stand.document.id, range: (tableSource as NSString).range(of: "Анна")))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(stand.children().isEmpty)
    }

    // MARK: Undo возвращает курсор в ячейку

    func testUndoAfterCellEditAndStructuralCommandReturnsCaretToCell() async throws {
        let stand = makeStand(tableSource)
        defer { stand.close() }
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(tableSource).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        var frame: NSRect?
        XCTAssertTrue(try await poll { frame = stand.layout.markdownTableFrame(for: cell, in: stand.container); return frame != nil })
        let rect = try XCTUnwrap(frame).offsetBy(dx: stand.view.textContainerOrigin.x, dy: stand.view.textContainerOrigin.y)
        // Правка внутри ячейки, затем выход и undo.
        XCTAssertTrue(stand.coordinator.beginTableCell(cell.range, frame: rect, cell: cell))
        let child = try XCTUnwrap(stand.children().first)
        child.setSelectedRange(NSRange(location: (child.string as NSString).length, length: 0))
        child.insertText("!", replacementRange: child.selectedRange())
        stand.coordinator.finishTableCell()
        XCTAssertNotEqual(stand.view.string, tableSource)
        stand.view.setSelectedRange(NSRange(location: 0, length: 0))
        try XCTUnwrap(stand.view.undoManager).undo()
        XCTAssertEqual(stand.view.string, tableSource)
        let selection = stand.view.selectedRange()
        XCTAssertTrue(NSLocationInRange(selection.location, cell.range) || selection.location == NSMaxRange(cell.range), "каретка в изменённой ячейке: \(selection)")
        XCTAssertTrue(try await poll { stand.children().count == 1 }, "после undo ячейка открыта")
        XCTAssertTrue(stand.children().first?.string.contains("Анна") == true, "открыта именно изменённая ячейка")
        stand.coordinator.finishTableCell()
        // Структурная команда из ячейки и undo.
        XCTAssertTrue(stand.coordinator.applyTableCommand(.insertColumnAfter, on: cell, frame: rect))
        stand.coordinator.finishTableCell()
        stand.view.setSelectedRange(NSRange(location: 0, length: 0))
        try XCTUnwrap(stand.view.undoManager).undo()
        XCTAssertEqual(stand.view.string, tableSource)
        let restored = stand.view.selectedRange()
        XCTAssertTrue(NSLocationInRange(restored.location, table.range) || restored.location == NSMaxRange(table.range), "каретка в таблице: \(restored)")
        XCTAssertTrue(try await poll { stand.children().count == 1 }, "после undo структурной команды ячейка открыта")
    }

    // MARK: IME

    func testTableMenuAndCommandsRefuseWhileMarkedText() async throws {
        let stand = makeStand(tableSource)
        defer { stand.close() }
        let table = try XCTUnwrap(MarkdownPresentationBuilder.parse(tableSource).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        var frame: NSRect?
        XCTAssertTrue(try await poll { frame = stand.layout.markdownTableFrame(for: cell, in: stand.container); return frame != nil })
        let rect = try XCTUnwrap(frame)
        let point = NSPoint(x: rect.midX + stand.view.textContainerOrigin.x, y: rect.midY + stand.view.textContainerOrigin.y)
        var items: [NSMenuItem] = []
        XCTAssertTrue(try await poll { items = stand.view.tableMenuHandler?(point) ?? []; return !items.isEmpty }, "без IME меню есть")
        // Ввод через IME в открытой ячейке: меню ячейки пусто, команда отказывает.
        XCTAssertTrue(stand.coordinator.beginTableCell(cell.range, frame: rect.offsetBy(dx: stand.view.textContainerOrigin.x, dy: stand.view.textContainerOrigin.y), cell: cell))
        let child = try XCTUnwrap(stand.children().first)
        child.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(child.tableMenuHandler?().count, 0)
        let before = stand.document.synchronizedSnapshot().text
        let button = FoldLayoutManager.TableEdgeButton(tableRange: table.range, cell: cell, command: .insertRowAfter, rect: .zero)
        XCTAssertEqual(stand.view.tableEdgeButtonHandler?(button), false)
        XCTAssertEqual(stand.document.synchronizedSnapshot().text, before)
        child.unmarkText()
        stand.coordinator.finishTableCell()
    }

    // MARK: Переключение вида (В3)

    func testSwitchingPresentationKeepsCaretCellAndScrollPosition() async throws {
        _ = NSApplication.shared
        // Таблица в несколько строк выше каретки: раскладки видов заметно различаются по высоте.
        let rows = (1...8).map { "| Имя \($0) | 中 |" }.joined(separator: "\r\n")
        let source = (1...40).map { "Абзац \($0)" }.joined(separator: "\r\n\r\n") + "\r\n\r\n| Имя | 中 |\r\n| --- | --- |\r\n" + rows + "\r\n| Анна | 😀 |\r\n"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let store = EditorSessionStore(limit: 1)
        let host = NSHostingView(rootView: EditorTextView(
            document: document, sessionStore: store, fontSize: 14, lineSpacing: 2, indentationStyle: .spaces, tabWidth: 4,
            wordWrap: true, showsLineNumbers: false, topInset: 0, isActive: true, requestTextTransformation: { _ in }, textFontFamily: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let coordinator = store.coordinator(for: document)
        defer { coordinator.updateActivity(false); window.close() }
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(coordinator.textView)
        let clip = try XCTUnwrap(coordinator.scrollView?.contentView)
        let anna = (source as NSString).range(of: "Анна")
        func caretDistance() -> CGFloat? {
            guard let layout = view.layoutManager, view.textStorage?.length ?? 0 > 0 else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: min(view.selectedRange().location, (view.textStorage?.length ?? 1) - 1))
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerOrigin.y - clip.bounds.origin.y
        }
        // Каретка в ячейке, таблица видна в середине окна.
        view.setSelectedRange(NSRange(location: anna.location + 2, length: 0))
        view.scrollRangeToVisible(anna)
        window.makeFirstResponder(view)
        XCTAssertTrue(try await poll { coordinator.openTableCellAtSelection(scrollsIntoView: true) || view.subviews.contains { $0 is MarkdownTableCellEditor } })
        let before = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.frame.minY) - clip.bounds.origin.y
        let lineHeight = try XCTUnwrap(coordinator.foldLayoutManager?.editorLineHeight)
        let formattedDocumentY = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.frame.minY)
        document.isMarkdownFormatted = false
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try await poll { !view.subviews.contains { $0 is MarkdownTableCellEditor } && view.string == source })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(NSLocationInRange(view.selectedRange().location, anna) || view.selectedRange().location == NSMaxRange(anna), "каретка в той же ячейке")
        let sourceDocumentY = try XCTUnwrap(caretDistance()) + clip.bounds.origin.y
        XCTAssertGreaterThan(abs(sourceDocumentY - formattedDocumentY), lineHeight, "раскладки различаются: без якоря каретка сместилась бы")
        XCTAssertEqual(try XCTUnwrap(caretDistance()), before, accuracy: lineHeight, "положение каретки в окне сохранено (исходный вид)")
        document.isMarkdownFormatted = true
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try await poll { view.subviews.contains { $0 is MarkdownTableCellEditor } }, "ячейка снова открыта")
        let after = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.frame.minY) - clip.bounds.origin.y
        XCTAssertEqual(after, before, accuracy: lineHeight, "положение ячейки в окне сохранено (оформленный вид)")
    }
}

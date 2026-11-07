import AppKit
import XCTest
@testable import LacEditor

/// Единый путь программной правки: `EditorTextView.Coordinator.perform(_:)` и делегат Writing Tools.
@MainActor
final class MarkdownEditTransactionTests: XCTestCase {
    private typealias T = MarkdownEditTransaction

    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }

        /// Версия текста редактора: `contentRevision` закрыт, поэтому берём её тем же путём, что ИИ и сниппеты.
        func revision() throws -> UInt {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return try XCTUnwrap(request.result).editorRevision
        }

        func ignoredRanges(_ enclosing: NSRange? = nil) -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: enclosing ?? NSRange(location: 0, length: shown.length))
                .map(\.rangeValue)
        }
    }

    private func makeEditor(_ source: String, formatted: Bool = true) -> Editor {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = formatted
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        // Без окна у NSTextView нет undoManager.
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
        return Editor(document: document, coordinator: coordinator, view: view, window: window)
    }

    /// Ждёт, пока Writing Tools получит карту текста (то есть готов разбор Markdown).
    /// По умолчанию ждёт любой непустой список; тесту с токеном media нужно своё условие (токен защищён и без разбора).
    private func waitForParse(_ editor: Editor, until condition: ([NSRange]) -> Bool = { !$0.isEmpty }) async throws {
        for _ in 0..<30 where !condition(editor.ignoredRanges()) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(editor.ignoredRanges()), "разбор Markdown не успел завершиться")
    }

    private let tokenSource = "до data:image/png;base64,iVBORw0KGgo= после\r\nконец 😀"

    // MARK: Общие проверки и отмена

    func testFormattingTransactionIsOneUndoAndKeepsActionName() throws {
        let editor = makeEditor("Привет мир 😀\r\n", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let original = editor.shown as String
        let word = editor.shown.range(of: "мир")
        var transaction = T(.formatting, range: word, replacement: "**мир**")
        transaction.expectedRevision = try editor.revision()
        transaction.selectionAfter = NSRange(location: word.location + 2, length: 3)
        transaction.actionName = "加粗"
        XCTAssertEqual(editor.coordinator.perform(transaction), .applied(NSRange(location: word.location, length: 7)))
        let changed = (original as NSString).replacingCharacters(in: word, with: "**мир**")
        XCTAssertEqual(editor.shown as String, changed)
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: word.location + 2, length: 3))
        XCTAssertEqual(editor.view.undoManager?.undoActionName, "加粗")
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, original)
        XCTAssertEqual(editor.view.undoManager?.canUndo, false, "вся правка должна отменяться одной записью")
        editor.view.undoManager?.redo()
        XCTAssertEqual(editor.shown as String, changed)
    }

    // Отмена возвращает выделение, которое было до правки (а не то, что оставила команда).
    func testSelectionBeforeIsRestoredByUndo() throws {
        let editor = makeEditor("Привет мир 😀", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let word = editor.shown.range(of: "мир")
        editor.view.setSelectedRange(word)
        var transaction = T(.formatting, range: word, replacement: "**мир**")
        transaction.expectedRevision = try editor.revision()
        transaction.selectionAfter = NSRange(location: word.location + 2, length: 3)
        transaction.selectionBefore = word
        XCTAssertEqual(editor.coordinator.perform(transaction), .applied(NSRange(location: word.location, length: 7)))
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, "Привет мир 😀")
        XCTAssertEqual(editor.view.selectedRange(), word)
    }

    func testNilSelectionBeforeRegistersNothing() throws {
        let editor = makeEditor("Привет мир", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        var transaction = T(.formatting, range: NSRange(location: 0, length: 6), replacement: "Пока")
        transaction.expectedRevision = try editor.revision()
        XCTAssertNotNil(editor.coordinator.perform(transaction))
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, "Привет мир")
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    func testStaleRevisionRefusesWithoutChangingTextOrUndo() throws {
        let editor = makeEditor("Привет мир", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        var transaction = T(.formatting, range: NSRange(location: 0, length: 6), replacement: "Пока")
        transaction.expectedRevision = try editor.revision() &+ 1
        XCTAssertEqual(editor.coordinator.perform(transaction), .refused(.staleRevision))
        XCTAssertEqual(editor.shown as String, "Привет мир")
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    func testMarkedTextRefusesTransaction() {
        let editor = makeEditor("Привет", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        editor.view.setSelectedRange(NSRange(location: 6, length: 0))
        editor.view.setMarkedText("к", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 6, length: 0))
        defer { editor.view.unmarkText() }
        XCTAssertTrue(editor.view.hasMarkedText())
        let before = editor.shown as String
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: 0, length: 1), replacement: "п")), .refused(.markedText))
        XCTAssertEqual(editor.shown as String, before)
    }

    func testNotEditableRefuses() {
        let editor = makeEditor("Привет", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        editor.view.isEditable = false
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: 0, length: 1), replacement: "п")), .refused(.notEditable))
        XCTAssertEqual(editor.shown as String, "Привет")
    }

    func testOutOfBoundsAndOverlappingEditsRefuse() {
        func edit(_ location: Int, _ length: Int) -> T.Edit { T.Edit(range: NSRange(location: location, length: length), replacement: "x") }
        XCTAssertEqual(T.geometryRefusal([], textLength: 5), .outOfBounds)
        XCTAssertEqual(T.geometryRefusal([edit(NSNotFound, 0)], textLength: 5), .outOfBounds)
        XCTAssertEqual(T.geometryRefusal([edit(3, 4)], textLength: 5), .outOfBounds)
        XCTAssertEqual(T.geometryRefusal([edit(0, 3), edit(2, 1)], textLength: 5), .outOfBounds, "порядок от начала к концу")
        XCTAssertEqual(T.geometryRefusal([edit(1, 3), edit(0, 2)], textLength: 5), .outOfBounds, "пересечение")
        XCTAssertNil(T.geometryRefusal([edit(3, 2), edit(0, 3)], textLength: 5))
        let editor = makeEditor("Привет", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: 4, length: 10), replacement: "x")), .refused(.outOfBounds))
        XCTAssertEqual(editor.shown as String, "Привет")
    }

    func testBatchEditsApplyFromEndToStartWithOneUndo() {
        let editor = makeEditor("альфа бета гамма", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let beta = editor.shown.range(of: "бета"), alpha = editor.shown.range(of: "альфа")
        var transaction = T(.formatting, edits: [.init(range: beta, replacement: "B"), .init(range: alpha, replacement: "A")])
        transaction.actionName = "批量"
        XCTAssertEqual(editor.coordinator.perform(transaction), .applied(NSRange(location: 0, length: 1)))
        XCTAssertEqual(editor.shown as String, "A B гамма")
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, "альфа бета гамма")
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    func testFormattingWithSameTextIsRefusedAsUnchanged() {
        let editor = makeEditor("Привет", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: 0, length: 6), replacement: "Привет")), .refused(.unchanged))
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    // MARK: Media

    func testRangeCuttingMediaTokenRefusesTransaction() {
        let editor = makeEditor(tokenSource)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let marker = editor.shown.range(of: "#lac-media-")
        XCTAssertNotEqual(marker.location, NSNotFound)
        let before = editor.shown as String
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: marker.location + 2, length: 0), replacement: "x")), .refused(.protectedMedia))
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: marker.location + 2, length: 3), replacement: "")), .refused(.protectedMedia))
        XCTAssertEqual(editor.shown as String, before)
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    func testRangeCoveringWholeTokenIsAllowed() throws {
        let editor = makeEditor(tokenSource)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let span = try XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let token = NSRange(location: span.displayStart, length: span.displayLength)
        let before = editor.shown as String
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: token, replacement: "[картинка]")), .applied(NSRange(location: token.location, length: 10)))
        XCTAssertEqual(editor.shown as String, (before as NSString).replacingCharacters(in: token, with: "[картинка]"))
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, before)
        XCTAssertEqual(editor.document.synchronizedText(), tokenSource)
    }

    func testReplacementTouchingTokenWithGluedCharacterRefuses() throws {
        let editor = makeEditor(tokenSource)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let span = try XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let end = NSRange(location: span.displayEnd, length: 0)
        let before = editor.shown as String
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: end, replacement: "x")), .refused(.protectedAddress))
        XCTAssertEqual(editor.shown as String, before)
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: end, replacement: " ")), .applied(NSRange(location: end.location, length: 1)))
    }

    // MARK: Ответ ИИ

    func testAIReplacementUsesTransactionAndKeepsMessages() throws {
        let editor = makeEditor("中文😀", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let revision = try editor.revision()
        func post(_ request: EditorRangeReplacementRequest) {
            NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        }
        let stale = EditorRangeReplacementRequest(documentID: editor.document.id, range: NSRange(location: 4, length: 0), originalText: "",
                                                  replacementText: "!", expectedEditorRevision: revision &+ 1, actionName: "AI")
        post(stale)
        XCTAssertFalse(stale.wasHandled)
        XCTAssertEqual(stale.failureMessage, L10n.tr("编辑内容已变化，请重新执行转换"))
        let request = EditorRangeReplacementRequest(documentID: editor.document.id, range: NSRange(location: 4, length: 0), originalText: "",
                                                    replacementText: "!", expectedEditorRevision: revision, actionName: "AI转换")
        request.groupsUndo = true
        request.resultingSelection = NSRange(location: 1, length: 1)
        post(request)
        XCTAssertTrue(request.wasHandled)
        XCTAssertNil(request.failureMessage)
        XCTAssertEqual(editor.shown as String, "中文😀!")
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(editor.view.undoManager?.undoActionName, "AI转换")
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, "中文😀")
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    func testAIReplacementCuttingTokenKeepsPositionMessage() throws {
        let editor = makeEditor(tokenSource)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let marker = editor.shown.range(of: "#lac-media-")
        let range = NSRange(location: marker.location, length: 5)
        let request = EditorRangeReplacementRequest(documentID: editor.document.id, range: range, originalText: editor.shown.substring(with: range),
                                                    replacementText: "x", expectedEditorRevision: try editor.revision(), actionName: "AI")
        request.space = .display
        let before = editor.shown as String
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(request.failureMessage, L10n.tr("原文位置已变化，请重新执行转换"))
        XCTAssertEqual(editor.shown as String, before)
    }

    // Граница внутри замены (чекбокс скрывает «[ ]» одним символом): ответ ИИ и вставка не должны начинаться внутри неё.
    func testPerformInsideReplacementIsRefusedAndWholeReplacementIsAllowed() async throws {
        let editor = makeEditor("- [ ] задача\n")
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        try await waitForParse(editor)
        let before = editor.shown as String
        let inside = NSRange(location: 3, length: 1)
        for reason in [T.Reason.aiReplacement, .paste] {
            XCTAssertEqual(editor.coordinator.perform(T(reason, range: inside, replacement: "x")),
                           .refused(.insideReplacement(NSRange(location: 2, length: 3))), "\(reason)")
        }
        XCTAssertEqual(editor.shown as String, before)
        XCTAssertEqual(editor.coordinator.perform(T(.aiReplacement, range: NSRange(location: 2, length: 3), replacement: "[x]")), .applied(NSRange(location: 2, length: 3)))
        XCTAssertEqual(editor.shown as String, "- [x] задача\n")
    }

    // Каретка внутри inline-формулы раскрывает её исходник (как в FoldLayoutManager): правка внутри проходит.
    // Чекбокс так не работает: он нарисован поверх всегда, поэтому для него выше берётся «границу внутри» без каретки.
    func testPerformInsideRevealedInlineFormulaIsAllowed() async throws {
        let editor = makeEditor("Формула $x^2$ конец\n")
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let formula = editor.shown.range(of: "$x^2$")
        let inside = NSRange(location: formula.location + 2, length: 1)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        // Пока каретка снаружи, формула свёрнута: отказ доказывает, что разбор свежий и запись формулы в карте есть.
        // Отказ ничего не меняет, поэтому им же ждём нового разбора после каждой правки.
        func waitForRefusal(_ reason: T.Reason) async throws {
            editor.view.setSelectedRange(NSRange(location: 0, length: 0))
            // До разбора `perform` правку применяет, а не отказывает: опрашивать им можно только свежую карту.
            try await waitForParse(editor)
            let expected = T.Outcome.refused(.insideReplacement(formula))
            for _ in 0..<30 where editor.coordinator.perform(T(reason, range: inside, replacement: "y")) != expected {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(editor.coordinator.perform(T(reason, range: inside, replacement: "y")), expected, "\(reason): карта с формулой не появилась")
            XCTAssertEqual(editor.shown as String, "Формула $x^2$ конец\n", "\(reason)")
        }
        for reason in [T.Reason.aiReplacement, .paste] {
            try await waitForRefusal(reason)
            // Каретка внутри формулы: она раскрыта, правка проходит.
            editor.view.setSelectedRange(NSRange(location: inside.location, length: 0))
            XCTAssertEqual(editor.coordinator.perform(T(reason, range: inside, replacement: "y")),
                           .applied(NSRange(location: inside.location, length: 1)), "\(reason)")
            XCTAssertEqual(editor.shown as String, "Формула $xy2$ конец\n", "\(reason)")
            editor.view.undoManager?.undo()
            XCTAssertEqual(editor.shown as String, "Формула $x^2$ конец\n", "\(reason)")
        }
    }

    // Граница внутри скрытого маркера: ответ ИИ и вставка отказываются, пока маркер скрыт; раскрытый маркер правится.
    func testAIReplacementInsideHiddenMarkerIsRefused() async throws {
        let source = "Привет **жирный** мир\n\nконец 中文\n"
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let strong = editor.shown.range(of: "**жирный**")
        let inside = NSRange(location: strong.location + 1, length: 1)
        func refusedAsHidden(_ outcome: T.Outcome) -> Bool {
            if case .refused(.insideHiddenSyntax(let owner)) = outcome { return owner == strong }
            return false
        }
        for reason in [T.Reason.aiReplacement, .paste] {
            editor.view.setSelectedRange(editor.shown.range(of: "конец"))
            // До разбора `perform` правку применяет, поэтому сначала ждём карту; отказ ничего не меняет, им же проверяем её свежесть.
            try await waitForParse(editor)
            for _ in 0..<30 where !refusedAsHidden(editor.coordinator.perform(T(reason, range: inside, replacement: "y"))) {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(refusedAsHidden(editor.coordinator.perform(T(reason, range: inside, replacement: "y"))), "\(reason): карта со скрытым маркером не появилась")
            XCTAssertEqual(editor.shown as String, source, "\(reason)")
            // Каретка у элемента раскрывает маркеры: правка проходит.
            editor.view.setSelectedRange(NSRange(location: strong.location, length: 0))
            XCTAssertEqual(editor.coordinator.perform(T(reason, range: inside, replacement: "y")),
                           .applied(NSRange(location: inside.location, length: 1)), "\(reason)")
            editor.view.undoManager?.undo()
            XCTAssertEqual(editor.shown as String, source, "\(reason)")
        }
    }

    // Заголовок раскрыт строкой целиком: вставка в его префикс проходит, из другой строки - отказ.
    func testPasteIntoRevealedHeadingPrefixIsAllowed() async throws {
        let source = "## Заголовок 中文\r\nтекст 😀\r\n"
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let inside = NSRange(location: 1, length: 1)
        editor.view.setSelectedRange(NSRange(location: editor.shown.length - 2, length: 0))
        func refused(_ outcome: T.Outcome) -> Bool {
            if case .refused(.insideHiddenSyntax) = outcome { return true }
            return false
        }
        // До разбора `perform` правку применяет: сначала ждём карту со скрытым префиксом.
        try await waitForParse(editor)
        for _ in 0..<30 where !refused(editor.coordinator.perform(T(.paste, range: inside, replacement: "x"))) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(refused(editor.coordinator.perform(T(.paste, range: inside, replacement: "x"))), "префикс скрыт, пока каретка на другой строке")
        editor.view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.coordinator.perform(T(.paste, range: inside, replacement: "x")), .applied(NSRange(location: 1, length: 1)))
        XCTAssertEqual(editor.shown as String, "#x" + source.dropFirst(2))
    }

    // Форматирование ужесточение не затронуло: команды намеренно режут маркеры.
    func testFormattingStillCutsMarkers() async throws {
        let editor = makeEditor("Привет **жирный** мир\n")
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        try await waitForParse(editor)
        let strong = editor.shown.range(of: "**жирный**")
        let inside = NSRange(location: strong.location + 1, length: 1)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: inside, replacement: "_")), .applied(NSRange(location: inside.location, length: 1)))
    }

    // Форматирование карту не спрашивает: оно намеренно правит маркеры.
    func testFormattingInsideReplacementIsNotCheckedByDisplayMap() async throws {
        let editor = makeEditor("- [ ] задача\n")
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        try await waitForParse(editor)
        XCTAssertEqual(editor.coordinator.perform(T(.formatting, range: NSRange(location: 3, length: 1), replacement: "x")), .applied(NSRange(location: 3, length: 1)))
        XCTAssertEqual(editor.shown as String, "- [x] задача\n")
    }

    // MARK: Вставка

    func testPasteTransactionReplacesSelectionWithOneUndoAndCaretAfter() {
        let editor = makeEditor("Привет мир", formatted: false)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let word = editor.shown.range(of: "мир")
        var transaction = T(.paste, range: word, replacement: "всем 😀")
        transaction.selectionAfter = NSRange(location: word.location + 7, length: 0)
        transaction.scrollsToSelection = true
        XCTAssertEqual(editor.coordinator.perform(transaction), .applied(NSRange(location: word.location, length: 7)))
        XCTAssertEqual(editor.shown as String, "Привет всем 😀")
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 14, length: 0))
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, "Привет мир")
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    // Вставка через insertText: перенумерация нумерованного списка вокруг вставки работает, как при наборе.
    func testTextInputPasteRenumbersOrderedList() async throws {
        let editor = makeEditor("1. a\n2. b\n")
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        var transaction = T(.paste, range: NSRange(location: 5, length: 0), replacement: "2. x\n")
        transaction.usesTextInput = true
        XCTAssertEqual(editor.coordinator.perform(transaction), .applied(NSRange(location: 5, length: 5)))
        for _ in 0..<30 where !(editor.shown as String).contains("3. b") { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(editor.shown as String, "1. a\n2. x\n3. b\n")
        // Каретка после вставленного текста (перенумерация сохраняет её место).
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 10, length: 0))
    }

    // MARK: Ячейка таблицы

    // Образец — MarkdownClipboardInteractionTests.testExplicitSourcePasteTargetsVirtualCellWithoutEarlyMaterialization.
    func testTableCellTransactionUpdatesCellStateBeforeDidChange() throws {
        let source = "| A | B |\n| --- | --- |\n| x | y |\n"
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationBuilder.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(editor.coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.insertText("Ж", replacementRange: NSRange(location: (child.string as NSString).length, length: 0))
        XCTAssertTrue((editor.shown as String).contains("Ж"), editor.shown as String)
        // Если состояние ячейки не обновилось до didChangeText, вторая правка отклонится как устаревшая.
        child.insertText("😀", replacementRange: NSRange(location: (child.string as NSString).length, length: 0))
        XCTAssertTrue((editor.shown as String).contains("Ж😀"), editor.shown as String)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(editor.shown as String, source)
    }

    // MARK: Writing Tools

    func testWritingToolsIgnoredRangesCoverTokensMarkersAndCode() async throws {
        let text = "# Т\n\n**жирный** и `код` ![a](data:image/png;base64,iVBORw0KGgo=)\n\n```\nкод\n```\n"
        let editor = makeEditor(text)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        // Ждём, пока список покроет открывающие `**` (появляется только после разбора).
        let opening = editor.shown.range(of: "**жирный**")
        let openingMarker = NSRange(location: opening.location, length: 2)
        try await waitForParse(editor) { $0.contains { NSIntersectionRange($0, openingMarker) == openingMarker } }
        let shown = editor.shown
        let ranges = editor.ignoredRanges()
        XCTAssertTrue(zip(ranges, ranges.dropFirst()).allSatisfy { NSMaxRange($0) < $1.location }, "отсортированы, не касаются: \(ranges)")
        XCTAssertTrue(ranges.allSatisfy { $0.length > 0 && NSMaxRange($0) <= shown.length }, "внутри текста: \(ranges)")
        func covered(_ range: NSRange, _ message: String) {
            XCTAssertTrue(ranges.contains { NSIntersectionRange($0, range) == range }, "\(message): \(ranges)")
        }
        let span = try XCTUnwrap(editor.document.mediaTable.spans(in: shown).first)
        covered(NSRange(location: span.displayStart, length: span.displayLength), "токен media")
        let strong = shown.range(of: "**жирный**")
        covered(NSRange(location: strong.location, length: 2), "открывающие **")
        covered(NSRange(location: NSMaxRange(strong) - 2, length: 2), "закрывающие **")
        covered(shown.range(of: "`код`"), "инлайн-код")
        covered(shown.range(of: "```\nкод\n```"), "забор кода")
        let word = shown.range(of: "жирный")
        XCTAssertFalse(ranges.contains { NSIntersectionRange($0, word).length > 0 }, "слово внутри ** менять можно")
        // Окно в середине слова: только то, что внутри окна.
        let window = NSRange(location: word.location + 1, length: 3)
        XCTAssertTrue(editor.ignoredRanges(window).isEmpty)
        let marker = NSRange(location: strong.location, length: 4)
        XCTAssertEqual(editor.ignoredRanges(marker), [NSRange(location: strong.location, length: 2)])
    }

    // Выделение всего текста не раскрывает элементы: формула, чекбокс и маркеры остаются защищёнными.
    func testWritingToolsIgnoredRangesIgnoreSelectionReveal() async throws {
        let text = "- [ ] задача\n\n**жирный** и $x^2$\n"
        let editor = makeEditor(text)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        let shown = editor.shown
        let strong = shown.range(of: "**жирный**")
        let formula = shown.range(of: "$x^2$")
        let checkbox = NSRange(location: 2, length: 3)
        let openingMarker = NSRange(location: strong.location, length: 2)
        try await waitForParse(editor) { $0.contains { NSIntersectionRange($0, openingMarker) == openingMarker } }
        editor.view.setSelectedRange(NSRange(location: 0, length: shown.length))
        let ranges = editor.ignoredRanges()
        func covered(_ range: NSRange, _ message: String) {
            XCTAssertTrue(ranges.contains { NSIntersectionRange($0, range) == range }, "\(message): \(ranges)")
        }
        covered(checkbox, "чекбокс")
        covered(openingMarker, "открывающие **")
        covered(formula, "inline-формула")
    }

    func testWritingToolsSessionTreatsEditsAsAutomatedAndEndsClean() {
        let editor = makeEditor(tokenSource)
        defer { editor.coordinator.updateActivity(false); editor.window.close() }
        // Правка, накрывающая токен лишь частью: обычный путь расширяет её до токена, а в сеансе она отклоняется без вложенной правки.
        let marker = editor.shown.range(of: "#lac-media-")
        let range = NSRange(location: marker.location, length: 5)
        let before = editor.shown as String
        editor.coordinator.textViewWritingToolsWillBegin(editor.view)
        XCTAssertFalse(editor.view.shouldChangeText(in: range, replacementString: ""))
        XCTAssertEqual(editor.shown as String, before)
        editor.coordinator.textViewWritingToolsDidEnd(editor.view)
        XCTAssertFalse(editor.view.shouldChangeText(in: range, replacementString: ""))
        XCTAssertNotEqual(editor.shown as String, before, "после сеанса токен снова удаляется вложенной правкой целиком")
    }
}

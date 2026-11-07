import AppKit
import XCTest
@testable import LacEditor

/// Управляет модальным окном «图片»: читает состояние блока выбора, нажимает кнопки и закрывает окно.
/// Таймер работает в режиме `.modalPanel`, как в `MarkdownImageUploadTests`.
@MainActor
final class PlacementDialogScript {
    var choose: MarkdownImagePlacement.Choice?
    var remember: Bool?
    var cancel = false
    private(set) var appeared = false
    private(set) var timedOut = false
    private(set) var hasPlacementControls = false
    private(set) var besideState: NSControl.StateValue?
    private(set) var embedState: NSControl.StateValue?
    private(set) var rememberState: NSControl.StateValue?
    private var finished = false

    init(choose: MarkdownImagePlacement.Choice? = nil, remember: Bool? = nil, cancel: Bool = false) {
        self.choose = choose
        self.remember = remember
        self.cancel = cancel
    }

    func stop() { finished = true; if NSApp.modalWindow != nil { NSApp.abortModal() } }

    func start(attempts: Int = 250) { step(attempts) }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] } + view.subviews.flatMap { buttons(in: $0) }
    }

    private func step(_ remaining: Int) {
        guard !finished else { return }
        if let window = NSApp.modalWindow {
            appeared = true
            let buttons = Self.buttons(in: window.contentView ?? NSView())
            func find(_ key: String) -> NSButton? { buttons.first { $0.title == L10n.tr(key) } }
            let beside = find("保存在文档旁边"), embed = find("嵌入文档"), remember = find("记住此文档的选择")
            hasPlacementControls = beside != nil && embed != nil && remember != nil
            besideState = beside?.state
            embedState = embed?.state
            rememberState = remember?.state
            if choose == .embedded { embed?.performClick(nil) }
            if choose == .besideDocument { beside?.performClick(nil) }
            if let wanted = self.remember, let remember, (remember.state == .on) != wanted { remember.performClick(nil) }
            NSApp.stopModal(withCode: cancel ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            return
        }
        if remaining > 0 {
            RunLoop.main.add(Timer(timeInterval: 0.02, repeats: false) { _ in MainActor.assumeIsolated { self.step(remaining - 1) } }, forMode: .modalPanel)
        } else { timedOut = true }
    }
}

final class MarkdownImagePlacementInteractionTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    @MainActor
    private struct Stand {
        let state: AppState
        let document: EditorDocument
        let view: LacTextView
        let preferences: AppPreferences
        let cleanup: () -> Void
    }

    /// Стенд как в `MarkdownImageUploadTests`: окно, редактор, состояние приложения.
    @MainActor
    private func makeStand(url: URL?, text: String = "before", formatted: Bool = false) throws -> Stand {
        _ = NSApplication.shared
        let suite = "MarkdownImagePlacementInteractionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: text, url: url, language: .markdown)
        // Оформленный режим включается до создания Coordinator, как в соседних тестах оформленного Markdown.
        document.isMarkdownFormatted = formatted
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: text), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return Stand(state: state, document: document, view: view, preferences: preferences) {
            coordinator.updateActivity(false); manager.unregister(windowID: id); window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func temporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func paste(_ stand: Stand, script: PlacementDialogScript, until done: @MainActor () -> Bool) async throws {
        script.start()
        XCTAssertTrue(stand.state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<200 where !(done() || script.timedOut) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(script.timedOut, "окно не появилось")
    }

    private func assetFiles(of documentURL: URL) -> [URL] {
        let folder = MarkdownImagePlacement.assetsFolder(for: documentURL)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
    }

    @MainActor
    func testSavedDocumentBesideChoiceWritesAssetsFileAndInsertsRelativeLink() async throws {
        let directory = try temporaryDirectory(named: "Папка с пробелом")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("Моя заметка.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let script = PlacementDialogScript(choose: .besideDocument)
        defer { script.stop() }
        try await paste(stand, script: script) { stand.view.string != "before" }
        XCTAssertTrue(script.hasPlacementControls)
        let files = assetFiles(of: documentURL)
        XCTAssertEqual(files.count, 1)
        let saved = try XCTUnwrap(files.first)
        XCTAssertNotNil(saved.lastPathComponent.range(of: #"^image-\d{8}-\d{6}\.png$"#, options: .regularExpression))
        XCTAssertEqual(try Data(contentsOf: saved), png)
        let address = try XCTUnwrap(MarkdownImageEditingService.address(for: saved, document: documentURL))
        XCTAssertEqual(address, "%D0%9C%D0%BE%D1%8F%20%D0%B7%D0%B0%D0%BC%D0%B5%D1%82%D0%BA%D0%B0.assets/" + saved.lastPathComponent)
        XCTAssertEqual(stand.view.string, "before![](<\(address)>)")
    }

    @MainActor
    func testSavedDocumentEmbedChoiceInsertsDataURIWithoutAssetsFolder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let script = PlacementDialogScript(choose: .embedded)
        defer { script.stop() }
        try await paste(stand, script: script) { stand.document.synchronizedSnapshot().text != "before" }
        // Текст документа хранит data URI; в окне редактора он может быть свёрнут в токен media.
        XCTAssertEqual(stand.document.synchronizedSnapshot().text, "before![](<data:image/png;base64,\(png.base64EncodedString())>)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkdownImagePlacement.assetsFolder(for: documentURL).path))
    }

    @MainActor
    func testRememberedChoiceIsPreselectedAndCheckboxIsSet() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let first = PlacementDialogScript(choose: .embedded, remember: true)
        defer { first.stop() }
        try await paste(stand, script: first) { stand.document.synchronizedSnapshot().text != "before" }
        XCTAssertEqual(first.besideState, .on, "без запомненного выбора отмечено «рядом»")
        XCTAssertEqual(first.rememberState, .off)
        XCTAssertEqual(stand.preferences.markdownImagePlacement(for: documentURL), .embedded)
        // Вторая вставка идёт в новом стенде с тем же файлом; у стенда свой набор UserDefaults, поэтому сохранённый выбор переносим тем же API.
        let second = PlacementDialogScript()
        defer { second.stop() }
        let defaults = stand.preferences
        let again = try makeStand(url: documentURL)
        defer { again.cleanup() }
        again.preferences.setMarkdownImagePlacement(defaults.markdownImagePlacement(for: documentURL), for: documentURL)
        try await paste(again, script: second) { again.document.synchronizedSnapshot().text != "before" }
        XCTAssertEqual(second.embedState, .on)
        XCTAssertEqual(second.besideState, .off)
        XCTAssertEqual(second.rememberState, .on)
        XCTAssertEqual(again.preferences.markdownImagePlacement(for: documentURL), .embedded)
        XCTAssertTrue(again.document.synchronizedSnapshot().text.contains("![](<data:image/png;base64,"))
    }

    @MainActor
    func testUncheckingRememberForgetsChoice() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        stand.preferences.setMarkdownImagePlacement(.embedded, for: documentURL)
        let script = PlacementDialogScript(remember: false)
        defer { script.stop() }
        try await paste(stand, script: script) { stand.document.synchronizedSnapshot().text != "before" }
        XCTAssertEqual(script.rememberState, .on)
        XCTAssertNil(stand.preferences.markdownImagePlacement(for: documentURL))
    }

    @MainActor
    func testCancelKeepsRememberedChoiceAndInsertsNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        stand.preferences.setMarkdownImagePlacement(.embedded, for: documentURL)
        let script = PlacementDialogScript(choose: .besideDocument, remember: false, cancel: true)
        defer { script.stop() }
        script.start()
        XCTAssertTrue(stand.state.presentMarkdownImage(transfer: .data(png)))
        // Окно закрывается кнопкой «取消»; ждём детерминированный признак — окно показано и отработало.
        for _ in 0..<100 where !script.appeared { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(script.appeared)
        XCTAssertEqual(stand.preferences.markdownImagePlacement(for: documentURL), .embedded)
        XCTAssertEqual(stand.view.string, "before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkdownImagePlacement.assetsFolder(for: documentURL).path))
    }

    @MainActor
    func testUnsavedDocumentEmbedsWithoutPlacementControls() async throws {
        let stand = try makeStand(url: nil)
        defer { stand.cleanup() }
        let script = PlacementDialogScript()
        defer { script.stop() }
        try await paste(stand, script: script) { stand.document.synchronizedSnapshot().text != "before" }
        XCTAssertTrue(script.appeared, "окно alt/заголовок остаётся")
        XCTAssertFalse(script.hasPlacementControls)
        XCTAssertNil(script.besideState)
        XCTAssertTrue(stand.document.synchronizedSnapshot().text.contains("![](<data:image/png;base64,"))
    }

    @MainActor
    func testVaultNoteEmbedsWithoutPlacementControls() async throws {
        // Каталог внутри корня локальных копий хранилища (тот же путь, что проверяет AppState.isVaultFile).
        let root = VaultStateStore.defaultRoot(vaultID: UUID())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(AppState.isVaultLocalFile(root.appendingPathComponent("note.md")))
        let documentURL = root.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let script = PlacementDialogScript()
        defer { script.stop() }
        try await paste(stand, script: script) { stand.document.synchronizedSnapshot().text != "before" }
        XCTAssertFalse(script.hasPlacementControls)
        XCTAssertTrue(stand.document.synchronizedSnapshot().text.contains("![](<data:image/png;base64,"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkdownImagePlacement.assetsFolder(for: documentURL).path))
    }

    @MainActor
    func testWriteFailureShowsMessageAndInsertsNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        // На месте папки лежит обычный файл: запись невозможна.
        try Data().write(to: MarkdownImagePlacement.assetsFolder(for: documentURL))
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let script = PlacementDialogScript(choose: .besideDocument)
        defer { script.stop() }
        let prefix = String(L10n.tr("无法保存图片：%@").dropLast(2))
        try await paste(stand, script: script) { stand.document.statusMessage?.hasPrefix(prefix) == true }
        XCTAssertTrue(stand.document.statusMessage?.hasPrefix(prefix) == true, stand.document.statusMessage ?? "nil")
        XCTAssertEqual(stand.view.string, "before")
        XCTAssertEqual(stand.document.synchronizedSnapshot().text, "before")
    }

    @MainActor
    func testUndoDoesNotDeleteSavedImageFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let script = PlacementDialogScript(choose: .besideDocument)
        defer { script.stop() }
        try await paste(stand, script: script) { stand.view.string != "before" }
        let inserted = stand.view.string
        let saved = try XCTUnwrap(assetFiles(of: documentURL).first)
        try XCTUnwrap(stand.view.undoManager).undo()
        XCTAssertEqual(stand.view.string, "before")
        XCTAssertEqual(try Data(contentsOf: saved), png)
        try XCTUnwrap(stand.view.undoManager).redo()
        XCTAssertEqual(stand.view.string, inserted)
    }

    // Вставка в середину абзаца (кириллица, CJK, emoji, \r\n): ссылка на файл - одна запись отмены, сам файл остаётся.
    @MainActor
    func testImageInsertionInMiddleOfParagraphIsOneUndo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let text = "до 中文 после 😀\r\nвторая строка"
        let stand = try makeStand(url: documentURL, text: text, formatted: true)
        defer { stand.cleanup() }
        stand.view.setSelectedRange(NSRange(location: 3, length: 0))
        let script = PlacementDialogScript(choose: .besideDocument)
        defer { script.stop() }
        try await paste(stand, script: script) { stand.view.string != text }
        let inserted = stand.view.string
        XCTAssertTrue(inserted.hasPrefix("до ![]("), inserted)
        XCTAssertTrue(inserted.hasSuffix("中文 после 😀\r\nвторая строка"), inserted)
        let saved = try XCTUnwrap(assetFiles(of: documentURL).first)
        let undo = try XCTUnwrap(stand.view.undoManager)
        undo.undo()
        XCTAssertEqual(stand.view.string, text)
        XCTAssertFalse(undo.canUndo, "вставка изображения должна отменяться одной записью")
        XCTAssertEqual(try Data(contentsOf: saved), png, "отмена текста не удаляет файл")
        undo.redo()
        XCTAssertEqual(stand.view.string, inserted)
    }

    @MainActor
    func testTwoPastesInOneSecondGetDistinctFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        for step in 0..<2 {
            let script = PlacementDialogScript(choose: .besideDocument)
            defer { script.stop() }
            let before = stand.view.string
            try await paste(stand, script: script) { stand.view.string != before }
            XCTAssertEqual(assetFiles(of: documentURL).count, step + 1, "после вставки \(step + 1)")
            stand.view.setSelectedRange(NSRange(location: (stand.view.string as NSString).length, length: 0))
        }
        // Секунда могла смениться между вставками: важно только, что имена разные и ничего не затёрто.
        XCTAssertEqual(Set(assetFiles(of: documentURL).map(\.lastPathComponent)).count, 2)
    }

    @MainActor
    func testExplicitCopyFolderStillWinsWithoutPlacementControls() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        stand.preferences.markdownImageUploadConfiguration.copyFolder = directory.appendingPathComponent("assets").path
        let script = PlacementDialogScript()
        defer { script.stop() }
        try await paste(stand, script: script) { stand.view.string != "before" }
        XCTAssertFalse(script.hasPlacementControls)
        XCTAssertEqual(stand.view.string, "before![](<assets/image.png>)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkdownImagePlacement.assetsFolder(for: documentURL).path))
    }

    @MainActor
    func testFileTransferInsertsLinkWithoutPlacementControls() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let documentURL = directory.appendingPathComponent("note.md")
        let source = directory.appendingPathComponent("photo.png")
        try png.write(to: source)
        let stand = try makeStand(url: documentURL)
        defer { stand.cleanup() }
        let script = PlacementDialogScript()
        defer { script.stop() }
        script.start()
        XCTAssertTrue(stand.state.presentMarkdownImage(transfer: .file(source)))
        for _ in 0..<200 where !(stand.view.string != "before" || script.timedOut) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(script.hasPlacementControls)
        XCTAssertEqual(stand.view.string, "before![](<photo.png>)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkdownImagePlacement.assetsFolder(for: documentURL).path))
    }

    // MARK: Continuity Camera

    @MainActor
    private func makeContinuityView(editable: Bool = true) -> (LacTextView, () -> [MarkdownImageTransfer]) {
        _ = NSApplication.shared
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isEditable = editable
        var received: [MarkdownImageTransfer] = []
        view.imageTransferHandler = { transfer in received.append(transfer); return true }
        return (view, { received })
    }

    private func privateBoard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)) }

    private func bitmap(width: Int, height: Int, alpha: CGFloat) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Заполняем буфер напрямую (premultiplied RGBA): поэлементный setColor на 3000x1500 слишком медленный.
        let data = try XCTUnwrap(rep.bitmapData)
        let alphaByte = UInt8(alpha * 255)
        for y in 0..<height {
            let row = data + y * rep.bytesPerRow
            for x in 0..<width { row[x * 4] = 0; row[x * 4 + 1] = 0; row[x * 4 + 2] = alphaByte; row[x * 4 + 3] = alphaByte }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testValidRequestorAcceptsImageReturnTypeOnlyWhenEditableAndReady() {
        let (view, _) = makeContinuityView()
        XCTAssertTrue((view.validRequestor(forSendType: nil, returnType: .png) as? LacTextView) === view)
        XCTAssertTrue((view.validRequestor(forSendType: nil, returnType: .tiff) as? LacTextView) === view)
        view.isEditable = false
        XCTAssertNil(view.validRequestor(forSendType: nil, returnType: .png))
        view.isEditable = true
        view.imageTransferHandler = nil
        XCTAssertNil(view.validRequestor(forSendType: nil, returnType: .png))
        let (marked, _) = makeContinuityView()
        marked.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(marked.validRequestor(forSendType: nil, returnType: .png))
    }

    @MainActor
    func testReadSelectionDeliversReducedJPEGToHandler() throws {
        let (view, received) = makeContinuityView()
        let board = privateBoard()
        board.clearContents()
        board.setData(try bitmap(width: 3000, height: 1500, alpha: 1), forType: .png)
        XCTAssertTrue(view.readSelection(from: board))
        XCTAssertEqual(received().count, 1)
        guard case let .data(data)? = received().first else { return XCTFail("ожидались данные изображения") }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 2048)
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    @MainActor
    func testReadSelectionKeepsPNGWhenTransparent() throws {
        let (view, received) = makeContinuityView()
        let board = privateBoard()
        board.clearContents()
        board.setData(try bitmap(width: 30, height: 20, alpha: 0.5), forType: .png)
        XCTAssertTrue(view.readSelection(from: board))
        guard case let .data(data)? = received().first else { return XCTFail("ожидались данные изображения") }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    @MainActor
    func testReadSelectionRejectsReadingModeGarbageAndTextFallback() throws {
        let (reading, readingReceived) = makeContinuityView(editable: false)
        let board = privateBoard()
        board.clearContents()
        board.setData(try bitmap(width: 10, height: 10, alpha: 1), forType: .png)
        XCTAssertFalse(reading.readSelection(from: board))
        XCTAssertTrue(readingReceived().isEmpty)
        let (view, received) = makeContinuityView()
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertFalse(view.readSelection(from: board))
        board.clearContents()
        board.setString("текст", forType: .string)
        _ = view.readSelection(from: board)
        XCTAssertTrue(received().isEmpty, "текст не должен идти по пути изображений")
    }

    @MainActor
    func testContinuityImageInsertsInSourceAndFormattedModes() async throws {
        for formatted in [false, true] {
            let stand = try makeStand(url: nil, formatted: formatted)
            defer { stand.cleanup() }
            XCTAssertEqual(stand.document.isMarkdownFormatted, formatted)
            stand.view.imageTransferHandler = { [weak state = stand.state] transfer in state?.presentMarkdownImage(transfer: transfer) == true }
            let script = PlacementDialogScript()
            defer { script.stop() }
            script.start()
            let board = privateBoard()
            board.clearContents()
            board.setData(try bitmap(width: 20, height: 10, alpha: 1), forType: .png)
            XCTAssertTrue(stand.view.readSelection(from: board), "formatted=\(formatted)")
            for _ in 0..<200 where !(stand.document.synchronizedSnapshot().text != "before" || script.timedOut) { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(stand.document.synchronizedSnapshot().text.contains("![](<data:image/jpeg;base64,"), "formatted=\(formatted)")
        }
    }
}

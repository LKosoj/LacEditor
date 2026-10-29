import Foundation
import AppKit
import XCTest
@testable import LacEditor

private final class ImageCopyURLProtocol: URLProtocol {
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class WaitingImageCopyURLProtocol: URLProtocol {
    static var started: XCTestExpectation?
    static var stopped: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?.fulfill() }
    override func stopLoading() { Self.stopped?.fulfill() }
}

final class MarkdownImageCopyTests: XCTestCase {
    func testRawSVGIsNotCopiedAsAReferencedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20'/></svg>"
        do {
            _ = try await MarkdownImageCopyService.prepare(text: source, selection: NSRange(location: 0, length: (source as NSString).length),
                selectedOnly: true, remoteOnly: false, document: nil, folder: directory)
            XCTFail("raw SVG is not a referenced file")
        } catch MarkdownImageUploadService.UploadError.invalidInput {
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    @MainActor
    func testMoveReportsActualPathWhenIdentityCannotBeReadAfterMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.png"), destination = root.appendingPathComponent("b.png")
        try png.write(to: source)
        let service = FileService(), identity = try service.workspaceNodeIdentity(source)
        XCTAssertThrowsError(try service.moveImageFile(source, to: destination, expectedIdentity: identity, identityReader: { url in
            if url == destination { throw CocoaError(.fileReadUnknown) }
            return try service.workspaceNodeIdentity(url)
        })) { error in
            guard let issue = error as? ImageFileMutationError, case let .movedWithoutIdentity(actual) = issue else { return XCTFail("Expected actual destination") }
            XCTAssertEqual(actual, destination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), png)
    }

    @MainActor
    func testMoveReportsBothPathsWhenMoveFailsAfterCreatingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.png"), destination = root.appendingPathComponent("b.png")
        try png.write(to: source)
        let service = FileService(), identity = try service.workspaceNodeIdentity(source)
        XCTAssertThrowsError(try service.moveImageFile(source, to: destination, expectedIdentity: identity, move: { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            throw CocoaError(.fileWriteUnknown)
        })) { error in
            guard let issue = error as? ImageFileMutationError, case let .moveIncomplete(old, new) = issue else { return XCTFail("Expected both paths") }
            XCTAssertEqual(old, source)
            XCTAssertEqual(new, destination)
        }
        XCTAssertEqual(try Data(contentsOf: source), png)
        XCTAssertEqual(try Data(contentsOf: destination), png)
    }

    @MainActor
    func testMoveImageUndoRedoConflictAndEditorRefusal() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = root.appendingPathComponent("a.png"), movedFile = root.appendingPathComponent("b.png")
        try png.write(to: sourceFile)
        let source = "![a](a.png)"
        let document = EditorDocument(text: source, url: root.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
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
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let undo = try XCTUnwrap(view.undoManager)
        undo.disableUndoRegistration()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: false, choose: { _ in movedFile })
        undo.enableUndoRegistration()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedFile.path))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: false, choose: { _ in movedFile })
        XCTAssertEqual(view.string, "![a](b.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertEqual(try Data(contentsOf: movedFile), png)
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedFile.path))
        undo.redo()
        XCTAssertEqual(view.string, "![a](b.png)")
        XCTAssertEqual(try Data(contentsOf: movedFile), png)
        undo.undo()
        try Data("occupied".utf8).write(to: movedFile)
        undo.redo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        XCTAssertEqual(try Data(contentsOf: movedFile), Data("occupied".utf8))
        try FileManager.default.removeItem(at: movedFile)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: false, choose: { _ in movedFile }, afterMove: { view.isEditable = false })
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedFile.path))
        view.isEditable = true
        undo.removeAllActions()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: true, confirm: { _ in true })
        XCTAssertEqual(view.string, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        undo.redo()
        XCTAssertEqual(view.string, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        let shared = source + " " + source
        XCTAssertTrue(view.shouldChangeText(in: NSRange(location: 0, length: (source as NSString).length), replacementString: shared))
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (source as NSString).length), with: shared)
        view.didChangeText()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: true, confirm: { _ in true })
        XCTAssertEqual(view.string, shared)
        XCTAssertEqual(try Data(contentsOf: sourceFile), png)
        let composed = "é ![a](a.png)"
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: composed)
        view.didChangeText()
        undo.removeAllActions()
        view.setSelectedRange(NSRange(location: 4, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: false, choose: { _ in movedFile })
        let changed = "é ![a](b.png)"
        XCTAssertEqual(view.string, changed)
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "e\u{301}")
        undo.undo()
        XCTAssertTrue(view.string.utf16.elementsEqual("e\u{301} ![a](b.png)".utf16))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        try FileManager.default.moveItem(at: movedFile, to: sourceFile)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        view.didChangeText()
        undo.removeAllActions()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: false, choose: { _ in movedFile })
        let otherDocument = EditorDocument(text: "![other](b.png)", url: root.appendingPathComponent("other.md"), language: .markdown)
        let otherState = AppState(initialDocument: otherDocument, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let otherWindow = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let otherID = UUID()
        manager.register(windowID: otherID, state: otherState, window: otherWindow)
        undo.undo()
        XCTAssertEqual(view.string, "![a](b.png)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(undo.canRedo)
        manager.unregister(windowID: otherID)
        otherWindow.close()
        let sharedReference = "![a][r] ![b][r]\n\n[r]: b.png"
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: sharedReference)
        view.didChangeText()
        undo.removeAllActions()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: true, confirm: { _ in true })
        XCTAssertEqual(view.string, sharedReference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFile.path))
        try FileManager.default.moveItem(at: movedFile, to: sourceFile)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        view.didChangeText()
        undo.removeAllActions()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.moveOrDeleteMarkdownImage(deleteOriginal: false, choose: { _ in movedFile })
        try Data("occupied".utf8).write(to: sourceFile)
        undo.undo()
        XCTAssertEqual(view.string, "![a](b.png)")
        XCTAssertEqual(try Data(contentsOf: sourceFile), Data("occupied".utf8))
        XCTAssertEqual(try Data(contentsOf: movedFile), png)
        XCTAssertFalse(undo.canRedo)
    }

    @MainActor
    func testCopyUsesOneUndoAndRejectsChangedSelectionAfterFolderChoice() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try png.write(to: root.appendingPathComponent("a.png"))
        let source = "![a](a.png)"
        let document = EditorDocument(text: source, url: root.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
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
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let folder = root.appendingPathComponent("out", isDirectory: true)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.copyMarkdownImages(selectedOnly: true, remoteOnly: false, choose: { folder })
        for _ in 0..<150 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "![a](out/a.png)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a.png")), png)
        let staleFolder = root.appendingPathComponent("stale", isDirectory: true)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.copyMarkdownImages(selectedOnly: true, remoteOnly: false, choose: {
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            return staleFolder
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path))
        XCTAssertEqual(view.string, source)
        let mixed = source + " ![remote](https://example.invalid/slow.png)"
        XCTAssertTrue(view.shouldChangeText(in: NSRange(location: 0, length: (source as NSString).length), replacementString: mixed))
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (source as NSString).length), with: mixed)
        view.didChangeText()
        let started = expectation(description: "remote copy started")
        let stopped = expectation(description: "remote copy cancelled")
        WaitingImageCopyURLProtocol.started = started
        WaitingImageCopyURLProtocol.stopped = stopped
        defer { WaitingImageCopyURLProtocol.started = nil; WaitingImageCopyURLProtocol.stopped = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitingImageCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let partialFolder = root.appendingPathComponent("partial", isDirectory: true)
        state.copyMarkdownImages(selectedOnly: false, remoteOnly: false, choose: { partialFolder }, session: session)
        await fulfillment(of: [started], timeout: 5)
        let end = NSRange(location: (mixed as NSString).length, length: 0)
        XCTAssertTrue(view.shouldChangeText(in: end, replacementString: "x"))
        view.textStorage?.replaceCharacters(in: end, with: "x")
        view.didChangeText()
        await fulfillment(of: [stopped], timeout: 5)
        for _ in 0..<150 where document.statusMessage?.contains(partialFolder.path) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(view.string, mixed + "x")
        XCTAssertEqual(try Data(contentsOf: partialFolder.appendingPathComponent("a.png")), png)
        XCTAssertTrue(document.statusMessage?.contains(partialFolder.path) == true)
    }

    func testCopyAllPreservesExistingFilesAndDeduplicatesLocalAndRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try png.write(to: sourceFolder.appendingPathComponent("x.png"))
        try Data("existing".utf8).write(to: output.appendingPathComponent("x.png"))
        let source = "![a](x.png) ![b](x.png) ![c](https://example.invalid/remote.png)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ImageCopyURLProtocol.data = png
        defer { session.invalidateAndCancel() }
        let result = try await MarkdownImageCopyService.prepare(text: source, selection: NSRange(location: 0, length: 0),
            selectedOnly: false, remoteOnly: false, document: sourceFolder.appendingPathComponent("note.md"), folder: output, session: session)
        XCTAssertEqual(result.created.count, 2)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("x.png")), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("x-2.png")), png)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("remote.png")), png)
        let changed = (source as NSString).replacingCharacters(in: result.edit.range, with: result.edit.replacement)
        let images = try MarkdownImageUploadService.images(in: changed)
        XCTAssertEqual(images.map(\.address), ["../out/x-2.png", "../out/x-2.png", "../out/remote.png"])
        XCTAssertEqual(source, "![a](x.png) ![b](x.png) ![c](https://example.invalid/remote.png)")
    }

    @MainActor
    func testMoveAllPreparesLocalAndRemoteWithoutChangingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try png.write(to: root.appendingPathComponent("x.png"))
        try Data("occupied".utf8).write(to: folder.appendingPathComponent("x.png"))
        let text = "![a](x.png) ![b](x.png) ![remote](https://example.invalid/y.png)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ImageCopyURLProtocol.data = png
        defer { session.invalidateAndCancel() }
        let plan = try await MarkdownImageCopyService.prepareMoveAll(text: text, selection: NSRange(location: 0, length: 0),
            document: root.appendingPathComponent("note.md"), folder: folder, files: FileService(), session: session)
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items.filter { $0.source != nil }.count, 1)
        XCTAssertEqual(plan.items.filter { $0.data == png }.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("x.png")), png)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("x.png")), Data("occupied".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("x-2.png").path))
        let changed = (text as NSString).replacingCharacters(in: plan.edit.range, with: plan.edit.replacement)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: changed).map(\.address), ["out/x-2.png", "out/x-2.png", "out/y.png"])
    }

    @MainActor
    func testMoveAllPreservesDifferentSVGFragments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        let original = root.appendingPathComponent("sprite#1.svg")
        try data.write(to: original)
        let source = "![a](sprite%231.svg#one) <img src='sprite%231.svg#two'>"
        let plan = try await MarkdownImageCopyService.prepareMoveAll(text: source, selection: NSRange(location: 0, length: 0),
            document: root.appendingPathComponent("note.md"), folder: folder, files: FileService())
        let changed = (source as NSString).replacingCharacters(in: plan.edit.range, with: plan.edit.replacement)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: changed).map(\.address), ["out/sprite%231.svg#one", "out/sprite%231.svg#two"])
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sprite#1.svg").path))
    }

    @MainActor
    func testRepeatedLocalAliasStillChecksItsImageType() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("good.png")
        try png.write(to: image)
        for name in ["alias.txt", "alias.jpg"] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: image)
            let source = "![first](good.png) ![second](\(name))"
            do {
                _ = try await MarkdownImageCopyService.prepareMoveAll(text: source, selection: NSRange(location: 0, length: 0),
                    document: root.appendingPathComponent("note.md"), folder: folder, files: FileService())
                XCTFail("Expected an invalid image type")
            } catch let error as MarkdownImageUploadService.UploadError { XCTAssertEqual(error, .invalidInput) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("good.png").path))
            do {
                _ = try await MarkdownImageCopyService.prepare(text: source, selection: NSRange(location: 0, length: 0),
                    selectedOnly: false, remoteOnly: false, document: root.appendingPathComponent("note.md"), folder: folder)
                XCTFail("Expected an invalid image type")
            } catch let error as MarkdownImageCopyService.PartialFailure {
                XCTAssertEqual(error.created.count, 1)
                try FileManager.default.removeItem(at: try XCTUnwrap(error.created.first))
            }
        }
    }

    @MainActor
    func testMoveAllUsesOneUndoAndKeepsRemoteCopy() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try png.write(to: root.appendingPathComponent("a.png"))
        try png.write(to: root.appendingPathComponent("b.png"))
        let source = "![a](a.png) ![b](b.png) ![remote](https://example.invalid/r.png)"
        let document = EditorDocument(text: source, url: root.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
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
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ImageCopyURLProtocol.data = png
        defer { session.invalidateAndCancel() }
        state.moveAllMarkdownImages(choose: { folder }, session: session)
        for _ in 0..<150 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "![a](out/a.png) ![b](out/b.png) ![remote](out/r.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.png").path))
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.png")), png)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b.png")), png)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("r.png")), png)
        undo.redo()
        XCTAssertEqual(view.string, "![a](out/a.png) ![b](out/b.png) ![remote](out/r.png)")
        undo.undo()
        try Data("modified copy".utf8).write(to: folder.appendingPathComponent("r.png"))
        undo.redo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.png")), png)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b.png")), png)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("r.png")), Data("modified copy".utf8))
        XCTAssertFalse(undo.canUndo)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("r.png"))
        var calls = 0
        let service = FileService()
        state.moveAllMarkdownImages(choose: { folder }, session: session, move: { from, to, identity in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteUnknown) }
            return try service.moveImageFile(from, to: to, expectedIdentity: identity)
        })
        for _ in 0..<150 where document.statusMessage?.contains(root.path) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.png")), png)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b.png")), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.png").path))
        XCTAssertTrue(document.statusMessage?.contains(root.path) == true)
    }

    func testPartialCopyReportsCreatedFileWithoutReplacingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try png.write(to: root.appendingPathComponent("first.png"))
        let source = "![a](first.png) ![b](missing.png)"
        do {
            _ = try await MarkdownImageCopyService.prepare(text: source, selection: NSRange(location: 0, length: 0), selectedOnly: false,
                remoteOnly: false, document: root.appendingPathComponent("note.md"), folder: root.appendingPathComponent("out", isDirectory: true))
            XCTFail("Expected partial failure")
        } catch let error as MarkdownImageCopyService.PartialFailure {
            XCTAssertEqual(error.created.count, 1)
            XCTAssertEqual(try Data(contentsOf: error.created[0]), png)
        }
        XCTAssertEqual(source, "![a](first.png) ![b](missing.png)")
    }

    func testCopyPreservesFragmentsForLocalAndRemoteSVG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        try svg.write(to: root.appendingPathComponent("sprite#1.svg"))
        let dataURL = "data:image/svg+xml;base64," + svg.base64EncodedString()
        let source = "![a](sprite%231.svg#one) <img src=\"sprite%231.svg#two\"> ![b](https://example.invalid/remote.svg#one) ![c](https://example.invalid/remote.svg#two) ![d](\(dataURL)#one) ![e](\(dataURL)#two)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ImageCopyURLProtocol.data = svg
        defer { session.invalidateAndCancel() }
        let result = try await MarkdownImageCopyService.prepare(text: source, selection: NSRange(location: 0, length: 0),
            selectedOnly: false, remoteOnly: false, document: root.appendingPathComponent("note.md"),
            folder: root.appendingPathComponent("out", isDirectory: true), session: session)
        XCTAssertEqual(result.created.count, 3)
        let changed = (source as NSString).replacingCharacters(in: result.edit.range, with: result.edit.replacement)
        let images = try MarkdownImageUploadService.images(in: changed)
        XCTAssertEqual(images.map(\.address), ["out/sprite%231.svg#one", "out/sprite%231.svg#two", "out/remote.svg#one", "out/remote.svg#two", "out/image.svg#one", "out/image.svg#two"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out/sprite#1.svg")), svg)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out/remote.svg")), svg)
    }

    func testDownloadAllChangesOnlyRemoteAndUsesFileURLForUnsavedDocument() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "![local](local.png) ![remote](https://example.invalid/remote.png)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ImageCopyURLProtocol.data = png
        defer { session.invalidateAndCancel() }
        let result = try await MarkdownImageCopyService.prepare(text: source, selection: NSRange(location: 0, length: 0),
            selectedOnly: false, remoteOnly: true, document: nil, folder: folder, session: session)
        let changed = (source as NSString).replacingCharacters(in: result.edit.range, with: result.edit.replacement)
        let images = try MarkdownImageUploadService.images(in: changed)
        XCTAssertEqual(images.first?.address, "local.png")
        XCTAssertEqual(images.last?.address, folder.appendingPathComponent("remote.png").absoluteString)
        XCTAssertEqual(try Data(contentsOf: result.created[0]), png)
    }

    func testCopyPreservesOriginalAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let output = root.appendingPathComponent("图片 folder", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = input.appendingPathComponent("图 😀.png")
        try png.write(to: original)
        let payload = try MarkdownImageUploadService.payload(address: original.absoluteString, document: nil)
        let copy = try MarkdownImageCopyService.copy(payload, to: output)
        XCTAssertEqual(copy.lastPathComponent, original.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: original), png)
        XCTAssertEqual(try Data(contentsOf: copy), png)
        try Data("newer".utf8).write(to: copy)
        XCTAssertThrowsError(try MarkdownImageCopyService.copy(payload, to: output))
        XCTAssertEqual(try Data(contentsOf: copy), Data("newer".utf8))
        XCTAssertEqual(try Data(contentsOf: original), png)
        let renamed = try MarkdownImageCopyService.copy(payload, to: output, name: "новое имя.png")
        XCTAssertEqual(try Data(contentsOf: renamed), png)
        XCTAssertEqual(try Data(contentsOf: copy), Data("newer".utf8))
        XCTAssertThrowsError(try MarkdownImageCopyService.copy(payload, to: output, name: "wrong.jpg"))
        XCTAssertThrowsError(try MarkdownImageCopyService.copy(payload, to: output, name: "../escape.png"))
        XCTAssertEqual(try MarkdownImageCopyService.copy(payload, to: input), original)
    }

    func testCopyRejectsDanglingSymlinkAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("image.png")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing.png"))
        let payload = try MarkdownImageUploadService.payload(data: png)
        XCTAssertThrowsError(try MarkdownImageCopyService.copy(payload, to: root))
        XCTAssertTrue((try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try MarkdownImageCopyService.copy(payload, to: root, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testFolderTemplateRelativeAndNestedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("文 件.md")
        let folder = try MarkdownImageCopyService.folder(path: "./assets/${filename}", document: document)
        XCTAssertEqual(folder.path, root.appendingPathComponent("assets/文 件.md").path)
        let literalDocument = root.appendingPathComponent("${draft}.md")
        let literalFolder = try MarkdownImageCopyService.folder(path: "./${filename}/images", document: literalDocument)
        XCTAssertEqual(literalFolder.path, root.appendingPathComponent("${draft}.md/images").path)
        XCTAssertEqual(try MarkdownImageCopyService.folder(path: "./${other}", document: document).lastPathComponent, "${other}")
        let payload = try MarkdownImageUploadService.payload(data: png)
        let result = try MarkdownImageCopyService.copy(payload, to: folder)
        XCTAssertEqual(try Data(contentsOf: result), png)
        XCTAssertThrowsError(try MarkdownImageCopyService.folder(path: "./assets", document: nil))
        XCTAssertThrowsError(try MarkdownImageCopyService.folder(path: "/tmp/${filename}", document: nil))
        XCTAssertEqual(try MarkdownImageCopyService.folder(path: "assets/子", document: document).path,
                       root.appendingPathComponent("assets/子").path)
        let cancelled = root.appendingPathComponent("cancelled/nested", isDirectory: true)
        XCTAssertThrowsError(try MarkdownImageCopyService.copy(payload, to: cancelled, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
    }
}

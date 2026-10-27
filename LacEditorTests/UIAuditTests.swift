import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

final class UIAuditTests: XCTestCase {
    @MainActor
    func testOpeningPlaceholderIsNotEditableUntilReadSucceeds() async throws {
        _ = NSApplication.shared
        let suiteName = "LacEditorIOTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "disk".write(to: url, atomically: true, encoding: .utf8)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults), readFile: { url in
            let result = try FileService.prepareRead(url)
            started.signal()
            release.wait()
            return result
        })
        state.beginOpeningFile(url)
        let document = try XCTUnwrap(state.selectedDocument)
        let store = EditorSessionStore(limit: 2)
        func editor(_ document: EditorDocument) -> some View {
            EditorTextView(document: document, sessionStore: store, fontSize: 14,
                lineSpacing: 2, indentationStyle: .spaces, tabWidth: 4,
                wordWrap: true, showsLineNumbers: false, topInset: 0,
                isActive: true, requestTextTransformation: { _ in })
                .disabled(state.isOpeningPlaceholder(document))
        }
        let host = NSHostingView(rootView: editor(document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let textView = try XCTUnwrap(store.coordinator(for: document).textView)
        XCTAssertFalse(textView.isEditable)
        document.ioState = .failed("failure")
        host.rootView = editor(document)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(textView.isEditable)
        document.ioState = .opening
        release.signal()
        for _ in 0..<100 where state.hasPendingOpen { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(state.hasPendingOpen)
        host.rootView = editor(document)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(textView.isEditable)
        XCTAssertEqual(document.text, "disk")

        let ordinary = EditorDocument(text: "local")
        ordinary.ioState = .failed("save failed")
        let ordinaryStore = EditorSessionStore(limit: 1)
        let ordinaryHost = NSHostingView(rootView:
            EditorTextView(document: ordinary, sessionStore: ordinaryStore, fontSize: 14,
                lineSpacing: 2, indentationStyle: .spaces, tabWidth: 4,
                wordWrap: true, showsLineNumbers: false, topInset: 0,
                isActive: true, requestTextTransformation: { _ in })
                .disabled(state.isOpeningPlaceholder(ordinary))
        )
        let ordinaryWindow = NSWindow(contentRect: window.frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        ordinaryWindow.contentView = ordinaryHost
        defer { ordinaryWindow.close() }
        ordinaryHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(try XCTUnwrap(ordinaryStore.coordinator(for: ordinary).textView).isEditable)
    }

    @MainActor
    func testEditorDefersActualMetricsUntilCompositionEnds() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "abc")
        let store = EditorSessionStore(limit: 1)
        func editor(_ size: CGFloat, _ spacing: CGFloat, _ tabs: Int) -> EditorTextView {
            EditorTextView(document: document, sessionStore: store, fontSize: size,
                lineSpacing: spacing, indentationStyle: .spaces, tabWidth: tabs,
                wordWrap: true, showsLineNumbers: false, topInset: 0,
                isActive: true, requestTextTransformation: { _ in })
        }
        let host = NSHostingView(rootView: editor(14, 2, 4))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let textView = try XCTUnwrap(store.coordinator(for: document).textView)
        let layout = try XCTUnwrap(textView.layoutManager as? FoldLayoutManager)
        window.makeFirstResponder(textView)
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 1))
        XCTAssertTrue(textView.hasMarkedText())
        host.rootView = editor(20, 6, 8)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textView.font?.pointSize, 14)
        XCTAssertEqual(textView.tabWidth, 4)
        XCTAssertEqual(layout.editorLineSpacing, 2)
        textView.unmarkText()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textView.font?.pointSize, 20)
        XCTAssertEqual(textView.tabWidth, 8)
        XCTAssertEqual(layout.editorLineSpacing, 6)

        textView.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 1))
        host.rootView = editor(16, 3, 2)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.rootView = editor(20, 6, 8)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        textView.unmarkText()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textView.font?.pointSize, 20)
        XCTAssertEqual(textView.tabWidth, 8)
        XCTAssertEqual(layout.editorLineSpacing, 6)
    }

    @MainActor
    func testMetricsWaitForCompositionAndApplyLatestUpdate() async throws {
        _ = NSApplication.shared
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        var applied = 0
        textView.applyOrDeferTextMetrics { applied = 1 }
        textView.applyOrDeferTextMetrics { applied = 2 }
        XCTAssertEqual(applied, 0)
        textView.unmarkText()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applied, 2)
    }

    @MainActor
    func testMetricsResumeAfterCommittingComposition() async throws {
        _ = NSApplication.shared
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        var applied = false
        textView.applyOrDeferTextMetrics { applied = true }
        textView.insertText("中文", replacementRange: textView.markedRange())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(applied)
    }

    @MainActor
    func testParagraphRefreshWaitsUntilCompositionEnds() async throws {
        _ = NSApplication.shared
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.string = "a\nb\nc\n"
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 123
        textView.defaultParagraphStyle = style
        textView.scheduleParagraphStyleRefresh(chunkSize: 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
                continuation.resume()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let before = textView.textStorage?.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotEqual(before?.defaultTabInterval, 123)
        textView.unmarkText()
        try await Task.sleep(for: .milliseconds(50))
        let after = textView.textStorage?.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(after?.defaultTabInterval, 123)
    }
}

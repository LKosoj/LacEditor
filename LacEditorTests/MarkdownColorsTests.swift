import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownColorsTests: XCTestCase {
    private final class Options: ObservableObject { @Published var colors = MarkdownColorOverrides() }
    private struct Host: View {
        let document: EditorDocument
        let sessions: EditorSessionStore
        @ObservedObject var options: Options
        var body: some View {
            EditorTextView(document: document, sessionStore: sessions, fontSize: 14, lineSpacing: 4,
                indentationStyle: .spaces, tabWidth: 4, wordWrap: true, showsLineNumbers: false,
                topInset: 8, isActive: true, requestTextTransformation: { _ in }, isOutlineVisible: options.colors.text != nil, colorOverrides: options.colors)
        }
    }
    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testNativeColorsAndResetPreserveTextTypingAndUndoWithEitherSyntaxSetting() async throws {
        _ = NSApplication.shared
        for syntax in [true, false] {
            let source = "plain words\n\n[link](https://example.com)\n\n`code`\n\n> quote\n\n" + String(repeating: "tail text\n", count: 80) + "\n[tail link](https://example.com)"
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            document.setOverride(syntax, for: .syntaxHighlighting)
            let sessions = EditorSessionStore(limit: 1), options = Options()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { sessions.coordinator(for: document).updateActivity(false); document.cancelMetricsRefresh(); window.close() }
            window.contentViewController = NSHostingController(rootView: Host(document: document, sessions: sessions, options: options))
            window.makeKeyAndOrderFront(nil)
            let coordinator = sessions.coordinator(for: document)
            let ready = await waitFor { coordinator.textView?.string == source }
            XCTAssertTrue(ready)
            let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(view.layoutManager)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let base = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let typing = view.typingAttributes[.foregroundColor] as? NSColor
            let red = try XCTUnwrap(MarkdownSRGBColor(red: 1, green: 0, blue: 0))
            let green = try XCTUnwrap(MarkdownSRGBColor(red: 0, green: 1, blue: 0))
            let blue = try XCTUnwrap(MarkdownSRGBColor(red: 0, green: 0, blue: 1))
            let yellow = try XCTUnwrap(MarkdownSRGBColor(red: 1, green: 1, blue: 0))
            let raw = source as NSString
            func color(_ attribute: NSAttributedString.Key, at location: Int) -> NSColor? {
                layout.temporaryAttribute(attribute, atCharacterIndex: location, effectiveRange: nil) as? NSColor
            }
            options.colors = MarkdownColorOverrides(text: red, background: blue, link: green, codeBackground: yellow, quoteBackground: green)
            let updated = await waitFor {
                color(.foregroundColor, at: 0) == red.nsColor &&
                color(.foregroundColor, at: raw.range(of: "link").location) == green.nsColor &&
                color(.backgroundColor, at: raw.range(of: "code").location) == yellow.nsColor &&
                color(.backgroundColor, at: raw.range(of: "quote").location) == green.nsColor
            }
            XCTAssertTrue(updated)
            XCTAssertEqual(view.backgroundColor, blue.nsColor)
            XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, base)
            XCTAssertEqual(view.typingAttributes[.foregroundColor] as? NSColor, typing)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertEqual(view.string, source)
            XCTAssertFalse(document.isDirty)
            XCTAssertFalse(view.undoManager?.canUndo ?? false)
            let tail = raw.range(of: "tail link")
            view.scrollRangeToVisible(tail)
            let scrolled = await waitFor { color(.foregroundColor, at: tail.location) == green.nsColor }
            XCTAssertTrue(scrolled)
            options.colors = .init()
            let reset = await waitFor { color(.foregroundColor, at: 0) != red.nsColor && view.backgroundColor != blue.nsColor }
            XCTAssertTrue(reset)
            XCTAssertEqual(view.string, source)
            XCTAssertFalse(document.isDirty)
        }
    }

    func testColorChangeWaitsForMarkedInputWithSyntaxDisabled() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "plain words", language: .markdown)
        document.setOverride(false, for: .syntaxHighlighting)
        let sessions = EditorSessionStore(limit: 1), options = Options()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); document.cancelMetricsRefresh(); window.close() }
        window.contentViewController = NSHostingController(rootView: Host(document: document, sessions: sessions, options: options))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView?.string == "plain words" }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(view.layoutManager)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let marked = view.string, markedRange = view.markedRange()
        let red = try XCTUnwrap(MarkdownSRGBColor(red: 1, green: 0, blue: 0))
        options.colors.text = red
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertTrue(coordinator.foldLayoutManager?.markdownColors.isEmpty == true)
        XCTAssertEqual(view.string, marked)
        XCTAssertEqual(view.markedRange(), markedRange)
        view.unmarkText()
        let applied = await waitFor {
            layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor == red.nsColor
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(view.string, marked)
    }

    func testColorPreferencesRoundTripAndColorOnlySnapshotKeepsFontDefaults() throws {
        let suite = "LacEditorTests.MarkdownColors.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertNil(preferences.markdownTypography)
        let color = try XCTUnwrap(MarkdownSRGBColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5))
        preferences.markdownLightColors.text = color
        XCTAssertEqual(preferences.markdownTypography?.usesCustomFontMetrics, false)
        XCTAssertEqual(preferences.markdownTypography?.lightColors.text, color)
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownLightColors.text, color)
        XCTAssertTrue(preferences.markdownDarkColors.isEmpty)
        preferences.markdownLightColors.text = nil
        XCTAssertNil(preferences.markdownTypography)
        XCTAssertNil(MarkdownSRGBColor(red: .nan, green: 0, blue: 0))
        XCTAssertNil(MarkdownSRGBColor(red: 0, green: 2, blue: 0))
        XCTAssertThrowsError(try JSONDecoder().decode(MarkdownSRGBColor.self, from: Data("{\"red\":-1,\"green\":0,\"blue\":0,\"alpha\":1}".utf8)))
    }
}

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import LacEditor

private final class ClipboardInteractionRemoteProtocol: URLProtocol {
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

private final class ClipboardDelayedRemoteProtocol: URLProtocol {
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?() }
    override func stopLoading() { Self.stopped?() }
}

@MainActor
private final class ClipboardBlockNavigation: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    init(_ finished: XCTestExpectation) { self.finished = finished }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
}

@MainActor
final class MarkdownClipboardInteractionTests: XCTestCase {
    func testRemoteCopyCancelsOnConsentRevocationWithoutWritingClipboard() async throws {
        _ = NSApplication.shared
        let started = expectation(description: "remote copy started")
        let stopped = expectation(description: "remote copy cancelled")
        ClipboardDelayedRemoteProtocol.started = { started.fulfill() }
        ClipboardDelayedRemoteProtocol.stopped = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipboardDelayedRemoteProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ClipboardDelayedRemoteProtocol.started = nil; ClipboardDelayedRemoteProtocol.stopped = nil }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "![alt](https://8.8.8.8/image.png) after"
        let document = EditorDocument(text: source, language: .markdown)
        document.allowsRemoteImages = true
        document.isMarkdownFormatted = true
        let store = EditorSessionStore(limit: 1)
        let editor = EditorTextView(document: document, sessionStore: store, fontSize: 14,
            lineSpacing: 2, indentationStyle: .spaces, tabWidth: 4, wordWrap: true,
            showsLineNumbers: false, topInset: 0, isActive: true, requestTextTransformation: { _ in })
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let coordinator = store.coordinator(for: document)
        coordinator.clipboardCopySession = session
        let view = try XCTUnwrap(coordinator.textView)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange((source as NSString).range(of: "![alt](https://8.8.8.8/image.png)"))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await fulfillment(of: [started], timeout: 10)
        document.allowsRemoteImages = false
        host.rootView = editor
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [stopped], timeout: 10)
        await task.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
    }

    func testFormattedCopyDownloadsSelectedRemoteImageIntoRTF() async throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        ClipboardInteractionRemoteProtocol.data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipboardInteractionRemoteProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ClipboardInteractionRemoteProtocol.data = Data() }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "中😀 ![alt](https://8.8.8.8/image.png)"
        let document = EditorDocument(text: source, language: .markdown)
        document.allowsRemoteImages = true
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        coordinator.clipboardCopySession = session
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange((source as NSString).range(of: "![alt](https://8.8.8.8/image.png)"))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<500 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "alt")
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64,") == true)
        let data = try XCTUnwrap(board.data(forType: .rtf))
        let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var attachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
        XCTAssertEqual(view.string, source)
    }

    func testCodeLanguageDialogCancellationAndStaleEdit() async throws {
        _ = NSApplication.shared
        let source = "```js\ncode\n```"
        let document = EditorDocument(text: source, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange((source as NSString).range(of: "code"))
        for stale in [false, true] {
            var finished = false, timedOut = false, attempts = 0
            let completed = expectation(description: stale ? "stale dialog finished" : "cancelled dialog finished")
            func act() {
                guard !finished else { return }
                attempts += 1
                if attempts > 250 { timedOut = true; finished = true; NSApp.abortModal(); completed.fulfill(); return }
                guard let content = NSApp.modalWindow?.contentView else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }; return
                }
                func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                let all = views(content)
                let buttonTitle = stale ? L10n.tr("确定") : L10n.tr("取消")
                guard let button = all.compactMap({ $0 as? NSButton }).first(where: { $0.title == buttonTitle }) else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }; return
                }
                if stale {
                    guard let input = all.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }; return
                    }
                    input.stringValue = "python"
                    view.insertText("!", replacementRange: NSRange(location: (source as NSString).length, length: 0))
                }
                finished = true
                button.performClick(nil)
                DispatchQueue.main.async { completed.fulfill() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }
            NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
                object: MarkdownClipboardRequest(documentID: document.id, command: .setCodeLanguage))
            await fulfillment(of: [completed], timeout: 10)
            finished = true
            XCTAssertFalse(timedOut)
            XCTAssertEqual(view.string, stale ? source + "!" : source)
        }
    }

    func testCodeBlockCommandsCopyAndChangeLanguageWithUndo() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "```swift linenos\r\n中😀\r\n```\r\n"
        let document = EditorDocument(text: source, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "中").location, length: 0))
        func command(_ value: MarkdownClipboardCommand) {
            NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
                object: MarkdownClipboardRequest(documentID: document.id, command: value))
        }
        board.clearContents(); board.setString("old", forType: .string)
        command(.copyCodeBlock)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "中😀\n")
        var accepted = false, attempts = 0, timedOut = false, finished = false
        func act() {
            guard !finished, !accepted, !timedOut else { return }
            attempts += 1
            if attempts > 250 { timedOut = true; NSApp.abortModal(); return }
            guard let content = NSApp.modalWindow?.contentView else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }
                return
            }
            func views(in view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { views(in: $0) }
            }
            let all = views(in: content)
            guard let input = all.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                  let button = all.compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.tr("确定") }) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }
                return
            }
            input.stringValue = "python"
            accepted = true
            button.performClick(nil)
        }
        defer { finished = true; if NSApp.modalWindow != nil { NSApp.abortModal() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }
        command(.setCodeLanguage)
        for _ in 0..<250 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(accepted)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(view.string, "```python linenos\r\n中😀\r\n```\r\n")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        let unclosed = "```js\ncode"
        view.string = unclosed
        view.setSelectedRange(NSRange(location: (unclosed as NSString).length, length: 0))
        board.clearContents(); board.setString("old", forType: .string)
        command(.copyCodeBlock)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "code\n")
        let nested = "> ```js\r\n> 中😀\r\n> ```"
        view.string = nested
        view.setSelectedRange(NSRange(location: (nested as NSString).range(of: "中").location, length: 0))
        board.clearContents(); board.setString("old", forType: .string)
        command(.copyCodeBlock)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "中😀\n")
    }

    func testThematicBreakCopiesAvailableFormatsAndExplicitHTML() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "中文😀\r\n\r\n* * *\r\n"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange((source as NSString).range(of: "* * *"))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(document.statusMessage, L10n.tr("已复制纯文本和 HTML"))
        XCTAssertEqual(board.string(forType: .string), "---")
        XCTAssertEqual(board.string(forType: .html), "<hr>")
        XCTAssertNil(board.data(forType: .rtf))
        NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
            object: MarkdownClipboardRequest(documentID: document.id, command: .copyHTML))
        for _ in 0..<250 where board.string(forType: .string) != "<hr>" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "<hr>")
        XCTAssertNil(document.statusMessage)
        XCTAssertEqual(view.string, source)
        let composite = "- ```js\r\n  中😀\r\n  ```"
        view.string = composite
        view.setSelectedRange(NSRange(location: 0, length: (composite as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "• 中😀\n")
        XCTAssertEqual(board.string(forType: .html), "<ul><li><pre><code class=\"language-js\">中😀\n</code></pre></li></ul>")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(document.statusMessage, L10n.tr("已复制纯文本和 HTML"))
        XCTAssertEqual(view.string, composite)
        let footnote = "Text[^1].\n\n[^1]: Note"
        view.string = footnote
        view.setSelectedRange((footnote as NSString).range(of: "Text[^1]."))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let copy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await copy.value
        XCTAssertEqual(board.string(forType: .string), "Text1.")
        XCTAssertEqual(board.string(forType: .html), "Text<sup>1</sup>.")
        view.setSelectedRange((footnote as NSString).range(of: "[^1]: Note"))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let definitionCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await definitionCopy.value
        XCTAssertEqual(board.string(forType: .string), "[1] Note")
        XCTAssertEqual(board.string(forType: .html), "[1] Note")
        XCTAssertEqual(view.string, footnote)
        let unusedFootnote = "Before\n\n[^unused]: Note"
        view.string = unusedFootnote
        view.setSelectedRange(NSRange(location: 0, length: (unusedFootnote as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        document.statusMessage = nil
        view.copy(nil)
        let unusedCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await unusedCopy.value
        XCTAssertEqual(board.string(forType: .string), unusedFootnote)
        XCTAssertTrue(board.string(forType: .html)?.contains("<pre><code>") == true)
        XCTAssertEqual(view.string, unusedFootnote)
        let quotedFootnote = "> Before\n>\n> [^unused]: Note"
        view.string = quotedFootnote
        view.setSelectedRange(NSRange(location: 0, length: (quotedFootnote as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let quotedCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await quotedCopy.value
        XCTAssertTrue(board.string(forType: .string)?.contains("[^unused]: Note") == true)
        XCTAssertTrue(board.string(forType: .html)?.contains("<blockquote>") == true)
        XCTAssertEqual(view.string, quotedFootnote)
        let listQuote = "- outer\n  > quoted 😀\n  > second"
        view.string = listQuote
        view.setSelectedRange(NSRange(location: 0, length: (listQuote as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let listQuoteCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await listQuoteCopy.value
        XCTAssertEqual(board.string(forType: .string), "• outer\n  > quoted 😀\n  > second")
        XCTAssertEqual(board.string(forType: .html), "<ul><li>outer<br><blockquote>quoted 😀<br>second</blockquote></li></ul>")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(view.string, listQuote)
        let listHeading = "- item\n  # 标题 😀\n\n  ---"
        view.string = listHeading
        view.setSelectedRange(NSRange(location: 0, length: (listHeading as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let listHeadingCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await listHeadingCopy.value
        XCTAssertEqual(board.string(forType: .string), "• item\n  标题 😀\n\n  ---")
        XCTAssertEqual(board.string(forType: .html), "<ul><li>item<br><h1>标题 😀</h1><br><br><hr></li></ul>")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(view.string, listHeading)
        view.string = footnote
        let partialReference = (footnote as NSString).range(of: "^1")
        view.setSelectedRange(partialReference)
        board.clearContents()
        board.setString("old", forType: .string)
        document.statusMessage = nil
        view.copy(nil)
        let partialCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await partialCopy.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(document.statusMessage, L10n.tr("无法复制格式化内容"))
        XCTAssertEqual(view.string, footnote)
        let emoji = "Before :smile: after"
        view.string = emoji
        let emojiToken = (emoji as NSString).range(of: ":smile:")
        view.setSelectedRange(NSRange(location: emojiToken.location + 1, length: emojiToken.length - 2))
        board.clearContents()
        board.setString("old", forType: .string)
        document.statusMessage = nil
        view.copy(nil)
        let emojiCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await emojiCopy.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(document.statusMessage, L10n.tr("无法复制格式化内容"))
        XCTAssertEqual(view.string, emoji)
        view.setSelectedRange(emojiToken)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let completeEmojiCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await completeEmojiCopy.value
        XCTAssertEqual(board.string(forType: .string), "😄")
        XCTAssertEqual(board.string(forType: .html), "😄")
        XCTAssertEqual(view.string, emoji)
        let aligned = "| A | B |\n| :---: | ---: |\n| x | y |"
        view.string = aligned
        view.setSelectedRange(NSRange(location: 0, length: (aligned as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "A\tB\nx\ty")
        XCTAssertEqual(board.string(forType: .html), "<table><tr><th align=\"center\">A</th><th align=\"right\">B</th></tr><tr><td align=\"center\">x</td><td align=\"right\">y</td></tr></table>")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(document.statusMessage, L10n.tr("已复制纯文本和 HTML"))
        XCTAssertEqual(view.string, aligned)
        let quoteTable = "> 中😀\r\n>\r\n> | A | B |\r\n> |---|---|\r\n> | x | y |"
        view.string = quoteTable
        view.setSelectedRange(NSRange(location: 0, length: (quoteTable as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "> 中😀\n> \n> A\tB\n> x\ty")
        XCTAssertEqual(board.string(forType: .html), "<blockquote>中😀<br><br><table><tr><th>A</th><th>B</th></tr><tr><td>x</td><td>y</td></tr></table></blockquote>")
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(document.statusMessage, L10n.tr("已复制纯文本和 HTML"))
    }

    func testFormattedCopyPreservesConfirmedUnderlineInRTF() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before <u>中😀text</u> ==highlight== ^two^ ~three~"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange((source as NSString).range(of: "😀te"))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "😀te")
        XCTAssertEqual(board.string(forType: .html), "<u>😀te</u>")
        let rtf = try XCTUnwrap(board.data(forType: .rtf))
        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(attributed.string, "😀te")
        XCTAssertEqual(attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(view.string, source)
        view.setSelectedRange((source as NSString).range(of: "==highlight== ^two^ ~three~"))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "highlight two three")
        XCTAssertEqual(board.string(forType: .html), "<mark>highlight</mark> <sup>two</sup> <sub>three</sub>")
        let decoratedRTF = try XCTUnwrap(board.data(forType: .rtf))
        let decorated = try NSAttributedString(data: decoratedRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let text = decorated.string as NSString
        guard decorated.string == "highlight two three" else { return XCTFail("RTF lost text") }
        XCTAssertNotNil(decorated.attribute(.backgroundColor, at: text.range(of: "highlight").location, effectiveRange: nil))
        let superscript = try XCTUnwrap(decorated.attribute(.baselineOffset, at: text.range(of: "two").location, effectiveRange: nil) as? NSNumber)
        let subscriptValue = try XCTUnwrap(decorated.attribute(.baselineOffset, at: text.range(of: "three").location, effectiveRange: nil) as? NSNumber)
        XCTAssertGreaterThan(superscript.doubleValue, 0)
        XCTAssertLessThan(subscriptValue.doubleValue, 0)
    }

    func testRemoteHTMLImagePasteTargetsVirtualTableCellAndUndoes() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "| A | B | C |\n|---|---|---|\n| x"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.last)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        board.clearContents()
        board.setString("<img src='https://example.com/a.png' alt='x'>", forType: .html)
        child.paste(nil)
        let task = try XCTUnwrap(coordinator.clipboardPasteTask)
        await task.value
        XCTAssertEqual(try MarkdownImageUploadService.images(in: view.string).map(\.address), ["https://example.com/a.png"])
        let updated = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.last)
        XCTAssertTrue((view.string as NSString).substring(with: updated.range).contains("https://example.com/a.png"))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testRTFImagePasteRejectsConverterDroppingOneImage() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let input = directory.appendingPathComponent("input.png")
        try png.write(to: input)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let executable = directory.appendingPathComponent("converter")
        try "#!/bin/sh\nmkdir media\ncp \(quote(input.path)) media/a.png\nprintf '%s' '![x](media/a.png)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let document = EditorDocument(text: "before", language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.string = "before"
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.clipboardConversionExecutable = executable
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        board.clearContents()
        board.setData(Data("{\\rtf1{\\pict x}{\\pict y}}".utf8), forType: .rtf)
        var waiting = true, sawPanel = false
        defer { waiting = false; if NSApp.modalWindow != nil { NSApp.abortModal() } }
        func stopUnexpectedPanel() {
            guard waiting else { return }
            if NSApp.modalWindow is NSSavePanel { sawPanel = true; NSApp.abortModal(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { stopUnexpectedPanel() }
        }
        stopUnexpectedPanel()
        view.paste(nil)
        let task = try XCTUnwrap(coordinator.clipboardPasteTask)
        await task.value
        waiting = false
        XCTAssertFalse(sawPanel)
        XCTAssertEqual(view.string, "before")
        XCTAssertEqual(document.statusMessage, L10n.tr("无法粘贴格式化内容"))
    }

    func testSavedImageNoticeFindsDocumentInAnotherWindowOnlyOnce() {
        _ = NSApplication.shared
        let manager = WindowManager()
        let source = EditorDocument(text: "source", language: .markdown)
        let other = EditorDocument(text: "other", language: .markdown)
        source.statusMessage = "source status"
        other.statusMessage = "other status"
        let sourceState = AppState(initialDocument: source, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let otherState = AppState(initialDocument: other, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let sourceWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        let sourceID = UUID(), otherID = UUID()
        manager.register(windowID: sourceID, state: sourceState, window: sourceWindow)
        manager.register(windowID: otherID, state: otherState, window: otherWindow)
        defer { manager.unregister(windowID: otherID); sourceWindow.close(); otherWindow.close() }
        manager.activate(windowID: otherID)
        let notice = ClipboardSavedImagesNotice(documentID: source.id, message: "/tmp/image.png")
        NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
        XCTAssertTrue(notice.handled)
        XCTAssertEqual(source.statusMessage, "source status\n/tmp/image.png")
        XCTAssertEqual(other.statusMessage, "other status")
    }

    func testSavedImageNoticeSurvivesSourceDocumentRelease() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let manager = WindowManager()
        let target = EditorDocument(text: "other", language: .markdown)
        target.statusMessage = "existing"
        let targetState = AppState(initialDocument: target, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let targetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        targetWindow.isReleasedWhenClosed = false
        let targetID = UUID()
        manager.register(windowID: targetID, state: targetState, window: targetWindow)
        targetWindow.makeKeyAndOrderFront(nil)
        var document: EditorDocument? = EditorDocument(text: "before", language: .markdown)
        document?.isMarkdownFormatted = true
        weak var weakDocument = document
        weakDocument = document
        var state: AppState? = AppState(initialDocument: try XCTUnwrap(document), recentFiles: manager.recentFiles, preferences: manager.preferences)
        var coordinator: EditorTextView.Coordinator? = EditorTextView.Coordinator(document: try XCTUnwrap(document))
        let storage = NSTextStorage(string: "before"), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: try XCTUnwrap(state), window: window)
        coordinator?.textView = view
        coordinator?.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator?.installObservers(scrollView: scroll)
        coordinator?.attachLiveTextProvider()
        coordinator?.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        manager.activate(windowID: id)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); if NSApp.modalWindow != nil { NSApp.abortModal() }; window.close(); targetWindow.close() }
        coordinator?.clipboardImageWrite = { data, url in
            try data.write(to: url, options: .withoutOverwriting)
            release.wait()
        }
        var waiting = true
        defer { waiting = false }
        func acceptPanel() {
            guard waiting else { return }
            if let panel = NSApp.modalWindow as? NSSavePanel {
                panel.directoryURL = directory
                panel.nameFieldStringValue = "released.png"
                panel.defaultButtonCell?.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { acceptPanel() }
        }
        let hex = png.map { String(format: "%02x", $0) }.joined()
        board.clearContents()
        board.setData(Data("{\\rtf1\\ansi {\\pict\\pngblip \(hex)}}".utf8), forType: .rtf)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        acceptPanel()
        view.paste(nil)
        let task = try XCTUnwrap(coordinator?.clipboardPasteTask)
        let output = directory.appendingPathComponent("released.png")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: output.path) { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        let wrote = FileManager.default.fileExists(atPath: output.path)
        coordinator?.updateActivity(false)
        if !wrote, NSApp.modalWindow != nil { NSApp.abortModal() }
        view.delegate = nil
        window.contentView = nil
        manager.unregister(windowID: id)
        window.close()
        coordinator = nil
        state = nil
        document = nil
        targetWindow.makeKeyAndOrderFront(nil)
        manager.activate(windowID: targetID)
        XCTAssertNil(weakDocument)
        release.signal()
        await task.value
        XCTAssertTrue(wrote)
        XCTAssertEqual(try Data(contentsOf: output), png)
        XCTAssertTrue(target.statusMessage?.hasPrefix("existing\n") == true)
        XCTAssertTrue(target.statusMessage?.contains(output.path) == true)
    }

    func testRTFImagePasteSavesChosenFileAndUndoesText() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before "
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        document.isMarkdownFormatted = true
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        var waiting = true, sawPanel = false
        defer { waiting = false; coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() }; window.close() }
        func acceptPanel() {
            guard waiting else { return }
            if let panel = NSApp.modalWindow as? NSSavePanel {
                sawPanel = true
                panel.directoryURL = directory
                panel.nameFieldStringValue = "chosen.png"
                panel.defaultButtonCell?.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { acceptPanel() }
        }
        board.clearContents()
        board.setData(Data("{\\rtf1\\ansi {\\pict\\pngblip \(hex)}}".utf8), forType: .rtf)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        acceptPanel()
        view.paste(nil)
        let pending = try XCTUnwrap(coordinator.clipboardPasteTask)
        for _ in 0..<300 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        if view.string == source { coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        await pending.value
        XCTAssertTrue(sawPanel)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: view.string).map(\.address), ["chosen.png"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("chosen.png")), png)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("chosen.png")), png)
        try await Task.sleep(for: .milliseconds(150))
        var firstPanel: NSSavePanel?, cancelledSecond = false
        waiting = true
        func selectThenCancel() {
            guard waiting else { return }
            if let panel = NSApp.modalWindow as? NSSavePanel {
                if firstPanel == nil, let button = panel.defaultButtonCell {
                    firstPanel = panel
                    panel.directoryURL = directory
                    panel.nameFieldStringValue = "partial.png"
                    button.performClick(nil)
                } else if let firstPanel, panel !== firstPanel {
                    cancelledSecond = true
                    NSApp.abortModal()
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { selectThenCancel() }
        }
        board.clearContents()
        board.setData(Data("{\\rtf1\\ansi {\\pict\\pngblip \(hex)} {\\pict\\pngblip \(hex)}}".utf8), forType: .rtf)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        selectThenCancel()
        view.paste(nil)
        let partialTask = try XCTUnwrap(coordinator.clipboardPasteTask)
        for _ in 0..<300 where !cancelledSecond { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        if !cancelledSecond { coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        await partialTask.value
        XCTAssertTrue(cancelledSecond)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("partial.png")), png)
        XCTAssertTrue(document.statusMessage?.contains(directory.appendingPathComponent("partial.png").path) == true)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        coordinator.clipboardImageWrite = { data, url in
            try data.write(to: url, options: .withoutOverwriting)
            release.wait()
        }
        waiting = true
        func acceptStalePanel() {
            guard waiting else { return }
            if let panel = NSApp.modalWindow as? NSSavePanel {
                panel.directoryURL = directory
                panel.nameFieldStringValue = "stale.png"
                panel.defaultButtonCell?.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { acceptStalePanel() }
        }
        let staleFile = directory.appendingPathComponent("stale.png")
        board.clearContents()
        board.setData(Data("{\\rtf1\\ansi {\\pict\\pngblip \(hex)}}".utf8), forType: .rtf)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        acceptStalePanel()
        view.paste(nil)
        let staleTask = try XCTUnwrap(coordinator.clipboardPasteTask)
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: staleFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        let wrote = FileManager.default.fileExists(atPath: staleFile.path)
        if wrote { view.insertText("user", replacementRange: view.selectedRange()) }
        else { coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        release.signal()
        await staleTask.value
        XCTAssertTrue(wrote)
        XCTAssertEqual(view.string, source + "user")
        XCTAssertEqual(try Data(contentsOf: staleFile), png)
        XCTAssertTrue(document.statusMessage?.contains(staleFile.path) == true)
        try await Task.sleep(for: .milliseconds(150))
        coordinator.clipboardImageWrite = { try $0.write(to: $1, options: .withoutOverwriting) }
        waiting = true
        func acceptMixedPanel() {
            guard waiting else { return }
            if let panel = NSApp.modalWindow as? NSSavePanel {
                panel.directoryURL = directory
                panel.nameFieldStringValue = "mixed.png"
                panel.defaultButtonCell?.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { acceptMixedPanel() }
        }
        let beforeMixed = view.string
        board.clearContents()
        board.setString("<p><img src='https://example.com/a.png' alt='remote'> <img src='data:image/png;base64,\(png.base64EncodedString())' alt='local'></p>", forType: .html)
        view.setSelectedRange(NSRange(location: (beforeMixed as NSString).length, length: 0))
        acceptMixedPanel()
        view.paste(nil)
        let mixedTask = try XCTUnwrap(coordinator.clipboardPasteTask)
        for _ in 0..<300 where view.string == beforeMixed { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        if view.string == beforeMixed { coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        await mixedTask.value
        XCTAssertEqual(try MarkdownImageUploadService.images(in: view.string).map(\.address), ["https://example.com/a.png", "mixed.png"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("mixed.png")), png)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, beforeMixed)
    }

    func testRTFImagePasteCancelLeavesTextUnchanged() async throws {
        _ = NSApplication.shared
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let rtf = Data("{\\rtf1\\ansi before {\\pict\\pngblip \(png.map { String(format: "%02x", $0) }.joined())} after}".utf8)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        var waiting = true, didCancel = false
        defer { waiting = false; coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        func cancelPanel() {
            guard waiting else { return }
            if NSApp.modalWindow is NSSavePanel { didCancel = true; NSApp.abortModal(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { cancelPanel() }
        }
        board.clearContents()
        board.setData(rtf, forType: .rtf)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        cancelPanel()
        view.paste(nil)
        let pending = try XCTUnwrap(coordinator.clipboardPasteTask)
        for _ in 0..<300 where !didCancel { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        XCTAssertTrue(didCancel)
        if !didCancel { coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        await pending.value
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        didCancel = false
        waiting = true
        board.clearContents()
        board.setString("<p>before <img src='data:image/png;base64,\(png.base64EncodedString())' alt='x'> after</p>", forType: .html)
        cancelPanel()
        view.paste(nil)
        let htmlPending = try XCTUnwrap(coordinator.clipboardPasteTask)
        for _ in 0..<300 where !didCancel { try await Task.sleep(for: .milliseconds(20)) }
        waiting = false
        XCTAssertTrue(didCancel)
        if !didCancel { coordinator.updateActivity(false); if NSApp.modalWindow != nil { NSApp.abortModal() } }
        await htmlPending.value
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testCopyEmbeddedImageThroughEditorPreservesSourceAndRTF() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let source = "![alt](<data:image/png;base64,\(png)> \"title\")"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "alt" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "alt")
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64,") == true)
        let rtf = try XCTUnwrap(board.data(forType: .rtf))
        let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var attachments = 0
        restored.enumerateAttribute(.attachment, in: NSRange(location: 0, length: restored.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        let remoteSource = "![remote](https://8.8.8.8/image.png)"
        view.insertText(remoteSource, replacementRange: NSRange(location: 0, length: (source as NSString).length))
        view.setSelectedRange(NSRange(location: 0, length: (remoteSource as NSString).length))
        board.clearContents()
        board.setString("old", forType: .string)
        NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
            object: MarkdownClipboardRequest(documentID: document.id, command: .copyHTML))
        for _ in 0..<250 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "<img src=\"https://8.8.8.8/image.png\" alt=\"remote\">")
        XCTAssertEqual(view.string, remoteSource)
    }

    func testExplicitSourcePasteTargetsVirtualCellWithoutEarlyMaterialization() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "| A | B | C |\n| --- | --- | --- |\n| x"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.last)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        board.clearContents()
        board.setString("|Z\nx", forType: .string)
        NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
            object: MarkdownClipboardRequest(documentID: document.id, command: .copyMarkdown))
        XCTAssertEqual(board.string(forType: .string), "|Z\nx")
        XCTAssertEqual(view.string, source)
        NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
            object: MarkdownClipboardRequest(documentID: document.id, command: .pasteSource))
        XCTAssertEqual(view.string, source + "||\\|Z<br>x")
        XCTAssertEqual(child.string, "|Z\nx")
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
    }

    func testExplicitClipboardCommandsUseActualSourceAndOneUndo() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before **bold** after"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        func command(_ action: MarkdownClipboardCommand) {
            NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
                object: MarkdownClipboardRequest(documentID: document.id, command: action))
        }
        view.setSelectedRange((source as NSString).range(of: "**bold**"))
        board.clearContents()
        board.setString("old", forType: .string)
        command(.copyMarkdown)
        for _ in 0..<250 where board.string(forType: .string) != "**bold**" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "**bold**")
        command(.copyHTML)
        for _ in 0..<250 where board.string(forType: .string) != "<strong>bold</strong>" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "<strong>bold</strong>")
        let item = NSPasteboardItem()
        item.setString("<b>wrong</b>", forType: .html)
        item.setString("**raw**", forType: .string)
        board.clearContents()
        board.writeObjects([item])
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        command(.pasteSource)
        XCTAssertEqual(view.string, source + "**raw**")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testMultipleSelectionsDoNotChangeClipboardOrPasteText() {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let document = EditorDocument(text: "one two", language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.string = "one two"
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 4, length: 3))], affinity: .downstream, stillSelecting: false)
        XCTAssertEqual(view.selectedRanges.count, 2)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        XCTAssertEqual(board.string(forType: .string), "old")
        let item = NSPasteboardItem()
        item.setString("<b>new</b>", forType: .html)
        item.setString("new", forType: .string)
        board.clearContents()
        board.writeObjects([item])
        view.paste(nil)
        XCTAssertEqual(view.string, "one two")
        XCTAssertEqual(view.selectedRanges.count, 2)
    }

    func testFormattedCopyWritesStructuralRTF() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        for source in ["| A | B |\n|---|---|\n| one | two |", "- one\n  - two\n- last", "> **two**", "## two"] {
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            coordinator.textView = view
            coordinator.foldLayoutManager = layout
            view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll)
            coordinator.updateActivity(true)
            defer { coordinator.updateActivity(false) }
            view.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
            board.clearContents()
            board.setString("old", forType: .string)
            view.copy(nil)
            for _ in 0..<250 where board.string(forType: .string) == "old" && document.statusMessage == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotEqual(board.string(forType: .string), "old")
            let attributed = try NSAttributedString(data: XCTUnwrap(board.data(forType: .rtf)), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            let two = (attributed.string as NSString).range(of: "two")
            XCTAssertNotEqual(two.location, NSNotFound)
            if two.location != NSNotFound {
                let style = attributed.attribute(.paragraphStyle, at: two.location, effectiveRange: nil) as? NSParagraphStyle
                if source.hasPrefix("|") { XCTAssertTrue(style?.textBlocks.contains { $0 is NSTextTableBlock } == true) }
                else if source.hasPrefix("-") { XCTAssertEqual(style?.textLists.count, 2) }
                else if source.hasPrefix(">") { XCTAssertTrue((style?.headIndent ?? 0) > 0 || (style?.firstLineHeadIndent ?? 0) > 0) }
                else {
                    let font = attributed.attribute(.font, at: two.location, effectiveRange: nil) as? NSFont
                    XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
                }
            }
            XCTAssertEqual(view.string, source)
        }
    }

    func testFormattedCopyOfPartialBoldProducesAllRepresentations() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before **bold** after"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let selected = (source as NSString).range(of: "ol")
        view.setSelectedRange(selected)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "ol" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "ol")
        XCTAssertEqual(board.string(forType: .html), "<strong>ol</strong>")
        let rtf = try XCTUnwrap(board.data(forType: .rtf))
        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(attributed.string, "ol")
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selected)
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        coordinator.clipboardCopyProject = { text, range, url, allowRemote, syntax, detailsOpenOverrides in
            started.signal()
            proceed.wait()
            let result = MarkdownClipboardCopyService.project(text, selection: range, includeImages: true, documentURL: url, allowRemoteImages: allowRemote, syntax: syntax, detailsOpenOverrides: detailsOpenOverrides)
            finished.signal()
            return result
        }
        defer { proceed.signal() }
        board.clearContents()
        board.setString("unchanged", forType: .string)
        view.copy(nil)
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.setSelectedRange(selected)
        proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    func testFormattedCopyOfPartialHTMLStrongUsesPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before <strong>中文😀</strong> after"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let selection = (source as NSString).range(of: "文😀")
        view.setSelectedRange(selection)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "文😀" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "文😀")
        XCTAssertEqual(board.string(forType: .html), "<strong>文😀</strong>")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
    }

    func testFormattedCopyOfKeyboardHTMLUsesPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before <kbd>中文😀</kbd> after"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange((source as NSString).range(of: "文😀"))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await task.value
        XCTAssertEqual(board.string(forType: .string), "文😀")
        XCTAssertEqual(board.string(forType: .html), "<kbd>文😀</kbd>")
        board.clearContents(); board.setString("old", forType: .string)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "<kbd>").location, length: 2))
        view.copy(nil)
        let refused = try XCTUnwrap(coordinator.clipboardCopyTask)
        await refused.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
    }

    func testFormattedCopyOfStyledSpanPreservesRTF() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before <span style='display:none;color:red;background:yellow;font-size:2rem'>**中文😀**</span> after"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange((source as NSString).range(of: "文😀"))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await task.value
        XCTAssertEqual(board.string(forType: .string), "文😀")
        XCTAssertTrue(board.string(forType: .html)?.contains("font-size:2.0rem") == true)
        XCTAssertFalse(board.string(forType: .html)?.contains("display:none") == true)
        let data = try XCTUnwrap(board.data(forType: .rtf))
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(restored.string, "文😀")
        let attributes = restored.attributes(at: 0, effectiveRange: nil)
        let foreground = try XCTUnwrap((attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        let background = try XCTUnwrap((attributes[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(foreground.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(foreground.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(background.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(background.greenComponent, 1, accuracy: 0.01)
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.1)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        board.clearContents(); board.setString("old", forType: .string)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "<span").location, length: 2))
        view.copy(nil)
        let refused = try XCTUnwrap(coordinator.clipboardCopyTask)
        await refused.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
    }

    func testFormattedCopyOfStyledTableCellUsesPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "| Left | Right |\n| --- | --- |\n| **<span style='color:red;background:yellow;font-size:2rem'>中文😀</span>** | neighbor |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange((source as NSString).range(of: "文😀"))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await task.value
        XCTAssertEqual(board.string(forType: .string), "文😀")
        XCTAssertTrue(board.string(forType: .html)?.contains("font-size:2.0rem") == true)
        let data = try XCTUnwrap(board.data(forType: .rtf))
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(restored.string, "文😀")
        let attributes = restored.attributes(at: 0, effectiveRange: nil)
        let foreground = try XCTUnwrap((attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        let background = try XCTUnwrap((attributes[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(foreground.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(foreground.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(background.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(background.greenComponent, 1, accuracy: 0.01)
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.1)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        board.clearContents(); board.setString("old", forType: .string)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "<span").location, length: 2))
        view.copy(nil)
        let refused = try XCTUnwrap(coordinator.clipboardCopyTask)
        await refused.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
    }

    func testNestedHTMLBlockSelectionMatchesWebKit() async throws {
        _ = NSApplication.shared
        let cases = ["<div>a<div><strong>中文😀</strong></div>c</div>", "<div>a<p>b</p>c</div>",
                     "<div><div>a</div><div>b</div></div>", "<div>a<div></div>b</div>"]
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let loaded = expectation(description: "HTML blocks loaded")
        let delegate = ClipboardBlockNavigation(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString(cases.map { "<section>" + $0 + "</section>" }.joined(), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let result = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('section'), x => { let r = document.createRange(); r.selectNodeContents(x); let s = getSelection(); s.removeAllRanges(); s.addRange(r); return s.toString(); })", in: nil, contentWorld: .defaultClient)
        let values = try XCTUnwrap(result as? [String])
        XCTAssertEqual(values.count, cases.count)
        for (source, expected) in zip(cases, values) {
            let raw = source as NSString
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertEqual(fragment.text, expected, source)
        }
        let script = """
        (() => {
          const e = document.createElement('section'); e.innerHTML = '<div>AA<div>BB</div><p>CC</p>DD</div>'; document.body.append(e);
          const d = e.firstElementChild, n = [d.firstChild, d.children[0].firstChild, d.children[1].firstChild, d.lastChild];
          return [[0,1],[1,2],[1,3],[0,3]].map(([a,b]) => { const r = document.createRange(); r.setStart(n[a],1); r.setEnd(n[b],1); const s = getSelection(); s.removeAllRanges(); s.addRange(r); return s.toString(); });
        })()
        """
        let partialResult = try await web.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        let partialValues = try XCTUnwrap(partialResult as? [String])
        let partialSource = "<div>AA<div>BB</div><p>CC</p>DD</div>" as NSString
        XCTAssertEqual(partialValues.count, 4)
        for ((start, end), expected) in zip([("AA", "BB"), ("BB", "CC"), ("BB", "DD"), ("AA", "DD")], partialValues) {
            let lower = partialSource.range(of: start).location + 1, upper = partialSource.range(of: end).location + 1
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(partialSource as String, selection: NSRange(location: lower, length: upper - lower)))
            XCTAssertEqual(fragment.text, expected)
        }
        let spacesScript = """
        (() => {
          const e = document.createElement('section'); e.innerHTML = '<div>aa <strong>  bb </strong> cc<div> dd </div> ee</div>'; document.body.append(e);
          const d = e.firstElementChild, n = [d.firstChild, d.children[0].firstChild];
          return [[0,2,3],[1,0,2]].map(([a,b,c]) => { const r = document.createRange(); r.setStart(n[a],b); r.setEnd(n[a],c); const s = getSelection(); s.removeAllRanges(); s.addRange(r); return s.toString(); });
        })()
        """
        let spacesResult = try await web.evaluateJavaScript(spacesScript, in: nil, contentWorld: .defaultClient)
        let spacesValues = try XCTUnwrap(spacesResult as? [String])
        XCTAssertEqual(spacesValues, [" ", ""])
        let whitespaceSource = "<div>aa <strong>  bb </strong> cc<div> dd </div> ee</div>" as NSString
        let firstSpace = NSRange(location: whitespaceSource.range(of: "aa ").location + 2, length: 1)
        XCTAssertEqual(MarkdownClipboardCopyService.project(whitespaceSource as String, selection: firstSpace)?.text, spacesValues.first)
        XCTAssertNil(MarkdownClipboardCopyService.project(whitespaceSource as String, selection: NSRange(location: whitespaceSource.range(of: "  bb").location, length: 2)))
        withExtendedLifetime(delegate) {}
    }

    func testNestedHTMLWhitespaceCopyKeepsInvisibleSelectionOutOfPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "<div>aa <strong>  bb </strong> cc<div> dd </div> ee</div>"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let raw = source as NSString
        let visible = NSRange(location: raw.range(of: "aa ").location + 2, length: 1)
        view.setSelectedRange(visible)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await task.value
        XCTAssertEqual(board.string(forType: .string), " ")
        XCTAssertTrue(board.string(forType: .html)?.contains("white-space:break-spaces") == true)
        let invisible = NSRange(location: raw.range(of: "  bb").location, length: 2)
        view.setSelectedRange(invisible)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let refused = try XCTUnwrap(coordinator.clipboardCopyTask)
        await refused.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), invisible)
    }

    func testFormattedDetailsAndSVGCopyPreservesClipboardForPartialSelection() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        for source in ["<details><summary>More</summary><strong>Body</strong></details>",
                       "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"] {
            let raw = source as NSString, document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200)); layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
            coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
            defer { coordinator.updateActivity(false); withExtendedLifetime(scroll) {} }
            view.setSelectedRange(NSRange(location: 0, length: raw.length))
            board.clearContents(); board.setString("old", forType: .string)
            view.copy(nil); await (try XCTUnwrap(coordinator.clipboardCopyTask)).value
            XCTAssertTrue(board.string(forType: .html)?.contains(source.hasPrefix("<svg") ? "data:image/svg+xml" : "<details") == true)
            let partial = NSRange(location: 0, length: raw.length - 1)
            view.setSelectedRange(partial)
            board.clearContents(); board.setString("old", forType: .string)
            view.copy(nil); await (try XCTUnwrap(coordinator.clipboardCopyTask)).value
            XCTAssertEqual(board.string(forType: .string), "old")
            XCTAssertEqual(view.string, source); XCTAssertEqual(view.selectedRange(), partial)
        }
    }

    func testFormattedDetailsCopyUsesCurrentDisclosureState() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let details = "<details><summary>More</summary><strong>Body</strong></details>"
        let source = details + "\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown); document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200)); layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close(); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(raw.range(of: "end")); coordinator.updateMarkdownPresentation()
        func button() -> NSButton? {
            view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.bezelStyle == .disclosure }
        }
        for _ in 0..<200 where button() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let disclosure = try XCTUnwrap(button()); disclosure.performClick(nil)
        XCTAssertEqual(disclosure.state, .on)
        view.setSelectedRange(raw.range(of: details))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil); await (try XCTUnwrap(coordinator.clipboardCopyTask)).value
        XCTAssertEqual(board.string(forType: .string), "More\nBody")
        XCTAssertTrue(board.string(forType: .html)?.contains("<details open") == true)
        XCTAssertEqual(view.string, source)
    }

    func testFormattedTwitterCopyUsesSandboxAndPreservesClipboardForPartialSelection() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "<blockquote class='twitter-tweet'><p lang='en'>Sunsets 中文</p><a href='https://twitter.com/Interior/status/463440424141459456'>post</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>"
        let raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        view.setSelectedRange(NSRange(location: 0, length: raw.length))
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        await (try XCTUnwrap(coordinator.clipboardCopyTask)).value
        XCTAssertEqual(board.string(forType: .string), "")
        XCTAssertTrue(board.string(forType: .html)?.contains("sandbox=\"allow-scripts\"") == true)
        XCTAssertFalse(board.string(forType: .html)?.contains("widgets.js") == true)
        XCTAssertNil(board.data(forType: .rtf))
        let partial = raw.range(of: "Sunsets 中文")
        view.setSelectedRange(partial)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        await (try XCTUnwrap(coordinator.clipboardCopyTask)).value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), partial)
    }

    func testFormattedMediaCopyPreservesClipboardForPartialSelection() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        for (tag, before, after, standalone) in [("<audio src=\"https://example.invalid/a.wav\" controls>fallback</audio>", "before ", " after", false),
                                                  ("<audio src=\"https://example.invalid/a.wav\" />", "before\n\n", "\n\nafter", true)] {
            let source = before + tag + after
            let raw = source as NSString
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
            defer { coordinator.updateActivity(false) }
            let selection = standalone ? raw.range(of: tag) : NSRange(location: 0, length: raw.length)
            view.setSelectedRange(selection)
            board.clearContents(); board.setString("old", forType: .string)
            view.copy(nil)
            let fullTask = try XCTUnwrap(coordinator.clipboardCopyTask)
            await fullTask.value
            XCTAssertEqual(board.string(forType: .string), standalone ? "" : "before  after")
            XCTAssertTrue(board.string(forType: .html)?.contains("<audio") == true)
            XCTAssertNil(board.data(forType: .rtf))
            let partial = standalone ? NSRange(location: raw.range(of: tag).location, length: 3) : raw.range(of: "fallback")
            view.setSelectedRange(partial)
            board.clearContents(); board.setString("old", forType: .string)
            view.copy(nil)
            let partialTask = try XCTUnwrap(coordinator.clipboardCopyTask)
            await partialTask.value
            XCTAssertEqual(board.string(forType: .string), "old")
            XCTAssertEqual(view.string, source)
            XCTAssertEqual(view.selectedRange(), partial)
        }
    }

    func testFormattedCopyOfStyledHTMLBlockUsesPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "<div>before <span style='color:red;background:yellow;font-size:2rem'>中文😀</span> after</div>"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let selection = NSRange(location: 0, length: (source as NSString).length)
        view.setSelectedRange(selection)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await task.value
        XCTAssertEqual(board.string(forType: .string), "before 中文😀 after")
        XCTAssertTrue(board.string(forType: .html)?.contains("font-size:2.0rem") == true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
    }

    func testFormattedCopyOfNestedHTMLBlocksUsesPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "<div>before<p><span style='color:red;background:yellow;font-size:2rem'>中文😀</span></p>after</div>"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view; coordinator.foldLayoutManager = layout; view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll); coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let selection = NSRange(location: 0, length: (source as NSString).length)
        view.setSelectedRange(selection)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let task = try XCTUnwrap(coordinator.clipboardCopyTask)
        await task.value
        XCTAssertEqual(board.string(forType: .string), "before\n中文😀\n\nafter")
        XCTAssertTrue(board.string(forType: .html)?.contains("font-size:2.0rem") == true)
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        let raw = source as NSString
        let lower = raw.range(of: "before").location + 1, upper = raw.range(of: "after").location + 1
        let partial = NSRange(location: lower, length: upper - lower)
        view.setSelectedRange(partial)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let partialTask = try XCTUnwrap(coordinator.clipboardCopyTask)
        await partialTask.value
        XCTAssertEqual(board.string(forType: .string), "efore\n中文😀\n\na")
        XCTAssertTrue(board.string(forType: .html)?.contains("font-size:2.0rem") == true)
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), partial)
    }

    func testFormattedCopyAfterReferenceDefinitionInQuoteUsesPasteboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let tag = "<img src='data:image/png;base64,\(png)' alt='image'>"
        let mixedBlock = "<div>before <strong>bold2</strong> \(tag) after</div>"
        let edgeBlock = "<div>\(tag) edge-text</div>"
        let styledImageTag = "<img src='data:image/png;base64,\(png)' alt='styled-image'>"
        let styledImageBlock = "<div><p><mark><span style='background:yellow'>\(styledImageTag)</span></mark></p></div>"
        let source = "> [id]: /url\r\n>\t中文😀 hello\r\n\r\n- [a]: /x\r\n   [b]: /y\r\n  hello\r\n\r\n- [c]: /z\r\n\t[d]: /q\r\n  end\r\n\r\n- [e]: /v\r\n  [f]: /w\r\n  中文\t**bold**\t[link][f]\r\n\r\ntext <a href='#target'>文字</a> before<br>after \(tag)\r\n\r\n\(mixedBlock)\r\n\r\n\(edgeBlock)\r\n\r\n\(styledImageBlock)"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let selection = (source as NSString).range(of: "中文😀")
        view.setSelectedRange(selection)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "中文😀" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "中文😀")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        let raw = source as NSString
        let second = raw.range(of: "   [b]: /y")
        view.setSelectedRange(second)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != " [b]: /y" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), " [b]: /y")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), second)
        let tab = raw.range(of: "\t[d]: /q")
        view.setSelectedRange(tab)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "  [d]: /q" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "  [d]: /q")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), tab)
        let bold = raw.range(of: "bold")
        view.setSelectedRange(bold)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "bold" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "bold")
        XCTAssertTrue(board.string(forType: .html)?.contains("<strong>bold</strong>") == true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), bold)
        let linked = raw.range(of: "文字")
        view.setSelectedRange(linked)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<250 where board.string(forType: .string) != "文字" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "文字")
        XCTAssertTrue(board.string(forType: .html)?.contains("href=\"#target\"") == true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), linked)
        let partialMarker = raw.range(of: "href")
        view.setSelectedRange(partialMarker)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let refused = try XCTUnwrap(coordinator.clipboardCopyTask)
        await refused.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
        let nestedImage = raw.range(of: tag, options: .backwards)
        view.setSelectedRange(nestedImage)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let nestedCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await nestedCopy.value
        XCTAssertEqual(board.string(forType: .string), "image")
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64," + png) == true)
        XCTAssertFalse(board.string(forType: .html)?.contains("before") == true)
        XCTAssertEqual(view.string, source)
        let styledImage = raw.range(of: styledImageTag)
        view.setSelectedRange(styledImage)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let styledImageCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await styledImageCopy.value
        XCTAssertEqual(board.string(forType: .string), "styled-image")
        XCTAssertTrue(board.string(forType: .html)?.contains("<mark><span style=\"background-color:") == true)
        XCTAssertTrue(board.string(forType: .html)?.contains("<p><mark>") == true)
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64," + png) == true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), styledImage)
        let mixedRange = raw.range(of: mixedBlock)
        view.setSelectedRange(mixedRange)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let mixedCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await mixedCopy.value
        XCTAssertEqual(board.string(forType: .string), "before bold2 image after")
        XCTAssertTrue(board.string(forType: .html)?.contains("<strong>bold2</strong>") == true)
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64," + png) == true)
        XCTAssertEqual(view.string, source)
        let htmlBreak = raw.range(of: "<br>")
        view.setSelectedRange(htmlBreak)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let breakCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await breakCopy.value
        XCTAssertEqual(board.string(forType: .string), "\n")
        XCTAssertTrue(board.string(forType: .html)?.contains("<br>") == true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), htmlBreak)
        let htmlImage = raw.range(of: tag)
        view.setSelectedRange(htmlImage)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let imageCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await imageCopy.value
        XCTAssertEqual(board.string(forType: .string), "image")
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64," + png) == true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), htmlImage)
        view.setSelectedRange(NSRange(location: htmlImage.location + 1, length: htmlImage.length - 2))
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        let partialImage = try XCTUnwrap(coordinator.clipboardCopyTask)
        await partialImage.value
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
        let edge = raw.range(of: " edge-text")
        view.setSelectedRange(edge)
        board.clearContents(); board.setString("old", forType: .string)
        view.copy(nil)
        let edgeCopy = try XCTUnwrap(coordinator.clipboardCopyTask)
        await edgeCopy.value
        XCTAssertEqual(board.string(forType: .string), " edge-text")
        XCTAssertFalse(board.string(forType: .html)?.contains("<img") ?? true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), edge)
    }

    func testFormattedInlineMathCopyKeepsContextAndSelectedSource() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "before $\\def\\foo{z}$ after $\\foo$ end"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let selected = (source as NSString).range(of: "$\\foo$")
        view.setSelectedRange(selected)
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<1500 where board.string(forType: .string) != "$\\foo$" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "$\\foo$")
        let html = try XCTUnwrap(board.string(forType: .html))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("\\def"))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selected)
        board.clearContents()
        board.setString("unchanged", forType: .string)
        view.copy(nil)
        let pending = try XCTUnwrap(coordinator.clipboardCopyTask)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        await pending.value
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        XCTAssertEqual(view.string, source)
    }

    func testDelayedPasteIsCancelledAfterSelectionMovesAndReturns() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = folder.appendingPathComponent("started")
        let finished = folder.appendingPathComponent("finished")
        let executable = folder.appendingPathComponent("converter")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nprintf ready > \(quote(started.path))\n/bin/sleep 1\nprintf finished > \(quote(finished.path))\nprintf converted\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        coordinator.clipboardConversionExecutable = executable
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
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
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: 1, length: 0))
        board.clearContents()
        board.setString("<p>rich</p>", forType: .html)
        child.paste(nil)
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        guard FileManager.default.fileExists(atPath: started.path) else { XCTFail("Conversion did not start"); return }
        child.setSelectedRange(NSRange(location: 2, length: 0))
        child.setSelectedRange(NSRange(location: 1, length: 0))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(child.string, "one")
        XCTAssertEqual(child.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testSourcePasteUsesPlainAlternative() {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let document = EditorDocument(text: "", language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isRichText = false
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let item = NSPasteboardItem()
        item.setString("<strong>rich</strong>", forType: .html)
        item.setString("plain", forType: .string)
        board.clearContents()
        board.writeObjects([item])
        view.paste(nil)
        XCTAssertEqual(view.string, "plain")
    }

    func testFormattedPasteConvertsHTMLInVirtualCellAndUndo() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "| A | B | C |\n| --- | --- | --- |\n| x"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.last)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let item = NSPasteboardItem()
        item.setString("<p><strong>中文😀 src=value url(example)</strong></p><!-- <img src='x'> -->", forType: .html)
        item.setString("plain alternative", forType: .string)
        board.clearContents()
        board.writeObjects([item])
        child.paste(nil)
        for _ in 0..<250 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, source + "||**中文😀 src=value url(example)**")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        try XCTUnwrap(view.undoManager).redo()
        XCTAssertEqual(view.string, source + "||**中文😀 src=value url(example)**")
    }

    func testEmbeddedImageDoesNotFallBackToPlainText() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let document = EditorDocument(text: "before", language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.string = "before"
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let item = NSPasteboardItem()
        item.setString("<p>Hello <img src='data:image/png;base64,AA=='></p>", forType: .html)
        item.setString("Hello", forType: .string)
        board.clearContents()
        board.writeObjects([item])
        view.paste(nil)
        let pending = try XCTUnwrap(coordinator.clipboardPasteTask)
        await pending.value
        XCTAssertEqual(view.string, "before")
        XCTAssertEqual(document.statusMessage, L10n.tr("无法粘贴格式化内容"))
        board.clearContents()
        board.setString("<p style='background:u\\72l(image.png)'>text</p>", forType: .html)
        view.paste(nil)
        XCTAssertEqual(view.string, "before")
        board.clearContents()
        board.setString("<p><img src='https://example.com/a.png?x=1&amp;y=2' alt='hello'> <img src='file:///tmp/lac-missing-image.png' alt='local'></p>", forType: .html)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.paste(nil)
        let remoteTask = try XCTUnwrap(coordinator.clipboardPasteTask)
        await remoteTask.value
        XCTAssertEqual(try MarkdownImageUploadService.images(in: view.string).map(\.address), ["https://example.com/a.png?x=1&y=2", "file:///tmp/lac-missing-image.png"])
        XCTAssertTrue(view.string.contains("hello"))
        let beforeRTF = view.string
        board.clearContents()
        board.setData(Data(#"{\rtf1 literal \\pict text}"#.utf8), forType: .rtf)
        view.setSelectedRange(NSRange(location: (beforeRTF as NSString).length, length: 0))
        view.paste(nil)
        let escapedTask = try XCTUnwrap(coordinator.clipboardPasteTask)
        await escapedTask.value
        XCTAssertEqual(view.string, beforeRTF + #"literal \pict text"#)
    }
}

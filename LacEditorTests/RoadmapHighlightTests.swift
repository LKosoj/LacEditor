import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

final class RoadmapHighlightTests: XCTestCase {
    func testFallbackLongMarkdownAndHTMLContextMatchesFullHighlight() {
        let filler = String(repeating: "中文😀\n", count: 20_000)
        for (language, start, end) in [
            (EditorLanguage.markdown, "```\n", "\n```"),
            (EditorLanguage.html, "<!--\n", "\n-->")
        ] {
            let text = start + filler + end
            let nsText = text as NSString
            let range = NSRange(location: nsText.length - (end as NSString).length - 500, length: 100)
            let full = SyntaxHighlighter.lexicalTokens(in: text, language: language, range: NSRange(location: 0, length: nsText.length), context: nil, revision: nil, isCancelled: { false })
            let partial = SyntaxHighlighter.lexicalTokens(in: text, language: language, range: range, context: nil, revision: nil, isCancelled: { false })
            func clipped(_ tokens: [SyntaxHighlighter.Token]) -> [SyntaxHighlighter.Token] {
                tokens.compactMap { token in
                    let intersection = NSIntersectionRange(token.range, range)
                    return intersection.length > 0 ? .init(range: intersection, kind: token.kind) : nil
                }
            }
            XCTAssertEqual(clipped(partial), clipped(full))
        }
    }

    func testMarkupContextReusesLongConstructsAndTracksEdits() {
        let filler = String(repeating: "中文😀 abc\n", count: 12_000)
        let cases: [(EditorLanguage, String, String)] = [
            (.markdown, "```\n", "\n```"),
            (.html, "<!--\n", "\n-->"),
            (.html, "<tag value=\"", "\">"),
        ]
        for (language, opening, closing) in cases {
            let source = opening + filler + closing + " tail"
            let length = (source as NSString).length
            let context = SyntaxHighlighter.IncrementalContext()
            func tokens(_ text: String, _ range: NSRange, _ cache: SyntaxHighlighter.IncrementalContext?, _ revision: UInt?) -> [SyntaxHighlighter.Token] {
                SyntaxHighlighter.lexicalTokens(in: text, language: language, range: range,
                    context: cache, revision: revision, isCancelled: { false })
            }
            func clipped(_ tokens: [SyntaxHighlighter.Token], _ range: NSRange) -> [SyntaxHighlighter.Token] {
                tokens.compactMap { token in
                    let intersection = NSIntersectionRange(token.range, range)
                    return intersection.length > 0 ? .init(range: intersection, kind: token.kind) : nil
                }
            }
            let full = tokens(source, NSRange(location: 0, length: length), nil, nil)
            for location in [1, length / 2, length - 10] {
                let range = NSRange(location: location, length: min(5, length - location))
                XCTAssertEqual(clipped(tokens(source, range, context, 1), range), clipped(full, range))
            }
            let prepared = context.preparedThrough
            let deep = NSRange(location: length / 2, length: 4)
            _ = tokens(source, deep, context, 1)
            XCTAssertEqual(context.preparedThrough, prepared)

            let updated = (source as NSString).replacingCharacters(in: NSRange(location: 0, length: (opening as NSString).length), with: "")
            context.invalidate(after: 0)
            let updatedLength = (updated as NSString).length
            let updatedRange = NSRange(location: updatedLength / 2, length: 5)
            let expected = tokens(updated, NSRange(location: 0, length: updatedLength), nil, nil)
            XCTAssertEqual(clipped(tokens(updated, updatedRange, context, 2), updatedRange), clipped(expected, updatedRange))
            XCTAssertEqual(clipped(tokens(source, deep, context, 4), deep), clipped(full, deep))
            let closingLocation = (opening as NSString).length + (filler as NSString).length
            let withoutClosing = (source as NSString).replacingCharacters(
                in: NSRange(location: closingLocation, length: (closing as NSString).length), with: "")
            context.invalidate(after: closingLocation)
            let changedLength = (withoutClosing as NSString).length
            let nearEnd = NSRange(location: changedLength - 5, length: 4)
            let changedFull = tokens(withoutClosing, NSRange(location: 0, length: changedLength), nil, nil)
            XCTAssertEqual(clipped(tokens(withoutClosing, nearEnd, context, 5), nearEnd), clipped(changedFull, nearEnd))
        }
    }

    func testLongOpenFenceAndCommentAdvanceOnlyToRequestedRange() {
        let filler = String(repeating: "中文😀 text\n", count: 20_000)
        for (language, opening, closing) in [
            (EditorLanguage.markdown, "```\n", "\n```"),
            (EditorLanguage.html, "<!--\n", "\n-->")
        ] {
            let text = opening + filler + closing
            let context = SyntaxHighlighter.IncrementalContext()
            let range = NSRange(location: 20, length: 10)
            let result = SyntaxHighlighter.lexicalTokens(in: text, language: language, range: range,
                context: context, revision: 1, isCancelled: { false })
            XCTAssertTrue(result.contains { NSIntersectionRange($0.range, range).length == range.length })
            XCTAssertLessThanOrEqual(context.preparedThrough, NSMaxRange(range) + 4)
            let prepared = context.preparedThrough
            _ = SyntaxHighlighter.lexicalTokens(in: text, language: language, range: range,
                context: context, revision: 1, isCancelled: { false })
            XCTAssertEqual(context.preparedThrough, prepared)
        }
    }

    func testClosingUnfinishedTagAndInlineAfterEdit() {
        for (language, source, closing) in [
            (EditorLanguage.html, "<tag attr=\"中文😀\"", ">"),
            (EditorLanguage.markdown, "prefix `中文😀", "`")
        ] {
            let context = SyntaxHighlighter.IncrementalContext()
            let range = NSRange(location: (source as NSString).length - 3, length: 2)
            let initial = SyntaxHighlighter.lexicalTokens(in: source, language: language, range: range,
                context: context, revision: 1, isCancelled: { false })
            XCTAssertFalse(initial.contains { $0.kind == .markup || $0.kind == .string })
            let updated = source + closing
            context.invalidate(after: (source as NSString).length)
            let length = (updated as NSString).length
            let changedRange = NSRange(location: 0, length: length)
            let cached = SyntaxHighlighter.lexicalTokens(in: updated, language: language, range: changedRange,
                context: context, revision: 2, isCancelled: { false })
            let fresh = SyntaxHighlighter.lexicalTokens(in: updated, language: language, range: changedRange,
                context: nil, revision: nil, isCancelled: { false })
            XCTAssertEqual(cached, fresh)
            XCTAssertTrue(cached.contains { $0.kind == (language == .html ? .markup : .string) })
        }
    }

    func testNilRevisionDoesNotReuseMarkupCache() {
        let context = SyntaxHighlighter.IncrementalContext()
        let text = "<!-- comment -->"
        let range = NSRange(location: 0, length: 5)
        _ = SyntaxHighlighter.lexicalTokens(in: text, language: .html, range: range,
            context: context, revision: 0, isCancelled: { false })
        let fresh = SyntaxHighlighter.lexicalTokens(in: "plain text here!", language: .html, range: range,
            context: context, revision: nil, isCancelled: { false })
        XCTAssertTrue(fresh.isEmpty)
    }

    func testUnfinishedNestedTagsDoNotRepeatedlyScanTail() {
        let text = String(repeating: "<a ", count: 40_000)
        let length = (text as NSString).length
        var checks = 0
        let context = SyntaxHighlighter.IncrementalContext()
        let result = SyntaxHighlighter.lexicalTokens(in: text, language: .html,
            range: NSRange(location: length - 10, length: 5), context: context, revision: 1,
            isCancelled: { checks += 1; return checks > 100 })
        XCTAssertTrue(result.isEmpty)
        XCTAssertLessThan(checks, 100)
        XCTAssertEqual(context.preparedThrough, length)
    }

    func testStaleRevisionCannotRestoreInvalidatedMarkup() {
        let original = "<!-- 中文😀 --> tail"
        let changed = "plain 中文😀 text tail"
        let context = SyntaxHighlighter.IncrementalContext()
        let range = NSRange(location: 0, length: (original as NSString).length)
        _ = SyntaxHighlighter.lexicalTokens(in: original, language: .html, range: range,
            context: context, revision: 1, isCancelled: { false })
        context.invalidate(after: 0)
        let stale = SyntaxHighlighter.lexicalTokens(in: original, language: .html, range: range,
            context: context, revision: 1, isCancelled: { false })
        XCTAssertTrue(stale.isEmpty)
        let changedRange = NSRange(location: 0, length: (changed as NSString).length)
        let current = SyntaxHighlighter.lexicalTokens(in: changed, language: .html, range: changedRange,
            context: context, revision: 2, isCancelled: { false })
        XCTAssertTrue(current.isEmpty)
    }

    func testInvalidationDuringMarkupScanDoesNotBlockOrCommit() {
        let completed = expectation(description: "scan completes after invalidation")
        let text = "<tag value=\"" + String(repeating: "中文😀", count: 40_000) + "\">"
        let context = SyntaxHighlighter.IncrementalContext()
        DispatchQueue.global().async {
            var checks = 0
            let result = SyntaxHighlighter.lexicalTokens(in: text, language: .html,
                range: NSRange(location: 0, length: 8), context: context, revision: 1,
                isCancelled: {
                    checks += 1
                    if checks == 2 { context.invalidate(after: 0) }
                    return false
                })
            XCTAssertTrue(result.isEmpty)
            XCTAssertEqual(context.preparedThrough, 0)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testCancelledMarkupPreparationIsNotCommitted() {
        let text = String(repeating: "中文😀 text\n", count: 20_000) + "<!-- end -->"
        let context = SyntaxHighlighter.IncrementalContext()
        var checks = 0
        let range = NSRange(location: (text as NSString).length - 10, length: 5)
        let result = SyntaxHighlighter.lexicalTokens(in: text, language: .html, range: range,
            context: context, revision: 1, isCancelled: { checks += 1; return checks > 2 })
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(context.preparedThrough, 0)
        let completed = SyntaxHighlighter.lexicalTokens(in: text, language: .html, range: range,
            context: context, revision: 1, isCancelled: { false })
        XCTAssertTrue(completed.contains { $0.kind == .comment })
    }

    func testRemovingProcessedRangeKeepsUnprocessedParts() {
        var ranges = DirtyRangeAccumulator()
        ranges.invalidate(NSRange(location: 10, length: 100))
        ranges.remove(NSRange(location: 40, length: 20))
        XCTAssertEqual(ranges.ranges, [NSRange(location: 10, length: 30), NSRange(location: 60, length: 50)])
    }

    func testJSONLongStringContextMatchesFullHighlight() {
        let text = "[\"" + String(repeating: "中文😀", count: 20_000) + "\"]"
        let length = (text as NSString).length
        let range = NSRange(location: length - 300, length: 100)
        let context = SyntaxHighlighter.IncrementalContext()
        let full = SyntaxHighlighter.lexicalTokens(in: text, language: .json, range: NSRange(location: 0, length: length), context: context, revision: 1, isCancelled: { false })
        let partial = SyntaxHighlighter.lexicalTokens(in: text, language: .json, range: range, context: context, revision: 1, isCancelled: { false })
        func clipped(_ tokens: [SyntaxHighlighter.Token]) -> [SyntaxHighlighter.Token] {
            tokens.compactMap { token in
                let intersection = NSIntersectionRange(token.range, range)
                return intersection.length > 0 ? .init(range: intersection, kind: token.kind) : nil
            }
        }
        XCTAssertEqual(clipped(partial), clipped(full))
    }

    func testLargeCodeUsesLexicalFallback() {
        let text = "// 中文😀\n" + String(repeating: " ", count: 20 * 1_024 * 1_024)
        let tokens = SyntaxHighlighter.tokens(in: text, language: .javascript,
            range: NSRange(location: 0, length: 8))
        XCTAssertTrue(tokens.contains { $0.kind == .comment })
    }

    func testFallbackCancellationStopsLongHTMLScan() {
        let text = String(repeating: "中文😀\n", count: 20_000) + "<!-- tail -->"
        var checks = 0
        let tokens = SyntaxHighlighter.lexicalTokens(in: text, language: .html,
            range: NSRange(location: (text as NSString).length - 10, length: 8),
            context: nil, revision: nil, isCancelled: { checks += 1; return checks > 2 })
        XCTAssertTrue(tokens.isEmpty)
        XCTAssertGreaterThan(checks, 2)
    }

    func testFallbackAfterRemovingLongMultilineOpeningMatchesFull() {
        let filler = String(repeating: "中文😀 text\n", count: 10_000)
        for (language, opening, closing) in [
            (EditorLanguage.markdown, "```\n", "\n```"),
            (EditorLanguage.html, "<!--\n", "\n-->")
        ] {
            let source = opening + filler + closing
            let updated = (source as NSString).replacingCharacters(
                in: NSRange(location: 0, length: (opening as NSString).length), with: ""
            )
            let length = (updated as NSString).length
            let range = NSRange(location: length - 500, length: 100)
            let full = SyntaxHighlighter.lexicalTokens(in: updated, language: language,
                range: NSRange(location: 0, length: length), context: nil, revision: nil, isCancelled: { false })
            let partial = SyntaxHighlighter.lexicalTokens(in: updated, language: language,
                range: range, context: nil, revision: nil, isCancelled: { false })
            func clipped(_ tokens: [SyntaxHighlighter.Token]) -> [SyntaxHighlighter.Token] {
                tokens.compactMap { token in
                    let intersection = NSIntersectionRange(token.range, range)
                    return intersection.length > 0 ? .init(range: intersection, kind: token.kind) : nil
                }
            }
            XCTAssertEqual(clipped(partial), clipped(full))
        }
    }

    @MainActor
    func testCoordinatorRecomputesInvalidTailWhenScrolledIntoView() async throws {
        _ = NSApplication.shared
        let source = "/*\n" + String(repeating: "          \n", count: 8_000) + "*/\n"
        let document = EditorDocument(text: source, language: .javascript)
        let store = EditorSessionStore(limit: 1)
        let host = NSHostingView(rootView: EditorTextView(document: document,
            sessionStore: store, fontSize: 14, lineSpacing: 2, indentationStyle: .spaces,
            tabWidth: 4, wordWrap: false, showsLineNumbers: false, topInset: 0,
            isActive: true, requestTextTransformation: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let coordinator = store.coordinator(for: document)
        let textView = try XCTUnwrap(coordinator.textView)
        let storage = try XCTUnwrap(textView.textStorage)
        let layout = try XCTUnwrap(textView.layoutManager)
        let location = (source as NSString).length - 100
        textView.scrollRangeToVisible(NSRange(location: location, length: 1))
        coordinator.scheduleHighlight(delay: 0)
        for _ in 0..<200 {
            if layout.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 1))
        coordinator.scheduleHighlight(delay: 0)
        for _ in 0..<200 {
            if layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 10, effectiveRange: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 10, effectiveRange: nil))
        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: 0, length: 2), replacementString: "//"))
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "//")
        textView.didChangeText()
        coordinator.scheduleHighlight(delay: 0)
        for _ in 0..<200 {
            if layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 10, effectiveRange: nil) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 10, effectiveRange: nil))
        textView.scrollRangeToVisible(NSRange(location: location, length: 1))
        coordinator.scheduleHighlight(delay: 0)
        for _ in 0..<200 {
            if layout.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil))
    }

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
    func testTreeChangedRangesAndSkippedRevisionMatchFullParse() {
        let backend = TreeSitterJavaScriptBackend()
        let id = UUID()
        let source = "/*\n" + String(repeating: "中文😀 text\n", count: 10_000) + "*/\nconst value = 1;"
        let editRange = NSRange(location: 0, length: 2)
        let updated = (source as NSString).replacingCharacters(in: editRange, with: "//")
        let edit = DocumentEditDelta(documentID: id, revision: 2, editedRange: editRange,
            replacementLength: 2, changeInLength: 0, changedLineRange: nil)
        let range = NSRange(location: (updated as NSString).length - 100, length: 80)
        func tokens(_ text: String, id: UUID, revision: UInt, edit: DocumentEditDelta? = nil,
                    cancelled: @escaping () -> Bool = { false }) -> [SyntaxHighlighter.Token] {
            backend.tokens(in: text, language: .javascript, range: range, context: nil,
                revision: revision, documentID: id, edit: edit, isCancelled: cancelled)
        }
        _ = tokens(source, id: id, revision: 1)
        let incremental = tokens(updated, id: id, revision: 2, edit: edit)
        let changed = SyntaxParserRegistry.changedRanges(documentID: id, revision: 2, language: .javascript)
        XCTAssertNotNil(changed)
        XCTAssertFalse(changed?.isEmpty ?? true)
        XCTAssertTrue(changed?.allSatisfy { NSMaxRange($0) <= (updated as NSString).length } == true)
        XCTAssertEqual(incremental, tokens(updated, id: UUID(), revision: 2))
        _ = tokens(source, id: id, revision: 3, cancelled: { true })
        XCTAssertEqual(tokens(updated, id: id, revision: 4), tokens(updated, id: UUID(), revision: 4))
        XCTAssertNil(SyntaxParserRegistry.changedRanges(documentID: id, revision: 4, language: .javascript))
    }
#endif
}

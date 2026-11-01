import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class FindScopeTests: XCTestCase {
    private func nsRange(of needle: String, in text: String, occurrence: Int = 0) -> NSRange {
        var found = NSRange(location: 0, length: 0)
        var search = NSRange(location: 0, length: (text as NSString).length)
        for _ in 0...occurrence {
            found = (text as NSString).range(of: needle, options: [], range: search)
            search = NSRange(location: NSMaxRange(found), length: (text as NSString).length - NSMaxRange(found))
        }
        return found
    }

    // MARK: Чистые функции

    func testScopeLimitsPlainMatches() {
        let text = "cat | cat | cat"
        let ranges = TextSearchService.allRanges(in: text, query: "cat", caseSensitive: false, scope: NSRange(location: 6, length: 3))
        XCTAssertEqual(ranges, [NSRange(location: 6, length: 3)])
    }

    func testScopeLimitsRegexMatches() throws {
        let text = "cat | cat | cat"
        let scope = NSRange(location: 6, length: 3)
        for options in [TextSearchService.Options(usesRegex: true), TextSearchService.Options(wholeWord: true)] {
            XCTAssertEqual(try TextSearchService.allRanges(in: text, query: "cat", options: options, scope: scope), [scope])
        }
    }

    func testScopeBoundsAreTransparent() throws {
        let word = TextSearchService.Options(wholeWord: true)
        XCTAssertEqual(try TextSearchService.allRanges(in: "concat cat", query: "cat", options: word, scope: NSRange(location: 3, length: 3)), [])
        let regex = TextSearchService.Options(usesRegex: true)
        XCTAssertEqual(try TextSearchService.allRanges(in: "ab\ncd", query: "^b", options: regex, scope: NSRange(location: 1, length: 1)), [])
        XCTAssertEqual(try TextSearchService.allRanges(in: "ab\ncd", query: "^cd", options: regex, scope: NSRange(location: 3, length: 2)),
                       [NSRange(location: 3, length: 2)])
        XCTAssertEqual(try TextSearchService.allRanges(in: "ab\ncd", query: "(?<=a)b", options: regex, scope: NSRange(location: 1, length: 1)),
                       [NSRange(location: 1, length: 1)])
    }

    func testScopeUsesUTF16WithEmojiBefore() throws {
        let text = "😀 cat | cat"
        let scope = nsRange(of: "cat", in: text, occurrence: 1)
        XCTAssertEqual(TextSearchService.allRanges(in: text, query: "cat", caseSensitive: false, scope: scope), [scope])
        let result = try TextSearchService.replaceAll(in: text, query: "cat", replacement: "dog", options: .init(), interpretsEscapes: false, scope: scope)
        XCTAssertEqual(result.text, "😀 cat | dog")
        XCTAssertEqual(result.count, 1)
    }

    func testScopeSkipsDataAddresses() throws {
        let text = "Y2F0 ![a](data:image/png;base64,Y2F0Y2F0) Y2F0"
        let whole = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertEqual(TextSearchService.allRanges(in: text, query: "Y2F0", caseSensitive: false, scope: whole).count, 2)
        let result = try TextSearchService.replaceAll(in: text, query: "Y2F0", replacement: "x", options: .init(), interpretsEscapes: false, scope: whole)
        XCTAssertEqual(result.text, "x ![a](data:image/png;base64,Y2F0Y2F0) x")
        let inner = nsRange(of: "data:", in: text)
        XCTAssertEqual(TextSearchService.allRanges(in: text, query: "Y2F0", caseSensitive: false,
                                                   scope: NSRange(location: inner.location, length: 20)), [])
    }

    func testScopeIsClampedAndEmptyScopeFindsNothing() {
        let text = "cat cat"
        XCTAssertEqual(TextSearchService.allRanges(in: text, query: "cat", caseSensitive: false, scope: NSRange(location: 4, length: 100)),
                       [NSRange(location: 4, length: 3)])
        XCTAssertEqual(TextSearchService.allRanges(in: text, query: "cat", caseSensitive: false, scope: NSRange(location: 0, length: 0)), [])
        XCTAssertEqual(TextSearchService.allRanges(in: text, query: "cat", caseSensitive: false, scope: NSRange(location: 50, length: 3)), [])
    }

    func testReplaceAllWithScopeChangesOnlyScope() throws {
        let text = "cat | cat | cat"
        let scope = NSRange(location: 6, length: 3)
        let plain = try TextSearchService.replaceAll(in: text, query: "cat", replacement: "dog", options: .init(), interpretsEscapes: true, scope: scope)
        XCTAssertEqual(plain.text, "cat | dog | cat")
        XCTAssertEqual(plain.count, 1)
        let regex = try TextSearchService.replaceAll(in: text, query: "(c)at", replacement: "$1og", options: .init(usesRegex: true),
                                                     interpretsEscapes: true, scope: scope)
        XCTAssertEqual(regex.text, "cat | cog | cat")
        XCTAssertEqual(regex.count, 1)
        let word = try TextSearchService.replaceAll(in: text, query: "cat", replacement: "dog", options: .init(wholeWord: true),
                                                    interpretsEscapes: true, scope: scope)
        XCTAssertEqual(word.text, "cat | dog | cat")
        XCTAssertEqual(word.count, 1)
        let unscoped = try TextSearchService.replaceAll(in: text, query: "cat", replacement: "dog", options: .init(), interpretsEscapes: true)
        XCTAssertEqual(unscoped.text, "dog | dog | dog")
        XCTAssertEqual(unscoped.count, 3)
    }

    func testReplacementForSelectionOutsideScopeIsNil() throws {
        let text = "cat | cat"
        let scope = NSRange(location: 6, length: 3)
        for options in [TextSearchService.Options(), TextSearchService.Options(usesRegex: true)] {
            XCTAssertNil(try TextSearchService.replacement(forSelection: NSRange(location: 0, length: 3), in: text, query: "cat",
                replacement: "dog", options: options, interpretsEscapes: true, scope: scope))
            XCTAssertEqual(try TextSearchService.replacement(forSelection: scope, in: text, query: "cat",
                replacement: "dog", options: options, interpretsEscapes: true, scope: scope), "dog")
        }
    }

    func testSearchableRangesIntersectWithScope() {
        let text = "ab ![a](data:image/png;base64,Y2F0Y2F0) cd"
        let length = (text as NSString).length
        XCTAssertEqual(TextSearchService.searchableRanges(in: text).count, 2)
        XCTAssertEqual(TextSearchService.searchableRanges(in: text, scope: NSRange(location: 0, length: length)).count, 2)
        let trimmed = TextSearchService.searchableRanges(in: text, scope: NSRange(location: 1, length: length - 2))
        XCTAssertEqual(trimmed.count, 2)
        XCTAssertEqual(trimmed.first?.location, 1)
        XCTAssertEqual(trimmed.last.map(NSMaxRange), length - 1)
        XCTAssertEqual(TextSearchService.searchableRanges(in: text, scope: NSRange(location: 0, length: 2)).count, 1)
    }

    func testCacheKeyDiffersByScope() {
        let first = TextSearchService.CacheKey(revision: 1, query: "a", caseSensitive: false, scope: NSRange(location: 0, length: 1))
        let second = TextSearchService.CacheKey(revision: 1, query: "a", caseSensitive: false, scope: NSRange(location: 1, length: 1))
        let none = TextSearchService.CacheKey(revision: 1, query: "a", caseSensitive: false)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, none)
        var cache = SearchMatchCacheStore()
        let id = UUID()
        cache.insert(.init(key: first, matches: [NSRange(location: 0, length: 1)]), for: id)
        XCTAssertNil(cache.value(for: id, key: second))
        XCTAssertNil(cache.value(for: id, key: none))
        XCTAssertNotNil(cache.value(for: id, key: first))
    }


    // MARK: Состояние AppState

    private func makeState(_ text: String, language: EditorLanguage = .plainText) throws -> (AppState, EditorDocument) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditorFindScope.\(UUID())"))
        let document = EditorDocument(text: text, language: language)
        let state = AppState(
            initialDocument: document,
            recentFiles: RecentFilesStore(defaults: defaults),
            preferences: AppPreferences(defaults: defaults)
        )
        return (state, document)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testEnablingScopeRequiresSelection() throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 3, length: 0)
        state.setFindInSelection(true)
        XCTAssertNil(state.findReplace.scope)
        XCTAssertEqual(state.findReplace.messageKind, .error)
        XCTAssertEqual(state.findReplace.message, L10n.tr("请先选中文本"))
        document.selectionRange = NSRange(location: 10, length: 50)
        state.setFindInSelection(true)
        XCTAssertNil(state.findReplace.scope)
    }

    func testEnablingScopeCapturesSelectionAndRevision() throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.setFindInSelection(true)
        let scope = try XCTUnwrap(state.findReplace.scope)
        XCTAssertEqual(scope.range, NSRange(location: 6, length: 3))
        XCTAssertEqual(scope.revision, document.textRevision)
        XCTAssertEqual(scope.documentID, document.id)
        state.setFindInSelection(false)
        XCTAssertNil(state.findReplace.scope)
    }

    func testScopedFindCountsOnlyInsideScope() async throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.presentFindReplace(mode: .find)
        state.findReplace.query = "cat"
        state.setFindInSelection(true)
        await waitUntil { state.findReplace.matches == [NSRange(location: 6, length: 3)] }
        XCTAssertEqual(state.findReplace.matches, [NSRange(location: 6, length: 3)])
    }

    func testContentChangeNotificationClearsScopeWithNotice() async throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.presentFindReplace(mode: .find)
        state.findReplace.query = "cat"
        state.setFindInSelection(true)
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
        await waitUntil { state.findReplace.scope == nil }
        XCTAssertNil(state.findReplace.scope)
        XCTAssertEqual(state.findReplace.messageKind, .notice)
        XCTAssertEqual(state.findReplace.message, L10n.tr("文本已变化，已取消选区查找"))
        await waitUntil(timeout: 1) { state.findReplace.matches?.count == 3 }
        XCTAssertEqual(state.findReplace.messageKind, .notice)
    }

    func testRevisionMismatchRefusesToRunOutsideScope() throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.findReplace.query = "cat"
        state.findReplace.replacement = "dog"
        state.setFindInSelection(true)
        document.text = "cat | cat | cat!"
        state.findNext()
        XCTAssertNil(state.findReplace.scope)
        XCTAssertEqual(state.findReplace.message, L10n.tr("文本已变化，已取消选区查找"))
        XCTAssertFalse(state.findReplace.isWorking)
        document.selectionRange = NSRange(location: 6, length: 3)
        state.setFindInSelection(true)
        document.text = "cat | cat | cat!!"
        state.replaceAllMatches()
        XCTAssertEqual(document.text, "cat | cat | cat!!")
        XCTAssertNil(state.findReplace.scope)
    }

    func testReplaceAllWithScopeChangesOnlyScopeAndClearsIt() async throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.findReplace.query = "cat"
        state.findReplace.replacement = "dog"
        state.setFindInSelection(true)
        state.replaceAllMatches()
        await waitUntil { document.text == "cat | dog | cat" }
        XCTAssertEqual(document.text, "cat | dog | cat")
        XCTAssertNil(state.findReplace.scope)
        XCTAssertEqual(state.findReplace.message, L10n.tr("已替换 %@ 处", "1"))
        XCTAssertEqual(state.findReplace.messageKind, .success)
    }

    func testReplaceAllWithZeroMatchesKeepsScope() async throws {
        let (state, document) = try makeState("cat | dog | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.findReplace.query = "cat"
        state.findReplace.replacement = "x"
        state.setFindInSelection(true)
        state.replaceAllMatches()
        await waitUntil { !state.findReplace.isWorking && state.findReplace.messageKind == .error }
        XCTAssertEqual(document.text, "cat | dog | cat")
        XCTAssertNotNil(state.findReplace.scope)
    }

    func testReplaceCurrentShiftsScope() throws {
        let (state, document) = try makeState("x cat cat y")
        document.selectionRange = NSRange(location: 2, length: 7)
        state.findReplace.query = "cat"
        state.findReplace.replacement = "doggo"
        state.setFindInSelection(true)
        document.selectionRange = NSRange(location: 2, length: 3)
        state.replaceCurrentMatch(keepFocusInBar: true)
        XCTAssertEqual(document.text, "x doggo cat y")
        let scope = try XCTUnwrap(state.findReplace.scope)
        XCTAssertEqual(scope.range, NSRange(location: 2, length: 9))
        XCTAssertEqual(scope.revision, document.synchronizedSnapshot().revision)
        XCTAssertNotEqual(state.findReplace.message, L10n.tr("文本已变化，已取消选区查找"))
    }

    func testTabSwitchAndDismissClearScope() throws {
        let (state, document) = try makeState("cat | cat | cat")
        let other = EditorDocument(text: "cat cat", language: .plainText)
        state.documents.append(other)
        document.selectionRange = NSRange(location: 6, length: 3)
        state.setFindInSelection(true)
        XCTAssertNotNil(state.findReplace.scope)
        state.selectedDocumentID = other.id
        XCTAssertNil(state.findReplace.scope)
        other.selectionRange = NSRange(location: 0, length: 3)
        state.setFindInSelection(true)
        XCTAssertEqual(state.findReplace.scope?.documentID, other.id)
        state.dismissFindReplace()
        XCTAssertNil(state.findReplace.scope)
    }

    func testReadingModeKeepsScopeAndRefusesReplace() throws {
        let (state, document) = try makeState("cat | cat | cat", language: .markdown)
        document.selectionRange = NSRange(location: 6, length: 3)
        state.findReplace.query = "cat"
        state.findReplace.replacement = "dog"
        state.setFindInSelection(true)
        document.setReadingMode(true)
        state.replaceAllMatches()
        XCTAssertEqual(document.text, "cat | cat | cat")
        XCTAssertEqual(state.findReplace.message, L10n.tr("阅读模式下无法修改"))
        XCTAssertNotNil(state.findReplace.scope)
    }

    func testScopeChangeDuringReplaceCancelsTask() throws {
        let (state, document) = try makeState("cat | cat | cat")
        document.selectionRange = NSRange(location: 6, length: 3)
        state.findReplace.query = "cat"
        state.findReplace.replacement = "dog"
        state.setFindInSelection(true)
        state.replaceAllMatches()
        XCTAssertTrue(state.findReplace.isWorking)
        state.setFindInSelection(false)
        XCTAssertFalse(state.findReplace.isWorking)
        XCTAssertEqual(state.findReplace.message, L10n.tr("已取消"))
        XCTAssertEqual(document.text, "cat | cat | cat")
    }

    func testOpenExtractedTextCreatesUnsavedPlainTextTab() throws {
        let (state, _) = try makeState("x")
        state.openExtractedText("a\nb\n", count: 2)
        let document = try XCTUnwrap(state.selectedDocument)
        XCTAssertEqual(state.documents.count, 2)
        XCTAssertEqual(document.language, .plainText)
        XCTAssertTrue(document.isDirty)
        XCTAssertNil(document.url)
        XCTAssertEqual(document.text, "a\nb\n")
        XCTAssertEqual(document.statusMessage, L10n.tr("已提取 %d 条", 2))
    }

    func testExtractMatchesOpensTabAndKeepsSourceText() async throws {
        let (state, document) = try makeState("cat dog\nbird\ncat")
        state.findReplace.query = "cat"
        state.extractMatches(.line)
        await waitUntil { state.documents.count == 2 }
        XCTAssertEqual(document.text, "cat dog\nbird\ncat")
        XCTAssertEqual(state.selectedDocument?.text, "cat dog\ncat\n")
        XCTAssertEqual(state.findReplace.messageKind, .success)
    }

    func testExtractWithEmptyTemplateAndNoMatchesCreatesNoTab() async throws {
        let (state, _) = try makeState("cat")
        state.findReplace.query = "cat"
        state.extractMatches(.template)
        XCTAssertEqual(state.findReplace.message, L10n.tr("请先在“替换为”中输入模板"))
        XCTAssertEqual(state.documents.count, 1)
        state.findReplace.query = "zzz"
        state.extractMatches(.match)
        await waitUntil { !state.findReplace.isWorking && state.findReplace.messageKind == .error }
        XCTAssertEqual(state.findReplace.message, L10n.tr("没有可提取的内容"))
        XCTAssertEqual(state.documents.count, 1)
    }
}

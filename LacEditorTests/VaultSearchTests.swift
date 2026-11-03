import XCTest
@testable import LacEditor

final class VaultSearchSupportTests: XCTestCase {
    // MARK: Разбор ответа

    func testParserReadsPathTitleSnippetAndIgnoresExtraFields() throws {
        let json = """
        {"query":"npd","source":"qmd","total":2,"limited":false,"results":[
          {"path":"projects/npd/status.md","directory":"projects/npd","name":"status.md","title":"Статус","snippet":"Текущий статус"},
          {"path":"daily/2026-11-03.md","directory":"daily","name":"2026-11-03.md","title":null}]}
        """
        let hits = try VaultAPIParser.search(Data(json.utf8))
        XCTAssertEqual(hits.map(\.path), ["projects/npd/status.md", "daily/2026-11-03.md"])
        XCTAssertEqual(hits[0].title, "Статус")
        XCTAssertEqual(hits[0].snippet, "Текущий статус")
        XCTAssertNil(hits[1].title)
        XCTAssertNil(hits[1].snippet)
    }

    func testResultsDropUnsafeHiddenAndDuplicatePaths() {
        let hits = [
            VaultSearchHit(path: "../x.md", title: nil, snippet: nil, score: nil),
            VaultSearchHit(path: "/abs.md", title: nil, snippet: nil, score: nil),
            VaultSearchHit(path: "a/.hidden/x.md", title: nil, snippet: nil, score: nil),
            VaultSearchHit(path: "secret/x.md", title: nil, snippet: nil, score: nil),
            VaultSearchHit(path: "projects/npd/status.md", title: "  ", snippet: "  отрывок  ", score: nil),
            VaultSearchHit(path: "projects/npd/status.md", title: "Повтор", snippet: nil, score: nil),
            VaultSearchHit(path: "root.md", title: "Корень", snippet: "", score: nil),
        ]
        let results = VaultSearchSupport.results(from: hits, hidden: ["secret"])
        XCTAssertEqual(results.map(\.path), ["projects/npd/status.md", "root.md"])
        XCTAssertEqual(results[0].title, "status")
        XCTAssertEqual(results[0].snippet, "отрывок")
        XCTAssertEqual(results[0].displayTrail, "projects › npd › status")
        XCTAssertEqual(results[1].displayTrail, "root")
        XCTAssertEqual(results[1].folderTrail, "")
        XCTAssertNil(results[1].snippet)
        XCTAssertEqual(results[1].title, "Корень")
    }

    func testPhaseForErrors() {
        XCTAssertEqual(VaultSearchSupport.phase(for: VaultClientError.searchUnavailable), .unavailable)
        XCTAssertEqual(VaultSearchSupport.phase(for: VaultClientError.offline), .offline)
        XCTAssertEqual(VaultSearchSupport.phase(for: VaultClientError.timeout), .offline)
        XCTAssertEqual(VaultSearchSupport.phase(for: VaultClientError.unauthorized), .failed(VaultClientError.unauthorized.userMessage))
        XCTAssertEqual(VaultSearchSupport.phase(for: VaultClientError.server(status: 500, message: nil)),
                       .failed(VaultClientError.server(status: 500, message: nil).userMessage))
        XCTAssertNil(VaultSearchSupport.phase(for: CancellationError()))
    }

    func testNormalizedQuery() {
        XCTAssertEqual(VaultSearchSupport.normalizedQuery("  проект \t НПД\n\u{0007}план  "), "проект НПД план")
        XCTAssertEqual(VaultSearchSupport.normalizedQuery(" \n\t "), "")
        let long = String(repeating: "ab ", count: 200)
        let normalized = VaultSearchSupport.normalizedQuery(long)
        XCTAssertLessThanOrEqual(normalized.unicodeScalars.count, 200)
        XCTAssertFalse(normalized.hasSuffix(" "))
        XCTAssertEqual(VaultSearchSupport.normalizedQuery(String(repeating: "я", count: 300)).count, 200)
    }

    func testHighlightRangesAreCaseAndDiacriticInsensitive() {
        let text = "Ёж и ёлка, Café"
        XCTAssertEqual(VaultSearchSupport.highlightRanges(in: text, query: "ёж ЁЛК"), [NSRange(location: 0, length: 2), NSRange(location: 5, length: 3)])
        XCTAssertEqual(VaultSearchSupport.highlightRanges(in: text, query: "cafe"), [NSRange(location: 11, length: 4)])
        XCTAssertEqual(VaultSearchSupport.highlightRanges(in: text, query: ""), [])
        XCTAssertEqual(VaultSearchSupport.highlightRanges(in: "aaa", query: "aa a"), [NSRange(location: 0, length: 3)])
    }

    func testRankNamesOrderAndLimit() throws {
        let paths = ["projects/npd/status-old.md", "projects/status.md", "notes/s-t-a-t-u-s.md", "x/status.md", "other/readme.md"]
        let ranked = try VaultSearchSupport.rankNames(query: "status", paths: paths)
        // точное имя (по порядку каталога), затем подстрока пути, затем подпоследовательность
        XCTAssertEqual(ranked.results.map(\.path), ["projects/status.md", "x/status.md", "projects/npd/status-old.md", "notes/s-t-a-t-u-s.md"])
        XCTAssertEqual(ranked.total, 4)
        let limited = try VaultSearchSupport.rankNames(query: "status", paths: paths, limit: 2)
        XCTAssertEqual(limited.results.count, 2)
        XCTAssertEqual(limited.total, 4)
    }

    func testRankNamesCancellation() {
        XCTAssertThrowsError(try VaultSearchSupport.rankNames(query: "a", paths: ["a.md"], isCancelled: { true }))
    }
}

final class VaultSnippetLocatorTests: XCTestCase {
    private func locate(_ snippet: String, in text: String, query: String = "") -> VaultSnippetMatch? {
        VaultSnippetLocator.locate(snippet: snippet, in: text, query: query)
    }

    private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    func testEllipsisAtEitherEndIsRemoved() throws {
        let text = "Начало. Текущий статус проекта в работе. Конец."
        for snippet in ["…Текущий статус проекта…", "Текущий статус проекта…", "…Текущий статус проекта", "...Текущий статус проекта..."] {
            let match = try XCTUnwrap(locate(snippet, in: text), snippet)
            XCTAssertEqual(substring(text, match.found), "Текущий статус проекта", snippet)
        }
    }

    func testWhitespaceDifferencesAreTolerated() throws {
        let text = "Заголовок\r\n\r\nТекущий\tстатус \u{00A0}  проекта\nв работе"
        let match = try XCTUnwrap(locate("Текущий статус проекта в работе", in: text))
        XCTAssertEqual(substring(text, match.found), "Текущий\tстатус \u{00A0}  проекта\nв работе")
    }

    func testUTF16RangesForEmojiAndChinese() throws {
        let text = "😀😀 пролог 好的 笔记 📝 текст после 🎉 конец"
        let match = try XCTUnwrap(locate("笔记 📝 текст после", in: text, query: "текст"))
        XCTAssertEqual(substring(text, match.found), "笔记 📝 текст после")
        XCTAssertEqual(substring(text, match.selection), "текст")
    }

    func testNoMatchAndShortSnippet() {
        XCTAssertNil(locate("совсем другой отрывок", in: "в тексте такого нет"))
        XCTAssertNil(locate("abc", in: "abc abc"))
        XCTAssertNil(locate("…ab…", in: "ab ab ab"))
        XCTAssertNil(locate("", in: "text"))
    }

    func testFirstOccurrenceWins() throws {
        let text = "один и тот же фрагмент. ещё раз один и тот же фрагмент."
        let match = try XCTUnwrap(locate("один и тот же фрагмент", in: text))
        XCTAssertEqual(match.found.location, 0)
    }

    func testChangedNoteFallsBackToHeadOrTail() throws {
        let common = "это общая часть заметки которая осталась прежней после правки автора вчера"
        let headText = common + " и совсем другой хвост. Конец."
        let matchHead = try XCTUnwrap(locate(common + " хвост который изменился иначе на сервере сегодня", in: headText))
        XCTAssertEqual(matchHead.found.location, 0)
        XCTAssertTrue(substring(headText, matchHead.found).hasPrefix("это общая часть"))
        let tailText = "Вступление. Другое начало здесь. " + common + " Конец."
        let matchTail = try XCTUnwrap(locate("Начало совсем иное в индексе " + common, in: tailText))
        XCTAssertTrue(substring(tailText, matchTail.found).hasSuffix("правки автора вчера"))
    }

    func testTooShortPartIsNotUsed() {
        // голова короче 12 символов не используется: «Короткая» + длинный несовпадающий хвост
        let snippet = "Короткая " + String(repeating: "и", count: 80)
        XCTAssertNil(locate(snippet, in: "Короткая мысль и всё"))
    }

    func testDiffMarkerLinesAreIgnored() throws {
        let text = "до. Нужный отрывок текста. после."
        let match = try XCTUnwrap(locate("@@ -1,2 @@\nНужный отрывок текста", in: text))
        XCTAssertEqual(substring(text, match.found), "Нужный отрывок текста")
    }

    func testCaseAndDiacriticAndUnicodeForms() throws {
        let text = "Рядом живёт Ёж и его друг"
        XCTAssertEqual(substring(text, try XCTUnwrap(locate("живёт ёж и его", in: text)).found), "живёт Ёж и его")
        let decomposed = "Le cafe\u{0301} est ouvert ici"
        XCTAssertNotNil(locate("le café est ouvert", in: decomposed))
    }

    func testSelectionIsQueryWordOrFirstLine() throws {
        let text = "Первая строка заметки\nвторая строка с нужным словом"
        let withWord = try XCTUnwrap(locate("Первая строка заметки вторая строка с нужным словом", in: text, query: "нужным"))
        XCTAssertEqual(substring(text, withWord.selection), "нужным")
        let noWord = try XCTUnwrap(locate("Первая строка заметки вторая строка с нужным словом", in: text, query: "ничего"))
        XCTAssertEqual(substring(text, noWord.selection), "Первая строка заметки")
        let long = String(repeating: "слово ", count: 40)
        let longMatch = try XCTUnwrap(locate(long.trimmingCharacters(in: .whitespaces), in: long, query: "нет"))
        XCTAssertLessThanOrEqual(longMatch.selection.length, 120)
    }

    func testHugeTextUsesPlainSearchWithoutCrash() throws {
        let filler = String(repeating: "x", count: VaultSnippetLocator.maxNormalizedLength + 1)
        let text = filler + " найденный отрывок в конце"
        let match = try XCTUnwrap(locate("найденный отрывок в конце", in: text))
        XCTAssertEqual(match.found.location, (filler as NSString).length + 1)
        XCTAssertNil(locate("отрывок   с   пробелами", in: text))
    }
}

@MainActor
final class VaultSearchControllerTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var searches: [String] = []
        var online = true
        var announcements: [String] = []
        var opened: [(String, Bool, String)] = []
        var paths = ["projects/status.md", "daily/2026-11-03.md", "projects/npd/status-old.md"]
        var complete = true
    }

    private func hit(_ path: String) -> VaultSearchHit { VaultSearchHit(path: path, title: nil, snippet: "отрывок", score: nil) }

    private func make(_ box: Box, delay: UInt64 = 20_000_000,
                      search: ((String) async throws -> [VaultSearchHit])? = nil) -> VaultSearchController {
        VaultSearchController(
            search: { query in
                box.searches.append(query)
                if let search { return try await search(query) }
                return [VaultSearchHit(path: "a/\(query).md", title: nil, snippet: "отрывок", score: nil)]
            },
            namePaths: { box.paths },
            isNameListComplete: { box.complete },
            isOnline: { box.online },
            sleep: { _ in try await Task.sleep(nanoseconds: delay) },
            open: { box.opened.append(($0.path, $1, $2)) },
            announce: { box.announcements.append($0) })
    }

    private func settle(_ controller: VaultSearchController) async {
        while let task = controller.currentTask {
            await task.value
            if controller.currentTask == task { break }
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    func testCancellationInsideSearchReturnsToIdle() async {
        let box = Box()
        let controller = make(box, search: { _ in throw CancellationError() })
        controller.query = "статус"
        controller.submit()
        await settle(controller)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testNamesModeLeavesWaitingPhaseAfterRanking() async {
        let box = Box()
        let controller = make(box)
        controller.mode = .names
        controller.query = "status"
        XCTAssertEqual(controller.phase, .waiting)
        await settle(controller)
        XCTAssertEqual(controller.phase, .results)
    }

    func testRapidTypingSendsOneRequest() async {
        let box = Box()
        let controller = make(box)
        controller.query = "п"
        controller.query = "пр"
        controller.query = "про"
        XCTAssertEqual(controller.phase, .waiting)
        await settle(controller)
        XCTAssertEqual(box.searches, ["про"])
        XCTAssertEqual(controller.phase, .results)
        XCTAssertEqual(controller.results.map(\.path), ["a/про.md"])
        XCTAssertEqual(box.announcements.count, 1)
    }

    func testSubmitStartsWithoutWaitingAndSecondSubmitOpensFirst() async {
        let box = Box()
        let controller = make(box, delay: 5_000_000_000)
        controller.query = "статус"
        controller.submit()
        await settle(controller)
        XCTAssertEqual(box.searches, ["статус"])
        controller.submit()
        XCTAssertEqual(box.opened.map(\.0), ["a/статус.md"])
        XCTAssertEqual(box.opened.first?.2, "статус")
    }

    func testStaleAnswerIsDiscarded() async {
        let box = Box()
        let controller = make(box, search: { query in
            if query == "a" { try? await Task.sleep(nanoseconds: 200_000_000) }
            return [VaultSearchHit(path: "r/\(query).md", title: nil, snippet: nil, score: nil)]
        })
        controller.query = "a"
        controller.submit()
        try? await Task.sleep(nanoseconds: 30_000_000)
        controller.query = "b"
        controller.submit()
        await settle(controller)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.results.map(\.path), ["r/b.md"])
        XCTAssertEqual(controller.phase, .results)
    }

    func testStaleErrorDoesNotChangePhase() async {
        let box = Box()
        let controller = make(box, search: { query in
            if query == "a" { try? await Task.sleep(nanoseconds: 150_000_000); throw VaultClientError.searchUnavailable }
            return [VaultSearchHit(path: "r/\(query).md", title: nil, snippet: nil, score: nil)]
        })
        controller.query = "a"
        controller.submit()
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.query = "b"
        controller.submit()
        await settle(controller)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(controller.phase, .results)
    }

    func testClearModeChangeAndCancelDropLateAnswers() async {
        let box = Box()
        let controller = make(box, search: { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return [VaultSearchHit(path: "late.md", title: nil, snippet: nil, score: nil)]
        })
        controller.query = "x"
        controller.submit()
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.clear()
        XCTAssertEqual(controller.phase, .idle)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(controller.results, [])

        controller.query = "x"
        controller.submit()
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.cancel()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(controller.results, [])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.query, "")

        controller.query = "x"
        controller.submit()
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.mode = .names
        await settle(controller)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(controller.results.contains { $0.path == "late.md" })
    }

    func testOfflineSkipsNetworkAndRetriesOnceWhenOnline() async {
        let box = Box()
        box.online = false
        let controller = make(box)
        controller.query = "q"
        await settle(controller)
        XCTAssertEqual(controller.phase, .offline)
        XCTAssertEqual(box.searches, [])
        box.online = true
        controller.connectivityChanged(isOnline: true)
        await settle(controller)
        XCTAssertEqual(box.searches, ["q"])
        XCTAssertEqual(controller.phase, .results)
        controller.connectivityChanged(isOnline: true)
        await settle(controller)
        XCTAssertEqual(box.searches, ["q"])
    }

    func testUnavailableHasNoAutoRetryButRetryWorks() async {
        let box = Box()
        var failing = true
        let controller = make(box, search: { query in
            if failing { throw VaultClientError.searchUnavailable }
            return [VaultSearchHit(path: "ok/\(query).md", title: nil, snippet: nil, score: nil)]
        })
        controller.query = "q"
        await settle(controller)
        XCTAssertEqual(controller.phase, .unavailable)
        controller.connectivityChanged(isOnline: true)
        await settle(controller)
        XCTAssertEqual(box.searches.count, 1)
        failing = false
        controller.retry()
        await settle(controller)
        XCTAssertEqual(controller.phase, .results)
        XCTAssertEqual(box.searches.count, 2)
    }

    func testNamesModeWorksOfflineAndFollowsRanking() async {
        let box = Box()
        box.online = false
        box.complete = false
        let controller = make(box)
        controller.mode = .names
        controller.query = "status"
        await settle(controller)
        XCTAssertEqual(controller.results.map(\.path), ["projects/status.md", "projects/npd/status-old.md"])
        XCTAssertEqual(controller.phase, .results)
        XCTAssertTrue(controller.namesListIsPartial)
        XCTAssertEqual(box.searches, [])
        box.complete = true
        controller.refreshNames()
        await settle(controller)
        XCTAssertFalse(controller.namesListIsPartial)
    }

    func testEmptyQueryAndSelect() async {
        let box = Box()
        let controller = make(box)
        controller.query = "   "
        controller.submit()
        await settle(controller)
        XCTAssertEqual(box.searches, [])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isActive)
        controller.query = "x"
        await settle(controller)
        controller.select(controller.results[0], newTab: true)
        XCTAssertEqual(box.opened.map(\.0), ["a/x.md"])
        XCTAssertEqual(box.opened.first?.1, true)
    }

    func testTwentyHitsMeanLimited() async {
        let box = Box()
        let controller = make(box, search: { _ in (0..<20).map { VaultSearchHit(path: "n/\($0).md", title: nil, snippet: nil, score: nil) } })
        controller.query = "q"
        await settle(controller)
        XCTAssertTrue(controller.isLimited)
        XCTAssertEqual(controller.results.count, 20)
        let few = make(Box(), search: { _ in (0..<19).map { VaultSearchHit(path: "n/\($0).md", title: nil, snippet: nil, score: nil) } })
        few.query = "q"
        await settle(few)
        XCTAssertFalse(few.isLimited)
    }
}

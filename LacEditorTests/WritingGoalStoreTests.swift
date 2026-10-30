import Combine
import XCTest
@testable import LacEditor

@MainActor
final class WritingGoalStoreTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "LacEditorTests.WritingGoal.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testFirstObservationSetsBaseline() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        let id = UUID()
        store.record(words: 500, documentID: id)
        XCTAssertEqual(store.progress(), 0)
        store.record(words: 530, documentID: id)
        XCTAssertEqual(store.progress(), 30)
    }

    func testProgressSumsPositiveDeltasOnly() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        let first = UUID(), second = UUID()
        store.record(words: 100, documentID: first)
        store.record(words: 100, documentID: second)
        store.record(words: 140, documentID: first)
        store.record(words: 75, documentID: second)
        XCTAssertEqual(store.progress(), 40)
    }

    func testDecreaseBelowBaseRecoversWithinSameDocument() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        let id = UUID()
        store.record(words: 100, documentID: id)
        store.record(words: 70, documentID: id)
        XCTAssertEqual(store.progress(), 0)
        store.record(words: 120, documentID: id)
        XCTAssertEqual(store.progress(), 20)
    }

    func testClosedDocumentContributionStays() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let now = { self.date(30, 12, 0, 0) }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: now)
        let id = UUID()
        store.record(words: 10, documentID: id)
        store.record(words: 25, documentID: id)
        XCTAssertEqual(store.progress(), 15)
        let restarted = WritingGoalStore(defaults: defaults, calendar: calendar, now: now)
        XCTAssertEqual(restarted.progress(), 15)
    }

    func testDayChangeResetsAndRebases() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var current = date(30, 23, 59, 59)
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { current })
        let id = UUID()
        store.record(words: 10, documentID: id)
        store.record(words: 50, documentID: id)
        XCTAssertEqual(store.progress(), 40)
        current = date(31, 0, 0, 1)
        XCTAssertEqual(store.progress(), 0)
        store.record(words: 50, documentID: id)
        XCTAssertEqual(store.progress(), 0)
        store.record(words: 60, documentID: id)
        XCTAssertEqual(store.progress(), 10)
    }

    func testDayChangeKeepsWordsTypedBeforeFirstStatistics() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var current = date(30, 23, 59, 59)
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { current })
        let open = UUID(), closed = UUID()
        store.record(words: 100, documentID: open)
        store.record(words: 7, documentID: closed)
        store.markClosed(documentID: closed)
        current = date(31, 0, 0, 1)
        let reopened = WritingGoalStore(defaults: defaults, calendar: calendar, now: { current })
        reopened.record(words: 130, documentID: open)
        XCTAssertEqual(reopened.progress(), 30)
        reopened.record(words: 9, documentID: closed)
        reopened.record(words: 19, documentID: closed)
        XCTAssertEqual(reopened.progress(), 40)
    }

    func testRebaseKeepsProgressWhenCountingChanges() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        let id = UUID()
        store.record(words: 100, documentID: id)
        store.record(words: 120, documentID: id)
        store.rebase(words: 3000, documentID: id)
        XCTAssertEqual(store.progress(), 20)
        store.record(words: 3005, documentID: id)
        XCTAssertEqual(store.progress(), 25)
    }

    func testProgressReadDoesNotMutate() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var current = date(30, 12, 0, 0)
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { current })
        store.record(words: 5, documentID: UUID())
        let storedEntries = defaults.data(forKey: "writingGoalEntries")
        let storedDay = defaults.string(forKey: "writingGoalDay")
        let revision = store.revision
        current = date(31, 12, 0, 0)
        _ = store.progress()
        XCTAssertEqual(defaults.data(forKey: "writingGoalEntries"), storedEntries)
        XCTAssertEqual(defaults.string(forKey: "writingGoalDay"), storedDay)
        XCTAssertEqual(store.revision, revision)
    }

    func testNegativeWordsIgnored() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        XCTAssertFalse(store.record(words: -1, documentID: UUID()))
        XCTAssertEqual(store.revision, 0)
        XCTAssertNil(defaults.data(forKey: "writingGoalEntries"))
    }

    func testCorruptedStoredDataStartsEmpty() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("2026-10-30", forKey: "writingGoalDay")
        defaults.set(Data([0xFF, 0x00, 0x12]), forKey: "writingGoalEntries")
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        XCTAssertEqual(store.progress(), 0)
        let id = UUID()
        store.record(words: 3, documentID: id)
        store.record(words: 8, documentID: id)
        XCTAssertEqual(store.progress(), 5)
    }

    func testPersistsOnlyWhenValueChanges() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = WritingGoalStore(defaults: defaults, calendar: calendar, now: { self.date(30, 12, 0, 0) })
        let id = UUID()
        XCTAssertTrue(store.record(words: 4, documentID: id))
        let revision = store.revision
        XCTAssertFalse(store.record(words: 4, documentID: id))
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.record(words: 9, documentID: id))
        XCTAssertEqual(store.revision, revision + 1)
    }

    func testDifferentSuitesAreIsolated() throws {
        let (firstDefaults, firstCleanup) = try makeDefaults()
        let (secondDefaults, secondCleanup) = try makeDefaults()
        defer { firstCleanup(); secondCleanup() }
        let now = { self.date(30, 12, 0, 0) }
        let first = WritingGoalStore(defaults: firstDefaults, calendar: calendar, now: now)
        let second = WritingGoalStore(defaults: secondDefaults, calendar: calendar, now: now)
        let id = UUID()
        first.record(words: 1, documentID: id)
        first.record(words: 11, documentID: id)
        XCTAssertEqual(first.progress(), 10)
        XCTAssertEqual(second.progress(), 0)
    }

    func testDailyWordGoalPreference() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.dailyWordGoal, 0)
        preferences.dailyWordGoal = 1500
        XCTAssertEqual(AppPreferences(defaults: defaults).dailyWordGoal, 1500)
        preferences.dailyWordGoal = -1
        XCTAssertEqual(preferences.dailyWordGoal, 1500)
        preferences.dailyWordGoal = AppPreferences.maximumDailyWordGoal + 1
        XCTAssertEqual(preferences.dailyWordGoal, 1500)
        defaults.set(-5, forKey: "dailyWordGoal")
        XCTAssertEqual(AppPreferences(defaults: defaults).dailyWordGoal, 0)
        defaults.set(AppPreferences.maximumDailyWordGoal + 1, forKey: "dailyWordGoal")
        XCTAssertEqual(AppPreferences(defaults: defaults).dailyWordGoal, 0)
    }

    private func waitForProgress(_ store: WritingGoalStore, expected: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.progress() != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testNewEmptyDocumentCountsTyping() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "")
        let state = AppState(initialDocuments: [document], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        defer { document.cancelMetricsRefresh() }
        document.text = "one two three four five six seven"
        await waitForProgress(preferences.writingGoal, expected: 7)
        XCTAssertEqual(preferences.writingGoal.progress(), 7)
        withExtendedLifetime(state) {}
    }

    func testSelectionStatisticsDoesNotRecord() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "")
        let state = AppState(initialDocuments: [document], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        defer { document.cancelMetricsRefresh() }
        document.text = "one two three four"
        document.selectionRange = NSRange(location: 0, length: 3)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(preferences.writingGoal.progress(), 0)
        document.selectionRange = NSRange(location: 0, length: 0)
        await waitForProgress(preferences.writingGoal, expected: 4)
        XCTAssertEqual(preferences.writingGoal.progress(), 4)
        withExtendedLifetime(state) {}
    }

    func testLargeProfileDoesNotRecord() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "", performanceProfile: .large)
        document.featureOverrides.wordCount = true
        let state = AppState(initialDocuments: [document], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        defer { document.cancelMetricsRefresh() }
        document.text = "one two three four"
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(preferences.writingGoal.progress(), 0)
        withExtendedLifetime(state) {}
    }

    func testSharedStoreAcrossStates() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let preferences = AppPreferences(defaults: defaults)
        let first = EditorDocument(text: ""), second = EditorDocument(text: "")
        let firstState = AppState(initialDocuments: [first], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let secondState = AppState(initialDocuments: [second], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        defer { first.cancelMetricsRefresh(); second.cancelMetricsRefresh() }
        first.text = "a b c"
        second.text = "d e"
        await waitForProgress(preferences.writingGoal, expected: 5)
        XCTAssertEqual(preferences.writingGoal.progress(), 5)
        withExtendedLifetime((firstState, secondState)) {}
    }
}

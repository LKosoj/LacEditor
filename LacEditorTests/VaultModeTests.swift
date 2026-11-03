import XCTest
@testable import LacEditor

final class VaultModeTests: XCTestCase {
    private let vaultID = "6E1F5B7C-2A4D-4E8B-9C3D-0F1A2B3C4D5E"

    // MARK: Привязка вкладки

    func testBindingRoundTrips() throws {
        let binding = VaultNoteBinding(vaultID: vaultID, path: "projects/status.md")
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(VaultNoteBinding.self, from: data)
        XCTAssertEqual(decoded, binding)
        XCTAssertTrue(decoded.isValid)
    }

    func testBindingToleratesBrokenFields() throws {
        let decoded = try JSONDecoder().decode(VaultNoteBinding.self, from: Data(#"{"vaultID": 5}"#.utf8))
        XCTAssertFalse(decoded.isValid)
        let empty = try JSONDecoder().decode(VaultNoteBinding.self, from: Data("[]".utf8))
        XCTAssertFalse(empty.isValid)
    }

    func testBindingRejectsUnsafePath() {
        XCTAssertFalse(VaultNoteBinding(vaultID: vaultID, path: "../secret.md").isValid)
        XCTAssertFalse(VaultNoteBinding(vaultID: "не-идентификатор", path: "a.md").isValid)
    }

    // MARK: Состояние связи

    func testStatusPriority() {
        XCTAssertEqual(VaultStatus.resolve(isConnecting: true, isOnline: true, unsentCount: 0, conflictCount: 0), .connecting)
        XCTAssertEqual(VaultStatus.resolve(isConnecting: false, isOnline: false, unsentCount: 2, conflictCount: 0), .offline)
        XCTAssertEqual(VaultStatus.resolve(isConnecting: false, isOnline: true, unsentCount: 2, conflictCount: 0), .attention(2))
        XCTAssertEqual(VaultStatus.resolve(isConnecting: false, isOnline: false, unsentCount: 2, conflictCount: 1), .attention(1))
        XCTAssertEqual(VaultStatus.resolve(isConnecting: false, isOnline: true, unsentCount: 0, conflictCount: 0), .online)
    }

    func testStatusSymbolsDiffer() {
        let names = [VaultStatus.online, .offline, .attention(1)].map(\.symbolName)
        XCTAssertEqual(Set(names).count, 3)
    }

    func testOpeningStateBecomesSlowOnlyFromLoading() {
        XCTAssertEqual(VaultOpeningState.loading.afterDelay(), .slow)
        XCTAssertEqual(VaultOpeningState.slow.afterDelay(), .slow)
        XCTAssertEqual(VaultOpeningState.waitingForConnection.afterDelay(), .waitingForConnection)
        XCTAssertEqual(VaultOpeningState.slowDelay, 3)
    }

    // MARK: Заметка дня

    func testDailyNotePaths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        XCTAssertEqual(VaultDailyNote.path(for: date, calendar: calendar), "daily/2026-11-03.md")
        XCTAssertEqual(VaultDailyNote.yesterday(of: date, calendar: calendar), "daily/2026-11-02.md")
        let newYear = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        XCTAssertEqual(VaultDailyNote.yesterday(of: newYear, calendar: calendar), "daily/2025-12-31.md")
    }

    func testDailyNoteDateFromPath() {
        XCTAssertEqual(VaultDailyNote.date(fromPath: "daily/2026-11-03.md"), "2026-11-03")
        XCTAssertNil(VaultDailyNote.date(fromPath: "daily/notes.md"))
        XCTAssertNil(VaultDailyNote.date(fromPath: "projects/2026-11-03.md"))
        XCTAssertNil(VaultDailyNote.date(fromPath: "daily/2026-11-03.txt"))
        XCTAssertNil(VaultDailyNote.date(fromPath: "daily/2026-1-03.md"))
    }

    // MARK: Список и заголовок

    func testPinToggleKeepsOrder() {
        var pinned = VaultPresentation.togglingPin("a.md", in: [])
        pinned = VaultPresentation.togglingPin("b.md", in: pinned)
        XCTAssertEqual(pinned, ["a.md", "b.md"])
        XCTAssertEqual(VaultPresentation.togglingPin("a.md", in: pinned), ["b.md"])
    }

    func testVisiblePinnedHidesHiddenRootsAndBadPaths() {
        let pinned = ["secret/a.md", "projects/b.md", "../x.md"]
        XCTAssertEqual(VaultPresentation.visiblePinned(pinned, hidden: ["secret"]), ["projects/b.md"])
    }

    func testDisplayNameAndTitlePrefix() {
        XCTAssertEqual(VaultPresentation.displayName(ofPath: "projects/status.md"), "status")
        XCTAssertEqual(VaultPresentation.displayName(ofPath: "readme"), "readme")
        XCTAssertEqual(VaultPresentation.titlePrefix(connectionName: "Работа", path: "projects/sub/status.md"), "Работа › projects › sub")
        XCTAssertEqual(VaultPresentation.titlePrefix(connectionName: "Работа", path: "status.md"), "Работа")
        XCTAssertEqual(VaultPresentation.titlePrefix(connectionName: "Работа", path: nil), "Работа")
    }

    func testEmptyCatalogBecauseOffline() {
        XCTAssertTrue(VaultPresentation.isCatalogEmptyBecauseOffline(rootsCount: 0, isOnline: false, isConnecting: false))
        XCTAssertFalse(VaultPresentation.isCatalogEmptyBecauseOffline(rootsCount: 0, isOnline: true, isConnecting: false))
        XCTAssertFalse(VaultPresentation.isCatalogEmptyBecauseOffline(rootsCount: 3, isOnline: false, isConnecting: false))
        XCTAssertFalse(VaultPresentation.isCatalogEmptyBecauseOffline(rootsCount: 0, isOnline: false, isConnecting: true))
    }

    // MARK: Серверное обновление текста

    private func apply(_ old: String, _ new: String) -> String? {
        guard let change = VaultTextDiff.enclosingChange(from: old, to: new) else { return nil }
        return (old as NSString).replacingCharacters(in: change.range, with: change.replacement)
    }

    func testDiffEqualTextsGiveNothing() {
        XCTAssertNil(VaultTextDiff.enclosingChange(from: "абв", to: "абв"))
    }

    func testDiffReplacesOnlyChangedMiddle() throws {
        let change = try XCTUnwrap(VaultTextDiff.enclosingChange(from: "строка 1\nстрока 2\nстрока 3", to: "строка 1\nновая\nстрока 3"))
        XCTAssertEqual(change.replacement, "новая")
        XCTAssertEqual(change.range, NSRange(location: 9, length: 8))
    }

    func testDiffAppendInsertsAtEnd() throws {
        let change = try XCTUnwrap(VaultTextDiff.enclosingChange(from: "a\n", to: "a\n- 14:05 запись\n"))
        XCTAssertEqual(change.range.length, 0)
        XCTAssertEqual(change.range.location, 2)
        XCTAssertEqual(change.replacement, "- 14:05 запись\n")
    }

    func testDiffRoundTripsVariousEdits() {
        let cases = [("", "новый"), ("старый", ""), ("aaa", "aaaa"), ("aaaa", "aaa"), ("abcabc", "abcXabc"), ("😀 текст", "😁 текст"),
                     ("a😀b", "a😁b"), ("x", "y")]
        for (old, new) in cases { XCTAssertEqual(apply(old, new), new, "\(old) -> \(new)") }
    }

    func testDiffDoesNotSplitSurrogatePair() throws {
        let change = try XCTUnwrap(VaultTextDiff.enclosingChange(from: "😀", to: "😁"))
        XCTAssertEqual(change.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(change.replacement, "😁")
    }
}

import XCTest
@testable import LacEditor

final class NavigationHistoryTests: XCTestCase {
    private let document = UUID()

    private func place(_ line: Int, _ column: Int = 1, in id: UUID? = nil) -> NavigationLocation {
        NavigationLocation(documentID: id ?? document, line: line, column: column)
    }

    func testRecordClearsForward() {
        var history = NavigationHistory()
        history.record(place(1))
        _ = history.goBack(from: place(5), isValid: { _ in true })
        XCTAssertTrue(history.canGoForward)
        history.record(place(7))
        XCTAssertFalse(history.canGoForward)
    }

    func testAdjacentDuplicateIsNotRecorded() {
        var history = NavigationHistory()
        history.record(place(1))
        history.record(place(1))
        XCTAssertEqual(history.back.count, 1)
        history.record(place(2))
        history.record(place(1))
        XCTAssertEqual(history.back.count, 3)
    }

    func testLimitKeepsNewestFifty() {
        var history = NavigationHistory()
        for line in 1...60 { history.record(place(line)) }
        XCTAssertEqual(history.back.count, 50)
        XCTAssertEqual(history.back.first, place(11))
        XCTAssertEqual(history.goBack(from: place(100), isValid: { _ in true }), place(60))
    }

    func testBackThenForwardRestoresCurrent() {
        var history = NavigationHistory()
        history.record(place(1))
        XCTAssertEqual(history.goBack(from: place(9), isValid: { _ in true }), place(1))
        XCTAssertEqual(history.goForward(from: place(1), isValid: { _ in true }), place(9))
        XCTAssertEqual(history.back, [place(1)])
    }

    func testBackSkipsInvalidAndDiscardsThem() {
        let closed = UUID()
        var history = NavigationHistory()
        history.record(place(1))
        history.record(place(2, in: closed))
        let target = history.goBack(from: place(9), isValid: { $0.documentID != closed })
        XCTAssertEqual(target, place(1))
        XCTAssertFalse(history.back.contains(place(2, in: closed)))
        XCTAssertNil(history.goBack(from: place(1), isValid: { _ in true }))
    }

    func testBackSkipsEntryEqualToCurrent() {
        var history = NavigationHistory()
        history.record(place(1))
        history.record(place(4))
        XCTAssertEqual(history.goBack(from: place(4), isValid: { _ in true }), place(1))
    }

    func testBackWithoutValidEntryKeepsForward() {
        var history = NavigationHistory()
        history.record(place(1))
        _ = history.goBack(from: place(5), isValid: { _ in true })
        history.record(place(2))
        history.record(place(3))
        _ = history.goBack(from: place(8), isValid: { _ in true })
        let forwardBefore = history.forward
        XCTAssertNil(history.goBack(from: place(3), isValid: { _ in false }))
        XCTAssertEqual(history.forward, forwardBefore)
        XCTAssertTrue(history.back.isEmpty)
    }

    func testForwardSkipsInvalid() {
        let closed = UUID()
        var history = NavigationHistory()
        history.record(place(1))
        history.record(place(2))
        _ = history.goBack(from: place(5, in: closed), isValid: { _ in true })
        _ = history.goBack(from: place(2), isValid: { _ in true })
        XCTAssertEqual(history.forward.count, 2)
        XCTAssertEqual(history.goForward(from: place(1), isValid: { $0.documentID != closed }), place(2))
        XCTAssertNil(history.goForward(from: place(2), isValid: { $0.documentID != closed }))
    }

    func testLocationRoundTripWithEmojiAndChinese() {
        let text = "😀中文\nabc"
        let offset = (text as NSString).range(of: "b").location
        let value = NavigationLocation.make(documentID: document, text: text, location: offset)
        XCTAssertEqual(value.line, 2)
        XCTAssertEqual(value.column, 2)
        XCTAssertEqual(value.location(in: text), offset)
        let inFirst = NavigationLocation.make(documentID: document, text: text, location: (text as NSString).range(of: "文").location)
        XCTAssertEqual(inFirst.line, 1)
        XCTAssertEqual(inFirst.column, 3)
        XCTAssertEqual(inFirst.location(in: text), (text as NSString).range(of: "文").location)
    }

    func testLocationClampsToShortDocument() {
        let text = "ab\ncd"
        XCTAssertEqual(place(10, 10).location(in: text), (text as NSString).length)
        XCTAssertEqual(place(1, 99).location(in: text), 2)
    }

    func testLocationInEmptyDocument() {
        XCTAssertEqual(place(1).location(in: ""), 0)
        XCTAssertEqual(place(5, 5).location(in: ""), 0)
        XCTAssertEqual(NavigationLocation.make(documentID: document, text: "", location: 3), place(1))
    }

    func testLocationWithCRLF() {
        let text = "a\r\nb"
        let offset = (text as NSString).range(of: "b").location
        let value = NavigationLocation.make(documentID: document, text: text, location: offset)
        XCTAssertEqual(value.line, 2)
        XCTAssertEqual(value.location(in: text), offset)
        XCTAssertEqual(place(1, 99).location(in: text), 1)
    }

    func testLocationAfterTextShrinks() {
        let text = "a\nb\ncd"
        let value = place(10, 1)
        XCTAssertEqual(value.location(in: text), (text as NSString).range(of: "cd").location)
    }
}

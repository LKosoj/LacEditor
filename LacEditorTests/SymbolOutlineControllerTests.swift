import Combine
import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class SymbolOutlineControllerTests: XCTestCase {
    private func wait(_ controller: SymbolOutlineController, for state: SymbolOutlineController.State,
                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<250 {
            if controller.state == state { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("состояние \(controller.state), ожидалось \(state)", file: file, line: line)
    }

    func testInactiveWhenSectionCollapsedOrLanguageUnsupported() {
        let controller = SymbolOutlineController(pause: 0.05)
        let script = EditorDocument(text: "function a(){}", language: .javascript)
        controller.update(document: script, isActive: false)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertTrue(controller.symbols.isEmpty)
        controller.update(document: EditorDocument(text: "text", language: .plainText), isActive: true)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertTrue(controller.symbols.isEmpty)
    }

    func testTooLargeTextShowsTooLargeAndDoesNotParse() {
        let controller = SymbolOutlineController(maximumUTF8Bytes: 10, pause: 0.05)
        let document = EditorDocument(text: "{\"alpha\": 1, \"beta\": 2}", language: .json)
        controller.update(document: document, isActive: true)
        XCTAssertEqual(controller.state, .tooLarge)
        XCTAssertTrue(controller.symbols.isEmpty)
        XCTAssertFalse(controller.isCurrent(for: document))
    }

    func testCloseClearsStateAndCancels() async {
        let controller = SymbolOutlineController(pause: 0.05)
        let document = EditorDocument(text: "{\"a\": 1}", language: .json)
        controller.update(document: document, isActive: true)
        await wait(controller, for: .loaded)
        controller.close()
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertTrue(controller.symbols.isEmpty)
    }

    func testLoadsSymbolsAfterUpdate() async {
        let controller = SymbolOutlineController(pause: 0.05)
        let document = EditorDocument(text: "{\"a\": {\"b\": 1}}", language: .json)
        controller.update(document: document, isActive: true)
        await wait(controller, for: .loaded)
        XCTAssertEqual(controller.symbols.map(\.name), ["a", "b"])
        XCTAssertTrue(controller.isCurrent(for: document))
    }

    func testEditMakesStateUpdatingAndRebuildsAfterPause() async {
        let controller = SymbolOutlineController(pause: 0.05)
        let document = EditorDocument(text: "{\"a\": 1}", language: .json)
        controller.update(document: document, isActive: true)
        await wait(controller, for: .loaded)
        document.text = "{\"a\": 1, \"z\": 2}"
        XCTAssertEqual(controller.state, .updating)
        XCTAssertFalse(controller.isCurrent(for: document))
        await wait(controller, for: .loaded)
        XCTAssertEqual(controller.symbols.map(\.name), ["a", "z"])
        XCTAssertTrue(controller.isCurrent(for: document))
    }

    func testNewerRunCancelsOlderRun() async {
        let controller = SymbolOutlineController(pause: 0.05)
        let document = EditorDocument(text: "{\"a\": 1}", language: .json)
        controller.update(document: document, isActive: true)
        await wait(controller, for: .loaded)
        document.text = "{\"b\": 1}"
        document.text = "{\"c\": 1}"
        await wait(controller, for: .loaded)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.symbols.map(\.name), ["c"])
    }

    func testStaleResultIsDiscardedWhenTextChangesDuringParse() async {
        let controller = SymbolOutlineController(pause: 10)
        let document = EditorDocument(text: "{\"a\": 1}", language: .json)
        controller.update(document: document, isActive: true)
        document.text = "{\"b\": 1}"
        try? await Task.sleep(for: .milliseconds(300))
        // пауза длинная, повторного запуска не было: результат старой версии не применён
        XCTAssertFalse(controller.isCurrent(for: document))
        XCTAssertNotEqual(controller.symbols.map(\.name), ["a"])
    }

    func testSwitchingDocumentCancelsPreviousDocumentTask() async {
        let controller = SymbolOutlineController(pause: 0.05)
        let first = EditorDocument(text: "{\"first\": 1}", language: .json)
        let second = EditorDocument(text: "{\"second\": 1}", language: .json)
        controller.update(document: first, isActive: true)
        controller.update(document: second, isActive: true)
        await wait(controller, for: .loaded)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.symbols.map(\.name), ["second"])
        XCTAssertFalse(controller.isCurrent(for: first))
        XCTAssertTrue(controller.isCurrent(for: second))
    }

    func testTextEditsSignalDoesNotFireFromOwnSnapshot() {
        let document = EditorDocument(text: "old", language: .json)
        document.attachLiveTextProvider(id: UUID(), provider: { "new" }, acknowledgement: { _ in })
        document.noteLiveEdit(isEmpty: false)
        var count = 0
        let subscription = document.textEdits.sink { count += 1 }
        let snapshot = document.symbolOutlineSnapshot()
        XCTAssertEqual(snapshot?.text, "new")
        XCTAssertEqual(count, 0)
        document.text = "other"
        XCTAssertEqual(count, 1)
        subscription.cancel()
    }

    func testLargeProfileWithPendingEditsSkipsSnapshot() {
        let document = EditorDocument(text: "old", language: .json)
        document.attachLiveTextProvider(id: UUID(), provider: { "new" }, acknowledgement: { _ in })
        document.performanceProfile = .large
        document.noteLiveEdit(isEmpty: false)
        XCTAssertNil(document.symbolOutlineSnapshot())
    }
}

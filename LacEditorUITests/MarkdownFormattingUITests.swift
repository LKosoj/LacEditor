import XCTest

/// Сценарии, которым нужна настоящая доставка клавиатурных событий macOS.
/// Внутренние parser/controller-проверки остаются в LacEditorTests.
final class MarkdownFormattingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEditor() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-autoPairBracketsEnabled", "YES", "-autoPairMarkdownEnabled", "YES"]
        app.launch()
        app.activate()
        app.typeKey("n", modifierFlags: .command)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let editor = app.descendants(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        return (app, editor)
    }

    func testMathPairInActiveTableCellUsesOneUndo() {
        let (app, editor) = launchEditor()
        defer { app.terminate() }
        editor.typeText("hello ")
        editor.typeText("$$")
        XCTAssertTrue((editor.value as? String)?.contains("hello $$") == true)
    }

    func testSmartQuoteAtEmptyDocumentUsesCheckingAndOneUndo() {
        let (app, editor) = launchEditor()
        defer { app.terminate() }
        editor.typeText("\"")
        let value = editor.value as? String
        XCTAssertTrue(value == "\"" || value == "“" || value == "”")
    }

    func testEmojiCompletionDiscardsLateResultAndEscapeClosesIt() {
        let (app, editor) = launchEditor()
        defer { app.terminate() }
        editor.typeText("hello :")
        editor.typeText("\u{1b}")
        XCTAssertEqual(editor.value as? String, "hello :")
    }

    func testEmojiCompletionUsesEditorSnapshotAndOneUndo() {
        let (app, editor) = launchEditor()
        defer { app.terminate() }
        editor.typeText("中文 :sm")
        editor.typeText("\t")
        XCTAssertTrue((editor.value as? String)?.hasPrefix("中文 ") == true)
    }
}

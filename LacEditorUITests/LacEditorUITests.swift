//
//  LacEditorUITests.swift
//  LacEditorUITests
//
//  Created by Алексей Чудинов on 04.11.2026.
//

import XCTest

final class LacEditorUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testAutoPairBracketInput() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launchArguments = [
            "-autoPairBracketsEnabled", "YES",
            "-autoPairMarkdownEnabled", "YES"
        ]
        app.launch()
        app.typeKey("n", modifierFlags: .command)

        let editor = app.descendants(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("(")
        XCTAssertTrue(editor.exists)
        XCTAssertEqual(editor.value as? String, "(")
    }

    func testAutoPairMarkdownInput() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-autoPairBracketsEnabled", "YES", "-autoPairMarkdownEnabled", "YES"]
        app.launch()
        app.typeKey("n", modifierFlags: .command)
        let editor = app.descendants(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("*")
        XCTAssertEqual(editor.value as? String, "*")
    }

    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

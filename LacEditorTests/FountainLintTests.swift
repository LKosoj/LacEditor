import XCTest
@testable import LacEditor

final class FountainLintTests: XCTestCase {
    private func kinds(_ text: String, titlePage: Bool = false) -> [Int: FountainElementKind] {
        Dictionary(FountainLint.parse(text, allowsTitlePage: titlePage).lines.map { ($0.number, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    func testSceneCharacterAndDialogue() {
        let result = kinds("INT. KITCHEN - DAY\n\nJOHN\nHello.\n")
        XCTAssertEqual(result[1], .sceneHeading)
        XCTAssertEqual(result[3], .character)
        XCTAssertEqual(result[4], .dialogue)
    }

    func testParentheticalInsideDialogue() {
        let result = kinds("JOHN\n(quietly)\nHello.\n")
        XCTAssertEqual(result[1], .character)
        XCTAssertEqual(result[2], .parenthetical)
        XCTAssertEqual(result[3], .dialogue)
    }

    func testCRLFAndBOMAreNormalized() {
        let result = kinds("\u{FEFF}INT. A - DAY\r\n\r\nJOHN\r\nHi\r\n")
        XCTAssertEqual(result[1], .sceneHeading)
        XCTAssertEqual(result[3], .character)
    }

    func testTransitionActionAndSingleUppercaseLine() {
        let result = kinds("He walks.\n\nCUT TO:\n\nSTOP\n")
        XCTAssertEqual(result[1], .action)
        XCTAssertEqual(result[3], .transition)
        XCTAssertEqual(result[5], .action)
    }

    func testForcedElements() {
        XCTAssertEqual(FountainLint.classifyBlock(["!JOHN", "Hello."]), .action)
        XCTAssertEqual(FountainLint.classifyBlock([".ИНТ. КУХНЯ - ДЕНЬ"]), .sceneHeading)
        XCTAssertEqual(FountainLint.classifyBlock(["@李雷", "你好"]), .character)
        XCTAssertEqual(FountainLint.classifyBlock(["> FADE OUT."]), .transition)
        XCTAssertEqual(FountainLint.classifyBlock(["> THE END <"]), .centered)
        XCTAssertEqual(FountainLint.classifyBlock(["~la la"]), .lyrics)
        XCTAssertEqual(FountainLint.classifyBlock(["==="]), .pageBreak)
        XCTAssertEqual(FountainLint.classifyBlock(["= synopsis"]), .synopsis)
        XCTAssertEqual(FountainLint.classifyBlock(["## Act"]), .section(level: 2))
    }

    func testNaturalHeadingIsCaseInsensitive() {
        XCTAssertEqual(FountainLint.classifyBlock(["int. kitchen - day"]), .sceneHeading)
        XCTAssertEqual(FountainLint.classifyBlock(["Int the house he sat."]), .sceneHeading)
    }

    func testChineseLineWithoutCaseStaysAction() {
        XCTAssertEqual(FountainLint.classifyBlock(["李雷：你好。"]), .action)
        XCTAssertEqual(FountainLint.classifyBlock(["李雷", "你好。"]), .character)
    }

    func testIsUppercase() {
        XCTAssertTrue(FountainLint.isUppercase("ABC"))
        XCTAssertTrue(FountainLint.isUppercase("ИВАН"))
        XCTAssertTrue(FountainLint.isUppercase("李雷"))
        XCTAssertFalse(FountainLint.isUppercase("Abc"))
        XCTAssertFalse(FountainLint.isUppercase("123"))
    }

    func testNotesAndBoneyardAreSkipped() {
        let note = FountainLint.parse("[[comment]]\n", allowsTitlePage: false)
        XCTAssertTrue(note.isValid)
        XCTAssertEqual(note.lines.first?.kind, .note)
        let boneyard = FountainLint.parse("/* hidden\nJOHN\nlines */\n\nHe walks.\n", allowsTitlePage: false)
        XCTAssertTrue(boneyard.isValid)
        XCTAssertEqual(boneyard.lines.first?.kind, .boneyard)
    }

    func testUnclosedNoteAndBoneyard() {
        XCTAssertTrue(FountainLint.parse("Text [[ never closed\n", allowsTitlePage: false).issues.contains { $0.kind == .unclosedNote })
        XCTAssertTrue(FountainLint.parse("a /* open\n\nb\n", allowsTitlePage: false).issues.contains { $0.kind == .unclosedBoneyard })
    }

    func testNoteWithBlankLineIsUnclosed() {
        let result = FountainLint.parse("a [[ first\n\nsecond ]] b\n", allowsTitlePage: false)
        XCTAssertTrue(result.issues.contains { $0.kind == .unclosedNote })
    }

    func testMissingBlankAfterNaturalHeading() {
        let bad = FountainLint.parse("INT. ROOM - DAY\nHe enters.\n", allowsTitlePage: false)
        XCTAssertTrue(bad.issues.contains { $0.kind == .missingBlankAfterHeading && $0.line == 1 })
        let forced = FountainLint.parse(".ROOM\nHe enters.\n", allowsTitlePage: false)
        XCTAssertFalse(forced.issues.contains { $0.kind == .missingBlankAfterHeading })
    }

    func testCodeFenceIsReported() {
        let result = FountainLint.parse("```fountain\nINT. A - DAY\n```\n", allowsTitlePage: false)
        XCTAssertEqual(result.issues.filter { $0.kind == .codeFence }.count, 2)
    }

    func testTitlePage() {
        let text = "Title: Story\nAuthor: Anna\n\nINT. A - DAY\n"
        let allowed = FountainLint.parse(text, allowsTitlePage: true)
        XCTAssertTrue(allowed.isValid)
        XCTAssertEqual(allowed.lines.first?.kind, .titlePage)
        let denied = FountainLint.parse(text, allowsTitlePage: false)
        XCTAssertTrue(denied.issues.contains { $0.kind == .titlePage })
    }

    func testActionWithColonIsNotTitlePage() {
        let action = FountainLint.parse("Mary looks at the clock: it's late.\n", allowsTitlePage: false)
        XCTAssertFalse(action.issues.contains { $0.kind == .titlePage })
        XCTAssertEqual(action.lines.first?.kind, .action)
        let draft = FountainLint.parse("Draft date: 1.1.2026\n\nHe walks.\n", allowsTitlePage: true)
        XCTAssertEqual(draft.lines.first?.kind, .titlePage)
    }

    func testEmptyDocument() {
        XCTAssertTrue(FountainLint.parse("", allowsTitlePage: false).issues.contains { $0.kind == .emptyDocument })
        XCTAssertTrue(FountainLint.parse(" \n\n", allowsTitlePage: false).issues.contains { $0.kind == .emptyDocument })
    }
}

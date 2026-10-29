import Foundation
import XCTest
import cmark_gfm
@testable import LacEditor

final class MarkdownFormattingServiceTests: XCTestCase {
    func testLooseHeadingFormattingUsesConfirmedMarker() throws {
        let source = "###中文😀" as NSString
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source, selection: NSRange(location: 3, length: 0), command: .heading(3), strictMode: false))
        XCTAssertEqual(edit.replacement, "中文😀")
        XCTAssertEqual(source as String, "###中文😀")
        let strict = try XCTUnwrap(MarkdownFormattingService.edit(in: source, selection: NSRange(location: 3, length: 0), command: .heading(3)))
        XCTAssertEqual(strict.replacement, "### ###中文😀")
    }

    func testListContainerPrefixProofKeepsOwnMarkerAndRejectsUnprovenEarlierParent() throws {
        for (text, expected, continuation) in [
            ("- x", Optional(""), Optional("")),
            ("> - x", "> ", "> "),
            ("- - child", "- ", "  "),
            ("- [x] 中文😀", "", ""),
            ("- parent\n  - child", "  ", "  "),
            ("-\tparent\n    - child", "    ", "    "),
            ("-\tparent\n\t- child", "\t", "\t"),
            (">\t- parent\n>\t  - child", ">\t  ", ">\t  ")
        ] {
            let checked = MarkdownMathExtension.withDocument(text) { root, _, _ -> Bool in
                var items: [OpaquePointer] = []
                func visit(_ node: OpaquePointer) {
                    if cmark_node_get_type(node) == CMARK_NODE_ITEM { items.append(node) }
                    var child = cmark_node_first_child(node)
                    while let current = child { visit(current); child = cmark_node_next(current) }
                }
                visit(root)
                guard let item = items.last else { XCTFail("Missing item: \(text)"); return false }
                let prefix = MarkdownPresentationParser.listContainerPrefixes(item, source: .init(text, root: root), text: text as NSString)
                XCTAssertEqual(prefix?.source, expected, text)
                XCTAssertEqual(prefix?.continuation, continuation, text)
                return true
            }
            XCTAssertEqual(checked, true)
        }
    }

    func testMathCommandsPreserveSelectionAndRejectCode() throws {
        let text = "before 中文😀 after"
        let selected = (text as NSString).range(of: "中文😀")
        let inline = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selected, command: .inlineMath))
        let inlineResult = apply(inline, to: text)
        XCTAssertEqual(inlineResult, "before $中文😀$ after")
        XCTAssertEqual((inlineResult as NSString).substring(with: inline.selectionRange), "中文😀")
        let empty = try XCTUnwrap(MarkdownFormattingService.edit(in: "abc" as NSString, selection: NSRange(location: 1, length: 0), command: .inlineMath))
        XCTAssertEqual(apply(empty, to: "abc"), "a$$bc")
        XCTAssertEqual(empty.selectionRange, NSRange(location: 2, length: 0))
        let emptyBlock = try XCTUnwrap(MarkdownFormattingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), command: .blockMath))
        XCTAssertEqual(emptyBlock.replacement, "$$\n\n$$")
        XCTAssertEqual(emptyBlock.selectionRange, NSRange(location: 3, length: 0))
        let blockText = "before\r\nvalue\r\nafter"
        let value = (blockText as NSString).range(of: "value")
        let block = try XCTUnwrap(MarkdownFormattingService.edit(in: blockText as NSString, selection: value, command: .blockMath))
        let blockResult = apply(block, to: blockText)
        XCTAssertTrue(blockResult.contains("$$\r\nvalue\r\n$$"))
        XCTAssertEqual((blockResult as NSString).substring(with: block.selectionRange), "value")
        for source in ["`code`", "```\ncode\n```", "$code$", "\\code"] {
            let range = (source as NSString).range(of: "code")
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: range, command: .inlineMath), source)
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: range, command: .blockMath), source)
        }
        for source in ["> before text", "- before text", "| text |\n| ---- |\n| cell |"] {
            let range = (source as NSString).range(of: "text")
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: range, command: .blockMath), source)
        }
        let quoted = "> text"
        XCTAssertNotNil(MarkdownFormattingService.edit(in: quoted as NSString, selection: (quoted as NSString).range(of: "text"), command: .inlineMath))
    }
    func testBlockMathUsesConfirmedQuoteAndListPrefixes() throws {
        for newline in ["\n", "\r\n"] {
            for (prefix, continuation) in [("> ", "> "), ("- ", "  "), ("> - ", ">   "), ("- [x] ", "  "), ("> - [X] ", ">   ")] {
                let separator = prefix == "> " ? newline + ">" + newline : newline
                let source = prefix + "中文😀" + separator + prefix + "sibling"
                let selection = (source as NSString).range(of: "中文😀")
                let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .blockMath), source)
                let result = apply(edit, to: source)
                XCTAssertEqual(result, prefix + "$$" + newline + continuation + "中文😀" + newline + continuation + "$$" + separator + prefix + "sibling")
                XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), "中文😀")
                XCTAssertEqual(MarkdownPresentationParser.parse(result).formulas.first?.source, "中文😀\n")
            }
        }
        for source in ["> before text", "- before text", "> text\n> continued", "- `text`", "- $text$"] {
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString,
                selection: (source as NSString).range(of: "text"), command: .blockMath), source)
        }
    }

    func testEmptyContainerMathDoesNotEscapeItsOwnerAtEndOfFile() {
        for source in ["> text", "- text", "> - [x] ", "-\t"] {
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: (source as NSString).length, length: 0), command: .blockMath), source)
        }
        let source = "> text\n"
        XCTAssertNotNil(MarkdownFormattingService.edit(in: source as NSString,
            selection: NSRange(location: (source as NSString).length, length: 0), command: .blockMath))
    }

    func testEmptyQuoteAndListMathKeepsContainerAndPlacesCaretInBody() throws {
        for (prefix, continuation) in [("> ", "> "), ("- ", "  "), ("7) ", "   "), ("- [ ] ", "  "), ("- [X] ", "  ")] {
            let source = "中文😀\n\n" + prefix
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: (source as NSString).length, length: 0), command: .blockMath), source)
            let result = apply(edit, to: source)
            XCTAssertEqual(result, source + "$$\n" + continuation + "\n" + continuation + "$$")
            XCTAssertEqual(edit.selectionRange, NSRange(location: (source as NSString).length + 3 + (continuation as NSString).length, length: 0))
            let formula = try XCTUnwrap(MarkdownPresentationParser.parse(result).formulas.first)
            XCTAssertEqual(formula.source, "\n")
        }
    }

    func testEmptyNestedListAndBareQuoteMathKeepAncestors() throws {
        let cases: [(String, String)] = [
            ("> - ", ">   "),
            ("- parent\r\n  - ", "    "),
            ("- parent\n  12) ", "      "),
            ("> - parent\n>   - ", ">     ")
        ]
        for (source, continuation) in cases {
            let newline = source.contains("\r\n") ? "\r\n" : "\n"
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: (source as NSString).length, length: 0), command: .blockMath), source)
            XCTAssertEqual(apply(edit, to: source), source + "$$" + newline + continuation + newline + continuation + "$$")
            XCTAssertEqual(edit.selectionRange, NSRange(location: (source as NSString).length + 2 + (newline as NSString).length + (continuation as NSString).length, length: 0))
        }
        let bare = try XCTUnwrap(MarkdownFormattingService.edit(in: ">" as NSString, selection: NSRange(location: 1, length: 0), command: .blockMath))
        XCTAssertEqual(apply(bare, to: ">"), "> $$\n> \n> $$")
        XCTAssertEqual(bare.selectionRange, NSRange(location: 7, length: 0))
    }

    func testMultilineContainerMathKeepsRawSelectionAndPrefixes() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for (prefix, continuation) in [("> ", "> "), ("- ", "  "), ("> - ", ">   "), ("- [ ] ", "  "), ("> - [x] ", ">   ")] {
                let rawBody = "中文😀" + newline + continuation + "e\u{301}"
                let source = prefix + rawBody
                let selection = (source as NSString).range(of: rawBody)
                let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .blockMath), source)
                let result = apply(edit, to: source)
                XCTAssertEqual(result, prefix + "$$" + newline + continuation + rawBody + newline + continuation + "$$")
                XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), rawBody)
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(result).formulas.first)
                XCTAssertTrue(formula.source.utf16.elementsEqual("中文😀\ne\u{301}\n".utf16))
            }
        }
        for source in ["> first\nlazy", "- first\nlazy"] {
            let selection = NSRange(location: 2, length: (source as NSString).length - 2)
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .blockMath), source)
        }
    }

    private func apply(_ edit: MarkdownFormattingEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testLinkCommandUsesFormattingService() throws {
        let source = "before 中文😀 after"
        let selection = (source as NSString).range(of: "中文😀")
        let input = MarkdownLinkInput(label: "中文😀", address: "https://example.com")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .link(input)))
        let result = apply(edit, to: source)
        XCTAssertEqual(result, "before [中文😀](<https://example.com>) after")
        XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), input.label)
        XCTAssertEqual(MarkdownFormattingCommand.link(input), .link(input))
    }

    func testTableCommandsUseFormattingPath() throws {
        let create = try XCTUnwrap(MarkdownFormattingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), command: .table(.create(rows: 1, columns: 2))))
        XCTAssertEqual(create.replacement, "|   |   |\n| --- | --- |\n|   |   |")
        XCTAssertEqual(create.selectionRange, NSRange(location: 2, length: 0))
        let source = "| A | B |\n| --- | --- |\n| 中文😀 | x |"
        let selection = (source as NSString).range(of: "中文😀")
        let caret = NSRange(location: selection.location, length: 0)
        let row = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: caret, command: .table(.insertRowAfter)))
        XCTAssertEqual(apply(row, to: source), source + "\n|   |   |")
        let column = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: caret, command: .table(.insertColumnAfter)))
        XCTAssertEqual(apply(column, to: source), "| A |   | B |\n| --- | --- | --- |\n| 中文😀 |   | x |")
        let align = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: caret, command: .table(.align(.center))))
        XCTAssertEqual(apply(align, to: source), "| A | B |\n| :---: | --- |\n| 中文😀 | x |")
        XCTAssertEqual(align.selectionRange, caret)
        let one = "| A |\n| --- |\n| x |" as NSString
        XCTAssertNil(MarkdownFormattingService.edit(in: one, selection: NSRange(location: one.range(of: "x").location, length: 0), command: .table(.deleteColumn)))
        XCTAssertNil(MarkdownFormattingService.edit(in: "plain" as NSString, selection: NSRange(location: 0, length: 0), command: .table(.deleteRow)))
    }

    func testInlineCommandsPreserveUnicodeSelectionAndToggle() throws {
        let text = "before 中文😀e\u{301} after"
        let selected = (text as NSString).range(of: "中文😀e\u{301}")
        for (command, marker) in [(MarkdownFormattingCommand.bold, "**"), (.italic, "*"), (.strikethrough, "~~")] {
            let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selected, command: command))
            let formatted = apply(insert, to: text)
            XCTAssertEqual(formatted, "before \(marker)中文😀e\u{301}\(marker) after")
            XCTAssertEqual((formatted as NSString).substring(with: insert.selectionRange), "中文😀e\u{301}")
            let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: command))
            XCTAssertEqual(apply(remove, to: formatted), text)
            XCTAssertEqual(remove.selectionRange, selected)
        }
    }

    func testEmptySelectionInsertsMarkersWithCaretInside() throws {
        let text = "ab😀cd"
        let selection = NSRange(location: 2, length: 0)
        for (command, marker) in [(MarkdownFormattingCommand.bold, "**"), (.italic, "*"), (.strikethrough, "~~"), (.inlineCode, "`")] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command))
            XCTAssertEqual(apply(edit, to: text), "ab\(marker)\(marker)😀cd")
            XCTAssertEqual(edit.selectionRange, NSRange(location: 2 + (marker as NSString).length, length: 0))
        }
    }

    func testCodeChoosesLongerFenceAndPreservesSpaces() throws {
        for selected in ["a`b", "`edge`", "text"] {
            let text = "x" + selected + "y"
            let range = NSRange(location: 1, length: (selected as NSString).length)
            let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: range, command: .inlineCode))
            let formatted = apply(insert, to: text)
            XCTAssertEqual((formatted as NSString).substring(with: insert.selectionRange), selected)
            let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: .inlineCode))
            XCTAssertEqual(apply(remove, to: formatted), text)
        }
    }

    func testOuterWhitespaceStaysOutsideAndMultipleParagraphsAreRejected() throws {
        let text = "left  word  right"
        let selection = (text as NSString).range(of: "  word  ")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .bold))
        let result = apply(edit, to: text)
        XCTAssertEqual(result, "left  **word**  right")
        XCTAssertTrue(MarkdownRenderer.render(result, darkMode: false).contains("<strong>word</strong>"))
        XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), "word")
        XCTAssertNil(MarkdownFormattingService.edit(in: "   " as NSString, selection: NSRange(location: 0, length: 3), command: .bold))
        let paragraphs = "first\r\n \r\nsecond"
        XCTAssertNil(MarkdownFormattingService.edit(in: paragraphs as NSString, selection: NSRange(location: 0, length: (paragraphs as NSString).length), command: .italic))
    }

    func testEscapedMarkersAreNeverRemoved() {
        for (text, command) in [("\\**word**", MarkdownFormattingCommand.bold), ("\\`word`", .inlineCode)] {
            let selection = (text as NSString).range(of: "word")
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command))
        }
    }

    func testEscapedInsertionBoundaryDoesNotChangeText() {
        let text = "\\word"
        let selection = (text as NSString).range(of: "word")
        for command in [MarkdownFormattingCommand.bold, .italic, .strikethrough, .inlineCode] {
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command))
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: NSRange(location: selection.location, length: 0), command: command))
        }
        XCTAssertEqual(text, "\\word")
    }

    func testInlineClosingDelimiterAfterBackslashes() throws {
        let odd = "word\\"
        let oddRange = NSRange(location: 0, length: (odd as NSString).length)
        for command in [MarkdownFormattingCommand.bold, .italic, .strikethrough] {
            XCTAssertNil(MarkdownFormattingService.edit(in: odd as NSString, selection: oddRange, command: command))
        }
        XCTAssertNotNil(MarkdownFormattingService.edit(in: odd as NSString, selection: oddRange, command: .inlineCode))
        let even = "word\\\\"
        let evenRange = NSRange(location: 0, length: (even as NSString).length)
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: even as NSString, selection: evenRange, command: .bold))
        XCTAssertTrue(MarkdownRenderer.render(apply(edit, to: even), darkMode: false).contains("<strong>word\\</strong>"))
    }

    func testUnclosedQuotedFenceEndsWhenQuoteEnds() throws {
        let text = "> ```\n> inside\n\nafter"
        let inside = (text as NSString).range(of: "inside")
        let after = (text as NSString).range(of: "after")
        for command in [MarkdownFormattingCommand.heading(1), .quote] {
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: inside, command: command))
            XCTAssertNotNil(MarkdownFormattingService.edit(in: text as NSString, selection: after, command: command))
        }
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: after, command: .heading(1)))
        let rendered = MarkdownRenderer.render(apply(edit, to: text), darkMode: false)
        XCTAssertTrue(rendered.contains("<code>inside"))
        XCTAssertTrue(rendered.contains("<h1>after</h1>"))
    }

    func testBlockCommandsDoNotModifyFencedOrIndentedCode() throws {
        let text = "````swift\ninside\n```\nstill inside\n````\nafter"
        for line in ["inside", "still inside", "````"] {
            let selection = (text as NSString).range(of: line)
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(1)))
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .quote))
        }
        let after = (text as NSString).range(of: "after")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: after, command: .heading(1)))
        XCTAssertTrue(apply(edit, to: text).hasSuffix("# after"))
        XCTAssertNil(MarkdownFormattingService.edit(in: "    code" as NSString, selection: NSRange(location: 4, length: 0), command: .quote))
    }

    func testAmbiguousAdjacentMarkersAreNotRemoved() throws {
        let text = "***word***"
        let selection = (text as NSString).range(of: "word")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .bold))
        XCTAssertEqual(apply(edit, to: text), "*****word*****")
    }

    func testHeadingsToggleMultipleLinesAndPreserveLineEndings() throws {
        let text = "first\r\nsecond\rthird\nrest"
        let selection = NSRange(location: 0, length: ("first\r\nsecond\r" as NSString).length)
        let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(2)))
        let formatted = apply(insert, to: text)
        XCTAssertEqual(formatted, "## first\r\n## second\rthird\nrest")
        let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: .heading(2)))
        XCTAssertEqual(apply(remove, to: formatted), text)
    }

    func testHeadingMarkerFollowedByTabIsReplacedOrRemoved() throws {
        let text = "#\tTitle"
        let selection = (text as NSString).range(of: "Title")
        let change = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(2)))
        XCTAssertEqual(apply(change, to: text), "## Title")
        let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(1)))
        XCTAssertEqual(apply(remove, to: text), "Title")
        XCTAssertTrue(MarkdownRenderer.render(text, darkMode: false).contains("<h1>Title</h1>"))
    }

    func testQuoteAddsAndRemovesOneLevelIncludingMixedLines() throws {
        let text = "> existing\nplain"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .quote))
        let formatted = apply(insert, to: text)
        XCTAssertEqual(formatted, "> > existing\n> plain")
        let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: .quote))
        XCTAssertEqual(apply(remove, to: formatted), text)
    }

    func testRejectsInvalidRangesFenceLinesAndNestedHeadingChanges() {
        let text = "😀"
        XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: NSRange(location: 1, length: 0), command: .bold))
        XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: NSRange(location: 4, length: 0), command: .bold))
        XCTAssertNil(MarkdownFormattingService.edit(in: "```swift" as NSString, selection: NSRange(location: 1, length: 0), command: .heading(1)))
        XCTAssertNil(MarkdownFormattingService.edit(in: "- item" as NSString, selection: NSRange(location: 3, length: 0), command: .heading(1)))
        XCTAssertNil(MarkdownFormattingService.edit(in: "text" as NSString, selection: NSRange(location: 0, length: 0), command: .heading(7)))
    }
    func testNewListCommandsPreserveSelectedUnicodeAndCRLF() throws {
        let source = "中文😀\r\ne\u{301} text"
        let selected = NSRange(location: 0, length: (source as NSString).length)
        for (command, expected) in [
            (MarkdownFormattingCommand.bulletList, "- 中文😀\r\n- e\u{301} text"),
            (.numberedList, "1. 中文😀\r\n2. e\u{301} text"),
            (.taskList, "- [ ] 中文😀\r\n- [ ] e\u{301} text")
        ] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selected, command: command))
            let result = apply(edit, to: source)
            XCTAssertEqual(result, expected)
            XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), String(expected.dropFirst(command == .taskList ? 6 : command == .numberedList ? 3 : 2)))
        }
    }

    func testExistingSingleLineListsConvertWithSourceAndSelectionPreserved() throws {
        let cases: [(String, MarkdownFormattingCommand, String)] = [
            ("- 中文😀\r\n- e\u{301}", .numberedList, "1. 中文😀\r\n2. e\u{301}"),
            ("7) first\n8) second", .bulletList, "- first\n- second"),
            ("- [x] done\n- [ ] todo", .numberedList, "1. done\n2. todo"),
            ("- [x] done\n- plain", .taskList, "- [x] done\n- [ ] plain"),
            ("> - one\r\n> - two", .numberedList, "> 1. one\r\n> 2. two"),
            ("-", .numberedList, "1. ")
        ]
        for (source, command, expected) in cases {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: 0, length: (source as NSString).length), command: command), source)
            XCTAssertEqual(apply(edit, to: source), expected)
            XCTAssertEqual(edit.selectionRange, NSRange(location: 0, length: (expected as NSString).length))
        }
        let source = "- 中文😀\n- second\n- third"
        let body = (source as NSString).range(of: "中文😀")
        let caret = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
            selection: NSRange(location: NSMaxRange(body), length: 0), command: .taskList))
        XCTAssertEqual(apply(caret, to: source), "- [ ] 中文😀\n- second\n- third")
        XCTAssertEqual(caret.selectionRange, NSRange(location: NSMaxRange(body) + 4, length: 0))
        let subset = (source as NSString).range(of: "- second\n- third")
        let numbered = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: subset, command: .numberedList))
        XCTAssertEqual(apply(numbered, to: source), "- 中文😀\n1. second\n2. third")
    }

    func testExistingListSameTypeAndAmbiguousSelectionAreUnchanged() {
        for (source, command) in [("+ item", MarkdownFormattingCommand.bulletList), ("7) item", .numberedList), ("- [X] done", .taskList)] {
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: NSRange(location: 2, length: 0), command: command))
        }
        for source in ["- first\n\nordinary", "> - a\n>\t- b"] {
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: 0, length: (source as NSString).length), command: .numberedList), source)
        }
        XCTAssertNil(MarkdownFormattingService.edit(in: "- item" as NSString, selection: NSRange(location: 0, length: 1), command: .numberedList))
    }

    func testMultilineListConversionPreservesNestedContentAndCode() throws {
        let cases: [(String, MarkdownFormattingCommand, String)] = [
            ("- parent\n  - child\n- next", .numberedList, "1. parent\n   - child\n2. next"),
            ("- parent\n  continuation", .numberedList, "1. parent\n   continuation"),
            ("- parent\nlazy", .numberedList, "1. parent\nlazy"),
            ("> - 中文😀\r\n>   - e\u{301}\r\n> - next", .numberedList, "> 1. 中文😀\r\n>    - e\u{301}\r\n> 2. next"),
            ("7) parent\n   - child", .bulletList, "- parent\n  - child"),
            ("- [x] parent\n  - child", .numberedList, "1. parent\n   - child"),
            ("- parent\n  - child", .taskList, "- [ ] parent\n  - child"),
            ("- parent\n\n  ```swift\n  let x = 1\n  ```", .numberedList,
             "1. parent\n\n   ```swift\n   let x = 1\n   ```")
        ]
        for (source, command, expected) in cases {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: 0, length: (source as NSString).length), command: command), source)
            XCTAssertEqual(apply(edit, to: source), expected, source)
            XCTAssertEqual(edit.selectionRange, NSRange(location: 0, length: (expected as NSString).length))
        }
    }

    func testTopLevelListTabsUseFourColumnStopsAndPreserveContent() throws {
        let cases: [(String, MarkdownFormattingCommand, String)] = [
            ("-\tparent\n\tchild", .numberedList, "1. parent\n   child"),
            ("1.\tparent\n\tchild", .bulletList, "- parent\n  child"),
            ("- parent\n\t- child", .numberedList, "1. parent\n     - child"),
            ("- a\tb", .numberedList, "1. a\tb"),
            ("- parent\nlazy\ttext", .numberedList, "1. parent\nlazy\ttext"),
            ("- [x] parent\n\tchild", .numberedList, "1. parent\n     child"),
            ("-\t[x] parent\n\tchild", .numberedList, "1. parent\n   child"),
            ("- [x] a\tb", .numberedList, "1. a\tb"),
            ("- [x]\tparent\n  continuation", .numberedList, "1. parent\n   continuation"),
            ("7)\t[x]\tbody", .numberedList, "7)\tbody")
        ]
        for (source, command, expected) in cases {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: 0, length: (source as NSString).length), command: command), source)
            XCTAssertEqual(apply(edit, to: source), expected, source)
        }
        let source = "- parent\n\tcontinued"
        let caret = NSRange(location: (source as NSString).range(of: "\t").location, length: 0)
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: caret, command: .numberedList))
        XCTAssertEqual(edit.selectionRange, NSRange(location: caret.location + 1, length: 0))
    }

    func testAncestorTabsUseAbsoluteColumnsWhenConvertingLists() throws {
        let cases: [(String, String)] = [
            ("> -\tparent\n>   continuation", "> 1. parent\n>    continuation"),
            ("> - a\n> \t- b", "> 1. a\n>    - b"),
            (">\t- parent\n>\t  - child", ">\t1. parent\n>\t   - child"),
            ("-\tparent\n\t- child", "1. parent\n   - child")
        ]
        for (source, expected) in cases {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: 0, length: (source as NSString).length), command: .numberedList), source)
            XCTAssertEqual(apply(edit, to: source), expected)
        }
        let source = "-\tparent\r\n\t- child\r\n\t  continued"
        let selected = (source as NSString).range(of: "\t- child\r\n\t  continued")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selected, command: .numberedList))
        XCTAssertEqual(apply(edit, to: source), "-\tparent\r\n\t1. child\r\n\t   continued")
    }

    func testSameLineNestedSelectionConvertsInnerOwner() throws {
        let source = "- - child"
        for selection in [(source as NSString).range(of: "child"), NSRange(location: 2, length: 7)] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .numberedList))
            XCTAssertEqual(apply(edit, to: source), "- 1. child")
        }
    }

    func testListSubsetDoesNotChangeUnselectedSpacingOrNumbering() {
        for source in ["- a\n\n- b", "3. before\n\n- a\n- b", "3. before\n- a\n- b"] {
            let selected = (source as NSString).range(of: "- a")
            XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: selected, command: .numberedList), source)
        }
    }

    func testOrderedTaskConversionPreservesExistingNumbers() throws {
        let source = "7) plain\n8) [x] done\n9) [ ] todo"
        for selected in [NSRange(location: 0, length: (source as NSString).length), (source as NSString).range(of: "8) [x] done\n9) [ ] todo")] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selected, command: .numberedList))
            XCTAssertEqual(apply(edit, to: source), "7) plain\n8) done\n9) todo")
        }
    }

    func testMultilineListCaretAndNestedLeafConvertOnlyTheirOwner() throws {
        let source = "- parent\n  continued\n  - child\n- next"
        let caret = (source as NSString).range(of: "continued").location + 3
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
            selection: NSRange(location: caret, length: 0), command: .numberedList))
        XCTAssertEqual(apply(edit, to: source), "1. parent\n   continued\n   - child\n- next")
        XCTAssertEqual(edit.selectionRange, NSRange(location: caret + 2, length: 0))
        let child = (source as NSString).range(of: "  - child")
        let nested = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: child, command: .numberedList))
        XCTAssertEqual(apply(nested, to: source), "- parent\n  continued\n  1. child\n- next")
    }

    func testQuotedTaskConversionUsesConfirmedContentAndKeepsCheckedState() throws {
        let cases: [(String, MarkdownFormattingCommand, String)] = [
            ("> - [x] done\r\n> - [ ] todo", .numberedList, "> 1. done\r\n> 2. todo"),
            ("> - [X] **done**", .bulletList, "> - **done**"),
            ("> - [x] done\n> - plain", .taskList, "> - [x] done\n> - [ ] plain"),
            ("> 7) [x] done\n> 8) plain", .numberedList, "> 7) done\n> 8) plain")
        ]
        for (source, command, expected) in cases {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString,
                selection: NSRange(location: 0, length: (source as NSString).length), command: command), source)
            XCTAssertEqual(apply(edit, to: source), expected)
        }
        let source = "> - [x] done\n\n[x]: https://example.com"
        XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString,
            selection: (source as NSString).range(of: "done"), command: .numberedList))
        XCTAssertNil(MarkdownFormattingService.edit(in: "> - [x] done" as NSString,
            selection: NSRange(location: 4, length: 2), command: .numberedList))
    }

    func testNewCommandsAtEmptyCursorAndBlockBoundaries() throws {
        for (command, expected, caret) in [
            (MarkdownFormattingCommand.bulletList, "- ", 2), (.numberedList, "1. ", 3),
            (.taskList, "- [ ] ", 6), (.fencedCode, "```\n\n```", 4), (.horizontalRule, "---", 3)
        ] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), command: command))
            XCTAssertEqual(apply(edit, to: ""), expected)
            XCTAssertEqual(edit.selectionRange, NSRange(location: caret, length: 0))
        }
        let source = "first\r\nsecond"
        let selection = NSRange(location: 0, length: 7)
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .bulletList))
        XCTAssertEqual(apply(edit, to: source), "- first\r\nsecond")
    }

    func testFencedCodeAndHorizontalRuleKeepTextAndLineEndings() throws {
        let source = "中文 ``` x\r\nnext"
        let selected = (source as NSString).range(of: "中文 ``` x")
        let code = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selected, command: .fencedCode))
        let fenced = apply(code, to: source)
        XCTAssertEqual(fenced, "````\r\n中文 ``` x\r\n````\r\nnext")
        XCTAssertEqual((fenced as NSString).substring(with: code.selectionRange), "中文 ``` x")
        let rule = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selected, command: .horizontalRule))
        XCTAssertEqual(apply(rule, to: source), "中文 ``` x\r\n\r\n---\r\n\r\nnext")
        XCTAssertEqual(rule.selectionRange, selected)
    }

    func testNewBlocksRejectCodeAndAmbiguousLines() {
        let commands: [MarkdownFormattingCommand] = [.bulletList, .numberedList, .taskList, .fencedCode, .horizontalRule]
        for text in ["```swift\nlet x = 1\n```", "    code", "> quote", "\\- escaped"] {
            let selection = NSRange(location: (text as NSString).length / 2, length: 0)
            for command in commands {
                XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command), "\(command): \(text)")
            }
        }
        for command in [MarkdownFormattingCommand.fencedCode, .horizontalRule] {
            XCTAssertNil(MarkdownFormattingService.edit(in: "- item" as NSString, selection: NSRange(location: 3, length: 0), command: command))
        }
    }
    func testUnclosedFenceAtEndRejectsAllNewCommands() {
        let commands: [MarkdownFormattingCommand] = [.bulletList, .numberedList, .taskList, .fencedCode, .horizontalRule]
        for newline in ["\n", "\r\n"] {
            for source in ["```" + newline, "> ```" + newline, "- ```" + newline] {
                let selection = NSRange(location: (source as NSString).length, length: 0)
                for command in commands {
                    XCTAssertNil(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: command), "\(command): \(source.debugDescription)")
                }
            }
        }
    }

    func testUnicodeSeparatorsStayInsideMarkdownLine() throws {
        for separator in ["\u{2028}", "\u{2029}"] {
            for newline in ["\n", "\r\n"] {
                let source = "a" + separator + "b" + newline + "next"
                let selection = NSRange(location: 2, length: 1)
                let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .fencedCode))
                let result = apply(edit, to: source)
                XCTAssertEqual(result, "```" + newline + "a" + separator + "b" + newline + "```" + newline + "next")
                XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), "b")
                XCTAssertTrue(MarkdownRenderer.renderPage(result, darkMode: false).body.contains("<code>a" + separator + "b\n</code>"))
            }
        }
    }

    func testRuleOnWhitespaceLineAndExistingBlankLines() throws {
        for (source, caret, expected) in [
            ("  \nnext", 1, "---\n  \nnext"),
            ("before\n  \nnext", 8, "before\n\n---\n  \nnext"),
            ("before\r\n  \r\nnext", 9, "before\r\n\r\n---\r\n  \r\nnext")
        ] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: NSRange(location: caret, length: 0), command: .horizontalRule))
            XCTAssertEqual(apply(edit, to: source), expected)
        }
        let source = "first\n\nnext"
        let selection = NSRange(location: 0, length: 5)
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .horizontalRule))
        XCTAssertEqual(apply(edit, to: source), "first\n\n---\n\nnext")
        XCTAssertEqual(edit.selectionRange, selection)
    }

    func testPartialMultilineSelectionPreservesSelectedText() throws {
        let source = "one\r\ntwo"
        let selection = NSRange(location: 1, length: 6)
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: .fencedCode))
        let result = apply(edit, to: source)
        XCTAssertEqual(result, "```\r\none\r\ntwo\r\n```")
        XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), "ne\r\ntw")
    }
    func testExistingBlockCommandsDoNotFormatCodeAcrossUnicodeSeparators() throws {
        for separator in ["\u{2028}", "\u{2029}"] {
            let code = "```\na" + separator + "b\n```"
            let inside = (code as NSString).range(of: "b")
            for command in [MarkdownFormattingCommand.heading(1), .quote] {
                XCTAssertNil(MarkdownFormattingService.edit(in: code as NSString, selection: inside, command: command))
                let plain = "a" + separator + "b"
                let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: plain as NSString, selection: (plain as NSString).range(of: "b"), command: command))
                XCTAssertEqual(apply(edit, to: plain), "a" + separator + (command == .quote ? "> b" : "# b"))
            }
        }
    }
    func testPartialMultilineSelectionForEveryNewCommand() throws {
        for newline in ["\n", "\r\n"] {
            let source = "alpha" + newline + "beta" + newline + "gamma"
            let selection = (source as NSString).range(of: "pha" + newline + "be")
            let cases: [(MarkdownFormattingCommand, String, String)] = [
                (.bulletList, "- alpha" + newline + "- beta" + newline + "gamma", "pha" + newline + "- be"),
                (.numberedList, "1. alpha" + newline + "2. beta" + newline + "gamma", "pha" + newline + "2. be"),
                (.taskList, "- [ ] alpha" + newline + "- [ ] beta" + newline + "gamma", "pha" + newline + "- [ ] be"),
                (.fencedCode, "```" + newline + "alpha" + newline + "beta" + newline + "```" + newline + "gamma", "pha" + newline + "be"),
                (.horizontalRule, "alpha" + newline + "beta" + newline + newline + "---" + newline + newline + "gamma", "pha" + newline + "be")
            ]
            for (command, expected, selected) in cases {
                let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: source as NSString, selection: selection, command: command))
                XCTAssertEqual(apply(edit, to: source), expected, "\(command)")
                XCTAssertEqual(edit.selectionRange, (expected as NSString).range(of: selected), "\(command)")
            }
        }
    }
}

import Foundation
import XCTest
import cmark_gfm
@testable import LacEditor

final class MarkdownMathExtensionTests: XCTestCase {
    @MainActor
    func testSyntaxPreferencesPreserveOldDefaultsAndSnapshot() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let old = preferences.markdownSyntax
        XCTAssertEqual(old, MarkdownSyntaxOptions())
        XCTAssertNil(old.preserveEditingWhitespace)
        XCTAssertNil(old.smartPunctuation)
        XCTAssertNil(old.preserveExportSoftBreaks)
        preferences.markdownSmartPunctuation = true
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownSyntax.smartPunctuation, true)
        preferences.markdownExportSoftBreaks = true
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownSyntax.preserveExportSoftBreaks, true)
        preferences.markdownEditingWhitespace = true
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownSyntax.preserveEditingWhitespace, true)
        preferences.markdownInlineMath = false
        preferences.markdownLegacyInlineMath = true
        preferences.markdownSmartPunctuation = false
        preferences.markdownEditingWhitespace = false
        preferences.markdownExportWhitespace = true
        preferences.markdownEditingSoftBreaks = false
        preferences.markdownExportSoftBreaks = false
        XCTAssertEqual(old, MarkdownSyntaxOptions())
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownSyntax,
                       MarkdownSyntaxOptions(inlineMath: false, legacyInlineMath: true, smartPunctuation: false,
                                             preserveEditingWhitespace: false, preserveExportWhitespace: true,
                                             preserveEditingSoftBreaks: false, preserveExportSoftBreaks: false))
        preferences.markdownEditingWhitespace = nil
        XCTAssertNil(AppPreferences(defaults: defaults).markdownSyntax.preserveEditingWhitespace)
        preferences.markdownSmartPunctuation = nil
        XCTAssertNil(AppPreferences(defaults: defaults).markdownSyntax.smartPunctuation)
        preferences.markdownExportSoftBreaks = nil
        XCTAssertNil(AppPreferences(defaults: defaults).markdownSyntax.preserveExportSoftBreaks)
    }

    func testInlineMathOptionsKeepBlockMathAndUseLegacyDelimiters() throws {
        let source = "正常 $x$ and $ spaced $5\n\n$$\ny\n$$"
        let modern = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(modern.inlineFormulas.map(\.source), ["x"])
        XCTAssertEqual(modern.formulas.count, 1)
        let legacy = MarkdownPresentationParser.parse(source, syntax: .init(legacyInlineMath: true))
        XCTAssertEqual(legacy.inlineFormulas.map(\.source), ["x", " spaced "])
        XCTAssertEqual(legacy.formulas.count, 1)
        let disabled = MarkdownPresentationParser.parse(source, syntax: .init(inlineMath: false))
        XCTAssertTrue(disabled.inlineFormulas.isEmpty)
        XCTAssertEqual(disabled.formulas.count, 1)
        XCTAssertEqual(source, "正常 $x$ and $ spaced $5\n\n$$\ny\n$$")
    }

    @MainActor
    func testStrictModePreferenceKeepsCurrentDefaultAndPersists() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.markdownSyntax.strictMode)
        preferences.markdownStrictMode = false
        XCTAssertFalse(AppPreferences(defaults: defaults).markdownSyntax.strictMode)
        preferences.markdownStrictMode = true
        XCTAssertTrue(AppPreferences(defaults: defaults).markdownSyntax.strictMode)
    }

    @MainActor
    func testPersistedInlineMathOptionsReachRenderingCopyAndExport() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "正常 $x$ and $ spaced $5\n\n`$code$`\n\n\\$escaped$\n\n$$\ny\n$$"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        for (enabled, legacy, expected) in [(true, false, ["x"]), (true, true, ["x", " spaced "]), (false, true, [String]())] {
            preferences.markdownInlineMath = enabled
            preferences.markdownLegacyInlineMath = legacy
            let syntax = AppPreferences(defaults: defaults).markdownSyntax
            XCTAssertEqual(syntax.inlineMath, enabled)
            XCTAssertEqual(syntax.legacyInlineMath, legacy)
            let parsed = MarkdownPresentationParser.parse(source, syntax: syntax)
            XCTAssertEqual(parsed.inlineFormulas.map(\.source), expected)
            XCTAssertEqual(parsed.formulas.map(\.source), ["y\n"])
            let page = MarkdownRenderer.renderPage(source, darkMode: false, syntax: syntax)
            XCTAssertEqual(page.formulas.filter { !$0.display }.map(\.source), expected)
            XCTAssertEqual(page.formulas.filter(\.display).map(\.source), ["y\n"])
            let copied = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, syntax: syntax))
            XCTAssertEqual(copied.mathExpressions.filter { !$0.display }.map(\.source), expected)
            XCTAssertEqual(copied.mathExpressions.filter(\.display).map(\.source), ["y\n"])
            let exported = try PandocExportService.markedExportSnapshot(source, syntax: syntax, includeTOC: false, isCancelled: { false })
            XCTAssertEqual(exported.math.filter { !$0.display }.map(\.source), expected)
            XCTAssertEqual(exported.math.filter(\.display).map(\.source), ["y\n"])
        }
        XCTAssertEqual(source, "正常 $x$ and $ spaced $5\n\n`$code$`\n\n\\$escaped$\n\n$$\ny\n$$")
    }

    func testSmartPunctuationUsesSnapshotWithoutChangingSource() {
        let source = "# \"Hello\" -- 世界"
        XCTAssertEqual(MarkdownPresentationParser.parse(source).headings.first?.title, "“Hello” – 世界")
        XCTAssertEqual(MarkdownPresentationParser.parse(source, syntax: .init(smartPunctuation: false)).headings.first?.title, "\"Hello\" -- 世界")
        XCTAssertEqual(source, "# \"Hello\" -- 世界")
    }

    func testClosingDollarImmediatelyAfterBackslashDoesNotCloseInEitherRule() {
        for syntax in [MarkdownSyntaxOptions(), MarkdownSyntaxOptions(legacyInlineMath: true)] {
            XCTAssertTrue(MarkdownPresentationParser.parse("$a\\$", syntax: syntax).inlineFormulas.isEmpty)
            XCTAssertTrue(MarkdownPresentationParser.parse("$a\\\\$", syntax: syntax).inlineFormulas.isEmpty)
            XCTAssertEqual(MarkdownPresentationParser.parse("$a\\\\$b$", syntax: syntax).inlineFormulas.map(\.source), ["a\\\\$b"])
            let mixed = "`$code$` $x$ and $y$\n\n<div>$raw$</div>"
            XCTAssertEqual(MarkdownPresentationParser.parse(mixed, syntax: syntax).inlineFormulas.map(\.source), ["x", "y"])
        }
    }

    func testChangedTableCellUsesSyntaxSnapshot() throws {
        let source = "| A |\n|---|\n| $x$ |"
        let syntax = MarkdownSyntaxOptions(inlineMath: false)
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source, syntax: syntax).tables.first)
        let row = try XCTUnwrap(table.rows.last)
        let changed = MarkdownPresentationParser.tableRowDisplay(row, text: source as NSString, previous: row,
                                                                  changedColumn: 0, referenceLabels: [], syntax: syntax)
        let cell = try XCTUnwrap(changed.cells.first)
        XCTAssertEqual(cell.displayText?.trimmingCharacters(in: .whitespaces), "$x$")
        XCTAssertFalse(cell.displayRuns.contains { if case .tableMath = $0.kind { return true }; return false })
    }
    private static func inspect(_ source: String) -> (blocks: [String], headings: [String], inline: [String])? {
        MarkdownMathExtension.withDocument(source) { root, ext, inline in
            var blocks: [String] = [], headings: [String] = []
            func visit(_ node: OpaquePointer) {
                if cmark_node_get_syntax_extension(node) == ext,
                   cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK,
                   let literal = cmark_node_get_literal(node) { blocks.append(String(cString: literal)) }
                if cmark_node_get_type(node) == CMARK_NODE_HEADING,
                   let child = cmark_node_first_child(node), let literal = cmark_node_get_literal(child) {
                    headings.append(String(cString: literal))
                }
                var child = cmark_node_first_child(node)
                while let item = child { visit(item); child = cmark_node_next(item) }
            }
            visit(root)
            return (blocks, headings, inline.map(\.text))
        }
    }

    func testClosedBlockIsOpaqueAndUnclosedRemainsMarkdown() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = ["$$", "# fake", "[id]: https://example.invalid", "$$", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertEqual(result.blocks.count, 1)
            XCTAssertTrue(result.blocks[0].contains("# fake"))
            XCTAssertEqual(result.headings, ["real"])
            let unclosed = try XCTUnwrap(Self.inspect(["$$", "", "# real"].joined(separator: newline)))
            XCTAssertTrue(unclosed.blocks.isEmpty)
            XCTAssertEqual(unclosed.headings, ["real"])
        }
    }

    func testClosedQuotedMathKeepsTeXAndStopsAtContainerBoundary() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for prefix in ["> ", "> > "] {
                let source = [prefix + "$$", prefix + "# fake", prefix + "```", prefix + "$$", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["# fake\n```\n"])
                XCTAssertEqual(result.headings, ["real"])
            }
            let source = ["> $$", "> # first", "", "> $$", "> # second"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertTrue(result.blocks.isEmpty)
            XCTAssertEqual(result.headings, ["first", "second"])
        }
    }

    func testQuotedMathAllowsMixedQuoteSpacing() throws {
        for newline in ["\n", "\r\n"] {
            let source = [">$$", "> 中文", ">$$", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertEqual(result.blocks, ["中文\n"])
            XCTAssertEqual(result.headings, ["real"])
            let nested = [">>$$", "> > x", ">>$$"].joined(separator: newline)
            XCTAssertEqual(try XCTUnwrap(Self.inspect(nested)).blocks, ["x\n"])
        }
    }

    func testQuotedMathSourceRangeAndSemanticTextRemainDistinct() throws {
        let source = "😀\r\n\r\n> $$\r\n> 中文😀\r\n> $$\r\n\r\n# real"
        let parsed: (NSRange, String)? = MarkdownMathExtension.withDocument(source) { root, ext, _ in
            let mapping = MarkdownPresentationParser.Source(source)
            func find(_ node: OpaquePointer) -> (NSRange, String)? {
                if cmark_node_get_syntax_extension(node) == ext, let range = mapping.range(node),
                   let literal = cmark_node_get_literal(node) { return (range, String(cString: literal)) }
                var child = cmark_node_first_child(node)
                while let current = child {
                    if let result = find(current) { return result }
                    child = cmark_node_next(current)
                }
                return nil
            }
            return find(root)
        } ?? nil
        let result = try XCTUnwrap(parsed)
        XCTAssertEqual((source as NSString).substring(with: result.0), "$$\r\n> 中文😀\r\n> $$")
        XCTAssertEqual(result.1, "中文😀\n")
    }

    func testListMathClosingStaysInsideItem() throws {
        for newline in ["\n", "\r\n"] {
            for (marker, indent) in [("- ", "  "), ("+ ", "  "), ("* ", "  "), ("12. ", "    "), ("3) ", "   ")] {
                let source = [marker + "$$", indent + "# fake", indent + "```", indent + "$$", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["# fake\n```\n"])
                XCTAssertEqual(result.headings, ["real"])
            }
            let unclosed = ["- $$", "  # first", "- next", "", "$$", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(unclosed))
            XCTAssertTrue(result.blocks.isEmpty)
            XCTAssertEqual(result.headings, ["first", "real"])
        }
    }

    func testNestedListMathKeepsSiblingAndCRLF() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["- parent", "  - $$", "    中文😀", "    $$", "- sibling", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertEqual(result.blocks, ["中文😀\n"])
            XCTAssertEqual(result.headings, ["real"])
            let parsed = MarkdownPresentationParser.parse(source)
            let formula = try XCTUnwrap(parsed.formulas.first)
            XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + "    中文😀" + newline + "    $$")
        }
    }

    func testQuoteListMathStaysInConfirmedContainer() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["> - $$", ">   中文😀", ">   $$", "> - sibling", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertEqual(result.blocks, ["中文😀\n"])
            XCTAssertEqual(result.headings, ["real"])
            let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
            XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + ">   中文😀" + newline + ">   $$")
            let unclosed = ["> - $$", ">   text", "", "  $$", "", "# real"].joined(separator: newline)
            XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
        }
    }

    func testTaskListMathUsesConfirmedCheckboxAndBlockIndent() throws {
        for newline in ["\n", "\r\n"] {
            for marker in ["[ ]", "[x]", "[X]"] {
                let source = ["- \(marker) $$", "  中文😀", "  $$", "- sibling"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"], source)
                let parsed = MarkdownPresentationParser.parse(source)
                let formula = try XCTUnwrap(parsed.formulas.first, source)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + "  中文😀" + newline + "  $$")
                let checkbox = try XCTUnwrap(parsed.taskCheckboxes.first, source)
                XCTAssertEqual(checkbox.state != 32, marker != "[ ]")
            }
            for opening in ["- [z] $$", "- [x]  $$", "- [x]\t$$"] {
                let source = [opening, "  x", "  $$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(source)).blocks.isEmpty, source)
            }
            for marker in ["[ ]", "[x]", "[X]"] {
                let quoted = ["> - \(marker) $$", ">   中文😀", ">   $$"].joined(separator: newline)
                XCTAssertEqual(try XCTUnwrap(Self.inspect(quoted)).blocks, ["中文😀\n"], quoted)
                let parsed = MarkdownPresentationParser.parse(quoted)
                let formula = try XCTUnwrap(parsed.formulas.first, quoted)
                XCTAssertEqual((quoted as NSString).substring(with: formula.range), "$$" + newline + ">   中文😀" + newline + ">   $$")
                let checkbox = try XCTUnwrap(parsed.taskCheckboxes.first, quoted)
                XCTAssertEqual(checkbox.state != 32, marker != "[ ]")
            }
            for opening in ["> - [z] $$", "> - [x]  $$", "> - [x]\t$$"] {
                let quoted = [opening, ">   x", ">   $$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(quoted)).blocks.isEmpty, quoted)
            }
        }
    }

    func testListMathPreservesBlankLinesWithoutCrossingQuote() throws {
        for newline in ["\n", "\r\n"] {
            let plain = ["- $$", "  x", "", "", "  y", "  $$", "", "# real"].joined(separator: newline)
            let first = try XCTUnwrap(Self.inspect(plain))
            XCTAssertEqual(first.blocks, ["x\n\n\ny\n"])
            XCTAssertEqual(first.headings, ["real"])
            let quoted = ["> - $$", ">   x", ">", ">   y", ">   $$", "", "# real"].joined(separator: newline)
            let second = try XCTUnwrap(Self.inspect(quoted))
            XCTAssertEqual(second.blocks, ["x\n\ny\n"])
            XCTAssertEqual(second.headings, ["real"])
            let exited = ["> - $$", ">   x", "", ">   $$", "", "# real"].joined(separator: newline)
            XCTAssertTrue(try XCTUnwrap(Self.inspect(exited)).blocks.isEmpty)
        }
    }

    func testListMathUsesOneToFourSpacesAfterMarker() throws {
        for newline in ["\n", "\r\n"] {
            for count in 1...4 {
                let gap = String(repeating: " ", count: count)
                let indent = String(repeating: " ", count: count + 1)
                let source = ["-" + gap + "$$", indent + "x", indent + "$$", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["x\n"])
                XCTAssertEqual(result.headings, ["real"])
            }
            let code = ["-     $$", "      x", "      $$", "", "# real"].joined(separator: newline)
            XCTAssertTrue(try XCTUnwrap(Self.inspect(code)).blocks.isEmpty)
        }
    }

    func testTabIndentedListMathHasExactUTF16Range() throws {
        for newline in ["\n", "\r\n"] {
            for marker in ["-\t", "- \t", "1.\t", "12.\t", "1. \t"] {
                for indent in ["\t", "    "] {
                    let source = [marker + "$$", indent + "中文😀", indent + "$$", "- sibling", "", "# real"].joined(separator: newline)
                    let result = try XCTUnwrap(Self.inspect(source))
                    XCTAssertEqual(result.blocks, ["中文😀\n"])
                    XCTAssertEqual(result.headings, ["real"])
                    let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                    XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                    let unclosed = [marker + "$$", indent + "x", "- sibling", indent + "$$", "", "# real"].joined(separator: newline)
                    XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
                }
            }
            let code = ["1.  \t$$", "    x", "    $$", "", "# real"].joined(separator: newline)
            XCTAssertTrue(try XCTUnwrap(Self.inspect(code)).blocks.isEmpty)
        }
    }

    func testQuotedTabListMathKeepsContainerAndRange() throws {
        for newline in ["\n", "\r\n"] {
            for indent in [">   ", "> \t", ">\t"] {
                let source = ["> -\t$$", indent + "中文😀", indent + "$$", "> - sibling", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = ["> -\t$$", indent + "x", "> - sibling", indent + "$$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testQuotedSpaceListMathAllowsTabContinuationAtSameColumn() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["> - $$", ">\t中文😀", ">\t$$", "> - sibling", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertEqual(result.blocks, ["中文😀\n"])
            XCTAssertEqual(result.headings, ["real"])
            let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
            XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + ">\t中文😀" + newline + ">\t$$")
        }
    }

    func testPartiallyConsumedTabPreservesCmarkTeX() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["- $$", "\t中文😀", "\t$$", "- sibling", "", "# real"].joined(separator: newline)
            let result = try XCTUnwrap(Self.inspect(source))
            XCTAssertEqual(result.blocks, ["  中文😀\n"])
            XCTAssertEqual(result.headings, ["real"])
            let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
            XCTAssertEqual(formula.source, "  中文😀\n")
            XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + "\t中文😀" + newline + "\t$$")
            let unclosed = ["- $$", "\tx", "- sibling", "\t$$"].joined(separator: newline)
            XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
        }
    }

    func testQuotedOrderedTabMathUsesAbsoluteTabStops() throws {
        for newline in ["\n", "\r\n"] {
            for indent in [">       ", "> \t\t", ">     \t"] {
                let source = ["> 1.\t$$", indent + "中文😀", indent + "$$", "> 2. sibling", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = ["> 1.\t$$", indent + "x", "> 2. sibling", indent + "$$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testNestedQuotedListTabMathKeepsContainer() throws {
        for newline in ["\n", "\r\n"] {
            for (before, marker, indent, sibling) in [
                ("", "> > -\t", "> >     ", "> > - sibling"),
                ("> - parent", ">   -\t", ">       ", ">   - sibling")
            ] {
                let lines = (before.isEmpty ? [] : [before]) + [marker + "$$", indent + "中文😀", indent + "$$", sibling, "", "# real"]
                let source = lines.joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = ((before.isEmpty ? [] : [before]) + [marker + "$$", indent + "x", sibling, indent + "$$"]).joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testNestedTabListMathStopsAtSibling() throws {
        for newline in ["\n", "\r\n"] {
            for indent in ["\t", "    "] {
                let source = ["- parent", "  -\t$$", indent + "中文😀", indent + "$$", "  - sibling", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = ["- parent", "  -\t$$", indent + "x", "  - sibling", indent + "$$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testDeepNestedTabListMathUsesTabStops() throws {
        for newline in ["\n", "\r\n"] {
            for indent in ["        ", "\t\t", "    \t", "\t    "] {
                let source = ["- parent", "    -\t$$", indent + "中文😀", indent + "$$", "    - sibling", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = ["- parent", "    -\t$$", indent + "x", "    - sibling", indent + "$$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testTabBeforeNestedListMarkerKeepsSourceAndSibling() throws {
        for newline in ["\n", "\r\n"] {
            for (marker, indent) in [("\t- ", "\t  "), ("\t-\t", "\t\t")] {
                let source = ["- parent", marker + "$$", indent + "中文😀", indent + "$$", "\t- sibling", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = ["- parent", marker + "$$", indent + "x", "\t- sibling", indent + "$$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testTabAfterQuoteBeforeListMarkerUsesSameColumnCalculation() throws {
        for newline in ["\n", "\r\n"] {
            for (marker, indent) in [(">\t- ", ">\t  "), (">\t-\t", ">\t\t")] {
                let source = [marker + "$$", indent + "中文😀", indent + "$$", ">\t- sibling", "", "# real"].joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
                let unclosed = [marker + "$$", indent + "x", ">\t- sibling", indent + "$$"].joined(separator: newline)
                XCTAssertTrue(try XCTUnwrap(Self.inspect(unclosed)).blocks.isEmpty)
            }
        }
    }

    func testIndentedQuoteMathKeepsCmarkStructure() throws {
        for newline in ["\n", "\r\n"] {
            for (marker, indent, sibling) in [("  > ", "  > ", ""), ("  > -\t", "  >     ", "  > - sibling")] {
                let lines = [marker + "$$", indent + "中文😀", indent + "$$"] + (sibling.isEmpty ? [] : [sibling]) + ["", "# real"]
                let source = lines.joined(separator: newline)
                let result = try XCTUnwrap(Self.inspect(source))
                XCTAssertEqual(result.blocks, ["中文😀\n"])
                XCTAssertEqual(result.headings, ["real"])
                let formula = try XCTUnwrap(MarkdownPresentationParser.parse(source).formulas.first)
                XCTAssertEqual((source as NSString).substring(with: formula.range), "$$" + newline + indent + "中文😀" + newline + indent + "$$")
            }
        }
    }

    func testFenceInsideClosedMathDoesNotHideFollowingHeading() throws {
        let result = try XCTUnwrap(Self.inspect("$$\n```\n$$\n\n# real"))
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.headings, ["real"])
    }

    func testFenceAfterClosedMathKeepsItsNormalMeaning() throws {
        let result = try XCTUnwrap(Self.inspect("$$\n```\n$$\n\n```text\ncode\n```\n\n# real"))
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.headings, ["real"])
    }

    func testUnclosedMathDoesNotConsumeFenceOrLaterHeading() throws {
        let source = "$$\n\n# real\n\n```text\ncode\n```\n\n# later"
        let result = try XCTUnwrap(Self.inspect(source))
        XCTAssertTrue(result.blocks.isEmpty)
        XCTAssertEqual(result.headings, ["real", "later"])
    }

    func testInlineCmarkPositionsAndCodeExclusions() throws {
        let source = "😀 $x$ `code $bad$` \\$z$\n\n> 中文 $q$\n\n| A |\n|---|\n| a\\|b $c$ |"
        let found = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { _, _, matches in
            matches.map { (line: $0.line, column: $0.column, text: $0.text) }
        })
        XCTAssertEqual(found.map(\.text), ["x", "q", "c"])
        XCTAssertEqual(found.map(\.line), [1, 3, 7])
        XCTAssertEqual(found.map(\.column), [6, 10, 7])
    }

    func testClosingDelimiterRejectsImmediatelyPrecedingBackslash() throws {
        for count in 1...4 {
            let slashes = String(repeating: "\\", count: count)
            let source = "中 $a" + slashes + "$ tail"
            let matches = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { _, _, items in
                items.map { (column: $0.column, text: $0.text) }
            })
            XCTAssertTrue(matches.isEmpty)
        }
    }

    func testCurrenciesAndUnpairedDelimitersStayText() throws {
        let result = try XCTUnwrap(Self.inspect("Price $2 and $5; $ x $; $x$5; plain $; $$x$"))
        XCTAssertTrue(result.inline.isEmpty)
    }

    func testTwoParsersDoNotShareContext() async throws {
        async let first = Task.detached { Self.inspect("$$\n# fake\n$$\n\n# one\n\n$a$") }.value
        async let second = Task.detached { Self.inspect("$$\n\n# two\n\n$b$") }.value
        let firstResult = await first
        let secondResult = await second
        let one = try XCTUnwrap(firstResult)
        let two = try XCTUnwrap(secondResult)
        XCTAssertEqual(one.headings, ["one"])
        XCTAssertEqual(one.inline, ["a"])
        XCTAssertEqual(two.headings, ["two"])
        XCTAssertEqual(two.inline, ["b"])
    }
}

import Foundation
import cmark_gfm
import XCTest
@testable import LacEditor

final class MarkdownPresentationParserTests: XCTestCase {
    func testTwitterWidgetRequiresConfirmedSource() throws {
        let widget = "<blockquote class='twitter-tweet'><p>Sunsets 中文</p><a href='https://x.com/Interior/status/463440424141459456'>Post</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>"
        let source = widget + "\n\nafter", raw = source as NSString
        let frame = try XCTUnwrap(MarkdownPresentationParser.parse(source).iframeBlocks.first)
        XCTAssertEqual(raw.substring(with: frame.range), widget)
        XCTAssertTrue(frame.html.contains("platform.twitter.com/embed/Tweet.html?id=463440424141459456&amp;dnt=true"))
        XCTAssertTrue(frame.html.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(frame.html.contains("widgets.js"))
        for invalid in [widget.replacingOccurrences(of: "widgets.js", with: "other.js"),
                        widget.replacingOccurrences(of: "<script async", with: "<script onclick='x()' async"),
                        "<template>" + widget + "</template>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(invalid).iframeBlocks.isEmpty, invalid)
        }
    }

    func testStandaloneSVGUsesConfirmedImageRange() throws {
        let one = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let multi = "<svg width='40' height='20'>\r\n<rect width='40' height='20' fill='red'/>\r\n</svg>"
        for svg in [one, multi] {
            let source = svg + "\n\nend"
            let image = try XCTUnwrap(MarkdownPresentationParser.parse(source).images.first)
            XCTAssertEqual((source as NSString).substring(with: image.range), svg)
            XCTAssertTrue(image.url.hasPrefix("data:image/svg+xml;base64,"))
            XCTAssertFalse(image.isInline)
        }
        let quoted = "> <svg width='40' height='20'>\r\n> <rect width='40' height='20' fill='red'/>\r\n> </svg>"
        XCTAssertEqual(MarkdownPresentationParser.parse(quoted).images.count, 1)
        for source in ["`" + one + "`", "<script>" + one + "</script>",
                       "<template>" + one + "</template>", "<select>" + one + "</select>",
                       "<svg width='40' height='20'><rect fill='currentColor'/></svg>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).images.isEmpty, source)
        }
    }

    func testInlineSVGKeepsNeighboringTextAndExactRanges() throws {
        let svg = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let source = "前😀 " + svg + " middle " + svg + " after\r\n\r\nend"
        let raw = source as NSString
        let images = MarkdownPresentationParser.parse(source).images
        XCTAssertEqual(images.count, 2)
        for image in images {
            XCTAssertTrue(image.isInline)
            XCTAssertEqual(raw.substring(with: image.range), svg)
            XCTAssertEqual(raw.substring(with: image.paragraphRange), "前😀 " + svg + " middle " + svg + " after")
        }
        XCTAssertLessThan(NSMaxRange(images[0].range), images[1].range.location)
    }

    func testRubyRequiresExactSourceAndDOM() throws {
        let source = "before <ruby>漢&amp;😀<rp>(</rp><rt>かん</rt><rp>)</rp></ruby> after" as NSString
        let result = MarkdownPresentationParser.parse(source as String)
        let ruby = try XCTUnwrap(result.ruby.first)
        XCTAssertEqual(result.ruby.count, 1)
        XCTAssertEqual(ruby.base, "漢&😀")
        XCTAssertEqual(ruby.reading, "かん")
        XCTAssertEqual(source.substring(with: ruby.baseRange), "漢&amp;😀")
        XCTAssertEqual(source.substring(with: ruby.readingRange), "かん")
        XCTAssertEqual(source.substring(with: ruby.range), "<ruby>漢&amp;😀<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>")
        for invalid in ["<ruby class='x'>漢<rt>kan</rt></ruby>", "<ruby>漢<rt>kan</ruby></rt>",
                        "<ruby>==漢==<rt>kan</rt></ruby>",
                        "<ruby>漢<rt>^kan^</rt></ruby>", "<script><ruby>漢<rt>kan</rt></ruby></script>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(invalid).ruby.isEmpty, invalid)
        }
        let unsupported = "before <ruby>==漢==<rt>kan</rt></ruby> after"
        let blocked = MarkdownPresentationParser.parse(unsupported)
        XCTAssertFalse(blocked.spans.contains { if case .highlight = $0.kind { return true }; return false })
    }

    func testSpacedRubyKeepsSourceRanges() throws {
        let source = "<ruby> 漢 <rt> ㄏㄢˋ </rt> </ruby>" as NSString
        let ruby = try XCTUnwrap(MarkdownPresentationParser.parse(source as String).ruby.first)
        XCTAssertEqual(source.substring(with: ruby.range), source as String)
        XCTAssertEqual(ruby.base, " 漢 ")
        XCTAssertEqual(ruby.reading, " ㄏㄢˋ ")
        XCTAssertEqual(MarkdownHTMLMediaService.rubyDisplayText(ruby.base), "漢")
        XCTAssertEqual(MarkdownHTMLMediaService.rubyDisplayText(ruby.reading), "ㄏㄢˋ")
        XCTAssertEqual(MarkdownHTMLMediaService.rubyDisplayText("a \u{301}b"), "a \u{301}b")
        XCTAssertEqual(MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(" \u{301}b", isCancelled: { false }), true)
        XCTAssertNil(MarkdownHTMLMediaService.rubyDisplayText("abc", isCancelled: { true }))
        for value in ["<ruby>漢<rt> </rt></ruby>", "X<ruby> 漢 <rt> kan </rt> </ruby>Y",
                      "<ruby>漢<rt>kan</rt> x</ruby>", "<ruby>\t漢<rt>kan</rt></ruby>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(value).ruby.isEmpty, value)
        }
    }

    func testRichDetailsRequiresConfirmedWholeBlock() throws {
        let source = "<details open><summary><strong>More &amp; 中文</strong></summary><em>Body</em> <a href='https://example.com'>link</a></details>"
        let presentation = MarkdownPresentationParser.parse(source)
        let details = try XCTUnwrap(presentation.detailsBlocks.first)
        XCTAssertEqual(details.range, NSRange(location: 0, length: (source as NSString).length))
        XCTAssertTrue(details.initiallyOpen)
        XCTAssertTrue(details.summaryHTML?.contains("<strong>") == true)
        XCTAssertTrue(details.bodyHTML?.contains("href=") == true)
        XCTAssertTrue(presentation.htmlBlocks.isEmpty)
        for invalid in ["<template>\(source)</template>", "<details><summary>x</summary><table><tr><td>y</td></tr></table></details>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(invalid).detailsBlocks.isEmpty, invalid)
        }
    }

    func testPlainDetailsRequiresConfirmedHTMLContext() throws {
        let source = "<details>\n<summary>More &amp; 中文</summary>\nBody 😀\n</details>\n\nend"
        let result = MarkdownPresentationParser.parse(source)
        let details = try XCTUnwrap(result.detailsBlocks.first)
        XCTAssertEqual(result.detailsBlocks.count, 1)
        XCTAssertEqual(details.summary, "More & 中文")
        XCTAssertEqual(details.body, "Body 😀")
        XCTAssertEqual((source as NSString).substring(with: details.range), "<details>\n<summary>More &amp; 中文</summary>\nBody 😀\n</details>")
        for valid in ["<details open><summary>More</summary>Body</details>",
                      "<details><summary>More</summary><a href='x'>Body</a></details>"] {
            XCTAssertEqual(MarkdownPresentationParser.parse(valid).detailsBlocks.count, 1, valid)
        }
        for invalid in ["<template><details><summary>More</summary>Body</details></template>",
                        "<script><details><summary>More</summary>Body</details></script>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(invalid).detailsBlocks.isEmpty, invalid)
        }
    }

    func testDetailsPresentationSurvivesCopiesAndTableEdit() throws {
        let source = "| A |\n| --- |\n| x |\n\n<details><summary>Title</summary>Body</details>" as NSString
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source as String).tables.first)
        let range = source.range(of: "<details><summary>Title</summary>Body</details>")
        let block = MarkdownDetailsBlock(range: range, summary: "Title", body: "Body")
        let presentation = MarkdownPresentation(spans: [], detailsBlocks: [block], tables: [table])
        XCTAssertEqual(presentation.resolvingHeadingEmoji([:]).detailsBlocks, [block])
        XCTAssertEqual(presentation.numberingHeadings(true).detailsBlocks, [block])
        let edit = source.range(of: "x")
        let updated = presentation.replacingTable(table, oldTable: table.range, edit: edit, replacementLength: 3)
        XCTAssertEqual(updated.detailsBlocks.first?.range, NSRange(location: range.location + 2, length: range.length))
        XCTAssertEqual(updated.detailsBlocks.first?.summary, "Title")
        XCTAssertEqual(updated.detailsBlocks.first?.body, "Body")
    }
    func testLazyParagraphInlineRangesUseRetainedSource() throws {
        for (first, continuation) in [("> ", ""), ("- ", ""), ("> - ", "")] {
            for ending in ["\n", "\r\n"] {
                let source = first + "before <span style='position:fixed'>中文😀" + ending + continuation + "second</span> after"
                let result = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, _, _ -> [String: NSRange] in
                    let mapping = MarkdownPresentationParser.Source(source, root: root), raw = source as NSString
                    var stack = [root], output: [String: NSRange] = [:]
                    while let node = stack.popLast() {
                        if cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH,
                           let ranges = mapping.lazyParagraphInlineRanges(node, text: raw) {
                            for (child, range) in ranges {
                                if let literal = cmark_node_get_literal(child) { output[String(cString: literal)] = range }
                            }
                        }
                        var child = cmark_node_first_child(node)
                        while let item = child { stack.append(item); child = cmark_node_next(item) }
                    }
                    return output
                })
                XCTAssertEqual(result["second"], (source as NSString).range(of: "second"), source)
                XCTAssertEqual(result["</span>"], (source as NSString).range(of: "</span>"), source)
            }
        }
        let transformed = "> - before <span style='position:fixed'>x\na &amp; -- \\*b\\*</span> after"
        let mapped = try XCTUnwrap(MarkdownMathExtension.withDocument(transformed, options: CMARK_OPT_SMART) { root, _, _ -> Bool in
            let source = MarkdownPresentationParser.Source(transformed, root: root), raw = transformed as NSString
            var stack = [root]
            while let node = stack.popLast() {
                if cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH,
                   let ranges = source.lazyParagraphInlineRanges(node, text: raw) {
                    return ranges.values.contains(raw.range(of: "a &amp; -- \\*b\\*"))
                }
                var child = cmark_node_first_child(node)
                while let item = child { stack.append(item); child = cmark_node_next(item) }
            }
            return false
        })
        XCTAssertTrue(mapped)
    }
    func testTableCellSourceRangeConfirmsPhysicalSeparators() throws {
        for prefixes in [["", "", ""], ["> ", "> ", "> "], ["- ", "  ", "  "]] {
            for ending in ["\n", "\r\n"] {
                for outsidePipes in [false, true] {
                    let lines = outsidePipes
                        ? ["| A | B |", "| --- | --- |", "| 中文\\|😀 | neighbor |"]
                        : ["A | B", "--- | ---", "中文\\|😀 | neighbor"]
                    let source = zip(prefixes, lines).map { $0.0 + $0.1 }.joined(separator: ending)
                    let ranges = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, _, _ -> [NSRange] in
                        let mapping = MarkdownPresentationParser.Source(source, root: root), raw = source as NSString
                        var stack = [root], result: [NSRange] = []
                        while let node = stack.popLast() {
                            if cmark_node_get_type_string(node).map({ String(cString: $0) }) == "table_cell",
                               cmark_node_get_start_line(node) == 3,
                               let range = mapping.tableRowCellSourceRanges(node, text: raw)?[node] { result.append(range) }
                            var child = cmark_node_first_child(node), children: [OpaquePointer] = []
                            while let item = child { children.append(item); child = cmark_node_next(item) }
                            stack.append(contentsOf: children.reversed())
                        }
                        return result
                    })
                    XCTAssertEqual(ranges.count, 2, source)
                    guard ranges.count == 2 else { continue }
                    let raw = source as NSString
                    XCTAssertEqual(raw.substring(with: ranges[0]).trimmingCharacters(in: .whitespaces), "中文\\|😀")
                    XCTAssertEqual(raw.substring(with: ranges[1]).trimmingCharacters(in: .whitespaces), "neighbor")
                }
            }
        }
    }
    func testTableKeyboardUsesConfirmedMappedHTMLPairs() throws {
        let source = "| A | B |\n|---|---|\n| plain | **<kbd>中文\\|😀</kbd>** |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.last)
        let keyboard = try XCTUnwrap(cell.displayRuns.first { $0.kind == .keyboard })
        let display = try XCTUnwrap(cell.displayText) as NSString
        XCTAssertEqual(display.substring(with: keyboard.range), "中文|😀")
        XCTAssertTrue(cell.displayRuns.contains { $0.kind == .strong && NSIntersectionRange($0.range, keyboard.range) == keyboard.range })
        for unsafe in ["<kbd onclick='x'>key</kbd>", "<kbd>key", "<script><kbd>key</kbd></script>"] {
            let text = "| A |\n|---|\n| " + unsafe + " |"
            let result = try XCTUnwrap(MarkdownPresentationParser.parse(text).tables.first?.rows.last?.cells.first)
            XCTAssertFalse(result.displayRuns.contains { $0.kind == .keyboard }, unsafe)
        }
    }

    func testEditingTextReplacementsUseConfirmedTextAndSourceRanges() throws {
        let source = "中文 😀 \"hi\" -- ...  x\n\n`code --  x` [label](https://example.com/--%20x)\n\n<script>--  x</script>"
        let raw = source as NSString
        let syntax = MarkdownSyntaxOptions(smartPunctuation: true, preserveEditingWhitespace: false)
        let parsed = MarkdownPresentationParser.parse(source, syntax: syntax)
        let replacements = parsed.textReplacements
        XCTAssertTrue(replacements.contains { $0.kind == .smart && raw.substring(with: $0.range) == "--" && $0.text == "–" })
        XCTAssertTrue(replacements.contains { $0.kind == .smart && raw.substring(with: $0.range) == "..." && $0.text == "…" })
        XCTAssertEqual(replacements.filter { $0.kind == .spaces }.map { raw.substring(with: $0.range) }, ["  "])
        XCTAssertFalse(replacements.contains { NSIntersectionRange($0.range, raw.range(of: "`code --  x`")).length > 0 })
        XCTAssertFalse(replacements.contains { NSIntersectionRange($0.range, raw.range(of: "https://example.com/--%20x")).length > 0 })
        XCTAssertTrue(MarkdownPresentationParser.parse(source, syntax: .init(smartPunctuation: false, preserveEditingWhitespace: true)).textReplacements.isEmpty)
        XCTAssertTrue(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .smart })
        XCTAssertTrue(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .spaces })
        let combined = "a  \u{301}b"
        let item = try XCTUnwrap(MarkdownPresentationParser.parse(combined, syntax: syntax).textReplacements.first { $0.kind == .spaces })
        XCTAssertTrue(item.text.utf16.elementsEqual(" \u{301}".utf16))
        XCTAssertTrue((combined as NSString).substring(with: item.range).utf16.elementsEqual("  \u{301}".utf16))
        let accentedDash = "a --\u{301} b"
        let dash = try XCTUnwrap(MarkdownPresentationParser.parse(accentedDash, syntax: syntax).textReplacements.first { $0.kind == .smart })
        XCTAssertTrue(dash.text.utf16.elementsEqual("–\u{301}".utf16))
        XCTAssertTrue((accentedDash as NSString).substring(with: dash.range).utf16.elementsEqual("--\u{301}".utf16))
    }

    func testEditingSoftBreakReplacementUsesConfirmedContainerPrefix() throws {
        for newline in ["\n", "\r", "\r\n"] {
            for prefix in ["", "> ", "- "] {
                let continuation = prefix == "- " ? "  " : prefix
                let source = prefix + "one" + newline + continuation + "two"
                let syntax = MarkdownSyntaxOptions(preserveEditingSoftBreaks: false)
                let replacement = try XCTUnwrap(MarkdownPresentationParser.parse(source, syntax: syntax).textReplacements.first { $0.kind == .softBreak }, source)
                XCTAssertEqual((source as NSString).substring(with: replacement.range), newline + continuation)
                XCTAssertEqual(replacement.text, " ")
                XCTAssertTrue(MarkdownPresentationParser.parse(source).textReplacements.isEmpty)
            }
            let hard = "one  " + newline + "two"
            XCTAssertFalse(MarkdownPresentationParser.parse(hard, syntax: .init(preserveEditingSoftBreaks: false)).textReplacements.contains { $0.kind == .softBreak })
            let styled = "> **one**" + newline + "> *two*"
            let styledBreak = try XCTUnwrap(MarkdownPresentationParser.parse(styled, syntax: .init(preserveEditingSoftBreaks: false)).textReplacements.first { $0.kind == .softBreak })
            XCTAssertEqual((styled as NSString).substring(with: styledBreak.range), newline + "> ")
        }
        let many = Array(repeating: "**one**", count: 80).joined(separator: "\n")
        let parsed = MarkdownPresentationParser.parse(many, syntax: .init(preserveEditingSoftBreaks: false))
        XCTAssertEqual(parsed.textReplacements.filter { $0.kind == .softBreak }.count, 79)
        for source in ["before ![image](a.png)\nafter", "> $x$\r\n> ![image](a.png)", "![a](a.png)\n![b](b.png)"] {
            let result = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false))
            let replacement = try XCTUnwrap(result.textReplacements.first { $0.kind == .softBreak }, source)
            let raw = source as NSString
            XCTAssertTrue(raw.substring(with: replacement.range).contains("\n"), source)
            XCTAssertTrue((result.images.map(\.range) + result.inlineFormulas.map(\.range)).allSatisfy {
                NSIntersectionRange($0, replacement.range).length == 0
            })
        }
        for source in ["<strong>one</strong>\ntwo", "one\n<em>two</em>", "<strong><em>one</em></strong>\ntwo", "**<em>one</em>**\ntwo", "one<br>\ntwo"] {
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false))
            let replacement = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .softBreak }, source)
            XCTAssertEqual((source as NSString).substring(with: replacement.range), "\n", source)
        }
        let unsafe = "<script>one</script>\ntwo"
        XCTAssertFalse(MarkdownPresentationParser.parse(unsafe, syntax: .init(preserveEditingSoftBreaks: false)).textReplacements.contains { $0.kind == .softBreak })
    }

    func testEditingTextReplacementMapsTabbedUnicodeSource() throws {
        for source in ["中文\t  --  end", ">\t中文 \t-- end", "**one**\t**one**  -- end"] {
            let parsed = MarkdownPresentationParser.parse(source)
            let raw = source as NSString
            let dash = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
            XCTAssertEqual(raw.substring(with: dash.range), "--")
            let tab = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && raw.substring(with: $0.range).contains("\t") }, source)
            XCTAssertEqual(tab.text, " ")
        }
        let ambiguous = "[id]: /url\t\"title\"\n[\n"
        let rejected = try XCTUnwrap(MarkdownMathExtension.withDocument(ambiguous) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), let text = cmark_node_first_child(paragraph) else { return false }
            let source = MarkdownPresentationParser.Source(ambiguous, root: root)
            return source.tabbedTextCandidateRanges(text, byteColumns: [:], scalarColumns: [:]).isEmpty
        })
        XCTAssertTrue(rejected)
        let retainedTab = "[id]: /url\n[\t"
        let directRejected = try XCTUnwrap(MarkdownMathExtension.withDocument(retainedTab) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), let text = cmark_node_first_child(paragraph) else { return false }
            let source = MarkdownPresentationParser.Source(retainedTab, root: root)
            return source.editingTextRange(text) == nil
        })
        XCTAssertTrue(directRejected)
    }

    func testTableEditingWhitespaceUsesSyntaxSnapshot() throws {
        let source = "| H | Other |\n|---|---|\n| 中文  **bold  text**  \\| 😀 | unchanged |"
        let collapsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
        let preserved = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: true))
        let first = try XCTUnwrap(collapsed.tables.first?.rows.last?.cells.first)
        let original = try XCTUnwrap(preserved.tables.first?.rows.last?.cells.first)
        XCTAssertEqual(first.displayText, "中文 bold text | 😀")
        XCTAssertEqual(original.displayText, "中文  bold  text  | 😀")
        XCTAssertTrue(first.displayRuns.contains { $0.kind == .strong })
        XCTAssertEqual(collapsed.tables.first?.rows.last?.cells.last?.displayText, "unchanged")
        XCTAssertEqual((source as NSString).substring(with: first.range), (source as NSString).substring(with: original.range))
    }

    func testInlineSpanUsesConfirmedTypedStylePairs() throws {
        let source = "before <span style='color:red'>red <span style=\"background-color:yellow\">nested</span></span> <span style='font-size:2rem'>large</span>"
        let parsed = MarkdownPresentationParser.parse(source)
        let spans = parsed.spans.compactMap { span -> MarkdownPresentationSpan? in
            if case .inlineStyle = span.kind { return span }
            return nil
        }
        XCTAssertEqual(spans.count, 3)
        XCTAssertTrue(spans.allSatisfy { $0.markerRanges.count == 2 })
        let mixed = "before <span style='position:fixed'>**<span style='color:red'>x</span>**</span> <span style='color:red'>visible</span>"
        let visible = MarkdownPresentationParser.parse(mixed).spans.filter { if case .inlineStyle = $0.kind { return true }; return false }
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.markerRanges.first, (mixed as NSString).range(of: "<span style='color:red'>", options: .backwards))
        let hiddenStrong = (mixed as NSString).range(of: "**<span style='color:red'>x</span>**")
        XCTAssertFalse(MarkdownPresentationParser.parse(mixed).spans.contains { NSIntersectionRange($0.range, hiddenStrong).length > 0 })
        let hiddenResources = "before <span style='position:fixed'>[link](https://example.com) ![image](a.png) --</span> after"
        let hiddenResult = MarkdownPresentationParser.parse(hiddenResources)
        XCTAssertTrue(hiddenResult.links.isEmpty)
        XCTAssertTrue(hiddenResult.images.isEmpty)
        XCTAssertTrue(hiddenResult.textReplacements.isEmpty)
        let crossing = "before <span style='position:fixed'>**<span style='color:red'>x**</span> <span style='color:red'>hidden</span>"
        XCTAssertFalse(MarkdownPresentationParser.parse(crossing).spans.contains { if case .inlineStyle = $0.kind { return true }; return false })
        let noSpan = "before <u>kept</u> and\t<em>also</em>"
        XCTAssertTrue(MarkdownPresentationParser.parse(noSpan).spans.contains { $0.kind == .underline })
        let plain = "before <span>**kept**</span> <span class='note'>**also**</span> and <span style='color:red'>red</span>"
        let plainResult = MarkdownPresentationParser.parse(plain)
        XCTAssertEqual(plainResult.spans.filter { $0.kind == .strong }.count, 2)
        XCTAssertTrue(plainResult.spans.contains { if case .inlineStyle = $0.kind { return true }; return false })
        for source in ["<span style='position:absolute'>bad <strong>x</strong></span>", "<span style='color:red' onclick='x'>bad</span>", "<script><span style='color:red'>bad</span></script>", "<span style='color:red'>unclosed"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).spans.contains { if case .inlineStyle = $0.kind { return true }; return false }, source)
        }
    }

    func testTableSpanUsesConfirmedSourceAndStyleRuns() throws {
        let source = "| H | Other |\n|---|---|\n| <span style='color:red'>**中文\\|😀 <span style='background:yellow'>inner</span>**</span> | unchanged |"
        let parsed = MarkdownPresentationParser.parse(source)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        XCTAssertEqual(cell.displayText, "中文|😀 inner")
        XCTAssertEqual(cell.displayRuns.filter { if case .inlineStyle = $0.kind { return true }; return false }.count, 2)
        XCTAssertTrue(cell.displayRuns.contains { $0.kind == .strong })
        XCTAssertEqual(parsed.tables.first?.rows.last?.cells.last?.displayText, "unchanged")
        let unsafe = "| H |\n|---|\n| <span style='position:fixed'>**hidden**</span> |"
        let rejected = try XCTUnwrap(MarkdownPresentationParser.parse(unsafe).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(rejected.displayText?.contains("<span style='position:fixed'>") == true)
        XCTAssertTrue(rejected.displayRuns.isEmpty)
    }

    func testEditingWhitespaceProvesTopLevelParagraphEdges() throws {
        for newline in ["", "\n", "\r\n", "\r"] {
            for leading in [" ", "  ", "   "] {
                let source = leading + "中文 😀" + "  " + newline
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let edges = parsed.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
                XCTAssertEqual(edges.map { (source as NSString).substring(with: $0.range) }, [leading, "  "], source)
                XCTAssertFalse(MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: true)).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty })
            }
        }
        for source in ["> quote  ", "- item  ", "> - nested  "] {
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
            let edges = parsed.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
            XCTAssertEqual(edges.count, 1, source)
            XCTAssertEqual((source as NSString).substring(with: try XCTUnwrap(edges.first).range), "  ")
        }
        for newline in ["\n", "\r", "\r\n"] {
            for (prefix, continuation) in [("> ", "> "), ("- ", "  "), ("> - ", ">   ")] {
                let source = prefix + "first" + newline + continuation + "中文 second  "
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let edges = parsed.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
                XCTAssertEqual(edges.count, 1, source)
                XCTAssertEqual((source as NSString).substring(with: try XCTUnwrap(edges.first).range), "  ")
            }
            let source = "  first" + newline + "second  " + newline + newline + "end"
            for preserveBreaks in [true, false] {
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: preserveBreaks))
                let edges = parsed.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
                XCTAssertEqual(edges.map { (source as NSString).substring(with: $0.range) }, ["  ", "  "], source)
            }
        }
        for source in ["    code  ", "text\\  ", " a\tb  ", "<em>text</em>  ", "> hard  \n> break"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty }, source)
        }
    }

    func testEditingWhitespaceKeepsStructuralQuoteAndListSpace() throws {
        for marker in [">", "-", "12."] {
            for spaces in 1...4 {
                let source = marker + String(repeating: " ", count: spaces) + "中文 😀"
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let edges = parsed.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
                if spaces == 1 { XCTAssertTrue(edges.isEmpty, source) }
                else {
                    let edge = try XCTUnwrap(edges.first, source)
                    XCTAssertEqual(edge.range.location, (marker as NSString).length + 1)
                    XCTAssertEqual(edge.range.length, spaces - 1)
                }
                XCTAssertFalse(MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: true)).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty })
            }
        }
        for source in ["-\ttext", ">     code", ">   first\n>   second"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty }, source)
        }
        for source in ["> -   中文😀", "- outer\n  -    中文😀", "> 12.   中文😀"] {
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
            let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
            XCTAssertEqual(NSMaxRange(edge.range), (source as NSString).range(of: "中文").location)
            XCTAssertGreaterThan(edge.range.length, 0)
        }
        for source in ["> >    中文😀", ">  >   中文😀", ">>    中文😀"] {
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
            let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
            let marker = (source as NSString).range(of: ">", options: .backwards)
            XCTAssertEqual(edge.range.location, NSMaxRange(marker) + 1)
            XCTAssertEqual(NSMaxRange(edge.range), (source as NSString).range(of: "中文").location)
        }
        XCTAssertFalse(MarkdownPresentationParser.parse("> >     code").textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty })
        for checked in [" ", "x"] {
            for spaces in 1...4 {
                let source = "- [\(checked)]" + String(repeating: " ", count: spaces) + "中文😀"
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let checkbox = try XCTUnwrap(parsed.taskCheckboxes.first)
                let edges = parsed.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
                if spaces == 1 { XCTAssertTrue(edges.isEmpty, source) }
                else {
                    let edge = try XCTUnwrap(edges.first, source)
                    XCTAssertEqual(edge.range.location, NSMaxRange(checkbox.markerRange) + 1)
                    XCTAssertEqual(edge.range.length, spaces - 1)
                }
            }
            for newline in ["\n", "\r\n"] {
                let source = "- outer" + newline + "  - [\(checked)]    中文😀"
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let checkbox = try XCTUnwrap(parsed.taskCheckboxes.first)
                let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
                XCTAssertEqual(edge.range.location, NSMaxRange(checkbox.markerRange) + 1)
                XCTAssertEqual(edge.range.length, 3)
            }
        }
        for source in ["- [x]     text", "> - [x]   quoted", "- [ ]\ttext", "- [x] task\n  -    中文"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty }, source)
        }
    }

    func testEditingWhitespaceProvesTrailingTabs() throws {
        for prefix in ["", "> ", "- ", "- [x] "] {
            for suffix in ["\t", " \t\t", "\t \t"] {
                let source = prefix + "中文😀" + suffix + "\r\n"
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
                XCTAssertEqual((source as NSString).substring(with: edge.range), suffix)
            }
        }
        for source in ["a\tb\t", "abc\\ \t", ">\ttext\t", "    code\t"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty }, source)
        }
    }

    func testEditingWhitespaceProvesWholeLeadingTabs() throws {
        for marker in [">", "-", "- [x]"] {
            for suffix in [" \t", "  \t"] {
                let source = marker + suffix + "中文😀\r\n"
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
                let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
                XCTAssertEqual(edge.range.location, (marker as NSString).length + 1)
                XCTAssertEqual((source as NSString).substring(with: edge.range), String(suffix.dropFirst()))
            }
        }
        for source in [">  - \t中文😀", ">> \t中文😀", "- outer\r\n    - \t中文😀", "- outer\r\n  - [x] \t中文😀"] {
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
            let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
            XCTAssertEqual((source as NSString).substring(with: edge.range), "\t")
        }
        for source in [">\ttext", "-\ttext", "- [x]\ttext", "> - \ttext", "> > \ttext", "> \tfirst\n> second", "> \ttext\tbody", "- [x] outer\n  - \ttext"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).textReplacements.contains { $0.kind == .spaces && $0.text.isEmpty }, source)
        }
    }

    func testPlainMultilineEditingUsesRetainedSourceMapping() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "中文 first" + newline + "   second --  end"
            let raw = source as NSString
            for preserveBreaks in [true, false] {
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: preserveBreaks))
                let smart = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
                XCTAssertEqual(raw.substring(with: smart.range), "--")
                let kind: MarkdownTextReplacement.Kind = preserveBreaks ? .spaces : .softBreak
                let mapped = try XCTUnwrap(parsed.textReplacements.first { $0.kind == kind && raw.substring(with: $0.range).contains("   ") }, source)
                XCTAssertEqual(raw.substring(with: mapped.range), preserveBreaks ? "   " : newline + "   ")
            }
        }
        for source in ["first  \n   second --"] {
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
            XCTAssertFalse(parsed.textReplacements.contains { $0.kind == .softBreak }, source)
        }
    }

    func testMultilineEditingMapsSingleLineInlineStyles() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "> first" + newline + ">   **中文 --** [link](https://example.com) `code`"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
            let smart = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
            XCTAssertEqual(raw.substring(with: smart.range), "--")
            let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong }, source)
            XCTAssertEqual(raw.substring(with: strong.range), "**中文 --**")
            let link = try XCTUnwrap(parsed.links.first, source)
            XCTAssertEqual(raw.substring(with: link.range), "[link](https://example.com)")
            let code = try XCTUnwrap(parsed.spans.first { $0.kind == .code }, source)
            XCTAssertEqual(raw.substring(with: code.range), "`code`")
            let soft = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .softBreak }, source)
            XCTAssertEqual(raw.substring(with: soft.range), newline + ">   ")
        }
        let source = "[link](https://example.com)" as NSString
        let rejected = try XCTUnwrap(MarkdownMathExtension.withDocument(source as String) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), let link = cmark_node_first_child(paragraph) else { return false }
            let mapping = MarkdownPresentationParser.Source(source as String, root: root)
            return mapping.linkMarkers(NSRange(location: 0, length: source.length), node: link,
                mappedRange: { _ in NSRange(location: source.length, length: 1) }).isEmpty
        })
        XCTAssertTrue(rejected)
    }

    func testMultilineEditingMapsWrappedSoftBreak() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "> **one" + newline + ">   中文 --** after"
            let raw = source as NSString
            for preserve in [true, false] {
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: preserve))
                let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong }, source)
                XCTAssertEqual(raw.substring(with: strong.range), "**one" + newline + ">   中文 --**")
                XCTAssertEqual(strong.markerRanges.count, 2)
                let smart = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
                XCTAssertEqual(raw.substring(with: smart.range), "--")
                let replacement = try XCTUnwrap(parsed.textReplacements.first { preserve ? ($0.kind == .spaces && $0.text.isEmpty) : $0.kind == .softBreak }, source)
                XCTAssertEqual(raw.substring(with: replacement.range), preserve ? "  " : newline + ">   ")
            }
        }
    }

    func testMultilineEditingMapsOnlyExactMarkdownImages() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "first" + newline + "   ![中文😀](a.png) after"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false))
            let image = try XCTUnwrap(parsed.images.first, source)
            XCTAssertEqual(raw.substring(with: image.range), "![中文😀](a.png)")
            let soft = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .softBreak }, source)
            XCTAssertEqual(raw.substring(with: soft.range), newline + "   ")
        }
        for source in ["first\n   ![alt](a.png \"title\")", "first\n   ![alt][ref]\n\n[ref]: a.png", "first\n   ![a\\*b](a.png)", "first\n   ![a&amp;b](a.png)"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).images.isEmpty, source)
        }
        let repeated = "first\n   ![a](a)"
        let valid = try XCTUnwrap(MarkdownMathExtension.withDocument(repeated) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), let first = cmark_node_first_child(paragraph),
                  let soft = cmark_node_next(first), let image = cmark_node_next(soft),
                  let child = cmark_node_first_child(image) else { return false }
            let mapping = MarkdownPresentationParser.Source(repeated, root: root)
            guard let ranges = mapping.lazyParagraphInlineRanges(paragraph, text: repeated as NSString, plainEditing: true),
                  let imageRange = ranges[image], let childRange = ranges[child] else { return false }
            return childRange == NSRange(location: imageRange.location + 2, length: 1)
        })
        XCTAssertTrue(valid)
    }

    func testMultilineEditingMapsEachInlineMathCallback() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "> first" + newline + ">   中文 $x$ then $x$"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false))
            XCTAssertEqual(parsed.inlineFormulas.count, 2, source)
            let first = raw.range(of: "$x$"), last = raw.range(of: "$x$", options: .backwards)
            XCTAssertEqual(parsed.inlineFormulas.map(\.range), [first, last])
            XCTAssertNotNil(parsed.textReplacements.first { $0.kind == .softBreak }, source)
        }
        let disabled = MarkdownPresentationParser.parse("first\n   $x$", syntax: .init(inlineMath: false))
        XCTAssertTrue(disabled.inlineFormulas.isEmpty)
        let onlyMath = MarkdownPresentationParser.parse("$x$\n   $y$", syntax: .init(preserveEditingSoftBreaks: false))
        XCTAssertEqual(onlyMath.inlineFormulas.count, 2)
        XCTAssertNotNil(onlyMath.textReplacements.first { $0.kind == .softBreak })
        for source in ["first\n   $unfinished", "first\n   $x$\ttext", "first\n   `$x$`"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).inlineFormulas.isEmpty, source)
        }
    }

    func testMultilineEditingMapsConfirmedInlineHTML() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "> first" + newline + ">   **<u>中文</u>** <br> then <u>x</u>"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false))
            let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong }, source)
            XCTAssertEqual(raw.substring(with: strong.range), "**<u>中文</u>**")
            let underlines = parsed.spans.filter { $0.kind == .underline }
            XCTAssertEqual(underlines.count, 2, source)
            XCTAssertEqual(Set(underlines.map { raw.substring(with: $0.range) }), Set(["<u>中文</u>", "<u>x</u>"]))
            let soft = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .softBreak }, source)
            XCTAssertEqual(raw.substring(with: soft.range), newline + ">   ")
        }
        let unsafe = "first\n   <span style='position:fixed'>**hidden**</span> <u>visible</u>"
        let parsed = MarkdownPresentationParser.parse(unsafe)
        XCTAssertFalse(parsed.spans.contains { $0.kind == .strong })
        XCTAssertTrue(parsed.spans.contains { $0.kind == .underline })
    }

    func testMultilineEditingMapsDecorationsWithoutChangingSource() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "first" + newline + "   中文 ==mark== ^sup^ ~sub~"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source)
            for (kind, spelling) in [(MarkdownPresentationKind.highlight, "==mark=="), (.superscriptText, "^sup^"), (.subscriptText, "~sub~")] {
                let span = try XCTUnwrap(parsed.spans.first { $0.kind == kind }, source)
                XCTAssertEqual(raw.substring(with: span.range), spelling)
                XCTAssertEqual(span.markerRanges.count, 2)
            }
        }
        let escaped = "first\n   \\==mark== \\^sup^"
        let parsed = MarkdownPresentationParser.parse(escaped)
        XCTAssertFalse(parsed.spans.contains { $0.kind == .highlight || $0.kind == .superscriptText })
        let equivalent = "==e\u{301}\u{327}==\n\n==e\u{327}\u{301}=="
        let raw = equivalent as NSString
        let rejected = try XCTUnwrap(MarkdownMathExtension.withDocument(equivalent) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), let text = cmark_node_first_child(paragraph) else { return false }
            let source = MarkdownPresentationParser.Source(equivalent, root: root)
            let other = raw.range(of: "==e\u{327}\u{301}==", options: .backwards)
            return MarkdownPresentationParser.highlightRanges(text, source: source, text: raw, mappedRange: other).isEmpty
        })
        XCTAssertTrue(rejected)
    }

    func testContainerMultilineEditingKeepsStructuralPrefix() throws {
        for newline in ["\n", "\r", "\r\n"] {
            for (opening, continuation) in [("> ", "> "), ("- ", "  "), ("> - ", ">   ")] {
                for extra in [1, 3, 5] {
                    let source = opening + "first" + newline + continuation + String(repeating: " ", count: extra) + "中文 --"
                    let raw = source as NSString
                    let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: true))
                    let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty }, source)
                    XCTAssertEqual(raw.substring(with: edge.range), String(repeating: " ", count: extra))
                    let smart = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
                    XCTAssertEqual(raw.substring(with: smart.range), "--")
                    let joined = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
                    let soft = try XCTUnwrap(joined.textReplacements.first { $0.kind == .softBreak }, source)
                    XCTAssertEqual(raw.substring(with: soft.range), newline + continuation + String(repeating: " ", count: extra))
                }
            }
        }
        for source in ["> first\nsecond --", "- first\nsecond --", "> first  \n> second", "> first\n> \tsecond"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false)).textReplacements.contains { $0.kind == .softBreak }, source)
        }
    }

    func testPlainMultilineBodyTabsUseUniqueRetainedRanges() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "first" + newline + "   中文\ttext --"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
            let tab = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && raw.substring(with: $0.range) == "\t" }, source)
            XCTAssertEqual(raw.substring(with: tab.range), "\t")
            let smart = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
            XCTAssertEqual(raw.substring(with: smart.range), "--")
            let soft = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .softBreak }, source)
            XCTAssertEqual(raw.substring(with: soft.range), newline + "   ")
        }
        for source in ["[id]: /url\n[\t"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false)).textReplacements.contains { $0.kind == .softBreak }, source)
        }
        let source = "first\n   a\t&eacute;"
        let rejected = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), let first = cmark_node_first_child(paragraph),
                  let soft = cmark_node_next(first), let textNode = cmark_node_next(soft) else { return false }
            "a\te\u{301}".withCString { _ = cmark_node_set_literal(textNode, $0) }
            let mapping = MarkdownPresentationParser.Source(source, root: root)
            return mapping.lazyParagraphInlineRanges(paragraph, text: source as NSString, plainEditing: true) == nil
        })
        XCTAssertTrue(rejected)
        for (opening, continuation) in [("> ", "> "), ("- ", "  "), ("> - ", ">   "), ("- [x] ", "  ")] {
            let source = opening + "first\r\n" + continuation + "   中文\ttext --"
            let raw = source as NSString
            let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
            let tab = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && raw.substring(with: $0.range) == "\t" }, source)
            XCTAssertEqual(raw.substring(with: tab.range), "\t")
            let smart = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .smart && $0.text == "–" }, source)
            XCTAssertEqual(raw.substring(with: smart.range), "--")
            XCTAssertNotNil(parsed.textReplacements.first { $0.kind == .softBreak }, source)
        }
    }

    func testMultilineBodyTabsKeepStyledRanges() throws {
        for newline in ["\n", "\r", "\r\n"] {
            for (first, continuation) in [("", ""), ("> ", "> "), ("- ", "  ")] {
                for body in ["**中文\ttext**", "*中文\ttext*", "~~中文\ttext~~", "[中文\ttext](https://example.com)"] {
                    let source = first + "before" + newline + continuation + "  " + body + " after"
                    let raw = source as NSString
                    let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
                    XCTAssertTrue(parsed.textReplacements.contains { $0.kind == .spaces && raw.substring(with: $0.range) == "\t" }, source)
                    XCTAssertTrue(parsed.textReplacements.contains { $0.kind == .softBreak }, source)
                }
            }
        }
        let source = "before\n  **same**\t**same**"
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
        XCTAssertTrue(parsed.textReplacements.contains { $0.kind == .softBreak })
        XCTAssertEqual(parsed.spans.filter { if case .strong = $0.kind { return true }; return false }.count, 2)
    }

    func testMultilineBodyTabsKeepConfirmedInlineHTML() {
        for newline in ["\n", "\r", "\r\n"] {
            for (first, continuation) in [("", ""), ("> ", "> "), ("- ", "  ")] {
                for body in ["<strong>中文\ttext</strong>", "<em>中文\ttext</em>", "<kbd>中文\ttext</kbd>", "<a href='https://example.com'>中文\ttext</a>", "中文\t<br>text"] {
                    let source = first + "before" + newline + continuation + "  " + body + " after"
                    let raw = source as NSString
                    let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
                    XCTAssertTrue(parsed.textReplacements.contains { $0.kind == .spaces && raw.substring(with: $0.range) == "\t" }, source)
                    XCTAssertTrue(parsed.textReplacements.contains { $0.kind == .softBreak }, source)
                }
            }
        }
        let unsafe = "before\n  <span style='position:fixed'>中文\ttext</span>"
        let parsed = MarkdownPresentationParser.parse(unsafe, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
        XCTAssertFalse(parsed.textReplacements.contains { $0.kind == .softBreak })
    }

    func testMultilineBodyTabsKeepConfirmedHTMLImages() {
        let image = "<img src='https://example.invalid/a.png' alt='中文' width='40'>"
        for newline in ["\n", "\r", "\r\n"] {
            for (first, continuation) in [("", ""), ("> ", "> "), ("- ", "  ")] {
                let source = first + "before" + newline + continuation + "  😀\t" + image + " and " + image + " after"
                let raw = source as NSString
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false))
                let ranges = parsed.images.map(\.range)
                XCTAssertEqual(ranges.count, 2, source)
                XCTAssertNotEqual(ranges.first, ranges.last)
                XCTAssertTrue(ranges.allSatisfy { raw.substring(with: $0) == image }, source)
                XCTAssertTrue(parsed.textReplacements.contains { $0.kind == .softBreak }, source)
            }
        }
        for body in ["<template>" + image + "</template>", "<script>" + image + "</script>", "<img src='x' onerror='evil()'>"] {
            let source = "before\n  😀\t" + body
            XCTAssertTrue(MarkdownPresentationParser.parse(source).images.isEmpty, source)
        }
    }

    func testPlainMultilineContinuationTabsUseExactRetainedSuffix() throws {
        for newline in ["\n", "\r", "\r\n"] {
            for prefix in ["\t", " \t", "  \t", "   \t", "\t  "] {
                let source = "first" + newline + prefix + "中文😀 --"
                let raw = source as NSString
                for preserve in [true, false] {
                    let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: preserve))
                    let replacement = try XCTUnwrap(parsed.textReplacements.first { preserve ? ($0.kind == .spaces && $0.text.isEmpty) : $0.kind == .softBreak }, source)
                    XCTAssertEqual(raw.substring(with: replacement.range), preserve ? prefix : newline + prefix)
                }
            }
        }
        let source = "first\n\t  text"
        let rejected = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root) else { return false }
            "first\n text\n".withCString { _ = cmark_node_set_string_content(paragraph, $0) }
            let mapping = MarkdownPresentationParser.Source(source, root: root)
            return mapping.lazyParagraphInlineRanges(paragraph, text: source as NSString, plainEditing: true) == nil
        })
        XCTAssertTrue(rejected)
        for (opening, continuation) in [("> ", "> "), ("- ", "  "), ("> - ", ">   "), ("- [x] ", "  ")] {
            let source = opening + "first\r\n" + continuation + "\t中文😀 --"
            let raw = source as NSString
            for preserve in [true, false] {
                let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: preserve))
                let replacement = try XCTUnwrap(parsed.textReplacements.first { preserve ? ($0.kind == .spaces && $0.text.isEmpty) : $0.kind == .softBreak }, source)
                XCTAssertEqual(raw.substring(with: replacement.range), preserve ? "\t" : "\r\n" + continuation + "\t")
            }
        }
        for source in ["> first\n\tsecond", "- first\n\tsecond", "> first\n>\tsecond"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false)).textReplacements.contains { $0.kind == .softBreak }, source)
        }
    }
    func testCompletedTaskRangesIncludeNestedItemsOnlyForCheckedTasks() {
        let source = "- [x] done\n  - [ ] nested\n- [ ] pending\n- [x] last"
        let raw = source as NSString
        let ranges = MarkdownPresentationParser.parse(source).completedTaskRanges
        XCTAssertEqual(ranges.count, 2)
        guard ranges.count == 2 else { return }
        XCTAssertTrue(NSLocationInRange(raw.range(of: "nested").location, ranges[0]))
        XCTAssertFalse(NSLocationInRange(raw.range(of: "pending").location, ranges[0]))
        XCTAssertTrue(NSLocationInRange(raw.range(of: "last").location, ranges[1]))
    }

    func testCompletedTaskRangeSurvivesNestedTableCellEdit() throws {
        let source = "- [x] task\n\n  | A |\n  |---|\n  | one |"
        let parsed = MarkdownPresentationParser.parse(source)
        let table = try XCTUnwrap(parsed.tables.first)
        let original = try XCTUnwrap(parsed.completedTaskRanges.first)
        let edit = (source as NSString).range(of: "one")
        let updated = parsed.replacingTable(table, oldTable: table.range, edit: edit, replacementLength: 5)
        XCTAssertEqual(updated.completedTaskRanges.first?.location, original.location)
        XCTAssertEqual(updated.completedTaskRanges.first?.length, original.length + 2)
    }

    func testInlineImagesKeepConfirmedUTF16RangesInContainers() {
        let text = "😀 before ![one](a.png) after ![two](b.png)\n\n> quote ![q](q.png)\n\n- [ ] ![task](t.png)\n\n`![code](x.png)`"
        let images = MarkdownPresentationParser.parse(text).images
        XCTAssertEqual(images.map(\.url), ["a.png", "b.png", "q.png", "t.png"])
        XCTAssertTrue(images.allSatisfy(\.isInline))
        XCTAssertEqual(images.map { (text as NSString).substring(with: $0.range) },
                       ["![one](a.png)", "![two](b.png)", "![q](q.png)", "![task](t.png)"])
    }

    func testInlineImageInHeadingUsesHeadingRange() throws {
        let text = "# 中文 ![alt](image.png)\n\nend"
        let parsed = MarkdownPresentationParser.parse(text)
        let image = try XCTUnwrap(parsed.images.first)
        let heading = try XCTUnwrap(parsed.headings.first)
        XCTAssertTrue(image.isInline)
        XCTAssertEqual(image.paragraphRange, heading.range)
        XCTAssertEqual((text as NSString).substring(with: image.range), "![alt](image.png)")
    }
    func testTableImageKeepsEscapedPipeAndSourceRange() throws {
        let text = "| 中文 | Picture |\n|---|---|\n| 😀 | ![a\\|b](image.png) |"
        let presentation = MarkdownPresentationParser.parse(text)
        let image = try XCTUnwrap(presentation.images.first)
        XCTAssertEqual(image.url, "image.png")
        XCTAssertEqual((text as NSString).substring(with: image.range), "![a\\|b](image.png)")
        let cell = try XCTUnwrap(presentation.tables.first?.rows.last?.cells.last)
        let run = try XCTUnwrap(cell.displayRuns.first { if case .tableImage = $0.kind { return true }; return false })
        guard case let .tableImage(relative) = run.kind else { return XCTFail("Missing table image") }
        XCTAssertEqual(cell.range.location + relative.location, image.range.location)
        XCTAssertEqual(relative.length, image.range.length)
    }
    func testNamedAnchorsUseConfirmedHTMLSource() {
        let source = "😀 <a id='中文' name='other'></a>\n\n<a id='中文'></a>\n\n`<a id='code'>`\n\n<script><a id='hidden'></script>\n\n<template><a id='inert'></a></template>\n\n<div><a id='block'></a></div>"
        let parsed = MarkdownPresentationParser.parse(source)
        let raw = source as NSString
        XCTAssertEqual(parsed.namedAnchors.map(\.name), ["中文", "other", "中文", "block"])
        XCTAssertEqual(parsed.namedAnchors.map { raw.substring(with: $0.range) },
                       ["<a id='中文' name='other'>", "<a id='中文'>", "<a id='中文'>", "<a id='block'>"])
    }

    func testNamedAnchorsConfirmShiftedHTMLSourceAndAcceptCRLF() {
        let shifted = "[foo]: https://example.com\n<a id='x'></a>\n\n[foo]"
        XCTAssertEqual(MarkdownPresentationParser.parse(shifted).namedAnchors.map(\.name), ["x"])
        let tabbed = "[foo]: https://example.com\n\t<a id='hidden'></a>"
        XCTAssertEqual(MarkdownPresentationParser.parse(tabbed).namedAnchors.map(\.name), ["hidden"])
        let block = "<div>\r\n<a id='中文'></a>\r\n</div>\r\n"
        XCTAssertEqual(MarkdownPresentationParser.parse(block).namedAnchors.map(\.name), ["中文"])
        let noFinalNewline = "<div><a id='end'></a></div>"
        XCTAssertEqual(MarkdownPresentationParser.parse(noFinalNewline).namedAnchors.map(\.name), ["end"])
    }

    func testPlainHeadingTextRangeRequiresExactSource() throws {
        let text = "# Straße e\u{301} 😀\n\nSetext\n======\n\n# **bold**\n\n# a &amp; b\n\n# :smile:"
        let raw = text as NSString
        let headings = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true).headings
        XCTAssertEqual(headings.count, 5)
        let first = try XCTUnwrap(headings[0].plainTextRange)
        XCTAssertEqual(raw.substring(with: first), "Straße e\u{301} 😀")
        let second = try XCTUnwrap(headings[1].plainTextRange)
        XCTAssertEqual(raw.substring(with: second), "Setext")
        XCTAssertNil(headings[2].plainTextRange)
        XCTAssertNil(headings[3].plainTextRange)
        XCTAssertNil(headings[4].plainTextRange)
        XCTAssertNil(MarkdownPresentationParser.parse("# :smile:").headings.first?.plainTextRange)
    }

    func testStrictSetextHeadingKeepsLeadingHashesVisible() throws {
        let parsed = MarkdownPresentationParser.parse("###Header\n---")
        let heading = try XCTUnwrap(parsed.spans.first { if case .heading = $0.kind { return true }; return false })
        XCTAssertTrue(heading.markerRanges.isEmpty)
    }

    func testLooseHeadingKeepsOriginalSourcePositions() throws {
        let text = "###中文😀\r\n"
        XCTAssertTrue(MarkdownPresentationParser.parse(text).headings.isEmpty)
        let parsed = MarkdownPresentationParser.parse(text, syntax: .init(strictMode: false))
        let heading = try XCTUnwrap(parsed.headings.first)
        XCTAssertEqual(heading.title, "中文😀")
        XCTAssertEqual((text as NSString).substring(with: heading.range), "###中文😀")
        let span = try XCTUnwrap(parsed.spans.first { if case .heading = $0.kind { return true }; return false })
        XCTAssertEqual(span.markerRanges, [NSRange(location: 0, length: 3)])
        XCTAssertTrue(MarkdownPresentationParser.parse("###Head\ttail", syntax: .init(strictMode: false)).headings.isEmpty)
    }

    func testLooseListUsesSourceIndentWithoutChangingIt() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "10. 中文😀\(newline)  1. ccc"
            let strict = MarkdownPresentationParser.parse(source)
            XCTAssertEqual(strict.listMarkers.map(\.depth), [1, 1])
            let loose = MarkdownPresentationParser.parse(source, syntax: .init(strictMode: false))
            XCTAssertEqual(loose.listMarkers.map(\.depth), [1, 2])
            XCTAssertEqual(loose.listMarkers.map { (source as NSString).substring(with: $0.range) }, ["10.", "1."])
            XCTAssertEqual(loose.looseIndents.count, 1)
            XCTAssertEqual(loose.looseIndents.first.map { (source as NSString).substring(with: $0.range) }, "  ")
            XCTAssertEqual(loose.looseIndents.first?.replacement, "    ")
            let threeSpaces = "10. aaa\(newline)   1. ccc"
            XCTAssertEqual(MarkdownPresentationParser.parse(threeSpaces, syntax: .init(strictMode: false)).listMarkers.map(\.depth), [1, 2])
            let continuation = "1. aaa\(newline)\(newline)  bbb"
            let parsed = MarkdownPresentationParser.parse(continuation, syntax: .init(strictMode: false))
            XCTAssertEqual(parsed.looseIndents.count, 1)
            XCTAssertEqual(parsed.looseIndents.first?.replacement, "   ")
        }
    }

    func testLooseListParsingCanBeCancelled() {
        let source = String(repeating: "1. aaa\n\n  bbb\n\n", count: 2000)
        var checks = 0
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(strictMode: false), isCancelled: {
            checks += 1
            return checks > 10
        })
        XCTAssertGreaterThan(checks, 10)
        XCTAssertTrue(parsed.listMarkers.isEmpty)
    }

    func testLooseListAfterUnicodeFrontMatterUsesOriginalPositions() {
        let source = "---\r\ntitle: 中文😀\r\n---\r\n\r\n10. aaa\r\n  1. ccc"
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(strictMode: false))
        XCTAssertEqual(parsed.listMarkers.map(\.depth), [1, 2])
        XCTAssertEqual(parsed.listMarkers.map { (source as NSString).substring(with: $0.range) }, ["10.", "1."])
        XCTAssertEqual(parsed.looseIndents.first.map { (source as NSString).substring(with: $0.range) }, "  ")
    }

    func testLooseListBeforeUnconfirmedTaskKeepsRestOfDocument() {
        let source = "1. aaa\n\n  bbb\n\n1. [ ] task\n\n# after"
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(strictMode: false))
        XCTAssertTrue(parsed.looseIndents.isEmpty)
        XCTAssertEqual(parsed.headings.map(\.title), ["after"])
        XCTAssertEqual(parsed.taskCheckboxes.count, 1)
    }

    func testPlainHeadingRangeMovesWithTableEditAndNumbering() throws {
        let text = "| A |\n|---|\n| one |\n\n# Straße"
        let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true)
        let table = try XCTUnwrap(parsed.tables.first)
        let original = try XCTUnwrap(parsed.headings.first?.plainTextRange)
        let edit = (text as NSString).range(of: "one")
        let updated = parsed.replacingTable(table, oldTable: table.range, edit: edit, replacementLength: 5).numberingHeadings(true)
        let shifted = try XCTUnwrap(updated.headings.first?.plainTextRange)
        XCTAssertEqual(shifted, NSRange(location: original.location + 2, length: original.length))
    }

    func testUppercaseHeadingRunsUseConfirmedRichSource() throws {
        let text = "# **Straße** &amp; [go](#id) `code`\n\n# :smile:\n\n# $x$\n\n# ![alt](image.png)"
        let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(parsed.headings.first)
        let runs = try XCTUnwrap(heading.uppercaseRuns)
        XCTAssertTrue(runs.contains { $0.styles.contains(.strong) && $0.pieces.map(\.text).joined() == "Straße" })
        XCTAssertTrue(runs.contains { $0.styles.contains(.link) && $0.pieces.map(\.text).joined() == "go" })
        XCTAssertTrue(runs.contains { $0.styles.contains(.code) && $0.pieces.map(\.text).joined() == "code" })
        XCTAssertTrue(runs.flatMap(\.pieces).contains { !$0.matchesSource && $0.text == "&" })
        let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: runs.flatMap(\.pieces), sourceRange: heading.range))
        XCTAssertEqual(projection.text, "STRASSE & GO CODE")
        let emojiHeading = parsed.headings[1].resolvingEmoji(["smile": "😄"])
        let emojiRuns = try XCTUnwrap(emojiHeading.uppercaseRuns)
        let emojiProjection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: emojiRuns.flatMap(\.pieces), sourceRange: emojiHeading.range))
        XCTAssertEqual(emojiProjection.text, "😄")
        let token = (text as NSString).range(of: ":smile:")
        XCTAssertEqual(emojiProjection.sourcePosition(for: 0), token.location - emojiHeading.range.location)
        XCTAssertEqual(emojiProjection.sourcePosition(for: 0, fraction: 0.75), NSMaxRange(token) - emojiHeading.range.location)
        let unknown = parsed.headings[1].resolvingEmoji([:])
        XCTAssertEqual(unknown.uppercaseRuns?.flatMap(\.pieces).map(\.text).joined(), ":smile:")
        XCTAssertEqual(parsed.headings[2].uppercaseRuns?.first?.attachment, .formula)
        XCTAssertEqual(parsed.headings[3].uppercaseRuns?.first?.attachment, .image)
        XCTAssertTrue(parsed.images.contains { (text as NSString).substring(with: $0.range) == "![alt](image.png)" && $0.isInline })
        XCTAssertNil(MarkdownPresentationParser.parse(text, includeEmojiCandidates: true).headings.first?.uppercaseRuns)
        XCTAssertNil(MarkdownPresentationParser.parse(text, includeUppercaseRuns: true).headings.first?.uppercaseRuns)
    }

    func testUppercaseHeadingKeepsStylesAcrossComposedCharacter() throws {
        let source = "# **e**\u{301} end"
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(presentation.headings.first)
        let runs = try XCTUnwrap(heading.uppercaseRuns)
        let base = try XCTUnwrap(runs.first { $0.pieces.map(\.text).joined() == "e" })
        let mark = try XCTUnwrap(runs.first { $0.pieces.map(\.text).joined().hasPrefix("\u{301}") })
        XCTAssertTrue(base.styles.contains(.strong))
        XCTAssertFalse(mark.styles.contains(.strong))
        let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: runs.flatMap(\.pieces), sourceRange: heading.range))
        XCTAssertTrue(projection.text.hasPrefix("E\u{301}"))
        let raw = source as NSString
        let baseRange = raw.range(of: "e")
        let markRange = raw.range(of: "\u{301}")
        XCTAssertEqual(projection.sourcePosition(for: 0, fraction: 0.25), baseRange.location - heading.range.location)
        XCTAssertEqual(projection.sourcePosition(for: 0, fraction: 0.75), NSMaxRange(markRange) - heading.range.location)
    }

    func testUppercaseHeadingRunsMapSetextLineBreaks() throws {
        for newline in ["\n", "\r", "\r\n"] {
            for prefix in ["", "> ", "- "] {
                let continuation = prefix == "- " ? "  " : prefix
                let text = prefix + "中文 **first**" + newline + continuation + "second" + newline + continuation + "======"
                for preserve in [true, false] {
                    let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true,
                        syntax: .init(preserveEditingSoftBreaks: preserve))
                    let heading = try XCTUnwrap(parsed.headings.first)
                    let runs = try XCTUnwrap(heading.uppercaseRuns)
                    let pieces = runs.flatMap(\.pieces)
                    let lineBreak = try XCTUnwrap(pieces.first { (text as NSString).substring(with: $0.sourceRange) == newline })
                    XCTAssertEqual(lineBreak.text, preserve ? "\n" : " ")
                    XCTAssertFalse(lineBreak.matchesSource)
                    let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: heading.range))
                    XCTAssertEqual(projection.text, preserve ? "中文 FIRST\nSECOND" : "中文 FIRST SECOND")
                    let displayOffset = (projection.text as NSString).range(of: preserve ? "\n" : " ", options: .backwards).location
                    XCTAssertEqual(projection.sourcePosition(for: displayOffset), lineBreak.sourceRange.location - heading.range.location)
                    XCTAssertEqual(projection.sourcePosition(for: displayOffset, fraction: 0.75), NSMaxRange(lineBreak.sourceRange) - heading.range.location)
                }
            }
        }
    }

    func testUppercaseHeadingRunsKeepHardBreakWhenSoftBreaksAreDisabled() throws {
        for marker in ["  ", "\\"] {
            let text = "first" + marker + "\nsecond\n======"
            let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true,
                syntax: .init(preserveEditingSoftBreaks: false))
            let heading = try XCTUnwrap(parsed.headings.first)
            let pieces = try XCTUnwrap(heading.uppercaseRuns).flatMap(\.pieces)
            let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: heading.range))
            XCTAssertEqual(projection.text, "FIRST\nSECOND")
            XCTAssertTrue(pieces.contains { $0.text == "\n" && (text as NSString).substring(with: $0.sourceRange) == "\n" })
        }
    }

    func testUppercaseHeadingRunsMapConfirmedHTMLBreak() throws {
        for marker in ["<br>", "<br/>", "<br />", "<BR>"] {
            let text = "# 中文 **first \(marker) second**"
            let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true,
                syntax: .init(preserveEditingSoftBreaks: false))
            let heading = try XCTUnwrap(parsed.headings.first)
            let pieces = try XCTUnwrap(heading.uppercaseRuns).flatMap(\.pieces)
            let lineBreak = try XCTUnwrap(pieces.first { $0.text == "\n" })
            XCTAssertEqual((text as NSString).substring(with: lineBreak.sourceRange), marker)
            let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: heading.range))
            XCTAssertEqual(projection.text, "中文 FIRST \n SECOND")
            let position = (projection.text as NSString).range(of: "\n").location
            XCTAssertEqual(projection.sourcePosition(for: position), lineBreak.sourceRange.location - heading.range.location)
            XCTAssertEqual(projection.sourcePosition(for: position, fraction: 0.75), NSMaxRange(lineBreak.sourceRange) - heading.range.location)
        }
        for marker in ["<br class='x'>", "<script><br></script>", "<template><br></template>"] {
            let text = "# first \(marker) second"
            let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true)
            XCTAssertNil(parsed.headings.first?.uppercaseRuns)
        }
    }

    func testUppercaseEmojiRunsMoveWithTableEdit() throws {
        let text = "| A |\n|---|\n| one |\n\n# :smile:"
        let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let table = try XCTUnwrap(parsed.tables.first)
        let original = try XCTUnwrap(parsed.headings.first?.uppercaseRuns?.first?.emoji.first?.range)
        let edit = (text as NSString).range(of: "one")
        let updated = parsed.replacingTable(table, oldTable: table.range, edit: edit, replacementLength: 5)
        let shifted = try XCTUnwrap(updated.headings.first?.uppercaseRuns?.first?.emoji.first?.range)
        XCTAssertEqual(shifted, NSRange(location: original.location + 2, length: original.length))
        let resolved = try XCTUnwrap(updated.headings.first?.resolvingEmoji(["smile": "😄"]).uppercaseRuns)
        XCTAssertEqual(resolved.flatMap(\.pieces).map(\.text).joined(), "😄")
    }

    func testUppercaseRunsUseOnlyConfirmedInlineHTMLAndImages() throws {
        let text = "# <strong>bold <em>中文</em></strong> <img src='a.png' width='50%'>\n\n# <mark>yes</mark> <sub>two</sub>\n\n# <script>ignored</script>"
        let parsed = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let first = try XCTUnwrap(parsed.headings.first?.uppercaseRuns)
        XCTAssertTrue(first.contains { $0.styles.contains(.strong) && $0.styles.contains(.emphasis) && $0.pieces.map(\.text).joined() == "中文" })
        XCTAssertTrue(first.contains { $0.attachment == .image })
        let second = try XCTUnwrap(parsed.headings[1].uppercaseRuns)
        XCTAssertTrue(second.contains { $0.styles.contains(.highlight) })
        XCTAssertTrue(second.contains { $0.styles.contains(.subscriptText) })
        XCTAssertNil(parsed.headings[2].uppercaseRuns)
    }

    func testReferenceDefinitionRetainedSuffixMapsInlineSources() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let text = "[id]: https://example.com" + newline + "中文 **bold** [link][id] $x$"
            let raw = text as NSString
            let parsed = MarkdownPresentationParser.parse(text)
            let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong })
            XCTAssertEqual(raw.substring(with: strong.range), "**bold**")
            let link = try XCTUnwrap(parsed.links.first)
            XCTAssertEqual(raw.substring(with: link.range), "[link][id]")
            let formula = try XCTUnwrap(parsed.inlineFormulas.first)
            XCTAssertEqual(raw.substring(with: formula.range), "$x$")
        }
    }

    func testReferenceDefinitionWithTopLevelTabPrefixMapsInlineSources() throws {
        for newline in ["\n", "\r\n"] {
            let text = "[id]: /url" + newline + "\t中文 **bold** [link][id] $x$"
            let raw = text as NSString
            let parsed = MarkdownPresentationParser.parse(text)
            let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong }, text)
            XCTAssertEqual(raw.substring(with: strong.range), "**bold**")
            let link = try XCTUnwrap(parsed.links.first, text)
            XCTAssertEqual(raw.substring(with: link.range), "[link][id]")
            let math = try XCTUnwrap(parsed.inlineFormulas.first, text)
            XCTAssertEqual(raw.substring(with: math.range), "$x$")
        }
    }

    func testReferenceDefinitionIsNotIncludedInParagraphGeometry() throws {
        let text = "[id]: /url\r\nhello\r\n\r\nnext"
        let raw = text as NSString
        let paragraphs = MarkdownPresentationParser.parse(text).paragraphs
        let first = try XCTUnwrap(paragraphs.first)
        XCTAssertEqual(raw.substring(with: first.range), "hello\r\n")
        XCTAssertEqual(first.separatorAfter.map { raw.substring(with: $0) }, "\r\n")
    }

    func testReferenceDefinitionInContainersUsesConfirmedColumns() throws {
        for newline in ["\n", "\r\n"] {
            for text in ["> [id]: /url" + newline + "> 中文 **bold** $x$",
                         "- [id]: /url" + newline + "  中文 **bold** $x$",
                         "> - [id]: /url" + newline + ">   中文 **bold** $x$"] {
                let raw = text as NSString
                let parsed = MarkdownPresentationParser.parse(text)
                let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong }, text)
                XCTAssertEqual(raw.substring(with: strong.range), "**bold**", text)
                let math = try XCTUnwrap(parsed.inlineFormulas.first, text)
                XCTAssertEqual(raw.substring(with: math.range), "$x$", text)
            }
        }
        for text in ["> [id]: /url\n> hello\n**world**",
                     "> [id]: /url\r\n> hello\r\n>   **world**",
                     "- [id]: /url\n  hello\n**world**"] {
            let strong = try XCTUnwrap(MarkdownPresentationParser.parse(text).spans.first { $0.kind == .strong }, text)
            XCTAssertEqual((text as NSString).substring(with: strong.range), "**world**", text)
        }
        let math = "> [id]: /url\r\n> hello\r\n>   $x$"
        let formula = try XCTUnwrap(MarkdownPresentationParser.parse(math).inlineFormulas.first)
        XCTAssertEqual((math as NSString).substring(with: formula.range), "$x$")
        for text in ["> [id]: /url\n>\t**bold**", "- [id]: /url\r\n\t**bold**",
                     "> - [id]: /url\n> \t**bold**"] {
            let strong = try XCTUnwrap(MarkdownPresentationParser.parse(text).spans.first { $0.kind == .strong }, text)
            XCTAssertEqual((text as NSString).substring(with: strong.range), "**bold**", text)
        }
        let contentTab = "> [id]: /url\n>\t**bo\tld**"
        XCTAssertFalse(MarkdownPresentationParser.parse(contentTab).spans.contains { $0.kind == .strong })
    }

    func testMultipleReferenceLinesInQuoteMapRetainedSources() throws {
        for newline in ["\n", "\r\n"] {
            let text = ["> [a]: /x", "> \"title 中文", "> [b]: /y\"", "> **bold** [link][a] $x$"].joined(separator: newline)
            let raw = text as NSString
            let parsed = MarkdownPresentationParser.parse(text)
            let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong })
            XCTAssertEqual(raw.substring(with: strong.range), "**bold**")
            let link = try XCTUnwrap(parsed.links.first)
            XCTAssertEqual(raw.substring(with: link.range), "[link][a]")
            let math = try XCTUnwrap(parsed.inlineFormulas.first)
            XCTAssertEqual(raw.substring(with: math.range), "$x$")
        }
    }

    func testMultipleReferenceLinesInListMapRetainedSources() throws {
        for newline in ["\n", "\r\n"] {
            for lines in [["> - [a]: /x", ">   [b]: /y", ">   中文 **bold** [link][b] $x$"],
                          ["- [x] [a]: /x", "  [b]: /y", "  中文 **bold** [link][b] $x$"]] {
                let text = lines.joined(separator: newline)
                let raw = text as NSString
                let parsed = MarkdownPresentationParser.parse(text)
                let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong })
                XCTAssertEqual(raw.substring(with: strong.range), "**bold**")
                let link = try XCTUnwrap(parsed.links.first)
                XCTAssertEqual(raw.substring(with: link.range), "[link][b]")
                let math = try XCTUnwrap(parsed.inlineFormulas.first)
                XCTAssertEqual(raw.substring(with: math.range), "$x$")
            }
        }
    }

    func testReferenceRetainedTabsMapInlineRanges() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let text = ["- [a]: /x", "  [b]: /y", "  中文\t**bold**\t[link][b] `code` $x$"].joined(separator: newline)
            let raw = text as NSString
            let parsed = MarkdownPresentationParser.parse(text)
            for (kind, expected) in [(MarkdownPresentationKind.strong, "**bold**"), (.code, "`code`")] {
                let span = try XCTUnwrap(parsed.spans.first { $0.kind == kind }, text)
                XCTAssertEqual(raw.substring(with: span.range), expected, text)
            }
            let link = try XCTUnwrap(parsed.links.first, text)
            XCTAssertEqual(raw.substring(with: link.range), "[link][b]", text)
            let formula = try XCTUnwrap(parsed.inlineFormulas.first, text)
            XCTAssertEqual(raw.substring(with: formula.range), "$x$", text)
        }
    }

    func testConfirmedInlineHTMLLinkUsesDecodedHrefAndSourceRange() throws {
        let text = "中文 <a href='https://example.com/?a=1&amp;b=2'>**bold**</a> end"
        let raw = text as NSString
        let parsed = MarkdownPresentationParser.parse(text)
        let link = try XCTUnwrap(parsed.links.first)
        XCTAssertEqual(link.url, "https://example.com/?a=1&b=2")
        XCTAssertEqual(raw.substring(with: link.range), "<a href='https://example.com/?a=1&amp;b=2'>**bold**</a>")
        let heading = MarkdownPresentationParser.parse("# <a href='#target'>**中文 :smile:**</a>", includeEmojiCandidates: true, includeUppercaseRuns: true)
        let runs = try XCTUnwrap(heading.headings.first?.uppercaseRuns)
        XCTAssertTrue(runs.contains { $0.styles.contains(.link) && $0.styles.contains(.strong) })
        XCTAssertEqual(heading.links.first?.url, "#target")
        let resolved = try XCTUnwrap(heading.headings.first?.resolvingEmoji(["smile": "😄"]).uppercaseRuns)
        XCTAssertTrue(resolved.contains { $0.styles.contains(.link) && $0.pieces.map(\.text).joined().contains("😄") })
    }

    func testParagraphSeparatorsRequireAdjacentConfirmedParagraphs() {
        let source = "中文😀 first\r\nsecond\r\n\r\n \r\nnext\r\n\r\n# heading\r\n"
        let raw = source as NSString
        let paragraphs = MarkdownPresentationParser.parse(source).paragraphs
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.first?.separatorAfter.map { raw.substring(with: $0) }, "\r\n \r\n")
        XCTAssertNil(paragraphs.last?.separatorAfter)
        let quote = "> first\r\n>\r\n> second\r\n"
        let quoteParagraphs = MarkdownPresentationParser.parse(quote).paragraphs
        XCTAssertEqual(quoteParagraphs.first?.separatorAfter.map { (quote as NSString).substring(with: $0) }, ">\r\n")
    }

    func testParagraphRangesUseConfirmedPhysicalLines() {
        let source = "# Heading\r\n\r\n中文😀 first\r\nsecond\r\n\r\n> quote\r\n\r\n```\r\ncode\r\n```\r\n"
        let parsed = MarkdownPresentationParser.parse(source)
        let raw = source as NSString
        XCTAssertEqual(parsed.paragraphs.map { raw.substring(with: $0.range) }, ["中文😀 first\r\nsecond\r\n", "> quote\r\n"])
        XCTAssertEqual(parsed.paragraphs.map { raw.substring(with: $0.lastLine) }, ["second\r\n", "> quote\r\n"])
        let ambiguous = "[foo]: https://example.com\nhello\n\n[foo]"
        let ambiguousRanges = MarkdownPresentationParser.parse(ambiguous).paragraphs.map(\.range)
        XCTAssertFalse(ambiguousRanges.contains { NSIntersectionRange($0, (ambiguous as NSString).range(of: "[foo]:")).length > 0 })
        let codeAfterDefinition = "[foo]: https://example.com\n`hello`\n\n[foo]"
        let codeRanges = MarkdownPresentationParser.parse(codeAfterDefinition).paragraphs.map(\.range)
        XCTAssertFalse(codeRanges.contains { NSIntersectionRange($0, (codeAfterDefinition as NSString).range(of: "[foo]:")).length > 0 })
        let codeOnly = "`hello`"
        XCTAssertEqual(MarkdownPresentationParser.parse(codeOnly).paragraphs.map(\.range), [NSRange(location: 0, length: (codeOnly as NSString).length)])
        for content in ["![中文](image.png)", "<span>中文</span>"] {
            let standalone = MarkdownPresentationParser.parse(content)
            XCTAssertEqual(standalone.paragraphs.map(\.range), [NSRange(location: 0, length: (content as NSString).length)])
            let afterDefinition = "[foo]: https://example.com\n" + content + "\n\n[foo]"
            let definition = (afterDefinition as NSString).range(of: "[foo]:")
            XCTAssertFalse(MarkdownPresentationParser.parse(afterDefinition).paragraphs.contains {
                NSIntersectionRange($0.range, definition).length > 0
            })
        }
    }

    func testListMarkersUseCmarkOrdinalsAndSourceRanges() {
        let source = "中文😀\r\n\r\n> 9. first\r\n> 1. second\r\n>    - child\r\n\r\n- [x] task\r\n- ordinary\r\n- \r\n"
        let presentation = MarkdownPresentationParser.parse(source)
        let raw = source as NSString
        XCTAssertEqual(presentation.listMarkers.map(\.text), ["9.", "10.", "•", "•", "•"])
        XCTAssertEqual(presentation.listMarkers.map(\.ordinal), [9, 10, nil, nil, nil])
        XCTAssertEqual(presentation.listMarkers.map(\.depth), [1, 1, 2, 1, 1])
        XCTAssertEqual(presentation.listMarkers.map { raw.substring(with: $0.range) }, ["9.", "1.", "-", "-", "-"])
        XCTAssertEqual(presentation.taskCheckboxes.count, 1)
        XCTAssertTrue(presentation.listMarkers.allSatisfy { NSLocationInRange($0.range.location, $0.line) })
    }

    func testListMarkersDoNotInventLazyContinuationOrCode() {
        let source = "- first\n  continued\nlazy\n\n```\n- code\n```\n"
        let markers = MarkdownPresentationParser.parse(source).listMarkers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual((source as NSString).substring(with: markers[0].range), "-")
    }

    func testListMarkerRangesSurviveTableEditAndTabs() throws {
        let source = "> -\tfirst\r\n\r\n| A |\r\n|---|\r\n| x |\r\n\r\n- after"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.listMarkers.count, 2)
        let table = try XCTUnwrap(parsed.tables.first)
        let edit = (source as NSString).range(of: "x")
        let updated = parsed.replacingTable(table, oldTable: table.range, edit: edit, replacementLength: 2)
        XCTAssertEqual(updated.listMarkers.first?.range, parsed.listMarkers.first?.range)
        XCTAssertEqual(updated.listMarkers.last?.range.location, (parsed.listMarkers.last?.range.location ?? 0) + 1)
        XCTAssertEqual(updated.listMarkers.map(\.depth), parsed.listMarkers.map(\.depth))
        XCTAssertEqual(updated.listMarkers.map(\.ordinal), parsed.listMarkers.map(\.ordinal))
        for source in [">\t- first\r\n", "-\tchild\n\t- nested\n"] {
            let markers = MarkdownPresentationParser.parse(source).listMarkers
            XCTAssertEqual(markers.count, source.hasPrefix(">") ? 1 : 2)
            XCTAssertTrue(markers.allSatisfy { (source as NSString).substring(with: $0.range) == "-" })
        }
    }
    func testIframeBlocksUseConfirmedTopLevelSourceRanges() throws {
        let source = "中😀\r\n\r\n<iframe src=\"https://example.com/embed\" width=\"50%\" height=\"240\" title=\"Example\"></iframe>\r\n\r\n```html\r\n<iframe src=\"https://example.com/no\"></iframe>\r\n```"
        let presentation = MarkdownPresentationParser.parse(source)
        let frame = try XCTUnwrap(presentation.iframeBlocks.first)
        XCTAssertEqual(presentation.iframeBlocks.count, 1)
        let raw = source as NSString
        XCTAssertTrue(raw.substring(with: frame.range).hasPrefix("<iframe src=\"https://example.com/embed\""))
        XCTAssertEqual(frame.width, "50%")
        XCTAssertEqual(frame.height, "240")
        XCTAssertEqual(frame.title, "Example")
        XCTAssertTrue(frame.html.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(MarkdownPresentationParser.parse("<iframe src=\"file:///tmp/a\"></iframe>").iframeBlocks.isEmpty)
        XCTAssertTrue(MarkdownPresentationParser.parse("> <iframe src=\"https://example.com\"></iframe>").iframeBlocks.isEmpty)
        let hidden = "before <script>\n\n<iframe src=\"https://example.com\"></iframe>\n\n<audio src=\"song.mp3\" />\n\n</script>"
        let blocked = MarkdownPresentationParser.parse(hidden)
        XCTAssertTrue(blocked.iframeBlocks.isEmpty)
        XCTAssertTrue(blocked.audioBlocks.isEmpty)
    }

    func testEmptyContainersProvideConfirmedFencePrefix() {
        for (source, prefix, continuation) in [("> ", "> ", "> "), ("- ", "- ", "  "), ("> - ", "> - ", ">   "),
                                                (">    ", ">    ", ">    "), ("-    ", "-    ", "     "), ("> -    ", "> -    ", ">      "),
                                                ("-\t", "-\t", " \t"), (">\t", ">\t", ">\t"), ("> -\t", "> -\t", ">  \t")] {
            let result = MarkdownPresentationParser.parse(source)
            XCTAssertEqual(result.fenceContainerLines.first?.sourcePrefix, prefix, source)
            XCTAssertEqual(result.fenceContainerLines.first?.continuationPrefix, continuation, source)
        }
        for source in ["-", "-     ", ">     ", "> -     "] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).fenceContainerLines.isEmpty, source)
        }
    }

    func testFenceContainerLinesConfirmParagraphPrefix() {
        for (source, prefix, continuation) in [
            ("> old", "> ", "> "),
            ("> - old", "> - ", ">   "),
            ("> first\n> old", "> ", "> "),
            ("- first\n  old", "  ", "  "),
            ("> - first\n>   old", ">   ", ">   "),
            ("> -\t中文😀\r\n> \told", "> \t", "> \t"),
            (">\t- first\n>\t  old", ">\t  ", ">\t  "),
            ("> > - first\n> >   old", "> >   ", "> >   "),
            ("- parent\r\n\r\n  old", "  ", "  ")
        ] {
            let result = MarkdownPresentationParser.parse(source)
            let line = (source as NSString).lineRange(for: NSRange(location: (source as NSString).length, length: 0))
            let candidate = result.fenceContainerLines.first { $0.line == line }
            XCTAssertEqual(candidate?.sourcePrefix, prefix, source)
            XCTAssertEqual(candidate?.continuationPrefix, continuation, source)
        }
        XCTAssertTrue(MarkdownPresentationParser.parse("> ```\n> old\n> ```").fenceContainerLines.isEmpty)
        XCTAssertTrue(MarkdownPresentationParser.parse("| A |\n|---|\n| old |").fenceContainerLines.isEmpty)
        for lazy in ["> first\nlazy", "> first\n  lazy", "- first\n old", "> - first\n>  old", "> - first\n >  old"] {
            let lazyLine = (lazy as NSString).lineRange(for: NSRange(location: (lazy as NSString).length, length: 0))
            XCTAssertFalse(MarkdownPresentationParser.parse(lazy).fenceContainerLines.contains { $0.line == lazyLine })
        }
    }

    func testFenceContextTracksOpaqueLinesIndependentlyOfPresentation() {
        let source = "---\ntitle: one\n---\n\ntext\n\n```js\ninside\n```\n\n<div>\nraw\n</div>\n\n- item\n  nested\n\nend"
        let raw = source as NSString
        let result = MarkdownPresentationParser.parse(source)
        XCTAssertTrue(result.fenceContextAvailable)
        func blocked(_ value: String) -> Bool {
            let location = raw.lineRange(for: raw.range(of: value)).location
            return result.fenceBlockedRanges.contains { NSLocationInRange(location, $0) }
        }
        XCTAssertTrue(blocked("title: one"))
        XCTAssertTrue(blocked("inside"))
        XCTAssertTrue(blocked("raw"))
        XCTAssertTrue(blocked("nested"))
        XCTAssertFalse(blocked("text"))
        XCTAssertTrue(blocked("```js"))
        XCTAssertFalse(blocked("end"))
        XCTAssertFalse(MarkdownPresentationParser.parse("\0").fenceContextAvailable)
        XCTAssertTrue(MarkdownPresentationParser.parse("```js\n").fenceBlockedEOF)
        XCTAssertFalse(MarkdownPresentationParser.parse("```js\nx\n```\n").fenceBlockedEOF)
    }
    func testCodeBlocksExposeOnlyConfirmedBodyAndLanguage() throws {
        let source = "中文😀\r\n\r\n```js\r\nlet a = 1;\r\n```\r\n\r\n~~~python\r\nx = 2\r\n~~~~\r\n\r\n```unknown\r\nx\r\n```\r\n\r\n```js\r\nunclosed"
        let blocks = MarkdownPresentationParser.parse(source).codeBlocks
        XCTAssertEqual(blocks.map(\.info), ["js", "python", "unknown", "js"])
        let text = source as NSString
        XCTAssertEqual(blocks.map { text.substring(with: $0.bodyRange) }, ["let a = 1;\r\n", "x = 2\r\n", "x\r\n", "unclosed"])
        XCTAssertEqual(blocks.map(\.literal), ["let a = 1;\n", "x = 2\n", "x\n", "unclosed\n"])
        XCTAssertEqual(blocks.map { text.substring(with: $0.infoRange) }, ["js", "python", "unknown", "js"])
        XCTAssertTrue(blocks.allSatisfy { NSLocationInRange($0.bodyRange.location, $0.range) })
    }
    func testCodeBlockInfoRangePreservesSpacesAndEmptyInfo() {
        let source = "```  js extra\nvalue\n```\n\n```\nempty info\n```\n\n```js\nlast\n"
        let text = source as NSString
        let blocks = MarkdownPresentationParser.parse(source).codeBlocks
        XCTAssertEqual(blocks.map { text.substring(with: $0.infoRange) }, ["  js extra", "", "js"])
        XCTAssertEqual(blocks.map(\.isClosed), [true, true, false])
        XCTAssertEqual(blocks.map { text.substring(with: $0.bodyRange) }, ["value\n", "empty info\n", "last\n"])
        XCTAssertTrue(blocks.allSatisfy { NSMaxRange($0.bodyRange) <= NSMaxRange($0.range) })
    }
    func testNestedCodeBlocksMapOnlyContainerFreeSource() {
        let source = "中😀\r\n\r\n> ```js\r\n> let x = 1\r\n> ```\r\n\r\n- ```python\r\n  x = 2\r\n  ```\r\n\r\n> - ```js\r\n>   let y = 3\r\n>   ```\r\n"
        let text = source as NSString
        let blocks = MarkdownPresentationParser.parse(source).codeBlocks
        XCTAssertEqual(blocks.map(\.info), ["js", "python", "js"])
        XCTAssertEqual(blocks.map(\.literal), ["let x = 1\n", "x = 2\n", "let y = 3\n"])
        XCTAssertEqual(blocks.map { $0.bodySegments.map { text.substring(with: $0) }.joined() },
                       ["let x = 1\r\n", "x = 2\r\n", "let y = 3\r\n"])
        XCTAssertTrue(blocks.allSatisfy(\.isClosed))
        let followingParagraph = "- first\n\n  ```js\n  let n = 42\n  ```\n\n- sibling\n"
        let afterParagraph = MarkdownPresentationParser.parse(followingParagraph).codeBlocks
        XCTAssertEqual(afterParagraph.map(\.literal), ["let n = 42\n"])
    }
    func testIndentedFenceAndClosingWhitespaceUseConfirmedContent() {
        let source = "  ```js\n  let x = 1\n  ```   \n\nafter"
        let text = source as NSString
        let blocks = MarkdownPresentationParser.parse(source).codeBlocks
        XCTAssertEqual(blocks.count, 1)
        guard let block = blocks.first else { return }
        XCTAssertTrue(block.isClosed)
        XCTAssertEqual(block.bodySegments.map { text.substring(with: $0) }.joined(), "let x = 1\n")
        XCTAssertEqual(block.literal, "let x = 1\n")
    }
    func testCodeContainerPrefixCanVaryBetweenLines() {
        let source = "> ```js\n>let x = 1\n> ```\n\n- ```js\n    let y = 2\n  ```\n"
        let text = source as NSString
        let blocks = MarkdownPresentationParser.parse(source).codeBlocks
        XCTAssertEqual(blocks.map(\.literal), ["let x = 1\n", "  let y = 2\n"])
        XCTAssertEqual(blocks.map { $0.bodySegments.map { text.substring(with: $0) }.joined() },
                       ["let x = 1\n", "  let y = 2\n"])
        XCTAssertTrue(blocks.allSatisfy(\.isClosed))
    }
    func testCodeBodyTabDoesNotInvalidateFenceCoordinates() {
        let source = "> - ```js\n>   let\tx = 1\n>   ```\n"
        let text = source as NSString
        let block = MarkdownPresentationParser.parse(source).codeBlocks.first
        XCTAssertEqual(block?.literal, "let\tx = 1\n")
        XCTAssertEqual(block?.bodySegments.map { text.substring(with: $0) }.joined(), "let\tx = 1\n")
        let unclosed = "```js\tlinenos\nx\ty"
        let unclosedBlock = MarkdownPresentationParser.parse(unclosed).codeBlocks.first
        XCTAssertEqual(unclosedBlock?.literal, "x\ty\n")
        XCTAssertEqual(unclosedBlock?.isClosed, false)
        let list = "-\t```js\n\tlet y = 2\n\t```\n"
        let listText = list as NSString
        let listBlock = MarkdownPresentationParser.parse(list).codeBlocks.first
        XCTAssertEqual(listBlock?.bodySegments.map { listText.substring(with: $0) }.joined(), "let y = 2\n")
        let partialTab = ">\t```js\n>\tlet x = 1\n>\t```\n"
        let partialBlock = MarkdownPresentationParser.parse(partialTab).codeBlocks.first
        XCTAssertEqual(partialBlock?.literal, " let x = 1\n")
        XCTAssertEqual(partialBlock?.bodyPadding, [1])
        let presentation = MarkdownPresentationParser.parse(partialTab)
        let partialText = partialTab as NSString
        let codeSpans = presentation.spans.filter { $0.kind == .codeBlock }
        XCTAssertEqual(codeSpans.count, 1)
        let span = codeSpans.first
        XCTAssertEqual(span?.markerRanges.map { partialText.substring(with: $0) }, ["```", "```"])
        XCTAssertEqual(partialBlock.map { partialText.substring(with: $0.infoRange) }, "js")
    }
    func testFlowAndSequenceUseConfirmedTopLevelFences() {
        let source = "中文😀\r\n\r\n```flow\r\ns=>start: Start\r\n```\r\n\r\n```sequence\r\nA->B: Hi\r\n```\r\n\r\n> ```flow\r\n> nested\r\n> ```\r\n\r\n```sequence\r\nunclosed"
        let diagrams = MarkdownPresentationParser.parse(source).diagrams
        XCTAssertEqual(diagrams.map(\.kind), [.flow, .sequence])
        let raw = source as NSString
        XCTAssertEqual(diagrams.map { raw.substring(with: $0.range) }, ["```flow\r\ns=>start: Start\r\n```", "```sequence\r\nA->B: Hi\r\n```"])
    }
    func testTableCellBreakRangesUseCmarkAndUTF16() {
        let raw = "中😀a\\|b<br>one\\|two<br/>three<br />four<BR>five \\<br> `<br>` <script>"
        let text = raw as NSString
        let ranges = MarkdownPresentationParser.tableCellBreaks(raw)
        XCTAssertEqual(ranges.map { text.substring(with: $0) }, ["<br>", "<br/>", "<br />", "<BR>"])
        XCTAssertEqual(ranges.first?.location, ("中😀a\\|b" as NSString).length)
        XCTAssertTrue(MarkdownPresentationParser.tableCellBreaks("<br\n>").isEmpty)
    }
    func testSimpleUnderlineUsesExactTagsAndExcludesAmbiguousShapes() {
        let source = "中文😀 <u>plain</u> and <u>second</u>\r\n\r\n`<u>code</u>` [<u>link</u>](url)\r\n\r\n<u>**bold**</u> <u class=\"x\">x</u>"
        let text = source as NSString
        let spans = MarkdownPresentationParser.parse(source).spans.filter { $0.kind == .underline }
        let values = spans.map { text.substring(with: $0.range) }
        XCTAssertTrue(values.contains("<u>plain</u>"))
        XCTAssertTrue(values.contains("<u>second</u>"))
        XCTAssertTrue(values.contains("<u>link</u>"))
        XCTAssertTrue(values.contains("<u>**bold**</u>"))
        XCTAssertEqual(spans.first?.markerRanges.map { text.substring(with: $0) }, ["<u>", "</u>"])
        for nested in ["<u><u>x</u></u>", "<u>before <u>x</u> tail</u>", "<u>**<u>x</u>**</u>", "<U><u>x</u></U>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(nested).spans.contains { $0.kind == .underline }, nested)
        }
        let attributed = "<u class=\"x\"><u>x</u></u>"
        let attributedText = attributed as NSString
        let attributedRanges = MarkdownPresentationParser.parse(attributed).spans.filter { $0.kind == .underline }.map { attributedText.substring(with: $0.range) }
        XCTAssertFalse(attributedRanges.contains(attributed))
    }
    func testSimpleSubscriptSuperscriptAndStrikethroughAreDistinct() {
        let source = "中文😀 H~2~O X^2^ ~~strike~~\r\n\r\n`~code~ ^code^` [^link^](url)"
        let text = source as NSString
        let spans = MarkdownPresentationParser.parse(source).spans
        XCTAssertEqual(spans.filter { $0.kind == .subscriptText }.map { text.substring(with: $0.range) }, ["~2~"])
        XCTAssertEqual(spans.filter { $0.kind == .superscriptText }.map { text.substring(with: $0.range) }, ["^2^"])
        XCTAssertEqual(spans.filter { $0.kind == .strikethrough }.map { text.substring(with: $0.range) }, ["~~strike~~"])
        let overlap = MarkdownPresentationParser.parse("==x^2^==").spans
        XCTAssertFalse(overlap.contains { $0.kind == .highlight || $0.kind == .superscriptText })
        for source in ["~==x==~", "~x^2^~"] {
            let spans = MarkdownPresentationParser.parse(source).spans
            XCTAssertFalse(spans.contains { $0.kind == .subscriptText || $0.kind == .highlight || $0.kind == .superscriptText }, source)
        }
    }
    func testAlertsRequireConfirmedTopLevelQuoteAndExactMarker() {
        for label in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let source = "中文😀\r\n\r\n> [!\(label)]\r\n> content"
            let alerts = MarkdownPresentationParser.parse(source).spans.filter { if case .alert = $0.kind { return true }; return false }
            XCTAssertEqual(alerts.count, 1, label)
            XCTAssertEqual(alerts.first?.kind, .alert(label))
            XCTAssertEqual(alerts.first?.markerRanges.first, (source as NSString).range(of: "[!\(label)]"))
        }
        for source in ["> [!UNKNOWN]\n> content", "> \\[!NOTE]\n> content", "> [!NOTE] extra\n> content",
                       "> [!NOTE]", "> > [!NOTE]\n> > content", "```\n> [!NOTE]\n> content\n```"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).spans.contains { if case .alert = $0.kind { return true }; return false }, source)
        }
    }
    func testSimpleFrontMatterDoesNotBecomeHeadingsAndPreservesOffsets() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let source = ["---", "title: 中文😀", "author: A B", "---", "", "# Heading"].joined(separator: ending)
            let result = MarkdownPresentationParser.parse(source)
            let yaml = try XCTUnwrap(result.spans.first { $0.kind == .yaml })
            XCTAssertEqual((source as NSString).substring(with: yaml.range), ["---", "title: 中文😀", "author: A B", "---"].joined(separator: ending))
            XCTAssertEqual(yaml.markerRanges.map { (source as NSString).substring(with: $0) }, ["---", "---"])
            XCTAssertEqual(result.headings.map(\.title), ["Heading"])
            XCTAssertEqual(result.headings.first?.range.location, (source as NSString).range(of: "# Heading").location)
        }
    }

    func testAmbiguousOrUnsupportedFrontMatterRemainsMarkdown() {
        for source in ["---", "---\ntitle: value", "text\n---\ntitle: ok\n---"] {
            XCTAssertNil(MarkdownPresentationParser.frontMatter(source), source)
            XCTAssertFalse(MarkdownPresentationParser.parse(source).spans.contains { $0.kind == .yaml }, source)
        }
    }

    func testFrontMatterBoundariesPreserveComplexContentAndLaterOffsets() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let front = ["---", "标题: 中文😀", "description: |", "  [toc]", "  # not a heading", "map: {one: 1, two: [x, y]}", "# comment", "---"].joined(separator: newline)
            let source = front + newline + newline + "[toc]" + newline + newline + "# After 😀"
            let result = MarkdownPresentationParser.parse(source)
            let yaml = try XCTUnwrap(result.spans.first { $0.kind == .yaml })
            XCTAssertEqual((source as NSString).substring(with: yaml.range), front)
            XCTAssertEqual(result.headings.map(\.title), ["After 😀"])
            XCTAssertEqual(result.headings.first?.range.location, (source as NSString).range(of: "# After 😀").location)
            XCTAssertEqual(result.tableOfContents, [(source as NSString).range(of: "[toc]", options: .backwards)])
            let masked = MarkdownPresentationParser.maskedFrontMatter(source, frontMatter: MarkdownPresentationParser.frontMatter(source))
            XCTAssertEqual(masked.utf8.count, source.utf8.count)
        }
        XCTAssertNotNil(MarkdownPresentationParser.frontMatter("---\n---"))
    }

    func testFrontMatterBOMTrailingWhitespaceAndDotClose() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for closing in ["--- \t", "... \t"] {
                let front = ["\u{feff}--- \t", "标题: 中文😀", "description: |", "  [toc]", closing].joined(separator: newline)
                let source = front + newline + newline + "# After"
                let parsed = MarkdownPresentationParser.parse(source)
                let span = try XCTUnwrap(parsed.spans.first { $0.kind == .yaml })
                XCTAssertEqual((source as NSString).substring(with: span.range), front)
                XCTAssertEqual(span.markerRanges.map { (source as NSString).substring(with: $0) }, ["---", String(closing.prefix(3))])
                XCTAssertEqual(parsed.headings.map(\.title), ["After"])
                XCTAssertEqual(parsed.headings.first?.range.location, (source as NSString).range(of: "# After").location)
                XCTAssertTrue(parsed.tableOfContents.isEmpty)
                let masked = MarkdownPresentationParser.maskedFrontMatter(source, frontMatter: MarkdownPresentationParser.frontMatter(source))
                XCTAssertEqual(masked.utf8.count, source.utf8.count)
            }
        }
        for source in [" ---\ntitle: x\n---", "--- # open\ntitle: x\n---", "---\ntitle: x\n... # end"] {
            XCTAssertNil(MarkdownPresentationParser.frontMatter(source), source)
        }
    }
    func testHighlightRangesMatchExactSourceAndExcludeAmbiguousNodes() {
        let source = "中文😀 ==one== and ==é==\r\n\r\n**==bold==**\r\n\r\n`==code==` [==link==](url)\r\n\r\n\\==escaped==\r\n\r\n== open== ===extra=== ==== ==unfinished"
        let text = source as NSString
        let highlights = MarkdownPresentationParser.parse(source).spans.filter { $0.kind == .highlight }
        XCTAssertEqual(highlights.map { text.substring(with: $0.range) }, ["==one==", "==é==", "==bold=="])
        for span in highlights { XCTAssertEqual(span.markerRanges.map { text.substring(with: $0) }, ["==", "=="]) }
    }
    func testStandaloneTableOfContentsUsesSharedHeadings() {
        let source = "中文😀\r\n\r\n[toc]\r\n\r\n# One\r\n\r\n## Two\r\n\r\n> [toc]\r\n\r\n- [toc]\r\n\r\n`[toc]`\r\n\r\n\\[toc]\r\n\r\n```\r\n[toc]\r\n```"
        let result = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(result.tableOfContents, [(source as NSString).range(of: "[toc]")])
        XCTAssertEqual(result.headings.map(\.title), ["One", "Two"])
        XCTAssertEqual(result.headings.map(\.level), [1, 2])
        XCTAssertTrue(MarkdownPresentationParser.parse("[toc]\n\n[toc]: https://example.com").tableOfContents.isEmpty)
    }
    private func marked(_ span: MarkdownPresentationSpan, in text: String) -> [String] {
        span.markerRanges.map { (text as NSString).substring(with: $0) }
    }

    func testUnicodeAndInlineFormattingUseUTF16Ranges() throws {
        let text = "# 中文 😀 **жирный** and *italic* ~~old~~ `code`"
        let presentation = MarkdownPresentationParser.parse(text)
        let heading = try XCTUnwrap(presentation.spans.first { $0.kind == .heading(1) })
        let strong = try XCTUnwrap(presentation.spans.first { $0.kind == .strong })
        let emphasis = try XCTUnwrap(presentation.spans.first { $0.kind == .emphasis })
        let strike = try XCTUnwrap(presentation.spans.first { $0.kind == .strikethrough })
        let code = try XCTUnwrap(presentation.spans.first { $0.kind == .code })
        XCTAssertEqual(marked(heading, in: text), ["# "])
        XCTAssertEqual((text as NSString).substring(with: strong.range), "**жирный**")
        XCTAssertEqual(marked(strong, in: text), ["**", "**"])
        XCTAssertEqual(marked(emphasis, in: text), ["*", "*"])
        XCTAssertEqual(marked(strike, in: text), ["~~", "~~"])
        XCTAssertEqual((text as NSString).substring(with: code.range), "`code`")
        XCTAssertEqual(marked(code, in: text), ["`", "`"])
    }

    func testLongASCIIAndUnicodeBoundariesAcrossLineEndings() throws {
        let prefix = String(repeating: "a", count: 100_000)
        let text = prefix + "\r\n\r## é中😀e\u{301} **ж😀**\r\r*after*\n"
        let spans = MarkdownPresentationParser.parse(text).spans
        let strong = try XCTUnwrap(spans.first { $0.kind == .strong })
        let emphasis = try XCTUnwrap(spans.first { $0.kind == .emphasis })
        XCTAssertEqual((text as NSString).substring(with: strong.range), "**ж😀**")
        XCTAssertEqual(marked(strong, in: text), ["**", "**"])
        XCTAssertEqual((text as NSString).substring(with: emphasis.range), "*after*")
    }

    func testNestedLinkHidesOnlyBracketsAndDestination() throws {
        let text = "[x **bold**](https://example.com/a_(b))"
        let spans = MarkdownPresentationParser.parse(text).spans
        let link = try XCTUnwrap(spans.first { $0.kind == .link })
        let strong = try XCTUnwrap(spans.first { $0.kind == .strong })
        XCTAssertEqual(marked(link, in: text), ["[", "](https://example.com/a_(b))"])
        XCTAssertEqual(marked(strong, in: text), ["**", "**"])
    }

    func testQuoteAndFencesWithCRLF() throws {
        let text = "> first\r\n> second\r\n\r\n```swift\r\nlet value = 1\r\n```"
        let spans = MarkdownPresentationParser.parse(text).spans
        let quote = try XCTUnwrap(spans.first { $0.kind == .quote })
        let code = try XCTUnwrap(spans.first { $0.kind == .codeBlock })
        XCTAssertEqual(marked(quote, in: text), [">", ">"])
        XCTAssertEqual(marked(code, in: text), ["```", "```"])
    }

    func testUncertainMarkupRemainsVisible() {
        let text = "\\*escaped*\n\n[reference][name]\n\n[name]: https://example.com\n\n# tab\t**bold**\n\n![**image**](image.png)"
        let spans = MarkdownPresentationParser.parse(text).spans
        let links = spans.filter { $0.kind == .link }
        XCTAssertTrue(links.allSatisfy { $0.markerRanges.isEmpty })
        XCTAssertFalse(spans.contains { $0.kind == .strong })
        XCTAssertFalse(spans.contains { $0.kind == .heading(1) })
    }

    func testParsingLeavesSourceUnchangedAndMalformedMarkupVisible() {
        let text = "中文 😀 **unfinished and [broken]("
        let original = text
        let spans = MarkdownPresentationParser.parse(text).spans
        XCTAssertEqual(text, original)
        XCTAssertFalse(spans.contains { $0.kind == .strong || $0.kind == .link })
    }

    func testSetextAndUnclosedFenceDoNotHideGuessedMarkers() throws {
        let text = "Heading\n=======\n\n```swift\nno closing fence"
        let spans = MarkdownPresentationParser.parse(text).spans
        let heading = try XCTUnwrap(spans.first { $0.kind == .heading(1) })
        let code = try XCTUnwrap(spans.first { $0.kind == .codeBlock })
        XCTAssertTrue(heading.markerRanges.isEmpty)
        XCTAssertTrue(code.markerRanges.isEmpty)
    }

    func testOutlineUsesParsedLabelsAndUTF16Ranges() throws {
        let text = "前文 😀\n\n# 中文 **bold** [link](https://example.com) `code` ![alt](x.png)\n\nSecond *title*\n------------\n\n```\n# not a heading\n```\n\n> ### 引用"
        let headings = MarkdownPresentationParser.parse(text).headings
        XCTAssertEqual(headings.map(\.level), [1, 2, 3])
        XCTAssertEqual(headings.map(\.title), ["中文 bold link code alt", "Second title", "引用"])
        XCTAssertTrue((text as NSString).substring(with: headings[0].range).hasPrefix("# 中文"))
        XCTAssertTrue((text as NSString).substring(with: headings[1].range).hasPrefix("Second *title*"))
        XCTAssertTrue((text as NSString).substring(with: headings[2].range).contains("### 引用"))
    }


    func testOutlineCanNavigateToHeadingContainingTabs() throws {
        let text = "前文 😀\n\n# tab\t**bold**"
        let heading = try XCTUnwrap(MarkdownPresentationParser.parse(text).headings.first)
        XCTAssertEqual(heading.title, "tab bold")
        XCTAssertEqual(heading.range.location, ("前文 😀\n\n" as NSString).length)
    }

    func testStandaloneImagesUseSourceUTF16Ranges() throws {
        let text = "前文 😀\r\n\r\n![图](images/a.png \"title\")\r\n\r\ntext ![x](b.png)"
        let images = MarkdownPresentationParser.parse(text).images
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image.range, (text as NSString).range(of: "![图](images/a.png \"title\")"))
        XCTAssertEqual(image.paragraphRange, image.range)
        XCTAssertEqual(image.url, "images/a.png")
        XCTAssertEqual(image.alt, "图")
        XCTAssertEqual(image.title, "title")
    }

    func testImagesInCodeAndTablesAreNotStandalone() {
        let text = "`![x](a.png)`\n\n| img |\n| --- |\n| ![x](a.png) |\n\n![x](data:image/png;base64,AA==)"
        let images = MarkdownPresentationParser.parse(text).images
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.url, "data:image/png;base64,AA==")
    }
    func testImageInTaskItemRemainsSource() {
        let source = "- [ ] ![a](data:image/png;base64,AA==)"
        let presentation = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(presentation.taskCheckboxes.count, 1)
        XCTAssertTrue(presentation.images.isEmpty)
        XCTAssertEqual(MarkdownPresentationParser.parse("![a](data:image/png;base64,AA==)").images.count, 1)
    }

}

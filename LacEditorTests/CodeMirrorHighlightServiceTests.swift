import Foundation
import XCTest
@testable import LacEditor

final class MarkdownLanguageHighlightServiceTests: XCTestCase {
    func testBundledModesProduceUTF16Ranges() throws {
        for (name, source) in [("go", "package main\nfunc main() { println(\"中😀\") }\n"),
                               ("java", "class Main { int n = 42; }\n"),
                               ("ruby", "def value\n  42\nend\n"),
                               ("react", "const App = () => <div>hello</div>;\n")] {
            let raw = source as NSString
            let tokens = try XCTUnwrap(MarkdownLanguageHighlightService.tokens(in: source, language: name, isCancelled: { false }), name)
            XCTAssertFalse(tokens.isEmpty, name)
            XCTAssertTrue(tokens.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= raw.length }, name)
        }
    }

    func testUnknownCancellationAndStalledModeReturnNoResult() {
        XCTAssertNil(MarkdownLanguageHighlightService.tokens(in: "value", language: "not-a-language", isCancelled: { false }))
        XCTAssertNil(MarkdownLanguageHighlightService.tokens(in: "package main", language: "go", isCancelled: { true }))
        XCTAssertNil(MarkdownLanguageHighlightService.tokens(in: "#", language: "ceylon", isCancelled: { false }))
    }

    func testAdditionalBundledLanguagesProduceTokens() throws {
        let examples = [
            ("abap", "REPORT zdemo.\nWRITE: / 'Hello'.\n"),
            ("elixir", "defmodule Demo do\n  def hello, do: :ok\nend\n"),
            ("glsl", "void main() { gl_FragColor = vec4(1.0); }\n"),
            ("htaccess", "<Directory /var/www>\n  Require all granted\n</Directory>\n"),
            ("makefile", "all:\n\t@echo hello\n"),
            ("nim", "proc hello() = echo \"hi\"\n"),
            ("stata", "display \"hello\"\n"),
            ("svelte", "<script>\nlet name = \"中😀\";\n</script>\n<p>Hello {name}</p>\n"),
            ("yara", "rule example { strings: $a = \"hello\" condition: $a }\n"),
            ("v", "module main\nfn main() { println(\"中😀\") }\n"),
            ("solidity", "pragma solidity ^0.8.0;\ncontract Demo { function f() public pure returns (uint) { return 1; } }\n")
        ]
        for (name, text) in examples {
            let tokens = try XCTUnwrap(MarkdownLanguageHighlightService.tokens(in: text, language: name, isCancelled: { false }), name)
            XCTAssertFalse(tokens.isEmpty, name)
        }
        let escaped = "proc hello() = echo \"中😀 & < > ' \"\n"
        XCTAssertNotNil(MarkdownLanguageHighlightService.tokens(in: escaped, language: "nim", isCancelled: { false }))
        var checks = 0
        XCTAssertNil(MarkdownLanguageHighlightService.tokens(in: String(repeating: "package main\n", count: 100), language: "go", isCancelled: {
            checks += 1
            return checks > 10
        }))
    }

    func testSolidityPreservesClassAndFunctionTokenKinds() throws {
        let source = "pragma solidity ^0.8.0; contract Demo { function f() public {} }"
        let raw = source as NSString
        let tokens = try XCTUnwrap(MarkdownLanguageHighlightService.tokens(in: source, language: "solidity", isCancelled: { false }))
        XCTAssertTrue(tokens.contains { $0.kind == .typeName && raw.substring(with: $0.range) == "Demo" })
        XCTAssertTrue(tokens.contains { $0.kind == .function && raw.substring(with: $0.range) == "f" })
    }

    func testSvelteHighlightsMarkupAndEmbeddedJavaScript() throws {
        let source = "<script>\nlet name = \"中😀\";\n</script>\n<p>Hello {name}</p>\n"
        let raw = source as NSString
        let tokens = try XCTUnwrap(MarkdownLanguageHighlightService.tokens(in: source, language: "svelte", isCancelled: { false }))
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && raw.substring(with: $0.range) == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .string && raw.substring(with: $0.range) == "\"中😀\"" })
        XCTAssertTrue(tokens.contains { $0.kind == .markup && raw.substring(with: $0.range) == "p" })
    }

    func testCodeBlockMapsBundledLanguageThroughCRLF() throws {
        let raw = "package main\r\nfunc main() { println(\"😀\") }\r\n"
        let literal = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(rawBody: raw, sourceLocation: 5,
            literal: literal, info: "go", visible: NSRange(location: 5, length: (raw as NSString).length)))
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.allSatisfy { $0.range.location >= 5 && NSMaxRange($0.range) <= 5 + (raw as NSString).length })
    }
}

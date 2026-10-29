import Foundation
import XCTest
@testable import LacEditor

// The fixture includes excerpts from CodeMirror 5.65.21 demos (MIT; see Resources/CodeMirror/LICENSE).
final class CodeMirrorLanguageMatrixTests: XCTestCase {
    private struct Example: Decodable {
        let name: String
        let aliases: [String]
        let example: String
    }

    func testOfficialMappedNamesAndAliasesHaveHighlightedExamples() throws {
        #if SWIFT_PACKAGE
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "typora-code-languages", withExtension: "json", subdirectory: "Fixtures"))
        #else
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/typora-code-languages.json")
        #endif
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: fixture))
        XCTAssertEqual(examples.count, 115)
        for example in examples {
            for name in [example.name] + example.aliases {
                let tokens = try XCTUnwrap(MarkdownLanguageHighlightService.tokens(in: example.example, language: name.uppercased(), isCancelled: { false }), name)
                XCTAssertFalse(tokens.isEmpty, name)
            }
        }
    }
}

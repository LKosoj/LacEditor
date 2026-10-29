import Foundation
import XCTest
@testable import LacEditor

final class MarkdownNativeMermaidParserTests: XCTestCase {
    func testClosedTopLevelDiagramsUseCmarkAndUTF16Ranges() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = ["😀 before", "", "```mermaid", "flowchart TD", "A --> B", "```", "", "```swift", "let x = 1", "```", "", "```mermaid", "unclosed"].joined(separator: newline)
            let parsed = MarkdownPresentationParser.parse(source)
            XCTAssertEqual(parsed.diagrams.count, 1)
            let diagram = try XCTUnwrap(parsed.diagrams.first)
            let expected = ["```mermaid", "flowchart TD", "A --> B", "```"].joined(separator: newline)
            XCTAssertEqual((source as NSString).substring(with: diagram.range), expected)
            XCTAssertEqual(diagram.source, "flowchart TD\nA --> B\n")
        }
    }
}

import XCTest
@testable import LacEditor

final class MindMapAIParsingTests: XCTestCase {
    func testParseMapValid() throws {
        let map = try MindMapAIService.parseMap(#"{"title":"Тема","nodes":[{"title":"A","children":[{"title":"A1"}]},{"title":"B"}]}"#)
        XCTAssertEqual(map.title, "Тема")
        XCTAssertEqual(MindMapAIService.nodeCount(map), 3)
    }

    func testParseMapFencedJSON() throws {
        let map = try MindMapAIService.parseMap("```json\n{\"title\":\"T\",\"nodes\":[{\"title\":\"思考\"}]}\n```")
        XCTAssertEqual(map.nodes.first?.title, "思考")
    }

    func testParseMapRejectsBadInput() {
        XCTAssertThrowsError(try MindMapAIService.parseMap("не JSON"))
        XCTAssertThrowsError(try MindMapAIService.parseMap(#"{"title":"T","nodes":[]}"#))
        XCTAssertThrowsError(try MindMapAIService.parseMap(#"{"title":"T","nodes":[{"title":"a\nb"}]}"#))
        let long = String(repeating: "x", count: MindMapAIService.maxTitleLength + 1)
        XCTAssertThrowsError(try MindMapAIService.parseMap(#"{"title":"T","nodes":[{"title":"\#(long)"}]}"#))
    }

    func testParseMapDepthAndCountLimits() {
        var deep = #"{"title":"z"}"#
        for _ in 0..<(MindMapAIService.maxDepth + 1) { deep = #"{"title":"n","children":[\#(deep)]}"# }
        XCTAssertThrowsError(try MindMapAIService.parseMap(#"{"title":"T","nodes":[\#(deep)]}"#))
        let many = (0...MindMapAIService.maxNodes).map { #"{"title":"n\#($0)"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try MindMapAIService.parseMap(#"{"title":"T","nodes":[\#(many)]}"#))
    }

    func testNodeAtMaxDepthWithEmptyChildrenIsValid() throws {
        var json = #"{"title":"n","children":[]}"#
        for _ in 1..<MindMapAIService.maxDepth { json = #"{"title":"n","children":[\#(json)]}"# }
        let map = try MindMapAIService.parseMap(#"{"title":"T","nodes":[\#(json)]}"#)
        XCTAssertEqual(MindMapAIService.nodeCount(map), MindMapAIService.maxDepth)
    }

    func testMarkerPrefixIsStripped() throws {
        let map = try MindMapAIService.parseMap(###"{"title":"","nodes":[{"title":"## - Заголовок"}]}"###)
        XCTAssertEqual(map.nodes.first?.title, "Заголовок")
        XCTAssertTrue(MindMapAIService.markdown(for: map, fallbackTitle: "Запас").hasPrefix("# Запас\n"))
    }

    func testParseIdeasDedupAndLimit() throws {
        let many = (0..<20).map { "\"idea \($0)\"" }.joined(separator: ",")
        let ideas = try MindMapAIService.parseIdeas(#"{"ideas":["Old","new","NEW"," old ",\#(many)]}"#, existing: ["old"])
        XCTAssertEqual(ideas.first, "new")
        XCTAssertFalse(ideas.contains { $0.lowercased() == "old" })
        XCTAssertEqual(ideas.count, MindMapAIService.maxIdeas)
        XCTAssertThrowsError(try MindMapAIService.parseIdeas("[]", existing: []))
    }

    func testInstructionsContainLanguage() {
        for code in ["ru", "en", "zh"] {
            XCTAssertTrue(MindMapAIService.buildInstructions(language: code).contains("(\(code))"))
            XCTAssertTrue(MindMapAIService.expandInstructions(language: code).contains("(\(code))"))
        }
        XCTAssertEqual(MindMapAIService.maxSubtreeBytes, 50 * 1024)
    }
}

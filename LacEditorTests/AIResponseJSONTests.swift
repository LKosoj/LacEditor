import Foundation
import XCTest
@testable import LacEditor

final class AIResponseJSONTests: XCTestCase {
    func testUnwrapsJSONFence() throws {
        for response in ["```json\n{\"a\":1}\n```", "```\n{\"a\":1}\n```", "```json\r\n{\"a\":1}\r\n```", "  \n```JSON\n{\"a\":1}\n```  \n", "```json {\"a\":1} ```"] {
            XCTAssertEqual(try AIResponseJSON.object(response)["a"] as? Int, 1, response)
        }
    }

    func testPlainJSONUnchanged() throws {
        XCTAssertEqual(AIResponseJSON.unwrap("  {\"a\":1}\n"), "{\"a\":1}")
        XCTAssertEqual(try AIResponseJSON.object("{\"a\":1}")["a"] as? Int, 1)
    }

    func testUnclosedFenceIsInvalid() {
        XCTAssertThrowsError(try AIResponseJSON.object("```json\n{\"a\":1}"))
        XCTAssertThrowsError(try AIResponseJSON.object("not JSON"))
        XCTAssertThrowsError(try AIResponseJSON.object("[1]"))
    }

    func testBacktickInsideStringKept() throws {
        let value = try AIResponseJSON.object("```json\n{\"a\":\"x ``` y\"}\n```")
        XCTAssertEqual(value["a"] as? String, "x ``` y")
    }
}

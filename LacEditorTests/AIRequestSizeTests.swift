import Foundation
import XCTest
@testable import LacEditor

final class AIRequestSizeTests: XCTestCase {
    func testBytesAreCountedAfterMediaSanitizing() {
        let media = "data:image/png;base64," + String(repeating: "A", count: 200 * 1024)
        XCTAssertEqual(AIRequestSize.bytes("x " + media), AIRequestSize.bytes("x [media omitted]"))
        XCTAssertLessThan(AIRequestSize.bytes(media), AIRequestSize.threshold)
    }

    func testBytesAreUTF8() {
        XCTAssertEqual(AIRequestSize.bytes("中"), 3)
        XCTAssertEqual(AIRequestSize.bytes("😀"), 4)
        XCTAssertEqual(AIRequestSize.bytes("a", "中"), 4)
    }

    func testThresholdBoundary() {
        XCTAssertEqual(AIRequestSize.threshold, 51_200)
        XCTAssertFalse(AIRequestSize.bytes(String(repeating: "a", count: 51_200)) > AIRequestSize.threshold)
        XCTAssertTrue(AIRequestSize.bytes(String(repeating: "a", count: 51_201)) > AIRequestSize.threshold)
    }

    func testTextFormat() {
        // Единица измерения зависит от локали, поэтому сверяем только число
        let small = AIRequestSize.text(2048)
        XCTAssertTrue(small.hasPrefix("2"))
        XCTAssertTrue(small.count > 1)
        XCTAssertTrue(AIRequestSize.text(AIRequestSize.threshold).hasPrefix("50"))
        XCTAssertTrue(AIRequestSize.text(AIRequestSize.threshold + 1024).hasPrefix("51"))
    }
}

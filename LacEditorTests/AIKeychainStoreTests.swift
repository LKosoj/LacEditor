import Foundation
import XCTest
@testable import LacEditor

final class AIKeychainStoreTests: XCTestCase {
    func testKeysAreSeparatedByEnvironmentRoleAndAddress() throws {
        let namespace = "LacEditor-test-\(UUID().uuidString)"
        let first = AIKeychainStore(namespace: namespace)
        let second = AIKeychainStore(namespace: namespace + "-other")
        let url = "https://example.com/v1"
        let otherURL = "https://other.example.com/v1"
        defer {
            try? first.delete(for: .text, baseURL: url)
            try? first.delete(for: .text, baseURL: otherURL)
            try? first.delete(for: .image, baseURL: url)
            try? first.delete(for: .ocr, baseURL: url)
            try? first.delete(for: .audio, baseURL: url)
            try? second.delete(for: .text, baseURL: url)
        }
        try first.save("first", for: .text, baseURL: url)
        XCTAssertEqual(try first.load(for: .text, baseURL: "HTTPS://EXAMPLE.COM:443/v1/"), "first")
        XCTAssertNil(try first.load(for: .text, baseURL: otherURL))
        XCTAssertNil(try first.load(for: .image, baseURL: url))
        XCTAssertNil(try second.load(for: .text, baseURL: url))
        try first.save("ocr", for: .ocr, baseURL: url)
        try first.save("audio", for: .audio, baseURL: url)
        XCTAssertEqual(try first.load(for: .ocr, baseURL: url), "ocr")
        XCTAssertEqual(try first.load(for: .audio, baseURL: url), "audio")
        XCTAssertNil(try first.load(for: .ocr, baseURL: otherURL))
        XCTAssertNil(try second.load(for: .audio, baseURL: url))
        XCTAssertEqual(try first.load(for: .text, baseURL: url), "first")
        try first.save("replacement", for: .text, baseURL: url)
        XCTAssertEqual(try first.load(for: .text, baseURL: url), "replacement")
        try first.delete(for: .text, baseURL: url)
        XCTAssertNil(try first.load(for: .text, baseURL: url))
    }
}

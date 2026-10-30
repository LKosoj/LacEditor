import XCTest
@testable import LacEditor

@MainActor
final class LineEndingTests: XCTestCase {
    func testDetectCountsEachKind() throws {
        XCTAssertEqual(try XCTUnwrap(LineEndingService.detect(in: "")).total, 0)
        XCTAssertEqual(try XCTUnwrap(LineEndingService.detect(in: "a\nb")), LineEndingSummary(lf: 1, crlf: 0, cr: 0))
        XCTAssertEqual(try XCTUnwrap(LineEndingService.detect(in: "a\r\nb\r\n")), LineEndingSummary(lf: 0, crlf: 2, cr: 0))
        XCTAssertEqual(try XCTUnwrap(LineEndingService.detect(in: "a\rb")), LineEndingSummary(lf: 0, crlf: 0, cr: 1))
        let mixed = try XCTUnwrap(LineEndingService.detect(in: "a\r\nb\nc\r"))
        XCTAssertEqual(mixed, LineEndingSummary(lf: 1, crlf: 1, cr: 1))
        XCTAssertTrue(mixed.isMixed)
        XCTAssertNil(mixed.uniform)
        XCTAssertEqual(try XCTUnwrap(LineEndingService.detect(in: "\r\r\n\n")), LineEndingSummary(lf: 1, crlf: 1, cr: 1))
    }

    func testUnicodeSeparatorsAndTextDoNotAffectCounts() throws {
        let summary = try XCTUnwrap(LineEndingService.detect(in: "中文\u{2028}😀\u{2029}x\u{85}y\n"))
        XCTAssertEqual(summary, LineEndingSummary(lf: 1, crlf: 0, cr: 0))
        XCTAssertEqual(summary.uniform, .lf)
    }

    func testConvertToEveryKind() {
        let source = "a\r\nb\nc\rd"
        for target in LineEnding.allCases {
            let expected = "a\(target.sequence)b\(target.sequence)c\(target.sequence)d"
            XCTAssertEqual(LineEndingService.convert(source, to: target), expected)
        }
    }

    func testConvertReturnsNilWhenNothingChanges() {
        XCTAssertNil(LineEndingService.convert("a\nb\n", to: .lf))
        XCTAssertNil(LineEndingService.convert("a\r\nb", to: .crlf))
        XCTAssertNil(LineEndingService.convert("без переносов", to: .crlf))
        XCTAssertNil(LineEndingService.convert("", to: .lf))
    }

    func testConvertKeepsOtherContent() {
        let converted = LineEndingService.convert("中文😀\r\n\u{2028}x\n", to: .cr)
        XCTAssertEqual(converted, "中文😀\r\u{2028}x\r")
        XCTAssertEqual(LineEndingService.convert("\n", to: .crlf), "\r\n")
    }

    func testConvertCancellation() {
        XCTAssertNil(LineEndingService.convert("a\r\nb", to: .lf, isCancelled: { true }))
        XCTAssertNil(LineEndingService.detect(in: "a\nb", isCancelled: { true }))
    }

    func testMappedLocation() {
        let text = "😀a\r\nb\nc" as NSString   // UTF-16: эмодзи 0–1, a 2, CR 3, LF 4, b 5, LF 6, c 7
        XCTAssertEqual(LineEndingService.mappedLocation(0, in: text, to: .lf), 0)
        XCTAssertEqual(LineEndingService.mappedLocation(3, in: text, to: .lf), 3)
        // Между CR и LF — начало переноса.
        XCTAssertEqual(LineEndingService.mappedLocation(4, in: text, to: .lf), 3)
        XCTAssertEqual(LineEndingService.mappedLocation(5, in: text, to: .lf), 4)
        XCTAssertEqual(LineEndingService.mappedLocation(text.length, in: text, to: .lf), text.length - 1)
        XCTAssertEqual(LineEndingService.mappedLocation(text.length, in: text, to: .crlf), text.length + 1)
        XCTAssertEqual(LineEndingService.mappedLocation(text.length, in: text, to: .cr), text.length - 1)
        let converted = LineEndingService.convert(text as String, to: .crlf) ?? ""
        XCTAssertLessThanOrEqual(LineEndingService.mappedLocation(text.length, in: text, to: .crlf), (converted as NSString).length)
    }

    func testLargeMixedTextDetectsAndCancels() throws {
        let line = "строка 中文 😀 line\r\nвторая\nтретья\r"
        let text = String(repeating: line, count: 5 * 1_024 * 1_024 / line.utf8.count + 1)
        let summary = try XCTUnwrap(LineEndingService.detect(in: text))
        XCTAssertEqual(summary.lf, summary.crlf)
        XCTAssertEqual(summary.cr, summary.lf)
        XCTAssertGreaterThan(summary.total, 0)
        XCTAssertNil(LineEndingService.detect(in: text, isCancelled: { true }))
    }

    func testDocumentDetectsLineEndings() {
        let document = EditorDocument(text: "a\r\nb")
        XCTAssertEqual(document.lineEndings?.uniform, .crlf)
    }

    func testLargeDocumentDetectsLatestTextOnly() async throws {
        let document = EditorDocument(text: String(repeating: "a\r\n", count: 40_000))
        let expectation = expectation(description: "line endings")
        let cancellable = document.$lineEndings.sink { summary in
            if summary?.uniform == .lf { expectation.fulfill() }
        }
        document.text = String(repeating: "a\r\n", count: 40_000)
        document.text = String(repeating: "a\n", count: 40_000)
        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(document.lineEndings?.lf, 40_000)
        cancellable.cancel()
    }
}

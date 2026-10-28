import XCTest
@testable import LacEditor

final class DocumentProvenanceTests: XCTestCase {
    func testReplacingAcrossSourcesAndUndoUnknown() {
        let history = DocumentProvenance()
        history.configure(enabled: true, length: 4)
        history.record(editedRange: NSRange(location: 2, length: 0), replacementLength: 2, source: .generated)
        XCTAssertEqual(history.fragments.map(\.source), [.unknown, .generated, .unknown])
        history.record(editedRange: NSRange(location: 1, length: 4), replacementLength: 1, source: .typed)
        XCTAssertEqual(history.fragments.map(\.range), [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)])
        history.record(editedRange: NSRange(location: 1, length: 1), replacementLength: 4, source: .unknown)
        XCTAssertEqual(history.fragments, [.init(range: NSRange(location: 0, length: 6), source: .unknown)])
    }

    func testUTF16LengthsAndDisableForgetHistory() {
        let history = DocumentProvenance()
        history.configure(enabled: true, length: 0)
        history.record(editedRange: NSRange(location: 0, length: 0), replacementLength: ("😀中" as NSString).length, source: .pasted)
        XCTAssertEqual(history.fragments.first?.range.length, 3)
        history.configure(enabled: false, length: 3)
        XCTAssertTrue(history.fragments.isEmpty)
        history.configure(enabled: true, length: 3)
        XCTAssertEqual(history.fragments.first?.source, .unknown)
    }
}

import XCTest
@testable import LacEditor

final class LaceditURLTests: XCTestCase {
    private func request(_ text: String) -> LaceditRequest? {
        URL(string: text).flatMap(LaceditRequest.init(url:))
    }

    private func inbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOpenURLWithLineAndColumnDecodesPath() {
        XCTAssertEqual(
            request("laceditor://open?path=%2Ftmp%2F%D0%B7%D0%B0%D0%BC%D0%B5%D1%82%D0%BA%D0%B8%20a.md&line=12&column=5"),
            .open(path: "/tmp/заметки a.md", line: 12, column: 5)
        )
    }

    func testOpenURLWithoutPositionsHasNilLineAndColumn() {
        XCTAssertEqual(request("laceditor://open?path=%2Ftmp%2Fa.md"), .open(path: "/tmp/a.md", line: nil, column: nil))
    }

    func testOpenURLRejectsRelativeEmptyAndParentPaths() {
        for text in ["laceditor://open?path=a.md", "laceditor://open?path=", "laceditor://open?path=/tmp/../etc/passwd",
                     "laceditor://open?path=/tmp/%2E%2E/x", "laceditor://open?path=/a%00b", "laceditor://open"] {
            XCTAssertNil(request(text), text)
        }
        XCTAssertNotNil(request("laceditor://open?path=/tmp/a..b"))
        XCTAssertNotNil(request("laceditor://open?path=/tmp/..hidden"))
    }

    func testOpenURLRejectsBadNumbers() {
        for value in ["0", "-1", "%2B1", "abc", "1.5", "1234567890", ""] {
            XCTAssertNil(request("laceditor://open?path=/x&line=\(value)"), value)
        }
        XCTAssertNil(request("laceditor://open?path=/x&column=3"))
        XCTAssertNil(request("laceditor://open?path=/x&line=1&line=2"))
        XCTAssertNotNil(request("laceditor://open?path=/x&line=1&column=999999999"))
    }

    func testRejectsForeignSchemeHostAndExtraParts() {
        for text in ["http://open?path=/x", "laceditor://delete?path=/x", "laceditor://open/extra?path=/x",
                     "laceditor://u@open?path=/x", "laceditor://open?path=/x#frag"] {
            XCTAssertNil(request(text), text)
        }
        XCTAssertNotNil(request("LACEDITOR://open?path=/x"))
    }

    func testStdinURLRequiresUUIDAndNothingElse() {
        let id = UUID()
        XCTAssertEqual(request("laceditor://stdin?id=\(id.uuidString)"), .stdin(id: id))
        XCTAssertNil(request("laceditor://stdin?id=../x"))
        XCTAssertNil(request("laceditor://stdin?id=1234"))
        XCTAssertNil(request("laceditor://stdin"))
        XCTAssertNil(request("laceditor://stdin?id=\(id.uuidString)&path=/x"))
    }

    func testInstallCommandQuotesScriptPath() {
        let command = LaceditInstall.command(scriptPath: "/Applications/My App/It's.app/Contents/Resources/lacedit")
        XCTAssertTrue(command.hasPrefix("sudo mkdir -p /usr/local/bin && sudo ln -sf '"))
        XCTAssertTrue(command.contains("'/Applications/My App/It'\\''s.app/Contents/Resources/lacedit'"))
        XCTAssertTrue(command.hasSuffix(" /usr/local/bin/lacedit"))
    }

    func testInboxReadsAndDeletesFile() throws {
        let directory = try inbox(), id = UUID()
        let file = directory.appendingPathComponent(id.uuidString + ".txt")
        try "привет 中😀".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(LaceditStdinInbox.take(id: id, directory: directory), "привет 中😀")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInboxDeletesInvalidUTF8AndReturnsNil() throws {
        let directory = try inbox(), id = UUID()
        let file = directory.appendingPathComponent(id.uuidString + ".txt")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: file)
        XCTAssertNil(LaceditStdinInbox.take(id: id, directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInboxRejectsOversizeAndDeletes() throws {
        let directory = try inbox(), id = UUID()
        let file = directory.appendingPathComponent(id.uuidString + ".txt")
        try Data(repeating: 0x61, count: 11).write(to: file)
        XCTAssertNil(LaceditStdinInbox.take(id: id, directory: directory, limit: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInboxRejectsSymlinkAndKeepsTarget() throws {
        let directory = try inbox(), id = UUID()
        let target = directory.appendingPathComponent("target.txt")
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent(id.uuidString + ".txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(LaceditStdinInbox.take(id: id, directory: directory))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "secret")
    }

    func testInboxMissingFileReturnsNil() throws {
        XCTAssertNil(LaceditStdinInbox.take(id: UUID(), directory: try inbox()))
    }
}

import XCTest
@testable import LacEditor

final class CriticMarkupExportTests: XCTestCase {
    private let syntax = MarkdownSyntaxOptions()

    func testResolvedAcceptAndReject() {
        let text = "a {++new++}{--old--} {~~x~>y~~} `{++c++}`"
        XCTAssertEqual(CriticMarkupPandoc.resolved(text, accept: true, syntax: syntax), "a new y `{++c++}`")
        XCTAssertEqual(CriticMarkupPandoc.resolved(text, accept: false, syntax: syntax), "a old x `{++c++}`")
    }

    func testSourceKeepsMarkupWhenTrackedUnsupported() {
        let text = "a {++b++}"
        let source = CriticMarkupPandoc.source(for: text, mode: .tracked, supportsTracked: false, syntax: syntax)
        XCTAssertEqual(source.text, text)
        XCTAssertNil(source.prefix)
    }

    func testTokenizePrefixIsNotInText() throws {
        let tokenized = try XCTUnwrap(CriticMarkupPandoc.tokenize("{++a++} {>>c<<}", syntax: syntax))
        XCTAssertTrue(tokenized.text.contains(tokenized.prefix + "I0Z"))
        XCTAssertTrue(tokenized.text.contains(tokenized.prefix + "c1Z"))
        XCTAssertFalse(tokenized.text.contains("{++"))
        XCTAssertNil(CriticMarkupPandoc.tokenize("plain", syntax: syntax))
    }

    private func str(_ text: String) -> [String: Any] { ["t": "Str", "c": text] }

    private func classes(_ node: Any) -> [String] {
        guard let object = node as? [String: Any], object["t"] as? String == "Span",
              let content = object["c"] as? [Any], let attributes = content.first as? [Any] else { return [] }
        return attributes[1] as? [String] ?? []
    }

    func testTransformBuildsSpans() {
        let p = "LACCRITICabc"
        let inlinesIn: [Any] = [str("\(p)I0Zadd\(p)i0Z"), ["t": "Space"] as [String: Any], str("\(p)H1Zmark\(p)h1Z"), str("\(p)C2Znote\(p)c2Z")]
        let para: [String: Any] = ["t": "Para", "c": inlinesIn]
        var json: Any = [para]
        CriticMarkupPandoc.transform(json: &json, prefix: p, author: "A", date: "2026-01-01T00:00:00Z")
        let result = (json as! [Any])[0] as! [String: Any]
        let inlines = result["c"] as! [Any]
        XCTAssertEqual(classes(inlines[0]), ["insertion"])
        XCTAssertEqual(inlines.map { classes($0) }.filter { !$0.isEmpty }.map { $0[0] }, ["insertion", "comment-start", "mark", "comment-end"])
    }

    func testSubstitutionGivesTwoIds() throws {
        let tokenized = try XCTUnwrap(CriticMarkupPandoc.tokenize("{~~x~>y~~}", syntax: syntax))
        let para: [String: Any] = ["t": "Para", "c": [str(tokenized.text)] as [Any]]
        var json: Any = [para]
        CriticMarkupPandoc.transform(json: &json, prefix: tokenized.prefix, author: "A", date: "d")
        let inlines = ((json as! [Any])[0] as! [String: Any])["c"] as! [Any]
        XCTAssertEqual(inlines.map { classes($0) }, [["deletion"], ["insertion"]])
    }

    func testUnpairedTokensAreDroppedKeepingText() {
        let p = "LACCRITICabc"
        let para: [String: Any] = ["t": "Para", "c": [str("\(p)I0Zkeep")] as [Any]]
        var json: Any = [para]
        CriticMarkupPandoc.transform(json: &json, prefix: p, author: "A", date: "d")
        let inlines = ((json as! [Any])[0] as! [String: Any])["c"] as! [Any]
        XCTAssertEqual((inlines[0] as! [String: Any])["c"] as? String, "keep")
    }

    @MainActor
    func testAccessoryDefaultsToCleanWhenNothingStored() {
        UserDefaults.standard.removeObject(forKey: CriticMarkupExportAccessory.defaultsKey)
        XCTAssertEqual(CriticMarkupExportAccessory.lastChoice(), .clean)
    }

    func testRenderModeMapping() {
        XCTAssertEqual(CriticMarkupExportMode.clean.renderMode, .result)
        XCTAssertEqual(CriticMarkupExportMode.original.renderMode, .original)
        XCTAssertEqual(CriticMarkupExportMode.tracked.renderMode, .show)
        XCTAssertTrue(PandocExportFormat.docx.supportsTrackedChanges)
    }

    func testPrefixChangesWhenAlreadyInText() throws {
        let tokenized = try XCTUnwrap(CriticMarkupPandoc.tokenize("{++a++}", syntax: syntax))
        let again = try XCTUnwrap(CriticMarkupPandoc.tokenize("{++a++} " + tokenized.prefix, syntax: syntax))
        XCTAssertFalse("{++a++} ".contains(again.prefix))
        XCTAssertNotEqual(again.prefix, tokenized.prefix)
    }

    func testHeaderIDLosesTokens() {
        let p = "LACCRITICABC"
        let id = p.lowercased() + "i0z" + "title"
        let attributes: [Any] = [id, [String](), [[String]]()]
        let inlines: [Any] = [str("\(p)I0Ztitle\(p)i0Z")]
        let header: [String: Any] = ["t": "Header", "c": [1, attributes, inlines] as [Any]]
        var json: Any = [header]
        CriticMarkupPandoc.transform(json: &json, prefix: p, author: "A", date: "d")
        let content = ((json as! [Any])[0] as! [String: Any])["c"] as! [Any]
        XCTAssertEqual((content[1] as! [Any])[0] as? String, "title")
    }

    private func docxEntries(_ file: URL, _ entry: String) throws -> String {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard FileManager.default.isExecutableFile(atPath: unzip.path) else { throw XCTSkip("unzip недоступен") }
        let process = Process()
        process.executableURL = unzip
        process.arguments = ["-p", file.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testPandocDocxByMode() throws {
        guard let executable = PandocExportService.findPandoc() else { throw XCTSkip("pandoc недоступен") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Text {++added++} and {--removed--} with {==mark==}{>>a note<<}."
        for mode in CriticMarkupExportMode.allCases {
            let result = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("\(mode.rawValue).docx"),
                                                         format: .docx, title: "T", executable: executable, critic: mode)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let document = try docxEntries(result.preparedURL, "word/document.xml")
            let comments = try docxEntries(result.preparedURL, "word/comments.xml")
            if mode == .tracked {
                XCTAssertTrue(document.contains("<w:ins "))
                XCTAssertTrue(document.contains("<w:del "))
                XCTAssertTrue(comments.contains("a note"))
            } else {
                XCTAssertFalse(document.contains("<w:ins "))
                XCTAssertFalse(document.contains("<w:del "))
                XCTAssertFalse(comments.contains("a note"))
            }
        }
    }
}

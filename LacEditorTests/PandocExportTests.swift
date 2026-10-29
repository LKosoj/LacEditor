import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class PandocExportTests: XCTestCase {
    private func unzip(_ archive: URL, _ name: String) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return bytes
    }

    func testMathMarkersRestoreAdjacentTextAndRejectWrongLocations() throws {
        let source = "前$x$後\n\n$$\ny\n$$"
        let presentation = MarkdownPresentationParser.parse(source)
        let (marked, markers) = try PandocExportService.markedMathSnapshot(source, presentation: presentation, isCancelled: { false })
        XCTAssertEqual(markers.count, 2)
        XCTAssertTrue(marked.contains("前" + markers[0].token + "後"))
        let tree: [String: Any] = ["meta": [:], "blocks": [
            ["t": "Para", "c": [["t": "Str", "c": "前" + markers[0].token + "後"]]],
            ["t": "Para", "c": [["t": "Str", "c": markers[1].token]]]
        ]]
        let restored = try PandocExportService.restoreMath(in: tree, markers: markers, isCancelled: { false })
        let blocks = try XCTUnwrap(restored["blocks"] as? [[String: Any]])
        let first = try XCTUnwrap(blocks[0]["c"] as? [[String: Any]])
        XCTAssertEqual(first.compactMap { $0["t"] as? String }, ["Str", "Math", "Str"])
        XCTAssertEqual(first.first?["c"] as? String, "前")
        XCTAssertEqual(first.last?["c"] as? String, "後")
        let display = try XCTUnwrap((blocks[1]["c"] as? [[String: Any]])?.first?["c"] as? [Any])
        XCTAssertEqual((display[0] as? [String: String])?["t"], "DisplayMath")
        XCTAssertThrowsError(try PandocExportService.restoreMath(in: ["meta": ["title": markers[0].token], "blocks": tree["blocks"]!], markers: markers, isCancelled: { false }))
        XCTAssertThrowsError(try PandocExportService.restoreMath(in: ["meta": [:], "blocks": [["t": "Code", "c": markers[0].token]]], markers: markers, isCancelled: { false }))
        XCTAssertThrowsError(try PandocExportService.restoreMath(in: ["meta": [:], "blocks": [tree["blocks"]!, tree["blocks"]!]], markers: markers, isCancelled: { false }))
    }

    func testPandocExportsConfirmedMathAndPreservesOrdinaryDollars() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "前$x$後 and $a$5 :smile:\n\n> $$\n> y\n> $$\n\n| A |\n|---|\n| $z$ |"
        let standard = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("standard.html"), format: .html, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: standard.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: standard.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("display=\"inline\"") || html.contains("math inline"))
        XCTAssertTrue(html.contains("display=\"block\"") || html.contains("math display"))
        XCTAssertTrue(html.contains("$a$5"))
        XCTAssertTrue(html.contains("😄"))
        let profile = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("profile.html"), profile: .standard(.html), title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: profile.preparedURL.deletingLastPathComponent()) }
        let profileHTML = try String(contentsOf: profile.preparedURL, encoding: .utf8)
        XCTAssertTrue(profileHTML.contains("display=\"inline\"") || profileHTML.contains("math inline"))
        XCTAssertTrue(profileHTML.contains("display=\"block\"") || profileHTML.contains("math display"))
        XCTAssertTrue(profileHTML.contains("$a$5"))
        let disabled = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("disabled.html"), format: .html, title: "Test", executable: executable, syntax: .init(inlineMath: false))
        defer { try? FileManager.default.removeItem(at: disabled.preparedURL.deletingLastPathComponent()) }
        let disabledHTML = try String(contentsOf: disabled.preparedURL, encoding: .utf8)
        XCTAssertTrue(disabledHTML.contains("$x$"))
        XCTAssertTrue(disabledHTML.contains("display=\"block\"") || disabledHTML.contains("math display"))
        XCTAssertEqual(source, "前$x$後 and $a$5 :smile:\n\n> $$\n> y\n> $$\n\n| A |\n|---|\n| $z$ |")
    }

    func testMathMetadataReaderPreservesPandocMetadata() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "---\ntitle: \"Hello $x$ [ref][id]\"\nauthors: [\"$y$\", \"**bold**\"]\n---\n\n[id]: https://example.com\n"
        let metadata = try XCTUnwrap(PandocExportService.originalMathMetadata(source, executable: executable, source: nil, temporary: directory, isCancelled: { false }))
        let title = try XCTUnwrap(metadata["title"] as? [String: Any])
        let nodes = try XCTUnwrap(title["c"] as? [[String: Any]])
        XCTAssertTrue(nodes.contains { $0["t"] as? String == "Math" })
        XCTAssertTrue(nodes.contains { ($0["c"] as? String)?.contains("[ref][id]") == true })
        XCTAssertNil(try PandocExportService.originalMathMetadata("---\ntitle: plain\n---\n", executable: executable, source: nil, temporary: directory, isCancelled: { false }))
    }

    func testExportSyntaxDefaultsKeepPandocAndWebKitBehavior() throws {
        let syntax = MarkdownSyntaxOptions()
        XCTAssertNil(syntax.smartPunctuation)
        XCTAssertNil(syntax.preserveEditingWhitespace)
        XCTAssertNil(syntax.preserveExportSoftBreaks)
        let source = "\"a\"\nb"
        let native = MarkdownRenderer.renderPage(source, darkMode: false, syntax: syntax, forExport: true)
        XCTAssertTrue(native.body.contains("<br"))
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("base.html"), format: .html, title: "Test", executable: executable, syntax: syntax)
        defer { try? FileManager.default.removeItem(at: baseline.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: baseline.preparedURL, encoding: .utf8)
        XCTAssertFalse(html.contains("<br"))
        XCTAssertTrue(html.contains("“a”"))
        let disabled = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("plain.html"), format: .html, title: "Test", executable: executable, syntax: .init(smartPunctuation: false))
        defer { try? FileManager.default.removeItem(at: disabled.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: disabled.preparedURL, encoding: .utf8).contains("\"a\""))
        let changed = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("changed.html"), format: .html, title: "Test", executable: executable, syntax: .init(smartPunctuation: true, preserveExportSoftBreaks: true))
        defer { try? FileManager.default.removeItem(at: changed.preparedURL.deletingLastPathComponent()) }
        let changedHTML = try String(contentsOf: changed.preparedURL, encoding: .utf8)
        XCTAssertTrue(changedHTML.contains("<br"))
        XCTAssertTrue(changedHTML.contains("“a”"))
    }

    func testLooseHeadingChangesOnlyExportSnapshot() throws {
        let source = "###中文😀\r\n\r\n```\n###code\n```\n"
        let strict = try PandocExportService.markedExportSnapshot(source, syntax: .init(), includeTOC: false, isCancelled: { false })
        XCTAssertEqual(strict.text, source)
        let loose = try PandocExportService.markedExportSnapshot(source, syntax: .init(strictMode: false), includeTOC: false, isCancelled: { false })
        XCTAssertEqual(loose.text, "### 中文😀\r\n\r\n```\n###code\n```\n")
    }

    func testLooseListIndentChangesOnlyExportSnapshot() throws {
        let source = "1. aaa\r\n\r\n  bbb\r\n\r\n10. aaa\r\n  1. ccc\r\n"
        let strict = try PandocExportService.markedExportSnapshot(source, syntax: .init(), includeTOC: false, isCancelled: { false })
        XCTAssertEqual(strict.text, source)
        let loose = try PandocExportService.markedExportSnapshot(source, syntax: .init(strictMode: false), includeTOC: false, isCancelled: { false })
        XCTAssertEqual(loose.text, "1. aaa\r\n\r\n   bbb\r\n\r\n10. aaa\r\n    1. ccc\r\n")
        let frontMatter = "---\r\ntitle: 中文😀\r\n---\r\n\r\n10. aaa\r\n  1. ccc\r\n"
        let withFrontMatter = try PandocExportService.markedExportSnapshot(frontMatter, syntax: .init(strictMode: false), includeTOC: false, isCancelled: { false })
        XCTAssertEqual(withFrontMatter.text, "---\r\ntitle: 中文😀\r\n---\r\n\r\n10. aaa\r\n    1. ccc\r\n")
    }

    func testLooseExamplesReachPandocHTML() throws {
        let source = "###Header\n\n1. aaa\n\n  bbb\n\n10. aaa\n  1. ccc\n"
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("loose.html"), format: .html, title: "Test", executable: executable, syntax: .init(strictMode: false))
        defer { try? FileManager.default.removeItem(at: output.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: output.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains(">Header</h3>"))
        XCTAssertTrue(html.contains("<p>bbb</p>"))
        XCTAssertTrue(html.contains("<li>ccc</li>"))
        let preview = MarkdownRenderer.renderPage(source, darkMode: false, syntax: .init(strictMode: false)).body
        XCTAssertEqual(preview.components(separatedBy: "<ol").count - 1, 2)
        XCTAssertEqual(html.components(separatedBy: "<ol").count - 1, 2)
        XCTAssertEqual(source, "###Header\n\n1. aaa\n\n  bbb\n\n10. aaa\n  1. ccc\n")
        let separated = "1. aaa\n\n  bbb\n\n---\n\n10. aaa\n  1. ccc\n"
        let separateOutput = try PandocExportService.prepare(text: separated, source: nil, destination: directory.appendingPathComponent("separated.html"), format: .html, title: "Test", executable: executable, syntax: .init(strictMode: false))
        defer { try? FileManager.default.removeItem(at: separateOutput.preparedURL.deletingLastPathComponent()) }
        let separateHTML = try String(contentsOf: separateOutput.preparedURL, encoding: .utf8)
        let separatePreview = MarkdownRenderer.renderPage(separated, darkMode: false, syntax: .init(strictMode: false)).body
        XCTAssertEqual(separatePreview.components(separatedBy: "<ol").count - 1, 3)
        XCTAssertEqual(separateHTML.components(separatedBy: "<ol").count - 1, 3)
        let differentDelimiter = "1. aaa\n\n  bbb\n\n1) ccc\n"
        let delimiterOutput = try PandocExportService.prepare(text: differentDelimiter, source: nil, destination: directory.appendingPathComponent("delimiter.html"), format: .html, title: "Test", executable: executable, syntax: .init(strictMode: false))
        defer { try? FileManager.default.removeItem(at: delimiterOutput.preparedURL.deletingLastPathComponent()) }
        let delimiterHTML = try String(contentsOf: delimiterOutput.preparedURL, encoding: .utf8)
        let delimiterPreview = MarkdownRenderer.renderPage(differentDelimiter, darkMode: false, syntax: .init(strictMode: false)).body
        XCTAssertEqual(delimiterPreview.components(separatedBy: "<ol").count - 1, 2)
        XCTAssertEqual(delimiterHTML.components(separatedBy: "<ol").count - 1, 2)
    }

    func testPreservedExportSpacesUseConfirmedTextOnly() throws {
        let source = "  lead   text  \nnext\n\n**strong   text** [link  text](https://example.com)\n\n| A |\n|---|\n| cell   text |\n\na &nbsp;   b \\  c\n\n`code   text`"
        let syntax = MarkdownSyntaxOptions(preserveExportWhitespace: true)
        let snapshot = try PandocExportService.markedExportSnapshot(source, syntax: syntax, includeTOC: false, isCancelled: { false })
        let spaces = snapshot.math.filter(\.preservesSpaces).map(\.source)
        XCTAssertTrue(spaces.contains("   "))
        XCTAssertTrue(spaces.contains("  "))
        XCTAssertTrue(snapshot.text.contains("  \nnext"))
        XCTAssertTrue(snapshot.text.contains("`code   text`"))
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try PandocExportService.prepare(text: source, source: nil, destination: directory.appendingPathComponent("spaces.html"), format: .html, title: "Test", executable: executable, syntax: syntax)
        defer { try? FileManager.default.removeItem(at: output.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: output.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("white-space: break-spaces;"))
        XCTAssertTrue(html.contains(">   </span>"))
        XCTAssertTrue(html.contains("code   text"))
        XCTAssertTrue(html.contains("<br"))
        XCTAssertFalse(html.contains("LACMATH"))
        XCTAssertTrue(source.contains("a &nbsp;   b"))
    }
    func testLatexExportPreservesConfirmedSpacesWithoutChangingMath() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "中文   text and $x$ with `code   text`"
        for profile in [false, true] {
            for preserve in [false, true] {
                let destination = directory.appendingPathComponent("out.tex")
                let syntax = MarkdownSyntaxOptions(preserveExportWhitespace: preserve)
                let result = try profile
                    ? PandocExportService.prepare(text: source, source: nil, destination: destination, profile: .standard(.latex), title: "Test", executable: executable, syntax: syntax)
                    : PandocExportService.prepare(text: source, source: nil, destination: destination, format: .latex, title: "Test", executable: executable, syntax: syntax)
                defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
                let latex = try String(contentsOf: result.preparedURL, encoding: .utf8)
                XCTAssertEqual(latex.contains("\\ \\ \\ "), preserve)
                XCTAssertTrue(latex.contains("x")); XCTAssertTrue(latex.contains("code"))
            }
        }
        XCTAssertEqual(source, "中文   text and $x$ with `code   text`")
    }

    func testDOCXAndEPUBContainOriginalSVGBytes() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2' fill='red'/></svg>".utf8)
        let text = "![x](data:image/svg+xml;base64," + svg.base64EncodedString() + ")"
        for format in [PandocExportFormat.docx, .epub] {
            let result = try PandocExportService.prepare(text: text, source: nil, destination: directory.appendingPathComponent("out.\(format.fileExtension)"), format: format, title: "Test", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let list = Process(), listPipe = Pipe()
            list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            list.arguments = ["-Z1", result.preparedURL.path]
            list.standardOutput = listPipe
            try list.run()
            let names = String(decoding: listPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            list.waitUntilExit()
            XCTAssertEqual(list.terminationStatus, 0)
            let name = try XCTUnwrap(names.split(separator: "\n").first(where: { $0.hasSuffix(".svg") }))
            let extract = Process(), pipe = Pipe()
            extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            extract.arguments = ["-p", result.preparedURL.path, String(name)]
            extract.standardOutput = pipe
            try extract.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            extract.waitUntilExit()
            XCTAssertEqual(extract.terminationStatus, 0)
            XCTAssertEqual(bytes, svg)
        }
    }
    func testRootMediaSnapshotUsesConfirmedStandaloneAndNestedSources() throws {
        let document = URL(fileURLWithPath: "/tmp/posts/note.md")
        let source = "---\ntypora-root-url: ../site\n---\n\n<video controls><source src='/one%23a.mp4?download=yes#t=10'><source src='/two.mp4'></video>\n\n<audio src='/sound.mp3'></audio>\n\n<textarea><video src='/hidden.mp4'></video></textarea>\n\n<video src='relative.mp4'></video>\n\n<div><video src='/main.mp4'><source src='/ignored.mp4'></video><audio><source src='/nested.mp3'></audio><template><video src='/inert.mp4'></video></template></div>\n\nbefore <video src='/inline.mp4'></video> after\n\nbefore <video controls> fallback **bold** <em>text</em> <source src='/inline-source.mp4'> </video> after\n\nbefore <video> <em><source src='/nested-wrong-parent.mp4'></em> <source src='/inline-after-nested.mp4'> </video> after\n\nbefore <video src> <source src='/invalid-parent.mp4'> </video> after\n\nbefore <template>\n\n<video src='/inline-inert.mp4'></video>\n\n</template>"
        let result = try PandocExportService.rootMediaSnapshot(source, document: document, isCancelled: { false })
        XCTAssertTrue(result.contains("src='/tmp/site/one%23a.mp4?download=yes#t=10'"))
        XCTAssertTrue(result.contains("src='/tmp/site/two.mp4'"))
        XCTAssertTrue(result.contains("src='/tmp/site/sound.mp3'"))
        XCTAssertTrue(result.contains("<video src='/hidden.mp4'>"))
        XCTAssertTrue(result.contains("src='relative.mp4'"))
        XCTAssertTrue(result.contains("src='/tmp/site/main.mp4'"))
        XCTAssertTrue(result.contains("src='/tmp/site/nested.mp3'"))
        XCTAssertTrue(result.contains("src='/ignored.mp4'"))
        XCTAssertTrue(result.contains("src='/inert.mp4'"))
        XCTAssertTrue(result.contains("src='/tmp/site/inline.mp4'"))
        XCTAssertTrue(result.contains("src='/tmp/site/inline-source.mp4'"))
        XCTAssertTrue(result.contains("src='/nested-wrong-parent.mp4'"))
        XCTAssertTrue(result.contains("src='/tmp/site/inline-after-nested.mp4'"))
        XCTAssertTrue(result.contains("src='/invalid-parent.mp4'"))
        XCTAssertTrue(result.contains("src='/inline-inert.mp4'"))
        let invalid = "---\ninvalid: [\n---\n\n<video src='relative.mp4'></video>"
        XCTAssertEqual(try PandocExportService.rootMediaSnapshot(invalid, document: document, isCancelled: { false }), invalid)
        XCTAssertThrowsError(try PandocExportService.rootMediaSnapshot(invalid.replacingOccurrences(of: "relative.mp4", with: "/absolute.mp4"), document: document, isCancelled: { false }))
    }
    func testRootImagesPreserveOtherASTTargets() throws {
        let text = "---\ntypora-root-url: ../site\n---\n"
        let document = URL(fileURLWithPath: "/tmp/posts/note.md")
        let tree: [String: Any] = ["meta": ["cover": ["t": "MetaInlines", "c": [["t": "Image", "c": [["", [], []], [], ["/cover.png", ""]]]]]], "blocks": [["t": "Para", "c": [
            ["t": "Image", "c": [["", [], []], [], ["/a%23b.png", ""]]],
            ["t": "Image", "c": [["", [], []], [], ["relative.png", ""]]],
            ["t": "Link", "c": [["", [], []], [], ["/a%23b.png", ""]]]
        ]]]]
        let rewritten = try PandocExportService.resolveRootImages(in: tree, text: text, document: document)
        let blocks = try XCTUnwrap(rewritten["blocks"] as? [[String: Any]])
        let inlines = try XCTUnwrap(blocks[0]["c"] as? [[String: Any]])
        func target(_ index: Int) throws -> String {
            let parts = try XCTUnwrap(inlines[index]["c"] as? [Any])
            return try XCTUnwrap((parts[2] as? [String])?.first)
        }
        XCTAssertEqual(try target(0), "file:///tmp/site/a%23b.png")
        XCTAssertEqual(try target(1), "relative.png")
        XCTAssertEqual(try target(2), "/a%23b.png")
        let metadata = try XCTUnwrap(rewritten["meta"] as? [String: Any])
        let cover = try XCTUnwrap(metadata["cover"] as? [String: Any])
        let image = try XCTUnwrap((cover["c"] as? [[String: Any]])?.first)
        let parts = try XCTUnwrap(image["c"] as? [Any])
        XCTAssertEqual((parts[2] as? [String])?.first, "file:///tmp/site/cover.png")
        XCTAssertThrowsError(try PandocExportService.resolveRootImages(in: tree, text: "---\ninvalid: [\n---\n", document: document))
    }

    func testPandocEmbedsRootImageBytesForStandardAndProfileExports() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let site = directory.appendingPathComponent("site", isDirectory: true)
        let posts = directory.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        try image.write(to: site.appendingPathComponent("a#b.png"))
        let text = "---\ntypora-root-url: ../site\n---\n\n![x](/a%23b.png)"
        let document = posts.appendingPathComponent("note.md")
        for format in [PandocExportFormat.docx, .epub] {
            for profile in [false, true] {
                let destination = directory.appendingPathComponent("result.\(format.fileExtension)")
                let result = try profile
                    ? PandocExportService.prepare(text: text, source: document, destination: destination, profile: .standard(format), title: "Test", executable: executable)
                    : PandocExportService.prepare(text: text, source: document, destination: destination, format: format, title: "Test", executable: executable)
                defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
                let listing = Process(), listPipe = Pipe()
                listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                listing.arguments = ["-Z1", result.preparedURL.path]
                listing.standardOutput = listPipe
                try listing.run()
                let names = String(decoding: listPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                listing.waitUntilExit()
                XCTAssertEqual(listing.terminationStatus, 0)
                let name = try XCTUnwrap(names.split(separator: "\n").first(where: { $0.hasSuffix(".png") }))
                let extract = Process(), dataPipe = Pipe()
                extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                extract.arguments = ["-p", result.preparedURL.path, String(name)]
                extract.standardOutput = dataPipe
                try extract.run()
                let bytes = dataPipe.fileHandleForReading.readDataToEndOfFile()
                extract.waitUntilExit()
                XCTAssertEqual(extract.terminationStatus, 0)
                XCTAssertEqual(bytes, image)
            }
        }
        let destination = directory.appendingPathComponent("invalid.docx")
        let invalid = "---\ninvalid: [\n---\n\n![x](/a%23b.png)"
        XCTAssertThrowsError(try PandocExportService.prepare(text: invalid, source: document, destination: destination,
                                                            format: .docx, title: "Test", executable: executable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let htmlSource = "---\ntypora-root-url: ../site\ntitle: '![x](/a%23b.png)'\n---\n\nbody"
        let html = try PandocExportService.prepare(text: htmlSource, source: document,
            destination: directory.appendingPathComponent("metadata.html"), format: .html, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: html.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: html.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        let rawHTMLSource = "---\ntypora-root-url: ../site\n---\n\n<img src='/a%23b.png'>"
        let rawHTML = try PandocExportService.prepare(text: rawHTMLSource, source: document,
            destination: directory.appendingPathComponent("raw.html"), format: .html, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: rawHTML.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: rawHTML.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        var htmlProfile = MarkdownExportProfile.standard(.html)
        htmlProfile.arguments = "--embed-resources"
        let video = Data("fixture video".utf8)
        try video.write(to: site.appendingPathComponent("clip.mp4"))
        let mediaSource = "---\ntypora-root-url: ../site\n---\n\n<video controls><source src='/clip.mp4?v=1#t=10'></video>\n\nbefore <video>fallback **bold** <source src='/clip.mp4'> </video> after"
        for profile in [false, true] {
            let target = directory.appendingPathComponent("video-\(profile).html")
            let result = try profile
                ? PandocExportService.prepare(text: mediaSource, source: document, destination: target, profile: htmlProfile, title: "Test", executable: executable)
                : PandocExportService.prepare(text: mediaSource, source: document, destination: target, format: .html, title: "Test", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
            XCTAssertTrue(html.contains("data:video/mp4;base64," + video.base64EncodedString() + "#t=10"))
            XCTAssertEqual(html.components(separatedBy: "data:video/mp4;base64," + video.base64EncodedString()).count - 1, 2)
            XCTAssertFalse(html.contains("data-lac-media-"))
        }
        let duplicateTemplate = directory.appendingPathComponent("duplicate.html")
        try "<html><body>$body$$body$</body></html>".write(to: duplicateTemplate, atomically: true, encoding: .utf8)
        htmlProfile.templatePath = duplicateTemplate.path
        XCTAssertThrowsError(try PandocExportService.prepare(text: mediaSource, source: document,
            destination: directory.appendingPathComponent("duplicate-media.html"), profile: htmlProfile, title: "Test", executable: executable))
        let misplacedTemplate = directory.appendingPathComponent("misplaced-source.html")
        try "<html><body><textarea>$body$</textarea></body></html>".write(to: misplacedTemplate, atomically: true, encoding: .utf8)
        let untouched = directory.appendingPathComponent("untouched.html")
        try "keep".write(to: untouched, atomically: true, encoding: .utf8)
        htmlProfile.templatePath = misplacedTemplate.path
        XCTAssertThrowsError(try PandocExportService.prepare(text: mediaSource, source: document,
            destination: untouched, profile: htmlProfile, title: "Test", executable: executable))
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "keep")
        htmlProfile.templatePath = nil
        let embeddedProfile = try PandocExportService.prepare(text: text, source: document,
            destination: directory.appendingPathComponent("profile.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: embeddedProfile.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: embeddedProfile.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        let hidden = site.appendingPathComponent("hidden.png")
        try image.write(to: hidden)
        let hiddenText = "<img src='\(hidden.path)'>"
        let rawProfileSource = "---\ntypora-root-url: ../site\n---\n\n<img src='/a%23b.png'>\n\nbefore <textarea>\(hiddenText)</textarea> after"
        let rawProfile = try PandocExportService.prepare(text: rawProfileSource, source: document,
            destination: directory.appendingPathComponent("raw-profile.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: rawProfile.preparedURL.deletingLastPathComponent()) }
        let rawProfileHTML = try String(contentsOf: rawProfile.preparedURL, encoding: .utf8)
        XCTAssertTrue(rawProfileHTML.contains("data:image/png;base64,"))
        XCTAssertTrue(rawProfileHTML.contains(hiddenText))
        let plainTextareaSource = "before <textarea>\(hiddenText) &amp; 中文</textarea> after"
        for profile in [false, true] {
            let destination = directory.appendingPathComponent("textarea-\(profile).html")
            let result = try profile
                ? PandocExportService.prepare(text: plainTextareaSource, source: document, destination: destination, profile: htmlProfile, title: "Test", executable: executable)
                : PandocExportService.prepare(text: plainTextareaSource, source: document, destination: destination, format: .html, title: "Test", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            XCTAssertTrue(try String(contentsOf: result.preparedURL, encoding: .utf8).contains("\(hiddenText) &amp; 中文"))
        }
        let multipleTextareas = "before <textarea>first\n\n**second**</textarea> after\n\n<textarea>\(hiddenText)</textarea>"
        let multiple = try PandocExportService.prepare(text: multipleTextareas, source: document,
            destination: directory.appendingPathComponent("multiple.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: multiple.preparedURL.deletingLastPathComponent()) }
        let multipleHTML = try String(contentsOf: multiple.preparedURL, encoding: .utf8)
        XCTAssertTrue(multipleHTML.contains("first\n\n**second**"))
        XCTAssertTrue(multipleHTML.contains(hiddenText))
        XCTAssertThrowsError(try PandocExportService.prepare(text: "before <textarea>unfinished", source: document,
            destination: directory.appendingPathComponent("unfinished.html"), profile: htmlProfile, title: "Test", executable: executable))
        let template = directory.appendingPathComponent("attribute.html")
        try "<?xml version=\"1.0\"?><html><body><div data-body='$body$'></div></body></html>".write(to: template, atomically: true, encoding: .utf8)
        htmlProfile.templatePath = template.path
        XCTAssertThrowsError(try PandocExportService.prepare(text: plainTextareaSource, source: document,
            destination: directory.appendingPathComponent("misplaced.html"), profile: htmlProfile, title: "Test", executable: executable))
        htmlProfile.templatePath = nil
        htmlProfile.arguments = ""
        let linkedProfile = try PandocExportService.prepare(text: text, source: document,
            destination: directory.appendingPathComponent("linked.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: linkedProfile.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: linkedProfile.preparedURL, encoding: .utf8).contains("/a%23b.png"))
        let defaultsFile = directory.appendingPathComponent("embed.yaml")
        try "embed-resources: true\n".write(to: defaultsFile, atomically: true, encoding: .utf8)
        htmlProfile.arguments = "--defaults '" + defaultsFile.path + "'"
        let defaultsProfile = try PandocExportService.prepare(text: text, source: document,
            destination: directory.appendingPathComponent("defaults.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: defaultsProfile.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: defaultsProfile.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        htmlProfile.arguments += " --embed-resources=false"
        let disabledProfile = try PandocExportService.prepare(text: text, source: document,
            destination: directory.appendingPathComponent("disabled.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: disabledProfile.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: disabledProfile.preparedURL, encoding: .utf8).contains("/a%23b.png"))
        let parentDefaults = directory.appendingPathComponent("parent.yaml")
        try "defaults: ['${.}/embed.yaml']\nembed-resources: false\nself-contained: true\n".write(to: parentDefaults, atomically: true, encoding: .utf8)
        htmlProfile.arguments = "--defaults '" + parentDefaults.path + "'"
        let nestedProfile = try PandocExportService.prepare(text: text, source: document,
            destination: directory.appendingPathComponent("nested.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: nestedProfile.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: nestedProfile.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        htmlProfile.arguments += " --self-contained=false"
        let nestedDisabled = try PandocExportService.prepare(text: text, source: document,
            destination: directory.appendingPathComponent("nested-disabled.html"), profile: htmlProfile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: nestedDisabled.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: nestedDisabled.preparedURL, encoding: .utf8).contains("/a%23b.png"))
    }
    func testLiveSnapshotDoesNotChangeSourceOrDirtyState() throws {
        let document = EditorDocument(text: "old", language: .markdown)
        document.attachLiveTextProvider(id: UUID(), provider: { "новый 中文 😀" }, acknowledgement: { _ in })
        document.noteLiveEdit(isEmpty: false)
        let snapshot = document.synchronizedSnapshot()
        XCTAssertEqual(snapshot.text, "новый 中文 😀")
        XCTAssertTrue(document.isDirty)
        XCTAssertNil(document.url)
    }

    func testConflictsIncludeSourceOtherOpenFilesAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let other = directory.appendingPathComponent("other.txt")
        let link = directory.appendingPathComponent("link.txt")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertTrue(PandocExportService.conflicts(destination: source, source: source, openURLs: []))
        XCTAssertTrue(PandocExportService.conflicts(destination: link, source: source, openURLs: [other]))
        XCTAssertFalse(PandocExportService.conflicts(destination: directory.appendingPathComponent("new.html"), source: source, openURLs: [other]))
    }

    func testProcessFailurePreservesDestinationAndReturnsDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("pandoc")
        let destination = directory.appendingPathComponent("result.html")
        try "#!/bin/sh\nprintf 'conversion failed' >&2\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PandocExportService.prepare(text: "new", source: nil, destination: destination, format: .html, title: "Document", executable: executable)) { error in
            XCTAssertTrue(error.localizedDescription.contains("conversion failed"))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
    }

    func testInstallReplacesExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.html")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        let replacementDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true
        )
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let prepared = replacementDirectory.appendingPathComponent("output.html")
        try "new".write(to: prepared, atomically: true, encoding: .utf8)
        try PandocExportService.install(prepared, at: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    }

    func testHTMLIncludesRelativeImageAndDocumentTitle() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = directory.appendingPathComponent("source folder")
        let outputDirectory = directory.appendingPathComponent("output folder")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try image.write(to: sourceDirectory.appendingPathComponent("image file.png"))
        let source = sourceDirectory.appendingPathComponent("original.md")
        let destination = outputDirectory.appendingPathComponent("result.html")
        let result = try PandocExportService.prepare(
            text: "![image](image%20file.png)", source: source, destination: destination,
            format: .html, title: "Название $ test", executable: executable
        )
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("<title>Название $ test</title>"))
    }

    func testRealPandocExportsSnapshot() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.html")
        let result = try PandocExportService.prepare(text: "# 中文 😀\n\n| a | b |\n|---|---|\n| 1 | 2 |", source: nil, destination: destination, format: .html, title: "Document", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        try PandocExportService.install(result.preparedURL, at: destination)
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Document</title>"))
        XCTAssertTrue(html.contains("中文 😀"))
        XCTAssertTrue(html.contains("<table>"))
    }

    func testPlainAndProfileExportResolveOnlyConfirmedEmoji() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "中文 :smile: and `:heart:` and \\:heart:"
        let destination = directory.appendingPathComponent("result.txt")
        for profile in [false, true] {
            let result = try profile
                ? PandocExportService.prepare(text: source, source: nil, destination: destination, profile: .standard(.text), title: "Document", executable: executable)
                : PandocExportService.prepare(text: source, source: nil, destination: destination, format: .text, title: "Document", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
            XCTAssertTrue(output.contains("中文 😄"))
            XCTAssertTrue(output.contains(":heart:"))
            XCTAssertFalse(output.contains(":smile:"))
        }
    }

    func testLatexExportPreservesInlineAndDisplayMath() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let destination = directory.appendingPathComponent("result.tex")
        let markdown = "中文😀 $x^2$\n\n$$\n\\frac{a}{b}\n$$\n"
        try Data(markdown.utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let result = try PandocExportService.prepare(text: markdown, source: source, destination: destination,
                                                      format: .latex, title: "Document", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let latex = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(latex.contains("\\(x^2\\)"))
        XCTAssertTrue(latex.contains("\\frac{a}{b}"))
        XCTAssertTrue(latex.contains("\\["))
        XCTAssertEqual(try Data(contentsOf: source), Data(markdown.utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testRealPandocExportsFB2() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.fb2")
        let result = try PandocExportService.prepare(text: "# 中文 😀\n\nText", source: nil, destination: destination, format: .fb2, title: "Document", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let fb2 = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(fb2.contains("<FictionBook"))
        XCTAssertTrue(fb2.contains("中文 😀"))
    }

    func testAdditionalFormatMapping() {
        XCTAssertEqual(Set(PandocExportFormat.allCases.map(\.rawValue)), Set([
            "html", "htmlPlain", "docx", "odt", "rtf", "epub", "fb2", "latex", "text", "pdf",
            "mediawiki", "rst", "textile", "opml"
        ]))
        XCTAssertEqual(PandocExportFormat.mediawiki.title, "MediaWiki")
        XCTAssertEqual(PandocExportFormat.mediawiki.fileExtension, "wiki")
        XCTAssertEqual(PandocExportFormat.mediawiki.writer, "mediawiki")
        XCTAssertEqual(PandocExportFormat.rst.title, "RST")
        XCTAssertEqual(PandocExportFormat.rst.fileExtension, "rst")
        XCTAssertEqual(PandocExportFormat.rst.writer, "rst")
        XCTAssertEqual(PandocExportFormat.textile.title, "Textile")
        XCTAssertEqual(PandocExportFormat.textile.fileExtension, "textile")
        XCTAssertEqual(PandocExportFormat.textile.writer, "textile")
        XCTAssertEqual(PandocExportFormat.opml.title, "OPML")
        XCTAssertEqual(PandocExportFormat.opml.fileExtension, "opml")
        XCTAssertEqual(PandocExportFormat.opml.writer, "opml")
    }

    func testRealPandocExportsAdditionalFormatsWithoutChangingFiles() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.md")
        try "original".write(to: source, atomically: true, encoding: .utf8)

        for format in [PandocExportFormat.mediawiki, .rst, .textile, .opml] {
            let destination = directory.appendingPathComponent("result.\(format.fileExtension)")
            try "previous".write(to: destination, atomically: true, encoding: .utf8)
            let result = try PandocExportService.prepare(
                text: "# 中文 😀\n\n## Section\n\nText", source: source, destination: destination,
                format: format, title: "Document", executable: executable
            )
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
            XCTAssertTrue(output.contains("中文 😀"), "\(format)")
            if format == .opml {
                let xml = try XMLDocument(contentsOf: result.preparedURL, options: [])
                XCTAssertEqual(xml.rootElement()?.name, "opml")
                let children = try xml.nodes(forXPath: "/opml/body/outline/outline")
                XCTAssertEqual(children.count, 1)
                XCTAssertEqual((children.first as? XMLElement)?.attribute(forName: "text")?.stringValue, "Section")
            } else {
                XCTAssertTrue(output.contains("Section"), "\(format)")
                switch format {
                case .mediawiki: XCTAssertTrue(output.contains("=="))
                case .rst: XCTAssertTrue(output.contains("-------"))
                case .textile: XCTAssertTrue(output.contains("h1."))
                default: break
                }
            }
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
        }
    }
    func testProfilesPreserveUnknownEntriesAndEmptyList() throws {
        let suite = "PandocExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = AppPreferences(defaults: defaults)
        XCTAssertEqual(initial.markdownExportConfiguration.profiles, MarkdownExportProfile.defaults)
        initial.markdownExportConfiguration.profiles = []
        XCTAssertTrue(AppPreferences(defaults: defaults).markdownExportConfiguration.profiles.isEmpty)
        let profile = MarkdownExportProfile.standard(.docx)
        let data = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["futureSetting"] = "keep"
        var future = object
        future["id"] = "unknown"
        future["kind"] = "future"
        let root: [String: Any] = ["futureRoot": 7, "profiles": [object, future]]
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: "markdownExportConfiguration")
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownExportConfiguration.profiles.count, 1)
        XCTAssertEqual(restored.unsupportedMarkdownExportEntryCount, 1)
        restored.markdownExportConfiguration.profiles[0].name = "Renamed"
        let savedData = try XCTUnwrap(defaults.data(forKey: "markdownExportConfiguration"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        let entries = try XCTUnwrap(saved["profiles"] as? [[String: Any]])
        XCTAssertEqual(saved["futureRoot"] as? Int, 7)
        XCTAssertEqual(entries[0]["futureSetting"] as? String, "keep")
        XCTAssertEqual(entries[1]["kind"] as? String, "future")
    }

    func testArgumentParsingPreservesVariablesAndRejectsOutputOverrides() throws {
        let arguments = try PandocExportService.checkedArguments("--metadata=title:'${title}' --wrap=none", variables: ["title": "中文 \"quoted\" ${literal}"])
        XCTAssertEqual(arguments, ["--metadata=title:中文 \"quoted\" ${literal}", "--wrap=none"])
        XCTAssertEqual(try PandocExportService.checkedArguments("--filter 'tools/中文 filter' --lua-filter=\"${filter}\" -H 'head file' --citeproc", variables: ["filter": "path $ literal.lua"]),
                       ["--filter", "tools/中文 filter", "--lua-filter=path $ literal.lua", "-H", "head file", "--citeproc"])
        XCTAssertEqual(try PandocExportService.checkedArguments("--reference-links --reference-location=section --markdown-headings atx --dpi 144 --strip-comments --table-of-contents", variables: [:]),
                       ["--reference-links", "--reference-location=section", "--markdown-headings", "atx", "--dpi", "144", "--strip-comments", "--table-of-contents"])
        XCTAssertEqual(try PandocExportService.checkedArguments("--dpi 0 --reference-location=wrong", variables: [:]), ["--dpi", "0", "--reference-location=wrong"])
        XCTAssertEqual(try PandocExportService.checkedArguments("--number-offset=-1 --variable=-literal", variables: [:]), ["--number-offset=-1", "--variable=-literal"])
        XCTAssertEqual(try PandocExportService.checkedArguments("-Ftool -dfile.yaml --future=value --future-flag", variables: [:]), ["-F", "tool", "-d", "file.yaml", "--future=value", "--future-flag"])
        for unsafe in ["-oresult", "--out=bad", "--rea=html", "--def=bad", "--extract-media=bad", "--ignore-args", "--future value"] {
            XCTAssertThrowsError(try PandocExportService.checkedArguments(unsafe, variables: [:]), unsafe)
        }
        XCTAssertThrowsError(try PandocExportService.checkedArguments("--metadata --output=/tmp/wrong", variables: [:]))
        XCTAssertThrowsError(try PandocExportService.checkedArguments("--output=/tmp/wrong", variables: [:]))
        XCTAssertEqual(try PandocExportService.checkedArguments("--defaults=other.yaml", variables: [:]), ["--defaults=other.yaml"])
        XCTAssertThrowsError(try PandocExportService.checkedArguments("--metadata='broken", variables: [:]))
        XCTAssertThrowsError(try PandocExportService.checkedArguments("--metadata=x:${missing}", variables: [:]))
    }

    func testProfileUsesReferenceLinkArgumentsWithRealPandoc() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.md")
        try Data("previous".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.text)
        profile.writer = "markdown"
        profile.arguments = "--reference-links --reference-location=document --markdown-headings=atx"
        let result = try PandocExportService.prepare(text: "# Heading\n\n[link](https://example.org)", source: nil,
            destination: destination, profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(output.contains("# Heading"))
        XCTAssertTrue(output.contains("[link]: https://example.org"))
        XCTAssertTrue(output.contains("https://example.org"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }

    func testProfilePassesFilterArgumentsAsSeparateValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("args")
        let recordPath = "'" + record.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executable = directory.appendingPathComponent("pandoc-fixture")
        let script = """
        #!/bin/sh
        out=''
        previous=''
        for arg in "$@"; do
          if [ "$previous" = '--output' ]; then out="$arg"; fi
          previous="$arg"
        done
        case "$out" in
          *.json) printf '%s' '{"pandoc-api-version":[1,23],"meta":{},"blocks":[]}' > "$out" ;;
          *) printf '%s\\n' "$@" > \(recordPath); printf output > "$out" ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let destination = directory.appendingPathComponent("out.html")
        try Data("old".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--filter '中文 filter' --include-in-header 'header file' --citeproc"
        let result = try PandocExportService.prepare(text: "snapshot", source: nil, destination: destination,
                                                      profile: profile, title: "test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let arguments = try String(contentsOf: record, encoding: .utf8).components(separatedBy: "\n")
        let filter = try XCTUnwrap(arguments.firstIndex(of: "--filter"))
        XCTAssertEqual(arguments[filter + 1], "中文 filter")
        let header = try XCTUnwrap(arguments.firstIndex(of: "--include-in-header"))
        XCTAssertEqual(arguments[header + 1], "header file")
        XCTAssertTrue(arguments.contains("--citeproc"))
        XCTAssertFalse(arguments.contains(destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testEPUBRejectsBothRepeatedTOCDepthForms() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.epub")
        try Data("old".utf8).write(to: destination)
        for arguments in ["--toc-depth=3", "--toc-depth 3"] {
            var profile = MarkdownExportProfile.standard(.epub)
            profile.epubTOCDepth = 2
            profile.arguments = arguments
            XCTAssertThrowsError(try PandocExportService.prepare(text: "# Heading", source: nil,
                destination: destination, profile: profile, title: "Title", executable: executable)) {
                guard case PandocExportError.invalidConfiguration = $0 else { return XCTFail("Expected repeated depth rejection: \($0)") }
            }
            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        }
    }

    func testProfileFilterProcessCancellationStopsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let started = directory.appendingPathComponent("started"), later = directory.appendingPathComponent("later")
        let executable = directory.appendingPathComponent("pandoc-fixture")
        let child = "printf started > \(quote(started.path)); /bin/sleep 2; printf later > \(quote(later.path))"
        let script = """
        #!/bin/sh
        out=''
        previous=''
        for arg in "$@"; do
          if [ "$previous" = '--output' ]; then out="$arg"; fi
          previous="$arg"
        done
        case "$out" in
          *.json) printf '%s' '{"pandoc-api-version":[1,23],"meta":{},"blocks":[]}' > "$out" ;;
          *) /bin/sh -c \(quote(child)) ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let destination = directory.appendingPathComponent("result.html")
        try Data("old".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--filter 'test filter'"
        let configured = profile
        let task = Task.detached {
            try PandocExportService.prepare(text: "snapshot", source: nil, destination: destination,
                profile: configured, title: "test", executable: executable, isCancelled: { Task.isCancelled })
        }
        defer { task.cancel() }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testDefaultsFileIsCheckedBeforeConversionAndPreservesDestination() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("out.html")
        let defaults = directory.appendingPathComponent("safe.yaml")
        try Data("# Source".utf8).write(to: source)
        try Data("previous".utf8).write(to: destination)
        try "toc: true\nmetadata:\n  author: '中文'\n".write(to: defaults, atomically: true, encoding: .utf8)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--defaults safe.yaml"
        let result = try PandocExportService.prepare(text: "# Current snapshot", source: source, destination: destination,
                                                      profile: profile, title: "Fallback", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("Current snapshot"))
        XCTAssertTrue(html.contains("中文"))
        XCTAssertEqual(try Data(contentsOf: source), Data("# Source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        for safe in ["\n# comment\n---\ntoc: true\n", "{\"toc\": true}", "metadata:\n  description: '${HOME} literal'\n"] {
            try safe.write(to: defaults, atomically: true, encoding: .utf8)
            let prepared = try PandocExportService.prepare(text: "# Safe", source: source, destination: destination,
                profile: profile, title: "test", executable: executable)
            defer { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
            XCTAssertTrue(try String(contentsOf: prepared.preparedURL, encoding: .utf8).contains("Safe"))
        }
        try "verbosity: ERROR\nfail-if-warnings: false\ndpi: 150\ntable-of-contents: true\nstrip-comments: true\n".write(to: defaults, atomically: true, encoding: .utf8)
        let extended = try PandocExportService.prepare(text: "# Heading\n\n<!-- hidden comment -->", source: source,
            destination: destination, profile: profile, title: "test", executable: executable)
        defer { try? FileManager.default.removeItem(at: extended.preparedURL.deletingLastPathComponent()) }
        let extendedHTML = try String(contentsOf: extended.preparedURL, encoding: .utf8)
        XCTAssertTrue(extendedHTML.contains("id=\"TOC\""))
        XCTAssertFalse(extendedHTML.contains("hidden comment"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        try "reference-links: true\nreference-location: document\nmarkdown-headings: atx\n".write(to: defaults, atomically: true, encoding: .utf8)
        profile.writer = "markdown"
        let references = try PandocExportService.prepare(text: "# Heading\n\n[link](https://example.org)", source: source,
            destination: destination, profile: profile, title: "test", executable: executable)
        defer { try? FileManager.default.removeItem(at: references.preparedURL.deletingLastPathComponent()) }
        let referencesText = try String(contentsOf: references.preparedURL, encoding: .utf8)
        XCTAssertTrue(referencesText.contains("# Heading"))
        XCTAssertTrue(referencesText.contains("[link]: https://example.org"))
        profile.writer = "html"
        let assets = directory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try png.write(to: assets.appendingPathComponent("image.png"))
        try "resource-path: ['assets']\n".write(to: defaults, atomically: true, encoding: .utf8)
        profile.arguments = "--defaults safe.yaml --embed-resources"
        let resources = try PandocExportService.prepare(text: "![image](image.png)", source: source,
            destination: destination, profile: profile, title: "test", executable: executable)
        defer { try? FileManager.default.removeItem(at: resources.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: resources.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        try "resource-path: ['${.}/assets']\n".write(to: defaults, atomically: true, encoding: .utf8)
        let yamlResources = try PandocExportService.prepare(text: "![image](image.png)", source: source,
            destination: destination, profile: profile, title: "test", executable: executable)
        defer { try? FileManager.default.removeItem(at: yamlResources.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: yamlResources.preparedURL, encoding: .utf8).contains("data:image/png;base64,"))
        let specialDirectory = directory.appendingPathComponent("literal${HOME}")
        let specialAssets = specialDirectory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: specialAssets, withIntermediateDirectories: true)
        try png.write(to: specialAssets.appendingPathComponent("image.png"))
        let jsonSource = specialDirectory.appendingPathComponent("source.md")
        try Data("source".utf8).write(to: jsonSource)
        let jsonDefaults = specialDirectory.appendingPathComponent("settings.json")
        let json: [String: Any] = ["resource-path": ["${.}/assets"], "metadata": ["description": "literal ${.}"]]
        try JSONSerialization.data(withJSONObject: json).write(to: jsonDefaults)
        profile.arguments = "--defaults settings.json --embed-resources"
        let jsonResult = try PandocExportService.prepare(text: "![image](image.png)", source: jsonSource,
            destination: destination, profile: profile, title: "test", executable: executable)
        defer { try? FileManager.default.removeItem(at: jsonResult.preparedURL.deletingLastPathComponent()) }
        let jsonHTML = try String(contentsOf: jsonResult.preparedURL, encoding: .utf8)
        XCTAssertTrue(jsonHTML.contains("data:image/png;base64,"))
        XCTAssertTrue(jsonHTML.contains("literal ${.}"))
        XCTAssertEqual(try Data(contentsOf: jsonSource), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        profile.arguments = "--defaults safe.yaml"
        XCTAssertThrowsError(try PandocExportService.prepare(text: "snapshot", source: nil, destination: destination,
            profile: profile, title: "test", executable: executable)) { error in
            guard case let PandocExportError.invalidConfiguration(reason) = error else {
                return XCTFail("Expected explicit path error, got \(error)")
            }
            XCTAssertEqual(reason, L10n.tr("未保存文档需要 defaults 绝对路径"))
        }
        for unsafe in ["input-file: other.md", "input-files: [other.md]", "output-file: other.html", "defaults: [other.yaml]", "log-file: log.txt", "from: html", "writer: /tmp/writer.lua", "\n---\nfrom: html", "# comment\n---\nfrom: html", "\n# comment\n\n---\t# comment\ninput-file: other.md", "toc: true\n...\n---\noutput-file: other.html"] {
            try unsafe.write(to: defaults, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try PandocExportService.prepare(text: "snapshot", source: source, destination: destination,
                profile: profile, title: "test", executable: executable))
            XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        }
    }

    func testNestedYAMLDefaultsResolvePathsAndRejectCyclesAndMergedOutput() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested"), assets = nested.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try png.write(to: assets.appendingPathComponent("image.png"))
        let parent = directory.appendingPathComponent("parent.yaml"), child = nested.appendingPathComponent("child.yaml")
        let source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("output.html")
        try Data("source".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let parentYAML = "defaults: ['${.}/nested/child.yaml']\ntoc: true\nmetadata:\n  title: &name !!str 001\n  author: *name\n  signedhex: -0x12\n  signedoctal: +0o7\n  plainyes: yes\n  plainon: on\n  literalfalse: !!str false\n  explicitint: !!int '42'\n  description: |\n    literal ${.}\n"
        let childYAML = "resource-path: &assets ['${.}/assets']\ntoc: false\n"
        try parentYAML.write(to: parent, atomically: true, encoding: .utf8)
        try childYAML.write(to: child, atomically: true, encoding: .utf8)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--defaults parent.yaml --embed-resources"
        let result = try PandocExportService.prepare(text: "# Heading\n\n![x](image.png)", source: source,
            destination: destination, profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("id=\"TOC\""))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("literal ${.}"))
        XCTAssertTrue(html.contains("001"))
        XCTAssertEqual(try String(contentsOf: parent, encoding: .utf8), parentYAML)
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), childYAML)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        let template = directory.appendingPathComponent("template.html")
        try "<html><head></head><body>[$signedhex$][$signedoctal$][$title$][$plainyes$][$plainon$][$literalfalse$][$explicitint$]$body$</body></html>".write(to: template, atomically: true, encoding: .utf8)
        profile.templatePath = template.path
        let typed = try PandocExportService.prepare(text: "# Heading", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: typed.preparedURL.deletingLastPathComponent()) }
        let typedHTML = try String(contentsOf: typed.preparedURL, encoding: .utf8)
        XCTAssertTrue(typedHTML.contains("[-0x12][+0o7][001][yes][on][false][42]"))
        profile.templatePath = nil
        try "defaults: ['${.}/../parent.yaml']\n".write(to: child, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PandocExportService.prepare(text: "text", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable))
        try "<<: &unsafe {output-file: forbidden.html}\n".write(to: parent, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PandocExportService.prepare(text: "text", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden.html").path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testNestedDefaultsUseCurrentYAMLDataDirectoryForLookup() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dataDirectory = directory.appendingPathComponent("data"), defaultsDirectory = dataDirectory.appendingPathComponent("defaults")
        try FileManager.default.createDirectory(at: defaultsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "child-" + UUID().uuidString
        try "toc: true\n".write(to: defaultsDirectory.appendingPathComponent(name + ".yaml"), atomically: true, encoding: .utf8)
        let parent = directory.appendingPathComponent("parent.yaml"), source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("output.html")
        try Data("source".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--data-dir '" + dataDirectory.path + "' --defaults parent.yaml"
        try "defaults: ['\(name)']\n".write(to: parent, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PandocExportService.prepare(text: "# Heading", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable))
        try "data-dir: '\(dataDirectory.path)'\ndefaults: ['\(name)']\n".write(to: parent, atomically: true, encoding: .utf8)
        let result = try PandocExportService.prepare(text: "# Heading", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: result.preparedURL, encoding: .utf8).contains("id=\"TOC\""))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testSiblingDefaultsResolveNamesBeforeApplyingEitherChild() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = directory.appendingPathComponent("original"), changed = directory.appendingPathComponent("changed")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent.yaml"), source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("output.html")
        try "data-dir: '\(changed.path)'\n".write(to: original.appendingPathComponent("first.yaml"), atomically: true, encoding: .utf8)
        try "metadata: {title: 'Original sibling'}\n".write(to: original.appendingPathComponent("second.yaml"), atomically: true, encoding: .utf8)
        try "metadata: {title: 'Wrong sibling'}\n".write(to: changed.appendingPathComponent("second.yaml"), atomically: true, encoding: .utf8)
        try "data-dir: '\(original.path)'\ndefaults: ['${USERDATA}/first.yaml', '${USERDATA}/second.yaml']\n".write(to: parent, atomically: true, encoding: .utf8)
        try Data("source".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--defaults parent.yaml"
        let result = try PandocExportService.prepare(text: "text", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("Original sibling"))
        XCTAssertFalse(html.contains("Wrong sibling"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testLaterDefaultsUseDataDirectoryFromEarlierDefaults() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = directory.appendingPathComponent("data"), defaults = data.appendingPathComponent("defaults")
        try FileManager.default.createDirectory(at: defaults, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "child-" + UUID().uuidString
        let first = directory.appendingPathComponent("first.yaml"), source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("output.html")
        try "data-dir: '\(data.path)'\n".write(to: first, atomically: true, encoding: .utf8)
        try "toc: true\n".write(to: defaults.appendingPathComponent(name + ".yaml"), atomically: true, encoding: .utf8)
        try Data("source".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--defaults first.yaml --defaults " + name
        let result = try PandocExportService.prepare(text: "# Heading", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try String(contentsOf: result.preparedURL, encoding: .utf8).contains("id=\"TOC\""))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testNestedDefaultsPreserveMissingEnvironmentWarning() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("output.html")
        let parent = directory.appendingPathComponent("parent.yaml"), child = directory.appendingPathComponent("child.yaml")
        try Data("source".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        try "toc: false\n".write(to: child, atomically: true, encoding: .utf8)
        let missing = "LACEDITOR_TEST_MISSING_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        XCTAssertNil(ProcessInfo.processInfo.environment[missing])
        try "defaults: ['${\(missing)}child.yaml']\n".write(to: parent, atomically: true, encoding: .utf8)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--defaults parent.yaml"
        let result = try PandocExportService.prepare(text: "text", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(result.diagnostics.contains(missing))
        profile.arguments += " --fail-if-warnings"
        XCTAssertThrowsError(try PandocExportService.prepare(text: "text", source: source, destination: destination,
            profile: profile, title: "Test", executable: executable))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testInvalidProfileDoesNotLaunchPandoc() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let executable = directory.appendingPathComponent("pandoc")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\nprintf started > \(quoted)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var profile = MarkdownExportProfile.standard(.text)
        profile.writer = "/tmp/custom.lua"
        XCTAssertThrowsError(try PandocExportService.prepare(text: ":smile:", source: nil,
            destination: directory.appendingPathComponent("output.txt"), profile: profile, title: "x", executable: executable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testProfileRejectsCustomWriterAndPDFBeforeStartingPandoc() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/pandoc")
        var profile = MarkdownExportProfile.standard(.text)
        profile.writer = "/tmp/custom.lua"
        XCTAssertThrowsError(try PandocExportService.prepare(text: "x", source: nil,
            destination: URL(fileURLWithPath: "/tmp/output.txt"), profile: profile, title: "x", executable: missing)) {
            guard case PandocExportError.invalidConfiguration = $0 else { return XCTFail("Writer must be rejected before launch: \($0)") }
        }
        for writer in ["", "html"] {
            profile.writer = writer
            XCTAssertThrowsError(try PandocExportService.prepare(text: "x", source: nil,
                destination: URL(fileURLWithPath: "/tmp/output.PDF"), profile: profile, title: "x", executable: missing)) {
                guard case PandocExportError.invalidConfiguration = $0 else { return XCTFail("PDF must be rejected before launch: \($0)") }
            }
        }
    }

    func testStyledHTMLUsesYAMLTitleAndConfiguredAppend() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("result.html")
        let markdown = "---\ntitle: 'A & B'\nappend-head: |\n  <meta name=\"description\" content=\"${title}\">\nappend-body-extra: |\n  <script>console.log('configured')</script>\n---\n\n# Heading"
        try Data(markdown.utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        var options = MarkdownHTMLExportOptions()
        options.allowDocumentOverrides = true
        options.appendBody = "<p>global footer</p>"
        let result = try PandocExportService.prepare(text: markdown, source: source, destination: destination,
            format: .html, title: "Fallback", executable: executable, htmlOptions: options)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("A &amp; B"))
        XCTAssertFalse(html.contains("Fallback"))
        XCTAssertTrue(html.contains("name=\"description\" content=\"A &amp; B\""))
        XCTAssertTrue(html.contains("global footer"))
        XCTAssertTrue(html.contains("console.log('configured')"))
        XCTAssertEqual(try Data(contentsOf: source), Data(markdown.utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testHTMLScriptContextEndsAfterComment() {
        var filter = MarkdownHTMLMediaService.SourceHTMLFilter()
        let result = filter.filter("<script><!-- comment --> <script></script>VISIBLE")
        XCTAssertEqual(result, "VISIBLE")
        var doubleEscaped = MarkdownHTMLMediaService.SourceHTMLFilter()
        XCTAssertEqual(doubleEscaped.filter("<script><!--<script>--></script>VISIBLE"), "VISIBLE")
    }

    func testHTMLAndEPUBPreserveSourceHTMLInExport() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        try image.write(to: directory.appendingPathComponent("sample.png"))
        let markdown = """
        Before 中文 😀

        ![sample](sample.png)

        <div id="source-id" class="source-class" data-key="datum" custom="value">body</div>

        <my-widget data-key="custom">unknown</my-widget>

        <script>window.sourceScript=1</script>

        <style>.source-class{color:red}</style>

        <meta name="source-meta" content="value">

        <textarea>keep **raw**</textarea>

        After
        """
        try Data(markdown.utf8).write(to: source)
        for format in [PandocExportFormat.html, .epub] {
            let destination = directory.appendingPathComponent(format == .html ? "result.html" : "result.epub")
            try Data("previous".utf8).write(to: destination)
            for profile in [false, true] {
                var exportProfile = MarkdownExportProfile.standard(format)
                if format == .html { exportProfile.arguments = "--embed-resources" }
                let result = try profile
                    ? PandocExportService.prepare(text: markdown, source: source, destination: destination,
                        profile: exportProfile, title: "Test", executable: executable)
                    : PandocExportService.prepare(text: markdown, source: source, destination: destination,
                        format: format, title: "Test", executable: executable)
                defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
                let html = format == .html ? try String(contentsOf: result.preparedURL, encoding: .utf8) :
                    String(decoding: try unzip(result.preparedURL, "*.xhtml"), as: UTF8.self)
                for expected in ["source-id", "source-class", "data-key", "custom=", "my-widget", "sourceScript", "<style", "source-meta", "Before", "After"] {
                    XCTAssertTrue(html.contains(expected), "\(format): missing \(expected)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: source), Data(markdown.utf8))
    }

    func testHTMLProfileUsesConfiguredAndDocumentAppend() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let destination = directory.appendingPathComponent("result.html")
        let markdown = "---\ntitle: 'A & B'\noutputPath: fake\nappend-head: |\n  <meta name=\"description\" content=\"${title}\">\n  <meta name=\"output\" content=\"${outputPath}\">\n---\n\n# Content"
        try Data(markdown.utf8).write(to: source)
        try Data("previous".utf8).write(to: destination)
        var options = MarkdownHTMLExportOptions()
        options.allowDocumentOverrides = true
        options.appendBody = "<p>configured footer</p>"
        let result = try PandocExportService.prepare(text: markdown, source: source, destination: destination,
            profile: .standard(.html), title: "Fallback", executable: executable, htmlOptions: options)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("name=\"description\" content=\"A &amp; B\""))
        XCTAssertTrue(html.contains("configured footer"))
        XCTAssertTrue(html.contains("name=\"output\" content=\"\(destination.path)\""))
        XCTAssertFalse(html.contains("name=\"output\" content=\"fake\""))
        XCTAssertEqual(try Data(contentsOf: source), Data(markdown.utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }

    func testProfileUsesYAMLTitleAndVariablesWithRealPandoc() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.html")
        try Data("previous".utf8).write(to: destination)
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--metadata=description:'${book.name}'"
        let input = "---\ntitle: YAML title\nbook:\n  name: '中文 *_quoted_*'\n---\n\n# Content"
        let result = try PandocExportService.prepare(text: input, source: nil, destination: destination,
                                                     profile: profile, title: "Fallback", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("YAML title"))
        XCTAssertTrue(html.contains("中文 *_quoted_*"))
        XCTAssertFalse(html.contains("Fallback"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        profile.arguments = "--metadata=path:${currentPath}"
        XCTAssertThrowsError(try PandocExportService.prepare(text: "---\ncurrentPath: fake\n---\n\nbody", source: nil,
            destination: destination, profile: profile, title: "Fallback", executable: executable))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }

    func testProfileDistinguishesAbsentAndEmptyYAMLTitle() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.html")
        let profile = MarkdownExportProfile.standard(.html)
        for (text, expectsFallback) in [("text", true), ("---\ntitle: ''\n---\n\ntext", false)] {
            let result = try PandocExportService.prepare(text: text, source: nil, destination: destination,
                                                         profile: profile, title: "Unique fallback title", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
            XCTAssertEqual(html.contains("Unique fallback title"), expectsFallback)
        }
    }

    func testProfileExportEmbedsRenderedMathAndDiagrams() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "---\ntypora-root-url: .\n---\n\nBEFOREMARK 中文 $x^2$ ![root](/root.png)\n\n```mermaid\nflowchart TD\nA --> B\n```\n\n```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\n```sequence\nAlice->Bob: Hello\n```\n\nAFTERMARK"
        let rootImage = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try rootImage.write(to: directory.appendingPathComponent("root.png"))
        let suite = "PandocImages." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var unexpectedModal = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { unexpectedModal = true; NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        func unzip(_ archive: URL, _ name: String) throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, name]; process.standardOutput = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return bytes
        }
        for format in [PandocExportFormat.html, .docx, .odt, .rtf, .fb2, .epub] {
            let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
            let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
            let destination = directory.appendingPathComponent("output.\(format.fileExtension)")
            var profile = MarkdownExportProfile.standard(format)
            if format == .html { profile.arguments = "--embed-resources" }
            state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
            for _ in 0..<900 {
                if state.hasPreviousMarkdownExport || unexpectedModal { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(unexpectedModal)
            XCTAssertTrue(state.hasPreviousMarkdownExport)
            guard FileManager.default.fileExists(atPath: destination.path) else { XCTFail("Missing \(format.rawValue)"); continue }
            if format == .html {
                let html = try String(contentsOf: destination, encoding: .utf8)
                XCTAssertGreaterThanOrEqual(html.components(separatedBy: "data:image/png;base64,").count - 1, 5)
                XCTAssertTrue(html.contains(rootImage.base64EncodedString()))
                XCTAssertTrue(html.contains("BEFOREMARK") && html.contains("AFTERMARK"))
            } else if format == .rtf {
                let rtf = try String(contentsOf: destination, encoding: .utf8)
                XCTAssertGreaterThanOrEqual(rtf.components(separatedBy: "\\pngblip").count - 1, 5)
                let hex = rootImage.map { String(format: "%02x", $0) }.joined()
                XCTAssertTrue(rtf.lowercased().contains(hex))
                XCTAssertTrue(rtf.contains("BEFOREMARK") && rtf.contains("AFTERMARK"))
            } else if format == .fb2 {
                let fb2 = try String(contentsOf: destination, encoding: .utf8)
                XCTAssertGreaterThanOrEqual(fb2.components(separatedBy: "content-type=\"image/png\"").count - 1, 5)
                XCTAssertTrue(fb2.contains(rootImage.base64EncodedString()))
                XCTAssertTrue(fb2.contains("BEFOREMARK") && fb2.contains("AFTERMARK"))
            } else {
                let listURL = directory.appendingPathComponent("listing.txt")
                FileManager.default.createFile(atPath: listURL.path, contents: nil)
                let list = try FileHandle(forWritingTo: listURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-Z1", destination.path]
                process.standardOutput = list
                try process.run(); process.waitUntilExit(); try list.close()
                XCTAssertEqual(process.terminationStatus, 0)
                let names = try String(contentsOf: listURL, encoding: .utf8).split(separator: "\n").map(String.init).filter { $0.hasSuffix(".png") }
                XCTAssertGreaterThanOrEqual(names.count, 5)
                var foundRoot = false
                for (index, name) in names.enumerated() {
                    let extracted = directory.appendingPathComponent("\(format.rawValue)-\(index).png")
                    FileManager.default.createFile(atPath: extracted.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: extracted)
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    unzip.arguments = ["-p", destination.path, name]
                    unzip.standardOutput = handle
                    try unzip.run(); unzip.waitUntilExit(); try handle.close()
                    XCTAssertEqual(unzip.terminationStatus, 0)
                    let bytes = try Data(contentsOf: extracted)
                    XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
                    if bytes == rootImage { foundRoot = true }
                }
                XCTAssertTrue(foundRoot)
                let xml = String(decoding: try unzip(destination, format == .epub ? "*.xhtml" : "*.xml"), as: UTF8.self)
                XCTAssertTrue(xml.contains("BEFOREMARK") && xml.contains("AFTERMARK"))
                try? FileManager.default.removeItem(at: listURL)
            }
            XCTAssertEqual(document.text, source)
            XCTAssertFalse(document.isDirty)
        }
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        var pptx = MarkdownExportProfile.standard(.docx)
        pptx.writer = "pptx"; pptx.extensions = ["pptx"]
        let slides = directory.appendingPathComponent("output.pptx")
        state.exportMarkdown(profile: pptx, destination: slides, expectedRevision: nil)
        for _ in 0..<900 {
            if state.hasPreviousMarkdownExport || unexpectedModal { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(unexpectedModal)
        XCTAssertTrue(state.hasPreviousMarkdownExport)
        let list = Process(), pipe = Pipe()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z1", slides.path]; list.standardOutput = pipe
        try list.run()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        XCTAssertEqual(list.terminationStatus, 0)
        let slideImages = names.split(separator: "\n").filter { $0.hasPrefix("ppt/media/") && $0.hasSuffix(".png") }
        XCTAssertGreaterThanOrEqual(slideImages.count, 5)
        var slideHasRoot = false
        for name in slideImages {
            let bytes = try unzip(slides, String(name))
            XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            if bytes == rootImage { slideHasRoot = true }
        }
        XCTAssertTrue(slideHasRoot)
        let slideXML = String(decoding: try unzip(slides, "ppt/slides/*.xml"), as: UTF8.self)
        XCTAssertTrue(slideXML.contains("BEFOREMARK") && slideXML.contains("AFTERMARK"))
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
    }

    func testLatexStagesRelativePNGAndPreservesExistingSidecars() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        let destination = directory.appendingPathComponent("中文 name.tex")
        let existing = directory.appendingPathComponent("中文 name_files", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("keep"))
        let source = "Before $x$ ![diagram](data:image/png;base64,\(png.base64EncodedString())) After"
        let prepared = try PandocExportService.prepare(text: source, source: nil, destination: destination,
                                                       format: .latex, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
        let assets = try XCTUnwrap(prepared.latexAssets)
        XCTAssertEqual(assets.directoryName, "中文 name_files-1")
        XCTAssertEqual(assets.files.count, 1)
        let tex = try String(contentsOf: prepared.preparedURL, encoding: .utf8)
        XCTAssertTrue(tex.contains("中文 name_files-1/image-1.png"))
        XCTAssertTrue(tex.contains("Before") && tex.contains("After"))
        try PandocExportService.install(prepared, at: destination, isCancelled: { false }, validate: {})
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(assets.directoryName).appendingPathComponent("image-1.png")), png)
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("keep")), Data("keep".utf8))
        let next = try PandocExportService.prepare(text: source, source: nil, destination: destination,
                                                   format: .latex, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: next.preparedURL.deletingLastPathComponent()) }
        XCTAssertEqual(next.latexAssets?.directoryName, "中文 name_files-2")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(assets.directoryName).appendingPathComponent("image-1.png")), png)
        var profile = MarkdownExportProfile.standard(.latex); profile.rawType = "latex"
        let profileSource = "---\ntitle: 'Metadata Title'\n---\n\n[toc]\n\n" + source
        let profiled = try PandocExportService.prepare(text: profileSource, source: nil, destination: destination,
            profile: profile, title: "Fallback", executable: executable)
        defer { try? FileManager.default.removeItem(at: profiled.preparedURL.deletingLastPathComponent()) }
        let profileTex = try String(contentsOf: profiled.preparedURL, encoding: .utf8)
        XCTAssertTrue(profileTex.contains("Metadata Title"))
        XCTAssertTrue(profileTex.contains("\\tableofcontents"))
        XCTAssertTrue(profileTex.contains("中文 name_files-2/image-1.png"))
    }

    func testLatexSidecarRaceAndChangedFileNeverReplaceDestination() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        let source = "![diagram](data:image/png;base64,\(png.base64EncodedString()))"
        let destination = directory.appendingPathComponent("result.tex")
        try Data("original".utf8).write(to: destination)
        let first = try PandocExportService.prepare(text: source, source: nil, destination: destination, format: .latex, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: first.preparedURL.deletingLastPathComponent()) }
        let firstAssets = try XCTUnwrap(first.latexAssets)
        let occupied = directory.appendingPathComponent(firstAssets.directoryName, isDirectory: true)
        XCTAssertThrowsError(try PandocExportService.install(first, at: destination, isCancelled: { false }) { throw CancellationError() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: occupied.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: occupied.appendingPathComponent("keep"))
        XCTAssertThrowsError(try PandocExportService.install(first, at: destination, isCancelled: { false }, validate: {}))
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: occupied.appendingPathComponent("keep")), Data("foreign".utf8))
        let second = try PandocExportService.prepare(text: source, source: nil, destination: destination, format: .latex, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: second.preparedURL.deletingLastPathComponent()) }
        let secondAssets = try XCTUnwrap(second.latexAssets)
        let sidecar = directory.appendingPathComponent(secondAssets.directoryName, isDirectory: true)
        var checks = 0
        XCTAssertThrowsError(try PandocExportService.install(second, at: destination, isCancelled: { false }) {
            checks += 1
            if checks == 2 { try Data("changed".utf8).write(to: sidecar.appendingPathComponent("image-1.png")) }
        }) { error in
            guard let exportError = error as? PandocExportError,
                  case let .incompleteLatexAssets(path, _) = exportError else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(path, sidecar.path)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: sidecar.appendingPathComponent("image-1.png")), Data("changed".utf8))
        let third = try PandocExportService.prepare(text: source, source: nil, destination: destination, format: .latex, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: third.preparedURL.deletingLastPathComponent()) }
        let thirdAssets = try XCTUnwrap(third.latexAssets)
        let cancelledSidecar = directory.appendingPathComponent(thirdAssets.directoryName, isDirectory: true)
        var cancellationChecks = 0
        XCTAssertThrowsError(try PandocExportService.install(third, at: destination, isCancelled: {
            cancellationChecks += 1; return cancellationChecks >= 4
        }, validate: {})) { error in
            guard let exportError = error as? PandocExportError,
                  case let .incompleteLatexAssets(path, _) = exportError else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(path, cancelledSidecar.path)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: cancelledSidecar.appendingPathComponent("image-1.png")), png)
        let fourth = try PandocExportService.prepare(text: source, source: nil, destination: destination, format: .latex, title: "Test", executable: executable)
        defer { try? FileManager.default.removeItem(at: fourth.preparedURL.deletingLastPathComponent()) }
        let fourthAssets = try XCTUnwrap(fourth.latexAssets)
        let stagedImage = fourth.preparedURL.deletingLastPathComponent().appendingPathComponent("latex-assets/image-1.png")
        try Data("changed staging".utf8).write(to: stagedImage)
        XCTAssertThrowsError(try PandocExportService.install(fourth, at: destination, isCancelled: { false }, validate: {}))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fourthAssets.directoryName).path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    func testLatexProfileWritesRenderedDiagramsBesideTex() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Before $x$\n\n```mermaid\nflowchart TD\nA --> B\n```\n\n```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\n```sequence\nAlice->Bob: Hello\n```\n\nAfter"
        let document = EditorDocument(text: source, language: .markdown)
        let suite = "LatexDiagram." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let destination = directory.appendingPathComponent("中文 name.tex")
        var unexpectedModal = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { unexpectedModal = true; NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        state.exportMarkdown(profile: .standard(.latex), destination: destination, expectedRevision: nil)
        for _ in 0..<900 {
            if state.hasPreviousMarkdownExport || unexpectedModal { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(unexpectedModal)
        XCTAssertTrue(state.hasPreviousMarkdownExport)
        let tex = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(tex.contains("\\(x\\)"))
        XCTAssertTrue(tex.contains("Before") && tex.contains("After"))
        let sidecar = directory.appendingPathComponent("中文 name_files", isDirectory: true)
        for index in 1...3 {
            let name = "image-\(index).png"
            XCTAssertTrue(tex.contains("中文 name_files/" + name))
            let bytes = try Data(contentsOf: sidecar.appendingPathComponent(name))
            XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        }
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
    }

    func testLatexCommitRejectsChangedRevisionAndReportsSidecar() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Before\n\n```mermaid\nflowchart TD\nA --> B\n```\n\nAfter"
        let document = EditorDocument(text: source, language: .markdown)
        let suite = "LatexCommitStale." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let destination = directory.appendingPathComponent("result.tex")
        try Data("old output".utf8).write(to: destination)
        let reached = expectation(description: "between PNG checks and TeX commit")
        var sidecar: URL?
        state.latexExportWillCommit = { url in
            sidecar = url
            document.text = source
            NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
            reached.fulfill()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        state.exportMarkdown(profile: .standard(.latex), destination: destination, expectedRevision: nil)
        await fulfillment(of: [reached], timeout: 90)
        let kept = try XCTUnwrap(sidecar)
        for _ in 0..<100 {
            if document.statusMessage?.contains(kept.path) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(document.statusMessage?.contains(kept.path) == true)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old output".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("image-1.png").path))
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(state.hasPreviousMarkdownExport)
    }

    func testLatexCommitRejectsSidecarReplacedAfterBackgroundCheck() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Before\n\n```mermaid\nflowchart TD\nA --> B\n```\n\nAfter"
        let document = EditorDocument(text: source, language: .markdown)
        let suite = "LatexCommitSwap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let destination = directory.appendingPathComponent("result.tex")
        try Data("old output".utf8).write(to: destination)
        let moved = directory.appendingPathComponent("moved-owned", isDirectory: true)
        let reached = expectation(description: "sidecar replaced before commit")
        var sidecar: URL?, swapError: Error?
        state.latexExportWillCommit = { url in
            sidecar = url
            do {
                try FileManager.default.moveItem(at: url, to: moved)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                try Data("foreign".utf8).write(to: url.appendingPathComponent("keep"))
            } catch { swapError = error }
            reached.fulfill()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        state.exportMarkdown(profile: .standard(.latex), destination: destination, expectedRevision: nil)
        await fulfillment(of: [reached], timeout: 90)
        XCTAssertNil(swapError)
        let replacement = try XCTUnwrap(sidecar)
        for _ in 0..<100 {
            if document.statusMessage?.contains(replacement.path) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(document.statusMessage?.contains(replacement.path) == true)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old output".utf8))
        XCTAssertEqual(try Data(contentsOf: replacement.appendingPathComponent("keep")), Data("foreign".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("image-1.png").path))
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(state.hasPreviousMarkdownExport)
    }

    func testProfileDiagramPreparationUsesSelectedSyntaxSnapshot() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Before $x$\n\n```mermaid\nflowchart TD\nA --> B\n```\n\nAfter"
        let document = EditorDocument(text: source, language: .markdown)
        let suite = "PandocDiagramSyntax." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults); preferences.markdownInlineMath = false
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let destination = directory.appendingPathComponent("result.html")
        let profile = MarkdownExportProfile.standard(.html)
        var unexpectedModal = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { unexpectedModal = true; NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        for _ in 0..<900 {
            if state.hasPreviousMarkdownExport || unexpectedModal { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(unexpectedModal)
        XCTAssertTrue(state.hasPreviousMarkdownExport)
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains("$x$"))
        XCTAssertEqual(html.components(separatedBy: "data:image/png;base64,").count - 1, 1)
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
    }

    func testPDFEngineProfileReceivesRenderedDiagramAndOriginalMath() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let engine = directory.appendingPathComponent("pdflatex")
        let script = """
        #!/bin/sh
        for last do :; done
        /bin/cp "$last" \(quoted)/engine.tex
        image=$(/usr/bin/grep -o '/[^{}]*[.]png' "$last" | /usr/bin/head -1)
        /bin/cp "$image" \(quoted)/diagram.png || exit 1
        printf '%%PDF-1.4\\n%%fixture\\n' > "$(/usr/bin/dirname "$last")/input.pdf"
        """
        try script.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let source = "Before $x$\n\n```mermaid\nflowchart TD\nA --> B\n```\n\nAfter"
        let document = EditorDocument(text: source, language: .markdown)
        let suite = "PandocPDFDiagram." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        var profile = MarkdownExportProfile.pdfEngineProfile(); profile.pdfEngine = engine.path
        let destination = directory.appendingPathComponent("result.pdf")
        var unexpectedModal = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { unexpectedModal = true; NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        for _ in 0..<900 {
            if state.hasPreviousMarkdownExport || unexpectedModal { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(unexpectedModal)
        XCTAssertTrue(state.hasPreviousMarkdownExport)
        let tex = try String(contentsOf: directory.appendingPathComponent("engine.tex"), encoding: .utf8)
        XCTAssertTrue(tex.contains("\\(x\\)"))
        XCTAssertTrue(tex.contains("Before") && tex.contains("After"))
        XCTAssertEqual(Array(try Data(contentsOf: directory.appendingPathComponent("diagram.png")).prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
    }

    func testChangedDocumentDoesNotInstallPreparedImages() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.html")
        try Data("old output".utf8).write(to: destination)
        let suite = "PandocImagesStale." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "$x^2$", language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if NSApp.modalWindow != nil { NSApp.abortModal() }
        }
        defer { timer.invalidate() }
        state.exportMarkdown(profile: .standard(.html), destination: destination, expectedRevision: nil)
        document.text = "new text"
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
        for _ in 0..<100 {
            if document.statusMessage?.contains(L10n.tr("文档已更改，导出已取消。")) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(document.statusMessage?.contains(L10n.tr("文档已更改，导出已取消。")) == true)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old output".utf8))
        XCTAssertFalse(state.hasPreviousMarkdownExport)
    }

    func testStandardPandocPreparationStopsOnCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("pandoc")
        let marker = directory.appendingPathComponent("started")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try ("#!/bin/sh\nprintf started > \(quoted)\nexec /bin/sleep 30\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let destination = directory.appendingPathComponent("result.html")
        let operation = BlockOperation()
        let task = Task.detached {
            try PandocExportService.prepare(text: "text", source: nil, destination: destination, format: .html,
                                            title: "test", executable: executable, isCancelled: { operation.isCancelled })
        }
        defer { operation.cancel(); task.cancel() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        operation.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRepeatProfileExportUsesLatestSnapshotAndRetainsSettings() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PandocExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "first snapshot", language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let notified = expectation(description: "export menu is notified")
        var wasNotified = false
        let observation = state.objectWillChange.sink {
            DispatchQueue.main.async {
                if state.hasPreviousMarkdownExport && !wasNotified {
                    wasNotified = true
                    notified.fulfill()
                }
            }
        }
        let destination = directory.appendingPathComponent("output.html")
        var profile = MarkdownExportProfile.standard(.html)
        profile.arguments = "--metadata=description:SavedSetting"
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        for _ in 0..<300 {
            if state.hasPreviousMarkdownExport { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(state.hasPreviousMarkdownExport)
        await fulfillment(of: [notified], timeout: 5)
        withExtendedLifetime(observation) {}
        let first = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(first.contains("first snapshot"))
        XCTAssertTrue(first.contains("SavedSetting"))
        document.text = "second snapshot"
        state.repeatMarkdownExport(overwrite: true)
        for _ in 0..<300 {
            if let text = try? String(contentsOf: destination, encoding: .utf8), text.contains("second snapshot") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let second = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(second.contains("second snapshot"))
        XCTAssertTrue(second.contains("SavedSetting"))
        XCTAssertEqual(document.text, "second snapshot")
    }

    func testExtensionsFieldRetainsSpaceWhileTypingMultipleExtensions() async throws {
        _ = NSApplication.shared
        var extensions = ["docx"]
        let binding = Binding<[String]>(get: { extensions }, set: { extensions = $0 })
        let host = NSHostingView(rootView: MarkdownExportExtensionsField(extensions: binding))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textField(in: host))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("docx ", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "docx ")
        editor.insertText("rst", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(extensions, ["docx", "rst"])
    }

    func testProfileUsesTemplateAndPreservesTemplateFile() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = directory.appendingPathComponent("template with spaces.html")
        let templateBytes = Data("custom-marker: $title$\n$body$".utf8)
        try templateBytes.write(to: template)
        var profile = MarkdownExportProfile.standard(.html)
        profile.templatePath = template.path
        let result = try PandocExportService.prepare(text: "---\ntitle: My title\n---\n\nHello", source: nil,
                                                     destination: directory.appendingPathComponent("out.html"),
                                                     profile: profile, title: "fallback", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(output.contains("custom-marker: My title"))
        XCTAssertTrue(output.contains("Hello"))
        XCTAssertEqual(try Data(contentsOf: template), templateBytes)
    }

    func testProfileUsesReferenceDocumentAndEPUBCover() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDestination = directory.appendingPathComponent("reference.docx")
        let reference = try PandocExportService.prepare(text: "# Reference", source: nil, destination: referenceDestination,
                                                        format: .docx, title: "Reference", executable: executable)
        defer { try? FileManager.default.removeItem(at: reference.preparedURL.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: reference.preparedURL, to: referenceDestination)
        let referenceBytes = try Data(contentsOf: referenceDestination)
        var docxProfile = MarkdownExportProfile.standard(.docx)
        docxProfile.referenceDocumentPath = referenceDestination.path
        let docx = try PandocExportService.prepare(text: "# Profile document", source: nil,
                                                   destination: directory.appendingPathComponent("out.docx"),
                                                   profile: docxProfile, title: "Document", executable: executable)
        defer { try? FileManager.default.removeItem(at: docx.preparedURL.deletingLastPathComponent()) }
        XCTAssertTrue(try PandocImportService.convert(source: docx.preparedURL, executable: executable).text.contains("Profile document"))
        XCTAssertEqual(try Data(contentsOf: referenceDestination), referenceBytes)
        let cover = directory.appendingPathComponent("cover.png")
        let coverBytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        try coverBytes.write(to: cover)
        var epubProfile = MarkdownExportProfile.standard(.epub)
        epubProfile.epubCoverPath = cover.path
        epubProfile.epubTOCDepth = 2
        let epub = try PandocExportService.prepare(text: "# Book section\n\nEPUB content", source: nil,
                                                   destination: directory.appendingPathComponent("out.epub"),
                                                   profile: epubProfile, title: "Book", executable: executable)
        defer { try? FileManager.default.removeItem(at: epub.preparedURL.deletingLastPathComponent()) }
        let imported = try PandocImportService.convert(source: epub.preparedURL, executable: executable)
        XCTAssertTrue(imported.text.contains("EPUB content"))
        XCTAssertTrue(imported.text.contains("data:image/png;base64,"))
        XCTAssertEqual(try Data(contentsOf: cover), coverBytes)
    }

    func testRawTOCUsesOnlyConfirmedStandaloneMarkers() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.md")
        let original = "# 中文 😀\r\n\r\n[toc]\r\n\r\n`[toc]`\r\n\r\n\\[toc]\r\n\r\n> [toc]\r\n\r\n- [toc]\r\n\r\n[toc]\r\n"
        try Data(original.utf8).write(to: source)
        for (format, raw, token) in [(PandocExportFormat.mediawiki, "mediawiki", "__TOC__"), (.latex, "latex", "\\tableofcontents")] {
            var profile = MarkdownExportProfile.standard(format)
            profile.rawType = raw
            let destination = directory.appendingPathComponent("output." + format.fileExtension)
            try Data("old".utf8).write(to: destination)
            let result = try PandocExportService.prepare(text: original, source: source, destination: destination,
                                                         profile: profile, title: "Document", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
            XCTAssertEqual(output.components(separatedBy: token).count - 1, 2)
            XCTAssertFalse(output.contains("LACEDITORTOC"))
            XCTAssertTrue(output.contains("toc"))
            XCTAssertEqual(try Data(contentsOf: source), Data(original.utf8))
            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        }
    }

    func testRawTOCDoesNotReplaceMarkerInsideComplexYAML() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let text = "---\ndescription: |\n\n  [toc]\n\ntitle: Test title\n---\n\n[toc]\n\nbody"
        try Data(text.utf8).write(to: source)
        let template = directory.appendingPathComponent("template.wiki")
        try Data("$title$\n$description$\n$body$".utf8).write(to: template)
        var profile = MarkdownExportProfile.standard(.mediawiki)
        profile.rawType = "mediawiki"
        profile.templatePath = template.path
        let result = try PandocExportService.prepare(text: text, source: source,
                                                     destination: directory.appendingPathComponent("result.wiki"),
                                                     profile: profile, title: "fallback", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(output.contains("Test title"))
        XCTAssertTrue(output.contains("[toc]"))
        XCTAssertEqual(output.components(separatedBy: "__TOC__").count - 1, 1)
        XCTAssertFalse(output.contains("LACEDITORTOC"))
        XCTAssertEqual(try Data(contentsOf: source), Data(text.utf8))
    }

    func testRawTOCUsesOneFrontMatterBoundaryForBothYAMLEndings() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = MarkdownExportProfile.standard(.mediawiki)
        profile.rawType = "mediawiki"
        for closing in ["---", "..."] {
            let text = "---\ndescription: |\n\n  [toc]\n\ntitle: T\n\(closing)\n---\n\n[toc]\n\n---\n"
            let destination = directory.appendingPathComponent("result.wiki")
            let result = try PandocExportService.prepare(text: text, source: nil, destination: destination,
                                                         profile: profile, title: "fallback", executable: executable)
            defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
            let output = try String(contentsOf: result.preparedURL, encoding: .utf8)
            XCTAssertEqual(output.components(separatedBy: "__TOC__").count - 1, 1)
            XCTAssertFalse(output.contains("LACEDITORTOC"))
        }
    }

}

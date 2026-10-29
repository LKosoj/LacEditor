import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownExportImagesServiceTests: XCTestCase {
    func testImageAltPreservesMarkdownPunctuationInTable() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        let markdown = try MarkdownExportImagesService.markdownImage(image, alt: "中😀 x*y*z_2 `code` &a; \\ |")
        let page = MarkdownRenderer.renderPage("| A |\n|---|\n| \(markdown) |", darkMode: false)
        XCTAssertTrue(page.body.contains("alt=\"中😀 x*y*z_2 `code` &amp;a; \\ |\""))
    }

    func testPreparesConfirmedMathAndDiagramsWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let source = "中文😀 $\\def\\R{R}$ then $\\R$\n\n> $$\n> x+1\n> $$\n\n| A |\n|---|\n| 中\\|😀 $x$ |\n\n```mermaid\nflowchart TD\nA --> B\n```\n\n```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\n```sequence\nAlice->Bob: Hello\n```"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "prepared export snapshot")
        var output: String?
        let service = MarkdownExportImagesService(source: document.synchronizedSnapshot().text, width: 400, dark: false, fontSize: 16, mathOptions: .init(), isCurrent: { true }) { result in
            if case let .success(value) = result { output = value }
            else { XCTFail("Preparation failed: \(result)") }
            done.fulfill()
        }
        service.start()
        await fulfillment(of: [done], timeout: 90)
        let prepared = try XCTUnwrap(output)
        let images = try MarkdownImageUploadService.images(in: prepared)
        XCTAssertEqual(images.count, 7)
        for image in images {
            let payload = try MarkdownImageUploadService.payload(address: image.address, document: nil)
            XCTAssertEqual(Array(payload.data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        }
        XCTAssertTrue(prepared.contains("中\\|😀 !["))
        XCTAssertTrue(prepared.contains("> !["))
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
    }

    func testPreparesConfirmedEmojiWithoutChangingSourceOrCode() async throws {
        let source = "中😀 :smile: \\:heart: `:smile:` [link](https://example.com/:smile:)\n\n| H |\n|---|\n| a\\|b :heart: |"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "prepared emoji")
        var output: String?
        let service = MarkdownExportImagesService(source: source, width: 400, dark: false, fontSize: 16,
            mathOptions: .init(), isCurrent: { true }) { result in
            if case let .success(value) = result { output = value } else { XCTFail("Preparation failed: \(result)") }
            done.fulfill()
        }
        service.start()
        await fulfillment(of: [done], timeout: 30)
        let prepared = try XCTUnwrap(output)
        XCTAssertTrue(prepared.contains("中😀 😄"))
        XCTAssertTrue(prepared.contains("a\\|b ❤️"))
        XCTAssertTrue(prepared.contains("\\:heart: `:smile:` [link](https://example.com/:smile:)"))
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
    }

    func testPreparationUsesSyntaxSnapshotAndCanPrepareOnlyDiagrams() async throws {
        _ = NSApplication.shared
        let source = "before $x$ and $ spaced $5 :smile:\n\n```mermaid\nflowchart TD\nA --> B\n```"
        func prepare(syntax: MarkdownSyntaxOptions, includeMath: Bool) async throws -> String {
            let done = expectation(description: "syntax-aware image preparation")
            var output: String?
            let service = MarkdownExportImagesService(source: source, width: 400, dark: false, fontSize: 16,
                mathOptions: .init(), syntax: syntax, includeMath: includeMath, isCurrent: { true }) { result in
                if case let .success(value) = result { output = value } else { XCTFail("Preparation failed: \(result)") }
                done.fulfill()
            }
            service.start()
            await fulfillment(of: [done], timeout: 90)
            withExtendedLifetime(service) {}
            return try XCTUnwrap(output)
        }
        let disabled = try await prepare(syntax: .init(inlineMath: false), includeMath: true)
        XCTAssertTrue(disabled.contains("$x$ and $ spaced $5"))
        XCTAssertEqual(try MarkdownImageUploadService.images(in: disabled).count, 1)
        let legacy = try await prepare(syntax: .init(legacyInlineMath: true), includeMath: true)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: legacy).count, 3)
        let diagramsOnly = try await prepare(syntax: .init(legacyInlineMath: true), includeMath: false)
        XCTAssertTrue(diagramsOnly.contains("$x$ and $ spaced $5 :smile:"))
        XCTAssertEqual(try MarkdownImageUploadService.images(in: diagramsOnly).count, 1)
    }

    func testCancellationAndStalenessCompleteOnce() async throws {
        let done = expectation(description: "cancelled")
        var completions = 0
        let service = MarkdownExportImagesService(source: "$x$", width: 400, dark: false, fontSize: 16, mathOptions: .init(), isCurrent: { true }) { result in
            completions += 1
            guard case .failure = result else { XCTFail("Expected cancellation"); done.fulfill(); return }
            done.fulfill()
        }
        service.start()
        service.cancel()
        await fulfillment(of: [done], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(completions, 1)
        let stale = expectation(description: "stale")
        let staleService = MarkdownExportImagesService(source: "$x$", width: 400, dark: false, fontSize: 16, mathOptions: .init(), isCurrent: { false }) { result in
            guard case .failure = result else { XCTFail("Expected stale refusal"); stale.fulfill(); return }
            stale.fulfill()
        }
        staleService.start()
        await fulfillment(of: [stale], timeout: 5)
    }
}

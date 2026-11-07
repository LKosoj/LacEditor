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
        let page = MarkdownHTMLRenderer.renderPage("| A |\n|---|\n| \(markdown) |", darkMode: false)
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

    // Диапазоны формул и диаграмм после кириллицы, CJK, эмодзи и \r\n (UTF-16) должны попадать точно: текст вокруг не портится.
    func testPreparationKeepsSurroundingTextWithCRLFAndNonASCII() async throws {
        _ = NSApplication.shared
        let source = "Привет 中文😀 $x$ конец\r\n\r\n$$\r\ny+1\r\n$$\r\n\r\n```mermaid\r\nflowchart TD\r\nA --> B\r\n```\r\n\r\nХвост 😀"
        let done = expectation(description: "prepared crlf snapshot")
        var output: String?
        let service = MarkdownExportImagesService(source: source, width: 400, dark: false, fontSize: 16, mathOptions: .init(), isCurrent: { true }) { result in
            if case let .success(value) = result { output = value } else { XCTFail("Preparation failed: \(result)") }
            done.fulfill()
        }
        service.start()
        await fulfillment(of: [done], timeout: 90)
        withExtendedLifetime(service) {}
        let prepared = try XCTUnwrap(output)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: prepared).count, 3)
        XCTAssertTrue(prepared.hasPrefix("Привет 中文😀 !["))
        XCTAssertTrue(prepared.contains(") конец\r\n\r\n!["))
        XCTAssertTrue(prepared.hasSuffix(")\r\n\r\nХвост 😀"))
        XCTAssertFalse(prepared.contains("$$"))
        XCTAssertFalse(prepared.contains("mermaid"))
    }

    // Формула и эмодзи внутри <audio> не заменяются при подготовке экспорта (отсев показа, как в редакторе).
    func testPreparationSkipsFormulasAndEmojiInsideAudio() async throws {
        let source = "Привет 中文😀\r\n\r\n<audio src=\"a.mp3\">$x$ :smile:</audio>\r\n\r\nконец"
        let done = expectation(description: "prepared audio snapshot")
        var output: String?
        let service = MarkdownExportImagesService(source: source, width: 400, dark: false, fontSize: 16, mathOptions: .init(), isCurrent: { true }) { result in
            if case let .success(value) = result { output = value } else { XCTFail("Preparation failed: \(result)") }
            done.fulfill()
        }
        service.start()
        await fulfillment(of: [done], timeout: 90)
        withExtendedLifetime(service) {}
        XCTAssertEqual(try XCTUnwrap(output), source)
    }

    // Диаграмма в цитате не заменяется картинкой при подготовке экспорта.
    func testPreparationKeepsDiagramInsideQuote() async throws {
        let source = "Привет 中😀\r\n\r\n> ```mermaid\r\n> A --> B\r\n> ```\r\n"
        let done = expectation(description: "prepared quote diagram")
        var output: String?
        let service = MarkdownExportImagesService(source: source, width: 400, dark: false, fontSize: 16, mathOptions: .init(), isCurrent: { true }) { result in
            if case let .success(value) = result { output = value } else { XCTFail("Preparation failed: \(result)") }
            done.fulfill()
        }
        service.start()
        await fulfillment(of: [done], timeout: 90)
        withExtendedLifetime(service) {}
        XCTAssertEqual(try XCTUnwrap(output), source)
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

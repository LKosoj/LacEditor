import AppKit
import WebKit
import XCTest
@testable import LacEditor

@MainActor
final class LegacyDiagramRenderServiceTests: XCTestCase {
    func testFlowAndBothSequenceThemesProduceCompleteImages() async throws {
        _ = NSApplication.shared
        let examples: [(LegacyDiagramRenderService.Kind, LegacyDiagramRenderService.Theme, String)] = [
            (.flow, .simple, "s=>start: 中文\nc=>condition: Choice?\ne=>end: End\ns->c\nc(yes)->e\nc(no)->s"),
            (.sequence, .simple, "Alice->Bob: 中文\nNote right of Bob: Note\nBob-->Alice: Done"),
            (.sequence, .hand, "Alice->Bob: 中文\nNote right of Bob: Note\nBob-->Alice: Done")
        ]
        for (kind, theme, source) in examples {
            let done = expectation(description: "diagram")
            var image: NSImage?
            let service = LegacyDiagramRenderService(code: source, kind: kind, theme: theme, width: 400) { result in
                if case let .success(value) = result { image = value }
                else { XCTFail("Diagram failed: \(result)") }
                done.fulfill()
            }
            service.start()
            await fulfillment(of: [done], timeout: 30)
            let svg = try XCTUnwrap(service.renderedSVG)
            XCTAssertTrue(XMLParser(data: svg).parse())
            let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
            XCTAssertTrue(svgText.contains("<svg"))
            XCTAssertFalse(svgText.contains("data:image/png"))
            if theme == .hand { XCTAssertTrue(svgText.contains("data:font/ttf;base64,")) }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image?.tiffRepresentation)))
            XCTAssertGreaterThan(bitmap.pixelsWide, 10)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 10)
            var darkPixels = 0
            var left = bitmap.pixelsWide, right = -1, top = bitmap.pixelsHigh, bottom = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.alphaComponent > 0.5, color.redComponent < 0.7, color.greenComponent < 0.7, color.blueComponent < 0.7 {
                        darkPixels += 1
                        left = min(left, x); right = max(right, x)
                        top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
            XCTAssertGreaterThan(darkPixels, 20)
            XCTAssertGreaterThan(left, 0)
            XCTAssertGreaterThan(top, 0)
            XCTAssertLessThan(right, bitmap.pixelsWide - 1)
            XCTAssertLessThan(bottom, bitmap.pixelsHigh - 1)
        }
    }

    func testInvalidInputAndCancellationCompleteOnce() async throws {
        _ = NSApplication.shared
        let failed = expectation(description: "invalid")
        let invalid = LegacyDiagramRenderService(code: "this is not valid", kind: .sequence, width: 300) { result in
            if case .success = result { XCTFail("Invalid diagram rendered") }
            failed.fulfill()
        }
        invalid.start()
        await fulfillment(of: [failed], timeout: 30)
        let cancelled = expectation(description: "cancelled")
        var completions = 0
        let service = LegacyDiagramRenderService(code: "s=>start: Start", kind: .flow, width: 300) { result in
            completions += 1
            guard case let .failure(error) = result, let error = error as? LegacyDiagramRenderService.RenderError,
                  case .cancelled = error else {
                XCTFail("Expected cancellation"); cancelled.fulfill(); return
            }
            cancelled.fulfill()
        }
        service.start()
        service.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(completions, 1)
    }
}

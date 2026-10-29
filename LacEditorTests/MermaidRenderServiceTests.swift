import AppKit
import WebKit
import XCTest
@testable import LacEditor

private final class DiagramSVGNavigation: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    var error: Error?
    init(_ finished: XCTestExpectation) { self.finished = finished }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error; finished.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error; finished.fulfill() }
}

@MainActor
final class MermaidRenderServiceTests: XCTestCase {
    private func svgSnapshot(_ data: Data, size: NSSize) async throws -> NSImage {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = WKWebView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let finished = expectation(description: "SVG loaded")
        let delegate = DiagramSVGNavigation(finished)
        view.navigationDelegate = delegate
        XCTAssertNotNil(view.load(data, mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)))
        await fulfillment(of: [finished], timeout: 30)
        if let error = delegate.error { throw error }
        return try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func testExportedSVGRemainsVisibleForMermaidAndHandSequence() async throws {
        _ = NSApplication.shared
        let finished = expectation(description: "Mermaid rendered")
        var original: NSImage?
        let mermaid = MermaidRenderService(code: "flowchart TD\nA[Start] --> B[End]", width: 480, dark: false) { result in
            if case let .success(image) = result { original = image }
            finished.fulfill()
        }
        mermaid.start()
        await fulfillment(of: [finished], timeout: 30)
        let image = try XCTUnwrap(original)
        let mermaidSVG = try XCTUnwrap(mermaid.renderedSVG)
        let handDone = expectation(description: "hand sequence rendered")
        var handImage: NSImage?
        let hand = LegacyDiagramRenderService(code: "Alice->Bob: Hello\nBob-->Alice: Done", kind: .sequence, theme: .hand, width: 480) { result in
            if case let .success(value) = result { handImage = value }
            handDone.fulfill()
        }
        hand.start()
        await fulfillment(of: [handDone], timeout: 30)
        for (svg, original) in [(mermaidSVG, image), (try XCTUnwrap(hand.renderedSVG), try XCTUnwrap(handImage))] {
            let rendered = try await svgSnapshot(svg, size: original.size)
            func darkPixels(_ value: NSImage) throws -> Int {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(value.tiffRepresentation)))
                var count = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.alphaComponent > 0.5, color.redComponent + color.greenComponent + color.blueComponent < 2.4 { count += 1 }
                    }
                }
                return count
            }
            let before = try darkPixels(original), after = try darkPixels(rendered)
            XCTAssertGreaterThan(before, 20)
            XCTAssertGreaterThan(after, 20)
            XCTAssertGreaterThan(Double(after) / Double(max(1, before)), 0.35)
            XCTAssertLessThan(Double(after) / Double(max(1, before)), 2.8)
        }
    }

    func testBundledDiagramsProduceVisibleImages() async throws {
        _ = NSApplication.shared
        let diagrams = [
            "flowchart TD\nA[Start] --> B[End]\nstyle A fill:#ff0000,stroke:#ff0000",
            "sequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Reply",
            "classDiagram\nAnimal <|-- Dog\nAnimal : +name",
            "gantt\ntitle Schedule\ndateFormat YYYY-MM-DD\nsection Work\nTask :a1, 2024-01-01, 3d"
        ]
        for (index, code) in diagrams.enumerated() {
            let finished = expectation(description: "diagram \(index)")
            var output: NSImage?
            var failure: Error?
            let service = MermaidRenderService(code: code, width: 480, dark: index == 1) { result in
                switch result {
                case let .success(image): output = image
                case let .failure(error): failure = error
                }
                finished.fulfill()
            }
            service.start()
            await fulfillment(of: [finished], timeout: 30)
            XCTAssertNil(failure, "\(String(describing: failure))")
            let image = try XCTUnwrap(output)
            let svg = try XCTUnwrap(service.renderedSVG)
            XCTAssertTrue(XMLParser(data: svg).parse())
            let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
            XCTAssertTrue(svgText.contains("<svg"))
            XCTAssertTrue(svgText.contains("<style"))
            XCTAssertFalse(svgText.contains("data:image/png"))
            XCTAssertEqual(image.size.width, 480)
            XCTAssertGreaterThan(image.size.height, 10)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var colors = Set<UInt32>()
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 100)) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 100)) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let red = UInt32((color.redComponent * 255).rounded())
                    let green = UInt32((color.greenComponent * 255).rounded())
                    let blue = UInt32((color.blueComponent * 255).rounded())
                    colors.insert((red << 16) | (green << 8) | blue)
                }
            }
            XCTAssertGreaterThan(colors.count, 2, "Diagram contains no visible detail")
        }
    }

    func testInvalidDiagramReturnsError() async {
        _ = NSApplication.shared
        let finished = expectation(description: "invalid diagram")
        var failed = false
        let service = MermaidRenderService(code: "flowchart TD\nA -->", width: 400, dark: false) { result in
            if case .failure = result { failed = true }
            finished.fulfill()
        }
        service.start()
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertTrue(failed)
    }

    func testCancelCompletesOnceAndReleasesService() async {
        _ = NSApplication.shared
        let finished = expectation(description: "cancel")
        var completions = 0
        var cancelled = false
        var service: MermaidRenderService? = MermaidRenderService(code: "flowchart TD\nA --> B", width: 400, dark: false) { result in
            completions += 1
            if case let .failure(error) = result, let error = error as? MermaidRenderService.RenderError, case .cancelled = error { cancelled = true }
            finished.fulfill()
        }
        weak var weakService = service
        service?.start()
        service?.cancel()
        service?.cancel()
        service = nil
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(weakService)
    }
}

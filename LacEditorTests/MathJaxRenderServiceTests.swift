import AppKit
import WebKit
import XCTest
@testable import LacEditor

@MainActor
final class MathJaxRenderServiceTests: XCTestCase {
    func testReferenceRectsPointToFormulaInSameDocument() async throws {
        _ = NSApplication.shared
        let expressions = [MathJaxRenderService.Expression(source: #"\ref{eq:abc}"#, display: false),
                           MathJaxRenderService.Expression(source: #"x\tag{1}\label{eq:abc}"#, display: true),
                           MathJaxRenderService.Expression(source: #"\ref{missing}"#, display: false)]
        let done = expectation(description: "reference images")
        var images: [NSImage?]?
        let service = MathJaxRenderService(expressions: expressions, outputIndices: [0, 1, 2], width: 400, dark: false, retainForRequests: true) {
            if case let .success(value) = $0 { images = value }
            done.fulfill()
        }
        defer { service.cancel() }
        service.start()
        await fulfillment(of: [done], timeout: 30)
        let output = try XCTUnwrap(images)
        guard output.count == 3 else { return XCTFail("Expected three formulas") }
        let image = try XCTUnwrap(output[0])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let reference = try XCTUnwrap(service.references[0]?.first)
        XCTAssertEqual(service.references[0]?.count, 1)
        XCTAssertEqual(reference.targetIndex, 1)
        XCTAssertEqual(reference.latex, #"\ref{eq:abc}"#)
        XCTAssertTrue(service.mathML[0]?.contains("<math") == true)
        XCTAssertGreaterThan(reference.rect.width, 0)
        XCTAssertGreaterThan(reference.rect.height, 0)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh)).contains(reference.rect))
        XCTAssertTrue(service.references[2]?.isEmpty == true)
        let again = expectation(description: "retained reference")
        service.requestImages([0]) { _ in again.fulfill() }
        await fulfillment(of: [again], timeout: 30)
        XCTAssertEqual(service.references[0]?.first?.targetIndex, 1)

        let isolated = expectation(description: "separate document")
        let other = MathJaxRenderService(expressions: [expressions[0]], outputIndices: [0], width: 400, dark: false, retainForRequests: true) { _ in isolated.fulfill() }
        defer { other.cancel() }
        other.start()
        await fulfillment(of: [isolated], timeout: 30)
        XCTAssertTrue(other.references[0]?.isEmpty == true)
    }

    func testMathMLUsesResolvedDocumentMacro() async throws {
        let done = expectation(description: "resolved MathML")
        let expressions = [MathJaxRenderService.Expression(source: #"\def\part{\frac{中}{2}}"#, display: true),
                           MathJaxRenderService.Expression(source: #"\part"#, display: false)]
        let service = MathJaxRenderService(expressions: expressions, outputIndices: [1], width: 400, dark: false) { _ in done.fulfill() }
        service.start()
        await fulfillment(of: [done], timeout: 30)
        let math = try XCTUnwrap(service.mathML[1])
        XCTAssertTrue(math.contains("<mfrac"))
        XCTAssertTrue(math.contains("中"))
    }

    func testNumberingAndPhysicsOptionsUseIsolatedDocuments() async throws {
        _ = NSApplication.shared
        func render(_ options: MathJaxRenderService.Options) async throws -> [NSImage?] {
            let done = expectation(description: "MathJax options")
            var images: [NSImage?]?
            let expressions = [MathJaxRenderService.Expression(source: "x", display: true),
                               MathJaxRenderService.Expression(source: #"\begin{equation}y\end{equation}"#, display: true),
                               MathJaxRenderService.Expression(source: #"\dv{x}{t}"#, display: true)]
            let service = MathJaxRenderService(expressions: expressions, outputIndices: [0, 1, 2], width: 400, dark: false, options: options) {
                if case let .success(value) = $0 { images = value }
                done.fulfill()
            }
            service.start()
            await fulfillment(of: [done], timeout: 30)
            return try XCTUnwrap(images)
        }
        let none = try await render(.init(physics: false, numbering: .none))
        let ams = try await render(.init(physics: true, numbering: .ams))
        let all = try await render(.init(physics: true, numbering: .all))
        XCTAssertEqual(none.count, 3)
        XCTAssertEqual(ams.count, 3)
        XCTAssertEqual(all.count, 3)
        guard none.count == 3, ams.count == 3, all.count == 3 else { return }
        XCTAssertGreaterThan(try XCTUnwrap(all[0]).size.width, try XCTUnwrap(none[0]).size.width)
        XCTAssertGreaterThan(try XCTUnwrap(ams[1]).size.width, try XCTUnwrap(none[1]).size.width)
        XCTAssertEqual(try XCTUnwrap(ams[0]).size.width, try XCTUnwrap(none[0]).size.width, accuracy: 1)
        func hasRed(_ image: NSImage) throws -> Bool {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.alphaComponent > 0.5, color.redComponent > 0.7,
                       color.greenComponent < 0.3, color.blueComponent < 0.3 { return true }
                }
            }
            return false
        }
        XCTAssertTrue(try hasRed(XCTUnwrap(none[2])))
        XCTAssertFalse(try hasRed(XCTUnwrap(ams[2])))
        let separate = try await render(.init(physics: false, numbering: .none))
        XCTAssertEqual(separate.count, 3)
        guard separate.count == 3 else { return }
        XCTAssertTrue(try hasRed(XCTUnwrap(separate[2])))
    }

    func testBundledFormulasProduceVisibleImages() async throws {
        _ = NSApplication.shared
        let formulas = [#"\frac{a}{b}"#, #"\begin{matrix}a&b\\c&d\end{matrix}"#,
                        #"\ce{H2O + CO2 -> H2CO3}"#, #"\dv{x}{t}"#,
                        #"\sum_{n=0}^{\infty}\frac{1}{n!}"#, #"\boxed{\frac{x}{y}}\tag{1}"#,
                        #"\mathbb{R}\aleph"#]
        for (index, source) in formulas.enumerated() {
            let finished = expectation(description: source)
            var output: NSImage?
            var failure: Error?
            let service = MathJaxRenderService(source: source, display: true, width: 400, dark: index == 1) { result in
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
            XCTAssertGreaterThan(image.size.width, 4)
            XCTAssertGreaterThan(image.size.height, 4)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            for point in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)).alphaComponent, 0.05)
            }
            if source.contains(#"\tag"#) {
                var tagVisible = false
                for y in 0..<bitmap.pixelsHigh {
                    for x in (bitmap.pixelsWide * 3 / 4)..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 { tagVisible = true; break }
                    }
                    if tagVisible { break }
                }
                XCTAssertTrue(tagVisible, "Equation tag is missing")
            }
            var matchingColor = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
                        matchingColor = index == 1 ? color.redComponent > 0.75 : color.redComponent < 0.25
                        if matchingColor { break }
                    }
                }
                if matchingColor { break }
            }
            XCTAssertTrue(matchingColor, "Formula color does not match the requested theme")
        }
    }

    func testFormulaImageUsesRequestedFontSize() async throws {
        _ = NSApplication.shared
        func render(_ fontSize: CGFloat) async throws -> NSImage {
            let finished = expectation(description: "formula size \(fontSize)")
            var image: NSImage?
            let service = MathJaxRenderService(source: #"\frac{x}{y}"#, display: false, width: 400, dark: false, fontSize: fontSize) {
                if case let .success(value) = $0 { image = value }
                finished.fulfill()
            }
            service.start()
            await fulfillment(of: [finished], timeout: 30)
            return try XCTUnwrap(image)
        }
        let small = try await render(14)
        let large = try await render(28)
        XCTAssertGreaterThan(large.size.width, small.size.width)
        XCTAssertGreaterThan(large.size.height, small.size.height)
    }

    func testBoxAroundPhantomHasFourVisibleSides() async throws {
        _ = NSApplication.shared
        let done = expectation(description: "boxed phantom")
        var result: NSImage?
        let service = MathJaxRenderService(source: #"\boxed{\phantom{XXX}}"#, display: true, width: 400, dark: false) { value in
            if case let .success(image) = value { result = image }
            done.fulfill()
        }
        service.start()
        await fulfillment(of: [done], timeout: 30)
        let image = try XCTUnwrap(result)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var left = bitmap.pixelsWide, right = -1, top = bitmap.pixelsHigh, bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThan(right - left, 3)
        XCTAssertGreaterThan(bottom - top, 3)
        guard right > left, bottom > top else { return }
        func visible(nearX x: Int, y: Int) -> Bool {
            for row in max(0, y - 1)...min(bitmap.pixelsHigh - 1, y + 1) {
                for column in max(0, x - 1)...min(bitmap.pixelsWide - 1, x + 1) {
                    if (bitmap.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.1 { return true }
                }
            }
            return false
        }
        XCTAssertTrue(visible(nearX: (left + right) / 2, y: top))
        XCTAssertTrue(visible(nearX: (left + right) / 2, y: bottom))
        XCTAssertTrue(visible(nearX: left, y: (top + bottom) / 2))
        XCTAssertTrue(visible(nearX: right, y: (top + bottom) / 2))
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.05)
    }

    func testRetainedDocumentProducesTwoVisibleBatches() async throws {
        _ = NSApplication.shared
        let expressions = [MathJaxRenderService.Expression(source: #"\def\R{\frac{a}{b}}"#, display: false),
                           MathJaxRenderService.Expression(source: #"\R"#, display: true),
                           MathJaxRenderService.Expression(source: #"\R + 1"#, display: true)]
        let first = expectation(description: "first visible formula")
        var firstImages: [NSImage?]?
        let service = MathJaxRenderService(expressions: expressions, outputIndices: [1], width: 400, dark: false, retainForRequests: true) {
            if case let .success(images) = $0 { firstImages = images }
            first.fulfill()
        }
        defer { service.cancel() }
        service.start()
        await fulfillment(of: [first], timeout: 30)
        XCTAssertNotNil(try XCTUnwrap(firstImages).first ?? nil)
        let second = expectation(description: "next visible formula")
        var secondImages: [NSImage?]?
        service.requestImages([2]) {
            if case let .success(images) = $0 { secondImages = images }
            second.fulfill()
        }
        await fulfillment(of: [second], timeout: 30)
        XCTAssertNotNil(try XCTUnwrap(secondImages).first ?? nil)
        service.webViewWebContentProcessDidTerminate(WKWebView(frame: .zero))
        var unavailable = false
        service.requestImages([1]) { result in
            if case let .failure(error) = result, let reason = error as? MathJaxRenderService.RenderError,
               case .unavailable = reason { unavailable = true }
        }
        XCTAssertTrue(unavailable)
    }

    func testDocumentBatchResolvesForwardReferenceAndMacro() async throws {
        _ = NSApplication.shared
        func render(_ expressions: [MathJaxRenderService.Expression], _ indices: [Int]) async throws -> [NSImage?] {
            let done = expectation(description: "document batch")
            var result: Result<[NSImage?], Error>?
            let service = MathJaxRenderService(expressions: expressions, outputIndices: indices, width: 400, dark: false) {
                result = $0
                done.fulfill()
            }
            service.start()
            await fulfillment(of: [done], timeout: 30)
            return try XCTUnwrap(result).get()
        }
        let batch = try await render([
            .init(source: #"\ref{eq}"#, display: true),
            .init(source: #"\def\RR{R}"#, display: true),
            .init(source: #"\RR"#, display: false),
            .init(source: #"x\tag{7}\label{eq}"#, display: true),
            .init(source: #"\frac{"#, display: true)
        ], [0, 2, 4])
        XCTAssertEqual(batch.count, 3)
        XCTAssertNil(batch[2])
        let expected = try await render([.init(source: #"\text{7}"#, display: true),
                                         .init(source: "R", display: false)], [0, 1])
        func alpha(_ image: NSImage?) throws -> (Int, Int, [UInt8]) {
            let image = try XCTUnwrap(image)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var values: [UInt8] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    values.append(UInt8(((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded()))
                }
            }
            return (bitmap.pixelsWide, bitmap.pixelsHigh, values)
        }
        for index in 0..<2 {
            let actual = try alpha(batch[index]), reference = try alpha(expected[index])
            XCTAssertEqual(actual.0, reference.0)
            XCTAssertEqual(actual.1, reference.1)
            XCTAssertEqual(actual.2, reference.2)
        }
        let isolated = try await render([.init(source: #"\RR"#, display: false)], [0])
        let independent = try alpha(isolated[0]), defined = try alpha(batch[1])
        XCTAssertTrue(independent.0 != defined.0 || independent.1 != defined.1 || independent.2 != defined.2)
    }

    func testInvalidFormulaFails() async {
        _ = NSApplication.shared
        let finished = expectation(description: "invalid formula")
        var failed = false
        let service = MathJaxRenderService(source: #"\frac{"#, display: false, width: 300, dark: false) { result in
            if case .failure = result { failed = true }
            finished.fulfill()
        }
        service.start()
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertTrue(failed)
    }

    func testExternalRequireIsRejected() async {
        _ = NSApplication.shared
        let finished = expectation(description: "external component")
        var failed = false
        let service = MathJaxRenderService(source: #"\require{https://example.invalid/script.js} x"#, display: false, width: 300, dark: false) { result in
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
        var service: MathJaxRenderService? = MathJaxRenderService(source: "x", display: false, width: 300, dark: false) { result in
            completions += 1
            if case let .failure(error) = result, let error = error as? MathJaxRenderService.RenderError, case .cancelled = error { cancelled = true }
            finished.fulfill()
        }
        weak var weakService = service
        service?.start()
        service?.cancel()
        service?.cancel()
        service = nil
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(cancelled)
        XCTAssertNil(weakService)
    }
}

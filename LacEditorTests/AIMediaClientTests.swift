import AppKit
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import LacEditor

private final class AIMediaURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AIMediaClientTests: XCTestCase {
    private func client() -> AIMediaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIMediaURLProtocol.self]
        return AIMediaClient(session: URLSession(configuration: configuration))
    }
    private func profile(_ api: AIAPIProtocol) -> AIModelProfile {
        var value = AIModelProfile(api: api)
        value.isEnabled = true
        value.baseURL = "https://example.com/gateway/v1"
        value.modelID = "example/model"
        return value
    }
    private func temporaryFile(_ data: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }
    func testAudioMultipartAndTextOrJSONResponse() async throws {
        let bytes = Data([0, 1, 255, 42])
        let file = try temporaryFile(bytes, extension: "wav")
        defer { try? FileManager.default.removeItem(at: file) }
        for response in ["Привет", #"{"text":"Привет"}"#] {
            AIMediaURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/gateway/v1/audio/transcriptions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
                let body = try XCTUnwrap(request.httpBody)
                XCTAssertNotNil(body.range(of: bytes))
                XCTAssertNotNil(body.range(of: Data("name=\"model\"\r\n\r\nexample/model".utf8)))
                XCTAssertNotNil(body.range(of: Data("name=\"response_format\"\r\n\r\ntext".utf8)))
                return (200, Data(response.utf8))
            }
            let result = try await client().transcribe(fileURL: file, profile: profile(.transcriptions), key: "secret")
            XCTAssertEqual(result, "Привет")
        }
    }
    func testPDFMultipartAndDOCXConversion() async throws {
        let document = PDFDocument()
        document.insert(PDFPage(image: NSImage(size: NSSize(width: 10, height: 10)))!, at: 0)
        let file = try temporaryFile(try XCTUnwrap(document.dataRepresentation()), extension: "pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/gateway/v1/pdf/convert")
            let body = try XCTUnwrap(request.httpBody)
            for field in ["name=\"output\"\r\n\r\ndocx", "Content-Type: application/pdf"] {
                XCTAssertNotNil(body.range(of: Data(field.utf8)))
            }
            return (200, Data(#"{"docx_base64":"UEsDBA=="}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIMediaURLProtocol.self]
        let media = AIMediaClient(session: URLSession(configuration: configuration), convertDOCX: { url in
            XCTAssertEqual(try Data(contentsOf: url), Data([0x50, 0x4b, 0x03, 0x04]))
            return "# result"
        })
        let result = try await media.recognize(fileURL: file, profile: profile(.gatewayPDF), key: "secret")
        XCTAssertEqual(result, "# result")
    }
    func testErrorsAndCancellation() async throws {
        let file = try temporaryFile(Data("audio".utf8), extension: "wav")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { _ in (403, Data("secret details".utf8)) }
        do { _ = try await client().transcribe(fileURL: file, profile: profile(.transcriptions), key: "secret"); XCTFail() }
        catch AIError.http(let status) { XCTAssertEqual(status, 403) }
        AIMediaURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await client().transcribe(fileURL: file, profile: profile(.transcriptions), key: nil); XCTFail() }
        catch is CancellationError {} catch { XCTFail("Unexpected error") }
        AIMediaURLProtocol.handler = { _ in (200, Data(#"{"text":""}"#.utf8)) }
        do { _ = try await client().transcribe(fileURL: file, profile: profile(.transcriptions), key: nil); XCTFail() }
        catch AIError.invalidResponse {} catch { XCTFail("Unexpected error") }
    }

    func testInvalidPDFConversionResponse() async throws {
        let document = PDFDocument()
        document.insert(PDFPage(image: NSImage(size: NSSize(width: 10, height: 10)))!, at: 0)
        let file = try temporaryFile(try XCTUnwrap(document.dataRepresentation()), extension: "pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { _ in (200, Data(#"{"docx_base64":"not-base64"}"#.utf8)) }
        do { _ = try await client().recognize(fileURL: file, profile: profile(.gatewayPDF), key: nil); XCTFail() }
        catch AIError.invalidResponse {} catch { XCTFail("Unexpected error") }
    }

    func testImageVisionUsesChosenProtocol() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a1sAAAAASUVORK5CYII=")!
        let file = try temporaryFile(png, extension: "png")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/responses")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            let url = try XCTUnwrap(content.first?["image_url"] as? String)
            XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
            let encoded = String(url.dropFirst("data:image/png;base64,".count))
            let output = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertNotNil(NSBitmapImageRep(data: output))
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"# Text"}]}]}"#.utf8))
        }
        let result = try await client().recognize(fileURL: file, profile: profile(.responses), key: nil)
        XCTAssertEqual(result, "# Text")
    }

    func testTIFFIsSentAsPNGForVision() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        let file = try temporaryFile(tiff, extension: "tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            let url = try XCTUnwrap(content.first?["image_url"] as? String)
            XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
            let image = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
            XCTAssertEqual(Array(image.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Text"}]}]}"#.utf8))
        }
        let result = try await client().recognize(fileURL: file, profile: profile(.responses), key: nil)
        XCTAssertEqual(result, "Text")

    }

    func testJPEGOrientationIsAppliedBeforeVision() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let original = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = try temporaryFile(encoded as Data, extension: "jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            let url = try XCTUnwrap(content.first?["image_url"] as? String)
            XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
            let data = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1)
            XCTAssertEqual(image.height, 2)
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Text"}]}]}"#.utf8))
        }
        let result = try await client().recognize(fileURL: file, profile: profile(.responses), key: nil)
        XCTAssertEqual(result, "Text")
        AIMediaURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody)
            let start = try XCTUnwrap(body.range(of: Data("%PDF".utf8)))
            let end = try XCTUnwrap(body.range(of: Data("%%EOF".utf8), in: start.lowerBound..<body.endIndex))
            let pdf = try XCTUnwrap(PDFDocument(data: body.subdata(in: start.lowerBound..<end.upperBound)))
            let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
            XCTAssertLessThan(bounds.width, bounds.height)
            return (200, Data(#"{"docx_base64":"UEsDBA=="}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIMediaURLProtocol.self]
        let media = AIMediaClient(session: URLSession(configuration: configuration), convertDOCX: { _ in "Text" })
        let pdfResult = try await media.recognize(fileURL: file, profile: profile(.gatewayPDF), key: nil)
        XCTAssertEqual(pdfResult, "Text")
    }

    func testCancellationDuringDOCXConversionDiscardsResultAndTemporaryFile() async throws {
        let document = PDFDocument()
        document.insert(PDFPage(image: NSImage(size: NSSize(width: 10, height: 10)))!, at: 0)
        let file = try temporaryFile(try XCTUnwrap(document.dataRepresentation()), extension: "pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        AIMediaURLProtocol.handler = { _ in (200, Data(#"{"docx_base64":"UEsDBA=="}"#.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIMediaURLProtocol.self]
        let entered = expectation(description: "DOCX conversion started")
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var convertedFile: URL?
        func savedFile() -> URL? { lock.lock(); defer { lock.unlock() }; return convertedFile }
        let media = AIMediaClient(session: URLSession(configuration: configuration), convertDOCX: { url in
            lock.lock(); convertedFile = url; lock.unlock()
            entered.fulfill()
            gate.wait()
            return "stale"
        })
        let operation = Task { try await media.recognize(fileURL: file, profile: profile(.gatewayPDF), key: nil) }
        await fulfillment(of: [entered], timeout: 5)
        operation.cancel()
        gate.signal()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let temporary = savedFile()
        XCTAssertNotNil(temporary)
        if let temporary { XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path)) }
    }
}

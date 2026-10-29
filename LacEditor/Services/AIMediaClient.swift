import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

private final class AIMediaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AIMediaClient {
    private let session: URLSession
    private let convertDOCX: (URL) throws -> String
    init(session: URLSession = .shared, convertDOCX: @escaping (URL) throws -> String = { try PandocImportService.convert(source: $0).text }) {
        self.session = session
        self.convertDOCX = convertDOCX
    }

    func recognize(fileURL: URL, profile: AIModelProfile, key: String?) async throws -> String {
        guard profile.isEnabled else { throw AIError.disabled }
        guard profile.supports(.ocr), !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidConfiguration }
        let preparation = Task.detached { try Self.prepareDocument(fileURL, pdf: profile.api == .gatewayPDF) }
        let prepared = try await Self.awaitTask(preparation)
        try Task.checkCancellation()
        if profile.api != .gatewayPDF {
            var pages: [String] = []
            for image in prepared {
                try Task.checkCancellation()
                pages.append(try await AIClient(session: session).generateImageDescription(data: image, instructions: "Transcribe the content faithfully as Markdown. Preserve structure, tables and formulas where possible. Return only Markdown; do not invent unreadable text.", profile: profile, key: key))
            }
            return pages.joined(separator: "\n\n")
        }
        let request = try multipart(profile: profile, path: "pdf/convert", key: key, fields: [("model", profile.modelID), ("output", "docx")], data: prepared[0], filename: "document.pdf", mime: "application/pdf")
        let data = try await fetch(request)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = result["docx_base64"] as? String,
              let docx = Data(base64Encoded: encoded), !docx.isEmpty else { throw AIError.invalidResponse }
        let convert = convertDOCX
        let conversion = Task.detached {
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("document.docx")
            try docx.write(to: file)
            try Task.checkCancellation()
            let result = try convert(file)
            try Task.checkCancellation()
            return result
        }
        let converted: String
        do { converted = try await Self.awaitTask(conversion) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIError.invalidResponse }
        try Task.checkCancellation()
        guard !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
        return converted
    }

    func transcribe(fileURL: URL, profile: AIModelProfile, key: String?) async throws -> String {
        guard profile.isEnabled else { throw AIError.disabled }
        guard profile.supports(.audio), !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidConfiguration }
        let data: Data
        let reading = Task.detached {
            try Task.checkCancellation()
            let data = try Data(contentsOf: fileURL)
            try Task.checkCancellation()
            return data
        }
        do { data = try await Self.awaitTask(reading) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIError.invalidResponse }
        try Task.checkCancellation()
        let ext = fileURL.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let filename = ext.range(of: "^[a-z0-9]+$", options: .regularExpression) == nil ? "audio" : "audio.\(ext)"
        let request = try multipart(profile: profile, path: "audio/transcriptions", key: key, fields: [("model", profile.modelID), ("response_format", "text")], data: data, filename: filename, mime: mime)
        let result = try await fetch(request)
        if let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] {
            guard let value = object["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
            return value
        }
        return try text(result)
    }

    private static func prepareDocument(_ url: URL, pdf: Bool) throws -> [Data] {
        try Task.checkCancellation()
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw AIError.invalidResponse }
        try Task.checkCancellation()
        if let document = PDFDocument(data: data) {
            guard document.pageCount > 0 else { throw AIError.invalidResponse }
            if pdf { return [data] }
            return try (0..<document.pageCount).map { index in
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw AIError.invalidResponse }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                      let width = Int(exactly: ceil(bounds.width * 2)), let height = Int(exactly: ceil(bounds.height * 2)),
                      width > 0, height > 0,
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AIError.invalidResponse }
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                context.scaleBy(x: 2, y: 2)
                context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .mediaBox, to: context)
                try Task.checkCancellation()
                guard let image = context.makeImage() else { throw AIError.invalidResponse }
                return try pngData(image)
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AIError.invalidResponse }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: max(original.width, original.height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AIError.invalidResponse }
        if !pdf { return [try pngData(image)] }
        let orientedImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let page = PDFPage(image: orientedImage) else { throw AIError.invalidResponse }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard let output = document.dataRepresentation() else { throw AIError.invalidResponse }
        return [output]
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw AIError.invalidResponse }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AIError.invalidResponse }
        try Task.checkCancellation()
        return output as Data
    }

    private static func awaitTask<T>(_ task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func multipart(profile: AIModelProfile, path: String, key: String?, fields: [(String, String)], data: Data, filename: String, mime: String) throws -> URLRequest {
        let base = try AIModelProfile.normalizedBaseURL(profile.baseURL)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw AIError.invalidConfiguration }
        components.path += "/" + path
        guard let url = components.url else { throw AIError.invalidConfiguration }
        let boundary = "LacEditor-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request, key: key)
        request.httpBody = body
        return request
    }

    private func authorize(_ request: inout URLRequest, key: String?) {
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    private func text(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
        return value
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request, delegate: AIMediaRedirectDelegate())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AIError.http(status: response.statusCode, data: data) }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AIError { throw error }
        catch { throw AIError.network }
    }
}

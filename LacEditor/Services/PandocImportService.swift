import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PandocImportError: LocalizedError {
    case unsupportedFormat
    case missingResource
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            L10n.tr("不支持此导入格式。")
        case .missingResource:
            L10n.tr("无法找到导入所需的资源。")
        case let .conversionFailed(details):
            L10n.tr("Pandoc 导入失败：%@", details)
        }
    }
}

struct PandocImportResult {
    let text: String
    let diagnostics: String
}

enum PandocImportService {
    static let readers = [
        "docx": "docx", "odt": "odt", "rtf": "rtf", "epub": "epub",
        "html": "html+raw_html", "htm": "html+raw_html", "tex": "latex", "latex": "latex", "fb2": "fb2",
        "ltx": "latex", "rst": "rst", "rest": "rst", "org": "org", "wiki": "mediawiki",
        "dokuwiki": "dokuwiki", "textile": "textile", "opml": "opml"
    ]
    static let extensions = readers.keys.sorted()

    static func convert(source: URL, executable: URL? = nil) throws -> PandocImportResult {
        guard let reader = readers[source.pathExtension.lowercased()] else { throw PandocImportError.unsupportedFormat }
        guard let pandoc = executable ?? PandocExportService.findPandoc() else { throw PandocExportError.missingPandoc }
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        guard let filter = resources.url(forResource: "import-images", withExtension: "lua", subdirectory: "Pandoc") else {
            throw PandocImportError.missingResource
        }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output.md")
        let log = temporary.appendingPathComponent("stderr")
        guard manager.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = pandoc
        process.currentDirectoryURL = source.deletingLastPathComponent()
        process.arguments = ["--from=\(reader)", "--to=gfm+yaml_metadata_block", "--standalone", "--lua-filter", filter.path,
                             "--output", output.path, "--", source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stderr.synchronize()
        let rawDiagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let diagnostics = rawDiagnostics.components(separatedBy: .newlines).map { line in
            line.trimmingCharacters(in: .whitespaces).hasSuffix("LACEDITOR_UNSUPPORTED_FIGURE")
                ? L10n.tr("复杂图片结构已保留为原始 HTML，预览可能无法显示。") : line
        }.joined(separator: "\n")
        guard process.terminationStatus == 0 else {
            throw PandocImportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(process.terminationStatus))" : diagnostics)
        }
        return PandocImportResult(text: try String(contentsOf: output, encoding: .utf8), diagnostics: diagnostics)
    }
}

enum PDFImportService {
    private struct ExtractedImage {
        let mimeType: String
        let data: Data
    }

    private final class ImageExtractionContext {
        var images: [ExtractedImage] = []
        let depth: Int

        init(depth: Int) {
            self.depth = depth
        }
    }

    private static let imageDictionaryApplier: CGPDFDictionaryApplierFunction = { _, object, rawContext in
        guard let rawContext else { return }
        let context = Unmanaged<ImageExtractionContext>.fromOpaque(rawContext).takeUnretainedValue()
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtypePointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer),
              let subtypePointer else { return }
        switch String(cString: subtypePointer) {
        case "Image":
            if let image = decodeImage(stream: stream, dictionary: dictionary) {
                context.images.append(image)
            }
        case "Form":
            var nestedResources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nestedResources), let nestedResources {
                context.images.append(contentsOf: extractImages(from: nestedResources, depth: context.depth + 1))
            }
        default:
            break
        }
    }

    static func convert(source: URL) throws -> PandocImportResult {
        guard let pdf = PDFDocument(url: source),
              let cgPDF = CGPDFDocument(source as CFURL),
              pdf.pageCount > 0 else {
            throw PandocImportError.conversionFailed(L10n.tr("无法读取 PDF 文档。"))
        }

        var sections: [String] = []
        var foundText = false
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            var parts: [String] = []
            if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                foundText = true
                parts.append(text)
            }

            if let cgPage = cgPDF.page(at: pageIndex + 1) {
                for (imageIndex, image) in extractImages(from: cgPage).enumerated() {
                    let encoded = image.data.base64EncodedString()
                    let description = L10n.tr("Страница PDF %lld, изображение %lld", pageIndex + 1, imageIndex + 1)
                    parts.append("![\(description)](data:\(image.mimeType);base64,\(encoded))")
                }
            }
            if !parts.isEmpty { sections.append(parts.joined(separator: "\n\n")) }
        }

        guard foundText else {
            throw PandocImportError.conversionFailed(L10n.tr("PDF не содержит текстового слоя."))
        }
        return PandocImportResult(text: sections.joined(separator: "\n\n---\n\n"), diagnostics: "")
    }

    private static func extractImages(from page: CGPDFPage) -> [ExtractedImage] {
        guard let pageDictionary = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources else { return [] }
        return extractImages(from: resources, depth: 0)
    }

    private static func extractImages(from resources: CGPDFDictionaryRef, depth: Int) -> [ExtractedImage] {
        guard depth < 8 else { return [] }
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return [] }
        let context = ImageExtractionContext(depth: depth)
        CGPDFDictionaryApplyFunction(
            xObjects,
            imageDictionaryApplier,
            Unmanaged.passUnretained(context).toOpaque()
        )
        return context.images
    }

    private static func decodeImage(
        stream: CGPDFStreamRef,
        dictionary: CGPDFDictionaryRef
    ) -> ExtractedImage? {
        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = copied as Data
        if format == .jpegEncoded { return ExtractedImage(mimeType: "image/jpeg", data: data) }
        if format == .JPEG2000 { return ExtractedImage(mimeType: "image/jp2", data: data) }
        guard format == .raw, let image = rawImage(data: data, dictionary: dictionary),
              let png = pngData(from: image) else { return nil }
        return ExtractedImage(mimeType: "image/png", data: png)
    }

    private static func rawImage(data: Data, dictionary: CGPDFDictionaryRef) -> CGImage? {
        var width = 0
        var height = 0
        var bitsPerComponent = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bitsPerComponent),
              width > 0, height > 0, bitsPerComponent == 8 else { return nil }

        var colorSpacePointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "ColorSpace", &colorSpacePointer),
              let colorSpacePointer else { return nil }
        let colorSpaceName = String(cString: colorSpacePointer)
        let components: Int
        let colorSpace: CGColorSpace
        switch colorSpaceName {
        case "DeviceGray":
            components = 1
            colorSpace = CGColorSpaceCreateDeviceGray()
        case "DeviceRGB":
            components = 3
            colorSpace = CGColorSpaceCreateDeviceRGB()
        case "DeviceCMYK":
            components = 4
            colorSpace = CGColorSpaceCreateDeviceCMYK()
        default:
            return nil
        }
        let bytesPerRow = width * components
        guard data.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerComponent * components,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

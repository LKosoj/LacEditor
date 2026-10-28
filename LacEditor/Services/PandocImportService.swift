import Foundation

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
        "html": "html+raw_html", "htm": "html+raw_html", "tex": "latex", "latex": "latex", "fb2": "fb2"
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
        process.arguments = ["--from=\(reader)", "--to=gfm", "--lua-filter", filter.path,
                             "--output", output.path, "--", source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stderr.synchronize()
        let diagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw PandocImportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(process.terminationStatus))" : diagnostics)
        }
        return PandocImportResult(text: try String(contentsOf: output, encoding: .utf8), diagnostics: diagnostics)
    }
}

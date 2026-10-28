import Foundation

enum PandocExportFormat: String, CaseIterable, Identifiable {
    case html, docx, odt, rtf, epub, fb2, latex, text, pdf

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latex: "LaTeX"
        case .text: "TXT"
        default: rawValue.uppercased()
        }
    }
    var fileExtension: String {
        switch self {
        case .latex: "tex"
        case .text: "txt"
        default: rawValue
        }
    }
    var writer: String {
        switch self {
        case .latex, .pdf: "latex"
        case .text: "plain"
        default: rawValue
        }
    }
}

enum PandocExportError: LocalizedError {
    case missingPandoc
    case conversionFailed(String)
    case openDocument

    var errorDescription: String? {
        switch self {
        case .missingPandoc:
            L10n.tr("找不到内置 Pandoc。请重新安装 LacEditor。")
        case let .conversionFailed(details):
            L10n.tr("Pandoc 导出失败：%@", details)
        case .openDocument:
            L10n.tr("不能覆盖在 LacEditor 中打开的文件或原始文件。")
        }
    }
}

struct PandocExportResult {
    let preparedURL: URL
    let diagnostics: String
}

enum PandocExportService {
    static func findPandoc() -> URL? {
        #if SWIFT_PACKAGE
        let executable = Bundle.module.resourceURL?.appendingPathComponent("Pandoc/pandoc")
        #else
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("pandoc")
        #endif
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    static func conflicts(destination: URL, source: URL?, openURLs: [URL]) -> Bool {
        let target = DocumentFileIdentity.resolve(destination)
        return ([source].compactMap { $0 } + openURLs).contains { url in
            let identity = DocumentFileIdentity.resolve(url)
            return target.canonicalPath == identity.canonicalPath || target.matches(identity)
        }
    }

    // Runs off the main thread. The returned file is on the destination volume
    // so the final move or replacement stays on the same volume.
    static func prepare(
        text: String, source: URL?, destination: URL, format: PandocExportFormat,
        title: String, executable: URL? = nil
    ) throws -> PandocExportResult {
        guard let pandoc = executable ?? findPandoc() else { throw PandocExportError.missingPandoc }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.md")
        let output = temporary.appendingPathComponent("output.\(format.fileExtension)")
        let log = temporary.appendingPathComponent("stderr")
        try text.write(to: input, atomically: true, encoding: .utf8)
        guard manager.createFile(atPath: log.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = pandoc
        var arguments = ["--from=gfm", "--to=\(format.writer)", "--standalone", "--metadata", "title=\(title)"]
        if format == .html { arguments.append("--embed-resources") }
        process.arguments = arguments + ["--output", output.path, input.path]
        if let source {
            process.currentDirectoryURL = source.deletingLastPathComponent()
        }
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        environment["PATH"] = path + ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stderr.synchronize()
        let diagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw PandocExportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(process.terminationStatus))" : diagnostics)
        }
        let replacementDirectory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(), create: true
        )
        let prepared = replacementDirectory.appendingPathComponent("output.\(format.fileExtension)")
        do {
            try manager.copyItem(at: output, to: prepared)
        } catch {
            try? manager.removeItem(at: replacementDirectory)
            throw error
        }
        return PandocExportResult(preparedURL: prepared, diagnostics: diagnostics)
    }

    static func install(_ prepared: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: prepared)
        } else {
            try manager.moveItem(at: prepared, to: destination)
        }
    }
}

import Foundation
import Darwin

enum ClipboardMarkdownConversionService {
    enum InputFormat: String, Sendable { case html, rtf }

    enum ConversionError: Error, Equatable {
        case missingPandoc
        case failed(String)
        case invalidOutput
    }

    struct Output: Equatable, Sendable {
        let markdown: String
        let diagnostics: String
    }

    // Count only explicit picture groups, pairing the adjacent Word fallback
    // representation with its primary picture. Ambiguous RTF is rejected.
    static func rtfPictureCount(_ data: Data, isCancelled: () -> Bool = { false }) -> Int? {
        enum Kind { case other, picture, primary, fallback }
        struct Group {
            var kind: Kind = .other
            var header = true
            var count = 0
            var pendingPrimary = false
        }
        if isCancelled() { return nil }
        let bytes = [UInt8](data)
        var stack: [Group] = [], index = 0, result: Int?
        func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
        while index < bytes.count {
            if isCancelled() { return nil }
            let byte = bytes[index]
            if byte == 123 {
                if !stack.isEmpty { stack[stack.count - 1].header = false }
                stack.append(Group())
                index += 1
            } else if byte == 125 {
                guard let group = stack.popLast() else { return nil }
                if stack.isEmpty {
                    guard result == nil else { return nil }
                    result = group.count
                } else {
                    let parent = stack.count - 1
                    let paired = stack[parent].pendingPrimary && group.kind == .fallback && group.count == 1
                    stack[parent].count += group.count - (paired ? 1 : 0)
                    stack[parent].pendingPrimary = group.kind == .primary && group.count == 1
                }
                index += 1
            } else if byte == 92 {
                guard !stack.isEmpty, index + 1 < bytes.count else { return nil }
                index += 1
                let first = bytes[index]
                if (65...90).contains(first) || (97...122).contains(first) {
                    let start = index
                    while index < bytes.count && ((65...90).contains(bytes[index]) || (97...122).contains(bytes[index])) {
                        if isCancelled() { return nil }
                        index += 1
                    }
                    let word = String(decoding: bytes[start..<index], as: UTF8.self)
                    if word == "bin" { return nil }
                    let current = stack.count - 1
                    if stack[current].header {
                        if word == "pict" { stack[current].kind = .picture; stack[current].count += 1 }
                        else if word == "shppict" { stack[current].kind = .primary }
                        else if word == "nonshppict" { stack[current].kind = .fallback }
                        stack[current].header = false
                    } else if word == "pict" { return nil }
                    stack[current].pendingPrimary = false
                    if index < bytes.count && (bytes[index] == 45 || (48...57).contains(bytes[index])) {
                        if bytes[index] == 45 { index += 1 }
                        while index < bytes.count && (48...57).contains(bytes[index]) {
                            if isCancelled() { return nil }
                            index += 1
                        }
                    }
                    if index < bytes.count && bytes[index] == 32 { index += 1 }
                } else {
                    let current = stack.count - 1
                    if first != 42 || !stack[current].header { stack[current].header = false; stack[current].pendingPrimary = false }
                    index += 1
                    if first == 39 {
                        guard index + 1 < bytes.count else { return nil }
                        func isHex(_ value: UInt8) -> Bool {
                            (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
                        }
                        guard isHex(bytes[index]), isHex(bytes[index + 1]) else { return nil }
                        index += 2
                    }
                }
            } else {
                if stack.isEmpty {
                    guard whitespace(byte) else { return nil }
                } else if !whitespace(byte) {
                    stack[stack.count - 1].header = false
                    stack[stack.count - 1].pendingPrimary = false
                }
                index += 1
            }
        }
        guard stack.isEmpty else { return nil }
        return result
    }

    // Call off the main thread. Each invocation owns its process and temporary files.
    static func convert(_ data: Data, format: InputFormat, executable: URL? = nil,
                        isCancelled: @escaping () -> Bool = { false }) throws -> Output {
        let (data, diagnostics) = try run(data, conversion: .clipboard(format), executable: executable, isCancelled: isCancelled)
        guard let markdown = String(data: data, encoding: .utf8) else { throw ConversionError.invalidOutput }
        return Output(markdown: markdown, diagnostics: diagnostics)
    }

    // RTF embeds media in the input. Resolve Pandoc's private extracted files
    // before the temporary directory is removed; no user file is written here.
    static func convertRTFWithMedia(_ data: Data, executable: URL? = nil,
                                    isCancelled: @escaping () -> Bool = { false }) throws -> Output {
        let (converted, diagnostics) = try run(data, conversion: .clipboard(.rtf), executable: executable,
                                               isCancelled: isCancelled, extractMedia: true)
        guard let markdown = String(data: converted, encoding: .utf8) else { throw ConversionError.invalidOutput }
        return Output(markdown: markdown, diagnostics: diagnostics)
    }

    enum FixedConversion {
        case clipboard(InputFormat)
    }

    // Fixed conversions for clipboard import.
    static func run(_ data: Data, conversion: FixedConversion, executable: URL?,
                    isCancelled: @escaping () -> Bool, extractMedia: Bool = false) throws -> (Data, String) {
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        try checkCancellation()
        guard let executable = executable ?? PandocExportService.findPandoc() else { throw ConversionError.missingPandoc }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        try checkCancellation()
        let inputName: String
        switch conversion {
        case let .clipboard(format): inputName = "input.\(format.rawValue)"
        }
        let input = temporary.appendingPathComponent(inputName)
        let output = temporary.appendingPathComponent("output.md")
        let log = temporary.appendingPathComponent("stderr")
        try data.write(to: input, options: .withoutOverwriting)
        try checkCancellation()
        guard manager.createFile(atPath: output.path, contents: nil),
              manager.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let stdout = try FileHandle(forWritingTo: output)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        try checkCancellation()
        let process = Process()
        process.executableURL = executable
        switch conversion {
        case let .clipboard(format):
            if extractMedia && format != .rtf { throw ConversionError.invalidOutput }
            process.arguments = ["--sandbox", "--from=\(format.rawValue)", "--to=gfm"] + (extractMedia ? ["--extract-media=media"] : []) + ["--", input.path]
        }
        process.currentDirectoryURL = temporary
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        while process.isRunning {
            if isCancelled() {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try checkCancellation()
        try stdout.synchronize()
        try stderr.synchronize()
        try checkCancellation()
        let diagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(diagnostics.isEmpty ? "Pandoc (\(process.terminationStatus))" : diagnostics)
        }
        var converted = try Data(contentsOf: output)
        try checkCancellation()
        if extractMedia {
            guard let markdown = String(data: converted, encoding: .utf8) else { throw ConversionError.invalidOutput }
            let images = try MarkdownImageUploadService.images(in: markdown, isCancelled: isCancelled)
            var urls: [URL] = []
            for image in images {
                try checkCancellation()
                guard image.syntax == .markdown, let parts = URLComponents(string: image.address),
                      parts.scheme == nil, parts.query == nil, parts.fragment == nil else { throw ConversionError.invalidOutput }
                let components = parts.path.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 2, components[0] == "media", !components[1].isEmpty,
                      components[1] != ".", components[1] != ".." else { throw ConversionError.invalidOutput }
                let media = temporary.appendingPathComponent("media", isDirectory: true)
                let directoryValues = try media.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw ConversionError.invalidOutput }
                let file = media.appendingPathComponent(String(components[1]))
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConversionError.invalidOutput }
                let payload = try MarkdownImageUploadService.payload(address: image.address, document: input)
                guard let url = URL(string: "data:\(payload.mime);base64,\(payload.data.base64EncodedString())") else { throw ConversionError.invalidOutput }
                urls.append(url)
            }
            if !images.isEmpty {
                let edit = try MarkdownImageUploadService.replacement(in: markdown, images: images, urls: urls,
                    selection: NSRange(location: 0, length: 0), isCancelled: isCancelled)
                converted = Data((markdown as NSString).replacingCharacters(in: edit.range, with: edit.replacement).utf8)
            }
            try checkCancellation()
        }
        return (converted, diagnostics)
    }
}

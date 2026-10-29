import AppKit
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct DecodedFile {
    let text: String
    let encoding: String.Encoding
    let encodingName: String
    let byteCount: Int
    let lineCount: Int
    var fileRevisionSnapshot: FileRevisionSnapshot? = nil
}

struct DocumentFileIdentity: Hashable, Sendable {
    let canonicalPath: String
    let resourceIdentifier: String?

    static func resolve(_ url: URL) -> Self {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? canonicalURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return Self(
            canonicalPath: canonicalURL.path,
            resourceIdentifier: values?.fileResourceIdentifier.map(String.init(describing:))
        )
    }

    func matches(_ other: Self) -> Bool {
        if let resourceIdentifier, let otherIdentifier = other.resourceIdentifier {
            return resourceIdentifier == otherIdentifier
        }
        return canonicalPath == other.canonicalPath
    }
}

enum ImageFileMutationError: Error {
    case movedWithoutIdentity(URL)
    case moveIncomplete(URL, URL)
    case trashedWithoutLocation
}

struct FileRevisionSnapshot: Equatable, Sendable {
    let identity: DocumentFileIdentity
    let modificationDate: Date?
    let fileSize: Int?

    nonisolated static func capture(_ url: URL) throws -> Self {
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try freshURL.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])
        return Self(
            identity: DocumentFileIdentity.resolve(freshURL),
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize
        )
    }
}

struct FileEncodingChoice: Sendable {
    let name: String
    let encoding: String.Encoding
}

struct WorkspaceItemSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let path: String
        let kind: String
        let content: Data
    }
    let rootDevice: UInt64
    let rootInode: UInt64
    let entries: [Entry]
    let fileIdentities: [DocumentFileIdentity]
}

struct WorkspaceNodeIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum PreparedFileRead {
    case decoded(DecodedFile)
    case needsEncoding(Data, byteCount: Int, fileRevisionSnapshot: FileRevisionSnapshot)
}

enum FileServiceError: LocalizedError {
    case unsupportedEncoding
    case unrepresentableCharacters(String)
    case invalidFileName
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            L10n.tr("无法使用所选编码读取文件。")
        case let .unrepresentableCharacters(encodingName):
            L10n.tr("当前内容包含无法使用%@保存的字符。", encodingName)
        case .invalidFileName:
            L10n.tr("文件名不能为空，也不能包含“/”。")
        case .destinationExists:
            L10n.tr("同一文件夹中已存在同名文件。")
        }
    }
}

@MainActor
final class FileService {
    nonisolated static let supportedExtensions = [
        "txt", "md", "markdown", "html", "htm", "json",
        "js", "mjs", "cjs", "ts", "tsx", "css", "py", "pyw", "swift",
        "sh", "bash", "zsh", "yaml", "yml", "c", "h", "cc", "cpp",
        "cxx", "hpp", "sql"
    ]

    func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedContentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func read(_ url: URL) throws -> DecodedFile {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return DecodedFile(
                text: text,
                encoding: .utf8,
                encodingName: "UTF-8",
                byteCount: data.count,
                lineCount: Self.countLines(in: text)
            )
        }

        return try decodeUsingSelectedEncoding(data, from: url)
    }

    nonisolated static func prepareRead(
        _ url: URL,
        readData: (URL, Data.ReadingOptions) throws -> Data = { try Data(contentsOf: $0, options: $1) }
    ) throws -> PreparedFileRead {
        let before = try FileRevisionSnapshot.capture(url)
        let byteCount = before.fileSize ?? 0
        let options: Data.ReadingOptions = byteCount > 20 * 1_024 * 1_024
            ? .mappedIfSafe
            : []
        let data = try readData(url, options)
        let prepared: PreparedFileRead
        if let text = String(data: data, encoding: .utf8) {
            prepared = .decoded(DecodedFile(
                text: text,
                encoding: .utf8,
                encodingName: "UTF-8",
                byteCount: byteCount,
                lineCount: countLines(in: text),
                fileRevisionSnapshot: before
            ))
        } else {
            let stableData = data.withUnsafeBytes { Data($0) }
            prepared = .needsEncoding(stableData, byteCount: byteCount, fileRevisionSnapshot: before)
        }
        let after = try FileRevisionSnapshot.capture(url)
        guard before == after else { throw CocoaError(.fileReadUnknown) }
        return prepared
    }

    nonisolated static func fileByteCount(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    func decodeUsingSelectedEncoding(
        _ data: Data,
        from url: URL,
        byteCount: Int? = nil
    ) throws -> DecodedFile {

        guard let selected = chooseEncoding(for: url) else {
            throw CocoaError(.userCancelled)
        }
        return try Self.decode(
            data,
            encoding: selected.encoding,
            encodingName: selected.name,
            byteCount: byteCount
        )
    }

    func chooseEncoding(for url: URL) -> FileEncodingChoice? {
        let choices = Self.selectableEncodings
        let alert = NSAlert()
        alert.messageText = L10n.tr("请选择文件编码")
        alert.informativeText = L10n.tr("“%@”不是有效的 UTF-8 文件。请选择用于打开它的文本编码。", url.lastPathComponent)
        alert.addButton(withTitle: L10n.tr("打开"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: choices.map(\.name))
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return choices[popup.indexOfSelectedItem]
    }

    nonisolated static func decode(
        _ data: Data,
        encoding: String.Encoding,
        encodingName: String,
        byteCount: Int? = nil,
        fileRevisionSnapshot: FileRevisionSnapshot? = nil
    ) throws -> DecodedFile {
        guard let text = String(data: data, encoding: encoding) else {
            throw FileServiceError.unsupportedEncoding
        }
        return DecodedFile(
            text: text,
            encoding: encoding,
            encodingName: encodingName,
            byteCount: byteCount ?? data.count,
            lineCount: countLines(in: text),
            fileRevisionSnapshot: fileRevisionSnapshot
        )
    }

    func write(_ text: String, to url: URL) throws {
        try Self.writeUTF8(text, to: url)
    }

    nonisolated static func writeUTF8(_ text: String, to url: URL) throws {
        try write(text, to: url, encoding: .utf8, encodingName: "UTF-8")
    }

    nonisolated static func write(
        _ text: String,
        to url: URL,
        encoding: String.Encoding,
        encodingName: String
    ) throws {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw FileServiceError.unrepresentableCharacters(encodingName)
        }
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func encodingName(for encoding: String.Encoding) -> String {
        if encoding == .utf8 { return "UTF-8" }
        if encoding == .utf16 { return "UTF-16" }
        if encoding == gb18030Encoding { return L10n.tr("简体中文（GB 18030）") }
        if encoding == .isoLatin1 { return L10n.tr("西欧（ISO Latin 1）") }
        if encoding == .windowsCP1252 { return L10n.tr("西欧（Windows Latin 1）") }
        if encoding == .macOSRoman { return L10n.tr("Mac OS 罗马编码") }
        return L10n.tr("编码 %@", String(describing: encoding.rawValue))
    }

    nonisolated static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(0x0632)
        )
    )

    nonisolated static let selectableEncodings: [FileEncodingChoice] = [
        FileEncodingChoice(name: "UTF-16", encoding: .utf16),
        FileEncodingChoice(name: L10n.tr("简体中文（GB 18030）"), encoding: gb18030Encoding),
        FileEncodingChoice(name: L10n.tr("西欧（ISO Latin 1）"), encoding: .isoLatin1),
        FileEncodingChoice(name: L10n.tr("西欧（Windows Latin 1）"), encoding: .windowsCP1252),
        FileEncodingChoice(name: L10n.tr("Mac OS 罗马编码"), encoding: .macOSRoman)
    ]

    nonisolated private static func countLines(in text: String) -> Int {
        var count = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR { count += 1 }
                previousWasCR = false
            case 0x0D:
                count += 1
                previousWasCR = true
            case 0x2028, 0x2029:
                count += 1
                previousWasCR = false
            default:
                previousWasCR = false
            }
        }
        return count
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/") else {
            throw FileServiceError.invalidFileName
        }
        guard newName != url.lastPathComponent else {
            return url.standardizedFileURL
        }

        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileServiceError.destinationExists
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func moveImageFile(_ source: URL, to destination: URL, expectedIdentity: WorkspaceNodeIdentity,
                       identityReader: ((URL) throws -> WorkspaceNodeIdentity)? = nil,
                       move: ((URL, URL) throws -> Void)? = nil) throws -> WorkspaceNodeIdentity {
        let identify = identityReader ?? workspaceNodeIdentity
        guard source.isFileURL, destination.isFileURL,
              try identify(source) == expectedIdentity else { throw CocoaError(.fileWriteNoPermission) }
        guard (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else { throw FileServiceError.destinationExists }
        do {
            if let move { try move(source, destination) }
            else { try FileManager.default.moveItem(at: source, to: destination) }
        } catch {
            if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil ||
                (try? FileManager.default.attributesOfItem(atPath: source.path)) == nil {
                throw ImageFileMutationError.moveIncomplete(source, destination)
            }
            throw error
        }
        do { return try identify(destination) }
        catch { throw ImageFileMutationError.movedWithoutIdentity(destination) }
    }

    func trashImageFile(_ source: URL, expectedIdentity: WorkspaceNodeIdentity) throws -> (URL, WorkspaceNodeIdentity) {
        guard source.isFileURL, try workspaceNodeIdentity(source) == expectedIdentity else { throw CocoaError(.fileWriteNoPermission) }
        var result: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &result)
        guard let result = result as URL? else { throw ImageFileMutationError.trashedWithoutLocation }
        do { return (result, try workspaceNodeIdentity(result)) }
        catch { throw ImageFileMutationError.movedWithoutIdentity(result) }
    }

    /// Verify each directory separately so a displayed folder replaced by a
    /// symlink is not followed by workspace operations.
    nonisolated func validateWorkspaceDirectory(_ directory: URL, root: URL) throws {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        let base = root.pathComponents
        let components = directory.pathComponents
        guard components.starts(with: base) else { throw CocoaError(.fileReadNoPermission) }
        var current = root
        func validateCurrent() throws {
            let fresh = URL(fileURLWithPath: current.path)
            let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        try validateCurrent()
        for component in components.dropFirst(base.count) {
            current.appendPathComponent(component, isDirectory: true)
            try validateCurrent()
        }
    }

    nonisolated func workspaceDestination(named name: String, in directory: URL, root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw FileServiceError.invalidFileName
        }
        try validateWorkspaceDirectory(directory, root: root)
        return directory.appendingPathComponent(name).standardizedFileURL
    }

    nonisolated func createWorkspaceItem(named name: String, in directory: URL, root: URL, isDirectory: Bool) throws -> URL {
        let destination = try workspaceDestination(named: name, in: directory, root: root)
        if isDirectory {
            guard mkdir(destination.path, 0o777) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else {
            try Data().write(to: destination, options: .withoutOverwriting)
        }
        return destination
    }

    nonisolated func createLinkedMarkdownFile(at url: URL) throws {
        guard url.isFileURL, ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw FileServiceError.invalidFileName
        }
        try Data().write(to: url, options: .withoutOverwriting)
    }

    nonisolated func copyWorkspaceItem(_ source: URL, named name: String, root: URL) throws -> URL {
        try validateWorkspaceDirectory(source.deletingLastPathComponent(), root: root)
        let destination = try workspaceDestination(named: name, in: source.deletingLastPathComponent(), root: root)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    nonisolated func moveWorkspaceItem(_ source: URL, to directory: URL, named name: String, root: URL) throws -> URL {
        let source = source.standardizedFileURL
        guard source != root.standardizedFileURL else { throw CocoaError(.fileWriteNoPermission) }
        try validateWorkspaceDirectory(source.deletingLastPathComponent(), root: root)
        let destination = try workspaceDestination(named: name, in: directory, root: root)
        guard !directory.standardizedFileURL.pathComponents.starts(with: source.pathComponents) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    nonisolated func trashWorkspaceItem(_ source: URL, root: URL, expectedIdentity: WorkspaceNodeIdentity) throws -> URL? {
        guard source.standardizedFileURL != root.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try validateWorkspaceDirectory(source.deletingLastPathComponent(), root: root)
        guard try workspaceNodeIdentity(source) == expectedIdentity else { throw CocoaError(.fileWriteNoPermission) }
        var result: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &result)
        return result as URL?
    }

    nonisolated func workspaceNodeIdentity(_ url: URL) throws -> WorkspaceNodeIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw CocoaError(.fileReadUnknown)
        }
        return WorkspaceNodeIdentity(device: device, inode: inode)
    }

    nonisolated func restoreWorkspaceTrashItem(_ trashURL: URL, to destination: URL, root: URL,
                                               expectedIdentity: WorkspaceNodeIdentity) throws {
        try validateWorkspaceDirectory(destination.deletingLastPathComponent(), root: root)
        guard try workspaceNodeIdentity(trashURL) == expectedIdentity else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.moveItem(at: trashURL, to: destination)
    }

    nonisolated func removeEmptyWorkspaceItem(_ url: URL, root: URL, snapshot: WorkspaceItemSnapshot) throws {
        try validateWorkspaceDirectory(url.deletingLastPathComponent(), root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.systemNumber] as? NSNumber)?.uint64Value == snapshot.rootDevice,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == snapshot.rootInode else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let kind = attributes[.type] as? FileAttributeType
        let status: Int32
        if kind == .typeDirectory {
            status = rmdir(url.path)
        } else if kind == .typeRegular, (attributes[.size] as? NSNumber)?.uint64Value == 0 {
            status = unlink(url.path)
        } else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    nonisolated func removeCopiedWorkspaceItem(_ url: URL, root: URL, snapshot: WorkspaceItemSnapshot) throws {
        try validateWorkspaceDirectory(url.deletingLastPathComponent(), root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.systemNumber] as? NSNumber)?.uint64Value == snapshot.rootDevice,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == snapshot.rootInode else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Called off the main thread after duplication and before its undo.
    /// The digest detects changes between snapshots, not concurrent races.
    nonisolated func workspaceItemSnapshot(_ url: URL) throws -> WorkspaceItemSnapshot {
        let manager = FileManager.default
        let rootAttributes = try manager.attributesOfItem(atPath: url.path)
        guard let device = (rootAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (rootAttributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries: [WorkspaceItemSnapshot.Entry] = []
        var fileIdentities: [DocumentFileIdentity] = []
        func read(_ current: URL, relative: String) throws {
            let attributes = try manager.attributesOfItem(atPath: current.path)
            guard let kind = attributes[.type] as? FileAttributeType else { throw CocoaError(.fileReadUnknown) }
            switch kind {
            case .typeDirectory:
                entries.append(.init(path: relative, kind: "directory", content: Data()))
                let children = try manager.contentsOfDirectory(atPath: current.path).sorted()
                for name in children {
                    try read(current.appendingPathComponent(name), relative: relative.isEmpty ? name : relative + "/" + name)
                }
            case .typeSymbolicLink:
                let target = try manager.destinationOfSymbolicLink(atPath: current.path)
                entries.append(.init(path: relative, kind: "link", content: Data(target.utf8)))
            case .typeRegular:
                fileIdentities.append(DocumentFileIdentity.resolve(current))
                let handle = try FileHandle(forReadingFrom: current)
                defer { try? handle.close() }
                var digest = SHA256()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    digest.update(data: chunk)
                }
                entries.append(.init(path: relative, kind: "file", content: Data(digest.finalize())))
            default:
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        try read(url, relative: "")
        return WorkspaceItemSnapshot(rootDevice: device, rootInode: inode, entries: entries, fileIdentities: fileIdentities)
    }

    static var supportedContentTypes: [UTType] {
        Self.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}

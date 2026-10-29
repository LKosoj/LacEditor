import Foundation
import UniformTypeIdentifiers

enum MarkdownImageCopyService {
    enum CopyError: LocalizedError {
        case invalidDestination
        var errorDescription: String? { L10n.tr("图片目标文件夹无效") }
    }

    struct BatchResult {
        let edit: MarkdownFormattingEdit
        let created: [URL]
    }

    struct PartialFailure: LocalizedError {
        let created: [URL]
        let reason: String
        var errorDescription: String? { L10n.tr("图片复制未完成：%@；已创建：%@", reason, created.map(\.path).joined(separator: ", ")) }
    }

    struct MoveAllPlan {
        struct Item {
            let source: URL?
            let destination: URL
            let identity: WorkspaceNodeIdentity?
            let data: Data?
        }
        let items: [Item]
        let edit: MarkdownFormattingEdit
    }

    static func prepareMoveAll(text: String, selection: NSRange, document: URL?, folder: URL,
                               files: FileService, session: URLSession = .shared) async throws -> MoveAllPlan {
        let images = try MarkdownImageUploadService.images(in: text, allowSharedReference: false, isCancelled: { Task.isCancelled })
        guard !images.isEmpty, folder.isFileURL,
              try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CopyError.invalidDestination }
        let paths = images.contains(where: { MarkdownResourcePaths.requiresRoot($0.address) })
            ? try MarkdownResourcePaths(text: text, document: document) : nil
        var items: [MoveAllPlan.Item] = [], targets: [URL] = [], known: [String: (URL, String)] = [:], used = Set<String>()
        for image in images {
            try Task.checkCancellation()
            let parsed = URL(string: image.address)
            let remote = ["http", "https"].contains(parsed?.scheme?.lowercased() ?? "")
            let payload: MarkdownImageUploadService.Payload
            let key: String
            if remote, let parsed {
                var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
                components?.fragment = nil
                key = "url:" + (components?.url?.absoluteString ?? parsed.absoluteString)
                if let target = known[key] { targets.append(target.0); continue }
                payload = try await MarkdownImageUploadService.download(parsed, session: session)
            } else {
                if image.address.hasPrefix("data:") {
                    key = "data:" + String(image.address.prefix { $0 != "#" })
                    if let target = known[key] { targets.append(target.0); continue }
                } else {
                    let local = try MarkdownImageUploadService.localURL(address: image.address, document: document, paths: paths)
                    let identity = DocumentFileIdentity.resolve(URL(fileURLWithPath: local.path))
                    key = identity.resourceIdentifier.map { "id:" + $0 } ?? "path:" + identity.canonicalPath
                    if let target = known[key] {
                        guard let type = UTType(filenameExtension: local.pathExtension), type.conforms(to: .image),
                              type.preferredMIMEType?.lowercased() == target.1 else { throw MarkdownImageUploadService.UploadError.invalidInput }
                        targets.append(target.0); continue
                    }
                }
                payload = try MarkdownImageUploadService.payload(address: image.address, document: document, paths: paths)
            }
            try Task.checkCancellation()
            let source = payload.localURL?.standardizedFileURL.resolvingSymlinksInPath()
            var name = payload.filename
            if remote, let candidate = parsed?.lastPathComponent, !candidate.isEmpty,
               UTType(filenameExtension: URL(fileURLWithPath: candidate).pathExtension)?.preferredMIMEType?.lowercased() == payload.mime {
                name = candidate
            }
            let original = URL(fileURLWithPath: name), stem = original.deletingPathExtension().lastPathComponent, ext = original.pathExtension
            var destination = folder.appendingPathComponent(name)
            let same = source.map { DocumentFileIdentity.resolve($0).matches(DocumentFileIdentity.resolve(destination)) } ?? false
            if !same {
                var suffix = 2
                while used.contains(destination.path) || (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
                    try Task.checkCancellation()
                    name = stem + "-\(suffix)" + (ext.isEmpty ? "" : "." + ext)
                    destination = folder.appendingPathComponent(name)
                    suffix += 1
                }
            }
            used.insert(destination.path)
            if !same {
                items.append(.init(source: source, destination: destination,
                                   identity: try source.map { try files.workspaceNodeIdentity($0) }, data: source == nil ? payload.data : nil))
            }
            guard let address = MarkdownImageEditingService.address(for: destination, document: document),
                  let url = URL(string: address) else { throw MarkdownImageUploadService.UploadError.invalidResult }
            known[key] = (url, payload.mime)
            targets.append(url)
        }
        let edit = try MarkdownImageUploadService.replacement(in: text, images: images, urls: targets, selection: selection,
                                                               isCancelled: { Task.isCancelled })
        return MoveAllPlan(items: items, edit: edit)
    }

    static func prepare(text: String, selection: NSRange, selectedOnly: Bool, remoteOnly: Bool,
                        document: URL?, folder: URL, session: URLSession = .shared,
                        isCancelled: @escaping () -> Bool = { false }) async throws -> BatchResult {
        var created: [URL] = []
        do {
            let images = try MarkdownImageUploadService.images(in: text, selection: selectedOnly ? selection : nil,
                                                               allowSharedReference: true, isCancelled: isCancelled).filter { image in
                let scheme = URL(string: image.address)?.scheme?.lowercased()
                let remote = scheme == "http" || scheme == "https"
                return remoteOnly ? remote : true
            }
            guard !images.isEmpty else { throw MarkdownImageUploadService.UploadError.invalidInput }
            var paths: MarkdownResourcePaths?
            if images.contains(where: { MarkdownResourcePaths.requiresRoot($0.address) }) {
                paths = try MarkdownResourcePaths(text: text, document: document)
            }
            var copied: [String: (URL, String)] = [:], targets: [URL] = []
            for image in images {
                if Task.isCancelled || isCancelled() { throw CancellationError() }
                let parsed = URL(string: image.address)
                let fragment = URLComponents(string: image.address)?.percentEncodedFragment
                func target(_ url: URL) throws -> URL {
                    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                        throw MarkdownImageUploadService.UploadError.invalidResult
                    }
                    components.percentEncodedFragment = fragment
                    guard let result = components.url else { throw MarkdownImageUploadService.UploadError.invalidResult }
                    return result
                }
                let payload: MarkdownImageUploadService.Payload
                let key: String
                let remote = parsed?.scheme?.lowercased() == "http" || parsed?.scheme?.lowercased() == "https"
                if remote {
                    guard let parsed else { throw MarkdownImageUploadService.UploadError.invalidInput }
                    var identity = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
                    identity?.fragment = nil
                    key = "url:" + (identity?.url?.absoluteString ?? parsed.absoluteString)
                    if let existing = copied[key] { targets.append(try target(existing.0)); continue }
                    payload = try await MarkdownImageUploadService.download(parsed, session: session)
                } else {
                    if image.address.hasPrefix("data:") {
                        key = "data:" + String(image.address.prefix { $0 != "#" })
                        if let existing = copied[key] { targets.append(try target(existing.0)); continue }
                    } else {
                        let local = try MarkdownImageUploadService.localURL(address: image.address, document: document, paths: paths)
                        let identity = DocumentFileIdentity.resolve(URL(fileURLWithPath: local.path))
                        key = identity.resourceIdentifier.map { "id:" + $0 } ?? "path:" + identity.canonicalPath
                        if let existing = copied[key] {
                            guard let type = UTType(filenameExtension: local.pathExtension), type.conforms(to: .image),
                                  type.preferredMIMEType?.lowercased() == existing.1 else { throw MarkdownImageUploadService.UploadError.invalidInput }
                            targets.append(try target(existing.0)); continue
                        }
                    }
                    payload = try MarkdownImageUploadService.payload(address: image.address, document: document, paths: paths)
                }
                if Task.isCancelled || isCancelled() { throw CancellationError() }
                var name = payload.filename
                if remote, let candidate = parsed?.lastPathComponent, !candidate.isEmpty,
                   UTType(filenameExtension: URL(fileURLWithPath: candidate).pathExtension)?.preferredMIMEType?.lowercased() == payload.mime {
                    name = candidate
                }
                let intended = folder.appendingPathComponent(name)
                let alreadySource = payload.localURL.map { DocumentFileIdentity.resolve($0).matches(DocumentFileIdentity.resolve(intended)) } ?? false
                if !alreadySource {
                    let original = URL(fileURLWithPath: name), stem = original.deletingPathExtension().lastPathComponent, ext = original.pathExtension
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                        if Task.isCancelled || isCancelled() { throw CancellationError() }
                        name = stem + "-\(suffix)" + (ext.isEmpty ? "" : "." + ext)
                        suffix += 1
                    }
                }
                let destination = try copy(payload, to: folder, name: name, isCancelled: { Task.isCancelled || isCancelled() })
                if !alreadySource { created.append(destination) }
                guard let address = MarkdownImageEditingService.address(for: destination, document: document), let url = URL(string: address) else {
                    throw MarkdownImageUploadService.UploadError.invalidResult
                }
                copied[key] = (url, payload.mime)
                targets.append(try target(url))
            }
            if Task.isCancelled || isCancelled() { throw CancellationError() }
            let edit = try MarkdownImageUploadService.replacement(in: text, images: images, urls: targets, selection: selection,
                                                                   isCancelled: { Task.isCancelled || isCancelled() })
            return BatchResult(edit: edit, created: created)
        } catch {
            if created.isEmpty { throw error }
            throw PartialFailure(created: created, reason: error.localizedDescription)
        }
    }

    static func folder(path: String, document: URL?) throws -> URL {
        guard !path.isEmpty else { throw CopyError.invalidDestination }
        var value = path
        if value.contains("${filename}") {
            guard let document, document.isFileURL else { throw CopyError.invalidDestination }
            value = value.replacingOccurrences(of: "${filename}", with: document.lastPathComponent)
        }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL }
        guard let document, document.isFileURL else { throw CopyError.invalidDestination }
        return URL(fileURLWithPath: value, isDirectory: true, relativeTo: document.deletingLastPathComponent()).standardizedFileURL
    }

    static func copy(_ payload: MarkdownImageUploadService.Payload, to folder: URL, name: String? = nil,
                     isCancelled: () -> Bool = { false }) throws -> URL {
        if isCancelled() { throw CancellationError() }
        let filename = name ?? payload.filename
        guard folder.isFileURL, !filename.isEmpty,
              filename != ".", filename != "..",
              URL(fileURLWithPath: filename).lastPathComponent == filename,
              let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension),
              type.preferredMIMEType?.lowercased() == payload.mime.lowercased() else { throw CopyError.invalidDestination }
        let directory = folder.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CopyError.invalidDestination }
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        if let source = payload.localURL, FileManager.default.fileExists(atPath: destination.path),
           DocumentFileIdentity.resolve(source).matches(DocumentFileIdentity.resolve(destination)) {
            return destination
        }
        if isCancelled() { throw CancellationError() }
        try payload.data.write(to: destination, options: .withoutOverwriting)
        return destination
    }
}

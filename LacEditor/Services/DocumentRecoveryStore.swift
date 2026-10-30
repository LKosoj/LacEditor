import Foundation

struct DocumentRecoverySnapshot: Equatable, Sendable {
    let documentID: UUID
    let text: String
    let sourceURL: URL?
    let language: EditorLanguage
    let encoding: String.Encoding
    let revision: UInt
    let selectionRange: NSRange
    let scrollPositionRatio: CGFloat
    let isPreviewVisible: Bool
    let fileRevisionSnapshot: FileRevisionSnapshot?
    let capturedAt: Date
    let isDirty: Bool

    init(documentID: UUID, text: String, sourceURL: URL?, language: EditorLanguage,
         encoding: String.Encoding, revision: UInt, selectionRange: NSRange,
         scrollPositionRatio: CGFloat, isPreviewVisible: Bool,
         fileRevisionSnapshot: FileRevisionSnapshot?, capturedAt: Date, isDirty: Bool = true) {
        self.documentID = documentID
        self.text = text
        self.sourceURL = sourceURL
        self.language = language
        self.encoding = encoding
        self.revision = revision
        self.selectionRange = selectionRange
        self.scrollPositionRatio = scrollPositionRatio
        self.isPreviewVisible = isPreviewVisible
        self.fileRevisionSnapshot = fileRevisionSnapshot
        self.capturedAt = capturedAt
        self.isDirty = isDirty
    }
}

struct DocumentRecoveryReference: Sendable {
    let snapshot: DocumentRecoverySnapshot
    let contentURL: URL
}

/// Итог записи копии для восстановления.
enum DocumentRecoveryPersistResult: Equatable, Sendable {
    case written
    case failed(String)
    case noSession
}

final class DocumentRecoveryStore: @unchecked Sendable {
    private struct SessionMarker: Codable {
        let sessionID: UUID
    }

    private struct SnapshotMetadata: Codable {
        let documentID: UUID
        let sourcePath: String?
        let language: String
        let encodingRawValue: UInt
        let revision: UInt
        let selectionLocation: Int
        let selectionLength: Int
        let scrollPositionRatio: Double
        let isPreviewVisible: Bool
        let canonicalPath: String?
        let resourceIdentifier: String?
        let modificationDate: Date?
        let fileSize: Int?
        let capturedAt: Date
        let contentFileName: String
        let isDirty: Bool?
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(
        label: "com.laceditor.document-recovery",
        qos: .utility
    )
    private var currentSessionID: UUID?

    init(
        rootURL: URL = DocumentRecoveryStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func startSession() throws -> [DocumentRecoverySnapshot] {
        try startSessionReferences().map { reference in
            try Self.read(reference)
        }
    }

    static func read(_ reference: DocumentRecoveryReference) throws -> DocumentRecoverySnapshot {
        let snapshot = reference.snapshot
        let text = try String(contentsOf: reference.contentURL, encoding: .utf8)
        return DocumentRecoverySnapshot(
            documentID: snapshot.documentID, text: text, sourceURL: snapshot.sourceURL,
            language: snapshot.language, encoding: snapshot.encoding, revision: snapshot.revision,
            selectionRange: snapshot.selectionRange, scrollPositionRatio: snapshot.scrollPositionRatio,
            isPreviewVisible: snapshot.isPreviewVisible, fileRevisionSnapshot: snapshot.fileRevisionSnapshot,
            capturedAt: snapshot.capturedAt, isDirty: snapshot.isDirty
        )
    }

    func startSessionReferences() throws -> [DocumentRecoveryReference] {
        try queue.sync {
            if currentSessionID != nil { return [] }
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )

            let previousSessionID = try readMarker()?.sessionID
            let recovered = try previousSessionID.map(loadReferences) ?? []
            let sessionID = UUID()
            do {
                try fileManager.createDirectory(
                    at: sessionURL(for: sessionID),
                    withIntermediateDirectories: true
                )

                // Copy recovered records before switching the marker.
                for snapshot in recovered {
                    try copyLocked(snapshot, sessionID: sessionID)
                }
                try writeMarker(SessionMarker(sessionID: sessionID))
            } catch {
                try? fileManager.removeItem(at: sessionURL(for: sessionID))
                throw error
            }
            currentSessionID = sessionID
            removeSessionDirectories(except: sessionID)
            return recovered.map { reference in
                DocumentRecoveryReference(snapshot: reference.snapshot, contentURL: sessionURL(for: sessionID).appendingPathComponent("\(reference.snapshot.documentID.uuidString.lowercased())-\(reference.snapshot.revision).utf8"))
            }
        }
    }

    func persist(_ snapshot: DocumentRecoverySnapshot,
                 completion: (@Sendable (DocumentRecoveryPersistResult) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let completion else {
                try? persistLocked(snapshot)
                return
            }
            let result: DocumentRecoveryPersistResult
            if currentSessionID == nil {
                result = .noSession
            } else {
                do { try persistLocked(snapshot); result = .written }
                catch { result = .failed(error.localizedDescription) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func persistForWorkspaceHandoff(_ snapshots: [DocumentRecoverySnapshot]) throws {
        try queue.sync {
            guard let sessionID = currentSessionID else {
                throw CocoaError(.fileWriteUnknown)
            }
            for snapshot in snapshots {
                try persistLocked(snapshot, sessionID: sessionID)
            }
        }
    }

    func copyForWorkspaceHandoff(_ references: [WorkspaceDocumentReference]) throws -> [DocumentRecoveryReference] {
        try queue.sync {
            guard let sessionID = currentSessionID else { throw CocoaError(.fileWriteUnknown) }
            return try references.map { reference in
                let value = reference.snapshot
                let snapshot = DocumentRecoverySnapshot(
                    documentID: value.documentID, text: "", sourceURL: value.sourceURL,
                    language: value.language, encoding: value.encoding, revision: 0,
                    selectionRange: value.selectionRange, scrollPositionRatio: value.scrollPositionRatio,
                    isPreviewVisible: value.isPreviewVisible, fileRevisionSnapshot: value.fileRevisionSnapshot,
                    capturedAt: Date(), isDirty: value.isDirty
                )
                let recovery = DocumentRecoveryReference(snapshot: snapshot, contentURL: reference.contentURL)
                try copyLocked(recovery, sessionID: sessionID)
                let name = "\(value.documentID.uuidString.lowercased())-0.utf8"
                return DocumentRecoveryReference(snapshot: snapshot, contentURL: sessionURL(for: sessionID).appendingPathComponent(name))
            }
        }
    }

    private func copyLocked(_ reference: DocumentRecoveryReference, sessionID: UUID) throws {
        let snapshot = reference.snapshot
        let directory = sessionURL(for: sessionID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = snapshot.documentID.uuidString.lowercased()
        let name = "\(stem)-\(snapshot.revision).utf8"
        let target = directory.appendingPathComponent(name)
        try fileManager.copyItem(at: reference.contentURL, to: target)
        let baseline = snapshot.fileRevisionSnapshot
        let metadata = SnapshotMetadata(
            documentID: snapshot.documentID, sourcePath: snapshot.sourceURL?.standardizedFileURL.path,
            language: snapshot.language.rawValue, encodingRawValue: snapshot.encoding.rawValue,
            revision: snapshot.revision, selectionLocation: snapshot.selectionRange.location,
            selectionLength: snapshot.selectionRange.length, scrollPositionRatio: Double(snapshot.scrollPositionRatio),
            isPreviewVisible: snapshot.isPreviewVisible, canonicalPath: baseline?.identity.canonicalPath,
            resourceIdentifier: baseline?.identity.resourceIdentifier, modificationDate: baseline?.modificationDate,
            fileSize: baseline?.fileSize, capturedAt: snapshot.capturedAt, contentFileName: name,
            isDirty: snapshot.isDirty
        )
        do {
            try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("\(stem).json"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
    }

    func discard(documentID: UUID) {
        queue.async { [weak self] in
            self?.discardLocked(documentID: documentID)
        }
    }

    func discard(documentIDs: [UUID]) {
        queue.async { [weak self] in
            guard let self else { return }
            for documentID in documentIDs {
                discardLocked(documentID: documentID)
            }
        }
    }

    func finishCleanly(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            defer { DispatchQueue.main.async(execute: completion) }
            self?.finishCleanlyLocked()
        }
    }

    func finishCleanlySynchronously() {
        queue.sync { finishCleanlyLocked() }
    }

    func flushForTesting() {
        queue.sync {}
    }

    func finishCleanlyForTesting() {
        finishCleanlySynchronously()
    }

    private func finishCleanlyLocked() {
        guard let sessionID = currentSessionID else { return }
        try? fileManager.removeItem(at: sessionURL(for: sessionID))
        if (try? readMarker()?.sessionID) == sessionID {
            try? fileManager.removeItem(at: markerURL)
        }
        currentSessionID = nil
    }

    private func persistLocked(_ snapshot: DocumentRecoverySnapshot) throws {
        guard let sessionID = currentSessionID else { return }
        try persistLocked(snapshot, sessionID: sessionID)
    }

    private func persistLocked(_ snapshot: DocumentRecoverySnapshot, sessionID: UUID) throws {
        let directory = sessionURL(for: sessionID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let stem = snapshot.documentID.uuidString.lowercased()
        let contentFileName = "\(stem)-\(snapshot.revision).utf8"
        let contentURL = directory.appendingPathComponent(contentFileName)
        try Data(snapshot.text.utf8).write(to: contentURL, options: .atomic)

        let baseline = snapshot.fileRevisionSnapshot
        let metadata = SnapshotMetadata(
            documentID: snapshot.documentID,
            sourcePath: snapshot.sourceURL?.standardizedFileURL.path,
            language: snapshot.language.rawValue,
            encodingRawValue: snapshot.encoding.rawValue,
            revision: snapshot.revision,
            selectionLocation: snapshot.selectionRange.location,
            selectionLength: snapshot.selectionRange.length,
            scrollPositionRatio: Double(snapshot.scrollPositionRatio),
            isPreviewVisible: snapshot.isPreviewVisible,
            canonicalPath: baseline?.identity.canonicalPath,
            resourceIdentifier: baseline?.identity.resourceIdentifier,
            modificationDate: baseline?.modificationDate,
            fileSize: baseline?.fileSize,
            capturedAt: snapshot.capturedAt,
            contentFileName: contentFileName,
            isDirty: snapshot.isDirty
        )
        let metadataURL = directory.appendingPathComponent("\(stem).json")
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        let prefix = "\(stem)-"
        for candidate in (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where candidate.lastPathComponent.hasPrefix(prefix)
            && candidate.lastPathComponent != contentFileName {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func loadReferences(sessionID: UUID) throws -> [DocumentRecoveryReference] {
        let directory = sessionURL(for: sessionID)
        let metadataURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try metadataURLs.map { metadataURL in
            let metadataData = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(SnapshotMetadata.self, from: metadataData)
            guard let language = EditorLanguage(rawValue: metadata.language) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let sourceURL = metadata.sourcePath.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            let baseline: FileRevisionSnapshot?
            if let canonicalPath = metadata.canonicalPath {
                baseline = FileRevisionSnapshot(
                    identity: DocumentFileIdentity(
                        canonicalPath: canonicalPath,
                        resourceIdentifier: metadata.resourceIdentifier
                    ),
                    modificationDate: metadata.modificationDate,
                    fileSize: metadata.fileSize
                )
            } else {
                baseline = nil
            }
            return DocumentRecoveryReference(snapshot: DocumentRecoverySnapshot(
                documentID: metadata.documentID,
                text: "",
                sourceURL: sourceURL,
                language: language,
                encoding: String.Encoding(rawValue: metadata.encodingRawValue),
                revision: metadata.revision,
                selectionRange: NSRange(
                    location: metadata.selectionLocation,
                    length: metadata.selectionLength
                ),
                scrollPositionRatio: CGFloat(metadata.scrollPositionRatio),
                isPreviewVisible: metadata.isPreviewVisible,
                fileRevisionSnapshot: baseline,
                capturedAt: metadata.capturedAt,
                isDirty: metadata.isDirty ?? true
            ), contentURL: directory.appendingPathComponent(metadata.contentFileName))
        }
        .sorted { $0.snapshot.capturedAt < $1.snapshot.capturedAt }
    }

    private func discardLocked(documentID: UUID) {
        guard let sessionID = currentSessionID else { return }
        let directory = sessionURL(for: sessionID)
        let stem = documentID.uuidString.lowercased()
        for candidate in (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where candidate.lastPathComponent == "\(stem).json"
            || candidate.lastPathComponent.hasPrefix("\(stem)-") {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private var markerURL: URL {
        rootURL.appendingPathComponent("ActiveSession.json")
    }

    private func sessionURL(for sessionID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "Session-\(sessionID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func readMarker() throws -> SessionMarker? {
        guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
        return try JSONDecoder().decode(
            SessionMarker.self,
            from: Data(contentsOf: markerURL)
        )
    }

    private func writeMarker(_ marker: SessionMarker) throws {
        try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
    }

    private func removeSessionDirectories(except activeSessionID: UUID) {
        let activeURL = sessionURL(for: activeSessionID).standardizedFileURL
        for candidate in (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [] where candidate.lastPathComponent.hasPrefix("Session-")
            && candidate.standardizedFileURL != activeURL {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = AppEnvironment.dataDirectoryName
        return base.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }
}

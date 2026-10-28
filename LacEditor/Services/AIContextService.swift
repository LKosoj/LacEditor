import Foundation

enum AIContextInput: Identifiable, Hashable {
    case document(UUID)
    case file(URL)

    var id: String {
        switch self {
        case .document(let id): "document:\(id.uuidString)"
        case .file(let url): "file:\(url.standardizedFileURL.path)"
        }
    }
}

struct AIContextSnapshot {
    let input: AIContextInput
    let name: String
    let text: String
    weak var document: EditorDocument?
    let documentRevision: UInt?
    let fileRevision: FileRevisionSnapshot?
}

enum AIContextError: LocalizedError {
    case unavailable
    case encodingRequired

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.tr("所选来源已不可用或已更改。")
        case .encodingRequired: L10n.tr("请先在编辑器中打开文件并选择编码。")
        }
    }
}

enum AIContextService {
    @MainActor
    static func capture(_ inputs: [AIContextInput], appState: AppState) async throws -> [AIContextSnapshot] {
        var snapshots: [AIContextSnapshot] = []
        for input in inputs {
            try Task.checkCancellation()
            let documents = appState.windowManager?.documentsForAI ?? appState.documents
            let document: EditorDocument?
            switch input {
            case .document(let id):
                document = documents.first { $0.id == id }
                guard document != nil else { throw AIContextError.unavailable }
            case .file(let url):
                let identity = DocumentFileIdentity.resolve(url)
                document = documents.first { $0.fileIdentity?.matches(identity) == true }
            }
            if let document {
                guard isAvailable(document, appState: appState) else { throw AIContextError.unavailable }
                let snapshot = document.synchronizedSnapshot()
                snapshots.append(AIContextSnapshot(input: input, name: document.displayName, text: snapshot.text,
                                                   document: document, documentRevision: snapshot.revision, fileRevision: nil))
            } else if case .file(let url) = input {
                let prepared = try await Task.detached { try FileService.prepareRead(url) }.value
                try Task.checkCancellation()
                guard case .decoded(let decoded) = prepared else { throw AIContextError.encodingRequired }
                snapshots.append(AIContextSnapshot(input: input, name: url.lastPathComponent, text: decoded.text,
                                                   document: nil, documentRevision: nil, fileRevision: decoded.fileRevisionSnapshot))
            }
        }
        guard isCurrent(snapshots, appState: appState) else { throw AIContextError.unavailable }
        return snapshots
    }

    @MainActor
    static func isCurrent(_ snapshots: [AIContextSnapshot], appState: AppState) -> Bool {
        let documents = appState.windowManager?.documentsForAI ?? appState.documents
        return snapshots.allSatisfy { snapshot in
            if let document = snapshot.document {
                guard documents.contains(where: { $0 === document }),
                      isAvailable(document, appState: appState),
                      document.textRevision == snapshot.documentRevision, !document.hasPendingLiveEdits else { return false }
                if case .file(let url) = snapshot.input {
                    return document.fileIdentity?.matches(DocumentFileIdentity.resolve(url)) == true
                }
                return true
            }
            guard case .file(let url) = snapshot.input, let revision = snapshot.fileRevision else { return false }
            let identity = DocumentFileIdentity.resolve(url)
            guard !documents.contains(where: { $0.fileIdentity?.matches(identity) == true }) else { return false }
            return (try? FileRevisionSnapshot.capture(url)) == revision
        }
    }

    @MainActor
    private static func isAvailable(_ document: EditorDocument, appState: AppState) -> Bool {
        switch document.ioState {
        case .opening, .failed: return false
        case .idle, .saving: break
        }
        let owner = appState.windowManager?.stateContaining(document) ?? appState
        return !owner.isOpeningPlaceholder(document)
            && appState.windowManager?.isRestorationPlaceholder(document) != true
    }

    static func promptContext(_ snapshots: [AIContextSnapshot]) -> String {
        struct Item: Encodable { let name: String; let text: String }
        let items = snapshots.map { Item(name: $0.name, text: $0.text) }
        guard let data = try? JSONEncoder().encode(items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

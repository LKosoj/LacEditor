import SwiftUI

/// Список снимков текущего файла для секции «Сцена» правой панели.
@MainActor
final class SnapshotListModel: ObservableObject {
    @Published private(set) var snapshots: [DocumentSnapshotInfo] = []
    @Published private(set) var isLoading = false

    private let store: DocumentSnapshotStore
    private var location: DocumentSnapshotLocation?
    private var generation = 0
    private var observer: NSObjectProtocol?

    init(store: DocumentSnapshotStore = .shared) {
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: DocumentSnapshotStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload(location: self.location)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Перезагружает список при смене файла или сцены.
    func bind(to location: DocumentSnapshotLocation?) {
        self.location = location
        reload(location: location)
    }

    func reload(location: DocumentSnapshotLocation?) {
        generation += 1
        let token = generation
        guard let location else {
            snapshots = []
            isLoading = false
            return
        }
        isLoading = true
        let store = store
        Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { store.list(location: location) }.value
            guard let self, token == self.generation else { return }
            self.snapshots = list
            self.isLoading = false
        }
    }
}

struct SnapshotsSectionView: View {
    @ObservedObject var appState: AppState
    @StateObject private var model = SnapshotListModel()
    @State private var renaming: DocumentSnapshotInfo?
    @State private var renameDraft = ""
    @State private var deleting: DocumentSnapshotInfo?

    private var location: DocumentSnapshotLocation? {
        appState.selectedDocument.flatMap { appState.snapshotLocation(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("快照")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.tr("制作快照…")) { appState.makeSnapshot() }
                    .disabled(!appState.canMakeSnapshot)
                    .accessibilityLabel(L10n.tr("制作快照"))
                    .accessibilityIdentifier("writer.snapshots.make")
            }
            if location == nil {
                ContentUnavailableView(L10n.tr("还没有快照"), systemImage: "camera",
                                       description: Text(L10n.tr("保存文件后才能制作快照")))
            } else if model.snapshots.isEmpty && !model.isLoading {
                ContentUnavailableView(L10n.tr("还没有快照"), systemImage: "camera",
                                       description: Text(L10n.tr("按 ⌃⌘S 保存当前文本的快照")))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.snapshots) { info in row(info) }
                }
                .accessibilityIdentifier("writer.snapshots.list")
            }
        }
        .onAppear { model.bind(to: location) }
        .onChange(of: location) { _, new in model.bind(to: new) }
        .alert(L10n.tr("重命名"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.tr("快照名称"), text: $renameDraft)
            Button(L10n.tr("重命名")) { commitRename() }
            Button(L10n.tr("取消"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(L10n.tr("删除此快照？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { info in
            Button(L10n.tr("删除"), role: .destructive) { delete(info) }
            Button(L10n.tr("取消"), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(L10n.tr("此操作无法撤销。"))
        }
    }

    private func row(_ info: DocumentSnapshotInfo) -> some View {
        let relative = relativeDate(info.date)
        return VStack(alignment: .leading, spacing: 2) {
            Text(info.name).lineLimit(2)
            Text(relative).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(L10n.tr("比较")) { appState.presentVersionHistory(mode: .snapshots, selecting: info.id) }
                    .accessibilityLabel(L10n.tr("比较"))
                Button(L10n.tr("恢复此版本")) {
                    if let document = appState.selectedDocument { appState.restoreSnapshot(info, in: document) }
                }
                .accessibilityLabel(L10n.tr("恢复此版本"))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.name), \(relative)")
        .accessibilityIdentifier("writer.snapshots.row.\(info.id.uuidString)")
        .accessibilityAction(named: L10n.tr("比较")) {
            appState.presentVersionHistory(mode: .snapshots, selecting: info.id)
        }
        .accessibilityAction(named: L10n.tr("恢复此版本")) {
            if let document = appState.selectedDocument { appState.restoreSnapshot(info, in: document) }
        }
        .accessibilityAction(named: L10n.tr("重命名")) {
            renameDraft = info.name
            renaming = info
        }
        .accessibilityAction(named: L10n.tr("删除")) { deleting = info }
        .contextMenu {
            Button(L10n.tr("重命名")) {
                renameDraft = info.name
                renaming = info
            }
            Button(L10n.tr("删除"), role: .destructive) { deleting = info }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: L10n.languageCode)
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func commitRename() {
        guard let info = renaming, let location else { renaming = nil; return }
        let name = renameDraft
        renaming = nil
        let store = DocumentSnapshotStore.shared
        let document = appState.selectedDocument
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do { try store.rename(id: info.id, to: name, location: location); return nil } catch { return error }
            }.value
            if failure != nil { document?.statusMessage = L10n.tr("无法保存快照") }
        }
    }

    private func delete(_ info: DocumentSnapshotInfo) {
        guard let location else { deleting = nil; return }
        deleting = nil
        let store = DocumentSnapshotStore.shared
        let document = appState.selectedDocument
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do { try store.delete(id: info.id, location: location); return nil } catch { return error }
            }.value
            if let failure {
                document?.statusMessage = (failure as? DocumentSnapshotError) == .readOnly
                    ? L10n.tr("快照由较新版本创建，无法修改")
                    : L10n.tr("无法保存快照")
            }
        }
    }
}

import SwiftUI

/// Состояние мастера «Создание проекта рукописи». Сам читает список файлов и сам отменяет чтение при закрытии.
@MainActor
final class ManuscriptWizardModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: String
        var isOn: Bool
    }

    private struct Loaded: Sendable {
        let paths: [String]
        let language: String?
    }

    nonisolated static let maxFiles = 2000

    let root: URL
    @Published var title: String
    @Published var language: String
    @Published var entries: [Entry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isTruncated = false
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        title = root.lastPathComponent
        language = ManuscriptProject.bcp47Language(forInterface: L10n.languageCode)
        start()
    }

    func cancel() { task?.cancel() }

    var selectedPaths: [String] { entries.filter(\.isOn).map(\.id) }

    func setAll(_ on: Bool) {
        for index in entries.indices { entries[index].isOn = on }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        entries.move(fromOffsets: offsets, toOffset: destination)
    }

    private func start() {
        let root = root
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> (Loaded, Bool)? in
                guard let listing = try? FolderSearchService.listing(root: root, isCancelled: { Task.isCancelled }) else { return nil }
                let files = listing.values
                    .filter { !$0.isSymbolicLink }
                    .map(\.file)
                    .filter {
                        ManuscriptProjectFiles.textExtensions.contains($0.url.pathExtension.lowercased())
                            && !ManuscriptProjectFiles.isServiceFolder(relativePath: $0.relativePath)
                    }
                    .sorted(by: FolderSearchService.fileOrder)
                let truncated = files.count > ManuscriptWizardModel.maxFiles
                let limited = Array(files.prefix(ManuscriptWizardModel.maxFiles))
                // Язык по началу первого файла, который будет отмечен по умолчанию.
                var language: String?
                if let first = limited.first(where: { ManuscriptWizardModel.isDefaultOn($0.relativePath) }),
                   let handle = try? FileHandle(forReadingFrom: first.url) {
                    let data = (try? handle.read(upToCount: 20_000)) ?? Data()
                    try? handle.close()
                    language = TextSegmentation.languageCode(for: TextSegmentation.language(of: String(decoding: data, as: UTF8.self)))
                }
                return (Loaded(paths: limited.map(\.relativePath), language: language), truncated)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            guard let result else { return }
            let (loaded, truncated) = result
            self.entries = loaded.paths.map { Entry(id: $0, isOn: Self.isDefaultOn($0)) }
            self.isTruncated = truncated
            if let language = loaded.language { self.language = language }
        }
    }

    /// По умолчанию отмечены md/markdown/txt в корне папки.
    nonisolated static func isDefaultOn(_ relativePath: String) -> Bool {
        !relativePath.contains("/")
            && ManuscriptProjectFiles.compileExtensions.contains((relativePath as NSString).pathExtension.lowercased())
    }
}

struct ManuscriptProjectWizardView: View {
    @ObservedObject var model: ManuscriptWizardModel
    /// Создаёт проект; возвращает текст ошибки или nil.
    let create: (String, String?, [String]) -> String?
    let cancel: () -> Void

    private var trimmedTitle: String { model.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("创建书稿项目"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("writer.wizard.title")
            Text(model.root.path)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            TextField(L10n.tr("项目名称"), text: $model.title)
            Picker(L10n.tr("项目语言"), selection: $model.language) {
                Text(L10n.tr("中文")).tag("zh-CN")
                Text("English").tag("en")
                Text("Русский").tag("ru")
            }
            Text(L10n.tr("选择要纳入项目的文件，拖动行调整顺序。文件不会被修改。"))
                .font(.caption).foregroundStyle(.secondary)
            fileList
            if model.isTruncated {
                Text(L10n.tr("文件过多，仅列出前 %d 个", ManuscriptWizardModel.maxFiles))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                StatusMessageView(kind: .error, text: message)
            }
            HStack {
                let allOn = !model.entries.isEmpty && model.entries.allSatisfy(\.isOn)
                Button(allOn ? L10n.tr("取消全选") : L10n.tr("全选")) { model.setAll(!allOn) }
                    .disabled(model.entries.isEmpty)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button(L10n.tr("取消")) { cancel() }
                    .accessibilityIdentifier("writer.wizard.cancel")
                Button(L10n.tr("创建")) {
                    model.errorMessage = create(trimmedTitle, model.language, model.selectedPaths)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || model.isLoading)
                .accessibilityIdentifier("writer.wizard.create")
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 440)
        .onExitCommand { cancel() }
        .onDisappear { model.cancel() }
    }

    private var fileList: some View {
        List {
            ForEach($model.entries) { $entry in
                Toggle(isOn: $entry.isOn) {
                    Text(entry.id).lineLimit(1).truncationMode(.middle)
                }
            }
            .onMove(perform: model.move)
        }
        .overlay {
            if model.entries.isEmpty && !model.isLoading {
                Text(L10n.tr("文件夹中没有文本文件，可创建空项目"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .accessibilityIdentifier("writer.wizard.list")
    }
}

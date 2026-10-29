import SwiftUI

struct FolderSearchView: View {
    @ObservedObject var controller: FolderSearchController
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.root != nil || controller.quickOpenRequest != nil || !controller.quickOpenItems.isEmpty || controller.isWorking {
                if let root = controller.root {
                    Text(L10n.tr("搜索范围：%@", root.path)).font(.caption).textSelection(.enabled)
                } else { Text(L10n.tr("文件夹位置")).font(.caption) }
                Picker(L10n.tr("文件夹搜索"), selection: $controller.mode) {
                    Text(L10n.tr("按名称打开")).tag(FolderSearchController.Mode.files)
                    Text(L10n.tr("搜索文件内容")).tag(FolderSearchController.Mode.text)
                    Text(L10n.tr("搜索标签")).tag(FolderSearchController.Mode.tags)
                }.pickerStyle(.segmented).disabled(controller.root == nil)
                HStack {
                    TextField(L10n.tr("搜索文件夹"), text: $controller.query)
                        .focused($queryFocused)
                        .onSubmit { controller.submit() }
                    Button(L10n.tr("搜索")) { controller.start() }
                        .disabled(controller.query.isEmpty && controller.quickOpenRequest == nil)
                }
                if controller.isWorking { ProgressView().controlSize(.small) }
                if controller.message == .stale { Text(L10n.tr("结果已过期，请重新搜索")).foregroundStyle(.secondary) }
                if controller.message == .failed { Text(L10n.tr("搜索失败")).foregroundStyle(.secondary) }
                if controller.hasSearched && controller.files.isEmpty && controller.matches.isEmpty && controller.quickOpenItems.isEmpty {
                    Text(L10n.tr("没有匹配结果")).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if controller.quickOpenRequest != nil { queryFocused = true } }
        .onChange(of: controller.quickOpenRequest) { _, request in
            if request != nil { queryFocused = true }
        }
        .task(id: controller.quickOpenRequest.map { [$0.uuidString, controller.query] }) {
            guard controller.quickOpenRequest != nil else { return }
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await controller.start()?.value
        }
    }

}

struct FolderSearchRow: Identifiable {
    enum Content {
        case file(FolderSearchService.File), match(FolderSearchService.Match), problem(FolderSearchService.Problem), quick(FolderSearchController.QuickOpenItem)
    }
    let id: String
    let content: Content

    @MainActor
    static func rows(_ controller: FolderSearchController) -> [Self] {
        let files: [Self] = controller.quickOpenItems.isEmpty
            ? controller.files.enumerated().map { .init(id: "file-\($0.offset)", content: .file($0.element)) }
            : controller.quickOpenItems.enumerated().map { .init(id: "quick-\($0.offset)", content: .quick($0.element)) }
        let matches: [Self] = controller.matches.enumerated().map { .init(id: "match-\($0.offset)", content: .match($0.element)) }
        let problems: [Self] = controller.problems.enumerated().map { .init(id: "problem-\($0.offset)", content: .problem($0.element)) }
        return files + matches + problems
    }
}

struct FolderSearchRowView: View {
    @ObservedObject var controller: FolderSearchController
    let row: FolderSearchRow

    var body: some View {
        Group {
            switch row.content {
            case let .quick(item):
                Button { controller.select(item) } label: {
                    switch item {
                    case let .folder(url): Label(url.path, systemImage: "folder")
                    case let .file(file): Label(file.relativePath, systemImage: "doc.text")
                    }
                }.buttonStyle(.plain)
            case let .file(file):
                Button(file.relativePath) { controller.select(file) }.buttonStyle(.plain)
            case let .match(match):
                Button { controller.select(match) } label: {
                    VStack(alignment: .leading) {
                        Text(match.file.relativePath).font(.caption)
                        Text(match.context).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            case let .problem(problem):
                Text("\(problem.url.path): \(reason(problem.reason))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reason(_ reason: FolderSearchService.ProblemReason) -> String {
        switch reason {
        case .inaccessible: L10n.tr("无法读取")
        case .symbolicLink: L10n.tr("已跳过符号链接")
        case .invalidUTF8: L10n.tr("不是有效的 UTF-8")
        case .invalidTags: L10n.tr("无法读取 YAML 标签")
        case .changed: L10n.tr("文件已变化")
        case .conflictingOpenDocuments: L10n.tr("打开的文档冲突")
        }
    }
}

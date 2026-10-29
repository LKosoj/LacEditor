import SwiftUI

struct FolderSearchView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: FolderSearchController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.root != nil || (controller.isWorking && controller.quickOpenRequest == nil) {
                if let root = controller.root {
                    Text(L10n.tr("搜索范围：%@", root.path)).font(.caption).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).stableHelp(root.path)
                } else { Text(L10n.tr("文件夹位置")).font(.caption) }
                Picker(L10n.tr("文件夹搜索"), selection: $controller.mode) {
                    Text(L10n.tr("按名称打开")).tag(FolderSearchController.Mode.files)
                    Text(L10n.tr("搜索文件内容")).tag(FolderSearchController.Mode.text)
                    Text(L10n.tr("搜索标签")).tag(FolderSearchController.Mode.tags)
                }.pickerStyle(.segmented).disabled(controller.root == nil)
                HStack {
                    TextField(L10n.tr("搜索文件夹"), text: $controller.query)
                        .onSubmit { controller.submit() }
                    Button(L10n.tr("搜索")) { controller.start() }
                        .disabled(controller.query.isEmpty)
                }
                if controller.isWorking && controller.quickOpenRequest == nil { ProgressView().controlSize(.small) }
                if controller.message == .stale { Text(L10n.tr("结果已过期，请重新搜索")).foregroundStyle(.secondary) }
                if controller.message == .failed {
                    Text(L10n.tr("搜索失败")).foregroundStyle(.secondary)
                    Button(L10n.tr("选择其他文件夹…")) { appState.openFolder() }.controlSize(.small)
                }
                if controller.quickOpenRequest == nil && controller.hasSearched && controller.files.isEmpty && controller.matches.isEmpty && controller.quickOpenItems.isEmpty {
                    Text(L10n.tr("没有匹配结果")).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FolderSearchRow: Identifiable {
    enum Content {
        case file(FolderSearchService.File), match(FolderSearchService.Match), problem(FolderSearchService.Problem)
    }
    let id: String
    let content: Content

    @MainActor
    static func rows(_ controller: FolderSearchController) -> [Self] {
        // результаты быстрого открытия показывает только плавающая панель, не боковая
        let files: [Self] = controller.quickOpenItems.isEmpty
            ? controller.files.enumerated().map { .init(id: "file-\($0.offset)", content: .file($0.element)) }
            : []
        let matches: [Self] = controller.matches.enumerated().map { .init(id: "match-\($0.offset)", content: .match($0.element)) }
        let problems: [Self] = controller.problems.enumerated().map { .init(id: "problem-\($0.offset)", content: .problem($0.element)) }
        return files + matches + problems
    }
}

struct FolderSearchRowView: View {
    @ObservedObject var controller: FolderSearchController
    let row: FolderSearchRow
    let navigation: FolderListNavigation

    var body: some View {
        let id = AnyHashable(row.id)
        Group {
            switch row.content {
            case let .file(file):
                Button { navigation.focused = id; controller.select(file) } label: {
                    Text(file.relativePath).lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(FolderListRowNavigation(id: id, navigation: navigation) {
                    controller.select(file); return .handled
                })
            case let .match(match):
                Button { navigation.focused = id; controller.select(match) } label: {
                    VStack(alignment: .leading) {
                        Text(match.file.relativePath).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(match.context).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(FolderListRowNavigation(id: id, navigation: navigation) {
                    controller.select(match); return .handled
                })
            case let .problem(problem):
                Text(L10n.tr("%@：%@", String(describing: problem.url.path), reason(problem.reason)))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Строки, которые можно выбрать с клавиатуры (проблемы — только текст).
    static func selectableIDs(_ rows: [FolderSearchRow]) -> [AnyHashable] {
        rows.compactMap { row -> AnyHashable? in
            switch row.content {
            case .file, .match: return AnyHashable(row.id)
            case .problem: return nil
            }
        }
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

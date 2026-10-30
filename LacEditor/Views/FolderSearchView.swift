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
                        .disabled(controller.replaceState == .applying)
                    Button(L10n.tr("搜索")) { controller.start() }
                        .disabled(controller.query.isEmpty || controller.replaceState == .applying)
                }
                if controller.mode == .text { replaceControls }
                if controller.isWorking && controller.quickOpenRequest == nil { ProgressView().controlSize(.small) }
                if controller.message == .stale { Text(L10n.tr("结果已过期，请重新搜索")).foregroundStyle(.secondary) }
                if controller.message == .invalidPattern { Text(L10n.tr("正则表达式无效")).foregroundStyle(.secondary) }
                if let report = controller.report { reportView(report) }
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

extension FolderSearchView {
    @ViewBuilder
    var replaceControls: some View {
        let isBusy = controller.replaceState != .idle
        HStack {
            Toggle("Aa", isOn: $controller.caseSensitive).help(L10n.tr("区分大小写"))
                .accessibilityLabel(L10n.tr("区分大小写")).accessibilityIdentifier("folderSearch.case")
            Toggle(".*", isOn: $controller.usesRegex).help(L10n.tr("正则表达式"))
                .accessibilityLabel(L10n.tr("正则表达式")).accessibilityIdentifier("folderSearch.regex")
            Toggle("ab", isOn: $controller.wholeWord).help(L10n.tr("全字匹配"))
                .accessibilityLabel(L10n.tr("全字匹配")).accessibilityIdentifier("folderSearch.word")
            Spacer()
            Toggle(L10n.tr("替换"), isOn: $controller.isReplaceEnabled).accessibilityIdentifier("folderSearch.replaceToggle")
        }.toggleStyle(.button).controlSize(.small).disabled(isBusy)
        if controller.isReplaceEnabled {
            TextField(L10n.tr("替换为"), text: $controller.replacement).disabled(isBusy)
                .accessibilityIdentifier("folderSearch.replacement")
            if controller.replaceState == .applying {
                Button(L10n.tr("停止")) { controller.cancelReplace() }.controlSize(.small)
            }
            if controller.hasSearched && !controller.matches.isEmpty {
                let selected = controller.selectedMatches.count
                Text(L10n.tr("已选 %d 处，共 %d 个文件", selected, Set(controller.selectedMatches.map(\.file.url)).count))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.tr("全选")) { controller.setAllSelected(true) }
                    Button(L10n.tr("取消全选")) { controller.setAllSelected(false) }
                    Spacer()
                    Button(L10n.tr("替换所选")) { controller.replaceSelected() }
                        .disabled(!controller.canReplace).accessibilityIdentifier("folderSearch.replaceSelected")
                }.controlSize(.small).disabled(controller.replaceState != .idle)
            }
        }
    }

    @ViewBuilder
    func reportView(_ report: FolderSearchController.ReplaceReport) -> some View {
        DisclosureGroup {
            ForEach(Array(report.replaced.enumerated()), id: \.offset) { _, item in
                Text(L10n.tr("%@：%@", item.file.relativePath, item.isOpen
                    ? L10n.tr("已在编辑器中修改，尚未保存") : L10n.tr("已替换 %d 处", item.count)))
                    .lineLimit(2).truncationMode(.middle)
            }
            ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, item in
                Text(L10n.tr("%@：%@", item.file.relativePath, skipText(item.reason)))
                    .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        } label: {
            VStack(alignment: .leading) {
                Text(L10n.tr("已替换 %d 处（%d 个文件）", report.replacedCount, report.replaced.count))
                if !report.skipped.isEmpty { Text(L10n.tr("已跳过 %d 个文件", report.skipped.count)) }
                if report.isCancelled { Text(L10n.tr("已取消，已替换 %d 个文件", report.replaced.count)) }
            }
        }
        .font(.caption)
        .accessibilityIdentifier("folderSearch.report")
        Button(L10n.tr("关闭")) { controller.dismissReport() }.controlSize(.small)
    }

    private func skipText(_ reason: FolderReplaceService.SkipReason) -> String {
        switch reason {
        case .changed: L10n.tr("文件已变化")
        case .notExactUTF8: L10n.tr("不是精确的 UTF-8（含 BOM 等）")
        case .inaccessible: L10n.tr("无法读取")
        case .symbolicLink: L10n.tr("已跳过符号链接")
        case .writeFailed: L10n.tr("无法写入")
        case .openDocumentBusy, .openInEditorFailed: L10n.tr("无法修改已打开的文档")
        }
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
                HStack(alignment: .top) {
                    if controller.isReplaceEnabled, controller.mode == .text {
                        Toggle(isOn: Binding(get: { controller.isSelected(match) }, set: { _ in controller.toggle(match) })) { EmptyView() }
                            .labelsHidden().toggleStyle(.checkbox).disabled(controller.replaceState != .idle)
                            .accessibilityLabel(controller.previews[match.key].map {
                                L10n.tr("%@：“%@”将替换为“%@”", match.file.relativePath, match.matchedText, $0)
                            } ?? L10n.tr("%@：%@", match.file.relativePath, match.matchedText))
                    }
                    Button { navigation.focused = id; controller.select(match) } label: {
                        VStack(alignment: .leading) {
                            Text(match.file.relativePath).font(.caption).lineLimit(1).truncationMode(.middle)
                            Text(contextText(match)).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .modifier(FolderListRowNavigation(id: id, navigation: navigation) {
                        controller.select(match); return .handled
                    })
                }
                .contextMenu {
                    if controller.isReplaceEnabled, controller.mode == .text {
                        Button(controller.selection(of: match.file) == true
                               ? L10n.tr("取消选择此文件的全部匹配") : L10n.tr("选择此文件的全部匹配")) { controller.toggle(match.file) }
                    }
                }
            case let .problem(problem):
                Text(L10n.tr("%@：%@", String(describing: problem.url.path), reason(problem.reason)))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Контекст строки; при включённой замене совпадение зачёркнуто и сразу за ним показана вставка.
    private func contextText(_ match: FolderSearchService.Match) -> AttributedString {
        let context = match.context as NSString
        let local = NSRange(location: match.range.location - match.contextRange.location, length: match.range.length)
        guard controller.isReplaceEnabled, controller.mode == .text, let replacement = controller.previews[match.key],
              local.location >= 0, NSMaxRange(local) <= context.length else { return AttributedString(match.context) }
        var old = AttributedString(context.substring(with: local))
        old.swiftUI.strikethroughStyle = .single
        var new = AttributedString(replacement)
        new.swiftUI.underlineStyle = .single
        return AttributedString(context.substring(to: local.location)) + old + new + AttributedString(context.substring(from: NSMaxRange(local)))
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

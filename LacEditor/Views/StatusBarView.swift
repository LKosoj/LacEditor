import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument

    @State private var showsBusyIndicator = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    if showsBusyIndicator {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    } else {
                        saveStatusIcon.frame(width: 12, height: 12)
                    }
                    Text(saveStatusLabel)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .layoutPriority(1)
                .help(saveStatusHelp)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(saveStatusLabel)
                .accessibilityValue(saveStatusDetail)
                .accessibilityIdentifier("status.save")
                if document.isLargeFileMode { performanceMenu }
                if document.isReadingMode {
                    Button { appState.toggleReadingMode() } label: {
                        statusItem(L10n.tr("阅读模式"), icon: "book")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("阅读模式：文本只读，可选择、复制并跟随链接（⌥⌘R 退出）"))
                    .accessibilityLabel(L10n.tr("退出阅读模式"))
                    .accessibilityIdentifier("status.readingMode")
                }
                if let suggestion = document.textCodecSuggestionTitle, geometry.size.width >= 600 {
                    Button { appState.presentTextTransformation(.smartDecode) } label: {
                        Label(suggestion, systemImage: "arrow.left.arrow.right")
                    }.buttonStyle(.plain).lineLimit(1).help(L10n.tr("预览解码结果"))
                }
                if let message = document.statusMessage {
                    Text(message).foregroundStyle(document.statusMessageIsError ? .red : .secondary)
                        .lineLimit(1).help(message).layoutPriority(2)
                }
                if geometry.size.width >= 700, document.language == .markdown, !document.isLargeFileMode,
                   let path = document.markdownElementPath {
                    let pathText = path.displayText
                    Text(pathText)
                        .lineLimit(1).truncationMode(.middle)
                        .help(L10n.tr("当前元素：%@", pathText))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.tr("当前元素：%@", pathText))
                        .accessibilityIdentifier("status.currentElement")
                }
                Spacer(minLength: 0)
                if geometry.size.width >= 420 { statusItem(document.encodingName).help(L10n.tr("文件编码")) }
                if geometry.size.width >= 480 { lineEndingMenu }
                if geometry.size.width >= 680, document.isWordCountEnabled, appState.preferences.dailyWordGoal > 0 {
                    WritingGoalStatusItem(store: appState.preferences.writingGoal, goal: appState.preferences.dailyWordGoal)
                }
                if geometry.size.width >= 620, document.isWordCountEnabled {
                    Menu {
                        if let statistics = document.statistics {
                            Text(document.selectionRange.length > 0 ? L10n.tr("选中内容统计") : L10n.tr("文档统计"))
                            if document.language == .markdown { Text(L10n.tr("词数按可读内容统计；字符和行数按源文本统计。")) }
                            Text(L10n.tr("词数：%@", String(statistics.words)))
                            Text(L10n.tr("字符数：%@", String(statistics.characters)))
                            Text(L10n.tr("不含空白的字符数：%@", String(statistics.charactersWithoutWhitespace)))
                            Text(L10n.tr("行数：%@", String(statistics.lines)))
                            Text(L10n.tr("预计阅读：%@ 分钟（%@ 词/分钟）", String(statistics.readingMinutes), String(appState.preferences.readingWordsPerMinute)))
                        } else {
                            Text(L10n.tr(document.statisticsUnavailable ? "无法统计此内容" : "统计更新中"))
                        }
                    } label: {
                        Text(document.statistics.map { statisticsLabel($0) } ?? L10n.tr(document.statisticsUnavailable ? "无法统计此内容" : "统计更新中"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.tr("查看文档统计"))
                }
                Button { appState.presentFindReplace(mode: .goToLine) } label: {
                    statusItem(geometry.size.width >= 360
                               ? L10n.tr("行 %@，列 %@", String(describing: document.cursorLine), String(describing: document.cursorColumn))
                               : "\(document.cursorLine):\(document.cursorColumn)")
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietActionButtonStyle())
                .padding(.horizontal, -4)
                .help(L10n.tr("行 %@，列 %@（点击跳转到行，⌘L）", String(describing: document.cursorLine), String(describing: document.cursorColumn)))
                .accessibilityIdentifier("status.cursor")
                .layoutPriority(3)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(width: geometry.size.width, height: LacEditorDesign.statusBarHeight)
        }
        .frame(height: LacEditorDesign.statusBarHeight)
        .onAppear { document.setStatisticsReadingSpeed(appState.preferences.readingWordsPerMinute) }
        .onChange(of: document.saveStatus) { _, status in
            if case .unsavedCopyFailed = status {
                AccessibilityNotification.Announcement(saveStatusDetail).post()
            }
        }
        .onChange(of: document.id) { _, _ in document.setStatisticsReadingSpeed(appState.preferences.readingWordsPerMinute) }
        .onChange(of: appState.preferences.readingWordsPerMinute) { _, value in document.setStatisticsReadingSpeed(value) }
        .background(Color(nsColor: .lacEditorBackground))
        .task(id: document.ioState) {
            showsBusyIndicator = false
            switch document.ioState {
            case .opening, .saving:
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                showsBusyIndicator = true
            default: break
            }
        }
    }

    private static let timeFormatter = makeSavedAtFormatter(dateStyle: .none)
    private static let dateTimeFormatter = makeSavedAtFormatter(dateStyle: .medium)

    private static func makeSavedAtFormatter(dateStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.languageCode)
        formatter.timeStyle = .short
        formatter.dateStyle = dateStyle
        return formatter
    }

    private var saveStatusLabel: String {
        switch document.saveStatus {
        case .busy: document.ioState.statusText ?? ""
        case .saved: L10n.tr("已保存")
        case .newDocument: L10n.tr("新文档")
        case .unsavedProtected, .unsavedPending, .unsavedUntracked: L10n.tr("未保存")
        case .unsavedCopyFailed: L10n.tr("未保存，无副本")
        }
    }

    @ViewBuilder
    private var saveStatusIcon: some View {
        switch document.saveStatus {
        case .busy:
            Image(systemName: document.isDirty ? "circle.fill" : "circle").font(.system(size: 6))
                .foregroundStyle(document.isDirty ? LacEditorDesign.accent : Color.secondary.opacity(0.6))
        case .unsavedPending, .unsavedUntracked:
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(LacEditorDesign.accent)
        case .saved:
            Image(systemName: "circle").font(.system(size: 6)).foregroundStyle(Color.secondary.opacity(0.6))
        case .newDocument:
            Image(systemName: "doc").font(.system(size: 8)).foregroundStyle(Color.secondary.opacity(0.6))
        case .unsavedProtected:
            Image(systemName: "checkmark.shield").font(.system(size: 8)).foregroundStyle(Color.secondary)
        case .unsavedCopyFailed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange)
        }
    }

    /// Подробность без строки о времени сохранения.
    private var saveStatusDetail: String {
        let base: String
        switch document.saveStatus {
        case .busy: return document.ioState.statusText ?? ""
        case .saved: base = L10n.tr("文件已保存")
        case .newDocument: return L10n.tr("新文档，尚无文件。输入的内容会保存在恢复副本中；按 ⌘S 创建文件。")
        case .unsavedUntracked: base = L10n.tr("有尚未保存的修改")
        case .unsavedProtected: base = L10n.tr("尚未保存到文件。恢复副本与当前内容一致，意外退出后可恢复。")
        case .unsavedPending: base = L10n.tr("尚未保存到文件。停止输入片刻后会更新恢复副本。")
        case .unsavedCopyFailed(let message): base = L10n.tr("尚未保存到文件，且无法写入恢复副本：%@。请手动保存（⌘S）。", message)
        }
        guard let date = document.lastSavedAt else { return base }
        let formatter = Calendar.current.isDateInToday(date) ? Self.timeFormatter : Self.dateTimeFormatter
        return base + "\n" + L10n.tr("上次保存：%@", formatter.string(from: date))
    }

    private var saveStatusHelp: String { saveStatusDetail }

    private func statisticsLabel(_ value: DocumentStatistics) -> String {
        switch appState.preferences.statisticsDisplayUnit {
        case .words: L10n.tr("%@ 词", String(value.words))
        case .characters: L10n.tr("%@ 字符", String(value.characters))
        case .charactersWithoutWhitespace: L10n.tr("%@ 字符（不含空白）", String(value.charactersWithoutWhitespace))
        case .lines: L10n.tr("%@ 行", String(value.lines))
        case .readingMinutes: L10n.tr("%@ 分钟", String(value.readingMinutes))
        }
    }

    private var lineEndingLabel: String {
        guard let summary = document.lineEndings else { return "…" }
        if summary.isMixed { return L10n.tr("混合") }
        // Без переносов новая строка в редакторе вставляется как LF.
        return (summary.uniform ?? .lf).shortName
    }

    private var lineEndingMenu: some View {
        Menu {
            Text(L10n.tr("换行符"))
            if let summary = document.lineEndings {
                Text(L10n.tr("LF：%@，CRLF：%@，CR：%@", String(summary.lf), String(summary.crlf), String(summary.cr)))
            } else {
                Text(L10n.tr("正在检测换行符…"))
            }
            Divider()
            ForEach(LineEnding.allCases) { kind in
                Button { appState.convertLineEndings(to: kind) } label: {
                    if document.lineEndings?.uniform == kind {
                        Label(L10n.tr("转换为 %@", kind.shortName), systemImage: "checkmark")
                    } else {
                        Text(L10n.tr("转换为 %@", kind.shortName))
                    }
                }
            }
        } label: {
            Text(lineEndingLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(document.ioState != .idle || document.isReadingMode)
        .help(L10n.tr("换行符：%@", lineEndingLabel))
        .accessibilityLabel(L10n.tr("换行符：%@", lineEndingLabel))
        .accessibilityIdentifier("status.lineEnding")
    }

    private var performanceMenu: some View {
        Menu {
            Text(document.performanceProfile.displayName)
            Divider()
            featureButton(
                L10n.tr("自动换行"),
                enabled: document.effectiveWordWrap(
                    globalDefault: appState.isWordWrapEnabled
                ),
                feature: .wordWrap
            )
            featureButton(
                L10n.tr("Markdown 预览"),
                enabled: document.isPreviewEffectivelyEnabled,
                feature: .preview
            )
            .disabled(document.language != .markdown)
            featureButton(
                L10n.tr("语法高亮"),
                enabled: document.isSyntaxHighlightingEnabled,
                feature: .syntaxHighlighting
            )
            featureButton(
                L10n.tr("代码折叠"),
                enabled: document.isFoldingEnabled,
                feature: .folding
            )
            featureButton(
                L10n.tr("实时字数统计"),
                enabled: document.isWordCountEnabled,
                feature: .wordCount
            )
            Divider()
            Text(L10n.tr("这些设置仅对当前标签有效"))
        } label: {
            Label(L10n.tr("大文件模式"), systemImage: "gauge.with.dots.needle.33percent")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.tr("查看大文件模式的性能保护选项"))
    }

    private func featureButton(
        _ title: String,
        enabled: Bool,
        feature: DocumentManagedFeature
    ) -> some View {
        Button {
            appState.toggleLargeFileFeature(feature)
        } label: {
            Label(title, systemImage: enabled ? "checkmark" : "minus")
        }
    }

    private func statusItem(_ text: String, icon: String? = nil, color: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct WritingGoalStatusItem: View {
    @ObservedObject var store: WritingGoalStore
    let goal: Int

    var body: some View {
        let written = store.progress()
        let reached = written >= goal
        HStack(spacing: 4) {
            Text("\(written) / \(goal)").monospacedDigit()
            if reached { Image(systemName: "checkmark") }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(L10n.tr("今天已写 %@ 词，目标 %@ 词。按文档统计净增量。", String(written), String(goal)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reached ? L10n.tr("今日字数 %@，目标 %@，已达成", String(written), String(goal)) : L10n.tr("今日字数 %@，目标 %@", String(written), String(goal)))
        .accessibilityIdentifier("status.writingGoal")
    }
}

extension MarkdownElement {
    /// Подпись для пути в строке состояния; логика выбора опирается на `kind`, не на переведённый текст.
    var title: String {
        let base: String
        switch kind {
        case .heading(let level): return L10n.tr("标题 %@ 级", String(level))
        case .quote: base = L10n.tr("引用")
        case .alert: base = L10n.tr("提示块")
        case .listItem: base = L10n.tr("列表项")
        case .task: base = L10n.tr("任务项")
        case .codeBlock(let language):
            return language.map { L10n.tr("代码块（%@）", $0) } ?? L10n.tr("代码块")
        case .mathBlock: return L10n.tr("公式块")
        case .table: return L10n.tr("表格")
        case .footnoteDefinition: return L10n.tr("脚注定义")
        case .htmlBlock: return L10n.tr("HTML 块")
        case .frontMatter: return L10n.tr("元数据（YAML）")
        case .strong: return L10n.tr("加粗")
        case .emphasis: return L10n.tr("斜体")
        case .strikethrough: return L10n.tr("删除线")
        case .code: return L10n.tr("行内代码")
        case .link: return L10n.tr("链接")
        case .footnoteReference: return L10n.tr("脚注引用")
        case .image: return L10n.tr("图片")
        case .formula: return L10n.tr("公式")
        }
        return level > 1 ? L10n.tr("%@（第 %@ 层）", base, String(level)) : base
    }
}

extension MarkdownElementPath {
    /// Последние четыре элемента через « › »; если элементов больше, в начале ставится «…».
    var displayText: String {
        let shown = elements.suffix(4).map(\.title).joined(separator: " › ")
        return elements.count > 4 ? "… › " + shown : shown
    }
}

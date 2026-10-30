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
                        Image(systemName: document.isDirty ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                            .foregroundStyle(document.isDirty ? LacEditorDesign.accent : Color.secondary.opacity(0.6))
                    }
                    Text(document.ioState.statusText ?? (document.isDirty ? L10n.tr("未保存") : L10n.tr("已保存")))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(document.ioState.statusText ?? (document.isDirty ? L10n.tr("有尚未保存的修改") : L10n.tr("文件已保存")))
                }.layoutPriority(1)
                if document.isLargeFileMode { performanceMenu }
                if let suggestion = document.textCodecSuggestionTitle, geometry.size.width >= 600 {
                    Button { appState.presentTextTransformation(.smartDecode) } label: {
                        Label(suggestion, systemImage: "arrow.left.arrow.right")
                    }.buttonStyle(.plain).lineLimit(1).help(L10n.tr("预览解码结果"))
                }
                if let message = document.statusMessage {
                    Text(message).foregroundStyle(document.statusMessageIsError ? .red : .secondary)
                        .lineLimit(1).help(message).layoutPriority(2)
                }
                Spacer(minLength: 0)
                if geometry.size.width >= 420 { statusItem(document.encodingName).help(L10n.tr("文件编码")) }
                if geometry.size.width >= 480 { lineEndingMenu }
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
        .disabled(document.ioState != .idle)
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

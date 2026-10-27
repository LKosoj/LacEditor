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
                    Text(message).foregroundStyle(message.hasPrefix(L10n.tr("JSON 无效")) ? .red : .secondary)
                        .lineLimit(1).help(message).layoutPriority(2)
                }
                Spacer(minLength: 0)
                if geometry.size.width >= 420 { statusItem(document.encodingName).help(L10n.tr("文件编码")) }
                if geometry.size.width >= 620, document.isWordCountEnabled {
                    statusItem(L10n.tr("%@ 字", String(describing: document.wordCount))).help(L10n.tr("文档字数"))
                }
                statusItem(geometry.size.width >= 360
                           ? L10n.tr("行 %@，列 %@", String(describing: document.cursorLine), String(describing: document.cursorColumn))
                           : "\(document.cursorLine):\(document.cursorColumn)")
                    .help(L10n.tr("行 %@，列 %@", String(describing: document.cursorLine), String(describing: document.cursorColumn)))
                    .layoutPriority(3)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(width: geometry.size.width, height: LacEditorDesign.statusBarHeight)
        }
        .frame(height: LacEditorDesign.statusBarHeight)
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
                .font(.system(size: 11))
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

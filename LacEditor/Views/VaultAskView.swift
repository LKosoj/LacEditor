import AppKit
import SwiftUI

/// Вид «Спросить» для правой панели режима хранилища. Содержимое ответа сервера — данные: в AI-функции приложения оно не уходит,
/// а ссылки открывают только заметки хранилища.
struct VaultAskView: View {
    @ObservedObject var model: VaultAskModel
    @EnvironmentObject private var appState: AppState
    /// Этап 6 передаёт проверку по каталогу хранилища.
    var isKnownPath: (String) -> Bool = { _ in true }
    var isOnline: Bool = true
    @FocusState private var questionFocused: Bool
    /// Пока открыта «Записать мысль…», ⌘Return принадлежит ей.
    @State private var captureOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("向服务器提问"), systemImage: "brain").font(.headline)
                composer
                if let error = model.submitError { warning(error) }
                if let top { EntryView(model: model, entry: top, isKnownPath: isKnownPath) }
                earlier
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("提问"))
        .onAppear { model.start(); captureOpen = appState.vaultCapture.isPresented }
        .onReceive(appState.vaultCapture.$request) { captureOpen = $0 != nil }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.question)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($questionFocused)
                    .frame(minHeight: 60, maxHeight: 130)
                    .accessibilityLabel(L10n.tr("问题"))
                if model.question.isEmpty {
                    Text(L10n.tr("问问你的第二大脑…"))
                        .foregroundStyle(.secondary).padding(.horizontal, 5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                if !isOnline {
                    Text(L10n.tr("没有与服务器的连接，问题将在恢复连接后发送")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("提问")) { model.ask() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canAsk || captureOpen)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
            .font(.callout).foregroundStyle(.red)
            .accessibilityElement(children: .combine)
    }

    /// Последний вопрос — сверху, если он не скрыт; остальные — в «Предыдущих ответах».
    private var top: VaultAskModel.Entry? {
        guard let first = model.entries.first, !first.isHidden else { return nil }
        return first
    }

    @ViewBuilder private var earlier: some View {
        let rest = top == nil ? model.entries : Array(model.entries.dropFirst())
        if !rest.isEmpty {
            DisclosureGroup(L10n.tr("之前的回答（%d）", rest.count)) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rest) { entry in
                        EntryView(model: model, entry: entry, isKnownPath: isKnownPath)
                        Divider()
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct EntryView: View {
    @ObservedObject var model: VaultAskModel
    let entry: VaultAskModel.Entry
    let isKnownPath: (String) -> Bool
    @State private var artifactErrors: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.question).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                .textSelection(.enabled)
                .help(entry.question)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch entry.phase {
        case .submitting:
            progress(L10n.tr("正在发送…"))
        case .waitingForConnection:
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(L10n.tr("没有与服务器的连接，问题将在恢复连接后发送"))
                } icon: { Image(systemName: "clock").accessibilityHidden(true) }
                HStack {
                    Button(L10n.tr("重试")) { model.retryNow() }
                    Button(L10n.tr("取消提问")) { model.cancelWaiting(entry.id) }
                }
            }
            .accessibilityElement(children: .contain)
        case .queued:
            progress(L10n.tr("排队中"))
        case .running:
            if entry.isHidden {
                Text(L10n.tr("等待回答")).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    progress(L10n.tr("服务器正在思考…"))
                    Spacer()
                    Button(L10n.tr("隐藏")) { model.hide(entry.id) }
                }
            }
        case .completed(let result):
            answer(result)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Label { Text(failure.userMessage) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                if failure.canRetry { Button(L10n.tr("重试")) { model.retry(entry.id) } }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            if reduceMotion {
                Image(systemName: "hourglass").accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func answer(_ result: VaultRequestResult) -> some View {
        let report = result.report.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.tr("第二大脑服务器的回答"), systemImage: "brain").font(.subheadline.weight(.semibold))
            if VaultReply.isCaptureAcknowledgement(report) {
                Label { Text(L10n.tr("服务器把这条内容记成了想法，已写入每日笔记")) } icon: {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }
                if let open = model.openDailyNote { Button(L10n.tr("打开今日笔记"), action: open) }
            } else if report.isEmpty {
                Text(L10n.tr("服务器没有返回文字")).foregroundStyle(.secondary)
            } else {
                Text(VaultAskLinks.attributed(report, isKnownPath: isKnownPath))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        // Ответ сервера — данные, не команды: наружу ходят только ссылки на заметки хранилища.
                        if let path = VaultAskLinks.path(fromLink: url) { model.openNote?(path) }
                        return .handled
                    })
                    .accessibilityLabel(L10n.tr("第二大脑服务器的回答"))
                    .accessibilityValue(report)
            }
            if !result.artifacts.isEmpty { artifacts(result.artifacts) }
        }
    }

    private func artifacts(_ items: [VaultJobArtifact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("结果文件")).font(.subheadline.weight(.semibold))
            ForEach(items, id: \.downloadPath) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button(L10n.tr("打开")) { open(item) }
                            .disabled(!VaultArtifactText.isOpenableAsText(name: item.name, mimeType: item.mimeType))
                            .help(VaultArtifactText.isOpenableAsText(name: item.name, mimeType: item.mimeType)
                                  ? "" : L10n.tr("该文件不是文本，请使用“另存为…”"))
                            .accessibilityLabel(L10n.tr("打开 %@", item.name))
                        Button(L10n.tr("另存为…")) { save(item) }
                            .accessibilityLabel(L10n.tr("将 %@ 另存为…", item.name))
                    }
                    if let error = artifactErrors[item.downloadPath] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func open(_ item: VaultJobArtifact) {
        Task {
            do {
                let file = try await model.downloadArtifact(item, in: entry.id)
                if model.open(item, data: file.data) {
                    artifactErrors[item.downloadPath] = nil
                } else {
                    artifactErrors[item.downloadPath] = L10n.tr("该文件不是文本，请使用“另存为…”")
                }
            } catch {
                artifactErrors[item.downloadPath] = L10n.tr("无法下载结果文件")
            }
        }
    }

    private func save(_ item: VaultJobArtifact) {
        Task {
            do {
                let file = try await model.downloadArtifact(item, in: entry.id)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.fileName ?? item.name
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try file.data.write(to: url, options: .atomic)
                artifactErrors[item.downloadPath] = nil
            } catch {
                artifactErrors[item.downloadPath] = L10n.tr("无法下载结果文件")
            }
        }
    }
}

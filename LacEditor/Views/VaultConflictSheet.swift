import SwiftUI

/// Данные и шаги листа решения конфликта: загрузка версий, выбор по кускам, применение.
@MainActor
final class VaultConflictSheetModel: ObservableObject {
    enum Phase: Equatable { case loading, failed, ready, applying }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var selection: VaultConflictSelection?
    @Published private(set) var message: String?
    private(set) var context: VaultConflictContext?
    /// Сравнение каждой версии куска с основой: считается один раз при загрузке, а не при каждой перерисовке.
    private(set) var diffs: [Int: (mine: [AITextComparison.Change], server: [AITextComparison.Change])] = [:]

    let serverPath: String
    private let session: VaultSession
    var onApply: ((VaultConflictContext, String) async -> VaultConflictApplyResult)?
    var onClose: (() -> Void)?

    init(session: VaultSession, serverPath: String) {
        self.session = session
        self.serverPath = serverPath
    }

    var title: String { L10n.tr("“%@”与服务器上的修改冲突", VaultPresentation.displayName(ofPath: serverPath)) }

    func load(keepingMessage: String? = nil) {
        phase = .loading
        message = keepingMessage
        Task { @MainActor in
            do {
                switch try await session.engine.conflictContext(serverPath: serverPath) {
                case .noLongerConflicting:
                    await session.refreshStates()
                    AccessibilityNotification.Announcement(L10n.tr("冲突已不存在，修改已自动合并")).post()
                    onClose?()
                case .conflict(let loaded):
                    context = loaded
                    let loadedSelection = VaultConflictSelection(conflict: loaded.conflict)
                    diffs = [:]
                    if !loadedSelection.isWholeTextOnly {
                        for id in loadedSelection.conflictIDs {
                            guard let parts = loadedSelection.parts(of: id) else { continue }
                            diffs[id] = (AITextComparison.changes(before: parts.base, after: parts.mine),
                                         AITextComparison.changes(before: parts.base, after: parts.server))
                        }
                    }
                    selection = loadedSelection
                    phase = .ready
                }
            } catch {
                phase = .failed
                let text = (error as? VaultClientError)?.userMessage ?? L10n.tr("无法读取服务器版本")
                show(text)
            }
        }
    }

    func choose(_ side: VaultMergeSide, for id: Int) {
        selection?.choose(side, for: id)
    }

    /// Клавиши ←/→: выбор варианта кусочка.
    func step(_ direction: Int, for id: Int) { selection?.step(direction, from: id) }

    /// Клавиша Delete: снять выбор.
    func clear(_ id: Int) { selection?.clear(id) }

    /// Сообщение под текстом и озвучивание для VoiceOver: цвет не единственный признак.
    private func show(_ text: String) {
        message = text
        AccessibilityNotification.Announcement(text).post()
    }

    /// «Применить выбранное»: доступно, когда выбраны все куски.
    func applyChoices() {
        guard let text = selection?.resolvedText else { return }
        apply(text)
    }

    func keepWhole(_ side: VaultMergeSide) {
        guard let context else { return }
        apply(side == .mine ? context.mine : context.server)
    }

    private func apply(_ text: String) {
        guard let context, let onApply, phase == .ready else { return }
        phase = .applying
        Task { @MainActor in
            switch await onApply(context, text) {
            case .resolved(let sent):
                let done = sent ? L10n.tr("冲突已解决") : L10n.tr("冲突已解决，连接恢复后发送")
                AccessibilityNotification.Announcement(done).post()
                onClose?()
            case .heldBack(let held):
                // Решение записано, но заметка снова не ушла: говорим как есть.
                var text = L10n.tr("冲突已解决，连接恢复后发送")
                switch held {
                case .conflict: text = L10n.tr("这篇笔记与服务器上的修改冲突。你的修改保存在此 Mac 上。")
                case .issue(let issue): text = L10n.tr("服务器没有接受这篇笔记的修改（%@）", issue.userMessage)
                case .deletedOnServer: text = L10n.tr("这篇笔记已在服务器上删除。你的文本会保存在此 Mac 的“未上传”中。")
                default: break
                }
                AccessibilityNotification.Announcement(text).post()
                onClose?()
            case .snapshotsFailed:
                phase = .ready
                show(L10n.tr("无法保存快照，冲突未改动"))
            case .busy:
                phase = .ready
                show(L10n.tr("笔记正忙，请再试一次"))
            case .changed:
                let text = L10n.tr("数据已变化，已刷新各处内容")
                AccessibilityNotification.Announcement(text).post()
                load(keepingMessage: text)
            }
        }
    }
}

/// Одна версия куска: строки сравнения с основой (как в «Версиях»), длинное свёрнуто до `collapsedLines`.
private struct VaultConflictVersionBox: View {
    let title: String
    let text: String
    let changes: [AITextComparison.Change]
    @State private var showsAll = false
    private static let collapsedLines = 12

    var body: some View {
        let shown = showsAll ? changes : Array(changes.prefix(Self.collapsedLines))
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if text.isEmpty {
                Text(L10n.tr("（已删除）")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown.indices, id: \.self) { TextDiffRow(change: shown[$0]) }
            if changes.count > shown.count {
                Button(L10n.tr("显示全部（%lld 行）", changes.count)) { showsAll = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Лист решения конфликта: каждый конфликтный кусок решается отдельно; версия, которую не выбрали, остаётся в снимках.
/// С клавиатуры: фокус на куске, ↑/↓ переходят между кусками, ←/→ выбирают вариант, Delete снимает выбор, Return применяет.
struct VaultConflictSheet: View {
    @ObservedObject var model: VaultConflictSheetModel
    @FocusState private var focusedID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.headline).lineLimit(2).accessibilityAddTraits(.isHeader)
            Text(L10n.tr("你不选择的版本会保留在快照中。")).font(.caption).foregroundStyle(.secondary)
            if let selection = model.selection, selection.conflict.autoMergedCount > 0 {
                Text(L10n.tr("自动合并：%lld 处", selection.conflict.autoMergedCount)).font(.caption).foregroundStyle(.secondary)
            }
            content
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.2)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 440)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack { if !reduceMotion { ProgressView() }; Text(L10n.tr("正在读取服务器版本…")).font(.callout).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 8) {
                Text(L10n.tr("无法读取服务器版本")).font(.callout)
                Button(L10n.tr("重试")) { model.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .applying:
            if let selection = model.selection {
                if selection.isWholeTextOnly {
                    Text(L10n.tr("笔记太大，无法分段显示。请选择整个版本。")).font(.callout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    pieces(selection)
                }
            }
        }
    }

    private func pieces(_ selection: VaultConflictSelection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(selection.conflictIDs.enumerated()), id: \.element) { index, id in
                        if let parts = selection.parts(of: id) {
                            piece(selection, id: id, number: index + 1, parts: parts).id(id)
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            // Без анимации: при «Уменьшить движение» прокрутка не должна двигаться плавно.
            .onChange(of: focusedID) { _, id in if let id { proxy.scrollTo(id) } }
            .onAppear { if focusedID == nil { focusedID = selection.conflictIDs.first } }
        }
    }

    private func piece(_ selection: VaultConflictSelection, id: Int, number: Int, parts: (mine: String, server: String, base: String)) -> some View {
        let chosen = selection.choice(for: id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("第 %lld 处，共 %lld 处", number, selection.total)).font(.subheadline.weight(.semibold))
                Spacer()
                Label(chosen.map { L10n.tr("已选择：%@", sideName($0)) } ?? L10n.tr("尚未选择"),
                      systemImage: chosen == nil ? "circle" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VaultConflictVersionBox(title: L10n.tr("你的第 %lld–%lld 行", selection.lineRange(of: id, side: .mine).lowerBound,
                                                   selection.lineRange(of: id, side: .mine).upperBound),
                                    text: parts.mine, changes: model.diffs[id]?.mine ?? [])
            VaultConflictVersionBox(title: L10n.tr("来自服务器"), text: parts.server, changes: model.diffs[id]?.server ?? [])
            Picker(L10n.tr("这部分在此处和服务器上都被修改了"), selection: Binding(
                get: { chosen },
                set: { if let side = $0 { model.choose(side, for: id) } })) {
                ForEach(selection.availableSides(for: id), id: \.self) { side in Text(sideName(side)).tag(Optional(side)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.tr("这部分在此处和服务器上都被修改了"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: focusedID == id ? 2 : 0))
        .focusable()
        .focused($focusedID, equals: id)
        .onKeyPress(.leftArrow) { model.step(-1, for: id); return .handled }
        .onKeyPress(.rightArrow) { model.step(1, for: id); return .handled }
        .onKeyPress(.upArrow) {
            if let target = selection.previous(before: id) { focusedID = target }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if let target = selection.next(after: id) { focusedID = target }
            return .handled
        }
        .onKeyPress(.delete) { model.clear(id); return .handled }
        .onKeyPress(.return) {
            if selection.isComplete { model.applyChoices() }
            else if let target = selection.nextUnresolved(after: id) { focusedID = target }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("第 %lld 处，共 %lld 处", number, selection.total))
        .accessibilityValue(chosen.map { L10n.tr("已选择：%@", sideName($0)) } ?? L10n.tr("尚未选择"))
    }

    private func sideName(_ side: VaultMergeSide) -> String {
        switch side {
        case .mine: L10n.tr("你的版本")
        case .server: L10n.tr("来自服务器")
        case .both: L10n.tr("两者（先服务器，后你的）")
        }
    }

    private var footer: some View {
        HStack {
            if let selection = model.selection, !selection.isWholeTextOnly, model.phase != .loading {
                Text(selection.isComplete ? L10n.tr("全部已选择，可以应用")
                     : L10n.tr("还有 %lld 处未选择", selection.total - selection.resolvedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.phase == .applying { Text(L10n.tr("正在应用…")).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(L10n.tr("保留我的整个版本")) { model.keepWhole(.mine) }
                .disabled(model.phase != .ready)
            Button(L10n.tr("采用服务器的整个版本")) { model.keepWhole(.server) }
                .disabled(model.phase != .ready)
            Button(L10n.tr("稍后解决")) { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.tr("应用所选方案")) { model.applyChoices() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase != .ready || model.selection?.isComplete != true)
        }
    }
}

import SwiftUI

/// Лист «Найти кандидатов»: имена из текста, которых ещё нет среди карточек. Ничего не создаётся без подтверждения.
struct WorldCandidatesView: View {
    @ObservedObject var world: StoryCardWorld
    let close: () -> Void
    let create: ([StoryCardCandidate]) -> Void
    let askAI: () -> Void
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var unchecked = Set<UUID>()
    @State private var types: [UUID: StoryCardType] = [:]

    init(world: StoryCardWorld, close: @escaping () -> Void, create: @escaping ([StoryCardCandidate]) -> Void, askAI: @escaping () -> Void) {
        self.world = world
        self.close = close
        self.create = create
        self.askAI = askAI
    }

    private var candidates: [StoryCardCandidate] {
        var seen = Set<String>()
        return (world.localCandidates + world.ai.candidates).filter { seen.insert($0.name.lowercased()).inserted }
    }

    private var chosen: [StoryCardCandidate] {
        candidates.filter { !unchecked.contains($0.id) }.map { candidate in
            var copy = candidate
            copy.type = types[candidate.id] ?? candidate.type
            return copy
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("候选设定")).font(.headline).accessibilityAddTraits(.isHeader)
            Text(L10n.tr("以下名称在当前文档中多次出现，但还没有卡片。"))
                .font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty && world.isSearchingCandidates { searching }
            else if candidates.isEmpty { emptyState } else { list }
            if !world.ai.message.isEmpty {
                AIPanelMessageView(kind: world.ai.messageKind, text: world.ai.message, action: world.ai.messageAction,
                                   openSettings: openAISettings, retry: askAI, sendAnyway: { world.ai.sendAnyway() })
            }
            HStack {
                if world.ai.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("取消")) { close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("world.candidates.cancel")
                Button(L10n.tr("创建所选")) {
                    create(chosen)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("world.candidates.create")
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
        .onExitCommand { close() }
    }

    private var searching: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.tr("正在查找…")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("未找到候选")).foregroundStyle(.secondary)
            if appState.aiAvailability(for: .worldCards) == .available {
                Button(L10n.tr("用 AI 查找候选")) { askAI() }
                    .disabled(world.ai.isRunning)
                    .accessibilityIdentifier("world.candidates.ai")
            } else {
                AIRecommendationHint(feature: .worldCards, message: L10n.tr("开启 AI 后可查找中文等文本中的人物与地点"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 120, alignment: .top)
    }

    private var list: some View {
        List {
            ForEach(candidates) { candidate in
                HStack(alignment: .top, spacing: 8) {
                    Toggle(candidate.name, isOn: Binding(
                        get: { !unchecked.contains(candidate.id) },
                        set: { if $0 { unchecked.remove(candidate.id) } else { unchecked.insert(candidate.id) } }
                    ))
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(candidate.name).fontWeight(.medium)
                            if candidate.fromAI { AIBadge() }
                            Text(L10n.tr("出现 %lld 次", candidate.occurrences)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(candidate.quote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Picker(L10n.tr("卡片类型"), selection: Binding(
                        get: { types[candidate.id] ?? candidate.type },
                        set: { types[candidate.id] = $0 }
                    )) {
                        ForEach(StoryCardType.allCases) { type in Text(type.title).tag(type) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minHeight: 180)
    }

    private func openAISettings() {
        SettingsNavigator.shared.open(.ai, aiPage: appState.aiAvailability(for: .worldCards) == .featureDisabled ? .features : .connections)
        SettingsWindowController.shared.present(windowManager: windowManager)
    }
}

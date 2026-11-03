import SwiftUI

/// Секция «设定» в боковой панели писательского проекта: карточки персонажей, мест и мира.
struct WorldSectionView: View {
    @ObservedObject var session: WriterSession
    @ObservedObject var world: StoryCardWorld
    @ObservedObject var appState: AppState
    @State private var isSectionExpanded: Bool
    @State private var filter = ""

    init(session: WriterSession, appState: AppState) {
        self.session = session
        self.world = session.world
        self.appState = appState
        let saved = UserDefaults.standard.object(forKey: Self.sectionKey(session.projectID)) as? Bool
        _isSectionExpanded = State(initialValue: saved ?? true)
    }

    static func sectionKey(_ projectID: UUID) -> String { "LacEditor.WorldSectionExpanded.\(projectID.uuidString)" }

    private var cards: [StoryCard] { world.catalog.cards }

    private var filtered: [StoryCard] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cards }
        return cards.filter { $0.allNames.contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if isSectionExpanded { content }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .task { appState.refreshWorld() }
        .onChange(of: session.projectID) { _, _ in appState.refreshWorld() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshWorld()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("设定"))
        .accessibilityIdentifier("world.section")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                isSectionExpanded.toggle()
                UserDefaults.standard.set(isSectionExpanded, forKey: Self.sectionKey(session.projectID))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).frame(width: 12)
                    Text(L10n.tr("设定")).font(.subheadline.weight(.semibold))
                    Text("\(cards.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("设定"))
            .accessibilityValue(isSectionExpanded ? L10n.tr("已展开") : L10n.tr("已折叠"))
            Menu {
                ForEach(StoryCardType.allCases) { type in
                    Button { appState.requestWorldCard(type: type) } label: {
                        Label(type.title, systemImage: type.symbol)
                    }
                }
                Divider()
                Button(L10n.tr("查找候选…")) { appState.findWorldCandidates() }
                Button(L10n.tr("添加卡片模板")) { appState.installStoryCardTemplates() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.tr("新建设定卡片"))
            .accessibilityIdentifier("world.add")
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
    }

    @ViewBuilder private var content: some View {
        if cards.isEmpty {
            emptyState
        } else {
            TextField(L10n.tr("筛选设定"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("world.filter")
            ForEach(StoryCardType.allCases) { type in
                let group = filtered.filter { $0.type == type }
                if !group.isEmpty {
                    Text(type.title).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 4)
                    ForEach(group) { card in row(card) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("还没有设定卡片"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L10n.tr("新建%@卡片", StoryCardType.character.title)) { appState.requestWorldCard(type: .character) }
                .controlSize(.small)
            AIRecommendationHint(feature: .worldCards, message: L10n.tr("开启 AI 后可查找中文等文本中的人物与地点"))
        }
        .padding(.horizontal, 4)
    }

    private func row(_ card: StoryCard) -> some View {
        HStack(spacing: 6) {
            Image(systemName: card.type.symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(card.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if card.excludedFromAI {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .help(L10n.tr("此卡片不会发送给 AI"))
                    .accessibilityLabel(L10n.tr("此卡片不会发送给 AI"))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { appState.openStoryCard(card) }
        .focusable()
        .onKeyPress(.return) {
            appState.openStoryCard(card)
            return .handled
        }
        .contextMenu {
            Button(L10n.tr("打开")) { appState.openStoryCard(card) }
            Button(L10n.tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([card.url]) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("%@：%@", card.type.title, card.title))
        .accessibilityHint(card.excludedFromAI ? L10n.tr("此卡片不会发送给 AI") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { appState.openStoryCard(card) }
        .accessibilityIdentifier("world.card.\(card.id)")
    }
}

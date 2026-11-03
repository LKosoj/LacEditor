import SwiftUI

/// Плашки карточек, упомянутых в сцене. Нет упоминаний или нет карточек — раздел не показывается.
struct StoryCardMentionsSection: View {
    @ObservedObject var session: WriterSession
    @ObservedObject var world: StoryCardWorld
    @ObservedObject var appState: AppState
    let node: ManuscriptNode
    @EnvironmentObject private var windowManager: WindowManager
    @State private var mentioned: [StoryCard] = []
    @State private var counts: [String: Int] = [:]
    @State private var isComplete = true

    init(session: WriterSession, appState: AppState, node: ManuscriptNode) {
        self.session = session
        self.world = session.world
        self.appState = appState
        self.node = node
    }

    private struct RefreshKey: Equatable {
        var nodeID: UUID
        var savedAt: Date?
        var cardCount: Int
    }

    var body: some View {
        Group {
            if !mentioned.isEmpty || !isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("提及")).font(.subheadline).foregroundStyle(.secondary)
                    if !isComplete {
                        Text(L10n.tr("提及结果不完整")).font(.caption).foregroundStyle(.secondary)
                    }
                    FlowLayoutRow(spacing: 6) {
                        ForEach(mentioned) { card in
                            Button { appState.openStoryCard(card) } label: {
                                Label(card.title, systemImage: card.type.symbol).lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .focusable()
                            .accessibilityLabel(L10n.tr("%@：%@，提及 %lld 次", card.type.title, card.title, counts[card.id] ?? 0))
                            .accessibilityIdentifier("world.mention.\(card.id)")
                        }
                    }
                }
            }
        }
        .task(id: RefreshKey(nodeID: node.id, savedAt: appState.selectedDocument?.lastSavedAt, cardCount: world.catalog.cards.count)) {
            await load()
        }
    }

    private func load() async {
        let cards = world.catalog.cards
        guard !cards.isEmpty else { mentioned = []; isComplete = true; return }
        let loaded = await WriterNodeTextLoader.load(nodes: [node], store: session.projectStore, windowManager: windowManager)
        guard !Task.isCancelled else { return }
        isComplete = loaded.problems.isEmpty && !loaded.snapshotsUnavailable
        guard let text = loaded.parts.first?.text else { mentioned = []; return }
        let matcher = StoryCardMatcher(cards: cards)
        let counts = await Task.detached(priority: .userInitiated) { StoryCardMentionService.cards(in: text, matcher: matcher) }.value
        guard !Task.isCancelled else { return }
        self.counts = counts
        mentioned = cards.filter { counts[$0.id] != nil }
    }
}

/// Простая переносимая по строкам раскладка для плашек.
private struct FlowLayoutRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

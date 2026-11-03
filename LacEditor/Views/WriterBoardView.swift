import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Тип переноса карточки: только внутри этого процесса и проекта, чужие перетаскивания не принимаются.
private let boardCardType = UTType(exportedAs: "com.laceditor.manuscript-card")

/// Начатое перетаскивание карточки: сам тип данных пуст (как у оглавления), значение перезаписывается при каждом начале.
@MainActor private enum WriterBoardDrag {
    static var current: (projectID: UUID, nodeID: UUID)?
}

/// Куда встанет карточка: у левого или правого края карточки `id`.
private struct BoardDropIndicator: Equatable {
    var id: UUID
    var placeAfter: Bool
}

/// Доска карточек: прямые дети открытой группы (или корня). Правка описаний, статус, метка, порядок и предложения описаний.
struct WriterBoardView: View {
    @ObservedObject var controller: WriterBoardController
    @ObservedObject var store: ManuscriptProjectStore
    @ObservedObject var counter: ManuscriptWordCounter
    @EnvironmentObject private var windowManager: WindowManager
    @FocusState private var gridFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnCount = 1
    @State private var indicator: BoardDropIndicator?
    @State private var labelTarget: UUID?
    @State private var labelText = ""
    // Счётчик нужен только чтобы перерисовать вид при изменении настроек: они публикуются отдельно от вида.
    @State private var preferencesVersion = 0

    private static let minimumCardWidth: CGFloat = 220
    private static let spacing: CGFloat = 12

    private var statuses: [ManuscriptStatus] { store.project?.statuses ?? [] }
    private var aiAvailable: Bool { preferencesVersion >= 0 && controller.isAIAvailable }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let message = controller.lastError { errorBar(message) }
            if let oversize = controller.oversize { oversizeBar(oversize) }
            if !aiAvailable {
                AIRecommendationHint(feature: .summary, message: L10n.tr("开启 AI 后可获得更贴切的梗概"))
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            content
        }
        .onChange(of: counter.counts) { _, _ in controller.refresh() }
        .onReceive(controller.preferencesWillChange.receive(on: DispatchQueue.main)) { _ in preferencesVersion += 1 }
        .alert(L10n.tr("设置标记…"), isPresented: Binding(get: { labelTarget != nil }, set: { if !$0 { labelTarget = nil } })) {
            TextField(L10n.tr("标记"), text: $labelText)
            Button(L10n.tr("确定")) {
                if let id = labelTarget { controller.setLabel(labelText, for: id) }
                labelTarget = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { labelTarget = nil }
        }
    }

    // MARK: Панель управления

    private var controlBar: some View {
        HStack(spacing: 8) {
            if controller.container != nil {
                Button { controller.goUp() } label: { Image(systemName: "chevron.up") }
                    .help(L10n.tr("上一级"))
                    .accessibilityLabel(L10n.tr("上一级"))
            }
            breadcrumb
            Spacer(minLength: 8)
            if let summary = controller.filterSummary {
                Text(L10n.tr("显示 %d / %d", summary.shown, summary.total))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button(L10n.tr("清除筛选")) { controller.resetFilter() }
                    .buttonStyle(.link).font(.caption)
            }
            statusMenu
            tagMenu
            Button { if let id = controller.selection { controller.move(id, step: -1) } } label: { Image(systemName: "arrow.left") }
                .disabled(!canMove)
                .help(L10n.tr("提前"))
                .accessibilityLabel(L10n.tr("提前"))
            Button { if let id = controller.selection { controller.move(id, step: 1) } } label: { Image(systemName: "arrow.right") }
                .disabled(!canMove)
                .help(L10n.tr("延后"))
                .accessibilityLabel(L10n.tr("延后"))
            // Перестановка без сочетаний клавиш: ⌥⌘←/→ заняты переключением вкладок, ⌥⌘↑/↓ — пунктами «上移/下移» меню «书稿项目».
            Button { if let id = controller.selection { controller.move(id, step: -columnCount) } } label: { Image(systemName: "arrow.up") }
                .disabled(!canMove)
                .help(L10n.tr("上移一行"))
                .accessibilityLabel(L10n.tr("上移一行"))
            Button { if let id = controller.selection { controller.move(id, step: columnCount) } } label: { Image(systemName: "arrow.down") }
                .disabled(!canMove)
                .help(L10n.tr("下移一行"))
                .accessibilityLabel(L10n.tr("下移一行"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var canMove: Bool {
        controller.selection != nil && controller.editingSynopsis == nil
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            let crumbs = controller.breadcrumb
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                if index == crumbs.count - 1 {
                    Text(crumb.title).font(.headline).lineLimit(1)
                } else {
                    Button(crumb.title) { controller.goTo(crumb.id) }
                        .buttonStyle(.link).lineLimit(1)
                }
            }
        }
    }

    private var statusMenu: some View {
        Menu {
            Button { controller.filter.status = nil } label: { checkLabel(L10n.tr("所有状态"), controller.filter.status == nil) }
            Button { controller.filter.status = "" } label: { checkLabel(L10n.tr("无状态"), controller.filter.status == "") }
            Divider()
            ForEach(statuses, id: \.title) { status in
                Button { controller.filter.status = status.title } label: { checkLabel(status.title, controller.filter.status == status.title) }
            }
        } label: {
            Text(statusFilterTitle)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(L10n.tr("状态"))
    }

    private var statusFilterTitle: String {
        guard let status = controller.filter.status else { return L10n.tr("所有状态") }
        return status.isEmpty ? L10n.tr("无状态") : status
    }

    private var tagMenu: some View {
        Menu {
            Button { controller.filter.tag = nil } label: { checkLabel(L10n.tr("所有标签"), controller.filter.tag == nil) }
            Divider()
            ForEach(BoardModel.availableTags(in: controller.cards), id: \.self) { tag in
                Button { controller.filter.tag = tag } label: { checkLabel(tag, controller.filter.tag == tag) }
            }
        } label: {
            Text(controller.filter.tag ?? L10n.tr("所有标签"))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(L10n.tr("标签"))
    }

    @ViewBuilder private func checkLabel(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Сообщения

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch controller.lastErrorAction {
            case .openSettings:
                Button(L10n.tr("AI 设置…")) {
                    SettingsNavigator.shared.open(.ai, aiPage: .connections)
                    SettingsWindowController.shared.present(windowManager: windowManager)
                }
            case .retry:
                if let id = controller.lastErrorCard {
                    Button(L10n.tr("重试")) {
                        controller.clearError()
                        controller.suggestSynopsisWithAI(for: id)
                    }
                }
            default:
                EmptyView()
            }
            Button { controller.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.tr("关闭"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private func oversizeBar(_ oversize: WriterBoardController.Oversize) -> some View {
        HStack(spacing: 8) {
            Text(AIRequestSize.warning(label: L10n.tr("书稿场景"), bytes: oversize.bytes))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.tr("仍然发送")) { controller.suggestSynopsisWithAI(for: oversize.id, ignoreSize: true) }
            Button(L10n.tr("取消")) { controller.dismissOversize() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }

    // MARK: Сетка

    @ViewBuilder private var content: some View {
        if controller.cards.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("书稿中还没有场景"), systemImage: "rectangle.on.rectangle")
            } actions: {
                Button(L10n.tr("新建场景")) { controller.createSceneHandler?(controller.container) }
                    .disabled(store.state != .loaded)
            }
        } else if controller.visibleCards.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("没有符合筛选的卡片"), systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button(L10n.tr("清除筛选")) { controller.resetFilter() }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: Self.spacing)], spacing: Self.spacing) {
                    ForEach(controller.visibleCards) { card in
                        BoardCardView(controller: controller, card: card, statuses: statuses, projectID: store.projectID,
                                      aiAvailable: aiAvailable, indicator: $indicator,
                                      select: select, askLabel: askLabel)
                            .id(card.id)
                    }
                }
                .padding(12)
                .animation(reduceMotion ? nil : LacEditorDesign.structuralAnimation, value: controller.visibleCards.map(\.id))
            }
            .onChange(of: controller.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            columnCount = max(1, Int(((width - 24) + Self.spacing) / (Self.minimumCardWidth + Self.spacing)))
        }
        .focusable()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        // Закончилась правка описания (принята или отменена): фокус возвращается сетке, чтобы работали стрелки.
        .onChange(of: controller.editingSynopsis) { _, editing in
            if editing == nil { gridFocused = true }
        }
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in handleKey(press) }
    }

    private func select(_ id: UUID) {
        gridFocused = true
        controller.selection = id
    }

    private func askLabel(_ id: UUID) {
        labelText = controller.cards.first { $0.id == id }?.label ?? ""
        labelTarget = id
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let visible = controller.visibleCards
        let current = controller.selection.flatMap { id in visible.firstIndex { $0.id == id } }
        if press.key == .return {
            guard press.modifiers.isEmpty, let current else { return .ignored }
            let card = visible[current]
            if card.isGroup { controller.enter(card.id) } else { controller.beginEditing(card.id) }
            return .handled
        }
        if press.key == .downArrow, press.modifiers == .command {
            guard let current else { return .ignored }
            let card = visible[current]
            if card.isGroup { controller.enter(card.id) } else { controller.openScene(card.id) }
            return .handled
        }
        guard press.modifiers.isEmpty else { return .ignored }
        let offset: Int
        switch press.key {
        case .leftArrow: offset = -1
        case .rightArrow: offset = 1
        case .upArrow: offset = -columnCount
        case .downArrow: offset = columnCount
        default: return .ignored
        }
        guard let current else {
            controller.selection = visible.first?.id
            return .handled
        }
        let target = current + offset
        if visible.indices.contains(target) { controller.selection = visible[target].id }
        return .handled
    }
}

// MARK: - Карточка

private struct BoardCardView: View {
    @ObservedObject var controller: WriterBoardController
    let card: BoardCard
    let statuses: [ManuscriptStatus]
    let projectID: UUID
    let aiAvailable: Bool
    @Binding var indicator: BoardDropIndicator?
    let select: (UUID) -> Void
    let askLabel: (UUID) -> Void
    @FocusState private var editorFocused: Bool
    @State private var width: CGFloat = 220

    private var isSelected: Bool { controller.selection == card.id }
    private var isEditing: Bool { controller.editingSynopsis == card.id }
    private var draft: WriterBoardController.Draft? { controller.drafts[card.id] }
    private var isBusy: Bool { controller.busy.contains(card.id) }
    private var statusColor: StatusColor? {
        guard let name = card.status else { return nil }
        return statuses.first { $0.title == name }?.color ?? .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if card.isGroup { groupSummary } else { synopsisArea }
            Spacer(minLength: 0)
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? LacEditorDesign.accent : Color.secondary.opacity(0.25),
                                                          lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: indicator?.placeAfter == true ? .trailing : .leading) {
            if indicator?.id == card.id {
                Capsule().fill(LacEditorDesign.accent).frame(width: 3).padding(.vertical, 2).offset(x: indicator?.placeAfter == true ? 7 : -7)
                    .allowsHitTesting(false)
            }
        }
        .opacity(card.include ? 1 : 0.55)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onTapGesture(count: 2) {
            select(card.id)
            if card.isGroup { controller.enter(card.id) } else { controller.openScene(card.id) }
        }
        .onTapGesture {
            let wasSelected = isSelected
            select(card.id)
            if wasSelected, !card.isGroup, !isEditing { controller.beginEditing(card.id) }
        }
        .onDrag {
            WriterBoardDrag.current = (projectID, card.id)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: boardCardType.identifier, visibility: .ownProcess) {
                $0(Data(), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [boardCardType], delegate: BoardDropDelegate(controller: controller, targetID: card.id, width: width,
                                                                 projectID: projectID, indicator: $indicator))
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: L10n.tr("提前")) { controller.selection = card.id; controller.move(card.id, step: -1) }
        .accessibilityAction(named: L10n.tr("延后")) { controller.selection = card.id; controller.move(card.id, step: 1) }
        .accessibilityAction(named: card.isGroup ? L10n.tr("进入分组") : L10n.tr("打开场景")) {
            if card.isGroup { controller.enter(card.id) } else { controller.openScene(card.id) }
        }
        .accessibilityActions {
            if !card.isGroup { Button(L10n.tr("编辑梗概")) { select(card.id); controller.beginEditing(card.id) } }
            if draft != nil {
                Button(L10n.tr("接受")) { controller.accept(card.id) }
                Button(L10n.tr("拒绝")) { controller.reject(card.id) }
            } else if canSuggest {
                Button(L10n.tr("建议梗概")) { controller.suggestSynopsis(for: card.id) }
                if aiAvailable { Button(L10n.tr("用 AI 建议梗概")) { controller.suggestSynopsisWithAI(for: card.id) } }
            }
        }
    }

    /// Кнопки «建议梗概» показываются у сцены без описания, черновика и работы в процессе.
    private var canSuggest: Bool { !card.isGroup && card.synopsis.isEmpty && draft == nil && !isBusy && !isEditing }

    private var accessibilityText: String {
        var text = card.title
        if let status = card.status { text = L10n.tr("%@，状态 %@", text, status) }
        if let words = card.wordCount { text = L10n.tr("%@，%d 字", text, words) }
        if !card.include { text = L10n.tr("%@，不在书稿中", text) }
        if card.isMissingFile { text = L10n.tr("%@，没有文件", text) }
        if !card.synopsis.isEmpty { text += ", " + card.synopsis }
        return text
    }

    // MARK: Части

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: card.isGroup ? "folder" : "doc.text").foregroundStyle(.secondary)
            Text(card.title).font(.headline).lineLimit(2)
            Spacer(minLength: 0)
            if !card.include {
                Text(L10n.tr("不在书稿中")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var groupSummary: some View {
        let scenes = L10n.tr("%d 个场景", card.sceneCount ?? 0)
        let words = card.wordCount.map { " · " + L10n.tr("%@ 词", String($0)) } ?? ""
        return Text(scenes + words).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var synopsisArea: some View {
        if isEditing {
            TextEditor(text: $controller.editingText)
                .font(.callout)
                .frame(minHeight: 70)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { editorFocused = true }
                .onChange(of: editorFocused) { _, focused in
                    if !focused, controller.editingSynopsis == card.id { controller.commitEditing() }
                }
                .onKeyPress(.escape) { controller.cancelEditing(); return .handled }
                .onKeyPress(.return) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    controller.commitEditing()
                    return .handled
                }
                .accessibilityLabel(L10n.tr("梗概"))
        } else if !card.synopsis.isEmpty {
            Text(card.synopsis).font(.callout).foregroundStyle(.secondary).lineLimit(4)
        }
        if !isEditing {
            if let draft { draftRow(draft) }
            else if isBusy { generating }
            else if card.synopsis.isEmpty { suggestButtons }
        }
    }

    private func draftRow(_ draft: WriterBoardController.Draft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                if draft.source == .ai { AIBadge() }
                Text(draft.text).font(.callout.italic()).lineLimit(6)
            }
            HStack {
                Button(L10n.tr("接受")) { controller.accept(card.id) }
                Button(L10n.tr("拒绝")) { controller.reject(card.id) }
            }
            .controlSize(.small)
        }
    }

    private var generating: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(L10n.tr("正在生成…")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var suggestButtons: some View {
        HStack(spacing: 6) {
            Button(L10n.tr("建议梗概")) { controller.suggestSynopsis(for: card.id) }
            if aiAvailable {
                Button { controller.suggestSynopsisWithAI(for: card.id) } label: {
                    HStack(spacing: 2) { Image(systemName: "sparkles"); Text(L10n.tr("用 AI 建议梗概")) }
                }
            }
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let name = card.status, let color = statusColor {
                StatusDot(color: color, title: name)
                Text(name).font(.caption).lineLimit(1)
            }
            if let label = card.label {
                Text(label).font(.caption2).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            }
            Spacer(minLength: 0)
            if card.isMissingFile {
                Label {
                    Text(L10n.tr("没有文件")).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            if !card.isGroup, let words = card.wordCount {
                Text(L10n.tr("%@ 词", String(words))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(card.isGroup ? L10n.tr("进入分组") : L10n.tr("打开场景")) {
            if card.isGroup { controller.enter(card.id) } else { controller.openScene(card.id) }
        }
        if card.isGroup {
            Button(L10n.tr("合并预览")) { controller.openCombinedHandler?(card.id) }
        } else {
            Button(L10n.tr("编辑梗概")) { select(card.id); controller.beginEditing(card.id) }
            if draft != nil {
                Button(L10n.tr("接受")) { controller.accept(card.id) }
                Button(L10n.tr("拒绝")) { controller.reject(card.id) }
            } else if canSuggest {
                Button(L10n.tr("建议梗概")) { controller.suggestSynopsis(for: card.id) }
                if aiAvailable { Button(L10n.tr("用 AI 建议梗概")) { controller.suggestSynopsisWithAI(for: card.id) } }
            }
            Menu(L10n.tr("状态")) {
                Button(L10n.tr("无状态")) { controller.setStatus(nil, for: card.id) }
                Divider()
                ForEach(statuses, id: \.title) { status in
                    Button(status.title) { controller.setStatus(status.title, for: card.id) }
                }
            }
        }
        Button(L10n.tr("设置标记…")) { askLabel(card.id) }
        Divider()
        Button(L10n.tr("提前")) { controller.selection = card.id; controller.move(card.id, step: -1) }
        Button(L10n.tr("延后")) { controller.selection = card.id; controller.move(card.id, step: 1) }
    }
}

// MARK: - Перетаскивание

private struct BoardDropDelegate: DropDelegate {
    let controller: WriterBoardController
    let targetID: UUID
    let width: CGFloat
    let projectID: UUID
    @Binding var indicator: BoardDropIndicator?

    private var draggedID: UUID? {
        WriterBoardDrag.current.flatMap { $0.projectID == projectID && $0.nodeID != targetID ? $0.nodeID : nil }
    }

    private func resolve(_ info: DropInfo) -> (moving: UUID, placeAfter: Bool)? {
        guard let draggedID, controller.cards.contains(where: { $0.id == draggedID }) else { return nil }
        return (draggedID, info.location.x >= width / 2)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil && info.hasItemsConforming(to: [boardCardType])
    }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info), let place = resolve(info) else {
            if indicator?.id == targetID { indicator = nil }
            return DropProposal(operation: .forbidden)
        }
        indicator = BoardDropIndicator(id: targetID, placeAfter: place.placeAfter)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if indicator?.id == targetID { indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = validateDrop(info: info) ? resolve(info) : nil
        indicator = nil
        WriterBoardDrag.current = nil
        guard let place else { return false }
        controller.drop(place.moving, onto: targetID, placeAfter: place.placeAfter)
        return true
    }
}

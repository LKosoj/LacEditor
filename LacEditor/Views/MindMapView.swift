import AppKit
import SwiftUI

/// Цвета карты: линии не менее 3:1, текст не менее 4.5:1 к фону окна в светлой и тёмной теме (проверяет `ContrastTests`).
enum MindMapPalette {
    private static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }

    static let lineColor = dynamic(light: 0.40, dark: 0.66)
    static let textColor = dynamic(light: 0.10, dark: 0.96)
    static let nodeFillColor = dynamic(light: 0.96, dark: 0.20)
    static let nodeStrokeColor = dynamic(light: 0.42, dark: 0.62)

    static let line = Color(nsColor: lineColor)
    static let text = Color(nsColor: textColor)
    static let nodeFill = Color(nsColor: nodeFillColor)
    static let nodeStroke = Color(nsColor: nodeStrokeColor)
}

private func mindMapDash(_ style: MindMapEdgeStyle) -> [CGFloat] {
    switch style {
    case .relation: []
    case .coMention: [6, 4]
    case .wikiLink: [2, 4]
    }
}

private func mindMapStyleTitle(_ style: MindMapEdgeStyle) -> String {
    switch style {
    case .relation: L10n.tr("明确关系")
    case .coMention: L10n.tr("同场景出现")
    case .wikiLink: L10n.tr("笔记链接")
    }
}

/// Шрифт по уровню: уровень выражается размером и насыщенностью, а не только цветом.
private func mindMapFont(level: Int) -> Font {
    switch level {
    case 0: .title3.weight(.semibold)
    case 1: .headline
    case 2: .body
    case 3: .subheadline
    default: .footnote
    }
}

private func mindMapCurve(from a: CGRect, to b: CGRect, curved: Bool) -> Path {
    var path = Path()
    if curved {
        let forward = b.midX >= a.midX
        let start = CGPoint(x: forward ? a.maxX : a.minX, y: a.midY)
        let end = CGPoint(x: forward ? b.minX : b.maxX, y: b.midY)
        let middle = (start.x + end.x) / 2
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
    } else {
        path.move(to: CGPoint(x: a.midX, y: a.midY))
        path.addLine(to: CGPoint(x: b.midX, y: b.midY))
    }
    return path
}

// MARK: Окно

struct MindMapView: View {
    @ObservedObject var controller: MindMapController
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @FocusState private var mapFocused: Bool

    private static let f2 = KeyEquivalent(Character(UnicodeScalar(UInt32(NSF2FunctionKey))!))

    var body: some View {
        VStack(spacing: 0) {
            MindMapToolbar(controller: controller)
            Divider()
            content
            if let preview = controller.mapPreview {
                Divider()
                MindMapAIPreviewView(controller: controller, map: preview)
            }
            if let ideas = controller.ideas {
                Divider()
                MindMapIdeasView(controller: controller, preview: ideas)
            }
            if !controller.aiMessage.isEmpty {
                Divider()
                AIPanelMessageView(kind: controller.aiMessageKind, text: controller.aiMessage, action: controller.aiMessageAction,
                                   openSettings: openAISettings, retry: { controller.retryAI() }, sendAnyway: { controller.sendAnyway() })
                    .padding(8)
            }
            Divider()
            MindMapStatusLine(controller: controller, feedback: controller.feedback)
        }
        .frame(minWidth: 520, minHeight: 360)
        .confirmationDialog(L10n.tr("删除节点"), isPresented: Binding(
            get: { controller.pendingDelete != nil },
            set: { if !$0 { controller.pendingDelete = nil } }
        )) {
            Button(L10n.tr("删除节点"), role: .destructive) {
                if let id = controller.pendingDelete { controller.performDelete(id) }
            }
            Button(L10n.tr("取消"), role: .cancel) { controller.pendingDelete = nil }
        }
        .onChange(of: controller.renamingID) { _, value in
            if value == nil { mapFocused = true }
        }
    }

    @ViewBuilder private var content: some View {
        if let message = controller.unavailableMessage {
            placeholder(message)
        } else if let message = controller.emptyMessage {
            VStack(spacing: 12) {
                placeholder(message)
                hints.padding(.horizontal, 12)
            }
        } else {
            VStack(spacing: 0) {
                if controller.presentation == .list {
                    MindMapListView(controller: controller)
                } else {
                    MindMapCanvasView(controller: controller)
                }
                hints
            }
            .focusable()
            .focused($mapFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { handle($0) }
            .onAppear { mapFocused = true }
            .overlay(alignment: .bottomTrailing) {
                if controller.kind == .links { MindMapLegendView().padding(10) }
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Подсказки об AI: одна на окно (и вторая для карточек мира в виде «Связи»).
    @ViewBuilder private var hints: some View {
        VStack(spacing: 6) {
            if controller.isAIVisible, !controller.canUseAI {
                AIRecommendationHint(
                    feature: .mindMap,
                    message: controller.tree.hasStructure ? L10n.tr("开启 AI 后可以让它为选中的节点想出更多分支。")
                        : L10n.tr("自动导图需要 AI：用它从连续文本生成导图结构。"))
            }
            if controller.kind == .links, appState.aiAvailability(for: .worldCards) != .available {
                AIRecommendationHint(feature: .worldCards, message: L10n.tr("开启 AI 后，可以在设定卡片中提议人物之间的关系。"))
            }
        }
    }

    private func openAISettings() {
        let page: AISettingsPage = appState.aiAvailability(for: .mindMap) == .featureDisabled ? .features : .connections
        SettingsNavigator.shared.open(.ai, aiPage: page)
        SettingsWindowController.shared.present(windowManager: windowManager)
    }

    // MARK: Клавиатура

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard controller.renamingID == nil else { return .ignored }
        let command = press.modifiers.contains(.command)
        let selected = controller.selectedID
        let isList = controller.presentation == .list
        switch press.key {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            if command, press.key == .downArrow, let selected { controller.goToText(selected); return .handled }
            if isList { return .ignored }
            let direction: MindMapController.Direction = press.key == .upArrow ? .up : press.key == .downArrow ? .down : press.key == .leftArrow ? .left : .right
            controller.moveSelection(direction)
            return .handled
        case .tab:
            guard controller.canEditStructure, let selected else { return .ignored }
            controller.addChild(selected)
            return .handled
        case .return:
            guard let selected else { return .ignored }
            if controller.kind == .document { controller.addSibling(selected) } else { controller.goToText(selected) }
            return .handled
        case .escape:
            controller.select(nil)
            return .handled
        case .delete, .deleteForward:
            guard let selected else { return .ignored }
            controller.requestDelete(selected)
            return .handled
        case .space:
            guard let selected else { return .ignored }
            controller.toggleCollapse(selected)
            return .handled
        case Self.f2:
            guard let selected else { return .ignored }
            controller.beginRename(selected)
            return .handled
        default:
            guard let selected, controller.canRename, !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                  let scalar = press.characters.unicodeScalars.first, scalar.value >= 32, !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  scalar.value < 0xF700 || scalar.value > 0xF8FF else { return .ignored }
            controller.beginRename(selected, seed: press.characters)
            return .handled
        }
    }
}

// MARK: Верхняя панель

private struct MindMapToolbar: View {
    @ObservedObject var controller: MindMapController
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if appState.writerSession != nil {
                    Picker(L10n.tr("导图"), selection: Binding(get: { controller.kind }, set: { controller.setKind($0) })) {
                        Text(L10n.tr("导图文档")).tag(MindMapKind.document)
                        Text(L10n.tr("导图项目")).tag(MindMapKind.project)
                        Text(L10n.tr("导图关系")).tag(MindMapKind.links)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if controller.kind != .links {
                    Picker(L10n.tr("树形"), selection: $controller.layoutStyle) {
                        Text(L10n.tr("树形")).tag(MindMapLayoutStyle.tree)
                        Text(L10n.tr("放射")).tag(MindMapLayoutStyle.radial)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(controller.kind == .project || controller.presentation == .list)
                }
                Picker(L10n.tr("图示"), selection: $controller.presentation) {
                    Text(L10n.tr("图示")).tag(MindMapController.Presentation.diagram)
                    Text(L10n.tr("列表")).tag(MindMapController.Presentation.list)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { controller.zoom(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L10n.tr("缩小")).accessibilityLabel(L10n.tr("缩小"))
                Button { controller.zoom(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L10n.tr("放大")).accessibilityLabel(L10n.tr("放大"))
                Button { controller.fitToWindow() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help(L10n.tr("适应窗口")).accessibilityLabel(L10n.tr("适应窗口"))
                Menu {
                    Button(L10n.tr("导出为 PNG…")) { controller.exportPNG() }
                    Button(L10n.tr("导出为 SVG…")) { controller.exportSVG() }
                } label: { Image(systemName: "square.and.arrow.up") }
                    .menuIndicator(.hidden).fixedSize()
                    .help(L10n.tr("导出为 PNG…")).accessibilityLabel(L10n.tr("导出为 PNG…"))
                    .disabled(controller.layout.placed.isEmpty)
                if controller.kind == .document {
                    Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help(L10n.tr("撤销")).accessibilityLabel(L10n.tr("撤销"))
                    Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .help(L10n.tr("重做")).accessibilityLabel(L10n.tr("重做"))
                }
                Spacer(minLength: 0)
                if controller.aiState == .working {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("停止")) { controller.cancelAI() }
                } else if controller.canUseAI {
                    Button(L10n.tr("AI 生成导图")) { controller.generateFromText() }
                    Button(L10n.tr("AI 扩展节点")) {
                        if let id = controller.selectedID { controller.expandNode(id) }
                    }
                    .disabled(controller.selectedID == nil || !controller.tree.hasStructure)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: Нижняя строка

private struct MindMapStatusLine: View {
    @ObservedObject var controller: MindMapController
    @ObservedObject var feedback: InlineFeedbackState

    var body: some View {
        HStack(spacing: 10) {
            if let item = feedback.item {
                MindMapFeedbackItem(feedback: feedback, item: item)
            } else {
                if let text = controller.truncationText { Text(text) }
                if let text = controller.shownCountText {
                    Text(text)
                    if controller.graph.hiddenNodeCount > 0, !controller.showAllCards {
                        Button(L10n.tr("显示全部")) { controller.showAllCards = true }
                    }
                }
                if controller.kind == .links {
                    Stepper(L10n.tr("至少 %lld 个共同场景", controller.minSharedScenes), value: $controller.minSharedScenes, in: 1...9)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            Text("\(Int((controller.zoomLevel * 100).rounded()))%").monospacedDigit()
                .accessibilityHidden(true)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(minHeight: 28)
        .buttonStyle(.link)
    }
}

private struct MindMapFeedbackItem: View {
    let feedback: InlineFeedbackState
    let item: InlineFeedbackState.Item

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol).accessibilityHidden(true)
            Text(item.title).lineLimit(1)
            if item.canUndo { Button(L10n.tr("撤销")) { feedback.undo() } }
        }
        .onHover { feedback.setInteracting($0) }
    }
}

// MARK: Схема

struct MindMapCanvasView: View {
    @ObservedObject var controller: MindMapController
    private static let anchor = "mindmap.selection"

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    let zoom = controller.zoomLevel
                    let size = controller.layout.size
                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            edgesLayer(size: size)
                            ForEach(placedIDs, id: \.self) { id in
                                if let node = controller.node(id), let placed = controller.layout.placed[id] {
                                    MindMapNodeView(controller: controller, node: node, lines: placed.lines)
                                        .frame(width: placed.frame.width, height: placed.frame.height)
                                        .position(x: placed.frame.midX, y: placed.frame.midY)
                                }
                            }
                        }
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .scaleEffect(zoom, anchor: .topLeading)
                        if let id = controller.selectedID, let frame = controller.layout.placed[id]?.frame {
                            Color.clear.frame(width: 1, height: 1)
                                .position(x: frame.midX * zoom, y: frame.midY * zoom)
                                .id(Self.anchor)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
                }
                .onChange(of: controller.selectedID) { _, _ in reader.scrollTo(Self.anchor, anchor: .center) }
                .onChange(of: controller.zoomLevel) { _, _ in reader.scrollTo(Self.anchor, anchor: .center) }
            }
            .onAppear { controller.viewport = proxy.size }
            .onChange(of: proxy.size) { _, value in controller.viewport = value }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("导图"))
    }

    private var placedIDs: [Int] { controller.layout.placed.keys.sorted() }

    private func edgesLayer(size: CGSize) -> some View {
        Canvas { context, _ in
            let selected = controller.selectedID
            let curved = controller.kind != .links
            for edge in controller.edges {
                guard let a = controller.layout.placed[edge.from]?.frame, let b = controller.layout.placed[edge.to]?.frame else { continue }
                let path = mindMapCurve(from: a, to: b, curved: curved)
                let width = 1.5 + CGFloat(min(edge.weight, 5)) * (controller.kind == .links ? 0.25 : 0)
                context.stroke(path, with: .color(MindMapPalette.line),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: mindMapDash(edge.style)))
                if let label = edge.label, !label.isEmpty, selected == edge.from || selected == edge.to {
                    let text = context.resolve(Text(label).font(.caption).foregroundColor(MindMapPalette.text))
                    context.draw(text, at: CGPoint(x: (a.midX + b.midX) / 2, y: (a.midY + b.midY) / 2))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: Узел

struct MindMapNodeView: View {
    @ObservedObject var controller: MindMapController
    let node: MindMapNode
    let lines: [String]
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isSelected: Bool { controller.selectedID == node.id }
    private var isRenaming: Bool { controller.renamingID == node.id }
    private var level: Int { controller.level(of: node.id) }
    private var hasChildren: Bool { controller.kind != .links && !node.childIDs.isEmpty }

    var body: some View {
        HStack(spacing: 4) {
            leading
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(mindMapFont(level: level))
                    .focused($fieldFocused)
                    .onSubmit { controller.rename(node.id, to: draft) }
                    .onExitCommand { controller.renamingID = nil }
                    .onAppear {
                        draft = controller.renameSeed ?? node.title
                        controller.renameSeed = nil
                        fieldFocused = true
                    }
                    .accessibilityLabel(L10n.tr("重命名"))
            } else {
                Text(lines.joined(separator: "\n"))
                    .font(mindMapFont(level: level))
                    .foregroundStyle(MindMapPalette.text)
                    .lineLimit(MindMapLayout.maxLines)
                    .multilineTextAlignment(.leading)
            }
            if hasChildren {
                Image(systemName: controller.isCollapsed(node.id) ? "chevron.right" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, MindMapLayout.paddingX / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(MindMapPalette.nodeFill))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : MindMapPalette.nodeStroke,
                              style: StrokeStyle(lineWidth: isSelected ? 3 : 1, dash: node.isExcludedFromBook ? [4, 3] : []))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .onTapGesture {
            controller.select(node.id)
            if NSEvent.modifierFlags.contains(.command) { controller.goToText(node.id) }
        }
        .modifier(MindMapNodeInteractions(controller: controller, node: node))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(controller.accessibilityValue(for: node.id))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .modifier(MindMapNodeActions(controller: controller, node: node))
    }

    private func open() {
        if controller.canRename, controller.kind == .document, node.kind != .virtualRoot {
            controller.beginRename(node.id)
        } else {
            controller.goToText(node.id)
        }
    }

    private var accessibilityTitle: String {
        var parts = [node.title]
        if let status = node.statusTitle { parts.append(status) }
        if node.isExcludedFromBook { parts.append(L10n.tr("不在书稿中")) }
        if node.isMissingFile { parts.append(L10n.tr("未找到")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var leading: some View {
        if let symbol = node.symbol {
            Image(systemName: symbol).font(.footnote).foregroundStyle(MindMapPalette.text).accessibilityHidden(true)
        } else if let color = node.statusColor, let title = node.statusTitle {
            StatusDot(color: color, title: title)
        }
        if node.isMissingFile {
            Image(systemName: "exclamationmark.triangle").font(.footnote).foregroundStyle(MindMapPalette.text).accessibilityHidden(true)
        }
    }
}

/// Перетаскивание и контекстное меню узла (Схема и Список).
struct MindMapNodeInteractions: ViewModifier {
    @ObservedObject var controller: MindMapController
    let node: MindMapNode
    private static let prefix = "mindmap-node:"

    func body(content: Content) -> some View {
        content
            .contextMenu { MindMapNodeMenu(controller: controller, node: node) }
            .draggable(Self.prefix + String(node.id)) {
                Text(node.title).padding(6)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let text = items.first, text.hasPrefix(Self.prefix), let id = Int(text.dropFirst(Self.prefix.count)) else { return false }
                controller.move(id, onto: node.id)
                return true
            }
    }
}

/// Действия узла для VoiceOver; повторяют контекстное меню.
struct MindMapNodeActions: ViewModifier {
    @ObservedObject var controller: MindMapController
    let node: MindMapNode

    func body(content: Content) -> some View {
        content
            .accessibilityAction { controller.select(node.id) }
            .accessibilityAction(named: L10n.tr("转到文本")) { controller.goToText(node.id) }
            .accessibilityAction(named: controller.isCollapsed(node.id) ? L10n.tr("展开节点") : L10n.tr("折叠")) { controller.toggleCollapse(node.id) }
            .accessibilityAction(named: L10n.tr("添加子节点")) { controller.addChild(node.id) }
            .accessibilityAction(named: L10n.tr("添加同级节点")) { controller.addSibling(node.id) }
            .accessibilityAction(named: L10n.tr("设为上一节点的子节点")) { controller.indent(node.id) }
            .accessibilityAction(named: L10n.tr("提升一级")) { controller.outdent(node.id) }
            .accessibilityAction(named: L10n.tr("删除节点")) { controller.requestDelete(node.id) }
            .accessibilityAction(named: L10n.tr("重命名")) { controller.beginRename(node.id) }
            .accessibilityAction(named: L10n.tr("提前")) { controller.shiftProject(node.id, by: -1) }
            .accessibilityAction(named: L10n.tr("延后")) { controller.shiftProject(node.id, by: 1) }
    }
}

struct MindMapNodeMenu: View {
    @ObservedObject var controller: MindMapController
    let node: MindMapNode

    var body: some View {
        Button(L10n.tr("转到文本")) { controller.goToText(node.id) }
        if controller.kind != .links, !node.childIDs.isEmpty {
            Button(controller.isCollapsed(node.id) ? L10n.tr("展开节点") : L10n.tr("折叠")) { controller.toggleCollapse(node.id) }
        }
        if controller.kind == .document {
            Divider()
            Button(L10n.tr("添加子节点")) { controller.addChild(node.id) }.disabled(!controller.canEditStructure)
            Button(L10n.tr("添加同级节点")) { controller.addSibling(node.id) }
                .disabled(!controller.canEditStructure || node.parentID == nil)
            Button(L10n.tr("设为上一节点的子节点")) { controller.indent(node.id) }.disabled(!controller.canIndent(node.id))
            Button(L10n.tr("提升一级")) { controller.outdent(node.id) }.disabled(!controller.canOutdent(node.id))
            Button(L10n.tr("重命名")) { controller.beginRename(node.id) }
                .disabled(!controller.canRename || node.kind == .virtualRoot)
            Button(L10n.tr("删除节点"), role: .destructive) { controller.requestDelete(node.id) }
                .disabled(!controller.canEditStructure || node.parentID == nil)
            if controller.canUseAI {
                Divider()
                Button(L10n.tr("AI 扩展节点")) { controller.expandNode(node.id) }.disabled(controller.aiState == .working)
            }
        }
        if controller.kind == .project, node.parentID != nil {
            Divider()
            Button(L10n.tr("提前")) { controller.shiftProject(node.id, by: -1) }
            Button(L10n.tr("延后")) { controller.shiftProject(node.id, by: 1) }
        }
    }
}

// MARK: Список

struct MindMapListView: View {
    @ObservedObject var controller: MindMapController

    var body: some View {
        List(selection: Binding(get: { controller.selectedID }, set: { controller.select($0) })) {
            if controller.kind == .links {
                ForEach(controller.visibleIDs, id: \.self) { id in
                    if let node = controller.node(id) {
                        MindMapListRow(controller: controller, node: node, indent: 0)
                            .tag(id)
                        ForEach(Array(controller.neighbors(of: id).enumerated()), id: \.offset) { _, link in
                            HStack {
                                Image(systemName: link.node.symbol ?? "circle").accessibilityHidden(true)
                                Text(link.node.title)
                                Text(link.label ?? mindMapStyleTitle(link.style)).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 20)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else {
                ForEach(controller.visibleIDs, id: \.self) { id in
                    if let node = controller.node(id) {
                        MindMapListRow(controller: controller, node: node, indent: controller.level(of: id))
                            .tag(id)
                    }
                }
            }
        }
        .accessibilityLabel(L10n.tr("导图"))
    }
}

private struct MindMapListRow: View {
    @ObservedObject var controller: MindMapController
    let node: MindMapNode
    let indent: Int
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = node.symbol {
                Image(systemName: symbol).accessibilityHidden(true)
            } else if let color = node.statusColor, let title = node.statusTitle {
                StatusDot(color: color, title: title)
            }
            if controller.renamingID == node.id {
                TextField("", text: $draft)
                    .focused($fieldFocused)
                    .onSubmit { controller.rename(node.id, to: draft) }
                    .onExitCommand { controller.renamingID = nil }
                    .onAppear {
                        draft = controller.renameSeed ?? node.title
                        controller.renameSeed = nil
                        fieldFocused = true
                    }
                    .accessibilityLabel(L10n.tr("重命名"))
            } else {
                Text(node.title).font(mindMapFont(level: min(indent, 4)))
            }
            Spacer(minLength: 0)
            if controller.kind != .links, !node.childIDs.isEmpty {
                Image(systemName: controller.isCollapsed(node.id) ? "chevron.right" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(indent) * 16)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if controller.canRename, controller.kind == .document, node.kind != .virtualRoot { controller.beginRename(node.id) } else { controller.goToText(node.id) }
        }
        .modifier(MindMapNodeInteractions(controller: controller, node: node))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel)
        .accessibilityValue(controller.accessibilityValue(for: node.id))
        .modifier(MindMapNodeActions(controller: controller, node: node))
    }

    private var rowLabel: String {
        var parts = [node.title]
        if let status = node.statusTitle { parts.append(status) }
        if node.isExcludedFromBook { parts.append(L10n.tr("不在书稿中")) }
        if node.isMissingFile { parts.append(L10n.tr("未找到")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: Легенда

struct MindMapLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([MindMapEdgeStyle.relation, .coMention, .wikiLink], id: \.rawValue) { style in
                HStack(spacing: 8) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 5))
                        path.addLine(to: CGPoint(x: 32, y: 5))
                    }
                    .stroke(MindMapPalette.line, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: mindMapDash(style)))
                    .frame(width: 32, height: 10)
                    .accessibilityHidden(true)
                    Text(mindMapStyleTitle(style)).font(.caption)
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Предпросмотр AI

struct MindMapAIPreviewView: View {
    @ObservedObject var controller: MindMapController
    let map: MindMapAIMap

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AIBadge()
                Text(L10n.tr("导图（AI 建议）")).font(.headline).accessibilityAddTraits(.isHeader)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(map.title).font(.headline)
                    ForEach(Array(lines(map.nodes, depth: 1).enumerated()), id: \.offset) { _, line in
                        Text(line.title).padding(.leading, CGFloat(line.depth) * 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            HStack {
                Button(L10n.tr("放入新文档")) { controller.putPreviewInNewDocument() }
                Button(L10n.tr("追加到文档末尾")) { controller.appendPreviewToDocument() }
                    .disabled(!controller.canRename)
                Spacer()
                Button(L10n.tr("放弃")) { controller.discardPreview() }
            }
        }
        .padding(10)
    }

    private func lines(_ nodes: [MindMapAINode], depth: Int) -> [(title: String, depth: Int)] {
        nodes.flatMap { [(title: $0.title, depth: depth)] + lines($0.children, depth: depth + 1) }
    }
}

struct MindMapIdeasView: View {
    @ObservedObject var controller: MindMapController
    let preview: MindMapController.IdeasPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AIBadge()
                Text(L10n.tr("AI 扩展节点")).font(.headline).accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(preview.ideas.enumerated()), id: \.offset) { index, idea in
                Toggle(idea, isOn: Binding(
                    get: { controller.ideas?.selected.contains(index) ?? false },
                    set: { isOn in
                        if isOn { controller.ideas?.selected.insert(index) } else { controller.ideas?.selected.remove(index) }
                    }))
            }
            HStack {
                Button(L10n.tr("添加所选")) { controller.addSelectedIdeas() }
                    .disabled(preview.selected.isEmpty || !controller.canEditStructure)
                Spacer()
                Button(L10n.tr("放弃")) { controller.discardPreview() }
            }
        }
        .padding(10)
    }
}

// MARK: Экспорт PNG

/// Картинка карты для PNG: светлая тема независимо от системной.
struct MindMapExportImage: View {
    let layout: MindMapLayoutResult
    let nodes: [MindMapNode]
    let edges: [(Int, Int, MindMapEdgeStyle)]
    let curved: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Canvas { context, _ in
                for (from, to, style) in edges {
                    guard let a = layout.placed[from]?.frame, let b = layout.placed[to]?.frame else { continue }
                    context.stroke(mindMapCurve(from: a, to: b, curved: curved), with: .color(Color(white: 0.35)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: mindMapDash(style)))
                }
            }
            ForEach(nodes.filter { layout.placed[$0.id] != nil }, id: \.id) { node in
                if let placed = layout.placed[node.id] {
                    Text(placed.lines.joined(separator: "\n"))
                        .font(.body).foregroundColor(Color(white: 0.1))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, MindMapLayout.paddingX / 2)
                        .frame(width: placed.frame.width, height: placed.frame.height, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.96)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.24), lineWidth: 1))
                        .position(x: placed.frame.midX, y: placed.frame.midY)
                }
            }
        }
        .frame(width: max(layout.size.width, 1), height: max(layout.size.height, 1))
        .environment(\.colorScheme, .light)
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Видимая строка дерева рукописи.
struct ManuscriptTreeRow: Identifiable, Equatable {
    let node: ManuscriptNode
    let depth: Int
    let isExpanded: Bool
    let hasChildren: Bool
    let isMissing: Bool
    let words: Int?
    var id: UUID { node.id }
}

/// Плоский список видимых строк и правила переноса. Чистые функции, без обращения к диску.
enum ManuscriptTreeRows {
    static func rows(project: ManuscriptProject, expanded: Set<UUID>, missing: Set<UUID>, counts: [UUID: Int]) -> [ManuscriptTreeRow] {
        var result: [ManuscriptTreeRow] = []
        func walk(_ nodes: [ManuscriptNode], depth: Int) {
            for node in nodes {
                let isOpen = node.kind == .group && expanded.contains(node.id)
                result.append(ManuscriptTreeRow(node: node, depth: depth, isExpanded: isOpen,
                                                hasChildren: node.kind == .group && !node.children.isEmpty,
                                                isMissing: missing.contains(node.id),
                                                words: node.kind == .text ? counts[node.id] : nil))
                if isOpen { walk(node.children, depth: depth + 1) }
            }
        }
        walk(project.nodes, depth: 0)
        return result
    }

    /// Куда уронить узел: у строки сверху или снизу, внутрь группы или в конец списка.
    enum DropTarget: Equatable {
        case before(UUID), after(UUID), into(UUID), end
    }

    /// Родитель и индекс для `ManuscriptProjectStore.moveNode` (индекс — после изъятия узла) либо nil,
    /// если перенос невозможен или ничего не меняет.
    static func destination(project: ManuscriptProject, dragged: UUID, target: DropTarget,
                            expanded: Set<UUID>) -> (parent: UUID?, index: Int)? {
        guard let moving = project.node(id: dragged), let origin = project.location(of: dragged) else { return nil }
        var place: (parent: UUID?, index: Int)
        switch target {
        case let .before(id):
            guard let found = project.location(of: id) else { return nil }
            place = found
        case let .after(id):
            guard let node = project.node(id: id), let found = project.location(of: id) else { return nil }
            place = node.kind == .group && !node.children.isEmpty && expanded.contains(id) ? (id, 0) : (found.parent, found.index + 1)
        case let .into(id):
            guard let node = project.node(id: id), node.kind == .group else { return nil }
            place = (id, node.children.count)
        case .end:
            place = (nil, project.nodes.count)
        }
        let subtree = Set(ManuscriptProject(title: "", nodes: [moving]).allNodes().map(\.id))
        if let parent = place.parent, subtree.contains(parent) { return nil }
        if place.parent == origin.parent, origin.index < place.index { place.index -= 1 }
        if place.parent == origin.parent, place.index == origin.index { return nil }
        return place
    }
}

/// Состояние секции: раскрытые группы (хранятся по проекту), отсутствующие файлы, переименование, подсветка переноса.
@MainActor
final class ManuscriptSectionModel: ObservableObject {
    struct DropIndicator: Equatable {
        enum Placement { case before, after, into }
        var id: UUID?
        var placement: Placement
    }

    @Published var expanded: Set<UUID>
    @Published private(set) var missing: Set<UUID> = []
    @Published var renaming: UUID?
    @Published var renameText = ""
    @Published var indicator: DropIndicator?
    private let projectID: UUID

    init(projectID: UUID) {
        self.projectID = projectID
        let saved = UserDefaults.standard.stringArray(forKey: Self.expandedKey(projectID)) ?? []
        expanded = Set(saved.compactMap(UUID.init(uuidString:)))
    }

    static func expandedKey(_ projectID: UUID) -> String { "LacEditor.ManuscriptExpanded.\(projectID.uuidString)" }
    static func sectionKey(_ projectID: UUID) -> String { "LacEditor.ManuscriptSectionExpanded.\(projectID.uuidString)" }

    func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        UserDefaults.standard.set(expanded.map(\.uuidString), forKey: Self.expandedKey(projectID))
    }

    func expand(_ id: UUID) {
        guard !expanded.contains(id) else { return }
        toggle(id)
    }

    /// Узлы, чьих файлов нет на диске (или путь небезопасен).
    func refreshMissing(store: ManuscriptProjectStore) {
        var result: Set<UUID> = []
        for node in store.project?.allNodes() ?? [] where node.kind == .text {
            if let url = store.fileURL(for: node), FileManager.default.fileExists(atPath: url.path) { continue }
            result.insert(node.id)
        }
        if result != missing { missing = result }
    }
}

private let manuscriptNodeType = UTType(exportedAs: "com.laceditor.manuscript-node")

/// Источник текущего переноса: сам тип данных пуст, как у оглавления.
@MainActor private enum ManuscriptDrag {
    static var current: (projectID: UUID, nodeID: UUID)?
}

struct ManuscriptSectionView: View {
    @ObservedObject var session: WriterSession
    @ObservedObject var appState: AppState
    @StateObject private var model: ManuscriptSectionModel
    @State private var isSectionExpanded: Bool
    @FocusState private var treeFocused: Bool

    init(session: WriterSession, appState: AppState) {
        self.session = session
        self.appState = appState
        _model = StateObject(wrappedValue: ManuscriptSectionModel(projectID: session.projectID))
        let key = ManuscriptSectionModel.sectionKey(session.projectID)
        let saved = UserDefaults.standard.object(forKey: key) as? Bool
        _isSectionExpanded = State(initialValue: saved ?? true)
    }

    private var store: ManuscriptProjectStore { session.projectStore }
    private var counter: ManuscriptWordCounter { session.wordCounter }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if isSectionExpanded { content }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .task { refresh() }
        .onChange(of: store.project) { _, _ in refresh() }
        .onChange(of: appState.selectedDocument?.lastSavedAt) { _, _ in recount() }
        .onChange(of: treeFocused) { _, focused in session.isTreeFocused = focused }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("书稿"))
    }

    private func refresh() {
        model.refreshMissing(store: store)
        recount()
    }

    private func recount() {
        guard store.state == .loaded else { return }
        counter.refresh(store: store, openDocuments: appState.windowManager?.folderSearchSnapshots(root: session.rootURL))
    }

    // MARK: Заголовок

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                isSectionExpanded.toggle()
                UserDefaults.standard.set(isSectionExpanded, forKey: ManuscriptSectionModel.sectionKey(session.projectID))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).frame(width: 12)
                    Text(L10n.tr("书稿")).font(.subheadline.weight(.semibold))
                    Text("\(sceneCount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("书稿"))
            .accessibilityValue(isSectionExpanded ? L10n.tr("已展开") : L10n.tr("已折叠"))
            Menu {
                Button(L10n.tr("新建场景")) { createScene(parent: nil, after: nil) }
                Button(L10n.tr("新建书稿分组")) { appState.createGroup(parent: nil, after: nil) }
                Button(L10n.tr("添加文件…")) { appState.addExistingFiles(parent: nil) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.state != .loaded)
            .accessibilityLabel(L10n.tr("添加到书稿"))
            .accessibilityIdentifier("manuscript.add")
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
    }

    private var sceneCount: Int { store.project?.allNodes().filter { $0.kind == .text }.count ?? 0 }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        switch store.state {
        case .loaded:
            if let project = store.project {
                if project.nodes.isEmpty { emptyState } else { tree(project) }
            }
        case .readOnlyNewerVersion:
            stateMessage(ManuscriptProjectError.readOnly.localizedDescription, action: nil)
        case .unreadable:
            stateMessage(L10n.tr("项目文件已损坏，无法读取。"), action: (L10n.tr("重新创建…"), { appState.presentManuscriptProjectWizard(root: session.rootURL) }))
        case .missing:
            stateMessage(L10n.tr("项目文件 .laceditor/project.json 不存在。"), action: (L10n.tr("重新创建…"), { appState.presentManuscriptProjectWizard(root: session.rootURL) }))
        }
    }

    private func stateMessage(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.tr("书稿中还没有场景"), systemImage: "doc.text")
        } actions: {
            Button(L10n.tr("新建场景")) { createScene(parent: nil, after: nil) }
            Button(L10n.tr("添加文件…")) { appState.addExistingFiles(parent: nil) }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func createScene(parent: UUID?, after: UUID?) {
        if let id = appState.createScene(parent: parent, after: after) {
            if let parent { model.expand(parent) }
            session.selectedNodeID = id
        }
    }

    private func tree(_ project: ManuscriptProject) -> some View {
        let rows = ManuscriptTreeRows.rows(project: project, expanded: model.expanded, missing: model.missing, counts: counter.counts)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row, project: project)
                }
                Color.clear
                    .frame(height: 16)
                    .overlay(alignment: .top) {
                        if model.indicator == ManuscriptSectionModel.DropIndicator(id: nil, placement: .before) {
                            Capsule().fill(LacEditorDesign.accent).frame(height: 2)
                        }
                    }
                    .onDrop(of: [manuscriptNodeType], delegate: ManuscriptDropDelegate(
                        rowID: nil, height: 16, projectID: session.projectID, model: model,
                        resolve: { _ in .end }, perform: { drop(project, $0, $1) }))
            }
        }
        .frame(maxHeight: 280)
        .focusable()
        .focused($treeFocused)
        .focusEffectDisabled()
        .editorFocusRing(treeFocused, radius: 6)
        .onKeyPress(phases: .down) { press in handleKey(press, project: project, rows: rows) }
        .accessibilityIdentifier("manuscript.tree")
    }

    private func drop(_ project: ManuscriptProject, _ dragged: UUID, _ target: ManuscriptTreeRows.DropTarget) {
        guard let place = ManuscriptTreeRows.destination(project: project, dragged: dragged, target: target, expanded: model.expanded) else { return }
        if let parent = place.parent { model.expand(parent) }
        appState.moveManuscriptNode(dragged, toParent: place.parent, index: place.index)
    }

    // MARK: Строка

    private func statusInfo(_ node: ManuscriptNode, project: ManuscriptProject) -> (title: String, color: StatusColor)? {
        guard node.kind == .text, let name = node.status, !name.isEmpty else { return nil }
        if let found = project.statuses.first(where: { $0.title == name }) { return (found.title, found.color) }
        return (name, .gray)
    }

    private func accessibilityText(_ row: ManuscriptTreeRow, status: String?) -> String {
        var text = row.node.title
        if let status { text = L10n.tr("%@，状态 %@", text, status) }
        if let words = row.words { text = L10n.tr("%@，%d 字", text, words) }
        if !row.node.include { text = L10n.tr("%@，不在书稿中", text) }
        if row.isMissing { text = L10n.tr("%@，没有文件", text) }
        return text
    }

    private func rowView(_ row: ManuscriptTreeRow, project: ManuscriptProject) -> some View {
        let node = row.node
        let status = statusInfo(node, project: project)
        let isSelected = session.selectedNodeID == node.id
        let symbol = node.kind == .group ? "folder" : row.isMissing ? "exclamationmark.triangle" : !node.include ? "eye.slash" : "doc.text"
        return HStack(spacing: 4) {
            if row.hasChildren {
                Button { model.toggle(node.id) } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? L10n.tr("折叠") : L10n.tr("展开"))
            } else {
                Spacer().frame(width: 12)
            }
            if let status { StatusDot(color: status.color, title: status.title) } else { Spacer().frame(width: 8) }
            Image(systemName: symbol)
                .foregroundStyle(row.isMissing ? Color.orange : Color.secondary)
                .frame(width: 16)
            if model.renaming == node.id {
                TextField("", text: $model.renameText)
                    .textFieldStyle(.plain)
                    .onSubmit { commitRename(node.id) }
                    .onExitCommand { model.renaming = nil }
            } else {
                Text(node.title)
                    .italic(!node.include)
                    .foregroundStyle(node.include && !row.isMissing ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if row.isMissing {
                Text(L10n.tr("没有文件")).font(.caption2).foregroundStyle(.secondary)
            } else if let words = row.words {
                Text("\(words)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 4)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(isSelected ? LacEditorDesign.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay { dropOverlay(for: node.id) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(node) }
        .onTapGesture { session.selectedNodeID = node.id }
        .onDrag {
            ManuscriptDrag.current = (session.projectID, node.id)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: manuscriptNodeType.identifier, visibility: .ownProcess) {
                $0(Data(), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [manuscriptNodeType], delegate: ManuscriptDropDelegate(
            rowID: node.id, height: 24, projectID: session.projectID, model: model,
            resolve: { fraction in
                if node.kind == .group && fraction > 0.3 && fraction < 0.7 { return .into(node.id) }
                return fraction < 0.5 ? .before(node.id) : .after(node.id)
            },
            perform: { drop(project, $0, $1) }))
        .contextMenu { contextMenu(for: row) }
        // Во время переименования поле ввода остаётся доступным для VoiceOver.
        .accessibilityElement(children: model.renaming == node.id ? .contain : .ignore)
        .accessibilityLabel(accessibilityText(row, status: status?.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: L10n.tr("打开")) { open(node) }
        .accessibilityAction(named: L10n.tr("上移")) { appState.moveManuscriptNodeUp(node.id) }
        .accessibilityAction(named: L10n.tr("下移")) { appState.moveManuscriptNodeDown(node.id) }
        .accessibilityAction(named: L10n.tr("从项目中移除")) { appState.removeNodeFromProject(node.id) }
        .accessibilityAction(named: L10n.tr("重命名")) { beginRename(node) }
        .accessibilityAction(named: L10n.tr("移入上方分组")) { appState.nestManuscriptNode(node.id) }
        .accessibilityAction(named: L10n.tr("移出到上一级")) { appState.outdentManuscriptNode(node.id) }
        .accessibilityAction(named: L10n.tr("新建场景")) { createScene(parent: parentForNew(row).parent, after: parentForNew(row).after) }
    }

    @ViewBuilder private func dropOverlay(for id: UUID) -> some View {
        if model.indicator?.id == id, let placement = model.indicator?.placement {
            switch placement {
            case .into:
                RoundedRectangle(cornerRadius: 5).strokeBorder(LacEditorDesign.accent, lineWidth: 2).allowsHitTesting(false)
            case .before, .after:
                VStack(spacing: 0) {
                    if placement == .after { Spacer(minLength: 0) }
                    Capsule().fill(LacEditorDesign.accent).frame(height: 2)
                    if placement == .before { Spacer(minLength: 0) }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func open(_ node: ManuscriptNode) {
        session.selectedNodeID = node.id
        if node.kind == .group { model.toggle(node.id) } else { appState.openManuscriptNode(node.id) }
    }

    private func beginRename(_ node: ManuscriptNode) {
        model.renameText = node.title
        model.renaming = node.id
    }

    private func commitRename(_ id: UUID) {
        appState.renameManuscriptNode(id, to: model.renameText)
        model.renaming = nil
    }

    // MARK: Меню и клавиши

    @ViewBuilder private func contextMenu(for row: ManuscriptTreeRow) -> some View {
        let node = row.node
        if node.kind == .text, !row.isMissing { Button(L10n.tr("打开")) { appState.openManuscriptNode(node.id) } }
        if row.isMissing { Button(L10n.tr("指定文件…")) { appState.locateMissingFile(for: node.id) } }
        Button(L10n.tr("重命名")) { beginRename(node) }
        Toggle(L10n.tr("纳入书稿"), isOn: Binding(get: { node.include }, set: { _ in appState.toggleManuscriptInclude(node.id) }))
        Divider()
        Button(L10n.tr("上移")) { appState.moveManuscriptNodeUp(node.id) }
        Button(L10n.tr("下移")) { appState.moveManuscriptNodeDown(node.id) }
        Button(L10n.tr("移入上方分组")) { appState.nestManuscriptNode(node.id) }
        Button(L10n.tr("移出到上一级")) { appState.outdentManuscriptNode(node.id) }
        Divider()
        Button(L10n.tr("新建场景")) { createScene(parent: parentForNew(row).parent, after: parentForNew(row).after) }
        Button(L10n.tr("新建书稿分组")) { appState.createGroup(parent: parentForNew(row).parent, after: parentForNew(row).after) }
        Button(L10n.tr("添加文件…")) { appState.addExistingFiles(parent: parentForNew(row).parent) }
        Divider()
        if node.kind == .text, !row.isMissing { Button(L10n.tr("在 Finder 中显示")) { appState.revealManuscriptNode(node.id) } }
        Button(L10n.tr("从项目中移除"), role: .destructive) { appState.removeNodeFromProject(node.id) }
    }

    /// Новый узел появляется внутри выбранной группы, а рядом с обычной сценой — после неё.
    private func parentForNew(_ row: ManuscriptTreeRow) -> (parent: UUID?, after: UUID?) {
        if row.node.kind == .group { return (row.node.id, nil) }
        return (store.project?.location(of: row.node.id)?.parent, row.node.id)
    }

    private func handleKey(_ press: KeyPress, project: ManuscriptProject, rows: [ManuscriptTreeRow]) -> KeyPress.Result {
        guard model.renaming == nil else { return .ignored }
        let selected = session.selectedNodeID
        let index = rows.firstIndex { $0.id == selected }
        let flags = press.modifiers
        switch press.key {
        case .upArrow, .downArrow:
            let delta = press.key == .upArrow ? -1 : 1
            guard let selected else {
                session.selectedNodeID = rows.first?.id
                return .handled
            }
            if flags.contains(.option) && flags.contains(.command) {
                if delta < 0 { appState.moveManuscriptNodeUp(selected) } else { appState.moveManuscriptNodeDown(selected) }
                return .handled
            }
            if flags.contains(.command), delta > 0, let row = rows.first(where: { $0.id == selected }) {
                open(row.node)
                return .handled
            }
            if let index, rows.indices.contains(index + delta) { session.selectedNodeID = rows[index + delta].id }
            return .handled
        case .return:
            guard let row = rows.first(where: { $0.id == selected }) else { return .ignored }
            beginRename(row.node)
            return .handled
        case .delete, .deleteForward:
            guard let selected else { return .ignored }
            appState.removeNodeFromProject(selected)
            return .handled
        case .leftArrow, .rightArrow:
            guard let row = rows.first(where: { $0.id == selected }), row.node.kind == .group else { return .ignored }
            if press.key == .rightArrow { model.expand(row.id) } else if row.isExpanded { model.toggle(row.id) }
            return .handled
        default:
            if press.characters.lowercased() == "e", flags.contains(.command), flags.contains(.shift), let selected {
                appState.toggleManuscriptInclude(selected)
                return .handled
            }
            return .ignored
        }
    }
}

/// Приём узла на строку (`rowID == nil` — зона «в конец списка»).
private struct ManuscriptDropDelegate: DropDelegate {
    let rowID: UUID?
    let height: CGFloat
    let projectID: UUID
    let model: ManuscriptSectionModel
    /// По доле высоты строки (0 — верх) определяет место.
    let resolve: (CGFloat) -> ManuscriptTreeRows.DropTarget
    let perform: (UUID, ManuscriptTreeRows.DropTarget) -> Void

    private var draggedID: UUID? {
        ManuscriptDrag.current.flatMap { $0.projectID == projectID ? $0.nodeID : nil }
    }

    private func indicator(for target: ManuscriptTreeRows.DropTarget) -> ManuscriptSectionModel.DropIndicator {
        switch target {
        case let .before(id): .init(id: id, placement: .before)
        case let .after(id): .init(id: id, placement: .after)
        case let .into(id): .init(id: id, placement: .into)
        case .end: .init(id: nil, placement: .before)
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil && info.hasItemsConforming(to: [manuscriptNodeType])
    }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        model.indicator = indicator(for: resolve(max(0, min(1, info.location.y / max(height, 1)))))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.indicator?.id == rowID { model.indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let dragged = draggedID
        let target = resolve(max(0, min(1, info.location.y / max(height, 1))))
        model.indicator = nil
        ManuscriptDrag.current = nil
        guard let dragged else { return false }
        perform(dragged, target)
        return true
    }
}

/// «Сцена N · Книга M» в строке состояния писательской вкладки. Пусто, пока числа не посчитаны или файл не в проекте.
struct WriterWordCountStatus: View {
    @ObservedObject var session: WriterSession
    @ObservedObject var counter: ManuscriptWordCounter
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            if let url = appState.selectedDocument?.url, let node = session.projectStore.node(forFileURL: url),
               let words = counter.counts[node.id] {
                let text = L10n.tr("场景 %d 字 · 全书 %d 字", words, counter.bookTotal)
                Text(text)
                    .lineLimit(1)
                    .help(text)
                    .accessibilityIdentifier("status.manuscriptWords")
            }
        }
        // Боковая панель может быть скрыта: тогда первый подсчёт запускает строка состояния.
        .task {
            guard counter.counts.isEmpty, !counter.isCounting, session.projectStore.state == .loaded else { return }
            counter.refresh(store: session.projectStore,
                            openDocuments: appState.windowManager?.folderSearchSnapshots(root: session.rootURL))
        }
    }
}

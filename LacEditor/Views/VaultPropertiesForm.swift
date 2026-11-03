import SwiftUI

/// Форма свойств заметки (шапка YAML). Return или уход фокуса подтверждает, Esc откатывает; одна правка — один шаг ⌘Z.
struct VaultPropertiesForm: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: VaultInspectorModel
    let documentID: UUID
    /// Собранная сервером страница: поля только показываются.
    let isReadOnly: Bool
    /// Документ сейчас нельзя править (режим чтения, большой файл, занят): поля неактивны.
    let isLocked: Bool
    @State private var message: String?
    /// Свойства, добавленные из меню: поле есть в форме, а в тексте появится при подтверждении непустого значения.
    @State private var pending: [String] = []

    private static let typeKeys = ["type", "status", "description", "created", "updated", "date"]
    private static let dateKeys: Set<String> = ["created", "updated", "date"]
    private static let addableKeys = ["type", "status", "tags", "description"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("笔记属性")).font(.headline).accessibilityAddTraits(.isHeader)
            if !model.isParsed {
                Text(L10n.tr("正在加载")).foregroundStyle(.secondary)
            } else {
                content
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .accessibilityLabel(message)
            }
            if isLocked && !isReadOnly {
                Text(L10n.tr("文档暂时不可编辑")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(isLocked && !isReadOnly)
        .onChange(of: documentID) { _, _ in message = nil; pending = [] }
        .onChange(of: model.frontmatter) { _, _ in pruneAfterReload() }
    }

    private var existingKeys: Set<String> {
        if case let .parsed(front) = model.frontmatter { return Set(front.fields.map(\.key)) }
        return []
    }

    @ViewBuilder
    private var content: some View {
        switch model.frontmatter {
        case .none:
            Text(L10n.tr("此笔记没有属性")).foregroundStyle(.secondary)
            pendingRows
            addMenu
        case let .failed(line, _):
            Label(L10n.tr("无法读取属性：第 %lld 行", line), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Button(L10n.tr("在文本中显示")) { appState.revealVaultLine(line, documentID: documentID) }
        case let .parsed(frontmatter):
            fields(frontmatter)
            pendingRows
            addMenu
        }
    }

    @ViewBuilder
    private var pendingRows: some View {
        ForEach(pending, id: \.self) { key in
            if key == "tags" {
                VaultTagsRow(items: [], isReadOnly: false,
                             add: { apply(.addListItem(key: "tags", item: $0)) },
                             remove: { _ in true })
            } else {
                VaultScalarRow(key: key, value: "") { text in
                    text.isEmpty ? true : apply(.setScalar(key: key, value: text))
                }
            }
        }
    }

    /// Меню «Добавить свойство»: только то, чего в шапке ещё нет.
    @ViewBuilder
    private var addMenu: some View {
        let candidates = Self.addableKeys.filter { !existingKeys.contains($0) && !pending.contains($0) }
        if !isReadOnly {
            Menu(L10n.tr("添加属性")) {
                ForEach(candidates, id: \.self) { key in Button(key) { pending.append(key) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(candidates.isEmpty)
        }
    }

    @ViewBuilder
    private func fields(_ frontmatter: VaultFrontmatter) -> some View {
        let user = frontmatter.fields.filter { !$0.isSystem }
        let system = frontmatter.fields.filter(\.isSystem)
        let main = user.filter { Self.typeKeys.contains($0.key) || $0.key == "tags" }
        let other = user.filter { !Self.typeKeys.contains($0.key) && $0.key != "tags" }
        ForEach(main) { field in row(field) }
        if main.isEmpty && pending.isEmpty { Text(L10n.tr("此笔记没有属性")).foregroundStyle(.secondary) }
        if !other.isEmpty {
            DisclosureGroup(L10n.tr("其他属性（%lld）", other.count)) {
                VStack(alignment: .leading, spacing: 8) { ForEach(other) { field in row(field) } }.padding(.top, 6)
            }
        }
        if !system.isEmpty {
            DisclosureGroup(L10n.tr("系统字段（%lld）", system.count)) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(system) { field in readOnlyRow(field, text: Self.text(of: field.value)) }
                }.padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func row(_ field: VaultFrontmatterField) -> some View {
        switch field.value {
        case let .scalar(value):
            if isReadOnly {
                readOnlyRow(field, text: value)
            } else if Self.dateKeys.contains(field.key), VaultFrontmatterEditor.dateComponents(from: value) != nil {
                VaultDateRow(key: field.key, value: value) { apply(.setScalar(key: field.key, value: $0)) }
            } else {
                VaultScalarRow(key: field.key, value: value) { apply(.setScalar(key: field.key, value: $0)) }
            }
        case let .list(items):
            if field.key == "tags" {
                VaultTagsRow(items: items, isReadOnly: isReadOnly,
                             add: { apply(.addListItem(key: "tags", item: $0)) },
                             remove: { apply(.removeListItem(key: "tags", item: $0)) })
            } else {
                readOnlyRow(field, text: items.joined(separator: ", "))
            }
        case let .readOnly(text):
            readOnlyRow(field, text: text)
        }
    }

    private func readOnlyRow(_ field: VaultFrontmatterField, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.key).font(.caption).foregroundStyle(.secondary)
            Text(text).lineLimit(3).textSelection(.enabled)
            if !field.isSystem && !isReadOnly {
                Button(L10n.tr("在文本中显示")) { appState.revealVaultLine(field.line, documentID: documentID) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// true — правка применена (или не нужна); false — отклонена, поле вернётся к значению из файла.
    private func apply(_ edit: VaultFrontmatterEdit) -> Bool {
        let result = appState.applyVaultFrontmatterEdit(edit, documentID: documentID)
        message = result
        if let result { AccessibilityNotification.Announcement(result).post() }
        model.reloadFrontmatter()
        return result == nil
    }

    /// Свойство, которое появилось в тексте, больше не «ожидающее».
    private func pruneAfterReload() {
        let keys = existingKeys
        pending.removeAll { keys.contains($0) }
    }

    private static func text(of value: VaultFrontmatterField.Value) -> String {
        switch value {
        case let .scalar(text), let .readOnly(text): text
        case let .list(items): items.joined(separator: ", ")
        }
    }
}

/// Однострочное значение: Return или уход фокуса подтверждает, Esc возвращает прежнее.
private struct VaultScalarRow: View {
    let key: String
    let value: String
    let commit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            TextField(key, text: $draft)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($focused)
                .onSubmit { finish() }
                .onExitCommand { draft = value; focused = false }
                .onChange(of: focused) { _, now in if !now { finish() } }
                .accessibilityLabel(key)
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, new in if !focused { draft = new } }
    }

    private func finish() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != value else { return }
        // Отказ: в поле возвращается значение из файла.
        if !commit(trimmed) { draft = value }
    }
}

/// Дата `ГГГГ-ММ-ДД`: системный выбор даты; значение пишется в том же виде.
private struct VaultDateRow: View {
    let key: String
    let value: String
    let commit: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            HStack {
                DatePicker(key, selection: binding, displayedComponents: .date).labelsHidden()
                Spacer()
                Button(L10n.tr("删除"), systemImage: "xmark.circle") { _ = commit("") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help(L10n.tr("删除") + " " + key).accessibilityLabel(L10n.tr("删除") + " " + key)
            }
        }
    }

    private var binding: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar(identifier: .gregorian)
                return VaultFrontmatterEditor.dateComponents(from: value).flatMap { calendar.date(from: $0) } ?? Date()
            },
            set: { date in
                let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
                let text = VaultFrontmatterEditor.dateString(from: parts)
                if text != value { _ = commit(text) }
            }
        )
    }
}

/// Теги чипами: удаление крестиком, добавление полем.
private struct VaultTagsRow: View {
    let items: [String]
    let isReadOnly: Bool
    let add: (String) -> Bool
    let remove: (String) -> Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("标签")).font(.caption).foregroundStyle(.secondary)
            VaultChipLayout(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, tag in
                    HStack(spacing: 2) {
                        Text("#" + tag)
                        if !isReadOnly {
                            Button { _ = remove(tag) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).font(.caption2)
                                .accessibilityLabel(L10n.tr("删除") + " " + tag)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
            }
            if !isReadOnly {
                TextField(L10n.tr("添加标签"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let value = draft.trimmingCharacters(in: .whitespaces)
                        // Тег, не прошедший проверку, остаётся в поле: его можно поправить.
                        if !value.isEmpty, add(value) { draft = "" }
                    }
                    .onExitCommand { draft = "" }
            }
        }
    }
}

/// Раскладка «в строку с переносом» для чипов.
private struct VaultChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 240, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}

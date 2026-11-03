import AppKit
import SwiftUI

/// Поле поиска боковой панели хранилища и переключатель «На сервере / Имена».
struct VaultSearchField: View {
    @ObservedObject var controller: VaultSearchController
    @ObservedObject var navigation: FolderListNavigation
    /// Esc в пустом поле: фокус уходит в редактор.
    let focusEditor: () -> Void
    @FocusState private var focused: Bool

    private var prompt: String {
        controller.mode == .server ? L10n.tr("在服务器上搜索笔记") : L10n.tr("按名称查找笔记")
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: controller.mode == .server ? "brain" : "magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(prompt, text: $controller.query)
                    .textFieldStyle(.plain).font(.callout)
                    .focused($focused)
                    .onSubmit { controller.submit() }
                    .onKeyPress(.downArrow) {
                        guard !controller.results.isEmpty else { return .ignored }
                        navigation.move(from: nil, offset: 1)
                        return .handled
                    }
                    .onExitCommand { escape() }
                    .accessibilityLabel(L10n.tr("搜索笔记库"))
                    .accessibilityValue(controller.query)
                    .accessibilityHint(prompt)
                if !controller.query.isEmpty {
                    Button { controller.clear(); focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(L10n.tr("清除"))
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
            .editorFocusRing(focused, radius: 7)
            Picker(L10n.tr("搜索方式"), selection: $controller.mode) {
                Text(L10n.tr("服务器搜索")).tag(VaultSearchMode.server)
                Text(L10n.tr("名称搜索")).tag(VaultSearchMode.names)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .accessibilityLabel(L10n.tr("搜索方式"))
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .onChange(of: controller.focusRequest) { _, _ in takeFocusIfRequested() }
        .onAppear { takeFocusIfRequested() }
    }

    private func takeFocusIfRequested() {
        guard controller.consumeFocusRequest() else { return }
        let selects = controller.selectsTextOnFocus
        DispatchQueue.main.async {
            focused = true
            // Текст выделяется в редакторе поля (field editor), когда фокус уже в нём.
            if selects, !controller.query.isEmpty {
                DispatchQueue.main.async { _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        }
    }

    /// Есть текст — поле очищается и панель возвращается к разделам; пусто — фокус в редактор.
    private func escape() {
        if controller.query.isEmpty { focusEditor() } else { controller.clear() }
    }
}

/// Строка состояния под переключателем: ожидание, число результатов, пустой результат, ошибка и действия.
struct VaultSearchStateView: View {
    @ObservedObject var controller: VaultSearchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.mode == .names, controller.namesListIsPartial {
                note(L10n.tr("正在加载笔记列表…"))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .waiting:
            if !controller.results.isEmpty { count }
        case .loading:
            HStack(spacing: 6) {
                // При «Уменьшить движение» вращающегося индикатора нет: состояние несёт текст.
                if !reduceMotion { ProgressView().controlSize(.small) }
                Text(L10n.tr("正在服务器上搜索…")).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .results:
            count
        case .empty:
            Text(L10n.tr("没有匹配结果")).font(.callout).foregroundStyle(.secondary)
            if controller.mode == .server { namesButton }
        case .unavailable:
            Text(L10n.tr("服务器搜索不可用")).font(.callout)
            HStack(spacing: 12) { retryButton; namesButton }
        case .offline:
            Text(L10n.tr("与服务器没有连接")).font(.callout)
            note(L10n.tr("“名称”搜索无需联网"))
            HStack(spacing: 12) { retryButton; namesButton }
        case .failed(let message):
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            retryButton
        }
    }

    private var count: some View {
        Text(L10n.tr("结果：%lld", controller.results.count)).font(.caption).foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
        Button(L10n.tr("重试")) { controller.retry() }.buttonStyle(.link).font(.caption)
    }

    private var namesButton: some View {
        Button(L10n.tr("改用名称搜索")) { controller.switchToNames() }.buttonStyle(.link).font(.caption)
    }
}

/// Подпись под списком: сервер показал максимум или список имён усечён.
struct VaultSearchFooter: View {
    @ObservedObject var controller: VaultSearchController

    var body: some View {
        if controller.isLimited, controller.phase == .results {
            Text(controller.mode == .server
                 ? L10n.tr("服务器最多显示 20 条结果")
                 : L10n.tr("仅显示前 %lld 条，请缩小搜索范围", VaultSearchSupport.namesLimit))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Строка результата. Return открывает в этой вкладке, ⌘Return и ⌘-щелчок — в новой.
struct VaultSearchRowView: View {
    @ObservedObject var controller: VaultSearchController
    let result: VaultSearchResult
    let query: String
    @ObservedObject var navigation: FolderListNavigation

    static func rowID(_ result: VaultSearchResult) -> AnyHashable { AnyHashable("vault-search|" + result.path) }

    /// Клавиша ⌘ в момент нажатия или щелчка.
    private static var wantsNewTab: Bool { NSApp.currentEvent?.modifierFlags.contains(.command) == true }

    var body: some View {
        let id = Self.rowID(result)
        Button {
            navigation.focused = id
            controller.select(result, newTab: Self.wantsNewTab)
        } label: {
            content
        }
        .modifier(FolderListRowNavigation(id: id, navigation: navigation) {
            controller.select(result, newTab: Self.wantsNewTab)
            return .handled
        })
        .onKeyPress(.escape) { controller.requestFocus(selectingText: false); return .handled }
        .contextMenu {
            Button(L10n.tr("打开")) { controller.select(result, newTab: false) }
            Button(L10n.tr("在新标签页中打开")) { controller.select(result, newTab: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
        .accessibilityHint(L10n.tr("Return 打开，⌘Return 在新标签页打开"))
        .accessibilityAddTraits(navigation.focused == id ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if controller.mode == .names {
                Text(namesLine).lineLimit(2).truncationMode(.middle)
            } else {
                Text(result.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                Text(result.displayTrail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let snippet = result.snippet {
                    Text(SearchHighlight.attributed((snippet, VaultSearchSupport.highlightRanges(in: snippet, query: query))))
                        .font(.caption).lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «папка › имя»: имя плотнее, найденное жирным и на фоне (не только цветом).
    private var namesLine: AttributedString {
        var line = AttributedString(result.folderTrail.isEmpty ? "" : result.folderTrail + VaultSearchSupport.trailSeparator)
        line.swiftUI.foregroundColor = .secondary
        var name = SearchHighlight.attributed((result.name, VaultSearchSupport.highlightRanges(in: result.name, query: query)))
        name.font = .body.weight(.medium)
        line += name
        return line
    }

    /// Строка читается целиком: заголовок, путь через запятую, отрывок без подсветки.
    private var spokenText: String {
        let trail = result.displayTrail.replacingOccurrences(of: VaultSearchSupport.trailSeparator, with: ", ")
        if controller.mode == .names { return trail }
        return [result.title, trail, result.snippet].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Фокус в редактор: тот же приём, что у быстрого открытия и палитры команд.
enum VaultSearchFocus {
    @MainActor
    static func focusEditor(in window: NSWindow?) {
        guard let window, let editor = editorView(in: window.contentView) else { return }
        window.makeFirstResponder(editor)
    }

    private static func editorView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is LacTextView { return view }
        for child in view.subviews { if let found = editorView(in: child) { return found } }
        return nil
    }
}

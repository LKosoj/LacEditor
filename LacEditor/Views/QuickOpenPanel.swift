import AppKit
import SwiftUI

/// Плавающая панель быстрого открытия (⌘⇧O) поверх области редактора.
/// Состояние живёт в `FolderSearchController`: панель открыта, пока есть `quickOpenRequest`.
struct QuickOpenOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: FolderSearchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousResponder: NSResponder?

    var body: some View {
        ZStack(alignment: .top) {
            if controller.quickOpenRequest != nil {
                Color.black.opacity(0.001).onTapGesture { dismiss() }
                QuickOpenPanel(controller: controller, dismiss: dismiss)
                    .padding(.top, 56)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? nil : LacEditorDesign.chromeAnimation, value: controller.quickOpenRequest)
        .onChange(of: controller.quickOpenRequest) { old, new in
            if old == nil, new != nil { previousResponder = capturableResponder() }
            else if old != nil, new == nil { restoreFocus() }
        }
    }

    /// Esc / клик вне: закрытие идёт через контроллер, фокус возвращает `onChange` выше —
    /// так же, как после Enter и открытия результата.
    private func dismiss() { controller.cancelQuickOpen() }

    /// Прежний ответчик; поле ввода самой панели (field editor) не запоминаем.
    private func capturableResponder() -> NSResponder? {
        let responder = appState.hostWindow?.firstResponder
        if let text = responder as? NSTextView, text.isFieldEditor { return nil }
        return responder
    }

    /// Возвращает фокус прежнему элементу, а если его нет — редактору; запоминание очищается.
    private func restoreFocus() {
        let previous = previousResponder as? NSView
        previousResponder = nil
        DispatchQueue.main.async {
            guard let window = appState.hostWindow, !appState.commandPalette.isPresented else { return }
            if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
            // фокус уже у другого элемента (не у исчезнувшего поля панели) — не отбираем
            if let current = window.firstResponder, !(current is NSWindow),
               !((current as? NSTextView)?.isFieldEditor ?? false) { return }
            if let previous, previous.window === window { window.makeFirstResponder(previous) }
            else if let editor = Self.editorView(in: window.contentView) { window.makeFirstResponder(editor) }
        }
    }

    private static func editorView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is LacTextView { return view }
        for child in view.subviews { if let found = editorView(in: child) { return found } }
        return nil
    }
}

struct QuickOpenPanel: View {
    @ObservedObject var controller: FolderSearchController
    let dismiss: () -> Void
    @State private var selectedIndex = 0
    @State private var keyboardMovedAt = Date.distantPast
    @State private var hoverSelectedIndex: Int?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.tr("快速打开"), text: $controller.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($queryFocused)
                    .accessibilityLabel(L10n.tr("快速打开"))
                    .onSubmit { openSelected() }
                    .onExitCommand { dismiss() }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: move(-1)
                        case .down: move(1)
                        default: break
                        }
                    }
                if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在查找…")) }
            }
            .padding(.horizontal, 12).frame(height: 40)
            if !controller.quickOpenItems.isEmpty {
                Divider()
                results
            } else if controller.hasSearched {
                Divider()
                Text(L10n.tr("没有匹配结果")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(width: 520)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("快速打开"))
        .onExitCommand { dismiss() }
        .onAppear { queryFocused = true; selectedIndex = 0 }
        .onChange(of: controller.quickOpenItems) { _, _ in
            keyboardMovedAt = Date()
            selectedIndex = 0
        }
        .onChange(of: controller.query) { _, _ in keyboardMovedAt = Date() }
        .task(id: controller.quickOpenRequest.map { [$0.uuidString, controller.query] }) {
            guard controller.quickOpenRequest != nil else { return }
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await controller.start()?.value
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(controller.quickOpenItems.enumerated()), id: \.element.id) { index, item in
                        Button { controller.select(item) } label: {
                            QuickOpenRow(item: item, query: controller.query, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { hoverSelect(index) } }
                        .focusable(false)
                        .id(item.id)
                        .accessibilityLabel(QuickOpenRowText.title(item))
                        .accessibilityValue(QuickOpenRowText.subtitle(item))
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: selectedIndex) { _, index in
                if hoverSelectedIndex == index { hoverSelectedIndex = nil; return }
                if controller.quickOpenItems.indices.contains(index) {
                    proxy.scrollTo(controller.quickOpenItems[index].id)
                }
            }
        }
    }

    /// Наведение меняет выбор без прокрутки; после стрелок 0,3 с игнорируется, иначе прокрутка под неподвижным курсором даёт шквал onHover.
    private func hoverSelect(_ index: Int) {
        guard Date().timeIntervalSince(keyboardMovedAt) > 0.3, index != selectedIndex else { return }
        hoverSelectedIndex = index
        selectedIndex = index
    }

    private func move(_ offset: Int) {
        keyboardMovedAt = Date()
        let ids = Array(controller.quickOpenItems.indices)
        selectedIndex = SidebarKeyboardNavigation.moved(from: selectedIndex, offset: offset, in: ids) ?? 0
    }

    /// Enter: уже найденный выбранный результат; иначе прежний путь `submit()` (подождать поиск, открыть первый).
    private func openSelected() {
        if controller.hasSearched, controller.quickOpenItems.indices.contains(selectedIndex) {
            controller.select(controller.quickOpenItems[selectedIndex])
        } else {
            controller.submit()
        }
    }
}

private struct QuickOpenRow: View {
    let item: FolderSearchController.QuickOpenItem
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(isSelected ? selectedText : tint).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(QuickOpenHighlight.attributed(title: QuickOpenRowText.title(item), query: query))
                    .font(.body).lineLimit(1)
                    .foregroundStyle(isSelected ? selectedText : Color.primary)
                Text(QuickOpenRowText.subtitle(item)).font(.subheadline)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.8) : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
    }

    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

    private var language: EditorLanguage? {
        if case let .file(file) = item { EditorLanguage.infer(from: file.url) } else { nil }
    }
    private var icon: String { language?.icon ?? "folder" }
    private var tint: Color { language.map(LacEditorDesign.fileTint(for:)) ?? .secondary }
}

/// Подсветка символов запроса в имени; считает по `Character`, только для отображения.
enum QuickOpenHighlight {
    /// Индексы `Character` в `title`, совпавшие с запросом без учёта регистра: сначала непрерывное вхождение, иначе последовательное.
    static func matchedOffsets(query: String, in title: String) -> Set<Int> {
        let q = Array(query.trimmingCharacters(in: .whitespaces)).map { String($0).lowercased() }
        guard !q.isEmpty else { return [] }
        let t = Array(title).map { String($0).lowercased() }
        if t.count >= q.count {
            for start in 0...(t.count - q.count) where Array(t[start..<start + q.count]) == q {
                return Set(start..<start + q.count)
            }
        }
        var result = Set<Int>()
        var j = 0
        for (i, character) in t.enumerated() where j < q.count && character == q[j] {
            result.insert(i)
            j += 1
        }
        return j == q.count ? result : []
    }

    static func attributed(title: String, query: String) -> AttributedString {
        let matched = matchedOffsets(query: query, in: title)
        var result = AttributedString()
        for (index, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(index) { piece.font = .body.bold() }
            result.append(piece)
        }
        return result
    }
}

extension FolderSearchController.QuickOpenItem: Identifiable {
    /// Вид + стандартизованный путь: папка и файл с одним путём невозможны, повторы отсекает контроллер.
    var id: String {
        switch self {
        case let .file(file): "file:" + file.url.standardizedFileURL.path
        case let .folder(url): "folder:" + url.standardizedFileURL.path
        }
    }
}

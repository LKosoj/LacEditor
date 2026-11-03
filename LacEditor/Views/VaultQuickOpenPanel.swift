import AppKit
import SwiftUI

/// Быстрое открытие (⌘⇧O) во вкладке хранилища: поиск по именам из каталога в памяти, без сети.
/// Состояние «панель открыта» живёт в `VaultSearchController`.
struct VaultQuickOpenOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: VaultSearchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousResponder: NSResponder?

    var body: some View {
        ZStack(alignment: .top) {
            if controller.isQuickOpenPresented {
                Color.black.opacity(0.001).onTapGesture { controller.dismissQuickOpen() }
                VaultQuickOpenPanel(controller: controller)
                    .padding(.top, 56)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? nil : LacEditorDesign.chromeAnimation, value: controller.isQuickOpenPresented)
        .onChange(of: controller.isQuickOpenPresented) { old, new in
            if !old, new { previousResponder = capturableResponder() } else if old, !new { restoreFocus() }
        }
    }

    /// Прежний ответчик; поле ввода самой панели (field editor) не запоминаем.
    private func capturableResponder() -> NSResponder? {
        let responder = appState.hostWindow?.firstResponder
        if let text = responder as? NSTextView, text.isFieldEditor { return nil }
        return responder
    }

    /// Возвращает фокус прежнему элементу, а если его нет — редактору; чужой фокус не отбирается.
    private func restoreFocus() {
        let previous = previousResponder as? NSView
        previousResponder = nil
        DispatchQueue.main.async {
            guard let window = appState.hostWindow, !appState.commandPalette.isPresented, !appState.snippetPicker.isPresented else { return }
            if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
            if let current = window.firstResponder, !(current is NSWindow),
               !((current as? NSTextView)?.isFieldEditor ?? false) { return }
            if let previous, previous.window === window { window.makeFirstResponder(previous) } else { VaultSearchFocus.focusEditor(in: window) }
        }
    }
}

private struct VaultQuickOpenPanel: View {
    @ObservedObject var controller: VaultSearchController
    @State private var query = ""
    @State private var results: [VaultSearchResult] = []
    @State private var hasSearched = false
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    /// Показываем не больше стольких строк: остальное уточняется запросом.
    private nonisolated static let limit = 50

    private var normalized: String { VaultSearchSupport.normalizedQuery(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.tr("快速打开"), text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($queryFocused)
                    .accessibilityLabel(L10n.tr("快速打开"))
                    .onSubmit { openSelected() }
                    .onExitCommand { controller.dismissQuickOpen() }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
            }
            .padding(.horizontal, 12).frame(height: 40)
            if !controller.isCatalogComplete {
                Text(L10n.tr("正在加载笔记列表…")).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if !results.isEmpty {
                Divider()
                list
            } else if hasSearched {
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
        .onExitCommand { controller.dismissQuickOpen() }
        .onAppear { queryFocused = true }
        .onChange(of: controller.quickOpenFocusRequest) { _, _ in queryFocused = true }
        .task(id: query) { await refresh() }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button { open(result) } label: {
                            VaultQuickOpenRow(result: result, query: query, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain).focusable(false).id(result.id)
                        .accessibilityLabel(result.name)
                        .accessibilityValue(result.folderTrail)
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: selectedIndex) { _, index in
                if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
            }
        }
    }

    /// Каждая буква пересчитывает имена в фоне; устаревший расчёт отменяется вместе с задачей.
    private func refresh() async {
        guard !normalized.isEmpty else {
            results = []
            hasSearched = false
            return
        }
        let text = normalized
        let paths = controller.catalogPaths()
        let worker = Task.detached(priority: .userInitiated) {
            try? VaultSearchSupport.rankNames(query: text, paths: paths, limit: Self.limit, isCancelled: { Task.isCancelled })
        }
        let ranked = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, let ranked else { return }
        results = ranked.results
        selectedIndex = 0
        hasSearched = true
    }

    private func move(_ offset: Int) {
        selectedIndex = SidebarKeyboardNavigation.moved(from: selectedIndex, offset: offset, in: Array(results.indices)) ?? 0
    }

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        open(results[selectedIndex])
    }

    /// ⌘ при выборе открывает заметку в новой вкладке.
    private func open(_ result: VaultSearchResult) {
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        controller.dismissQuickOpen()
        controller.select(result, newTab: newTab, query: normalized)
    }
}

private struct VaultQuickOpenRow: View {
    let result: VaultSearchResult
    let query: String
    let isSelected: Bool

    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text").foregroundStyle(isSelected ? selectedText : Color.secondary).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(QuickOpenHighlight.attributed(title: result.name, query: query))
                    .font(.body).lineLimit(1)
                    .foregroundStyle(isSelected ? selectedText : Color.primary)
                if !result.folderTrail.isEmpty {
                    Text(result.folderTrail).font(.subheadline)
                        .foregroundStyle(isSelected ? selectedText.opacity(0.8) : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
    }
}

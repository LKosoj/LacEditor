import AppKit
import SwiftUI

/// Состояние панели выбора сниппета. Панель открыта, пока есть `request`.
@MainActor
final class SnippetPickerController: ObservableObject {
    @Published private(set) var request: UUID?
    @Published var query = ""
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var message: String?
    private var pending: Snippet?

    var isPresented: Bool { request != nil }
    var results: [Snippet] { SnippetService.ranked(snippets, query: query) }

    func present(snippets: [Snippet], message: String?) {
        query = ""
        pending = nil
        self.snippets = snippets
        self.message = message
        request = UUID()
    }

    func dismiss() {
        pending = nil
        request = nil
    }

    func choose(_ snippet: Snippet) {
        pending = snippet
        request = nil
    }

    /// Выбранный сниппет отдаётся один раз.
    func takePending() -> Snippet? {
        defer { pending = nil }
        return pending
    }
}

/// Плавающая панель выбора сниппета поверх области редактора; устроена как палитра команд.
struct SnippetPickerOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: SnippetPickerController
    @ObservedObject var folderSearch: FolderSearchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousResponder: NSResponder?

    var body: some View {
        ZStack(alignment: .top) {
            if controller.isPresented {
                Color.black.opacity(0.001).onTapGesture { controller.dismiss() }
                SnippetPickerPanel(controller: controller)
                    .padding(.top, 56)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? nil : LacEditorDesign.chromeAnimation, value: controller.request)
        .onChange(of: controller.request) { old, new in
            if old == nil, new != nil { previousResponder = capturableResponder() }
            else if old != nil, new == nil { closed() }
        }
        .onChange(of: folderSearch.quickOpenRequest) { _, new in
            if new != nil { controller.dismiss() }
        }
    }

    private func capturableResponder() -> NSResponder? {
        let responder = appState.hostWindow?.firstResponder
        if let text = responder as? NSTextView, text.isFieldEditor { return nil }
        return responder
    }

    /// Сначала возвращается фокус, затем (следующим проходом главного потока) вставляется выбранный сниппет.
    private func closed() {
        restoreFocus()
        DispatchQueue.main.async {
            guard appState.hostWindow?.isKeyWindow == true else { _ = controller.takePending(); return }
            if let snippet = controller.takePending() { appState.insertSnippet(snippet) }
        }
    }

    private func restoreFocus() {
        let previous = previousResponder as? NSView
        previousResponder = nil
        DispatchQueue.main.async {
            guard let window = appState.hostWindow, appState.folderSearch.quickOpenRequest == nil,
                  !appState.commandPalette.isPresented else { return }
            if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
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

private struct SnippetPickerPanel: View {
    @ObservedObject var controller: SnippetPickerController
    @State private var selectedIndex = 0
    @State private var keyboardMovedAt = Date.distantPast
    @State private var hoverSelectedIndex: Int?
    @FocusState private var queryFocused: Bool

    var body: some View {
        let results = controller.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.tr("搜索文本片段"), text: $controller.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($queryFocused)
                    .accessibilityLabel(L10n.tr("搜索文本片段"))
                    .accessibilityIdentifier("snippetPicker.field")
                    .onSubmit { chooseSelected(in: results) }
                    .onExitCommand { controller.dismiss() }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: move(-1, count: results.count)
                        case .down: move(1, count: results.count)
                        default: break
                        }
                    }
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            if let message = controller.message {
                StatusMessageView(kind: .error, text: message)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            if !results.isEmpty {
                list(results)
            } else {
                Text(controller.snippets.isEmpty
                     ? L10n.tr("还没有文本片段。可在设置中添加，或选中文字后使用「将所选内容存为文本片段…」。")
                     : L10n.tr("没有匹配的文本片段"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(width: 520)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("插入文本片段"))
        .onExitCommand { controller.dismiss() }
        .onAppear { queryFocused = true; selectedIndex = 0 }
        .onChange(of: controller.query) { _, _ in
            keyboardMovedAt = Date()
            selectedIndex = 0
        }
    }

    private func list(_ results: [Snippet]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, snippet in
                        Button { controller.choose(snippet) } label: {
                            SnippetPickerRow(snippet: snippet, query: controller.query, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityIdentifier("snippetPicker.row.\(snippet.id.uuidString)")
                        .accessibilityLabel(snippet.name)
                        .accessibilityValue(SnippetPickerRow.firstLine(of: snippet.text))
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                        .onHover { if $0 { hoverSelect(index) } }
                        .id(snippet.id)
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: selectedIndex) { _, index in
                if hoverSelectedIndex == index { hoverSelectedIndex = nil; return }
                if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
            }
        }
    }

    /// Наведение меняет выбор без прокрутки; после стрелок 0,3 с игнорируется, как в быстром открытии.
    private func hoverSelect(_ index: Int) {
        guard Date().timeIntervalSince(keyboardMovedAt) > 0.3, index != selectedIndex else { return }
        hoverSelectedIndex = index
        selectedIndex = index
    }

    private func move(_ offset: Int, count: Int) {
        keyboardMovedAt = Date()
        selectedIndex = SidebarKeyboardNavigation.moved(from: selectedIndex, offset: offset, in: Array(0..<count)) ?? 0
    }

    private func chooseSelected(in results: [Snippet]) {
        guard results.indices.contains(selectedIndex) else { return }
        controller.choose(results[selectedIndex])
    }
}

private struct SnippetPickerRow: View {
    let snippet: Snippet
    let query: String
    let isSelected: Bool

    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(QuickOpenHighlight.attributed(title: snippet.name, query: query))
                .font(.body).lineLimit(1)
                .foregroundStyle(isSelected ? selectedText : Color.primary)
            Text(Self.firstLine(of: snippet.text)).font(.subheadline)
                .foregroundStyle(isSelected ? selectedText.opacity(0.8) : Color.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
    }

    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
}

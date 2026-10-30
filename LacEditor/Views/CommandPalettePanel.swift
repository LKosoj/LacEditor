import AppKit
import SwiftUI

/// Плавающая палитра команд (⇧⌘A) поверх области редактора: пункты главного меню с поиском.
/// Панель открыта, пока у `CommandPaletteController` есть `request`.
struct CommandPaletteOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: CommandPaletteController
    @ObservedObject var folderSearch: FolderSearchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousResponder: NSResponder?

    var body: some View {
        ZStack(alignment: .top) {
            if controller.isPresented {
                Color.black.opacity(0.001).onTapGesture { controller.dismiss() }
                CommandPalettePanel(controller: controller)
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

    /// Сначала возвращается фокус, затем (следующим проходом главного потока) выполняется выбранный пункт меню.
    private func closed() {
        restoreFocus()
        DispatchQueue.main.async {
            guard appState.hostWindow?.isKeyWindow == true else { controller.dismiss(); return }
            controller.performPending(menu: NSApp.mainMenu)
        }
    }

    private func restoreFocus() {
        let previous = previousResponder as? NSView
        previousResponder = nil
        DispatchQueue.main.async {
            guard let window = appState.hostWindow, appState.folderSearch.quickOpenRequest == nil else { return }
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

struct CommandPalettePanel: View {
    @ObservedObject var controller: CommandPaletteController
    @State private var selectedIndex = 0
    @State private var keyboardMovedAt = Date.distantPast
    @State private var hoverSelectedIndex: Int?
    @FocusState private var queryFocused: Bool

    var body: some View {
        let results = controller.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.tr("命令面板"), text: $controller.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($queryFocused)
                    .accessibilityLabel(L10n.tr("命令面板"))
                    .accessibilityIdentifier("commandPalette.field")
                    .onSubmit { runSelected(in: results) }
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
            if !results.isEmpty {
                Divider()
                list(results)
            } else {
                Divider()
                Text(L10n.tr("没有匹配的命令")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(width: 520)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("命令面板"))
        .onExitCommand { controller.dismiss() }
        .onAppear { queryFocused = true; selectedIndex = 0 }
        .onChange(of: controller.query) { _, _ in
            keyboardMovedAt = Date()
            selectedIndex = 0
        }
    }

    private func list(_ results: [PaletteCommand]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        Button { controller.run(command) } label: {
                            CommandPaletteRow(command: command, query: controller.query, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { hoverSelect(index) } }
                        .focusable(false)
                        .id(command.id)
                        .accessibilityIdentifier("commandPalette.row.\(command.id)")
                        .accessibilityLabel(command.fullTitle)
                        .accessibilityValue(command.shortcut)
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
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

    private func runSelected(in results: [PaletteCommand]) {
        guard results.indices.contains(selectedIndex) else { return }
        controller.run(results[selectedIndex])
    }
}

private struct CommandPaletteRow: View {
    let command: PaletteCommand
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(QuickOpenHighlight.attributed(title: command.title, query: query))
                    .font(.body).lineLimit(1)
                    .foregroundStyle(isSelected ? selectedText : Color.primary)
                if !command.subtitle.isEmpty {
                    Text(command.subtitle).font(.subheadline)
                        .foregroundStyle(isSelected ? selectedText.opacity(0.8) : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if !command.shortcut.isEmpty {
                Text(command.shortcut).font(.caption)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
    }

    private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
}

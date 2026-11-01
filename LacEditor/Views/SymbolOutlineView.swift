import SwiftUI

private struct SymbolOutlineTrigger: Hashable {
    let documentID: UUID
    let language: EditorLanguage
    let isActive: Bool
}

/// Раздел «Символы» боковой панели для файлов не Markdown: список функций, классов и т. п. Состояние раскрытия не сохраняется.
struct SymbolOutlineSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument

    private var isActive: Bool { appState.isSymbolOutlineExpanded && appState.isSidebarEffectivelyVisible }

    var body: some View {
        DisclosureGroup(isExpanded: $appState.isSymbolOutlineExpanded) {
            SymbolOutlineView(controller: appState.symbolOutline, document: document) {
                appState.revealSymbol($0, in: document)
            }
        } label: {
            Text(L10n.tr("符号"))
                .font(.subheadline.weight(.semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .task(id: SymbolOutlineTrigger(documentID: document.id, language: document.language, isActive: isActive)) {
            appState.symbolOutline.update(document: document, isActive: isActive)
        }
        .onDisappear { appState.symbolOutline.close() }
    }
}

struct SymbolOutlineView: View {
    @ObservedObject var controller: SymbolOutlineController
    /// Не `@ObservedObject`: список не перерисовывается на каждое движение курсора.
    let document: EditorDocument
    let reveal: (OutlineSymbol) -> Void
    @State private var query = ""
    @State private var visible: [OutlineSymbol] = []
    @State private var currentID: Int?
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focusedID: Int?
    @FocusState private var filterFocused: Bool
    @FocusState private var clearFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch controller.state {
            case .inactive, .updating:
                message(L10n.tr("正在更新符号…"))
            case .tooLarge:
                message(L10n.tr("文件过大，无法生成大纲"))
            case .loaded:
                if controller.symbols.isEmpty {
                    message(L10n.tr("暂无符号"))
                } else {
                    filterField
                    if visible.isEmpty {
                        message(L10n.tr("没有匹配的符号"))
                    } else {
                        list
                    }
                }
            }
        }
        .onReceive(controller.$symbols) { symbols in
            // значения берём из публикации: `@Published` сообщает до записи свойства
            visible = SymbolOutlineService.filtered(symbols, query: query)
            updateCurrent(symbols: symbols, caret: document.selectionRange.location)
        }
        .onReceive(document.$selectionRange) { selection in
            updateCurrent(symbols: controller.symbols, caret: selection.location)
        }
        .onChange(of: query) { _, value in
            visible = SymbolOutlineService.filtered(controller.symbols, query: value)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    private func updateCurrent(symbols: [OutlineSymbol], caret: Int) {
        let id = SymbolOutlineService.currentIndex(in: symbols, caret: caret).map { symbols[$0].id }
        if id != currentID { currentID = id }
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.tr("筛选符号"), text: $query)
                .textFieldStyle(.plain).font(.callout)
                .accessibilityLabel(L10n.tr("筛选符号"))
                .focused($filterFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel(L10n.tr("清除筛选"))
                    .focused($clearFocused).editorFocusRing(clearFocused, radius: 3)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
        .editorFocusRing(filterFocused, radius: 7)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { symbol in
                        SymbolOutlineRow(symbol: symbol, isCurrent: symbol.id == currentID) { reveal(symbol) }
                            .focused($focusedID, equals: symbol.id)
                            .editorFocusRing(focusedID == symbol.id)
                            .id(symbol.id)
                            .onKeyPress(.upArrow) { moveFocus(from: symbol.id, offset: -1, proxy: proxy) }
                            .onKeyPress(.downArrow) { moveFocus(from: symbol.id, offset: 1, proxy: proxy) }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight > 0 ? contentHeight : MarkdownOutlineView.estimatedHeight(rowCount: visible.count),
                               MarkdownOutlineView.maximumHeight))
        }
    }

    private func moveFocus(from id: Int, offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let next = SidebarKeyboardNavigation.moved(from: id, offset: offset, in: visible.map(\.id)) else { return .ignored }
        focusedID = next
        proxy.scrollTo(next)
        return .handled
    }
}

private struct SymbolOutlineRow: View {
    let symbol: OutlineSymbol
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(symbol.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, CGFloat(symbol.level) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SoftRowButtonStyle())
        .sidebarRowChrome(selected: isCurrent, hovering: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(symbol.name)
        .accessibilityValue(symbol.kind.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

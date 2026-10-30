import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownOutlineView: View {
    @ObservedObject var document: EditorDocument
    var maximumLevel = 6
    let reveal: (MarkdownHeading) -> Void
    var canMove: (MarkdownHeading, MarkdownSectionMoveService.Direction) -> Bool = { _, _ in false }
    var move: (MarkdownHeading, MarkdownSectionMoveService.Direction) -> Bool = { _, _ in false }
    /// Раздел и заголовок, перед которым он встанет (nil — в конец документа).
    var drop: (MarkdownHeading, MarkdownHeading?) -> Void = { _, _ in }
    @State private var indicator: OutlineDropIndicator?
    @State private var visibleHeadings: [MarkdownHeading] = []
    @State private var currentID: Int?
    @State private var contentHeight: CGFloat = 0
    @State private var awaitsMovedFocus = false
    @FocusState private var focusedID: Int?

    static let maximumHeight: CGFloat = 320

    /// Оценка до первого измерения: около 24 pt на строку, не меньше одной строки.
    static func estimatedHeight(rowCount: Int) -> CGFloat { min(CGFloat(max(rowCount, 1)) * 24, maximumHeight) }

    private var estimatedRowCount: Int {
        document.isMarkdownOutlineCurrent ? document.markdownHeadings.filter { $0.level <= maximumLevel }.count : 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !document.isMarkdownOutlineCurrent {
                        Text(L10n.tr("正在更新大纲…"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else if visibleHeadings.isEmpty {
                        Text(L10n.tr("暂无标题"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(visibleHeadings.enumerated()), id: \.element.id) { offset, heading in
                            MarkdownOutlineRow(heading: heading, isCurrent: heading.id == currentID,
                                               canMove: canMove, move: { _ = move($0, $1) }) { reveal(heading) }
                                .focused($focusedID, equals: heading.id)
                                .editorFocusRing(focusedID == heading.id)
                                .id(heading.id)
                                .modifier(OutlineSectionDrop(
                                    heading: heading, next: offset + 1 < visibleHeadings.count ? visibleHeadings[offset + 1] : nil,
                                    document: document, indicator: $indicator, drop: drop))
                                .onKeyPress(.upArrow) { press in
                                    if press.modifiers == .option { return moveSection(heading, .up) }
                                    return moveFocus(from: heading.id, offset: -1, proxy: proxy)
                                }
                                .onKeyPress(.downArrow) { press in
                                    if press.modifiers == .option { return moveSection(heading, .down) }
                                    return moveFocus(from: heading.id, offset: 1, proxy: proxy)
                                }
                        }
                        // зона «в конец документа»
                        Color.clear.frame(height: 14).contentShape(Rectangle())
                            .modifier(OutlineSectionDrop(heading: nil, next: nil, document: document,
                                                         indicator: $indicator, drop: drop))
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            // Короткое оглавление не оставляет пустого места, длинное прокручивается внутри 320 pt.
            .frame(height: min(contentHeight > 0 ? contentHeight : Self.estimatedHeight(rowCount: estimatedRowCount), Self.maximumHeight))
        }
        .onReceive(Publishers.CombineLatest3(document.$markdownHeadings, document.$selectionRange,
                                             document.$isMarkdownOutlineCurrent)) { value in
            // значения берём из публикации: `@Published` сообщает до записи свойства
            let (headings, selection, isCurrent) = value
            let id = MarkdownOutlineCurrent.headingID(in: headings.filter { $0.level <= maximumLevel },
                                                      caret: selection.location, isCurrent: isCurrent)
            if id != currentID { currentID = id }
        }
        .onReceive(document.$markdownHeadings) { headings in
            visibleHeadings = headings.filter { $0.level <= maximumLevel }
            // перенос ставит курсор в начало строки заголовка (перед отступом до трёх пробелов): фокус следует за ним на новое место
            if awaitsMovedFocus {
                awaitsMovedFocus = false
                let caret = document.selectionRange.location
                if let moved = visibleHeadings.first(where: { (0...3).contains($0.range.location - caret) }) { focusedID = moved.id }
            }
        }
        .onDisappear {
            indicator = nil
        }
        .onChange(of: maximumLevel) { _, value in
            visibleHeadings = document.markdownHeadings.filter { $0.level <= value }
            currentID = MarkdownOutlineCurrent.headingID(in: visibleHeadings, caret: document.selectionRange.location,
                                                         isCurrent: document.isMarkdownOutlineCurrent)
        }
    }

    private func moveSection(_ heading: MarkdownHeading, _ direction: MarkdownSectionMoveService.Direction) -> KeyPress.Result {
        guard heading.isTopLevel, canMove(heading, direction) else { return .ignored }
        awaitsMovedFocus = move(heading, direction)
        return .handled
    }

    private func moveFocus(from id: Int, offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let next = SidebarKeyboardNavigation.moved(from: id, offset: offset, in: visibleHeadings.map(\.id)) else { return .ignored }
        focusedID = next
        proxy.scrollTo(next)
        return .handled
    }
}

private struct MarkdownOutlineRow: View {
    let heading: MarkdownHeading
    let isCurrent: Bool
    let canMove: (MarkdownHeading, MarkdownSectionMoveService.Direction) -> Bool
    let move: (MarkdownHeading, MarkdownSectionMoveService.Direction) -> Void
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let title = heading.renderedTitle.isEmpty ? (heading.number ?? "") + L10n.tr("无标题") : heading.numberedTitle
        Button(action: action) {
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(heading.level - 1) * 12)
        }
        .buttonStyle(SoftRowButtonStyle())
        .sidebarRowChrome(selected: isCurrent, hovering: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(L10n.tr("标题 %@ 级", String(heading.level)))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            if heading.isTopLevel {
                Button(L10n.tr("上移章节")) { move(heading, .up) }.disabled(!canMove(heading, .up))
                Button(L10n.tr("下移章节")) { move(heading, .down) }.disabled(!canMove(heading, .down))
            }
        }
        .accessibilityAction(named: L10n.tr("上移章节")) { if heading.isTopLevel, canMove(heading, .up) { move(heading, .up) } }
        .accessibilityAction(named: L10n.tr("下移章节")) { if heading.isTopLevel, canMove(heading, .down) { move(heading, .down) } }
    }
}

/// Тип переноса раздела: только внутри этого окна, чужие перетаскивания не принимаются.
private let outlineSectionType = UTType(exportedAs: "com.laceditor.outline-section")

/// Последнее начатое перетаскивание раздела. Тип виден всем окнам, а об отмене система не сообщает:
/// значение перезаписывается при каждом начале, и окно другого документа его отвергает.
@MainActor private enum OutlineSectionDrag {
    static var current: (documentID: UUID, headingID: Int)?
}

/// Куда встанет раздел: у строки `id` сверху или снизу; id == nil — полоса «в конец».
private struct OutlineDropIndicator: Equatable {
    enum Placement { case before, after }
    var id: Int?
    var placement: Placement
}

/// Перетаскивание заголовка верхнего уровня и приём раздела на строку оглавления (`heading == nil` — зона «в конец»).
private struct OutlineSectionDrop: ViewModifier {
    let heading: MarkdownHeading?
    /// Следующая видимая строка: нижняя половина строки означает вставку перед ней.
    let next: MarkdownHeading?
    let document: EditorDocument
    @Binding var indicator: OutlineDropIndicator?
    let drop: (MarkdownHeading, MarkdownHeading?) -> Void
    @State private var height: CGFloat = 24

    func body(content: Content) -> some View {
        draggable(content)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            .overlay {
                if let indicator, indicator.id == heading?.id {
                    VStack(spacing: 0) {
                        if indicator.placement == .after { Spacer(minLength: 0) }
                        Capsule().fill(LacEditorDesign.accent).frame(height: 2)
                        if indicator.placement == .before { Spacer(minLength: 0) }
                    }.allowsHitTesting(false)
                }
            }
            .onDrop(of: [outlineSectionType], delegate: OutlineSectionDropDelegate(
                heading: heading, next: next, height: height, document: document,
                indicator: $indicator, drop: drop))
    }

    @ViewBuilder private func draggable(_ content: Content) -> some View {
        if let heading, heading.isTopLevel {
            content.onDrag {
                OutlineSectionDrag.current = (document.id, heading.id)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: outlineSectionType.identifier, visibility: .ownProcess) {
                    $0(Data(), nil)
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}

private struct OutlineSectionDropDelegate: DropDelegate {
    let heading: MarkdownHeading?
    let next: MarkdownHeading?
    let height: CGFloat
    let document: EditorDocument
    @Binding var indicator: OutlineDropIndicator?
    let drop: (MarkdownHeading, MarkdownHeading?) -> Void

    private var draggedID: Int? {
        OutlineSectionDrag.current.flatMap { $0.documentID == document.id ? $0.headingID : nil }
    }

    /// Раздел, заголовок «перед» (nil — в конец) и положение индикатора; nil, если сюда ставить нельзя.
    private func resolve(_ info: DropInfo) -> (section: MarkdownHeading, before: MarkdownHeading?, placement: OutlineDropIndicator.Placement)? {
        let headings = document.markdownHeadings
        guard document.isMarkdownOutlineCurrent, let draggedID,
              let section = headings.firstIndex(where: { $0.id == draggedID }) else { return nil }
        let placement: OutlineDropIndicator.Placement = heading != nil && info.location.y < height / 2 ? .before : .after
        let before = placement == .before ? heading : next
        var target = MarkdownSectionMoveService.Target.end
        if let heading, !heading.isTopLevel { return nil }
        if let before {
            guard let index = headings.firstIndex(where: { $0.sameSource(as: before) }) else { return nil }
            target = .before(index)
        }
        guard MarkdownSectionMoveService.validate(section: section, target: target, headings: headings) == nil else { return nil }
        return (headings[section], before, placement)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil && info.hasItemsConforming(to: [outlineSectionType])
    }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info), let place = resolve(info) else {
            if indicator?.id == heading?.id { indicator = nil }
            return DropProposal(operation: .forbidden)
        }
        indicator = OutlineDropIndicator(id: heading?.id, placement: place.placement)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if indicator?.id == heading?.id { indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = validateDrop(info: info) ? resolve(info) : nil
        indicator = nil
        OutlineSectionDrag.current = nil
        guard let place else { return false }
        drop(place.section, place.before)
        return true
    }
}

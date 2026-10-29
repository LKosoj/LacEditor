import AppKit
import UniformTypeIdentifiers

private final class MarkdownTableAccessibilityCell: NSAccessibilityElement {
    var activate: (() -> Bool)?
    var isCurrent: (() -> Bool)?

    override func accessibilityPerformPress() -> Bool { activate?() ?? false }
    override func isAccessibilitySelected() -> Bool { isCurrent?() == true && super.isAccessibilitySelected() }
    override func accessibilityFrame() -> NSRect { isCurrent?() == true ? super.accessibilityFrame() : .zero }
    override func accessibilityFrameInParentSpace() -> NSRect { isCurrent?() == true ? super.accessibilityFrameInParentSpace() : .zero }
}

final class MarkdownTableAccessibilityRow: NSObject, NSAccessibilityRow {
    weak var owner: LacTextView?
    weak var table: MarkdownTableAccessibilityTable?
    var frameInView = NSRect.zero
    var index = 0
    var cells: [NSAccessibilityElement] = []
    var cellsProvider: (() -> [NSAccessibilityElement])?
    var selected = false

    func accessibilityFrame() -> NSRect {
        guard !frameInView.isEmpty, table?.isCurrent?() == true, let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(frameInView, to: nil))
    }
    func accessibilityParent() -> Any? { table }
    func accessibilityIndex() -> Int { index }
    @objc func isAccessibilityElement() -> Bool { table?.isCurrent?() == true }
    @objc func accessibilityRole() -> NSAccessibility.Role? { .row }
    @objc func accessibilityChildren() -> [Any]? { table?.isCurrent?() == true ? (cellsProvider?() ?? cells) : [] }
    @objc func isAccessibilitySelected() -> Bool { table?.isCurrent?() == true && selected }
}

final class MarkdownTableAccessibilityTable: NSObject, NSAccessibilityTable {
    weak var owner: LacTextView?
    var frameInView = NSRect.zero
    var rows: [MarkdownTableAccessibilityRow] = []
    var rowCount = 0
    var columnCount = 0
    var isCurrent: (() -> Bool)?
    var allRowsProvider: (() -> [MarkdownTableAccessibilityRow])?
    var headerProvider: (() -> [NSAccessibilityElement])?
    var selectedRowsProvider: (() -> [MarkdownTableAccessibilityRow])?
    var headerRow: MarkdownTableAccessibilityRow?
    var retainedSelectedRows: [MarkdownTableAccessibilityRow] = []

    func accessibilityFrame() -> NSRect {
        guard isCurrent?() == true, let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(frameInView, to: nil))
    }
    func accessibilityParent() -> Any? { owner }
    func accessibilityLabel() -> String? { L10n.tr("表格") }
    @objc func isAccessibilityElement() -> Bool { isCurrent?() == true }
    func accessibilityRows() -> [any NSAccessibilityRow]? { isCurrent?() == true ? (allRowsProvider?() ?? rows) : [] }
    @objc func accessibilityRole() -> NSAccessibility.Role? { .table }
    @objc func accessibilityChildren() -> [Any]? { isCurrent?() == true ? rows : [] }
    @objc func accessibilityRowCount() -> Int { rowCount }
    @objc func tableAccessibilityColumnCount() -> Int { columnCount }
    func accessibilitySelectedRows() -> [any NSAccessibilityRow]? { isCurrent?() == true ? (selectedRowsProvider?() ?? rows.filter(\.selected)) : [] }
    func accessibilitySelectedCells() -> [Any]? {
        guard isCurrent?() == true else { return [] }
        retainedSelectedRows = selectedRowsProvider?() ?? rows.filter(\.selected)
        return retainedSelectedRows.flatMap { $0.accessibilityChildren() ?? [] }
            .compactMap { $0 as? NSAccessibilityElement }.filter { $0.isAccessibilitySelected() }
    }
    func accessibilityColumnHeaderUIElements() -> [Any]? { isCurrent?() == true ? (headerProvider?() ?? rows.first(where: { $0.index == 0 })?.cells ?? []) : [] }
    func accessibilityVisibleRows() -> [any NSAccessibilityRow]? { isCurrent?() == true ? rows : [] }
    func accessibilityVisibleCells() -> [Any]? { isCurrent?() == true ? rows.flatMap(\.cells) : [] }
}

enum MarkdownTableAccessibilityMove { case rowUp, rowDown, columnLeft, columnRight }

enum MarkdownImageTransfer: Sendable {
    case file(URL), data(Data), remote(URL)
}

enum IndentationStyle: String, CaseIterable, Identifiable {
    case spaces
    case tabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spaces: L10n.tr("使用空格")
        case .tabs: L10n.tr("使用 Tab 字符")
        }
    }
}

func lacEditorFont(size: CGFloat) -> NSFont {
    // Menlo supplies stable fixed-width metrics for Latin text. AppKit uses
    // the system fallback (PingFang on Chinese systems) for glyphs Menlo does
    // not contain. FoldLayoutManager deliberately keeps line metrics based on
    // this requested font rather than whichever fallback draws the first glyph.
    NSFont(name: "Menlo-Regular", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

extension NSColor {
    static let lacEditorBackground = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedWhite: 0.105, alpha: 1)
        }
        return NSColor(
            red: 251.0 / 255.0,
            green: 251.0 / 255.0,
            blue: 251.0 / 255.0,
            alpha: 1
        )
    }

    static let lacCurrentLineBackground = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(
                calibratedRed: 0.48,
                green: 0.53,
                blue: 0.88,
                alpha: 0.14
            )
        }
        return NSColor(
            calibratedRed: 0.31,
            green: 0.34,
            blue: 0.66,
            alpha: 0.07
        )
    }

    static let lacDelimiterMatchBackground = NSColor(name: nil) { appearance in
        let alpha: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua])
            == .darkAqua ? 0.24 : 0.14
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }
}

final class LacTextView: NSTextView {
    func placeMarkdownSubview(_ child: NSView, in rect: NSRect) {
        guard layoutOrientation == .vertical, child.superview === self, let clip = enclosingScrollView?.contentView else {
            child.frameRotation = 0
            child.frame = rect
            return
        }
        let target = clip.convert(rect, from: self)
        child.frameRotation = boundsRotation
        child.setFrameSize(target.size)
        child.setFrameOrigin(rect.origin)
        let actual = clip.convert(child.bounds, from: child)
        let oldOrigin = convert(actual.origin, from: clip)
        let desiredOrigin = convert(target.origin, from: clip)
        child.setFrameOrigin(NSPoint(x: child.frame.origin.x + desiredOrigin.x - oldOrigin.x,
                                     y: child.frame.origin.y + desiredOrigin.y - oldOrigin.y))
        child.needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        let existing = super.accessibilityChildren() ?? []
        guard let layout = layoutManager as? FoldLayoutManager, let container = textContainer,
              let window, let textStorage else { return existing }
        let cells = layout.visibleTableAccessibilityCells(in: container)
        let revision = tableAccessibilityRevision?()
        let selection = tableAccessibilitySelection?()
        let capturedVisibleRect = visibleRect
        var elements: [Any] = []
        var index = 0
        while index < cells.count {
            let tableRange = cells[index].tableRange
            var end = index
            while end < cells.count && cells[end].tableRange == tableRange { end += 1 }
            let group = Array(cells[index..<end])
            let frame = group.reduce(NSRect.null) { $0.union($1.frame) }
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let table = MarkdownTableAccessibilityTable()
            table.owner = self
            table.frameInView = frame
            table.rowCount = group[0].rowCount
            table.columnCount = group[0].columnCount
            table.isCurrent = { [weak self] in
                guard let self, let revision, self.tableAccessibilityRevision?() == revision,
                      self.visibleRect == capturedVisibleRect,
                      let layout = self.layoutManager as? FoldLayoutManager, let container = self.textContainer else { return false }
                let current = self.tableAccessibilitySelection?()
                guard current?.0 == selection?.0, current?.1 == selection?.1 else { return false }
                return layout.visibleTableAccessibilityCells(in: container).contains { $0.tableRange == tableRange }
            }
            var rows: [MarkdownTableAccessibilityRow] = [], cursor = 0
            while cursor < group.count {
                let rowIndex = group[cursor].row
                var rowEnd = cursor
                while rowEnd < group.count && group[rowEnd].row == rowIndex { rowEnd += 1 }
                let rowCells = Array(group[cursor..<rowEnd])
                let rowFrame = rowCells.reduce(NSRect.null) { $0.union($1.frame) }
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                let row = MarkdownTableAccessibilityRow()
                row.owner = self
                row.table = table
                row.frameInView = rowFrame
                row.index = rowIndex
                var children: [NSAccessibilityElement] = []
                for entry in rowCells {
                    let cellFrame = entry.frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                    let label = layout.markdownTableAccessibleText(entry.cell)
                        ?? layout.tableCellAttributedText(entry.cell, text: textStorage.mutableString).string
                    guard let cell = MarkdownTableAccessibilityCell.element(withRole: .cell,
                            frame: window.convertToScreen(convert(cellFrame, to: nil)), label: label, parent: row) as? MarkdownTableAccessibilityCell else { continue }
                    cell.isCurrent = { [weak table] in table?.isCurrent?() == true }
                    cell.setAccessibilityFrameInParentSpace(cellFrame.offsetBy(dx: -rowFrame.minX, dy: -rowFrame.minY))
                    cell.setAccessibilityRowIndexRange(NSRange(location: rowIndex, length: 1))
                    cell.setAccessibilityColumnIndexRange(NSRange(location: entry.cell.column, length: 1))
                    let selected = Self.tableCellSelected(entry.cell, selection: selection)
                    cell.setAccessibilitySelected(selected)
                    row.selected = row.selected || selected
                    cell.activate = { [weak self, weak table] in
                        guard let self, let table, table.isCurrent?() == true, let revision, self.tableAccessibilityRevision?() == revision,
                              let layout = self.layoutManager as? FoldLayoutManager, let container = self.textContainer,
                              let visible = layout.visibleTableAccessibilityCells(in: container).first(where: {
                                  $0.tableRange == entry.tableRange && $0.row == entry.row && $0.cell == entry.cell
                              }) else { return false }
                        return self.tableCellHandler?(visible.cell, visible.frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)) == true
                    }
                    var actions: [NSAccessibilityCustomAction] = []
                    let choices: [(String, MarkdownTableAccessibilityMove, Bool)] = [
                        ("上移行", .rowUp, entry.row > 1),
                        ("下移行", .rowDown, entry.row > 0 && entry.row + 1 < entry.rowCount),
                        ("左移列", .columnLeft, entry.cell.column > 0),
                        ("右移列", .columnRight, entry.cell.column + 1 < entry.columnCount)
                    ]
                    for (name, command, allowed) in choices where allowed {
                        actions.append(NSAccessibilityCustomAction(name: L10n.tr(name)) { [weak self, weak table] in
                            guard let self, let table, table.isCurrent?() == true, let revision, self.tableAccessibilityRevision?() == revision,
                                  let layout = self.layoutManager as? FoldLayoutManager, let container = self.textContainer,
                                  let visible = layout.visibleTableAccessibilityCells(in: container).first(where: {
                                      $0.tableRange == entry.tableRange && $0.row == entry.row && $0.cell == entry.cell
                                  }) else { return false }
                            return self.tableAccessibilityActionHandler?(visible.cell,
                                visible.frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), command) == true
                        })
                    }
                    cell.setAccessibilityCustomActions(actions)
                    children.append(cell)
                }
                row.cells = children
                rows.append(row)
                cursor = rowEnd
            }
            table.rows = rows
            if let model = layout.accessibilityTableModel(tableRange) {
                let visibleRows = rows
                table.allRowsProvider = { [weak self, weak table] in
                    guard let self, let table, table.isCurrent?() == true else { return [] }
                    let visibleByIndex = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.index, $0) })
                    return model.rows.indices.map { rowIndex in
                        if let visible = visibleByIndex[rowIndex] { return visible }
                        return self.offscreenAccessibilityRow(model: model, rowIndex: rowIndex, table: table, revision: revision, selection: selection)
                    }
                }
                table.headerProvider = { [weak self, weak table] in
                    guard let self, let table, table.isCurrent?() == true else { return [] }
                    if let header = visibleRows.first(where: { $0.index == 0 }) { return header.cells }
                    let header = self.offscreenAccessibilityRow(model: model, rowIndex: 0, table: table, revision: revision, selection: selection)
                    table.headerRow = header
                    return header.accessibilityChildren() as? [NSAccessibilityElement] ?? []
                }
                table.selectedRowsProvider = { [weak self, weak table] in
                    guard let self, let table, table.isCurrent?() == true, let selection else { return [] }
                    var low = 0, high = model.rows.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        if NSMaxRange(model.rows.range(at: middle)) < selection.0.location { low = middle + 1 }
                        else { high = middle }
                    }
                    let visibleByIndex = Dictionary(uniqueKeysWithValues: visibleRows.map { ($0.index, $0) })
                    var result: [MarkdownTableAccessibilityRow] = []
                    while low < model.rows.count && model.rows.range(at: low).location <= NSMaxRange(selection.0) {
                        let row = visibleByIndex[low] ?? self.offscreenAccessibilityRow(model: model, rowIndex: low,
                            table: table, revision: revision, selection: selection)
                        if row.selected { result.append(row) }
                        low += 1
                    }
                    return result
                }
            }
            elements.append(table)
            index = end
        }
        return existing + elements
    }

    private func offscreenAccessibilityRow(model: MarkdownTable, rowIndex: Int, table: MarkdownTableAccessibilityTable,
                                           revision: UInt?, selection: (NSRange, Int?)?) -> MarkdownTableAccessibilityRow {
        let row = MarkdownTableAccessibilityRow()
        row.owner = self
        row.table = table
        row.index = rowIndex
        if model.rows.indices.contains(rowIndex), let selection {
            let range = model.rows.range(at: rowIndex)
            let intersects = selection.0.length == 0
                ? selection.0.location >= range.location && selection.0.location <= NSMaxRange(range)
                : NSIntersectionRange(selection.0, range).length > 0
            if intersects { row.selected = model.rows[rowIndex].cells.contains { Self.tableCellSelected($0, selection: selection) } }
        }
        row.cellsProvider = { [weak self, weak table, weak row] in
            guard let self, let table, let row, table.isCurrent?() == true, let revision,
                  self.tableAccessibilityRevision?() == revision, model.rows.indices.contains(rowIndex) else { return [] }
            return model.rows[rowIndex].cells.compactMap { item in
                guard let cell = MarkdownTableAccessibilityCell.element(withRole: .cell, frame: .zero,
                        label: item.displayText, parent: row) as? MarkdownTableAccessibilityCell else { return nil }
                cell.isCurrent = { [weak table] in table?.isCurrent?() == true }
                cell.setAccessibilityFrameInParentSpace(.zero)
                cell.setAccessibilityRowIndexRange(NSRange(location: rowIndex, length: 1))
                cell.setAccessibilityColumnIndexRange(NSRange(location: item.column, length: 1))
                cell.setAccessibilitySelected(Self.tableCellSelected(item, selection: selection))
                cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: L10n.tr("定位")) { [weak self, weak table] in
                    guard let self, let table, table.isCurrent?() == true,
                          self.tableAccessibilityRevision?() == revision else { return false }
                    return self.tableAccessibilityRevealHandler?(item) == true
                }])
                return cell as NSAccessibilityElement
            }
        }
        return row
    }

    private static func tableCellSelected(_ cell: MarkdownTableCell, selection: (NSRange, Int?)?) -> Bool {
        guard let selection else { return false }
        if let column = selection.1 { return selection.0 == cell.range && column == cell.column }
        guard cell.virtualSeparators == 0 else { return false }
        if selection.0.length == 0 {
            return selection.0.location >= cell.range.location && selection.0.location < NSMaxRange(cell.range)
        }
        return NSIntersectionRange(selection.0, cell.range).length > 0
    }
    var indentationStyle: IndentationStyle = .spaces
    var tabWidth: Int = 4
    var editorLineSpacing: CGFloat = FoldLayoutManager.defaultLineSpacing
    private var paragraphRefreshGeneration: UInt = 0
    private var paragraphRefreshLocation = 0
    private var paragraphRefreshWorkItem: DispatchWorkItem?
    private var paragraphRefreshChunkSize = 32 * 1_024
    private var paragraphRefreshPaused = false
    private var pendingTextMetrics: (() -> Void)?
    private var compositionCompletionScheduled = false

    var editorLineHeight: CGFloat {
        (layoutManager as? FoldLayoutManager)?.editorLineHeight
            ?? ((font?.pointSize ?? 14) + editorLineSpacing)
    }


    var currentLineColor: NSColor = .lacCurrentLineBackground
    var selectionTrackingHandler: (() -> Void)?
    var compositionCompletionHandler: (() -> Void)?
    var compositionStartHandler: ((Bool) -> Void)?
    var appearanceChangedHandler: (() -> Void)?
    var paragraphStylesChangedHandler: ((NSRange) -> Void)?
    var requestsFirstResponderWhenAttached = false
    var textTransformationHandler: ((TextTransformationOperation) -> Void)?
    var diagramMenuHandler: ((NSPoint) -> [NSMenuItem])?
    var imageTransferHandler: ((MarkdownImageTransfer) -> Bool)?
    var videoTransferHandler: ((URL) -> Bool)?
    var remoteImageTransferEnabled = false
    var richPasteHandler: ((NSPasteboard) -> Bool)?
    var richCopyHandler: ((NSPasteboard) -> Bool)?
    var listIndentationHandler: ((Bool) -> Bool)?
    var listNewlineHandler: (() -> Bool)?
    var codeFenceNewlineHandler: (() -> Bool)?
    var taskCheckboxHandler: ((MarkdownTaskCheckbox) -> Bool)?
    var markdownLinkHandler: ((NSPoint) -> Bool)?
    var footnoteNavigationHandler: ((NSPoint) -> Bool)?
    var blockMathReferenceHandler: ((NSPoint) -> Bool)?
    var tableOfContentsHandler: ((NSRange, MarkdownHeading?) -> Bool)?
    var pageBreakHandler: ((NSRange) -> Bool)?
    var tableCellHandler: ((MarkdownTableCell, NSRect) -> Bool)?
    var tableAccessibilityRevision: (() -> UInt?)?
    var tableAccessibilitySelection: (() -> (NSRange, Int?)?)?
    var tableAccessibilityActionHandler: ((MarkdownTableCell, NSRect, MarkdownTableAccessibilityMove) -> Bool)?
    var tableAccessibilityRevealHandler: ((MarkdownTableCell) -> Bool)?
    var tableOutsideClickHandler: (() -> Bool)?
    var tableDragStartHandler: ((FoldLayoutManager.TableDragHandle) -> Bool)?
    var tableDragEndHandler: ((FoldLayoutManager.TableDragHandle, FoldLayoutManager.TableDragHandle?) -> Void)?
    private var pendingTableDrag: FoldLayoutManager.TableDragHandle?
    private var consumedTableMouseDown = false
    var completionText: String? { didSet { needsDisplay = true } }
    var acceptAICompletion: (() -> Bool)?
    var dismissAICompletion: (() -> Void)?
    var emojiCompletionRange: NSRange?
    var emojiCompletionSpelling = ""
    var emojiCompletionValues: [String] = []
    var acceptEmojiCompletion: ((String, NSRange) -> Bool)?
    var dismissEmojiCompletion: (() -> Void)?
    var editSource: DocumentProvenance.Source = .unknown
    var autoPairBracketsEnabled = false
    var autoPairMarkdownEnabled = false
    var autoPairAllowed: (() -> Bool)?
    var mathPairAllowed: ((NSRange) -> Bool)?
    private var autoPairs: [MarkdownAutoPairService.Pair] = []
    private var isPairInsertion = false
    private var pairKeyCharacter: String?
    var focusModeEnabled = false { didSet { if focusModeEnabled != oldValue { needsDisplay = true } } }

    override var rangeForUserCompletion: NSRange { emojiCompletionRange ?? super.rangeForUserCompletion }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard emojiCompletionRange == charRange else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        return emojiCompletionValues
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
        guard emojiCompletionRange == charRange else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
            return
        }
        if isFinal {
            _ = acceptEmojiCompletion?(word, charRange)
            dismissEmojiCompletion?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if focusModeEnabled && !hasMarkedText() {
            backgroundColor.withAlphaComponent(0.65).setFill()
            for rect in focusDimmedRects(in: dirtyRect) { rect.fill() }
        }
        guard let completionText, !completionText.isEmpty, let window,
              !hasMarkedText(), selectedRange().length == 0 else { return }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: screenRect.minX, y: screenRect.maxY))
        let point = convert(windowPoint, from: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (completionText as NSString).draw(at: point, withAttributes: attributes)
    }

    func focusDimmedRects(in dirtyRect: NSRect) -> [NSRect] {
        guard focusModeEnabled, let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return [] }
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.location <= storage.length,
              selection.length <= storage.length - selection.location else { return [] }
        let text = storage.mutableString
        let active = text.paragraphRange(for: selection)
        let visible = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        var rectangles: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard NSIntersectionRange(characters, active).length == 0 else { return }
            let clipped = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).intersection(dirtyRect)
            if !clipped.isEmpty { rectangles.append(clipped) }
        }
        return rectangles
    }

    func imageTransfer(from pasteboard: NSPasteboard, preferText: Bool = false) -> MarkdownImageTransfer? {
        if preferText && pasteboard.string(forType: .string) != nil { return nil }
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.count == 1, let type = UTType(filenameExtension: files[0].pathExtension), type.conforms(to: .image) {
            return .file(files[0])
        }
        guard files.isEmpty else { return nil }
        let plainText = pasteboard.string(forType: .string)
        if plainText == nil, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return .data(data) }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        if remoteImageTransferEnabled, urls.count == 1, ["http", "https"].contains(urls[0].scheme?.lowercased() ?? ""), urls[0].host != nil,
           plainText == nil || (!preferText && plainText == urls[0].absoluteString) {
            return .remote(urls[0])
        }
        return nil
    }

    func videoTransfer(from pasteboard: NSPasteboard) -> URL? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard files.count == 1, let type = UTType(filenameExtension: files[0].pathExtension), type.conforms(to: .movie) else { return nil }
        return files[0]
    }

    override func paste(_ sender: Any?) {
        dismissAICompletion?()
        if richPasteHandler?(.general) == true { return }
        if isEditable, !hasMarkedText(), let transfer = imageTransfer(from: .general, preferText: true), imageTransferHandler?(transfer) == true { return }
        let previous = editSource
        editSource = .pasted
        defer { editSource = previous }
        super.paste(sender)
    }

    override func copy(_ sender: Any?) {
        if richCopyHandler?(.general) == true { return }
        super.copy(sender)
    }

    /// NSTextView normally reports the fallback font used by the first glyph.
    /// When a document starts with Chinese, that can be PingFang even though
    /// the requested editor font is Menlo. Always expose the requested font so
    /// typing and tab metrics cannot change with the first character.
    override var font: NSFont? {
        get {
            (layoutManager as? FoldLayoutManager)?.textFont ?? super.font
        }
        set {
            guard let newValue else { return }
            (layoutManager as? FoldLayoutManager)?.textFont = newValue
            super.font = newValue
            typingAttributes[.font] = newValue
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, pendingTableDrag != nil {
            cancelTableDrag()
            return
        }
        if hasMarkedText() { super.keyDown(with: event); return }
        if event.keyCode == 53, completionText != nil { dismissAICompletion?(); return }
        if event.keyCode == 53, emojiCompletionRange != nil {
            super.keyDown(with: event)
            dismissEmojiCompletion?()
            return
        }
        if event.keyCode == 48, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           !hasMarkedText(), acceptAICompletion?() == true { return }
        if event.keyCode == 48, emojiCompletionRange != nil {
            super.keyDown(with: event)
            return
        }
        // Handle the physical Tab key before AppKit applies its paragraph
        // indentation command. This is especially important at column zero.
        if event.keyCode == 48, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            if listIndentationHandler?(false) == true { return }
            insertTab(nil)
            return
        }
        if event.keyCode == 48, event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if listIndentationHandler?(true) == true { return }
            insertBacktab(nil)
            return
        }
        let previousPairKeyCharacter = pairKeyCharacter
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        pairKeyCharacter = modifiers.isEmpty && event.characters?.utf16.count == 1 ? event.characters : nil
        defer { pairKeyCharacter = previousPairKeyCharacter }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        consumedTableMouseDown = false
        if let layout = layoutManager as? FoldLayoutManager, let container = textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            if let handle = layout.tableDragHandle(at: location, in: container) {
                consumedTableMouseDown = true
                if tableDragStartHandler?(handle) == true { pendingTableDrag = handle }
                return
            }
            if let (cell, frame) = layout.markdownTableCellInfo(at: location, in: container) {
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    if blockMathReferenceHandler?(point) == true { return }
                    if markdownLinkHandler?(point) == true { return }
                }
                if tableCellHandler?(cell, frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)) == true { return }
            }
            if tableOutsideClickHandler?() == true { return }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                if footnoteNavigationHandler?(point) == true { return }
                if blockMathReferenceHandler?(point) == true { return }
                if markdownLinkHandler?(point) == true { return }
            }
            if let checkbox = layout.markdownTaskCheckbox(at: location, in: container),
               let taskCheckboxHandler {
                _ = taskCheckboxHandler(checkbox)
                return
            }
            if let character = layout.uppercaseHeadingSourcePosition(at: location, in: container) {
                guard let window, let storage = textStorage else {
                    super.mouseDown(with: event)
                    return
                }
                window.makeFirstResponder(self)
                let line = storage.mutableString.lineRange(for: NSRange(location: character, length: 0))
                layout.updateMarkdownRevealedRange(line)
                layout.ensureLayout(forCharacterRange: line)
                let caret = firstRect(forCharacterRange: NSRange(location: character, length: 0), actualRange: nil)
                guard caret.height > 0, caret.minX.isFinite, caret.minY.isFinite else {
                    super.mouseDown(with: event)
                    return
                }
                let target = window.convertPoint(fromScreen: NSPoint(x: caret.midX, y: caret.midY))
                guard let translated = NSEvent.mouseEvent(with: .leftMouseDown, location: target,
                    modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: window.windowNumber,
                    context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) else {
                    super.mouseDown(with: event)
                    return
                }
                super.mouseDown(with: translated)
                return
            }
            if let character = layout.markdownImageLocation(at: location, in: container) {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: character, length: 0))
                return
            }
            if let range = layout.markdownPageBreak(at: location, in: container), pageBreakHandler?(range) == true { return }
            if let entry = layout.markdownTOC(at: location, in: container),
               tableOfContentsHandler?(entry.range, entry.heading) == true { return }
        } else {
            if tableOutsideClickHandler?() == true { return }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                let point = convert(event.locationInWindow, from: nil)
                if footnoteNavigationHandler?(point) == true { return }
                if markdownLinkHandler?(point) == true { return }
            }
        }
        // TextKit represents a final empty line (the line after a trailing
        // newline) as an extra line fragment without a character range. Its
        // default hit testing maps clicks in that fragment back to the
        // preceding newline, which makes the last visible line impossible to
        // place the caret in from the editor area. Treat the fragment as the
        // document-end insertion point before falling back to AppKit.
        if let layoutManager,
           let storage = textStorage,
           storage.length > 0,
           storage.mutableString.character(at: storage.length - 1)
                == 10,
           !layoutManager.extraLineFragmentRect.isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            var extraRect = layoutManager.extraLineFragmentRect
            extraRect.origin.x += textContainerOrigin.x
            extraRect.origin.y += textContainerOrigin.y
            extraRect.size.width = max(bounds.width, extraRect.width)
            if extraRect.insetBy(dx: 0, dy: -2).contains(point) {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: storage.length, length: 0))
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if pendingTableDrag != nil { return }
        super.mouseDragged(with: event)
    }

    func cancelTableDrag() {
        guard let start = pendingTableDrag else { return }
        pendingTableDrag = nil
        tableDragEndHandler?(start, nil)
    }

    override func mouseUp(with event: NSEvent) {
        if consumedTableMouseDown && pendingTableDrag == nil { consumedTableMouseDown = false; return }
        guard let start = pendingTableDrag else { super.mouseUp(with: event); return }
        pendingTableDrag = nil
        consumedTableMouseDown = false
        let point = convert(event.locationInWindow, from: nil)
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let target = (layoutManager as? FoldLayoutManager).flatMap { layout in
            textContainer.flatMap { layout.tableDragTarget(at: location, in: $0, axis: start.axis) }
        }
        tableDragEndHandler?(start, target)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isEditable, !hasMarkedText(), imageTransferHandler != nil, imageTransfer(from: sender.draggingPasteboard) != nil { return .copy }
        if isEditable, !hasMarkedText(), videoTransferHandler != nil, videoTransfer(from: sender.draggingPasteboard) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable, !hasMarkedText() else { return super.performDragOperation(sender) }
        let transfer = imageTransfer(from: sender.draggingPasteboard)
        let video: URL?
        if case nil = transfer { video = videoTransfer(from: sender.draggingPasteboard) } else { video = nil }
        guard transfer.map({ _ in imageTransferHandler != nil }) ?? (video != nil && videoTransferHandler != nil) else { return super.performDragOperation(sender) }
        let previous = selectedRange()
        let point = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: location, length: 0))
        if let transfer, imageTransferHandler?(transfer) == true { return true }
        if let video, videoTransferHandler?(video) == true { return true }
        setSelectedRange(previous)
        if video != nil { return false }
        return super.performDragOperation(sender)
    }

    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        if isEditable {
            registerForDraggedTypes(Array(Set(readablePasteboardTypes + [.fileURL, .URL, .png, .tiff])))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDragTypeRegistration()
        guard requestsFirstResponderWhenAttached,
              let window else { return }
        window.makeFirstResponder(self)
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting flag: Bool
    ) {
        super.setSelectedRange(
            charRange,
            affinity: affinity,
            stillSelecting: flag
        )
        if flag {
            selectionTrackingHandler?()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChangedHandler?()
        needsDisplay = true
        if let layoutManager {
            layoutManager.invalidateDisplay(
                forCharacterRange: NSRange(
                    location: 0,
                    length: textStorage?.length ?? 0
                )
            )
        }
    }

    override func prepareContent(in rect: NSRect) {
        // NSView's documented way to suppress responsive-scrolling overdraw.
        // Large TextKit documents already prefetch one viewport after idle;
        // preparing AppKit's larger speculative rect duplicates that work.
        if EditorLayoutPolicy.usesViewportLayout(textLength: textStorage?.length ?? 0) {
            super.prepareContent(in: visibleRect)
        } else {
            super.prepareContent(in: rect)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager,
              textContainer != nil,
              let text = textStorage?.mutableString else { return }
        let location = min(selectedRange().location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: lineRange,
            actualCharacterRange: nil
        )
        var lineRects: [NSRect] = []
        if glyphRange.length == 0, location == text.length {
            var lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty {
                lineRect = NSRect(x: 0, y: textContainerInset.height, width: bounds.width, height: editorLineHeight)
            }
            lineRects.append(lineRect)
        } else {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect,
                _,
                _,
                _,
                _ in
                lineRects.append(lineRect)
            }
        }
        currentLineColor.setFill()
        for var lineRect in lineRects {
            lineRect.origin.x = 0
            lineRect.origin.y += textContainerOrigin.y
            lineRect.size.width = bounds.width
            lineRect.intersection(rect).fill()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let diagramItems = diagramMenuHandler?(convert(event.locationInWindow, from: nil)) ?? []
        if !diagramItems.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            diagramItems.forEach { menu.addItem($0) }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        let root = NSMenuItem(
            title: L10n.tr("编码与解码"),
            action: nil,
            keyEquivalent: ""
        )
        root.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: L10n.tr("编码与解码")
        )
        let submenu = NSMenu(title: L10n.tr("编码与解码"))
        if let text = textStorage?.mutableString,
           let candidate = TextCodecService.candidate(
               in: text,
               selection: selectedRange(),
               allowsTokenAtCaret: true,
               maximumLength: TextCodecService.automaticDetectionLimit
           ),
           let detection = TextCodecService.detect(
               in: candidate.text,
               allowsBase64: selectedRange().length > 0
           ) {
            submenu.addItem(transformationMenuItem(
                L10n.tr("智能解码（%@）", L10n.tr(detection.kind.rawValue)),
                operation: .smartDecode
            ))
            submenu.addItem(.separator())
        }

        submenu.addItem(categoryMenuItem(
            title: "URL",
            operations: [.urlEncodeComponent, .urlDecode, .formURLDecode]
        ))
        submenu.addItem(categoryMenuItem(
            title: "Base64",
            operations: [
                .base64Encode, .base64Decode,
                .base64URLEncode, .base64URLDecode
            ]
        ))
        submenu.addItem(categoryMenuItem(
            title: L10n.tr("HTML 实体"),
            operations: [.htmlEncode, .htmlDecode]
        ))
        submenu.addItem(categoryMenuItem(
            title: L10n.tr("Unicode/JSON 转义"),
            operations: [.unicodeEncode, .unicodeDecode]
        ))
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    @objc
    private func performTextTransformation(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let operation = TextTransformationOperation(rawValue: rawValue) else { return }
        textTransformationHandler?(operation)
    }

    private func categoryMenuItem(
        title: String,
        operations: [TextTransformationOperation]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        operations.forEach {
            submenu.addItem(transformationMenuItem($0.title, operation: $0))
        }
        item.submenu = submenu
        return item
    }

    private func transformationMenuItem(
        _ title: String,
        operation: TextTransformationOperation
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performTextTransformation(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = operation.rawValue
        return item
    }

    override func insertTab(_ sender: Any?) {
        let indentation = indentationStyle == .tabs
            ? "\t"
            : String(repeating: " ", count: tabWidth)
        let range = selectedRange()
        // Replace directly instead of routing through AppKit's tab command,
        // which may briefly apply its own paragraph indentation at column 0.
        replaceCharacters(in: range, with: indentation)
        setSelectedRange(NSRange(
            location: range.location + (indentation as NSString).length,
            length: 0
        ))
    }

    override func doCommand(by selector: Selector) {
        if hasMarkedText() { super.doCommand(by: selector); return }
        // NSTextView may dispatch Tab through the command chain as well as
        // insertTab(_:). Handle it exactly once to avoid the visible bounce.
        if selector == #selector(insertTab(_:)) {
            if listIndentationHandler?(false) == true { return }
            insertTab(nil)
            return
        }
        if selector == #selector(insertBacktab(_:)) {
            if listIndentationHandler?(true) == true { return }
            insertBacktab(nil)
            return
        }
        super.doCommand(by: selector)
    }

    override func insertBacktab(_ sender: Any?) {
        let range = selectedRange()
        guard range.length == 0, range.location > 0,
              let text = textStorage?.string as NSString? else {
            super.insertBacktab(sender)
            return
        }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let beforeCaret = NSRange(location: line.location, length: range.location - line.location)
        let prefix = text.substring(with: beforeCaret)
        let removeCount: Int
        if prefix.hasSuffix("\t") {
            removeCount = 1
        } else {
            removeCount = min(tabWidth, prefix.reversed().prefix { $0 == " " }.count)
        }
        guard removeCount > 0 else { return }
        replaceCharacters(in: NSRange(
            location: range.location - removeCount,
            length: removeCount
        ), with: "")
        setSelectedRange(NSRange(location: range.location - removeCount, length: 0))
    }

    func configureTabStops() {
        let paragraphStyle = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let displayFont = self.font ?? lacEditorFont(size: 14)
        let width = displayFont.maximumAdvancement.width * CGFloat(tabWidth)
        paragraphStyle.defaultTabInterval = width
        paragraphStyle.tabStops = []
        // The layout manager is the sole owner of line height. Paragraph-level
        // min/max heights are intentionally cleared because input methods can
        // replace the first run's font during composition.
        paragraphStyle.minimumLineHeight = 0
        paragraphStyle.maximumLineHeight = 0
        paragraphStyle.lineHeightMultiple = 1
        paragraphStyle.lineSpacing = 0
        typingAttributes[.font] = displayFont
        typingAttributes[.foregroundColor] = NSColor.labelColor
        typingAttributes[.paragraphStyle] = paragraphStyle
        defaultParagraphStyle = paragraphStyle
        enclosingScrollView?.lineScroll = editorLineHeight
    }

    func applyOrDeferTextMetrics(_ update: (() -> Void)?) {
        pendingTextMetrics = update
        if !hasMarkedText() {
            pendingTextMetrics = nil
            update?()
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        pairKeyCharacter = nil
        dismissEmojiCompletion?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionStartHandler?(hasMarkedText())
        resumeAfterComposition(wasMarked: wasMarked)
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        super.unmarkText()
        resumeAfterComposition(wasMarked: wasMarked)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        dismissAICompletion?()
        let wasMarked = hasMarkedText()
        let previous = editSource
        if editSource == .unknown { editSource = .typed }
        defer { editSource = previous }
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if !wasMarked, previous == .unknown, isEditable, selectedRanges.count == 1,
           autoPairAllowed?() == true, let storage = textStorage,
           let character = insertString as? String, character == pairKeyCharacter,
           let action = MarkdownAutoPairService.action(in: storage.mutableString, selection: selection, character: character,
                                                        brackets: autoPairBracketsEnabled, markdown: autoPairMarkdownEnabled, pairs: autoPairs) {
            switch action {
            case let .skip(location):
                setSelectedRange(NSRange(location: location, length: 0))
                return
            case let .replace(range, replacement, finalSelection, pair):
                if character == "$" && mathPairAllowed?(range) != true { break }
                let oldLength = storage.length
                shiftAutoPairs(replacing: range, inserted: (replacement as NSString).length)
                autoPairs.append(pair)
                breakUndoCoalescing()
                isPairInsertion = true
                super.insertText(replacement, replacementRange: range)
                isPairInsertion = false
                if storage.length == oldLength - range.length + (replacement as NSString).length,
                   NSMaxRange(finalSelection) <= storage.length,
                   storage.mutableString.substring(with: NSRange(location: range.location, length: (replacement as NSString).length)) == replacement {
                    setSelectedRange(finalSelection)
                } else { autoPairs.removeAll() }
                breakUndoCoalescing()
                return
            }
        }
        if !wasMarked, previous == .unknown, autoPairAllowed?() == true,
           let replacement = insertString as? String, replacement == pairKeyCharacter {
            shiftAutoPairs(replacing: selection, inserted: (replacement as NSString).length)
            isPairInsertion = true
            super.insertText(insertString, replacementRange: replacementRange)
            isPairInsertion = false
        } else {
            autoPairs.removeAll()
            super.insertText(insertString, replacementRange: replacementRange)
        }
        resumeAfterComposition(wasMarked: wasMarked)
    }

    override func didChangeText() {
        if !isPairInsertion { autoPairs.removeAll() }
        super.didChangeText()
    }

    private func shiftAutoPairs(replacing range: NSRange, inserted: Int) {
        guard range.location != NSNotFound else { autoPairs.removeAll(); return }
        let delta = inserted - range.length
        autoPairs = autoPairs.compactMap { pair in
            var pair = pair
            if NSMaxRange(range) <= pair.open {
                pair.open += delta
                pair.close += delta
            } else if range.location >= pair.open + pair.count && NSMaxRange(range) <= pair.close {
                pair.close += delta
            } else if range.location < pair.close + pair.count && NSMaxRange(range) > pair.open {
                return nil
            }
            return pair
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), isEditable, selection.length == 0, selectedRanges.count == 1,
           autoPairAllowed?() == true, let storage = textStorage,
           let pair = autoPairs.last(where: { $0.close == selection.location && $0.open + $0.count == $0.close }),
           pair.close + pair.count <= storage.length,
           (pair.opener == 40 || pair.opener == 91 || pair.opener == 123 || pair.opener == 34 || pair.opener == 39 ? autoPairBracketsEnabled : autoPairMarkdownEnabled) {
            let opening = String(UnicodeScalar(pair.opener)!), closing = String(UnicodeScalar(pair.closer)!)
            if storage.mutableString.substring(with: NSRange(location: pair.open, length: pair.count)) == String(repeating: opening, count: pair.count),
               storage.mutableString.substring(with: NSRange(location: pair.close, length: pair.count)) == String(repeating: closing, count: pair.count) {
                let range = NSRange(location: pair.open + pair.count - 1, length: 2)
                shiftAutoPairs(replacing: range, inserted: 0)
                if pair.count > 1 {
                    autoPairs.append(MarkdownAutoPairService.Pair(open: pair.open, close: pair.close - 1, opener: pair.opener, closer: pair.closer, count: pair.count - 1))
                }
                breakUndoCoalescing()
                isPairInsertion = true
                super.insertText("", replacementRange: range)
                isPairInsertion = false
                setSelectedRange(NSRange(location: range.location, length: 0))
                breakUndoCoalescing()
                return
            }
        }
        autoPairs.removeAll()
        super.deleteBackward(sender)
    }

    private func resumeAfterComposition(wasMarked: Bool) {
        if wasMarked && !hasMarkedText() && !compositionCompletionScheduled {
            compositionCompletionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.compositionCompletionScheduled = false
                if !self.hasMarkedText() { self.compositionCompletionHandler?() }
            }
        }
        guard pendingTextMetrics != nil || paragraphRefreshPaused else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !hasMarkedText() else { return }
            let update = pendingTextMetrics
            pendingTextMetrics = nil
            update?()
            if paragraphRefreshPaused {
                paragraphRefreshPaused = false
                applyParagraphStyleChunk(
                    generation: paragraphRefreshGeneration,
                    chunkSize: paragraphRefreshChunkSize
                )
            }
        }
    }

    /// Apply paragraph attributes in cancellable chunks so large documents do
    /// not block typing and window resizing for one long main-thread turn.
    func scheduleParagraphStyleRefresh(chunkSize: Int = 32 * 1_024) {
        paragraphRefreshWorkItem?.cancel()
        paragraphRefreshGeneration &+= 1
        paragraphRefreshLocation = 0
        paragraphRefreshChunkSize = chunkSize
        paragraphRefreshPaused = false
        let generation = paragraphRefreshGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.applyParagraphStyleChunk(
                generation: generation,
                chunkSize: chunkSize
            )
        }
        paragraphRefreshWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func applyParagraphStyleChunk(
        generation: UInt,
        chunkSize: Int
    ) {
        guard generation == paragraphRefreshGeneration else { return }
        if hasMarkedText() {
            paragraphRefreshWorkItem = nil
            paragraphRefreshPaused = true
            paragraphRefreshLocation = 0
            return
        }
        guard
              paragraphRefreshWorkItem?.isCancelled != true,
              let storage = textStorage,
              let style = defaultParagraphStyle,
              storage.length > 0 else {
            paragraphRefreshWorkItem = nil
            return
        }
        let start = min(paragraphRefreshLocation, storage.length)
        let end = min(storage.length, start + max(1, chunkSize))
        guard end > start else {
            paragraphRefreshWorkItem = nil
            return
        }
        storage.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: start, length: end - start)
        )
        paragraphStylesChangedHandler?(NSRange(location: start, length: end - start))
        paragraphRefreshLocation = end
        if end < storage.length {
            let next = DispatchWorkItem { [weak self] in
                self?.applyParagraphStyleChunk(
                    generation: generation,
                    chunkSize: chunkSize
                )
            }
            paragraphRefreshWorkItem = next
            DispatchQueue.main.async(execute: next)
        } else {
            paragraphRefreshWorkItem = nil
        }
    }

    func cancelParagraphStyleRefresh() {
        paragraphRefreshWorkItem?.cancel()
        paragraphRefreshWorkItem = nil
        paragraphRefreshGeneration &+= 1
        paragraphRefreshPaused = false
    }

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() || !isEditable {
            super.insertNewline(sender)
            return
        }
        if codeFenceNewlineHandler?() == true { return }
        if listNewlineHandler?() == true { return }
        guard let nsString = textStorage?.mutableString else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let lineRange = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
        let linePrefix = nsString.substring(with: NSRange(
            location: lineRange.location,
            length: max(0, min(selection.location - lineRange.location, lineRange.length))
        ))
        let indentation = String(linePrefix.prefix { $0 == " " || $0 == "\t" })
        let trimmed = linePrefix.trimmingCharacters(in: .whitespaces)
        let continuation = trimmed.hasSuffix("{") || trimmed.hasSuffix("[") ? indentationUnit : ""
        insertText("\n\(indentation)\(continuation)", replacementRange: selection)
    }

    private var indentationUnit: String {
        indentationStyle == .tabs ? "\t" : String(repeating: " ", count: tabWidth)
    }
}

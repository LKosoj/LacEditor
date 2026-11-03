import AppKit

/// Временное подчёркивание замечания по стилю. Диапазон — UTF-16 в координатах исходника.
struct StyleMark: Equatable {
    let range: NSRange
    let source: FindingSource     // .rule — точечное, .ai — штриховое подчёркивание
}

extension EditorCommandNotification {
    static let styleMarks = Notification.Name("LacEditor.styleMarks")
}

/// Пустой список снимает подчёркивания стиля.
final class StyleMarksRequest {
    let documentID: UUID
    let textRevision: UInt
    let marks: [StyleMark]

    init(documentID: UUID, textRevision: UInt, marks: [StyleMark]) {
        self.documentID = documentID
        self.textRevision = textRevision
        self.marks = marks
    }
}

/// Хранит последние метки и наложенные временные атрибуты менеджера раскладки.
/// В `textStorage` ничего не пишется: метки не попадают в undo, предпросмотр, экспорт и копирование.
final class StyleMarksPainter {
    private(set) var marks: [StyleMark] = []
    private var revision: UInt?
    private var applied: [NSRange] = []
    private var appliedVisible: NSRange?
    private var isDirty = false

    func set(_ marks: [StyleMark], revision: UInt) {
        self.marks = marks.sorted { $0.range.location < $1.range.location }
        self.revision = revision
        isDirty = true
    }

    /// Оформление Markdown могло снять подчёркивание: следующий `refresh` накладывает метки заново.
    func reapply() { isDirty = true }

    func clear(in layoutManager: NSLayoutManager, length: Int) {
        removeApplied(in: layoutManager, length: length)
        marks = []
        revision = nil
    }

    /// `map` — карта токенов координатора, `visible` — видимый участок на экране. Атрибуты накладываются только в нём.
    func refresh(in layoutManager: NSLayoutManager, visible: NSRange?, map: MarkdownMediaMap, length: Int,
                 currentRevision: UInt, hasPendingLiveEdits: Bool, hasMarkedText: Bool) {
        guard let revision, revision == currentRevision, !hasPendingLiveEdits, !hasMarkedText,
              !marks.isEmpty, let visible else {
            removeApplied(in: layoutManager, length: length)
            return
        }
        if !isDirty, visible == appliedVisible { return }
        removeApplied(in: layoutManager, length: length)
        isDirty = false
        let fileVisible = map.sourceRange(forDisplay: visible)
        // Метки сортированы по началу и могут вкладываться: ищем по началу с запасом в самую длинную метку.
        let longest = marks.map(\.range.length).max() ?? 0
        var low = 0, high = marks.count
        while low < high {
            let mid = (low + high) / 2
            if marks[mid].range.location < fileVisible.location - longest { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < marks.count, marks[index].range.location < NSMaxRange(fileVisible) {
            let mark = marks[index]
            index += 1
            guard NSMaxRange(mark.range) > fileVisible.location else { continue }
            let range = map.displayRange(forSource: mark.range)
            if range.length > 0, NSMaxRange(range) <= length {
                let pattern: NSUnderlineStyle = mark.source == .rule ? .patternDot : .patternDash
                layoutManager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.union(pattern).rawValue,
                                                    forCharacterRange: range)
                layoutManager.addTemporaryAttribute(.underlineColor,
                                                    value: mark.source == .rule ? NSColor.lacStyleRuleUnderline : NSColor.lacStyleAIUnderline,
                                                    forCharacterRange: range)
                applied.append(range)
            }
        }
        appliedVisible = visible
    }

    private func removeApplied(in layoutManager: NSLayoutManager, length: Int) {
        guard !applied.isEmpty || appliedVisible != nil else { return }
        let cleared = applied
        applied.removeAll(keepingCapacity: true)
        appliedVisible = nil
        for range in cleared where NSMaxRange(range) <= length {
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
    }
}

extension NSColor {
    /// Подчёркивание локальных правил (оранжевый, не красный: красный — орфография); контраст к `lacEditorBackground` не ниже 4,5:1.
    static let lacStyleRuleUnderline = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.35, alpha: 1)
            : NSColor(calibratedRed: 0.60, green: 0.30, blue: 0.0, alpha: 1)
    }

    /// Подчёркивание замечаний AI (фиолетовый); контраст к `lacEditorBackground` не ниже 4,5:1.
    static let lacStyleAIUnderline = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.78, green: 0.65, blue: 1.0, alpha: 1)
            : NSColor(calibratedRed: 0.45, green: 0.22, blue: 0.75, alpha: 1)
    }
}

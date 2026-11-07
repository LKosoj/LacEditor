import Foundation

/// Соответствие «текст редактора ↔ видимый текст».
/// Текст редактора — строка `NSTextStorage` (с токенами media), видимый — то, что пользователь видит после скрытия маркеров и замен.
/// Карта строится из полей `MarkdownPresentation` и хранит только нетривиальные записи (скрытые символы и замены); остальной текст идёт 1 к 1.
/// Все диапазоны — UTF-16. Не входят в карту: сворачивание, заглавные буквы заголовков, номера заголовков, `looseIndents`, `separatorAfter`
/// (меняют только геометрию), marked text (во время композиции слой ничего не скрывает — вызывающий берёт `identity`).
/// Таблица в видимом тексте — склейка `displayText` ячеек без разделителей и переводов строк между строками.
struct MarkdownDisplayMap: Equatable, Sendable {
    /// `checkbox` - логическая единица для выделения и правки: глифы `[ ]` в слое не скрываются, а рисуются поверх, так что это не точное описание глифов.
    enum Replacement: Equatable, Sendable {
        case blockImage, inlineImage, checkbox, blockFormula, inlineFormula, emoji, diagram
        case embeddedBlock, ruby, pageBreak, tableOfContents, listMarker, typography, mediaLabel, tableCell
    }

    enum Kind: Equatable, Sendable {
        /// Нулевые глифы: маркеры оформления.
        case hiddenMarker
        /// Скрытое внутри таблицы: разделители и строка-делитель.
        case tableStructure
        case replacement(Replacement)
    }

    struct Entry: Equatable, Sendable {
        /// Диапазон в тексте редактора, `length > 0`.
        let source: NSRange
        /// Позиция записи в видимом тексте.
        let displayStart: Int
        /// У скрытых — 0.
        let displayLength: Int
        let kind: Kind
        /// Элемент-владелец: для таблицы — вся таблица, для скрытого маркера — элемент разметки, для замены — она сама.
        let owner: NSRange
        /// Маркер inline-элемента (strong, emphasis, code, link…): раскрывается по выделению, а не по строке.
        var isInline = false
        /// Диапазон, по которому считается раскрытие, если он не совпадает с `owner` (у цитаты владелец — сам маркер, раскрытие по абзацу цитаты).
        var revealOwner: NSRange? = nil
        var displayEnd: Int { displayStart + displayLength }
    }

    /// Кандидат до нормализации; также точка входа для тестов без разбора.
    struct Candidate: Equatable, Sendable {
        var source: NSRange
        var kind: Kind
        var displayLength: Int
        var owner: NSRange
        var isInline = false
        var revealOwner: NSRange? = nil
    }

    /// Токен media в тексте редактора, который рисуется подписью «… 12 КБ».
    struct MediaLabel: Equatable, Sendable {
        let range: NSRange
        let displayLength: Int
    }

    /// Раскрытие маркеров: те же диапазоны, что держит `FoldLayoutManager`. Без него все маркеры скрыты.
    struct Reveal: Equatable, Sendable {
        var revealedRange: NSRange? = nil
        var inlineSelection: NSRange? = nil
        /// Выделение: непустое и задевающее чекбокс убирает его замену.
        var selection: NSRange? = nil
        static let none = Reveal()

        /// Копия `FoldLayoutManager.touches`: пустой диапазон касается включительно, непустой — пересечением длины > 0.
        static func touches(_ owner: NSRange, _ revealed: NSRange?) -> Bool {
            guard let revealed else { return false }
            if revealed.length == 0 { return revealed.location >= owner.location && revealed.location <= NSMaxRange(owner) }
            return NSIntersectionRange(owner, revealed).length > 0
        }

        /// Скрыта ли запись при этом раскрытии: то же правило, что у конструктора карты и `FoldLayoutManager.isMarkdownMarkerHidden`.
        /// Карта с `Reveal.none` содержит все маркеры; какие из них видны сейчас, решает этот метод.
        func hides(_ entry: Entry) -> Bool {
            guard entry.kind == .hiddenMarker else { return false }
            return !Self.touches(entry.revealOwner ?? entry.owner, entry.isInline ? (inlineSelection ?? revealedRange) : revealedRange)
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case outOfBounds
        /// У замены нет внутренних позиций.
        case insideReplacement(NSRange)
        /// Позиция строго внутри участка, где позиции cmark не подтверждены.
        case unreliableRegion(NSRange)
    }

    /// К какому краю цепочки скрытых символов относится позиция видимого текста.
    enum Affinity: Equatable, Sendable { case leading, trailing }
    /// `tight` — самый узкий исходный диапазон (без маркеров по краям), `covering` — с примыкающими маркерами.
    enum Coverage: Equatable, Sendable { case tight, covering }
    /// Что делать с позицией внутри замены.
    enum Interior: Equatable, Sendable { case fail, snapDown, snapUp }

    enum Restriction: Equatable, Sendable {
        case outOfBounds
        case insideHiddenSyntax(owner: NSRange)
        case insideReplacement(Replacement, NSRange)
        /// Таблица правится только через редактор ячейки.
        case tableCell(table: NSRange)
        /// Выделение захватило не все маркеры элемента.
        case splitsElement(owner: NSRange)
        case unreliableRegion(NSRange)
    }

    enum Editability: Equatable, Sendable {
        case allowed
        case forbidden(Restriction)
    }

    /// Элемент разметки с собственными маркерами: индексы его записей в `entries` и объемлющий владелец.
    struct OwnerNode: Equatable, Sendable {
        let range: NSRange
        let indices: [Int]
        let parent: Int
    }

    let sourceLength: Int
    let displayLength: Int
    let entries: [Entry]
    /// Отсортированные слитые участки; позиции на их границах надёжны, строго внутри — нет.
    let unreliable: [NSRange]
    private let owners: [OwnerNode]
    private let tables: [NSRange]

    // MARK: Построение

    init(presentation: MarkdownPresentation, textLength: Int, reveal: Reveal = .none,
         mediaLabels: [MediaLabel] = [],
         listMarkerLength: (MarkdownListMarker) -> Int = { $0.text.utf16.count },
         isReplacementShown: (Replacement, NSRange) -> Bool = { _, _ in true }) {
        var candidates: [Candidate] = []
        var unreliable = presentation.unreliableRanges
        func add(_ range: NSRange, _ kind: Kind, _ length: Int, owner: NSRange? = nil, inline: Bool = false, revealOwner: NSRange? = nil) {
            guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                  NSMaxRange(range) <= textLength else { return }
            candidates.append(Candidate(source: range, kind: kind, displayLength: length, owner: owner ?? range,
                                        isInline: inline, revealOwner: revealOwner))
        }
        // Картинки слоя: запись есть, пока картинка установлена.
        func image(_ kind: Replacement, _ range: NSRange) {
            if isReplacementShown(kind, range) { add(range, .replacement(kind), 1) }
        }
        for span in presentation.spans {
            let inline: Bool
            switch span.kind {
            case .strong, .emphasis, .strikethrough, .code, .keyboard, .link, .highlight, .subscriptText, .superscriptText, .underline, .inlineStyle, .critic, .obsidianComment: inline = true
            default: inline = false
            }
            if Reveal.touches(span.range, inline ? (reveal.inlineSelection ?? reveal.revealedRange) : reveal.revealedRange) { continue }
            var isQuote = false
            if case .quote = span.kind { isQuote = true }
            for marker in span.markerRanges {
                add(marker, .hiddenMarker, 0, owner: isQuote ? marker : span.range, inline: inline, revealOwner: isQuote ? span.range : nil)
            }
        }
        for item in presentation.textReplacements where !Reveal.touches(item.range, reveal.inlineSelection) {
            add(item.range, .replacement(.typography), item.text.utf16.count)
        }
        for marker in presentation.listMarkers where !Reveal.touches(marker.line, reveal.revealedRange) {
            add(marker.range, .replacement(.listMarker), listMarkerLength(marker))
        }
        for box in presentation.taskCheckboxes {
            if let selection = reveal.selection, selection.length > 0, NSIntersectionRange(selection, box.markerRange).length > 0 { continue }
            add(box.markerRange, .replacement(.checkbox), 1)
        }
        for item in presentation.images { image(item.isInline ? .inlineImage : .blockImage, item.isInline ? item.range : item.paragraphRange) }
        for item in presentation.formulas { image(.blockFormula, item.range) }
        for item in presentation.inlineFormulas { image(.inlineFormula, item.range) }
        for item in presentation.diagrams { image(.diagram, item.range) }
        if presentation.emojiCandidatesIncluded { for item in presentation.emojiCandidates { image(.emoji, item.range) } }
        for item in presentation.ruby { image(.ruby, item.range) }
        for item in presentation.audioBlocks { image(.embeddedBlock, item.range) }
        for item in presentation.iframeBlocks { image(.embeddedBlock, item.range) }
        for item in presentation.detailsBlocks { image(.embeddedBlock, item.range) }
        for item in presentation.htmlBlocks { image(.embeddedBlock, item.range) }
        for range in presentation.pageBreaks { add(range, .replacement(.pageBreak), 1) }
        if !presentation.headings.isEmpty { for range in presentation.tableOfContents { add(range, .replacement(.tableOfContents), 1) } }
        for label in mediaLabels { add(label.range, .replacement(.mediaLabel), label.displayLength) }
        for table in presentation.tables where table.range.length > 0 && table.range.location >= 0 && NSMaxRange(table.range) <= textLength {
            var cells: [MarkdownTableCell] = []
            for row in table.rows { cells.append(contentsOf: row.cells.filter { $0.range.length > 0 }) }
            cells.sort { $0.range.location < $1.range.location }
            var cursor = table.range.location
            var sound = true
            for cell in cells {
                if cell.range.location < cursor || NSMaxRange(cell.range) > NSMaxRange(table.range) { sound = false; break }
                cursor = NSMaxRange(cell.range)
            }
            if !sound || cells.isEmpty {
                // Ячейки не лежат по порядку внутри таблицы: разбирать нечем, вся таблица — одна скрытая запись.
                if !sound { unreliable.append(table.range) }
                add(table.range, .tableStructure, 0, owner: table.range)
                continue
            }
            cursor = table.range.location
            for cell in cells {
                add(NSRange(location: cursor, length: cell.range.location - cursor), .tableStructure, 0, owner: table.range)
                add(cell.range, .replacement(.tableCell), cell.displayText?.utf16.count ?? cell.range.length, owner: table.range)
                cursor = NSMaxRange(cell.range)
            }
            add(NSRange(location: cursor, length: NSMaxRange(table.range) - cursor), .tableStructure, 0, owner: table.range)
        }
        self.init(candidates: candidates, textLength: textLength, unreliable: unreliable)
    }

    init(candidates: [Candidate], textLength: Int, unreliable: [NSRange] = []) {
        func rank(_ kind: Kind) -> Int {
            switch kind {
            case .replacement(.tableCell): return 0
            case .replacement: return 1
            case .tableStructure: return 2
            case .hiddenMarker: return 3
            }
        }
        let sorted = candidates.filter { $0.source.location >= 0 && $0.source.length > 0 && NSMaxRange($0.source) <= textLength && $0.displayLength >= 0 }
            .sorted {
                if $0.source.location != $1.source.location { return $0.source.location < $1.source.location }
                if $0.source.length != $1.source.length { return $0.source.length > $1.source.length }
                if rank($0.kind) != rank($1.kind) { return rank($0.kind) < rank($1.kind) }
                // Один маркер у вложенных цитат принадлежит нескольким элементам: остаётся внутренний (скрыт, пока не задет он, а не внешний).
                return ($0.revealOwner ?? $0.owner).length < ($1.revealOwner ?? $1.owner).length
            }
        var lost = unreliable.filter { $0.location >= 0 && $0.length > 0 && NSMaxRange($0) <= textLength }
        var accepted: [Candidate] = []
        var acceptedEnd = 0
        for candidate in sorted {
            if candidate.source.location >= acceptedEnd {
                accepted.append(candidate)
                acceptedEnd = NSMaxRange(candidate.source)
            } else if NSMaxRange(candidate.source) <= acceptedEnd {
                // Внутри принятого: внешний побеждает. Скрытый символ внутри замены текста слой гасит иначе, чем карта, — участку нельзя верить.
                if candidate.kind == .hiddenMarker, let outer = accepted.last, outer.kind == .replacement(.typography) { lost.append(outer.source) }
            } else {
                lost.append(candidate.source)
            }
        }
        var entries: [Entry] = []
        entries.reserveCapacity(accepted.count)
        var shift = 0
        for candidate in accepted {
            entries.append(Entry(source: candidate.source, displayStart: candidate.source.location + shift,
                                 displayLength: candidate.displayLength, kind: candidate.kind, owner: candidate.owner,
                                 isInline: candidate.isInline, revealOwner: candidate.revealOwner))
            shift += candidate.displayLength - candidate.source.length
        }
        self.sourceLength = textLength
        self.displayLength = textLength + shift
        self.entries = entries
        self.unreliable = MarkdownPresentation.mergedRanges(lost)
        // Владельцы с собственными маркерами (вложенность — как в `MarkdownElementIndex.nest`) и таблицы.
        var grouped: [NSRange: [Int]] = [:]
        var tableRanges: [NSRange] = []
        for (index, entry) in entries.enumerated() {
            switch entry.kind {
            case .hiddenMarker where entry.owner != entry.source: grouped[entry.owner, default: []].append(index)
            case .tableStructure, .replacement(.tableCell):
                if tableRanges.last != entry.owner { tableRanges.append(entry.owner) }
            default: break
            }
        }
        var nodes: [OwnerNode] = []
        let ordered = grouped.sorted {
            if $0.key.location != $1.key.location { return $0.key.location < $1.key.location }
            return $0.key.length > $1.key.length
        }
        var stack: [Int] = []
        for (range, indices) in ordered {
            while let top = stack.last, NSMaxRange(nodes[top].range) < NSMaxRange(range) { stack.removeLast() }
            nodes.append(OwnerNode(range: range, indices: indices, parent: stack.last ?? -1))
            stack.append(nodes.count - 1)
        }
        self.owners = nodes
        self.tables = tableRanges
    }

    static func identity(textLength: Int) -> MarkdownDisplayMap {
        MarkdownDisplayMap(candidates: [], textLength: textLength)
    }

    // MARK: Поиск

    /// Первый индекс из `0..<count`, где условие истинно (условие монотонно).
    private static func firstIndex(_ count: Int, where holds: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if holds(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Участок, у которого `location < point < max`.
    private func unreliableContaining(_ point: Int) -> NSRange? {
        let index = Self.firstIndex(unreliable.count) { NSMaxRange(unreliable[$0]) > point }
        guard index < unreliable.count, unreliable[index].location < point else { return nil }
        return unreliable[index]
    }

    /// Запись, чей `[location, max)` содержит позицию.
    func entry(atSource location: Int) -> Entry? {
        let index = Self.firstIndex(entries.count) { entries[$0].source.location > location } - 1
        guard index >= 0, location < NSMaxRange(entries[index].source) else { return nil }
        return entries[index]
    }

    // MARK: Точки

    func displayLocation(forSource location: Int, interior: Interior = .fail) -> Result<Int, Failure> {
        guard location >= 0, location <= sourceLength else { return .failure(.outOfBounds) }
        if let range = unreliableContaining(location) { return .failure(.unreliableRegion(range)) }
        let index = Self.firstIndex(entries.count) { entries[$0].source.location > location } - 1
        guard index >= 0 else { return .success(location) }
        let entry = entries[index]
        if location < NSMaxRange(entry.source) {
            if location == entry.source.location || entry.displayLength == 0 { return .success(entry.displayStart) }
            switch interior {
            case .fail: return .failure(.insideReplacement(entry.source))
            case .snapDown: return .success(entry.displayStart)
            case .snapUp: return .success(entry.displayEnd)
            }
        }
        return .success(entry.displayEnd + location - NSMaxRange(entry.source))
    }

    func sourceLocation(forDisplay location: Int, affinity: Affinity, interior: Interior = .fail) -> Result<Int, Failure> {
        guard location >= 0, location <= displayLength else { return .failure(.outOfBounds) }
        let inside = Self.firstIndex(entries.count) { entries[$0].displayStart > location } - 1
        if inside >= 0, entries[inside].displayLength > 0,
           entries[inside].displayStart < location, location < entries[inside].displayEnd {
            switch interior {
            case .fail: return .failure(.insideReplacement(entries[inside].source))
            case .snapDown: return .success(entries[inside].source.location)
            case .snapUp: return .success(NSMaxRange(entries[inside].source))
            }
        }
        // Последняя запись, закончившаяся не правее позиции; скрытые записи в этой точке идут цепочкой подряд.
        var last = Self.firstIndex(entries.count) { entries[$0].displayEnd > location } - 1
        let high = last >= 0 ? NSMaxRange(entries[last].source) + location - entries[last].displayEnd : location
        var low = high
        while last >= 0, entries[last].displayLength == 0, entries[last].displayStart == location, NSMaxRange(entries[last].source) == low {
            low = entries[last].source.location
            last -= 1
        }
        let result = affinity == .leading ? low : high
        if let range = unreliableContaining(result) { return .failure(.unreliableRegion(range)) }
        return .success(result)
    }

    // MARK: Диапазоны

    func displayRange(forSource range: NSRange, coverage: Coverage = .tight) -> Result<NSRange, Failure> {
        let startInterior: Interior = coverage == .tight ? .fail : .snapDown
        let endInterior: Interior = coverage == .tight ? .fail : .snapUp
        switch displayLocation(forSource: range.location, interior: startInterior) {
        case .failure(let failure): return .failure(failure)
        case .success(let start):
            if range.length == 0 { return .success(NSRange(location: start, length: 0)) }
            switch displayLocation(forSource: NSMaxRange(range), interior: endInterior) {
            case .failure(let failure): return .failure(failure)
            case .success(let end): return .success(NSRange(location: start, length: max(0, end - start)))
            }
        }
    }

    func sourceRange(forDisplay range: NSRange, coverage: Coverage = .tight, caretAffinity: Affinity = .leading) -> Result<NSRange, Failure> {
        if range.length == 0 {
            return sourceLocation(forDisplay: range.location, affinity: caretAffinity).map { NSRange(location: $0, length: 0) }
        }
        let tight = coverage == .tight
        switch sourceLocation(forDisplay: range.location, affinity: tight ? .trailing : .leading, interior: tight ? .fail : .snapDown) {
        case .failure(let failure): return .failure(failure)
        case .success(let start):
            switch sourceLocation(forDisplay: NSMaxRange(range), affinity: tight ? .leading : .trailing, interior: tight ? .fail : .snapUp) {
            case .failure(let failure): return .failure(failure)
            case .success(let end): return .success(NSRange(location: start, length: max(0, end - start)))
            }
        }
    }

    // MARK: Каретка

    /// Куда поставить каретку, которую указатель или вертикальное движение оставили в цепочке скрытых маркеров (края включительно).
    /// Внутри цепочки все позиции выглядят одинаково (маркеры нулевой ширины), а в тексте это разные места.
    /// Выбирается позиция с наименьшим числом inline-элементов, которые её строго содержат: снаружи `**жирного**`, но после `## ` и `> `;
    /// при равенстве — правее. nil — каретка не в цепочке (или участок ненадёжен): оставить как есть.
    /// Карта должна быть построена с `Reveal.none`, текущее раскрытие приходит в `reveal`.
    func settledCaret(atSource point: Int, reveal: Reveal) -> Int? {
        guard point >= 0, point <= sourceLength, unreliableContaining(point) == nil else { return nil }
        func hidden(_ index: Int) -> Bool { index >= 0 && index < entries.count && entries[index].displayLength == 0 && reveal.hides(entries[index]) }
        func joined(_ left: Int, _ right: Int) -> Bool { NSMaxRange(entries[left].source) == entries[right].source.location }
        // Запись справа начинается в точке; запись слева заканчивается в ней или содержит её.
        let right = Self.firstIndex(entries.count) { entries[$0].source.location >= point }
        let seed: Int
        if hidden(right), entries[right].source.location == point { seed = right }
        else if hidden(right - 1), NSMaxRange(entries[right - 1].source) >= point { seed = right - 1 }
        else { return nil }
        var first = seed, last = seed
        while hidden(first - 1), joined(first - 1, first) { first -= 1 }
        while hidden(last + 1), joined(last, last + 1) { last += 1 }
        var best: (position: Int, depth: Int)?
        var candidates = [entries[first].source.location]
        for index in first...last { candidates.append(NSMaxRange(entries[index].source)) }
        for position in candidates {
            let depth = ownerChain(strictlyAround: position).filter { entries[$0.indices[0]].isInline }.count
            if best == nil || depth <= best!.depth { best = (position, depth) }
        }
        guard let best, unreliableContaining(best.position) == nil else { return nil }
        return best.position
    }

    // MARK: Элементы и правка

    /// Владельцы, строго содержащие точку, от внутреннего к внешнему.
    private func ownerChain(strictlyAround point: Int) -> [OwnerNode] {
        var index = Self.firstIndex(owners.count) { owners[$0].range.location > point } - 1
        var chain: [OwnerNode] = []
        while index >= 0 {
            let node = owners[index]
            if node.range.location < point && point < NSMaxRange(node.range) { chain.append(node) }
            index = node.parent
        }
        return chain
    }

    /// Часть маркеров владельца внутри диапазона (но не все): диапазон рвёт элемент.
    private func splits(_ node: OwnerNode, _ range: NSRange) -> Bool {
        let first = Self.firstIndex(node.indices.count) { entries[node.indices[$0]].source.location >= range.location }
        guard first < node.indices.count, NSMaxRange(entries[node.indices[first]].source) <= NSMaxRange(range) else { return false }
        let all = entries[node.indices[0]].source.location >= range.location
            && NSMaxRange(entries[node.indices[node.indices.count - 1]].source) <= NSMaxRange(range)
        return !all
    }

    /// Выделение не рвёт элемент: захваченный маркер, разрезанный маркер или замена расширяются до целого элемента.
    func expandToElement(_ range: NSRange) -> NSRange {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= sourceLength else { return range }
        var result = range
        for _ in 0..<(owners.count + 4) {
            let before = result
            if let entry = entry(atSource: result.location), entry.source.location < result.location {
                result = NSUnionRange(result, entry.source)
            }
            if let entry = entry(atSource: NSMaxRange(result)), entry.source.location < NSMaxRange(result) {
                result = NSUnionRange(result, entry.source)
            }
            for point in [result.location, NSMaxRange(result)] {
                for node in ownerChain(strictlyAround: point) where splits(node, result) { result = NSUnionRange(result, node.range) }
            }
            for table in tables where Self.cuts(table, result) { result = NSUnionRange(result, table) }
            if result == before { break }
        }
        return result
    }

    /// Каретка строго внутри защищённого участка либо непустой диапазон пересекает его, но не покрывает целиком.
    private static func cuts(_ protected: NSRange, _ range: NSRange) -> Bool {
        if range.length == 0 { return protected.location < range.location && range.location < NSMaxRange(protected) }
        return NSIntersectionRange(protected, range).length > 0
            && !(range.location <= protected.location && NSMaxRange(protected) <= NSMaxRange(range))
    }

    /// Принцип: разрез защищённого участка запрещён; охват целиком и каретка на границе разрешены.
    /// Порядок причин: граница позиции, таблица, ненадёжный участок, запись, элемент.
    func editability(ofSource range: NSRange) -> Editability {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= sourceLength else { return .forbidden(.outOfBounds) }
        let end = NSMaxRange(range)
        if let table = tables.first(where: { Self.cuts($0, range) }) { return .forbidden(.tableCell(table: table)) }
        if let region = unreliable.first(where: { Self.cuts($0, range) }) { return .forbidden(.unreliableRegion(region)) }
        for point in range.length == 0 ? [range.location] : [range.location, end] {
            guard let entry = entry(atSource: point), entry.source.location < point else { continue }
            switch entry.kind {
            case .hiddenMarker: return .forbidden(.insideHiddenSyntax(owner: entry.owner))
            case .tableStructure: return .forbidden(.tableCell(table: entry.owner))
            case .replacement(let kind): return .forbidden(.insideReplacement(kind, entry.source))
            }
        }
        for point in [range.location, end] {
            for node in ownerChain(strictlyAround: point) where splits(node, range) { return .forbidden(.splitsElement(owner: node.range)) }
        }
        return .allowed
    }
}

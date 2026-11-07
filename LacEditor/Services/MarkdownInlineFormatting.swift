import Foundation

/// Данные разбора для строчных команд форматирования (жирный, курсив, зачёркивание, код).
/// Нужны, чтобы команда понимала готовые элементы: частичное выделение внутри `**жирного**` разрезает его,
/// `_курсив_` снимается, внутри кода, адреса ссылки и на стыке пунктов списка правка отклоняется.
/// Все диапазоны — UTF-16 в тексте редактора.
struct MarkdownInlineContext {
    enum Kind: Equatable { case strong, emphasis, strikethrough, code, link }

    struct Span: Equatable {
        let kind: Kind
        /// Весь элемент вместе с маркерами.
        let range: NSRange
        /// Открывающий и закрывающий маркер (у ссылки — `[` и `](адрес)`).
        let markers: [NSRange]

        /// Текст между маркерами.
        var content: NSRange { NSRange(location: NSMaxRange(markers[0]), length: markers[1].location - NSMaxRange(markers[0])) }
    }

    /// Элементы с двумя подтверждёнными маркерами.
    var spans: [Span] = []
    /// Строчные элементы без внутренностей: код, формулы, картинки, сноски. Выделение может целиком охватывать их, но не резать.
    var atoms: [NSRange] = []
    /// Блоки, где строчное форматирование запрещено: front matter, код, формулы, HTML.
    var blocked: [NSRange] = []
    var tables: [NSRange] = []
    /// Остальные блоки (пункты, задачи, цитаты, заголовки): выделение не должно переходить из одного в другой.
    var blocks: [NSRange] = []
    /// Участки, где позиции разбора не подтверждены (в том числе `***слово***`, у которого нет подтверждённых маркеров).
    var unreliable: [NSRange] = []
    var strictMode = true

    init(presentation: MarkdownPresentation, strictMode: Bool = true) {
        self.strictMode = strictMode
        unreliable = presentation.unreliableRanges
        for span in presentation.spans {
            let kind: Kind
            switch span.kind {
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .strikethrough: kind = .strikethrough
            case .code: kind = .code
            case .link: kind = .link
            default: continue
            }
            if span.markerRanges.count == 2 {
                spans.append(Span(kind: kind, range: span.range, markers: span.markerRanges))
            } else if kind != .code {
                // Элемент без подтверждённых маркеров: правку рядом с ним делать по тексту нельзя.
                unreliable.append(span.range)
            }
        }
        let flat = presentation.elements.flattened
        for (range, kind) in flat.blocks {
            switch kind {
            case .frontMatter, .codeBlock, .mathBlock, .htmlBlock: blocked.append(range)
            case .table: tables.append(range)
            default: blocks.append(range)
            }
        }
        for (range, kind) in flat.inlines {
            switch kind {
            case .code, .formula, .image, .footnoteReference: atoms.append(range)
            default: break
            }
        }
    }
}

/// Итог строчной команды на разборе.
enum MarkdownInlineResult {
    case edit(MarkdownFormattingEdit)
    /// Правка запрещена (код, адрес ссылки, таблица, граница блока, нечего менять).
    case refused
    /// Разбор не подходит (ненадёжный участок, каретка вне элемента): остаётся прежний путь по тексту.
    case fallback
}

extension MarkdownFormattingService {
    private static func overlaps(_ range: NSRange, _ selection: NSRange) -> Bool {
        selection.length == 0
            ? range.location < selection.location && selection.location < NSMaxRange(range)
            : NSIntersectionRange(range, selection).length > 0
    }

    private static func covers(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location <= inner.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Строчная команда по готовому разбору. `selection` уже обрезан по пробелам (`inlineSelection`).
    static func inlineEdit(in text: NSString, selection: NSRange, command: MarkdownFormattingCommand,
                           context: MarkdownInlineContext) -> MarkdownInlineResult {
        let kind: MarkdownInlineContext.Kind, marker: String
        switch command {
        case .bold: (kind, marker) = (.strong, "**")
        case .italic: (kind, marker) = (.emphasis, "*")
        case .strikethrough: (kind, marker) = (.strikethrough, "~~")
        case .inlineCode: (kind, marker) = (.code, "`")
        default: return .fallback
        }
        let end = NSMaxRange(selection)
        if context.unreliable.contains(where: { overlaps($0, selection) }) { return .fallback }
        // Блок кода/формулы/HTML: каретка на первой строке блока тоже внутри (пара маркеров сломала бы ограждение).
        if context.blocked.contains(where: { selection.length == 0
            ? $0.location <= selection.location && selection.location < NSMaxRange($0)
            : NSIntersectionRange($0, selection).length > 0 }) { return .refused }
        if kind == .code {
            // Команда «код» на своём коде снимает его, на любом другом пересечении с кодом отказывает.
            if let code = context.spans.first(where: { $0.kind == .code && ($0.range == selection || $0.content == selection) }) {
                guard let edit = codeEdit(in: text, selection: code.content), edit.range == code.range else { return .refused }
                return .edit(edit)
            }
            if context.atoms.contains(where: { overlaps($0, selection) || (selection.length > 0 && covers(selection, $0)) }) { return .refused }
        } else {
            for atom in context.atoms where overlaps(atom, selection) {
                if selection.length == 0 || !covers(selection, atom) { return .refused }
            }
        }
        for table in context.tables where overlaps(table, selection) {
            // В таблице выделение должно лежать в одной ячейке: одна строка и ни одной вертикальной черты.
            let selected = text.substring(with: selection) as NSString
            var previous: unichar = 0
            for index in 0..<selected.length {
                let character = selected.character(at: index)
                if character == 10 || character == 13 || (character == 124 && previous != 92) { return .refused }
                previous = character
            }
            // Разбор не отдаёт спанов внутри ячеек, проверить результат нечем: правка по прежнему текстовому пути.
            return .fallback
        }
        for block in context.blocks where overlaps(block, selection) && !covers(block, selection) { return .refused }
        for span in context.spans where span.kind != .code && overlaps(span.range, selection) {
            if selection.length > 0 && covers(selection, span.range) { continue }
            // Частичный охват элемента, адрес ссылки или маркер: правка по тексту сломала бы элемент.
            guard covers(span.range, selection), covers(span.content, selection) else { return .refused }
        }
        if kind == .code { return .fallback }
        let same = context.spans.filter { $0.kind == kind }
        guard selection.length > 0 else {
            // Каретка в уже оформленном слове: команда ничего не меняет.
            return same.contains(where: { $0.content.location <= selection.location && selection.location <= NSMaxRange($0.content) })
                ? .refused : .fallback
        }
        let size = (marker as NSString).length
        var parts: [MarkdownEditTransaction.Edit]
        var logical = selection
        var old: MarkdownInlineContext.Span?
        // Что должно быть в новом тексте (диапазоны считаются после того, как известны все части).
        let expected: (PartsMap) -> (present: [NSRange], absent: [NSRange])
        if let whole = same.first(where: { $0.range == selection || $0.content == selection }) {
            // Снятие: выделен элемент целиком или его содержимое.
            parts = [.init(range: whole.markers[1], replacement: ""), .init(range: whole.markers[0], replacement: "")]
            logical = whole.content
            old = whole
            expected = { map in ([], [NSRange(location: map.position(whole.content.location, insertionsAtPointCount: true), length: whole.content.length)]) }
        } else if let host = same.filter({ covers($0.content, selection) }).min(by: { $0.range.length < $1.range.length }) {
            // Частичное снятие: элемент разрезается, выделенная часть остаётся без маркера.
            let open = text.substring(with: host.markers[0]), close = text.substring(with: host.markers[1])
            let leftEmpty = selection.location == host.content.location, rightEmpty = end == NSMaxRange(host.content)
            parts = [
                rightEmpty ? .init(range: host.markers[1], replacement: "") : .init(range: NSRange(location: end, length: 0), replacement: open),
                leftEmpty ? .init(range: host.markers[0], replacement: "") : .init(range: NSRange(location: selection.location, length: 0), replacement: close)
            ]
            old = host
            expected = { map in
                var present: [NSRange] = []
                if !leftEmpty {
                    let closing = map.position(selection.location, insertionsAtPointCount: true)
                    present.append(NSRange(location: host.range.location, length: closing - host.range.location))
                }
                if !rightEmpty {
                    let opening = map.position(end, insertionsAtPointCount: false)
                    present.append(NSRange(location: opening, length: map.position(NSMaxRange(host.range), insertionsAtPointCount: true) - opening))
                }
                return (present, [])
            }
        } else {
            // Оборачивание: вложенные элементы того же вида теряют свои маркеры, чтобы не получить `****`.
            guard !isEscaped(selection.location, in: text), !isEscaped(end, in: text) else { return .refused }
            parts = [.init(range: NSRange(location: end, length: 0), replacement: marker)]
            for inner in same where covers(selection, inner.range) {
                parts.append(.init(range: inner.markers[1], replacement: ""))
                parts.append(.init(range: inner.markers[0], replacement: ""))
            }
            parts.append(.init(range: NSRange(location: selection.location, length: 0), replacement: marker))
            expected = { map in
                let start = map.position(selection.location, insertionsAtPointCount: true)
                let finish = map.position(end, insertionsAtPointCount: false)
                return ([NSRange(location: start - size, length: finish - start + 2 * size)], [])
            }
        }
        let map = PartsMap(parts)
        let start = map.position(logical.location, insertionsAtPointCount: true)
        let finish = map.position(NSMaxRange(logical), insertionsAtPointCount: false)
        let union = map.parts.dropFirst().reduce(map.parts[0].range) { NSUnionRange($0, $1.range) }
        let replaced = NSMutableString(string: text.substring(with: union))
        for part in map.parts {
            replaced.replaceCharacters(in: NSRange(location: part.range.location - union.location, length: part.range.length), with: part.replacement)
        }
        let checks = expected(map)
        guard verified(text, parts: map.parts, union: union, kind: kind, present: checks.present, absent: checks.absent,
                       old: old, strictMode: context.strictMode) else { return .refused }
        return .edit(MarkdownFormattingEdit(range: union, replacement: replaced as String,
                                            selectionRange: NSRange(location: start, length: finish - start), parts: map.parts))
    }

    /// Правки от конца к началу (как требует транзакция) и пересчёт позиций старого текста в новый.
    private struct PartsMap {
        let parts: [MarkdownEditTransaction.Edit]

        init(_ unsorted: [MarkdownEditTransaction.Edit]) {
            // При равном начале раньше идёт более длинная правка: удаление маркера в той же точке, что и вставка, не пересекается с ней.
            parts = unsorted.sorted {
                $0.range.location != $1.range.location ? $0.range.location > $1.range.location : $0.range.length > $1.range.length
            }
        }

        /// Вставка ровно в точке считается лежащей до неё, если `insertionsAtPointCount` (начало выделения), и после неё иначе (конец).
        func position(_ point: Int, insertionsAtPointCount: Bool) -> Int {
            var delta = 0
            for part in parts {
                let finish = NSMaxRange(part.range)
                if finish < point || (finish == point && (part.range.length > 0 || insertionsAtPointCount)) {
                    delta += (part.replacement as NSString).length - part.range.length
                }
            }
            return point + delta
        }
    }

    /// Первая и последняя строки «верхнего» блока вокруг диапазона: пустая строка перед ним и строка без отступа.
    static func topLevelWindow(in text: NSString, around range: NSRange) -> NSRange {
        func isBlank(_ line: NSRange) -> Bool {
            for index in line.location..<NSMaxRange(line) {
                let character = text.character(at: index)
                if character != 32 && character != 9 && character != 10 && character != 13 { return false }
            }
            return true
        }
        func startsBlock(_ line: NSRange) -> Bool {
            if line.location == 0 { return true }
            let first = text.character(at: line.location)
            return first != 32 && first != 9 && !isBlank(line) && isBlank(markdownLineRange(in: text, at: line.location - 1))
        }
        var first = markdownLineRange(in: text, at: min(range.location, max(0, text.length - 1)))
        while !startsBlock(first) { first = markdownLineRange(in: text, at: first.location - 1) }
        var end = markdownLineRange(in: text, at: min(max(NSMaxRange(range) - (range.length > 0 ? 1 : 0), 0), max(0, text.length - 1))).location
        end = NSMaxRange(markdownLineRange(in: text, at: end))
        while end < text.length {
            let line = markdownLineRange(in: text, at: end)
            if startsBlock(line) { break }
            end = NSMaxRange(line)
        }
        return NSRange(location: first.location, length: end - first.location)
    }

    private static func verified(_ text: NSString, parts: [MarkdownEditTransaction.Edit], union: NSRange, kind: MarkdownInlineContext.Kind,
                                 present: [NSRange], absent: [NSRange], old: MarkdownInlineContext.Span?, strictMode: Bool) -> Bool {
        let presentationKind: MarkdownPresentationKind
        switch kind {
        case .strong: presentationKind = .strong
        case .emphasis: presentationKind = .emphasis
        case .strikethrough: presentationKind = .strikethrough
        default: return false
        }
        let window = topLevelWindow(in: text, around: union)
        let result = NSMutableString(string: text.substring(with: window))
        for part in parts {
            result.replaceCharacters(in: NSRange(location: part.range.location - window.location, length: part.range.length), with: part.replacement)
        }
        func spans(_ source: String) -> [NSRange] {
            MarkdownPresentationBuilder.parse(source, syntax: .init(strictMode: strictMode)).spans
                .filter { $0.kind == presentationKind }.map(\.range)
        }
        // Окно должно разбираться так же, как документ: прежний элемент находится в нём.
        if let old {
            let before = spans(text.substring(with: window))
            guard before.contains(NSRange(location: old.range.location - window.location, length: old.range.length)) else { return false }
        }
        let after = spans(result as String)
        func relative(_ range: NSRange) -> NSRange { NSRange(location: range.location - window.location, length: range.length) }
        return present.allSatisfy { after.contains(relative($0)) } && !absent.contains(where: { after.contains(relative($0)) })
    }
}

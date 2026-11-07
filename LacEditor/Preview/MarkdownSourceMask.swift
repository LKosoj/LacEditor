import Foundation

/// Маскировка исходного текста перед cmark: front matter, `%%…%%` (заметки хранилища) и CriticMarkup.
/// Длина в UTF-16 и положение CR/LF не меняются, байты UTF-8 — меняются: позиции строятся от маскированного текста,
/// а тексты узлов берутся из исходного по тем же диапазонам. `[[…]]` и `![[…]]` не маскируются — их ищут по текстовым узлам.
enum MarkdownSourceMask {
    struct Options: Equatable, Sendable {
        var syntax: MarkdownSyntaxOptions
        /// Заметка хранилища: `%%…%%` — комментарии.
        var isVaultNote: Bool
        var detectsFrontMatter: Bool
        var includesCritic: Bool
    }

    enum Kind: Equatable, Sendable {
        case frontMatter
        case comment
        case critic(CriticMarkupKind)
    }

    struct Segment: Equatable, Sendable {
        var kind: Kind
        /// Весь участок (UTF-16 исходника): у критика от `{` до `}`, у комментария от первого `%` до последнего `%`.
        var range: NSRange
        /// Служебные знаки: `{++`/`++}`, `%%`/`%%`, `---`/`---`.
        var markerRanges: [NSRange]
        /// Между разделителями; у подмены — вся пара «было~>стало».
        var contentRange: NSRange
        /// `~>` только у подмены.
        var separatorRange: NSRange?
        /// `%%`: каждая строка комментария, кроме нетронутого текста, содержит только пробелы и префикс цитаты или списка.
        var occupiesWholeLines: Bool
        /// `%%`: комментарий стоит строками внутри абзаца, пустая строка разорвала бы его.
        var keepsParagraph: Bool
    }

    struct Result: Equatable, Sendable {
        /// Той же длины в UTF-16, CR/LF на тех же местах.
        var text: String
        /// Отсортированы по `range.location`.
        var segments: [Segment]
        /// Заменитель: первая свободная единица Private Use Area (U+E000…U+F8FF) либо свободный U+FFFF.
        var placeholder: UInt16
        /// Ничего не замаскировано: `text` совпадает с исходным.
        var isIdentity: Bool
    }

    /// `excluded` — отсортированные слитые запрещённые диапазоны (код, формулы, HTML-блоки, таблицы); без них берётся оценка `estimatedExcluded`.
    static func mask(_ text: String, options: Options, excluded: [NSRange]? = nil, isCancelled: () -> Bool = { false }) -> Result {
        let identity = Result(text: text, segments: [], placeholder: 0xFFFF, isIdentity: true)
        let source = text as NSString
        let front = options.detectsFrontMatter ? MarkdownFrontMatter.frontMatter(text) : nil
        let hasCritic = options.includesCritic && CriticMarkupRender.mayContainMarkup(text)
        let hasComment = options.isVaultNote && MarkdownObsidianComment.mayContainComment(source)
        guard front != nil || hasCritic || hasComment, !isCancelled() else { return identity }

        var segments: [Segment] = []
        if let front {
            segments.append(Segment(kind: .frontMatter, range: front.range, markerRanges: front.markers,
                                    contentRange: NSRange(location: NSMaxRange(front.markers[0]), length: max(0, front.markers[1].location - NSMaxRange(front.markers[0]))),
                                    separatorRange: nil, occupiesWholeLines: true, keepsParagraph: false))
        }
        var zones: [NSRange] = []
        if hasCritic || hasComment {
            zones = excluded ?? estimatedExcluded(text, isCancelled: isCancelled)
            if isCancelled() { return identity }
            if let front { zones = merged(zones + [front.range]) }
        }
        var critic: [Segment] = []
        if hasCritic {
            for item in CriticMarkupService.items(in: source, excluded: zones) {
                var markers = [NSRange(location: item.range.location, length: 3), NSRange(location: NSMaxRange(item.range) - 3, length: 3)]
                if let separator = item.separator { markers.insert(separator, at: 1) }
                critic.append(Segment(kind: .critic(item.kind), range: item.range, markerRanges: markers, contentRange: item.content,
                                      separatorRange: item.separator, occupiesWholeLines: false, keepsParagraph: false))
            }
        }
        var comments: [NSRange] = []
        if hasComment {
            // Тело `{>>…<<}` в старом потоке заменялось маркерами раньше `%%`, поэтому `%%` внутри него не виден.
            let criticComments = critic.filter { $0.kind == .critic(.comment) }.map(\.range)
            comments = MarkdownObsidianComment.ranges(in: source, excluded: merged(zones + criticComments))
        }
        if !comments.isEmpty {
            // Критик целиком внутри комментария или пересекающий его границу отбрасывается; комментарий внутри содержимого критика остаётся.
            critic.removeAll { item in
                comments.contains { comment in
                    let overlap = NSIntersectionRange(item.range, comment)
                    return overlap.length > 0 && !(NSLocationInRange(comment.location, item.contentRange) && NSMaxRange(comment) <= NSMaxRange(item.contentRange))
                }
            }
        }
        segments.append(contentsOf: critic)
        var commentSegments: [Segment] = []
        var wholeLines: [[Bool]] = []
        for range in comments {
            let lines = wholeLineFlags(source, range: range, comments: comments)
            wholeLines.append(lines)
            commentSegments.append(Segment(kind: .comment, range: range,
                                           markerRanges: [NSRange(location: range.location, length: 2), NSRange(location: NSMaxRange(range) - 2, length: 2)],
                                           contentRange: NSRange(location: range.location + 2, length: range.length - 4),
                                           separatorRange: nil, occupiesWholeLines: !lines.contains(false), keepsParagraph: isInsideParagraph(range, in: source, comments: comments)))
        }
        segments.append(contentsOf: commentSegments)
        guard !segments.isEmpty else { return identity }
        segments.sort { $0.range.location < $1.range.location }

        guard let placeholder = freePlaceholder(in: source) else { return identity }
        var units = Array(text.utf16)
        func fill(_ range: NSRange, with value: UInt16) {
            for index in range.location..<NSMaxRange(range) where units[index] != 10 && units[index] != 13 { units[index] = value }
        }
        for segment in segments {
            switch segment.kind {
            case .frontMatter:
                fill(segment.range, with: 32)
            case .critic(let kind):
                if kind == .comment { fill(segment.range, with: placeholder) }
                else {
                    for marker in segment.markerRanges { fill(marker, with: placeholder) }
                }
            case .comment:
                if segment.keepsParagraph { fill(segment.range, with: placeholder); continue }
                let lines = wholeLines[comments.firstIndex(of: segment.range)!]
                var lineIndex = 0
                var position = segment.range.location
                while position < NSMaxRange(segment.range) {
                    let line = source.lineRange(for: NSRange(location: position, length: 0))
                    let part = NSIntersectionRange(line, segment.range)
                    fill(part, with: lines[lineIndex] ? 32 : placeholder)
                    lineIndex += 1
                    position = NSMaxRange(line)
                }
            }
        }
        return Result(text: String(decoding: units, as: UTF16.self), segments: segments, placeholder: placeholder, isIdentity: false)
    }

    // MARK: - Комментарии

    /// По каждой строке комментария: вне комментариев на ней только пробелы и префикс цитаты или списка (как `isBlankLine` ниже).
    private static func wholeLineFlags(_ text: NSString, range: NSRange, comments: [NSRange]) -> [Bool] {
        func inComment(_ index: Int) -> Bool { comments.contains { NSLocationInRange(index, $0) } }
        var flags: [Bool] = []
        var position = range.location
        while position < NSMaxRange(range) {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: line.location, length: 0))
            var rest: [UInt16] = []
            for index in line.location..<contentsEnd { rest.append(inComment(index) ? 32 : text.character(at: index)) }
            flags.append(afterPrefix(0, rest.count, in: NSString(characters: rest, length: rest.count)) == rest.count)
            position = NSMaxRange(line)
        }
        return flags
    }

    static func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    /// Первая позиция после префикса строки: пробелы, `>` цитаты и маркеры списка (`-`, `*`, `+`, `1.`, `1)`).
    static func afterPrefix(_ start: Int, _ end: Int, in text: NSString) -> Int {
        var index = start
        while index < end {
            let unit = text.character(at: index)
            if isBlank(unit) || unit == 62 { index += 1; continue }
            if unit == 45 || unit == 42 || unit == 43, index + 1 >= end || isBlank(text.character(at: index + 1)) { index += 1; continue }
            var digits = index
            while digits < end, text.character(at: digits) >= 48, text.character(at: digits) <= 57 { digits += 1 }
            if digits > index, digits < end, text.character(at: digits) == 46 || text.character(at: digits) == 41,
               digits + 1 >= end || isBlank(text.character(at: digits + 1)) { index = digits + 1; continue }
            break
        }
        return index
    }

    /// Строка, где нет ничего кроме пробелов и префикса цитаты или списка (или её нет совсем).
    static func isBlankLine(at location: Int, in text: NSString) -> Bool {
        guard location >= 0, location < text.length else { return true }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: line.location, length: 0))
        return afterPrefix(line.location, contentsEnd, in: text) == contentsEnd
    }

    /// Комментарий занимает строки целиком и стоит внутри абзаца: пустая строка разорвала бы абзац.
    /// `comments` — все комментарии текста (на строке с комментарием могут стоять другие комментарии).
    static func isInsideParagraph(_ range: NSRange, in text: NSString, comments: [NSRange]) -> Bool {
        func insideComment(_ index: Int) -> Bool { comments.contains { NSLocationInRange(index, $0) } }
        let startLine = text.lineRange(for: NSRange(location: range.location, length: 0))
        let endLine = text.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: endLine.location, length: 0))
        let before = (afterPrefix(startLine.location, range.location, in: text)..<range.location).allSatisfy { isBlank(text.character(at: $0)) || insideComment($0) }
        let after = (NSMaxRange(range)..<max(NSMaxRange(range), contentsEnd)).allSatisfy { isBlank(text.character(at: $0)) || insideComment($0) }
        guard before, after, startLine.location > 0, NSMaxRange(endLine) < text.length else { return false }
        return !isBlankLine(at: startLine.location - 1, in: text) && !isBlankLine(at: NSMaxRange(endLine), in: text)
    }

    private static func freePlaceholder(in text: NSString) -> UInt16? {
        var used = Set<UInt16>()
        for index in 0..<text.length {
            let unit = text.character(at: index)
            if (unit >= 0xE000 && unit <= 0xF8FF) || unit == 0xFFFF { used.insert(unit) }
        }
        var candidate: UInt16 = 0xE000
        while candidate <= 0xF8FF { if !used.contains(candidate) { return candidate }; candidate += 1 }
        return used.contains(0xFFFF) ? nil : 0xFFFF
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

// MARK: - Оценка запрещённых диапазонов

extension MarkdownSourceMask {
    /// Приблизительные запрещённые диапазоны без разбора cmark: ограждённый и отступный код, блоки `$$`, HTML-блоки,
    /// таблицы и строчный код. Один построчный проход. Строчные формулы `$…$` не оцениваются (зависят от настроек).
    /// Вход для `mask`, пока дерева ещё нет; точные диапазоны дерева (`excludedRanges`) можно передать в `mask(excluded:)`.
    static func estimatedExcluded(_ text: String, isCancelled: () -> Bool = { false }) -> [NSRange] {
        var estimator = ExcludedEstimator(Array(text.utf16))
        return estimator.run(isCancelled: isCancelled)
    }

    private static let htmlBlockNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details",
        "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3",
        "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes",
        "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title",
        "tr", "track", "ul"
    ]

    private struct ExcludedEstimator {
        let u: [UInt16]
        var zones: [NSRange] = []

        init(_ units: [UInt16]) { u = units }

        struct Line { var start: Int; var end: Int; var next: Int }
        struct Scan {
            var body: Int
            var depth: Int
            var indent: Int
            var marker: Int?
            var markerIndent: Int
            /// Число `>` перед маркером списка на этой строке.
            var markerDepth: Int
            var isBlank: Bool
        }
        enum HTMLEnd { case token([UInt16]), blank }

        func lines() -> [Line] {
            var result: [Line] = []
            var start = 0
            while start < u.count {
                var end = start
                while end < u.count, u[end] != 10, u[end] != 13 { end += 1 }
                var next = end
                if next < u.count { next += (u[next] == 13 && next + 1 < u.count && u[next + 1] == 10) ? 2 : 1 }
                result.append(Line(start: start, end: end, next: next))
                start = next
            }
            return result
        }

        func ascii(_ s: String) -> [UInt16] { Array(s.utf16) }

        func whitespace(_ from: Int, _ col: Int, _ end: Int) -> (Int, Int) {
            var pos = from, column = col
            while pos < end, u[pos] == 32 || u[pos] == 9 {
                column = u[pos] == 9 ? (column / 4 + 1) * 4 : column + 1
                pos += 1
            }
            return (pos, column)
        }

        /// Столбец первого непробельного знака после `count` знаков `>` в начале строки; nil, если столько цитат нет.
        func column(afterQuotes count: Int, in line: Line) -> Int? {
            var (pos, col) = whitespace(line.start, 0, line.end)
            for _ in 0..<count {
                guard pos < line.end, u[pos] == 62 else { return nil }
                pos += 1; col += 1
                if pos < line.end, u[pos] == 32 { pos += 1; col += 1 }
                (pos, col) = whitespace(pos, col, line.end)
            }
            return col
        }

        /// Длина маркера списка в позиции, если за ним пробел, таб или конец строки.
        func markerWidth(_ pos: Int, _ end: Int) -> Int? {
            guard pos < end else { return nil }
            var width = 0
            if u[pos] == 45 || u[pos] == 42 || u[pos] == 43 {
                width = 1
            } else if u[pos] >= 48, u[pos] <= 57 {
                var digits = pos
                while digits < end, u[digits] >= 48, u[digits] <= 57 { digits += 1 }
                guard digits - pos <= 9, digits < end, u[digits] == 46 || u[digits] == 41 else { return nil }
                width = digits + 1 - pos
            } else {
                return nil
            }
            let after = pos + width
            guard after >= end || u[after] == 32 || u[after] == 9 else { return nil }
            return width
        }

        /// Начало строки: цитаты и маркеры списка; `listColumns` — открытые пункты списка (столбцы их содержимого).
        func scan(_ line: Line, listColumns: [Int]) -> Scan {
            var (pos, col) = whitespace(line.start, 0, line.end)
            let isBlank = pos >= line.end
            var base = 0
            if let column = listColumns.last(where: { $0 <= col }), !isBlank { base = column }
            var depth = 0
            var marker: Int?
            var markerIndent = 0
            var markerDepth = 0
            while pos < line.end, col - base < 4 {
                if u[pos] == 62 {
                    depth += 1; pos += 1; col += 1
                    if pos < line.end, u[pos] == 32 { pos += 1; col += 1 }
                    base = col
                } else if let width = markerWidth(pos, line.end) {
                    markerIndent = col
                    markerDepth = depth
                    pos += width; col += width
                    let (afterPos, afterCol) = whitespace(pos, col, line.end)
                    if afterPos >= line.end || afterCol - col >= 5 {
                        base = col + 1
                        if afterPos < line.end, afterCol - col >= 5 { pos += 1; col += 1 }
                    } else {
                        base = afterCol
                        pos = afterPos; col = afterCol
                    }
                    marker = base
                    (pos, col) = whitespace(pos, col, line.end)
                    continue
                } else {
                    break
                }
                (pos, col) = whitespace(pos, col, line.end)
            }
            return Scan(body: pos, depth: depth, indent: col - base, marker: marker, markerIndent: markerIndent, markerDepth: markerDepth, isBlank: pos >= line.end)
        }

        func hasPrefix(_ token: String, at pos: Int, end: Int, caseInsensitive: Bool = false) -> Bool {
            let units = ascii(token)
            guard pos + units.count <= end else { return false }
            for (offset, unit) in units.enumerated() {
                var value = u[pos + offset]
                if caseInsensitive, value >= 65, value <= 90 { value += 32 }
                if value != unit { return false }
            }
            return true
        }

        func contains(_ token: [UInt16], from: Int, to end: Int, caseInsensitive: Bool = false) -> Bool {
            guard !token.isEmpty, end - from >= token.count else { return false }
            var pos = from
            while pos + token.count <= end {
                var matches = true
                for (offset, unit) in token.enumerated() {
                    var value = u[pos + offset]
                    if caseInsensitive, value >= 65, value <= 90 { value += 32 }
                    if value != unit { matches = false; break }
                }
                if matches { return true }
                pos += 1
            }
            return false
        }

        func isLetter(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) }

        /// Тип HTML-блока по началу тела строки; блок типа 7 абзац не прерывает (`afterParagraph`).
        func htmlStart(_ pos: Int, _ end: Int, afterParagraph: Bool) -> HTMLEnd? {
            guard pos < end, u[pos] == 60 else { return nil }
            for name in ["script", "pre", "style", "textarea"] where hasPrefix("<" + name, at: pos, end: end, caseInsensitive: true) {
                let after = pos + 1 + name.utf16.count
                if after >= end || u[after] == 32 || u[after] == 9 || u[after] == 62 { return .token(ascii("</" + name + ">")) }
            }
            if hasPrefix("<!--", at: pos, end: end) { return .token(ascii("-->")) }
            if hasPrefix("<?", at: pos, end: end) { return .token(ascii("?>")) }
            if hasPrefix("<![CDATA[", at: pos, end: end) { return .token(ascii("]]>")) }
            if hasPrefix("<!", at: pos, end: end), pos + 2 < end, isLetter(u[pos + 2]) { return .token(ascii(">")) }
            var nameStart = pos + 1
            if nameStart < end, u[nameStart] == 47 { nameStart += 1 }
            var nameEnd = nameStart
            while nameEnd < end, isLetter(u[nameEnd]) || (u[nameEnd] >= 48 && u[nameEnd] <= 57) || (nameEnd > nameStart && u[nameEnd] == 45) { nameEnd += 1 }
            guard nameEnd > nameStart, isLetter(u[nameStart]) else { return nil }
            let name = String(decoding: u[nameStart..<nameEnd], as: UTF16.self).lowercased()
            let following = nameEnd < end ? u[nameEnd] : 32
            if htmlBlockNames.contains(name), following == 32 || following == 9 || following == 62 || (following == 47 && nameEnd + 1 < end && u[nameEnd + 1] == 62) || nameEnd >= end { return .blank }
            // Тип 7: один полный тег на строке, не прерывает абзац.
            guard !afterParagraph else { return nil }
            var last = end
            while last > pos, u[last - 1] == 32 || u[last - 1] == 9 { last -= 1 }
            guard last - 1 > pos, u[last - 1] == 62 else { return nil }
            for index in (pos + 1)..<(last - 1) where u[index] == 60 || u[index] == 62 { return nil }
            return .blank
        }

        func tableCells(_ line: Line) -> Int {
            var start = line.start, end = line.end
            while start < end, u[start] == 32 || u[start] == 9 { start += 1 }
            while end > start, u[end - 1] == 32 || u[end - 1] == 9 { end -= 1 }
            guard start < end else { return 0 }
            var count = 1
            var index = start
            while index < end {
                if u[index] == 92 { index += 2; continue }
                if u[index] == 124, index != start, index != end - 1 { count += 1 }
                index += 1
            }
            return count
        }

        func isDelimiterRow(_ line: Line) -> Bool {
            var sawDash = false
            var hasPipe = false
            for index in line.start..<line.end {
                switch u[index] {
                case 124: hasPipe = true
                case 45: sawDash = true
                case 58, 32, 9: break
                default: return false
                }
            }
            return sawDash && hasPipe
        }

        mutating func run(isCancelled: () -> Bool) -> [NSRange] {
            let all = lines()
            var index = 0
            var listColumns: [Int] = []
            var prevParagraph = false
            var prevDepth = 0
            var math: Int?
            var paragraph: [(start: Int, body: Int, end: Int)] = []
            var codeEnd: Int?
            var codeStart = 0

            func flushCode(_ estimator: inout ExcludedEstimator) {
                if let end = codeEnd { estimator.zones.append(NSRange(location: codeStart, length: end - codeStart)); codeEnd = nil }
            }
            func flushParagraph(_ estimator: inout ExcludedEstimator) {
                estimator.inlineCode(paragraph)
                paragraph.removeAll(keepingCapacity: true)
            }
            if let front = MarkdownFrontMatter.frontMatter(String(decoding: u, as: UTF16.self)) {
                while index < all.count, all[index].start < NSMaxRange(front.range) { index += 1 }
            }
            var counter = 0
            while index < all.count {
                counter += 1
                if counter % 512 == 0, isCancelled() { return [] }
                let line = all[index]
                let info = scan(line, listColumns: listColumns)
                if info.depth == 0 && prevDepth > 0 && !prevParagraph { listColumns = [] }
                // Ограждённый код.
                if !info.isBlank, info.indent < 4, u[info.body] == 96 || u[info.body] == 126 {
                    let ch = u[info.body]
                    var run = info.body
                    while run < line.end, u[run] == ch { run += 1 }
                    var isFence = run - info.body >= 3
                    if isFence, ch == 96 { for position in run..<line.end where u[position] == 96 { isFence = false; break } }
                    if isFence {
                        flushParagraph(&self); flushCode(&self)
                        let length = run - info.body
                        let depth = info.depth
                        // Пункт, в котором открыто ограждение (маркер на этой же строке), уже считается открытым.
                        let fenceColumns = info.marker.map { marker in listColumns.filter { $0 <= info.markerIndent } + [marker] } ?? listColumns.filter { $0 <= whitespace(line.start, 0, line.end).1 }
                        let stackCount = fenceColumns.count
                        // Цитаты перед маркером пункта: конец пункта проверяется по столбцу после них, а не после всех `>` строки.
                        let itemDepth = info.marker != nil ? info.markerDepth : depth
                        var endPosition = u.count
                        var cursor = index + 1
                        var closed = false
                        while cursor < all.count {
                            let current = all[cursor]
                            let inner = scan(current, listColumns: fenceColumns)
                            // Пустая строка без `>` закрывает цитату (строка `>` — нет: у неё depth не меньше).
                            if inner.depth < depth { endPosition = all[cursor - 1].end; break }
                            // Пункт списка закончился: строка с меньшим отступом, чем у содержимого пункта.
                            if stackCount > 0, !inner.isBlank, (column(afterQuotes: itemDepth, in: current) ?? 0) < (fenceColumns.last ?? 0) {
                                endPosition = all[cursor - 1].end; break
                            }
                            if !inner.isBlank, inner.indent < 4 {
                                var close = inner.body
                                while close < current.end, u[close] == ch { close += 1 }
                                if close - inner.body >= length, (close..<current.end).allSatisfy({ u[$0] == 32 || u[$0] == 9 }) {
                                    endPosition = current.end; closed = true; break
                                }
                            }
                            cursor += 1
                        }
                        if cursor >= all.count { endPosition = u.count }
                        zones.append(NSRange(location: line.start, length: endPosition - line.start))
                        // Блок оборвался цитатой или пунктом — эта строка разбирается заново.
                        index = closed ? cursor + 1 : cursor
                        prevParagraph = false; prevDepth = depth
                        listColumns = fenceColumns
                        continue
                    }
                }
                // Блок формулы `$$`.
                if let start = math {
                    if !info.isBlank, info.body + 2 == line.end, u[info.body] == 36, u[info.body + 1] == 36 {
                        zones.append(NSRange(location: start, length: line.end - start)); math = nil
                    }
                    index += 1; prevDepth = info.depth; continue
                }
                if !info.isBlank, info.body + 2 == line.end, u[info.body] == 36, u[info.body + 1] == 36 {
                    flushParagraph(&self); flushCode(&self)
                    math = line.start; prevParagraph = false; index += 1; prevDepth = info.depth; continue
                }
                if info.isBlank {
                    flushParagraph(&self)
                    prevParagraph = false; prevDepth = info.depth
                    index += 1; continue
                }
                // Отступный код.
                if info.indent >= 4, !prevParagraph || codeEnd != nil, info.marker == nil {
                    if codeEnd == nil { codeStart = line.start; flushParagraph(&self) }
                    codeEnd = line.end
                    index += 1; prevDepth = info.depth; continue
                }
                flushCode(&self)
                // HTML-блок.
                if info.indent < 4, let kind = htmlStart(info.body, line.end, afterParagraph: prevParagraph) {
                    flushParagraph(&self)
                    var cursor = index
                    var endPosition = u.count
                    switch kind {
                    case .token(let token):
                        endPosition = u.count
                        while cursor < all.count {
                            let current = all[cursor]
                            let from = cursor == index ? info.body : current.start
                            if contains(token, from: from, to: current.end, caseInsensitive: true) { endPosition = current.end; break }
                            cursor += 1
                        }
                    case .blank:
                        var last = line.end
                        cursor = index + 1
                        while cursor < all.count, !scan(all[cursor], listColumns: listColumns).isBlank { last = all[cursor].end; cursor += 1 }
                        endPosition = last
                        cursor -= 1
                    }
                    zones.append(NSRange(location: line.start, length: endPosition - line.start))
                    index = cursor + 1
                    prevParagraph = false; prevDepth = info.depth
                    continue
                }
                // Таблица.
                if index + 1 < all.count, contains([124], from: line.start, to: line.end), info.indent < 4 {
                    let delimiter = all[index + 1]
                    let delimiterScan = scan(delimiter, listColumns: listColumns)
                    if !delimiterScan.isBlank, isDelimiterRow(Line(start: delimiterScan.body, end: delimiter.end, next: delimiter.next)),
                       tableCells(Line(start: info.body, end: line.end, next: line.next)) == tableCells(Line(start: delimiterScan.body, end: delimiter.end, next: delimiter.next)) {
                        flushParagraph(&self)
                        var last = delimiter.end
                        var cursor = index + 2
                        while cursor < all.count, !scan(all[cursor], listColumns: listColumns).isBlank { last = all[cursor].end; cursor += 1 }
                        zones.append(NSRange(location: line.start, length: last - line.start))
                        index = cursor
                        prevParagraph = false; prevDepth = info.depth
                        continue
                    }
                }
                // Абзац (и заголовок) для строчного кода.
                let startsBlock = info.marker != nil || info.depth != prevDepth || (u[info.body] == 35 && info.indent < 4)
                if startsBlock || !prevParagraph { flushParagraph(&self) }
                if let marker = info.marker {
                    listColumns = listColumns.filter { $0 <= info.markerIndent } + [marker]
                } else if info.indent == 0 && info.depth == 0 && !prevParagraph {
                    listColumns = []
                }
                paragraph.append((line.start, info.body, line.end))
                prevParagraph = true; prevDepth = info.depth
                if u[info.body] == 35 { flushParagraph(&self); prevParagraph = false }
                index += 1
            }
            flushCode(&self)
            flushParagraph(&self)
            return MarkdownSourceMask.merged(zones)
        }

        /// Строчный код: серия `` ` `` длины n закрывается ближайшей серией той же длины в абзаце; перед серией нечётное число `\` экранирует первый знак.
        mutating func inlineCode(_ lines: [(start: Int, body: Int, end: Int)]) {
            guard !lines.isEmpty else { return }
            var positions: [Int] = []
            for line in lines { positions.append(contentsOf: line.body..<line.end) }
            var runs: [(start: Int, length: Int)] = []
            var cursor = 0
            while cursor < positions.count {
                guard u[positions[cursor]] == 96 else { cursor += 1; continue }
                var length = 0
                while cursor + length < positions.count, u[positions[cursor + length]] == 96, positions[cursor + length] == positions[cursor] + length { length += 1 }
                let total = length
                var start = cursor
                var slashes = 0
                var back = cursor - 1
                while back >= 0, u[positions[back]] == 92, positions[back] == positions[back + 1] - 1 { slashes += 1; back -= 1 }
                if slashes % 2 == 1 { start += 1; length -= 1 }
                if length > 0 { runs.append((positions[start], length)) }
                cursor += total
            }
            var index = 0
            while index < runs.count {
                if let close = runs[(index + 1)...].firstIndex(where: { $0.length == runs[index].length }) {
                    zones.append(NSRange(location: runs[index].start, length: runs[close].start + runs[close].length - runs[index].start))
                    index = close + 1
                } else {
                    index += 1
                }
            }
        }
    }
}

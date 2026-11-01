import Combine
import Foundation

enum FindReplaceMode: String, CaseIterable, Identifiable {
    case find = "查找"
    case replace = "替换"
    case goToLine = "跳转行"   // внутренний идентификатор, пользователю не показывается

    var id: String { rawValue }
}

/// Область поиска в панели: документ, выделение (`FindReplaceState.scope`) или все открытые документы.
enum FindScope: String, CaseIterable, Identifiable {
    case document, selection, openDocuments

    var id: String { rawValue }
}

/// Итог поиска по открытым документам для строки счётчика панели.
struct OpenDocumentsSummary: Equatable {
    var matchCount: Int
    var documentCount: Int
    var skippedTitles: [String]   // «имя (причина)», уже готовый текст
}

@MainActor
final class FindReplaceState: ObservableObject {
    enum MessageKind { case info, success, error, notice }

    @Published var mode: FindReplaceMode = .find
    @Published var query = ""
    @Published var replacement = ""
    @Published var interpretsEscapes = true
    @Published var isCaseSensitive = false
    @Published var usesRegex = false
    @Published var matchesWholeWord = false
    // Любое обычное присваивание сбрасывает вид сообщения; вид задаёт только show(_:kind:).
    @Published var message: String? { didSet { messageKind = .info } }
    @Published private(set) var messageKind: MessageKind = .info
    @Published var isWorking = false
    @Published var activeDocumentID: UUID?
    @Published var focusRequestID = UUID()
    @Published var isBarVisible = false
    @Published var goToLineText = ""
    @Published private(set) var matches: [NSRange]?
    private(set) var matchesDocumentID: UUID?
    /// «В выделении»: диапазон UTF-16 в координатах файла и ревизия текста на момент включения.
    struct Scope: Equatable {
        let documentID: UUID
        let range: NSRange
        let revision: UInt
    }
    @Published var scope: Scope?
    /// «Все открытые документы»: поиск и замена идут по всем вкладкам; область «В выделении» при этом снята.
    @Published var searchesOpenDocuments = false
    @Published private(set) var openDocumentsSummary: OpenDocumentsSummary?

    var area: FindScope {
        searchesOpenDocuments ? .openDocuments : (scope != nil ? .selection : .document)
    }

    var searchOptions: TextSearchService.Options {
        .init(caseSensitive: isCaseSensitive, usesRegex: usesRegex, wholeWord: matchesWholeWord)
    }

    func show(_ text: String?, kind: MessageKind) {
        message = text
        messageKind = kind
    }

    func setOpenDocumentsSummary(_ value: OpenDocumentsSummary?) {
        if openDocumentsSummary != value { openDocumentsSummary = value }
    }

    func setMatches(_ value: [NSRange]?, documentID: UUID?) {
        matches = value
        matchesDocumentID = documentID
    }
}

enum TextSearchService {
    struct CacheKey: Hashable, Sendable {
        let revision: UInt
        let query: String
        let caseSensitive: Bool
        var usesRegex = false
        var wholeWord = false
        var scope: NSRange? = nil
    }

    struct Options: Hashable, Sendable {
        var caseSensitive = false
        var usesRegex = false
        var wholeWord = false
        var isPlain: Bool { !usesRegex && !wholeWord }
    }

    enum SearchError: Error { case invalidPattern }

    static func interpreted(_ value: String, enabled: Bool) -> String {
        guard enabled else { return value }
        var result = ""
        var isEscaping = false

        for character in value {
            if isEscaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "s": result.append(" ")
                case "0": result.append("\0")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping { result.append("\\") }
        return result
    }

    static func nextRange(
        in text: String,
        query: String,
        after selection: NSRange,
        caseSensitive: Bool
    ) -> NSRange? {
        let nsText = text as NSString
        guard !query.isEmpty, nsText.length > 0 else { return nil }
        let options = compareOptions(caseSensitive: caseSensitive)
        let start = min(NSMaxRange(selection), nsText.length)
        let tail = NSRange(location: start, length: nsText.length - start)
        let match = nsText.range(of: query, options: options, range: tail)
        if match.location != NSNotFound { return match }
        let wrapped = nsText.range(
            of: query,
            options: options,
            range: NSRange(location: 0, length: start)
        )
        return wrapped.location == NSNotFound ? nil : wrapped
    }

    static func nextRange(
        in matches: [NSRange],
        after selection: NSRange
    ) -> NSRange? {
        guard !matches.isEmpty else { return nil }
        let location = NSMaxRange(selection)
        return matches.first(where: { $0.location >= location }) ?? matches[0]
    }

    static func previousRange(
        in text: String,
        query: String,
        before selection: NSRange,
        caseSensitive: Bool
    ) -> NSRange? {
        let nsText = text as NSString
        guard !query.isEmpty, nsText.length > 0 else { return nil }
        var options = compareOptions(caseSensitive: caseSensitive)
        options.insert(.backwards)
        let end = min(selection.location, nsText.length)
        let head = NSRange(location: 0, length: end)
        let match = nsText.range(of: query, options: options, range: head)
        if match.location != NSNotFound { return match }
        let wrapped = nsText.range(
            of: query,
            options: options,
            range: NSRange(location: end, length: nsText.length - end)
        )
        return wrapped.location == NSNotFound ? nil : wrapped
    }

    static func previousRange(
        in matches: [NSRange],
        before selection: NSRange
    ) -> NSRange? {
        guard !matches.isEmpty else { return nil }
        let location = selection.location
        return matches.last(where: { NSMaxRange($0) <= location }) ?? matches[matches.count - 1]
    }

    /// Участки текста, по которым идёт поиск: всё, кроме адресов `data:` (заголовка и данных).
    /// При `scope` участки урезаются областью поиска; пустые отбрасываются.
    static func searchableRanges(in text: String, scope: NSRange? = nil) -> [NSRange] {
        var parts: [NSRange] = []
        var location = 0
        for address in MarkdownMediaTable.addressRanges(in: text) {
            if address.location > location { parts.append(NSRange(location: location, length: address.location - location)) }
            location = NSMaxRange(address)
        }
        let length = (text as NSString).length
        if location < length { parts.append(NSRange(location: location, length: length - location)) }
        guard let scope else { return parts }
        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: length))
        return parts.compactMap {
            let part = NSIntersectionRange($0, clamped)
            return part.length > 0 ? part : nil
        }
    }

    /// Совпадения выражения по участкам `searchableRanges`. Границы участков прозрачны:
    /// `^`, `$` и проверки соседних символов видят настоящий текст, а не край участка.
    static func enumerateMatches(
        of regex: NSRegularExpression,
        in text: String,
        scope: NSRange? = nil,
        using body: (NSTextCheckingResult?, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        var stopped = false
        for part in searchableRanges(in: text, scope: scope) where !stopped {
            // reportProgress вызывает блок и внутри долгого совпадения, поэтому отмена прерывает и его.
            regex.enumerateMatches(
                in: text,
                options: [.reportProgress, .withTransparentBounds, .withoutAnchoringBounds],
                range: part
            ) { match, _, stop in
                body(match, stop)
                if stop.pointee.boolValue { stopped = true }
            }
        }
    }

    static func allRanges(
        in text: String,
        query: String,
        caseSensitive: Bool,
        scope: NSRange? = nil,
        isCancelled: () -> Bool = { false }
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let nsText = text as NSString
        let options = compareOptions(caseSensitive: caseSensitive)
        let queryLength = (query as NSString).length
        var matches: [NSRange] = []
        for part in searchableRanges(in: text, scope: scope) {
            let end = NSMaxRange(part)
            var location = part.location
            while location <= end - queryLength {
                if matches.count.isMultiple(of: 512), isCancelled() { return [] }
                let range = NSRange(location: location, length: end - location)
                let match = nsText.range(of: query, options: options, range: range)
                guard match.location != NSNotFound else { break }
                matches.append(match)
                location = max(match.location + max(match.length, 1), location + 1)
            }
        }
        return matches
    }

    static func selectionMatches(
        in text: String,
        query: String,
        selection: NSRange,
        caseSensitive: Bool
    ) -> Bool {
        let nsText = text as NSString
        guard selection.location != NSNotFound,
              NSMaxRange(selection) <= nsText.length,
              selection.length == (query as NSString).length else { return false }
        let selected = nsText.substring(with: selection)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return selected.compare(query, options: options) == .orderedSame
    }

    static func replacingAll(
        in text: String,
        query: String,
        replacement: String,
        caseSensitive: Bool,
        scope: NSRange? = nil,
        isCancelled: () -> Bool = { false }
    ) -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        let nsText = text as NSString
        let options = compareOptions(caseSensitive: caseSensitive)
        let parts = searchableRanges(in: text, scope: scope)
        var count = 0

        for part in parts {
            var location = part.location
            while location <= NSMaxRange(part) {
                if count.isMultiple(of: 512), isCancelled() { return (text, 0) }
                let range = NSRange(location: location, length: NSMaxRange(part) - location)
                let match = nsText.range(of: query, options: options, range: range)
                guard match.location != NSNotFound else { break }
                count += 1
                location = NSMaxRange(match)
            }
        }

        let output = NSMutableString(string: text)
        // С конца: замена не сдвигает ещё не обработанные участки.
        for part in parts.reversed() {
            _ = output.replaceOccurrences(of: query, with: replacement, options: options, range: part)
        }
        return (output as String, count)
    }

    /// Целое слово задаётся lookaround, а не \b: у запроса вроде "@foo" или "C++" края не словесные.
    static func regularExpression(query: String, options: Options) throws -> NSRegularExpression {
        var pattern = options.usesRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do { return try NSRegularExpression(pattern: pattern, options: flags) }
        catch { throw SearchError.invalidPattern }
    }

    static func allRanges(
        in text: String,
        query: String,
        options: Options,
        scope: NSRange? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if options.isPlain {
            return allRanges(in: text, query: query, caseSensitive: options.caseSensitive, scope: scope, isCancelled: isCancelled)
        }
        let regex = try regularExpression(query: query, options: options)
        var result: [NSRange] = []
        var cancelled = false
        enumerateMatches(of: regex, in: text, scope: scope) { match, stop in
            if isCancelled() { cancelled = true; stop.pointee = true; return }
            guard let range = match?.range, range.length > 0 else { return }
            result.append(range)
        }
        return cancelled ? [] : result
    }

    /// Шаблон замены в режиме регулярного выражения: $1, \$, \\ как в ICU; \n \r \t становятся управляющими символами.
    static func regexTemplate(_ value: String) -> String {
        var out = ""
        var pending = false
        for ch in value {
            if pending {
                switch ch {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                pending = false
            } else if ch == "\\" {
                pending = true
            } else {
                out.append(ch)
            }
        }
        if pending { out.append("\\\\") }
        return out
    }

    static func template(for replacement: String, options: Options, interpretsEscapes: Bool) -> String {
        options.usesRegex
            ? regexTemplate(replacement)
            : NSRegularExpression.escapedTemplate(for: interpreted(replacement, enabled: interpretsEscapes))
    }

    static func replaceAll(
        in text: String,
        query: String,
        replacement: String,
        options: Options,
        interpretsEscapes: Bool,
        scope: NSRange? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        if options.isPlain {
            return replacingAll(
                in: text,
                query: query,
                replacement: interpreted(replacement, enabled: interpretsEscapes),
                caseSensitive: options.caseSensitive,
                scope: scope,
                isCancelled: isCancelled
            )
        }
        let regex = try regularExpression(query: query, options: options)
        let tpl = template(for: replacement, options: options, interpretsEscapes: interpretsEscapes)
        let ns = text as NSString
        var output = ""
        var cursor = 0
        var count = 0
        var cancelled = false
        enumerateMatches(of: regex, in: text, scope: scope) { match, stop in
            if isCancelled() { cancelled = true; stop.pointee = true; return }
            // Пустые совпадения пропускаются, как в allRanges: иначе «Заменить все» меняло бы то, что поиск не нашёл.
            guard let match, match.range.length > 0 else { return }
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += regex.replacementString(for: match, in: text, offset: 0, template: tpl)
            cursor = NSMaxRange(match.range)
            count += 1
        }
        if cancelled { return (text, 0) }
        output += ns.substring(from: cursor)
        return (output, count)
    }

    /// Текст замены, если `selection` — ровно одно совпадение; иначе nil. Нужен для «Заменить».
    static func replacement(
        forSelection selection: NSRange,
        in text: String,
        query: String,
        replacement: String,
        options: Options,
        interpretsEscapes: Bool,
        scope: NSRange? = nil
    ) throws -> String? {
        let ns = text as NSString
        guard !query.isEmpty, selection.location != NSNotFound, NSMaxRange(selection) <= ns.length,
              let part = searchableRanges(in: text, scope: scope).first(where: { NSMaxRange(selection) <= NSMaxRange($0) }),
              selection.location >= part.location else { return nil }
        if options.isPlain {
            return selectionMatches(in: text, query: query, selection: selection, caseSensitive: options.caseSensitive)
                ? interpreted(replacement, enabled: interpretsEscapes) : nil
        }
        let regex = try regularExpression(query: query, options: options)
        // Ищем до конца текста, а не только в выделении: жадные шаблоны оцениваются так же, как при поиске.
        let tail = NSRange(location: selection.location, length: NSMaxRange(part) - selection.location)
        guard let match = regex.firstMatch(
            in: text,
            options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
            range: tail
        ), match.range == selection, selection.length > 0 else { return nil }
        return regex.replacementString(
            for: match,
            in: text,
            offset: 0,
            template: template(for: replacement, options: options, interpretsEscapes: interpretsEscapes)
        )
    }

    /// Обратное к `interpreted(_, enabled: true)`: \, LF, CR, TAB и NUL переживают круг.
    static func escapedForInterpretation(_ value: String) -> String {
        var out = ""
        // По скалярам: CRLF в Character — один символ, и сравнение с "\r" и "\n" по отдельности его бы пропустило.
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\0": out.append("\\0")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Номер (с 1) совпадения, равного `selection`; matches отсортированы.
    static func currentIndex(in matches: [NSRange], selection: NSRange) -> Int? {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].location < selection.location { low = mid + 1 } else { high = mid }
        }
        guard low < matches.count, matches[low] == selection else { return nil }
        return low + 1
    }

    /// Первый индекс, чьё совпадение заканчивается правее `location`.
    static func firstIndex(in matches: [NSRange], endingAfter location: Int) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(matches[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func compareOptions(caseSensitive: Bool) -> NSString.CompareOptions {
        caseSensitive ? [.literal] : [.literal, .caseInsensitive]
    }
}

/// Per-document search result cache with deterministic least-recently-used eviction.
/// The cache stores only ranges; the caller remains responsible for revision validation
/// through `CacheKey`.
struct SearchMatchCacheStore {
    struct Entry {
        let key: TextSearchService.CacheKey
        let matches: [NSRange]
    }

    let capacity: Int
    private(set) var entries: [UUID: Entry] = [:]
    private var usage: [UUID] = []

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for documentID: UUID, key: TextSearchService.CacheKey) -> Entry? {
        guard let entry = entries[documentID], entry.key == key else { return nil }
        touch(documentID)
        return entry
    }

    mutating func insert(_ entry: Entry, for documentID: UUID) {
        entries[documentID] = entry
        touch(documentID)
        while entries.count > capacity, let leastRecentlyUsed = usage.first {
            usage.removeFirst()
            entries.removeValue(forKey: leastRecentlyUsed)
        }
    }

    private mutating func touch(_ documentID: UUID) {
        usage.removeAll { $0 == documentID }
        usage.append(documentID)
    }
}

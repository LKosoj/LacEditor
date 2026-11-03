import Foundation
import Yams

/// Одно поле шапки заметки хранилища.
struct VaultFrontmatterField: Equatable, Identifiable, Sendable {
    enum Value: Equatable, Sendable {
        /// Одна строка; значение без кавычек и без комментария в конце.
        case scalar(String)
        /// Простые слова (только для `tags`): `[a, b]` или `- a` построчно.
        case list([String])
        /// Многострочное или сложное: исходный текст значения как есть (для показа, не для правки).
        case readOnly(String)
    }

    var key: String
    var value: Value
    /// Номер строки ключа в файле, с 1.
    var line: Int
    /// Ключ входит в `VaultServerRules.systemFrontmatterFields`.
    var isSystem: Bool
    /// Ключ может повторяться, поэтому номер строки входит в идентификатор.
    var id: String { "\(line):\(key)" }
}

struct VaultFrontmatter: Equatable, Sendable {
    /// Поля в порядке файла.
    var fields: [VaultFrontmatterField]
    /// Вся шапка от первой `---` (после BOM) до конца закрывающей строки, UTF-16.
    var range: NSRange
    /// Окончание строк открывающей `---`: "\n", "\r\n" или "\r".
    var lineEnding: String
}

enum VaultFrontmatterParseResult: Equatable, Sendable {
    /// Шапки нет: текст не начинается с `---` или закрывающей `---` нет.
    case none
    case parsed(VaultFrontmatter)
    /// Ошибка YAML; `line` с 1, номер в файле (а не в шапке).
    case failed(line: Int, reason: String)
}

enum VaultFrontmatterEdit: Equatable, Sendable {
    /// Пусто — убрать поле; поля нет — добавить в конец шапки.
    case setScalar(key: String, value: String)
    /// Поля нет — создаётся `key: [item]`; повтор (без учёта регистра) — `.duplicate`.
    case addListItem(key: String, item: String)
    case removeListItem(key: String, item: String)
}

struct VaultFrontmatterPatch: Equatable, Sendable {
    var range: NSRange
    var replacement: String
}

enum VaultFrontmatterEditError: Error, Equatable {
    /// В шапке ошибка YAML.
    case parseFailed(line: Int)
    /// Поле сложное или многострочное.
    case readOnlyField(String)
    /// Перевод строки или управляющий символ в значении, пустой или недопустимый тег, недопустимый ключ.
    case invalidValue
    /// Тег уже есть (без учёта регистра): для пользователя не ошибка.
    case duplicate
    case notFound
    /// Повторное чтение Yams показало расхождение: правка отклоняется.
    case verificationFailed
}

/// Правка шапки YAML построчными заплатками: меняется только целевое поле, всё остальное (порядок, кавычки соседей,
/// комментарии, пустые строки, окончания строк, BOM, текст после шапки) остаётся нетронутым байт в байт.
/// Границы шапки — как в `MarkdownPresentationParser.frontMatter`; начало поля — как в `VaultMerge.records`
/// (первая колонка не пробел/табуляция/`#`/`-`, дальше `:`). Результат перечитывается Yams.
enum VaultFrontmatterEditor {
    // MARK: Внутренние типы

    private struct Line {
        var text: String
        var eol: String
    }

    /// Поле: строка ключа и строки продолжения. `contentEnd` — после последней строки, не пустой и не комментария.
    private struct Block {
        var key: String
        var start: Int
        var contentEnd: Int
        var end: Int
    }

    private struct Unsupported: Error {
        var index: Int
    }

    private enum Style { case plain, double, single }

    /// Значение в строке ключа или элемента: диапазон в строке (UTF-16), стиль, пусто ли.
    private struct Scan {
        var range: NSRange
        var style: Style
        var isEmpty: Bool
        var colonEnd: Int
    }

    private struct Header {
        var range: NSRange
        var bodyStart: Int
        var body: String
        var eol: String
    }

    private typealias Entry = (key: String, value: Node)

    private enum Analysis {
        case none
        case failed(line: Int, reason: String)
        case ok(header: Header, lines: [Line], blocks: [Block], entries: [Entry], duplicates: Set<String>)
    }

    // MARK: Чтение

    static func parse(_ text: String) -> VaultFrontmatterParseResult {
        switch analyze(text) {
        case .none:
            return .none
        case let .failed(line, reason):
            return .failed(line: line, reason: reason)
        case let .ok(header, lines, blocks, _, duplicates):
            var fields: [VaultFrontmatterField] = []
            for block in blocks {
                let value = fieldValue(block, lines: lines, isDuplicate: duplicates.contains(block.key))
                fields.append(VaultFrontmatterField(
                    key: block.key, value: value, line: block.start + 2,
                    isSystem: VaultServerRules.systemFrontmatterFields.contains(block.key)))
            }
            return .parsed(VaultFrontmatter(fields: fields, range: header.range, lineEnding: header.eol))
        }
    }

    private static func analyze(_ text: String) -> Analysis {
        guard let front = MarkdownPresentationParser.frontMatter(text), front.markers.count == 2 else { return .none }
        let ns = text as NSString
        let opening = ns.lineRange(for: NSRange(location: front.markers[0].location, length: 0))
        let bodyStart = NSMaxRange(opening)
        let bodyEnd = front.markers[1].location
        guard bodyEnd >= bodyStart else { return .none }
        let openingText = ns.substring(with: opening)
        let eol = openingText.hasSuffix("\r\n") ? "\r\n" : (openingText.hasSuffix("\r") ? "\r" : "\n")
        let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
        let range = NSRange(location: front.markers[0].location, length: front.range.length - front.markers[0].location)
        let header = Header(range: range, bodyStart: bodyStart, body: body, eol: eol)
        let entries: [Entry]
        do {
            entries = try Self.entries(body)
        } catch {
            return .failed(line: failureLine(error), reason: String(describing: error))
        }
        let lines = split(body)
        let blocks: [Block]
        do {
            blocks = try Self.blocks(lines)
        } catch let error as Unsupported {
            return .failed(line: error.index + 2, reason: "unsupported")
        } catch {
            return .failed(line: 2, reason: String(describing: error))
        }
        var seen = Set<String>(), duplicates = Set<String>()
        for block in blocks where !seen.insert(block.key).inserted { duplicates.insert(block.key) }
        return .ok(header: header, lines: lines, blocks: blocks, entries: entries, duplicates: duplicates)
    }

    private static func failureLine(_ error: Error) -> Int {
        guard let yaml = error as? YamlError else { return 2 }
        switch yaml {
        case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
            // Метка считается от первой строки тела; в файле перед ней открывающая `---`.
            return max(2, mark.line + 1)
        default:
            return 2
        }
    }

    private struct NotMapping: Error {}

    private static func entries(_ yaml: String) throws -> [Entry] {
        guard let root = try Yams.compose(yaml: yaml) else { return [] }
        guard let mapping = root.mapping else { throw NotMapping() }
        var result: [Entry] = []
        for item in mapping {
            guard let name = item.key.scalar?.string else { throw NotMapping() }
            result.append((key: name, value: item.value))
        }
        return result
    }

    private static func fieldValue(_ block: Block, lines: [Line], isDuplicate: Bool) -> VaultFrontmatterField.Value {
        let raw = rawText(block, lines: lines)
        guard !isDuplicate, let scan = scanValue(lines[block.start].text) else { return .readOnly(raw) }
        let line = lines[block.start].text as NSString
        let hasMore = block.contentEnd > block.start + 1
        if block.key == "tags" {
            if let items = tagItems(block, lines: lines, scan: scan) { return .list(items) }
            return .readOnly(raw)
        }
        if scan.isEmpty { return hasMore ? .readOnly(raw) : .scalar("") }
        if hasMore { return .readOnly(raw) }
        let token = line.substring(with: scan.range)
        if scan.style == .plain, let first = token.first, "[{|>&*!".contains(first) { return .readOnly(raw) }
        if let node = scalarNode(token), let scalar = node.scalar { return .scalar(scalar.string) }
        return .readOnly(raw)
    }

    /// Значение поля так, как оно записано: после двоеточия и строки продолжения.
    private static func rawText(_ block: Block, lines: [Line]) -> String {
        var parts: [String] = []
        let first = lines[block.start].text as NSString
        if let scan = scanValue(lines[block.start].text) {
            parts.append(first.substring(from: scan.colonEnd))
        }
        for index in (block.start + 1)..<max(block.start + 1, block.contentEnd) { parts.append(lines[index].text) }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Элементы `tags`: `[a, b]`, `[]`, пустое значение с блочным списком или без него; иначе nil.
    private static func tagItems(_ block: Block, lines: [Line], scan: Scan) -> [String]? {
        let line = lines[block.start].text as NSString
        if scan.isEmpty {
            if block.contentEnd == block.start + 1 { return [] }
            return blockItems(block, lines: lines)?.map(\.value)
        }
        guard block.contentEnd == block.start + 1, scan.style == .plain, scan.range.length >= 2,
              line.character(at: scan.range.location) == 91,
              line.character(at: NSMaxRange(scan.range) - 1) == 93,
              let ranges = flowItems(line, open: scan.range.location, close: NSMaxRange(scan.range) - 1) else { return nil }
        var result: [String] = []
        for range in ranges {
            guard let value = scalarNode(line.substring(with: range))?.scalar?.string else { return nil }
            result.append(value)
        }
        return result
    }

    /// Элементы блочного списка (`- a`, по одной строке): строка и значение; сложный элемент — nil.
    private static func blockItems(_ block: Block, lines: [Line]) -> [(index: Int, value: String)]? {
        var result: [(index: Int, value: String)] = []
        for index in (block.start + 1)..<max(block.start + 1, block.contentEnd) {
            let text = lines[index].text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard isItemStart(trimmed) else { return nil }
            let ns = text as NSString
            var dash = 0
            while dash < ns.length, ns.character(at: dash) == 32 || ns.character(at: dash) == 9 { dash += 1 }
            guard let scan = scanValue(ns, from: dash + 1), !scan.isEmpty else { return nil }
            let token = ns.substring(with: scan.range)
            if scan.style == .plain, let first = token.first, "[{|>&*!".contains(first) { return nil }
            guard let value = scalarNode(token)?.scalar?.string else { return nil }
            result.append((index, value))
        }
        return result
    }

    // MARK: Правка

    /// Одна замена на всю правку; nil — текст не изменится.
    static func patch(for edit: VaultFrontmatterEdit, in text: String) throws -> VaultFrontmatterPatch? {
        switch analyze(text) {
        case .none:
            return try createHeader(edit, in: text)
        case let .failed(line, _):
            throw VaultFrontmatterEditError.parseFailed(line: line)
        case let .ok(header, lines, blocks, before, duplicates):
            var lines = lines
            let target: String
            var expectedScalar: String?? = nil
            var expectedList: [String]?
            switch edit {
            case let .setScalar(key, value):
                target = key
                let trimmed = try cleanScalar(value)
                try setScalar(key, trimmed, lines: &lines, blocks: blocks, duplicates: duplicates, eol: header.eol)
                expectedScalar = .some(trimmed.isEmpty ? nil : trimmed)
            case let .addListItem(key, item):
                target = key
                let clean = try cleanItem(item, key: key)
                let old = try addListItem(key, clean, lines: &lines, blocks: blocks, duplicates: duplicates, eol: header.eol)
                expectedList = old + [clean]
            case let .removeListItem(key, item):
                target = key
                let removed = try removeListItem(key, item, lines: &lines, blocks: blocks, duplicates: duplicates, eol: header.eol)
                expectedList = removed
            }
            let newBody = lines.map { $0.text + $0.eol }.joined()
            guard newBody != header.body else { return nil }
            let after: [Entry]
            do { after = try entries(newBody) } catch { throw VaultFrontmatterEditError.verificationFailed }
            try verify(target: target, before: before, after: after, expectedScalar: expectedScalar, expectedList: expectedList)
            return diff(old: header.body, new: newBody, offset: header.bodyStart)
        }
    }

    private static func cleanScalar(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 0x2028 || $0.value == 0x2029 || $0.value == 0x85 }) else {
            throw VaultFrontmatterEditError.invalidValue
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func cleanItem(_ item: String, key: String) throws -> String {
        if key == "tags" {
            guard let tag = normalizedTag(item) else { throw VaultFrontmatterEditError.invalidValue }
            return tag
        }
        let clean = try cleanScalar(item)
        guard !clean.isEmpty, !clean.contains(",") else { throw VaultFrontmatterEditError.invalidValue }
        return clean
    }

    private static func validKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-. "))
        return key.unicodeScalars.allSatisfy { allowed.contains($0) } && !key.hasSuffix(" ")
    }

    private static func setScalar(_ key: String, _ value: String, lines: inout [Line], blocks: [Block],
                                  duplicates: Set<String>, eol: String) throws {
        let matches = blocks.filter { $0.key == key }
        if let block = matches.first {
            guard !duplicates.contains(key), case let .scalar(current) = fieldValue(block, lines: lines, isDuplicate: false) else {
                throw VaultFrontmatterEditError.readOnlyField(key)
            }
            if value.isEmpty {
                lines.removeSubrange(block.start..<block.contentEnd)
                return
            }
            guard value != current else { return }
            guard let scan = scanValue(lines[block.start].text) else { throw VaultFrontmatterEditError.readOnlyField(key) }
            let line = lines[block.start].text as NSString
            let oldTag = scan.isEmpty ? nil : scalarNode(line.substring(with: scan.range))?.tag
            let token = scalarToken(value, style: scan.style, oldTag: oldTag)
            if scan.isEmpty {
                replace(&lines, index: block.start, range: NSRange(location: scan.colonEnd, length: 0), with: " " + token)
            } else {
                replace(&lines, index: block.start, range: scan.range, with: token)
            }
            return
        }
        guard !value.isEmpty else { return }
        guard validKey(key) else { throw VaultFrontmatterEditError.invalidValue }
        insert(["\(key): \(scalarToken(value, style: .plain, oldTag: nil))"], at: blocks.last?.contentEnd ?? 0, lines: &lines, eol: eol)
    }

    /// Возвращает прежние элементы списка (для проверки).
    private static func addListItem(_ key: String, _ item: String, lines: inout [Line], blocks: [Block],
                                    duplicates: Set<String>, eol: String) throws -> [String] {
        let matches = blocks.filter { $0.key == key }
        guard let block = matches.first else {
            guard validKey(key) else { throw VaultFrontmatterEditError.invalidValue }
            insert(["\(key): [\(scalarToken(item, style: .plain, oldTag: nil))]"], at: blocks.last?.contentEnd ?? 0, lines: &lines, eol: eol)
            return []
        }
        guard !duplicates.contains(key), case let .list(current) = fieldValue(block, lines: lines, isDuplicate: false),
              let scan = scanValue(lines[block.start].text) else { throw VaultFrontmatterEditError.readOnlyField(key) }
        if current.contains(where: { $0.lowercased() == item.lowercased() }) { throw VaultFrontmatterEditError.duplicate }
        let line = lines[block.start].text as NSString
        if scan.isEmpty {
            // Блочный список: новая строка после последнего элемента, с тем же отступом и стилем кавычек.
            let items = blockItems(block, lines: lines) ?? []
            guard let last = items.last else {
                insert(["  - \(scalarToken(item, style: .plain, oldTag: nil))"], at: block.contentEnd, lines: &lines, eol: eol)
                return current
            }
            let text = lines[last.index].text as NSString
            var position = 0
            while position < text.length, text.character(at: position) == 32 || text.character(at: position) == 9 { position += 1 }
            position += 1
            let dashEnd = position
            while position < text.length, text.character(at: position) == 32 || text.character(at: position) == 9 { position += 1 }
            let style = scanValue(text, from: dashEnd).map(\.style) ?? .plain
            let prefix = text.substring(to: position)
            insert(["\(prefix)\(scalarToken(item, style: style, oldTag: nil))"], at: last.index + 1, lines: &lines, eol: eol)
            return current
        }
        let open = scan.range.location, close = NSMaxRange(scan.range) - 1
        guard let ranges = flowItems(line, open: open, close: close) else { throw VaultFrontmatterEditError.readOnlyField(key) }
        let token = scalarToken(item, style: .plain, oldTag: nil)
        if let last = ranges.last {
            replace(&lines, index: block.start, range: NSRange(location: NSMaxRange(last), length: 0), with: ", " + token)
        } else {
            replace(&lines, index: block.start, range: NSRange(location: open + 1, length: close - open - 1), with: token)
        }
        return current
    }

    /// Возвращает ожидаемые элементы после удаления.
    private static func removeListItem(_ key: String, _ item: String, lines: inout [Line], blocks: [Block],
                                       duplicates: Set<String>, eol: String) throws -> [String] {
        guard let block = blocks.first(where: { $0.key == key }) else { throw VaultFrontmatterEditError.notFound }
        guard !duplicates.contains(key), case let .list(current) = fieldValue(block, lines: lines, isDuplicate: false),
              let scan = scanValue(lines[block.start].text) else { throw VaultFrontmatterEditError.readOnlyField(key) }
        let wanted = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let position = current.firstIndex(of: wanted) ?? current.firstIndex(where: { $0.lowercased() == wanted.lowercased() }) else {
            throw VaultFrontmatterEditError.notFound
        }
        var expected = current
        expected.remove(at: position)
        let line = lines[block.start].text as NSString
        if scan.isEmpty {
            guard let items = blockItems(block, lines: lines), items.count == current.count else { throw VaultFrontmatterEditError.readOnlyField(key) }
            lines.remove(at: items[position].index)
            if expected.isEmpty {
                // Последний тег убран: поле остаётся пустым списком.
                replace(&lines, index: block.start, range: NSRange(location: scan.colonEnd, length: 0), with: " []")
            }
            return expected
        }
        guard let ranges = flowItems(line, open: scan.range.location, close: NSMaxRange(scan.range) - 1), ranges.count == current.count else {
            throw VaultFrontmatterEditError.readOnlyField(key)
        }
        let removal: NSRange
        if ranges.count == 1 {
            removal = NSRange(location: scan.range.location + 1, length: NSMaxRange(scan.range) - 1 - scan.range.location - 1)
        } else if position == 0 {
            removal = NSRange(location: ranges[0].location, length: ranges[1].location - ranges[0].location)
        } else {
            removal = NSRange(location: NSMaxRange(ranges[position - 1]), length: NSMaxRange(ranges[position]) - NSMaxRange(ranges[position - 1]))
        }
        replace(&lines, index: block.start, range: removal, with: "")
        return expected
    }

    /// Заметка без шапки: первая правка создаёт её в начале текста после BOM, с окончанием строк документа.
    private static func createHeader(_ edit: VaultFrontmatterEdit, in text: String) throws -> VaultFrontmatterPatch? {
        let body: String
        switch edit {
        case let .setScalar(key, value):
            let clean = try cleanScalar(value)
            guard !clean.isEmpty else { return nil }
            guard validKey(key) else { throw VaultFrontmatterEditError.invalidValue }
            body = "\(key): \(scalarToken(clean, style: .plain, oldTag: nil))"
        case let .addListItem(key, item):
            let clean = try cleanItem(item, key: key)
            guard validKey(key) else { throw VaultFrontmatterEditError.invalidValue }
            body = "\(key): [\(scalarToken(clean, style: .plain, oldTag: nil))]"
        case .removeListItem:
            throw VaultFrontmatterEditError.notFound
        }
        let ns = text as NSString
        var eol = "\n"
        var position = 0
        while position < ns.length {
            let unit = ns.character(at: position)
            if unit == 13 { eol = position + 1 < ns.length && ns.character(at: position + 1) == 10 ? "\r\n" : "\r"; break }
            if unit == 10 { break }
            position += 1
        }
        guard (try? entries(body + "\n")) != nil else { throw VaultFrontmatterEditError.verificationFailed }
        let offset = ns.length > 0 && ns.character(at: 0) == 0xFEFF ? 1 : 0
        return VaultFrontmatterPatch(range: NSRange(location: offset, length: 0), replacement: "---\(eol)\(body)\(eol)---\(eol)")
    }

    private static func verify(target: String, before: [Entry], after: [Entry], expectedScalar: String??, expectedList: [String]?) throws {
        let failure = VaultFrontmatterEditError.verificationFailed
        let oldOthers = before.filter { $0.key != target }, newOthers = after.filter { $0.key != target }
        guard oldOthers.count == newOthers.count else { throw failure }
        for (old, new) in zip(oldOthers, newOthers) {
            guard old.key == new.key, old.value == new.value else { throw failure }
        }
        let new = after.filter { $0.key == target }
        if let expectedScalar {
            if let value = expectedScalar {
                guard new.count == 1, new[0].value.scalar?.string == value else { throw failure }
            } else {
                guard new.isEmpty else { throw failure }
            }
        }
        if let expectedList {
            guard new.count == 1, strings(of: new[0].value) == expectedList else { throw failure }
        }
    }

    private static func strings(of node: Node) -> [String]? {
        if let sequence = node.sequence {
            var result: [String] = []
            for item in sequence {
                guard let scalar = item.scalar else { return nil }
                result.append(scalar.string)
            }
            return result
        }
        if let scalar = node.scalar, scalar.string.isEmpty { return [] }
        return nil
    }

    // MARK: Значения

    /// Допустимое имя тега: без пробелов и `, [ ] { } # " '`, не только цифры; ведущий `#` отбрасывается до проверки.
    static func normalizedTag(_ raw: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.hasPrefix("#") { tag.removeFirst() }
        guard !tag.isEmpty, !tag.allSatisfy(\.isNumber) else { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",[]{}#\"'"))
        guard tag.unicodeScalars.allSatisfy({ !forbidden.contains($0) && $0.value >= 32 }) else { return nil }
        return tag
    }

    /// «ГГГГ-ММ-ДД» в компоненты (без часовых поясов); nil для остального и для несуществующих дат.
    static func dateComponents(from value: String) -> DateComponents? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(calendar: calendar, year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    static func dateString(from components: DateComponents) -> String {
        String(format: "%04ld-%02ld-%02ld", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Значение для записи в строку: стиль кавычек прежнего значения сохраняется; без кавычек — только если Yams читает строку как есть.
    private static func scalarToken(_ value: String, style: Style, oldTag: Tag?) -> String {
        switch style {
        case .double:
            return doubleQuoted(value)
        case .single:
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case .plain:
            if isPlainSafe(value, oldTag: oldTag) { return value }
            return doubleQuoted(value)
        }
    }

    private static func doubleQuoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func isPlainSafe(_ value: String, oldTag: Tag?) -> Bool {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespaces), !value.contains("\t") else { return false }
        guard let root = try? Yams.compose(yaml: "k: \(value)"), let mapping = root.mapping, mapping.count == 1,
              let node = mapping.first?.value, let scalar = node.scalar, scalar.string == value else { return false }
        return node.tag == Tag(.str) || node.tag == oldTag
    }

    // MARK: Строки и поля

    private static func split(_ text: String) -> [Line] {
        let ns = text as NSString
        var result: [Line] = []
        var position = 0
        while position < ns.length {
            var end = position
            while end < ns.length, ns.character(at: end) != 10, ns.character(at: end) != 13 { end += 1 }
            var next = end
            if next < ns.length {
                if ns.character(at: next) == 13, next + 1 < ns.length, ns.character(at: next + 1) == 10 { next += 2 } else { next += 1 }
            }
            result.append(Line(text: ns.substring(with: NSRange(location: position, length: end - position)),
                               eol: ns.substring(with: NSRange(location: end, length: next - end))))
            position = next
        }
        return result
    }

    private static let keyPattern = try! NSRegularExpression(
        pattern: ##"^(?:"([^"\\]*)"|'([^']*)'|([^\s#:"'\[\]{},&*!|>%@`?\-][^:#]*?))[ \t]*:(?:[ \t]|$)"##)

    /// Имя ключа и позиция двоеточия в строке верхнего уровня.
    private static func key(of text: String) -> (name: String, colon: Int)? {
        let ns = text as NSString
        guard let match = keyPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let end = NSMaxRange(match.range)
        let colon = ns.character(at: end - 1) == 58 ? end - 1 : end - 2
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return (ns.substring(with: match.range(at: group)), colon)
        }
        return nil
    }

    private static func isBlankOrComment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func isItemStart(_ trimmed: String) -> Bool {
        trimmed == "-" || trimmed.hasPrefix("- ") || trimmed.hasPrefix("-\t")
    }

    /// Поля верхнего уровня. Строка нулевого отступа, не похожая на ключ, — неподдерживаемая запись.
    private static func blocks(_ lines: [Line]) throws -> [Block] {
        var result: [Block] = []
        for (index, line) in lines.enumerated() {
            guard let first = line.text.first, first != " ", first != "\t", first != "#" else { continue }
            if isItemStart(line.text), !result.isEmpty { continue }
            guard let name = key(of: line.text)?.name else { throw Unsupported(index: index) }
            result.append(Block(key: name, start: index, contentEnd: index + 1, end: lines.count))
        }
        for position in result.indices {
            let end = position + 1 < result.count ? result[position + 1].start : lines.count
            result[position].end = end
            var content = end
            while content > result[position].start + 1, isBlankOrComment(lines[content - 1].text) { content -= 1 }
            result[position].contentEnd = content
        }
        return result
    }

    /// Значение в строке ключа: после двоеточия.
    private static func scanValue(_ text: String) -> Scan? {
        guard let key = key(of: text) else { return nil }
        return scanValue(text as NSString, from: key.colon + 1)
    }

    /// Значение, начиная с позиции `from` (сразу после `:` или `-`).
    private static func scanValue(_ ns: NSString, from colonEnd: Int) -> Scan? {
        let length = ns.length
        func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
        var start = colonEnd
        while start < length, isSpace(ns.character(at: start)) { start += 1 }
        if start == length || (ns.character(at: start) == 35 && start > colonEnd) {
            return Scan(range: NSRange(location: colonEnd, length: 0), style: .plain, isEmpty: true, colonEnd: colonEnd)
        }
        let first = ns.character(at: start)
        if first == 34 || first == 39 {
            var index = start + 1
            var end: Int?
            while index < length {
                let unit = ns.character(at: index)
                if first == 34, unit == 92 { index += 2; continue }
                if unit == first {
                    if first == 39, index + 1 < length, ns.character(at: index + 1) == 39 { index += 2; continue }
                    end = index + 1
                    break
                }
                index += 1
            }
            guard let end else { return nil }
            var tail = end
            while tail < length, isSpace(ns.character(at: tail)) { tail += 1 }
            guard tail == length || ns.character(at: tail) == 35 else { return nil }
            return Scan(range: NSRange(location: start, length: end - start), style: first == 34 ? .double : .single,
                        isEmpty: false, colonEnd: colonEnd)
        }
        var end = length
        var index = start
        while index + 1 < length {
            if isSpace(ns.character(at: index)), ns.character(at: index + 1) == 35 { end = index; break }
            index += 1
        }
        while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
        return Scan(range: NSRange(location: start, length: end - start), style: .plain, isEmpty: false, colonEnd: colonEnd)
    }

    /// Узел из одного значения; nil — не скаляр или ошибка.
    private static func scalarNode(_ token: String) -> Node? {
        guard let node = try? Yams.compose(yaml: token), node.scalar != nil else { return nil }
        return node
    }

    /// Диапазоны элементов однострочного `[a, "b", 'c']` (без пробелов по краям); вложенные скобки, пустые элементы — nil.
    private static func flowItems(_ line: NSString, open: Int, close: Int) -> [NSRange]? {
        func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
        var ranges: [NSRange] = []
        var start = open + 1
        var quote: unichar = 0
        var seenContent = false
        var index = open + 1
        func finish(_ end: Int) -> Bool {
            var from = start, to = end
            while from < to, isSpace(line.character(at: from)) { from += 1 }
            while to > from, isSpace(line.character(at: to - 1)) { to -= 1 }
            guard to > from else { return false }
            ranges.append(NSRange(location: from, length: to - from))
            return true
        }
        while index < close {
            let unit = line.character(at: index)
            if quote != 0 {
                if quote == 34, unit == 92 { index += 2; continue }
                if unit == quote {
                    if quote == 39, index + 1 < close, line.character(at: index + 1) == 39 { index += 2; continue }
                    quote = 0
                }
                index += 1
                continue
            }
            if unit == 91 || unit == 123 || unit == 93 || unit == 125 { return nil }
            if unit == 44 {
                guard finish(index) else { return nil }
                start = index + 1
                seenContent = false
            } else if !isSpace(unit), !seenContent {
                seenContent = true
                if unit == 34 || unit == 39 { quote = unit }
            }
            index += 1
        }
        guard quote == 0 else { return nil }
        if !seenContent, ranges.isEmpty { return [] }
        guard finish(close) else { return nil }
        return ranges
    }

    private static func replace(_ lines: inout [Line], index: Int, range: NSRange, with replacement: String) {
        lines[index].text = (lines[index].text as NSString).replacingCharacters(in: range, with: replacement)
    }

    private static func insert(_ texts: [String], at index: Int, lines: inout [Line], eol: String) {
        if index > 0, index <= lines.count, lines[index - 1].eol.isEmpty { lines[index - 1].eol = eol }
        lines.insert(contentsOf: texts.map { Line(text: $0, eol: eol) }, at: index)
    }

    /// Минимальная замена между старым и новым телом шапки; суррогатные пары не разрезаются.
    private static func diff(old: String, new: String, offset: Int) -> VaultFrontmatterPatch {
        let oldNS = old as NSString, newNS = new as NSString
        let common = min(oldNS.length, newNS.length)
        var prefix = 0
        while prefix < common, oldNS.character(at: prefix) == newNS.character(at: prefix) { prefix += 1 }
        while prefix > 0, prefix < oldNS.length, UTF16.isTrailSurrogate(oldNS.character(at: prefix)) { prefix -= 1 }
        while prefix > 0, prefix < newNS.length, UTF16.isTrailSurrogate(newNS.character(at: prefix)) { prefix -= 1 }
        var suffix = 0
        while suffix < common - prefix,
              oldNS.character(at: oldNS.length - 1 - suffix) == newNS.character(at: newNS.length - 1 - suffix) { suffix += 1 }
        while suffix > 0, UTF16.isTrailSurrogate(oldNS.character(at: oldNS.length - suffix)) { suffix -= 1 }
        let range = NSRange(location: offset + prefix, length: oldNS.length - prefix - suffix)
        let replacement = newNS.substring(with: NSRange(location: prefix, length: newNS.length - prefix - suffix))
        return VaultFrontmatterPatch(range: range, replacement: replacement)
    }
}

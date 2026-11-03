import Foundation
import Yams

enum StoryCardHeaderEdit: Equatable {
    case setType(StoryCardType)
    case addAlias(String)
    case removeAlias(String)
    case addRelation(StoryCardRelation)
    case removeRelation(StoryCardRelation)
}

struct StoryCardHeaderPatch: Equatable {
    /// Диапазон UTF-16 в исходном тексте.
    var range: NSRange
    var replacement: String
    /// Заполнено, если правка добавила `id`.
    var addedID: UUID?
}

enum StoryCardHeaderEditError: Error, Equatable {
    case noHeader, flowStyle, verificationFailed, duplicateAlias, emptyValue, notFound
}

/// Правка шапки карточки построчными заплатками. Известные ключи (`type`, `id`, `aliases`, `relations`) меняются,
/// всё остальное (чужие поля, комментарии, пустые строки, окончания строк) остаётся нетронутым.
/// Результат перечитывается Yams: при любом расхождении правка отклоняется.
enum StoryCardHeaderEditor {
    private struct Line {
        var text: String
        var eol: String
    }

    private struct Block {
        var key: String
        var start: Int
        /// Конец содержимого (без хвостовых пустых строк и комментариев) и конец блока; индексы исключающие.
        var contentEnd: Int
        var end: Int
    }

    /// Строит ОДНУ замену для всей шапки (одна отменяемая правка).
    static func patch(for edit: StoryCardHeaderEdit, in text: String, newID: () -> UUID) throws -> StoryCardHeaderPatch {
        let ns = text as NSString
        guard let front = MarkdownPresentationParser.frontMatter(text), front.markers.count == 2 else {
            throw StoryCardHeaderEditError.noHeader
        }
        let opening = ns.lineRange(for: NSRange(location: front.markers[0].location, length: 0))
        let bodyStart = NSMaxRange(opening)
        let bodyEnd = front.markers[1].location
        guard bodyEnd >= bodyStart else { throw StoryCardHeaderEditError.noHeader }
        let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
        let openingText = ns.substring(with: opening)
        let eol = openingText.hasSuffix("\r\n") ? "\r\n" : (openingText.hasSuffix("\r") ? "\r" : "\n")

        let before = try entries(body)
        var lines = split(body)
        var target = ""
        switch edit {
        case let .setType(type):
            target = "type"
            try setType(type, lines: &lines, eol: eol)
        case let .addAlias(value):
            target = "aliases"
            try addAlias(value, lines: &lines, eol: eol)
        case let .removeAlias(value):
            target = "aliases"
            try removeAlias(value, lines: &lines, eol: eol)
        case let .addRelation(relation):
            target = "relations"
            try addRelation(relation, lines: &lines, eol: eol)
        case let .removeRelation(relation):
            target = "relations"
            try removeRelation(relation, lines: &lines, eol: eol)
        }

        var addedID: UUID?
        let present = try blocks(lines)
        if !present.contains(where: { $0.key == "id" }) {
            let id = newID()
            let index = present.first { $0.key == "type" }?.contentEnd ?? 0
            insert(["id: \(id.uuidString)"], at: index, lines: &lines, eol: eol)
            addedID = id
        }

        let newBody = lines.map { $0.text + $0.eol }.joined()
        let after = try entries(newBody)
        try verify(edit, target: target, before: before, after: after, addedID: addedID)
        return diff(old: body, new: newBody, offset: bodyStart, addedID: addedID)
    }

    /// Несколько правок подряд как ОДНА замена (один шаг отмены). Повтор уже существующего значения и пустое значение пропускаются;
    /// если изменений нет — nil. Остальные ошибки отклоняют всю пачку.
    static func patch(for edits: [StoryCardHeaderEdit], in text: String, newID: () -> UUID) throws -> StoryCardHeaderPatch? {
        var working = text
        var addedID: UUID?
        for edit in edits {
            if case let .addRelation(relation) = edit, existingRelations(in: working).contains(relation) { continue }
            do {
                let step = try patch(for: edit, in: working, newID: newID)
                working = (working as NSString).replacingCharacters(in: step.range, with: step.replacement)
                if addedID == nil { addedID = step.addedID }
            } catch StoryCardHeaderEditError.duplicateAlias {
                continue
            } catch StoryCardHeaderEditError.emptyValue {
                continue
            } catch StoryCardHeaderEditError.notFound {
                continue
            }
        }
        guard working != text else { return nil }
        return diff(old: text, new: working, offset: 0, addedID: addedID)
    }

    private static func existingRelations(in text: String) -> [StoryCardRelation] {
        guard let mapping = try? PandocExportService.yamlFrontMatter(text) else { return [] }
        for item in mapping where item.key.scalar?.string == "relations" { return StoryCardHeader.relations(item.value) }
        return []
    }

    // MARK: Значения

    /// Значение YAML: простое слово остаётся как есть, всё остальное (двоеточия, #, кавычки, числа, пробелы по краям) — в двойных кавычках.
    static func quoted(_ value: String) -> String {
        let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "y", "n"]
        let scalars = value.unicodeScalars
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-."))
        let isPlain = !value.isEmpty
            && scalars.first.map { CharacterSet.letters.contains($0) } == true
            && scalars.last != " "
            && scalars.allSatisfy { allowed.contains($0) }
            && !reserved.contains(value.lowercased())
        if isPlain { return value }
        var result = "\""
        for scalar in scalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // MARK: Операции

    private static func setType(_ type: StoryCardType, lines: inout [Line], eol: String) throws {
        guard let block = try blocks(lines).first(where: { $0.key == "type" }) else {
            insert(["type: \(type.rawValue)"], at: 0, lines: &lines, eol: eol)
            return
        }
        let old = lines[block.start].text
        var comment = ""
        if !old.contains("\""), !old.contains("'"), let range = old.range(of: " #") { comment = String(old[range.lowerBound...]) }
        let lineEnd = lines[block.start].eol.isEmpty ? eol : lines[block.start].eol
        lines.replaceSubrange(block.start..<block.contentEnd, with: [Line(text: "type: \(type.rawValue)\(comment)", eol: lineEnd)])
    }

    private static func addAlias(_ value: String, lines: inout [Line], eol: String) throws {
        let alias = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { throw StoryCardHeaderEditError.emptyValue }
        guard let block = try blocks(lines).first(where: { $0.key == "aliases" }) else {
            insert(["aliases:", "  - \(quoted(alias))"], at: lines.count, lines: &lines, eol: eol)
            return
        }
        let current = StoryCardHeader.strings(try blockValue(block, lines: lines))
        guard !current.contains(where: { $0.lowercased() == alias.lowercased() }) else {
            throw StoryCardHeaderEditError.duplicateAlias
        }
        if try isInline(block, lines: lines) {
            replaceBlock(block, with: ["aliases:"] + (current + [alias]).map { "  - \(quoted($0))" }, lines: &lines, eol: eol)
        } else {
            insert(["\(itemIndent(block, lines: lines))- \(quoted(alias))"], at: block.contentEnd, lines: &lines, eol: eol)
        }
    }

    private static func removeAlias(_ value: String, lines: inout [Line], eol: String) throws {
        let alias = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let block = try blocks(lines).first(where: { $0.key == "aliases" }) else { throw StoryCardHeaderEditError.notFound }
        let current = StoryCardHeader.strings(try blockValue(block, lines: lines))
        guard let position = current.firstIndex(of: alias) else { throw StoryCardHeaderEditError.notFound }
        var rest = current
        rest.remove(at: position)
        if rest.isEmpty {
            replaceBlock(block, with: ["aliases: []"], lines: &lines, eol: eol)
        } else if try isInline(block, lines: lines) {
            replaceBlock(block, with: ["aliases:"] + rest.map { "  - \(quoted($0))" }, lines: &lines, eol: eol)
        } else {
            let items = try parseItems(block, lines: lines)
            guard let item = items.first(where: { $0.node.scalar?.string.trimmingCharacters(in: .whitespacesAndNewlines) == alias }) else {
                throw StoryCardHeaderEditError.verificationFailed
            }
            lines.removeSubrange(item.range)
        }
    }

    private static func relationLines(_ relation: StoryCardRelation, indent: String) -> [String] {
        var result = ["\(indent)- to: \(quoted(relation.to))"]
        if !relation.kind.isEmpty { result.append("\(indent)  kind: \(quoted(relation.kind))") }
        return result
    }

    private static func addRelation(_ relation: StoryCardRelation, lines: inout [Line], eol: String) throws {
        let to = relation.to.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = relation.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { throw StoryCardHeaderEditError.emptyValue }
        let new = StoryCardRelation(to: to, kind: kind)
        guard let block = try blocks(lines).first(where: { $0.key == "relations" }) else {
            insert(["relations:"] + relationLines(new, indent: "  "), at: lines.count, lines: &lines, eol: eol)
            return
        }
        if try isInline(block, lines: lines) {
            // Встроенный непустой список переписать без потерь нельзя: у элементов могут быть чужие поля.
            let value = try blockValue(block, lines: lines)
            guard value?.sequence?.isEmpty == true else { throw StoryCardHeaderEditError.flowStyle }
            replaceBlock(block, with: ["relations:"] + relationLines(new, indent: "  "), lines: &lines, eol: eol)
        } else {
            insert(relationLines(new, indent: itemIndent(block, lines: lines)), at: block.contentEnd, lines: &lines, eol: eol)
        }
    }

    private static func removeRelation(_ relation: StoryCardRelation, lines: inout [Line], eol: String) throws {
        guard let block = try blocks(lines).first(where: { $0.key == "relations" }) else { throw StoryCardHeaderEditError.notFound }
        if try isInline(block, lines: lines) { throw StoryCardHeaderEditError.flowStyle }
        let items = try parseItems(block, lines: lines)
        guard let item = items.first(where: { StoryCardHeader.relation($0.node) == relation }) else {
            throw StoryCardHeaderEditError.notFound
        }
        if items.count == 1 {
            replaceBlock(block, with: ["relations: []"], lines: &lines, eol: eol)
        } else {
            lines.removeSubrange(item.range)
        }
    }

    // MARK: Строки и блоки

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

    /// Имя ключа и конец совпадения (после двоеточия и одного пробела) для строки верхнего уровня.
    private static func key(of text: String) -> (name: String, end: Int)? {
        let ns = text as NSString
        guard let match = keyPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return (ns.substring(with: match.range(at: group)), NSMaxRange(match.range))
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

    /// Блоки ключей верхнего уровня. Строка нулевого отступа, не похожая на ключ (`{`, `[`, `? ` и т. п.), — неподдерживаемая запись.
    private static func blocks(_ lines: [Line]) throws -> [Block] {
        var result: [Block] = []
        for (index, line) in lines.enumerated() {
            guard let first = line.text.first, first != " ", first != "\t", first != "#" else { continue }
            if isItemStart(line.text), !result.isEmpty { continue }
            guard let name = key(of: line.text)?.name else { throw StoryCardHeaderEditError.flowStyle }
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

    /// После ключа есть значение в той же строке (`[a, b]`, `a`), а не список ниже.
    private static func isInline(_ block: Block, lines: [Line]) throws -> Bool {
        let text = lines[block.start].text
        guard let end = key(of: text)?.end else { throw StoryCardHeaderEditError.flowStyle }
        let rest = (text as NSString).substring(from: end).trimmingCharacters(in: .whitespaces)
        return !rest.isEmpty && !rest.hasPrefix("#")
    }

    private static func leadingWhitespace(_ text: String) -> String {
        String(text.prefix { $0 == " " || $0 == "\t" })
    }

    /// Отступ элементов списка в блоке; без элементов — два пробела.
    private static func itemIndent(_ block: Block, lines: [Line]) -> String {
        for index in (block.start + 1)..<max(block.start + 1, block.contentEnd) {
            let text = lines[index].text
            if isItemStart(text.trimmingCharacters(in: .whitespaces)) { return leadingWhitespace(text) }
        }
        return "  "
    }

    /// Значение ключа блока, разобранное Yams.
    private static func blockValue(_ block: Block, lines: [Line]) throws -> Yams.Node? {
        let yaml = lines[block.start..<block.contentEnd].map { $0.text + $0.eol }.joined()
        return try entries(yaml).first { $0.key == block.key }?.value
    }

    /// Элементы блочного списка: диапазоны строк и разобранные узлы.
    private static func parseItems(_ block: Block, lines: [Line]) throws -> [(range: Range<Int>, node: Yams.Node)] {
        let indent = itemIndent(block, lines: lines)
        var starts: [Int] = []
        for index in (block.start + 1)..<max(block.start + 1, block.contentEnd) {
            let text = lines[index].text
            if leadingWhitespace(text) == indent, isItemStart(text.trimmingCharacters(in: .whitespaces)) { starts.append(index) }
        }
        var result: [(range: Range<Int>, node: Yams.Node)] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : block.contentEnd
            let yaml = lines[start..<end].map { line -> String in
                let text = line.text
                return (text.hasPrefix(indent) ? String(text.dropFirst(indent.count)) : text) + line.eol
            }.joined()
            guard let root = try? Yams.compose(yaml: yaml, PandocExportService.yaml12Resolver()),
                  let first = root.sequence?.first else { throw StoryCardHeaderEditError.verificationFailed }
            result.append((start..<end, first))
        }
        return result
    }

    private static func insert(_ texts: [String], at index: Int, lines: inout [Line], eol: String) {
        if index > 0, index <= lines.count, lines[index - 1].eol.isEmpty { lines[index - 1].eol = eol }
        lines.insert(contentsOf: texts.map { Line(text: $0, eol: eol) }, at: index)
    }

    /// Заменяет содержимое блока (комментарии после него остаются).
    private static func replaceBlock(_ block: Block, with texts: [String], lines: inout [Line], eol: String) {
        lines.replaceSubrange(block.start..<block.contentEnd, with: texts.map { Line(text: $0, eol: eol) })
    }

    // MARK: Проверка и заплатка

    private static func entries(_ yaml: String) throws -> [(key: String, value: Yams.Node)] {
        do {
            guard let root = try Yams.compose(yaml: yaml, PandocExportService.yaml12Resolver()) else { return [] }
            guard let mapping = root.mapping else { throw StoryCardHeaderEditError.verificationFailed }
            var result: [(key: String, value: Yams.Node)] = []
            for item in mapping {
                guard let name = item.key.scalar?.string else { throw StoryCardHeaderEditError.verificationFailed }
                result.append((key: name, value: item.value))
            }
            return result
        } catch {
            throw StoryCardHeaderEditError.verificationFailed
        }
    }

    private static func verify(_ edit: StoryCardHeaderEdit, target: String, before: [(key: String, value: Yams.Node)],
                               after: [(key: String, value: Yams.Node)], addedID: UUID?) throws {
        let failure = StoryCardHeaderEditError.verificationFailed
        guard Set(before.map(\.key)).count == before.count, Set(after.map(\.key)).count == after.count else { throw failure }
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.key, $0.value) })
        let new = Dictionary(uniqueKeysWithValues: after.map { ($0.key, $0.value) })
        var expectedKeys = Set(old.keys)
        expectedKeys.insert(target)
        if addedID != nil { expectedKeys.insert("id") }
        guard Set(new.keys) == expectedKeys else { throw failure }
        for (key, value) in old where key != target {
            guard new[key] == value else { throw failure }
        }
        if let addedID { guard new["id"]?.scalar?.string == addedID.uuidString else { throw failure } }
        switch edit {
        case let .setType(type):
            guard new["type"]?.scalar?.string == type.rawValue else { throw failure }
        case let .addAlias(value):
            let alias = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard StoryCardHeader.strings(new["aliases"]) == StoryCardHeader.strings(old["aliases"]) + [alias] else { throw failure }
        case let .removeAlias(value):
            var expected = StoryCardHeader.strings(old["aliases"])
            if let position = expected.firstIndex(of: value.trimmingCharacters(in: .whitespacesAndNewlines)) { expected.remove(at: position) }
            guard StoryCardHeader.strings(new["aliases"]) == expected else { throw failure }
        case let .addRelation(relation):
            let added = StoryCardRelation(to: relation.to.trimmingCharacters(in: .whitespacesAndNewlines),
                                          kind: relation.kind.trimmingCharacters(in: .whitespacesAndNewlines))
            guard StoryCardHeader.relations(new["relations"]) == StoryCardHeader.relations(old["relations"]) + [added] else { throw failure }
        case let .removeRelation(relation):
            var expected = StoryCardHeader.relations(old["relations"])
            if let position = expected.firstIndex(of: relation) { expected.remove(at: position) }
            guard StoryCardHeader.relations(new["relations"]) == expected else { throw failure }
        }
    }

    /// Минимальная замена между старым и новым телом шапки; суррогатные пары не разрезаются.
    private static func diff(old: String, new: String, offset: Int, addedID: UUID?) -> StoryCardHeaderPatch {
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
        return StoryCardHeaderPatch(range: range, replacement: replacement, addedID: addedID)
    }
}

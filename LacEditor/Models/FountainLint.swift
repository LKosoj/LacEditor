import Foundation

enum FountainElementKind: Equatable {
    case titlePage, sceneHeading, action, character, dialogue, parenthetical
    case transition, centered, lyrics, pageBreak
    case section(level: Int), synopsis, note, boneyard, blank
}

struct FountainLine: Equatable {
    /// Номер строки с 1.
    let number: Int
    let text: String
    let kind: FountainElementKind
}

enum FountainIssueKind: Equatable {
    /// `[[` без `]]`.
    case unclosedNote
    /// `/*` без `*/`.
    case unclosedBoneyard
    /// Строка сцены без пустой строки после.
    case missingBlankAfterHeading
    /// Ограждение кода (три обратные кавычки): ИИ забыл его снять.
    case codeFence
    case emptyDocument
    /// Титульная страница там, где её быть не должно.
    case titlePage
}

struct FountainIssue: Equatable {
    let kind: FountainIssueKind
    let line: Int
}

struct FountainLintResult {
    let lines: [FountainLine]
    let issues: [FountainIssue]
    var isValid: Bool { issues.isEmpty }
}

/// Небольшой разборщик Fountain по спецификации fountain.io: один эталонный классификатор для защиты `!` в экспортёре
/// и для проверки ответа ИИ. Своя интерпретация спецификации, а не гарантия совпадения с Highland или Fade In.
enum FountainLint {
    private struct Masked {
        var text: String
        /// Строка целиком внутри заметки или блока комментариев.
        var fully: FountainElementKind?
    }

    /// Ключ титульной страницы — одно слово до двоеточия; многословный только известный «Draft date».
    /// Иначе действие вроде «Mary looks at the clock: it's late» принималось бы за титульную страницу.
    private static let titleKey = try! NSRegularExpression(pattern: "^(Draft date|[A-Za-z][A-Za-z0-9]*):", options: .caseInsensitive)
    private static let sceneStart = try! NSRegularExpression(pattern: "^(INT|EXT|EST|INT\\.?/EXT|I/E)[. ]", options: .caseInsensitive)

    static func parse(_ text: String, allowsTitlePage: Bool) -> FountainLintResult {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FountainLintResult(lines: [], issues: [FountainIssue(kind: .emptyDocument, line: 1)])
        }
        let raw = source.components(separatedBy: "\n")
        var issues: [FountainIssue] = []
        let masked = mask(raw, issues: &issues)
        var lines: [FountainLine] = []
        var index = 0

        func isBlank(_ item: Masked) -> Bool { item.text.trimmingCharacters(in: .whitespaces).isEmpty }

        if masked[0].fully == nil, matchesTitleKey(masked[0].text) {
            if !allowsTitlePage { issues.append(FountainIssue(kind: .titlePage, line: 1)) }
            while index < raw.count, !isBlank(masked[index]) {
                lines.append(FountainLine(number: index + 1, text: raw[index], kind: .titlePage))
                index += 1
            }
        }

        var block: [(number: Int, text: String)] = []
        func flush() {
            guard !block.isEmpty else { return }
            defer { block = [] }
            let texts = block.map(\.text)
            let kind = classifyBlock(texts)
            for (offset, item) in block.enumerated() {
                let itemKind: FountainElementKind
                let trimmed = item.text.trimmingCharacters(in: .whitespaces)
                if offset == 0 {
                    itemKind = kind
                } else {
                    switch kind {
                    case .character:
                        itemKind = trimmed.isEmpty ? .dialogue : (trimmed.hasPrefix("(") && trimmed.hasSuffix(")") ? .parenthetical : .dialogue)
                    case .lyrics:
                        itemKind = .lyrics
                    default:
                        itemKind = .action
                    }
                }
                lines.append(FountainLine(number: item.number, text: raw[item.number - 1], kind: itemKind))
            }
            if kind == .sceneHeading, block.count > 1, isNaturalHeading(texts[0]) {
                issues.append(FountainIssue(kind: .missingBlankAfterHeading, line: block[0].number))
            }
        }

        while index < raw.count {
            let item = masked[index]
            let number = index + 1
            if isBlank(item) {
                // Строка из двух и более пробелов внутри диалога не рвёт блок.
                if item.fully == nil, raw[index].count >= 2, !block.isEmpty, classifyBlock(block.map(\.text)) == .character {
                    block.append((number, raw[index]))
                } else {
                    flush()
                    lines.append(FountainLine(number: number, text: raw[index], kind: item.fully ?? .blank))
                }
            } else {
                block.append((number, item.text))
            }
            index += 1
        }
        flush()

        for (offset, item) in masked.enumerated() where item.fully == nil {
            if item.text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                issues.append(FountainIssue(kind: .codeFence, line: offset + 1))
            }
        }
        lines.sort { $0.number < $1.number }
        return FountainLintResult(lines: lines, issues: issues.sorted { $0.line < $1.line })
    }

    /// Вид первой строки блока, разделённого пустыми строками. Осторожный: сомнительный случай считается не действием,
    /// и экспортёр ставит перед ним `!`. Одиночная строка заглавными (и китайская строка) остаётся действием.
    static func classifyBlock(_ lines: [String]) -> FountainElementKind {
        guard let rawFirst = lines.first else { return .blank }
        let first = stripNotes(rawFirst).trimmingCharacters(in: .whitespaces)
        if first.isEmpty { return .blank }
        if first.hasPrefix("!") { return .action }
        if first.count >= 3, first.allSatisfy({ $0 == "=" }) { return .pageBreak }
        if first.hasPrefix("#") { return .section(level: first.prefix(while: { $0 == "#" }).count) }
        if first.hasPrefix("=") { return .synopsis }
        if first.hasPrefix("~") { return .lyrics }
        if first.hasPrefix(">") { return first.count > 1 && first.hasSuffix("<") ? .centered : .transition }
        if first.hasPrefix("."), !first.hasPrefix(".."), first.count > 1 { return .sceneHeading }
        if first.hasPrefix("@") { return .character }
        if isNaturalHeading(first) { return .sceneHeading }
        if lines.count == 1, first.hasSuffix("TO:"), isUppercase(first) { return .transition }
        if lines.count >= 2 {
            var name = first
            if let open = name.firstIndex(of: "(") { name = String(name[..<open]) }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("^") { name.removeLast() }
            if isUppercase(name) { return .character }
        }
        return .action
    }

    /// Есть хоть одна буква; все буквы с регистром верхние. Буквы без регистра (иероглифы) считаются верхними.
    static func isUppercase(_ s: String) -> Bool {
        var hasLetter = false
        for scalar in s.unicodeScalars {
            if scalar.properties.isLowercase { return false }
            if CharacterSet.letters.contains(scalar) { hasLetter = true }
        }
        return hasLetter
    }

    // MARK: Внутреннее

    private static func matchesTitleKey(_ line: String) -> Bool {
        titleKey.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func isNaturalHeading(_ line: String) -> Bool {
        let trimmed = stripNotes(line).trimmingCharacters(in: .whitespaces)
        return sceneStart.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
    }

    /// Убирает `[[…]]` из строки; незакрытая заметка отрезается до конца строки.
    static func stripNotes(_ line: String) -> String {
        guard line.contains("[[") else { return line }
        var result = ""
        var rest = Substring(line)
        while let open = rest.range(of: "[[") {
            result += rest[..<open.lowerBound]
            if let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
                rest = rest[close.upperBound...]
            } else {
                rest = ""
            }
        }
        return result + rest
    }

    /// Вырезает заметки и блоки комментариев. Строка целиком внутри них получает вид `.note`/`.boneyard`.
    private static func mask(_ raw: [String], issues: inout [FountainIssue]) -> [Masked] {
        var result: [Masked] = []
        var boneyardOpen: Int?
        var noteOpen: Int?
        for (index, line) in raw.enumerated() {
            let number = index + 1
            if let opened = noteOpen, boneyardOpen == nil, line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Внутри заметки пустых строк быть не должно.
                issues.append(FountainIssue(kind: .unclosedNote, line: opened))
                noteOpen = nil
                result.append(Masked(text: "", fully: nil))
                continue
            }
            var rest = Substring(line)
            var output = ""
            var touchedBoneyard = false, touchedNote = false
            while !rest.isEmpty {
                if boneyardOpen != nil {
                    touchedBoneyard = true
                    if let close = rest.range(of: "*/") {
                        rest = rest[close.upperBound...]
                        boneyardOpen = nil
                    } else {
                        rest = ""
                    }
                } else if noteOpen != nil {
                    touchedNote = true
                    if let close = rest.range(of: "]]") {
                        rest = rest[close.upperBound...]
                        noteOpen = nil
                    } else {
                        rest = ""
                    }
                } else {
                    let boneyard = rest.range(of: "/*"), note = rest.range(of: "[[")
                    if let boneyard, note == nil || boneyard.lowerBound < note!.lowerBound {
                        output += rest[..<boneyard.lowerBound]
                        rest = rest[boneyard.upperBound...]
                        boneyardOpen = number
                        touchedBoneyard = true
                    } else if let note {
                        output += rest[..<note.lowerBound]
                        rest = rest[note.upperBound...]
                        noteOpen = number
                        touchedNote = true
                    } else {
                        output += rest
                        rest = ""
                    }
                }
            }
            var fully: FountainElementKind?
            if output.trimmingCharacters(in: .whitespaces).isEmpty {
                if touchedBoneyard { fully = .boneyard } else if touchedNote { fully = .note }
            }
            result.append(Masked(text: output, fully: fully))
        }
        if let opened = boneyardOpen { issues.append(FountainIssue(kind: .unclosedBoneyard, line: opened)) }
        if let opened = noteOpen { issues.append(FountainIssue(kind: .unclosedNote, line: opened)) }
        return result
    }
}

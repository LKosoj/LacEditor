import Foundation

/// Локальные правила стиля. Чистые функции без состояния: можно вызывать из `Task.detached`.
enum StyleCheckService {
    struct Word {
        let range: NSRange
        let surface: String
        let stem: String
        let language: TextLanguage
        let isStop: Bool
        let sentence: Int
        let paragraph: Int
        /// Номер слова среди всех слов текста (стоп-слова считаются).
        let index: Int
        /// Накопленное число знаков слов до этого слова (для окна в знаках у китайского).
        let charOffset: Int
    }

    struct Sentence {
        let range: NSRange
        let text: String
        let language: TextLanguage
        let paragraph: Int
        let words: [Word]
    }

    static let repeatedWordLimit = 300
    static let customWordLimit = 500

    /// Один проход. `isCancelled` опрашивается между абзацами; при отмене возвращает то, что успело набраться (вызывающий результат отбросит).
    static func check(text: String, isMarkdown: Bool, settings: StyleCheckSettings,
                      documentID: UUID, revision: UInt,
                      isCancelled: () -> Bool = { false }) -> StyleCheckResult {
        let length = (text as NSString).length
        let mask = StyleProseMask(text: text, isMarkdown: isMarkdown)
        let languages = paragraphLanguages(mask: mask, fixedLanguage: settings.fixedLanguage)
        let sentences = Self.sentences(mask: mask, paragraphLanguages: languages, fixedLanguage: settings.fixedLanguage,
                                       customStops: customStops(settings.customStopWords), isCancelled: isCancelled)
        var findings: [StyleFinding] = []
        if !isCancelled() {
            if settings.isEnabled(.repeatedWord) { findings += repeatedWords(sentences, settings: settings, isCancelled: isCancelled) }
            if settings.isEnabled(.repeatedStart) { findings += repeatedStarts(sentences, settings: settings) }
            if settings.isEnabled(.longSentence) { findings += longSentences(sentences, settings: settings) }
            if settings.isEnabled(.customWord) { findings += customWords(mask: mask, sentences: sentences, settings: settings, isCancelled: isCancelled) }
            if settings.isEnabled(.spacing) { findings += spacing(text: text, mask: mask, paragraphLanguages: languages, settings: settings, isCancelled: isCancelled) }
        }
        findings.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length < $1.range.length }
        var counts: [TextLanguage: Int] = [:]
        for sentence in sentences { counts[sentence.language, default: 0] += sentence.words.count }
        let language = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }?.key ?? .other
        return StyleCheckResult(documentID: documentID, revision: revision, textLength: length, language: language, findings: findings)
    }

    // MARK: Подготовка

    /// Языки абзацев маски (параллельный массив). Ручной язык действует на все абзацы.
    static func paragraphLanguages(mask: StyleProseMask, fixedLanguage: TextLanguage?) -> [TextLanguage] {
        let text = mask.masked as NSString
        return mask.paragraphs.map { fixedLanguage ?? TextSegmentation.language(of: text.substring(with: $0)) }
    }

    /// Пользовательские стоп-слова: каждое прогоняется через `normalize` для каждого языка и остаётся в исходном виде.
    static func customStops(_ words: [String]) -> [TextLanguage: Set<String>] {
        var result: [TextLanguage: Set<String>] = [:]
        for word in words {
            for language in TextLanguage.allCases {
                result[language, default: []].insert(WordNormalizer.normalize(word, language: language))
                result[language, default: []].insert(word.lowercased())
            }
        }
        return result
    }

    static func sentences(mask: StyleProseMask, paragraphLanguages: [TextLanguage], fixedLanguage: TextLanguage?,
                          customStops: [TextLanguage: Set<String>], isCancelled: () -> Bool = { false }) -> [Sentence] {
        let masked = mask.masked as NSString
        var result: [Sentence] = []
        var wordIndex = 0, charOffset = 0
        for (paragraphIndex, paragraph) in mask.paragraphs.enumerated() {
            if isCancelled() { break }
            let paragraphLanguage = paragraphLanguages[paragraphIndex]
            for segment in TextSegmentation.sentences(in: mask.masked, range: paragraph) {
                // Короткое предложение язык определяет плохо: берётся язык абзаца.
                let language = fixedLanguage ?? (segment.range.length >= 20 ? TextSegmentation.language(of: segment.text) : paragraphLanguage)
                var words: [Word] = []
                for token in TextSegmentation.words(in: mask.masked, range: segment.range) {
                    guard token.text.rangeOfCharacter(from: .letters) != nil else { continue }
                    let stem = WordNormalizer.normalize(token.text, language: language)
                    let custom = customStops[language]
                    let isStop = StopWords.contains(stem, language: language)
                        || custom?.contains(stem) == true || custom?.contains(token.text.lowercased()) == true
                    words.append(Word(range: token.range, surface: token.text, stem: stem, language: language, isStop: isStop,
                                      sentence: result.count, paragraph: paragraphIndex, index: wordIndex, charOffset: charOffset))
                    wordIndex += 1
                    charOffset += token.text.count
                }
                result.append(Sentence(range: segment.range, text: masked.substring(with: segment.range),
                                       language: language, paragraph: paragraphIndex, words: words))
            }
        }
        return result
    }

    // MARK: Повтор слов

    static func repeatedWords(_ sentences: [Sentence], settings: StyleCheckSettings, isCancelled: () -> Bool = { false }) -> [StyleFinding] {
        var last: [String: Word] = [:]
        var result: [StyleFinding] = []
        for sentence in sentences {
            if isCancelled() { break }
            for word in sentence.words {
                let isChinese = word.language == .zh
                if word.isStop || word.stem.count < (isChinese ? 2 : 3) || word.surface.allSatisfy(\.isNumber) { continue }
                let key = "\(word.language.rawValue)|\(word.stem)"
                // Последнее вхождение обновляется всегда: цепочка повторов подсвечивает каждое следующее слово.
                defer { last[key] = word }
                guard let previous = last[key], result.count < repeatedWordLimit else { continue }
                let window = isChinese ? settings.windowChars : settings.windowWords
                let distance = isChinese ? word.charOffset - previous.charOffset : word.index - previous.index
                guard distance <= window else { continue }
                let explanation = isChinese
                    ? L10n.tr("“%@”在 %lld 个字内重复", word.surface, window)
                    : L10n.tr("“%@”在 %lld 个词内重复", word.surface, window)
                result.append(StyleFinding(category: .repeatedWord, range: word.range, fragment: word.surface,
                                           explanation: explanation, related: [previous.range]))
            }
        }
        return result
    }

    // MARK: Повтор начала предложений

    /// Диапазон (относительно строки) первых `count` букв предложения без кавычек и знаков в начале.
    private static func leadingLetters(_ text: String, count: Int) -> (range: NSRange, key: String)? {
        var key = "", start: String.Index?, end = text.startIndex
        for index in text.indices {
            if key.count == count { break }
            guard text[index].isLetter else { continue }
            if start == nil { start = index }
            key.append(text[index])
            end = text.index(after: index)
        }
        guard key.count == count, let start else { return nil }
        return (NSRange(start..<end, in: text), key)
    }

    static func repeatedStarts(_ sentences: [Sentence], settings: StyleCheckSettings) -> [StyleFinding] {
        var result: [StyleFinding] = []
        guard sentences.count > 1 else { return result }
        for index in 1..<sentences.count {
            let previous = sentences[index - 1], current = sentences[index]
            guard previous.paragraph == current.paragraph, previous.language == current.language else { continue }
            if current.language == .zh {
                guard let first = leadingLetters(previous.text, count: 2), let second = leadingLetters(current.text, count: 2),
                      first.key == second.key,
                      previous.text.filter(\.isLetter).count >= 4, current.text.filter(\.isLetter).count >= 4 else { continue }
                let range = NSRange(location: current.range.location + second.range.location, length: second.range.length)
                result.append(StyleFinding(category: .repeatedStart, range: range, fragment: second.key,
                                           explanation: L10n.tr("相邻句子都以“%@”开头", second.key),
                                           related: [NSRange(location: previous.range.location + first.range.location, length: first.range.length)]))
            } else {
                // Стоп-слова не пропускаются: «Он… Он…» как раз и нужно ловить.
                guard previous.words.count >= 2, current.words.count >= 2,
                      let first = previous.words.first, let second = current.words.first, first.stem == second.stem else { continue }
                result.append(StyleFinding(category: .repeatedStart, range: second.range, fragment: second.surface,
                                           explanation: L10n.tr("相邻句子都以“%@”开头", second.surface), related: [first.range]))
            }
        }
        return result
    }

    // MARK: Длинные предложения

    static func longSentences(_ sentences: [Sentence], settings: StyleCheckSettings) -> [StyleFinding] {
        var result: [StyleFinding] = []
        for sentence in sentences {
            let isChinese = sentence.language == .zh
            let size = isChinese ? sentence.words.reduce(0) { $0 + $1.surface.count } : sentence.words.count
            let limit = isChinese ? settings.longSentenceChars : settings.longSentenceWords
            guard size > limit else { continue }
            let explanation = isChinese
                ? L10n.tr("句子有 %lld 个字，上限是 %lld 个", size, limit)
                : L10n.tr("句子有 %lld 个词，上限是 %lld 个", size, limit)
            result.append(StyleFinding(category: .longSentence, range: sentence.range, fragment: sentence.text, explanation: explanation))
        }
        return result
    }

    // MARK: Свои списки

    private static func isLetterOrDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    static func customWords(mask: StyleProseMask, sentences: [Sentence], settings: StyleCheckSettings, isCancelled: () -> Bool = { false }) -> [StyleFinding] {
        let text = mask.masked as NSString
        var result: [StyleFinding] = []
        for raw in settings.customWords {
            if isCancelled() { break }
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            let hasIdeographs = entry.unicodeScalars.contains { $0.value >= 0x3400 && $0.value <= 0x9FFF }
            let hasCyrillic = entry.unicodeScalars.contains { $0.value >= 0x400 && $0.value <= 0x4FF }
            // Без учёта диакритики «й» совпало бы с «и», поэтому для кириллицы сравнивается только регистр.
            let options: NSString.CompareOptions = hasCyrillic ? [.caseInsensitive] : [.caseInsensitive, .diacriticInsensitive]
            var position = 0
            while position < text.length, result.count < customWordLimit, !isCancelled() {
                let found = text.range(of: entry, options: options, range: NSRange(location: position, length: text.length - position))
                guard found.location != NSNotFound, found.length > 0 else { break }
                position = NSMaxRange(found)
                if !hasIdeographs {
                    if found.location > 0, isLetterOrDigit(text.character(at: found.location - 1)) { position = found.location + 1; continue }
                    if NSMaxRange(found) < text.length, isLetterOrDigit(text.character(at: NSMaxRange(found))) { position = found.location + 1; continue }
                }
                guard mask.isProse(found) else { continue }
                result.append(StyleFinding(category: .customWord, range: found, fragment: text.substring(with: found),
                                           explanation: L10n.tr("词表中的词：%@", entry)))
            }
        }
        return result
    }

    // MARK: Пробелы

    private static let latinSigns: Set<UInt16> = Set(",.;:!?…)]".utf16)
    private static let basicSigns: Set<UInt16> = Set(",.".utf16)
    private static let chineseSigns: Set<UInt16> = Set("，。！？；：、）」』”’》】".utf16)

    private static func isLineBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }
    private static func isSeriesSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x3000 }

    /// Знак после пробела не должен быть началом слова («.gitignore», «:smile:»).
    private static func endsSign(after index: Int, in units: [UInt16]) -> Bool {
        guard index < units.count else { return true }
        let next = units[index]
        if isLineBreak(next) || next == 0x20 || next == 0x09 || next == 0xA0 { return true }
        guard let scalar = Unicode.Scalar(next) else { return false }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    /// Работает по исходному тексту, а не по маске: пробелы вместо кода не должны выглядеть двойными пробелами.
    static func spacing(text: String, mask: StyleProseMask, paragraphLanguages: [TextLanguage], settings: StyleCheckSettings, isCancelled: () -> Bool = { false }) -> [StyleFinding] {
        let units = Array(text.utf16)
        let source = text as NSString
        var result: [StyleFinding] = []
        var index = 0, steps = 0
        while index < units.count {
            steps += 1
            if steps % 4096 == 0, isCancelled() { break }
            guard isSeriesSpace(units[index]) else { index += 1; continue }
            var end = index
            while end < units.count, isSeriesSpace(units[end]) { end += 1 }
            defer { index = end }
            // Отступ в начале строки и пробелы перед переводом строки (в том числе Markdown-перенос) не трогаются.
            guard index > 0, !isLineBreak(units[index - 1]), units[index - 1] != 0x09, end < units.count, !isLineBreak(units[end]) else { continue }
            let series = NSRange(location: index, length: end - index)
            guard mask.isProse(NSRange(location: index - 1, length: series.length + 2)),
                  let paragraph = paragraphIndex(containing: index, in: mask.paragraphs) else { continue }
            let signs: Set<UInt16>
            switch paragraphLanguages[paragraph] {
            case .en, .ru: signs = latinSigns
            case .other: signs = basicSigns
            case .zh: signs = chineseSigns
            }
            let sign = units[end]
            if signs.contains(sign), paragraphLanguages[paragraph] == .zh || endsSign(after: end + 1, in: units) {
                let fragment = source.substring(with: NSRange(location: index, length: series.length + 1))
                result.append(StyleFinding(category: .spacing, range: series, fragment: fragment,
                                           explanation: L10n.tr("标点前多余的空格"), replacement: ""))
            } else if series.length >= 2, units[index..<end].allSatisfy({ $0 == 0x20 }) {
                let fragment = source.substring(with: NSRange(location: index, length: series.length + 1))
                result.append(StyleFinding(category: .spacing, range: series, fragment: fragment,
                                           explanation: L10n.tr("多余的连续空格"), replacement: " "))
            }
        }
        return result
    }

    private static func paragraphIndex(containing location: Int, in paragraphs: [NSRange]) -> Int? {
        var low = 0, high = paragraphs.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(paragraphs[middle]) <= location { low = middle + 1 } else { high = middle }
        }
        return low < paragraphs.count && paragraphs[low].location <= location ? low : nil
    }
}

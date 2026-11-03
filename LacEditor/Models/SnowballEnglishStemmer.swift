import Foundation

/// Английский стеммер Snowball (Porter2). Вход: нижний регистр, только a–z и апостроф.
/// Чистая функция на массивах UTF-16, без регулярных выражений.
enum SnowballEnglishStemmer {
    private typealias W = [UInt16]

    private static func w(_ s: String) -> W { Array(s.utf16) }

    // Слова, которые не подчиняются правилам: вход целиком -> результат.
    private static let exceptions1: [String: String] = [
        "skis": "ski", "skies": "sky", "dying": "die", "lying": "lie", "tying": "tie",
        "idly": "idl", "gently": "gentl", "ugly": "ugli", "early": "earli", "only": "onli", "singly": "singl",
        "sky": "sky", "news": "news", "howe": "howe", "atlas": "atlas", "cosmos": "cosmos", "bias": "bias", "andes": "andes"
    ]
    // Слова, которые остаются как есть после шага 1a.
    private static let exceptions2: Set<String> = ["inning", "outing", "canning", "herring", "earring", "proceed", "exceed", "succeed"]

    private static func table(_ pairs: [(String, String)]) -> [(suffix: W, replacement: W)] {
        pairs.sorted { $0.0.utf16.count > $1.0.utf16.count }.map { (w($0.0), w($0.1)) }
    }

    private static let step2Table = table([
        ("tional", "tion"), ("enci", "ence"), ("anci", "ance"), ("abli", "able"), ("entli", "ent"),
        ("izer", "ize"), ("ization", "ize"), ("ational", "ate"), ("ation", "ate"), ("ator", "ate"),
        ("alism", "al"), ("aliti", "al"), ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"), ("ousness", "ous"),
        ("iveness", "ive"), ("iviti", "ive"), ("biliti", "ble"), ("bli", "ble"), ("ogi", "og"),
        ("fulli", "ful"), ("lessli", "less"), ("li", "")
    ])
    private static let step3Table = table([
        ("tional", "tion"), ("ational", "ate"), ("alize", "al"), ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"),
        ("ful", ""), ("ness", ""), ("ative", "")
    ])
    private static let step4Table = table(
        ["al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent", "ism", "ate", "iti", "ous", "ive", "ize", "ion"].map { ($0, "") }
    )
    private static let step1bTable = table([("eed", "eed"), ("eedly", "eed"), ("ed", ""), ("edly", ""), ("ing", ""), ("ingly", "")])
    private static let doubles: [W] = ["bb", "dd", "ff", "gg", "mm", "nn", "pp", "rr", "tt"].map(w)
    private static let validLiEndings: Set<UInt16> = Set("cdeghkmnrt".utf16)

    static func stem(_ input: String) -> String {
        if input.utf16.count <= 2 { return input }
        var word = w(input)
        if word.first == 0x27 { word.removeFirst() }
        if word.count <= 2 { return String(decoding: word, as: UTF16.self) }
        if let exception = exceptions1[String(decoding: word, as: UTF16.self)] { return exception }

        markConsonantY(&word)
        let (p1, p2) = regions(word)

        step0(&word)
        step1a(&word)
        if exceptions2.contains(String(decoding: word, as: UTF16.self)) { return String(decoding: word, as: UTF16.self) }
        step1b(&word, p1: p1)
        step1c(&word)
        step2(&word, p1: p1)
        step3(&word, p1: p1, p2: p2)
        step4(&word, p2: p2)
        step5(&word, p1: p1, p2: p2)

        return String(decoding: word.map { $0 == 0x59 ? 0x79 : $0 }, as: UTF16.self)   // Y -> y
    }

    // MARK: Буквы и области

    private static func isVowel(_ c: UInt16) -> Bool {
        c == 0x61 || c == 0x65 || c == 0x69 || c == 0x6F || c == 0x75 || c == 0x79   // a e i o u y
    }

    /// y в начале слова и y после гласной считаются согласной: помечаем заглавной Y.
    private static func markConsonantY(_ word: inout W) {
        for i in 0..<word.count where word[i] == 0x79 {
            if i == 0 || isVowel(word[i - 1]) { word[i] = 0x59 }
        }
    }

    /// Начало области после первой согласной, идущей за гласной, начиная с `from`.
    private static func regionStart(_ word: W, from: Int) -> Int {
        var i = from
        while i < word.count && !isVowel(word[i]) { i += 1 }
        while i < word.count && isVowel(word[i]) { i += 1 }
        return i < word.count ? i + 1 : word.count
    }

    private static func regions(_ word: W) -> (p1: Int, p2: Int) {
        var p1: Int?
        for prefix in ["gener", "commun", "arsen"] where hasPrefix(word, w(prefix)) { p1 = prefix.utf16.count }
        let start = p1 ?? regionStart(word, from: 0)
        return (start, regionStart(word, from: start))
    }

    private static func hasPrefix(_ word: W, _ prefix: W) -> Bool {
        word.count >= prefix.count && Array(word[0..<prefix.count]) == prefix
    }

    private static func hasSuffix(_ word: W, _ suffix: W) -> Bool {
        word.count >= suffix.count && Array(word[(word.count - suffix.count)...]) == suffix
    }

    private static func containsVowel(_ word: W, upTo end: Int) -> Bool {
        end > 0 && word[0..<end].contains(where: isVowel)
    }

    /// Короткий слог в конце слова `word[0..<end]`: (а) согласная, гласная, согласная (не w, x, Y);
    /// или (б) все слово — гласная и согласная.
    private static func endsWithShortSyllable(_ word: W, end: Int) -> Bool {
        if end >= 3 {
            let last = word[end - 1]
            let isPlainConsonant = !isVowel(last) && last != 0x77 && last != 0x78 && last != 0x59   // не w, x, Y
            if isPlainConsonant && isVowel(word[end - 2]) && !isVowel(word[end - 3]) { return true }
        }
        return end == 2 && isVowel(word[0]) && !isVowel(word[1])
    }

    /// Самый длинный подходящий суффикс из таблицы (таблицы упорядочены от длинного к короткому).
    private static func longestMatch(_ word: W, in table: [(suffix: W, replacement: W)]) -> (suffix: W, replacement: W)? {
        table.first { hasSuffix(word, $0.suffix) }
    }

    // MARK: Шаги

    private static func step0(_ word: inout W) {
        for suffix in ["'s'", "'s", "'"].map(w) where hasSuffix(word, suffix) {
            word.removeLast(suffix.count)
            return
        }
    }

    private static func step1a(_ word: inout W) {
        if hasSuffix(word, w("sses")) {
            word.removeLast(2)
        } else if hasSuffix(word, w("ied")) || hasSuffix(word, w("ies")) {
            // «ied/ies» -> «i», если перед ним больше одной буквы, иначе «ie»
            word.removeLast(word.count - 3 > 1 ? 2 : 1)
        } else if hasSuffix(word, w("us")) || hasSuffix(word, w("ss")) {
            return
        } else if hasSuffix(word, w("s")) {
            // «s» убирается, если гласная есть в слове до буквы, стоящей прямо перед «s»
            if containsVowel(word, upTo: word.count - 2) { word.removeLast() }
        }
    }

    private static func step1b(_ word: inout W, p1: Int) {
        guard let match = longestMatch(word, in: step1bTable) else { return }
        let start = word.count - match.suffix.count
        if match.suffix == w("eed") || match.suffix == w("eedly") {
            if start >= p1 {
                word.removeLast(match.suffix.count)
                word.append(contentsOf: w("ee"))
            }
            return
        }
        guard containsVowel(word, upTo: start) else { return }
        word.removeLast(match.suffix.count)
        if hasSuffix(word, w("at")) || hasSuffix(word, w("bl")) || hasSuffix(word, w("iz")) {
            word.append(0x65)
        } else if doubles.contains(where: { hasSuffix(word, $0) }) {
            word.removeLast()
        } else if word.count == p1 && endsWithShortSyllable(word, end: word.count) {
            word.append(0x65)   // короткое слово: R1 пуста
        }
    }

    private static func step1c(_ word: inout W) {
        guard word.count > 2, let last = word.last, last == 0x79 || last == 0x59, !isVowel(word[word.count - 2]) else { return }
        word[word.count - 1] = 0x69
    }

    private static func step2(_ word: inout W, p1: Int) {
        guard let match = longestMatch(word, in: step2Table) else { return }
        let start = word.count - match.suffix.count
        guard start >= p1 else { return }
        if match.suffix == w("ogi") {
            guard start > 0, word[start - 1] == 0x6C else { return }   // только после «l»
        } else if match.suffix == w("li") {
            guard start > 0, validLiEndings.contains(word[start - 1]) else { return }
        }
        word.removeLast(match.suffix.count)
        word.append(contentsOf: match.replacement)
    }

    private static func step3(_ word: inout W, p1: Int, p2: Int) {
        guard let match = longestMatch(word, in: step3Table) else { return }
        let start = word.count - match.suffix.count
        guard start >= (match.suffix == w("ative") ? p2 : p1) else { return }
        word.removeLast(match.suffix.count)
        word.append(contentsOf: match.replacement)
    }

    private static func step4(_ word: inout W, p2: Int) {
        guard let match = longestMatch(word, in: step4Table) else { return }
        let start = word.count - match.suffix.count
        guard start >= p2 else { return }
        if match.suffix == w("ion") {
            guard start > 0, word[start - 1] == 0x73 || word[start - 1] == 0x74 else { return }   // только после s или t
        }
        word.removeLast(match.suffix.count)
    }

    private static func step5(_ word: inout W, p1: Int, p2: Int) {
        guard let last = word.last else { return }
        let start = word.count - 1
        if last == 0x65 {
            if start >= p2 || (start >= p1 && !endsWithShortSyllable(word, end: start)) { word.removeLast() }
        } else if last == 0x6C {
            if start >= p2 && start > 0 && word[start - 1] == 0x6C { word.removeLast() }
        }
    }
}

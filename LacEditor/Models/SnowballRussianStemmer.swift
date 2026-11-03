import Foundation

/// Русский стеммер Snowball. Вход: нижний регистр, только а–я (ё заменяется на е).
/// Окончания ищутся только внутри RV (часть слова после первой гласной).
enum SnowballRussianStemmer {
    private typealias W = [UInt16]

    /// Окончание; `needsA` — перед ним должна стоять «а» или «я» (они остаются в слове).
    private struct Ending {
        let suffix: W
        let needsA: Bool
    }

    private static func ending(_ group1: String, _ group2: String) -> [Ending] {
        let first = group1.split(separator: " ").map { Ending(suffix: Array($0.utf16), needsA: true) }
        let second = group2.split(separator: " ").map { Ending(suffix: Array($0.utf16), needsA: false) }
        return (first + second).sorted { $0.suffix.count > $1.suffix.count }
    }

    private static let perfectiveGerund = ending("в вши вшись", "ив ивши ившись ыв ывши ывшись")
    private static let reflexive = ending("", "ся сь")
    private static let adjective = ending("", "ее ие ые ое ими ыми ей ий ый ой ем им ым ом его ого ему ому их ых ую юю ая яя ою ею")
    private static let participle = ending("ем нн вш ющ щ", "ивш ывш ующ")
    private static let verb = ending(
        "ла на ете йте ли й л ем н ло но ет ют ны ть ешь нно",
        "ила ыла ена ейте уйте ите или ыли ей уй ил ыл им ым ен ило ыло ено ят ует уют ит ыт ены ить ыть ишь ую ю")
    private static let noun = ending(
        "",
        "а ев ов ие ье е иями ями ами еи ии и ией ей ой ий й иям ям ием ем ам ом о у ах иях ях ы ь ю ию ью ия ья я")
    private static let derivational = ending("", "ост ость")
    private static let tidy = ending("", "ейше ейш нн ь")

    private static let vowels: Set<UInt16> = Set("аеиоуыэюя".utf16)
    private static let letterA: UInt16 = 0x430   // а
    private static let letterYa: UInt16 = 0x44F  // я
    private static let letterI: UInt16 = 0x438   // и
    private static let letterN: UInt16 = 0x43D   // н

    static func stem(_ input: String) -> String {
        var word = Array(input.replacingOccurrences(of: "ё", with: "е").utf16)
        // RV — после первой гласной; p2 — после «негласная, гласная, негласная» от RV (граница R2 для шага 3).
        var i = 0
        while i < word.count && !vowels.contains(word[i]) { i += 1 }
        guard i < word.count else { return String(decoding: word, as: UTF16.self) }
        let rv = i + 1
        var j = rv
        func skip(vowel: Bool) {
            while j < word.count && vowels.contains(word[j]) != vowel { j += 1 }
            if j < word.count { j += 1 }
        }
        skip(vowel: false)
        skip(vowel: true)
        skip(vowel: false)
        let r2 = j

        if !remove(&word, from: perfectiveGerund, rv: rv) {
            _ = remove(&word, from: reflexive, rv: rv)
            if remove(&word, from: adjective, rv: rv) {
                _ = remove(&word, from: participle, rv: rv)
            } else if !remove(&word, from: verb, rv: rv) {
                _ = remove(&word, from: noun, rv: rv)
            }
        }
        if word.count > rv, word[word.count - 1] == letterI { word.removeLast() }

        // Шаг 3: «ост/ость» убираются, только если лежат целиком в R2.
        if let match = longest(word, in: derivational, rv: rv), word.count - match.suffix.count >= r2 {
            word.removeLast(match.suffix.count)
        }

        // Шаг 4
        if let match = longest(word, in: tidy, rv: rv) {
            if match.suffix.count >= 3 {                       // «ейш», «ейше»
                word.removeLast(match.suffix.count)
                if word.count >= 2, word[word.count - 1] == letterN, word[word.count - 2] == letterN { word.removeLast() }
            } else if match.suffix.count == 2 {                // «нн» -> «н»
                word.removeLast()
            } else {                                           // «ь»
                word.removeLast()
            }
        }
        return String(decoding: word, as: UTF16.self)
    }

    /// Самое длинное подходящее окончание внутри RV. Если оно требует «а/я» перед собой, а их нет — совпадения нет.
    private static func longest(_ word: W, in endings: [Ending], rv: Int) -> Ending? {
        for ending in endings {
            let start = word.count - ending.suffix.count
            guard start >= rv, Array(word[start...]) == ending.suffix else { continue }
            if ending.needsA {
                guard start - 1 >= rv, word[start - 1] == letterA || word[start - 1] == letterYa else { return nil }
            }
            return ending
        }
        return nil
    }

    private static func remove(_ word: inout W, from endings: [Ending], rv: Int) -> Bool {
        guard let match = longest(word, in: endings, rv: rv) else { return false }
        word.removeLast(match.suffix.count)
        return true
    }
}

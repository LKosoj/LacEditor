import Foundation

/// Черновое описание сцены: результат работы алгоритма или первые предложения текста.
struct SynopsisDraft: Equatable {
    enum Method: Equatable { case firstSentences, textRank }
    let text: String
    let method: Method
}

/// Описание сцены без AI: два самых «центральных» предложения (TextRank — предложения оцениваются по общим словам).
/// Работает для китайского, английского и русского; остальные языки разбираются как английский (по словам из `NLTokenizer`).
enum SceneSynopsisDrafter {
    static let maxCharacters = 300
    static let maxCharactersCJK = 120
    /// Сколько предложений берётся на ранжирование: матрица сходства растёт как квадрат.
    static let maxSentences = 200
    /// Меньше пригодных предложений — ранжировать нечего, берём первые.
    static let minUsableSentences = 5
    static let summarySentenceCount = 2

    /// nil, если в тексте нет ни одного предложения или работа отменена.
    static func draft(from markdown: String, language: TextLanguage? = nil,
                      isCancelled: () -> Bool = { false }) -> SynopsisDraft? {
        if isCancelled() { return nil }
        let prose = plainProse(from: markdown)
        guard !prose.isEmpty else { return nil }
        let lang = language ?? TextSegmentation.language(of: prose)
        let isCJK = lang == .zh
        var sentences: [String] = []
        for (index, segment) in TextSegmentation.sentences(in: prose).prefix(maxSentences).enumerated() {
            if index % 50 == 0, isCancelled() { return nil }
            let collapsed = segment.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !collapsed.isEmpty { sentences.append(collapsed) }
        }
        guard !sentences.isEmpty else { return nil }
        let usable = sentences.indices.filter { isUsable(sentences[$0], isCJK: isCJK) }
        func firstSentences() -> SynopsisDraft? {
            let source = usable.isEmpty ? Array(sentences.indices) : usable
            let picked = source.prefix(summarySentenceCount).map { sentences[$0] }
            guard !picked.isEmpty else { return nil }
            return SynopsisDraft(text: finish(picked, isCJK: isCJK), method: .firstSentences)
        }
        guard usable.count >= minUsableSentences else { return firstSentences() }
        var wordSets: [Set<String>] = []
        for (position, index) in usable.enumerated() {
            if position % 50 == 0, isCancelled() { return nil }
            let words = TextSegmentation.words(in: sentences[index]).map { WordNormalizer.normalize($0.text, language: lang) }
            wordSets.append(Set(words.filter { !$0.isEmpty && !StopWords.contains($0, language: lang) }))
        }
        let scores = rank(wordSets, isCancelled: isCancelled)
        if isCancelled() { return nil }
        guard scores.contains(where: { $0 > 0 }) else { return firstSentences() }
        let order = scores.indices.sorted { left, right in
            abs(scores[left] - scores[right]) > 1e-12 ? scores[left] > scores[right] : left < right
        }
        let best = order.prefix(summarySentenceCount).sorted()
        return SynopsisDraft(text: finish(best.map { sentences[usable[$0]] }, isCJK: isCJK), method: .textRank)
    }

    /// Чистый текст прозы: без front matter, блоков кода, заголовков, картинок и `data:`-адресов,
    /// ссылка `[текст](адрес)` даёт «текст», HTML-теги убраны, `[[вики|текст]]` даёт видимый текст.
    static func plainProse(from markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: {
               let line = $0.trimmingCharacters(in: .whitespaces)
               return line == "---" || line == "..."
           }) {
            lines.removeSubrange(0...close)
        }
        var result: [String] = []
        var fence: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") { fence = "```"; continue }
            if line.hasPrefix("~~~") { fence = "~~~"; continue }
            if line.hasPrefix("#") { continue }
            result.append(cleanLine(line))
        }
        // Абзацы разделяются пустой строкой; лишние пустые строки схлопываются.
        var paragraphs: [String] = []
        var current: [String] = []
        for line in result {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let cleanupPatterns: [(String, String)] = [
        ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),
        ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        ("\\[\\[[^\\]|]*\\|([^\\]]*)\\]\\]", "$1"),
        ("\\[\\[([^\\]]*)\\]\\]", "$1"),
        ("<[^>]*>", ""),
        ("^(?:>\\s*)+", ""),
        ("^(?:[-*+]|\\d+[.)])\\s+", "")
    ]

    private static let cleanups: [(NSRegularExpression, String)] = cleanupPatterns.compactMap { entry in
        (try? NSRegularExpression(pattern: entry.0)).map { ($0, entry.1) }
    }

    private static func cleanLine(_ line: String) -> String {
        var text = line
        for (expression, template) in cleanups {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                       withTemplate: template)
        }
        return text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isUsable(_ sentence: String, isCJK: Bool) -> Bool {
        if isCJK {
            return sentence.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 6
        }
        return TextSegmentation.words(in: sentence).count >= 3
    }

    /// Сходство предложений по общим словам: |a∩b| / (ln|a| + ln|b|), в варианте TextRank с запасом +1 под логарифмом.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let denominator = log(Double(a.count) + 1) + log(Double(b.count) + 1)
        guard denominator > 0 else { return 0 }
        return Double(a.intersection(b).count) / denominator
    }

    /// Оценки предложений (PageRank, d = 0,85). Пустое множество слов — оценка 0; нет ни одной связи — все оценки 0.
    static func rank(_ wordSets: [Set<String>], isCancelled: () -> Bool = { false }) -> [Double] {
        let count = wordSets.count
        guard count > 0 else { return [] }
        var weights = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        var hasEdges = false
        for i in 0..<count {
            if i % 50 == 0, isCancelled() { return [Double](repeating: 0, count: count) }
            for j in (i + 1)..<max(count, i + 1) {
                let value = similarity(wordSets[i], wordSets[j])
                if value > 0 { weights[i][j] = value; weights[j][i] = value; hasEdges = true }
            }
        }
        guard hasEdges else { return [Double](repeating: 0, count: count) }
        let outSum = weights.map { $0.reduce(0, +) }
        let damping = 0.85
        var scores = [Double](repeating: 1 / Double(count), count: count)
        for _ in 0..<30 {
            if isCancelled() { break }
            var next = [Double](repeating: (1 - damping) / Double(count), count: count)
            for j in 0..<count where outSum[j] > 0 {
                let share = damping * scores[j] / outSum[j]
                for i in 0..<count where weights[j][i] > 0 { next[i] += share * weights[j][i] }
            }
            let change = zip(next, scores).map { abs($0 - $1) }.max() ?? 0
            scores = next
            if change < 1e-4 { break }
        }
        return scores.indices.map { wordSets[$0].isEmpty ? 0 : scores[$0] }
    }

    /// Склейка предложений и обрезка до лимита: целое первое предложение, если оно помещается, иначе по границе слова.
    private static func finish(_ sentences: [String], isCJK: Bool) -> String {
        let limit = isCJK ? maxCharactersCJK : maxCharacters
        let joined = sentences.joined(separator: isCJK ? "" : " ")
        guard joined.count > limit else { return joined }
        if let first = sentences.first, first.count <= limit { return first }
        let source = sentences.first ?? joined
        var cut = String(source.prefix(limit - 1))
        if !isCJK, let space = cut.lastIndex(where: { $0.isWhitespace }), space > cut.startIndex {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }
}

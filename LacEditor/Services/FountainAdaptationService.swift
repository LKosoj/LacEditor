import Foundation

/// Чистая часть ИИ-адаптации прозы в Fountain: инструкция, вход, разбор и проверка ответа, сборка. Без сети и без интерфейса.
enum FountainAdaptationService {
    static let instructions = """
    Convert the scene from prose to Fountain screenplay form. Keep the language of the text. \
    Do not invent or drop content. Keep lines starting with `#`, `=`, and `[[ ]]` notes unchanged. \
    Scene headings for non-English text must be forced with a leading dot, e.g. `.ИНТ. КУХНЯ - ДЕНЬ`, `.内景. 厨房 - 白天`. \
    For character names in languages without letter case, use a leading `@`. \
    No title page. No code fences. Reply with JSON: {"fountain": "..."}
    """

    /// Язык сцены сообщается строкой в начале входа.
    static func input(sceneFountain: String, languageCode: String?) -> String {
        guard let languageCode else { return sceneFountain }
        return "Language: \(languageCode)\n\n" + sceneFountain
    }

    /// Повторный запрос: исходный вход и список найденных проблем.
    static func retryInput(base: String, issues: [FountainIssue]) -> String {
        let list = issues.map { "- line \($0.line): \(description(of: $0.kind))" }.joined(separator: "\n")
        return base + "\n\nThe previous reply was rejected. Fix these problems and reply again in the same JSON format:\n" + list
    }

    /// JSON `{"fountain": "..."}` → строка; без JSON берётся текст без ограждений ``` / ```fountain.
    static func parse(_ response: String) -> String? {
        if let object = try? AIResponseJSON.object(response) {
            guard let text = object["fountain"] as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        var text = AIResponseJSON.unwrap(response)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func validate(_ text: String) -> FountainLintResult {
        FountainLint.parse(text, allowsTitlePage: false)
    }

    /// Титульная страница, затем для каждой сцены алгоритмический заголовок и тело, через пустую строку.
    static func assemble(titlePage: String, sections: [(headerFountain: String, body: String)]) -> String {
        var blocks: [String] = []
        if !titlePage.isEmpty { blocks.append(titlePage) }
        for section in sections {
            for text in [section.headerFountain, section.body] {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append(trimmed) }
            }
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    private static func description(of kind: FountainIssueKind) -> String {
        switch kind {
        case .unclosedNote: "a [[ note is not closed with ]]"
        case .unclosedBoneyard: "a /* comment is not closed with */"
        case .missingBlankAfterHeading: "a scene heading must be followed by an empty line"
        case .codeFence: "remove the code fence"
        case .emptyDocument: "the reply is empty"
        case .titlePage: "do not add a title page"
        }
    }
}

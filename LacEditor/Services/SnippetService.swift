import Foundation

enum SnippetService {
    struct Rendered: Equatable {
        let text: String
        /// Смещение курсора в тексте вставки, UTF-16.
        let cursorOffset: Int
    }

    /// Подставляет `{{selection}}`, `{{date}}`, `{{time}}` за один проход: подставленный текст заново не разбирается.
    /// Первый `{{cursor}}` задаёт положение курсора, остальные удаляются; без метки курсор в конце.
    static func render(_ template: String, selection: String, date: Date, timeZone: TimeZone = .current) -> Rendered {
        let values = [
            "{{selection}}": selection,
            "{{date}}": NoteTemplateService.formatted(date, format: NoteTemplateService.defaultDateFormat, timeZone: timeZone),
            "{{time}}": NoteTemplateService.formatted(date, format: NoteTemplateService.defaultTimeFormat, timeZone: timeZone),
        ]
        let result = NoteTemplateService.substitute(template, values: values, cursorToken: "{{cursor}}")
        return Rendered(text: result.text, cursorOffset: result.cursorOffset ?? result.text.utf16.count)
    }

    /// Пустой запрос сохраняет порядок хранилища; иначе ранг общей функции быстрого открытия, при равенстве — порядок хранилища.
    static func ranked(_ snippets: [Snippet], query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }
        let matcher = FolderSearchService.NameQuery(trimmed, caseSensitive: false)
        var scored: [(Snippet, Int, Int)] = []
        for (index, snippet) in snippets.enumerated() {
            if let rank = try? matcher.rank(path: snippet.name, name: snippet.name) {
                scored.append((snippet, rank, index))
            }
        }
        scored.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        return scored.map(\.0)
    }

    /// Одна замена выделения (или вставка в точке курсора) с одной записью отмены; курсор — по `{{cursor}}`.
    static func insertionRequest(snippet: Snippet, selection: EditorTextSelectionSnapshot,
                                 date: Date = Date(), timeZone: TimeZone = .current) -> EditorRangeReplacementRequest {
        let rendered = render(snippet.text, selection: selection.text, date: date, timeZone: timeZone)
        let request = EditorRangeReplacementRequest(
            documentID: selection.documentID,
            range: selection.range,
            originalText: selection.text,
            replacementText: rendered.text,
            expectedEditorRevision: selection.editorRevision,
            actionName: L10n.tr("插入文本片段")
        )
        request.space = .source
        request.groupsUndo = true
        request.resultingSelection = NSRange(location: selection.range.location + rendered.cursorOffset, length: 0)
        return request
    }

    /// Первая непустая строка, не более 40 символов; пусто, если текст из одних пробелов.
    static func suggestedName(for text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
        }
        return ""
    }
}

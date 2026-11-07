import Foundation

/// Общий вход редактора (U6.0): «ядро → builder» за один вызов.
/// AppKit и cmark здесь не нужны: ядро разбора и builder уже работают без них.
extension MarkdownPresentationBuilder {
    /// Какие данные ядро считает для редактора. Критика, встраивания, индекс элементов и данные TextKit нужны всегда;
    /// остальное — по флагам показа.
    static func editorIncludes(readableText: Bool = false, emojiCandidates: Bool = false, uppercaseRuns: Bool = false,
                               wikiLinks: Bool = false, blockIndex: Bool = false) -> MarkdownDocumentModel.Includes {
        var includes: MarkdownDocumentModel.Includes = [.noteEmbeds, .criticMarkup, .elementIndex, .editorContext]
        if wikiLinks { includes.insert(.wikiLinks) }
        if emojiCandidates { includes.insert(.emoji) }
        if uppercaseRuns { includes.insert(.uppercaseRuns) }
        if readableText { includes.insert(.readableText) }
        if blockIndex { includes.insert(.blockIndex) }
        return includes
    }

    /// Модель для сервисов, которым нужны узлы. `nil` — разбор отменён.
    static func model(of text: String, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(),
                      includes: MarkdownDocumentModel.Includes = editorIncludes(), isVaultNote: Bool = false,
                      detectsFrontMatter: Bool = true, isCancelled: @escaping () -> Bool = { false }) -> MarkdownDocumentModel? {
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: isVaultNote, detectsFrontMatter: detectsFrontMatter)
        return MarkdownDocumentParser.parse(text, options: options, isCancelled: isCancelled)
    }

    /// Оформление из модели: NUL заменяется на U+FFFD, как в ядре (длина в UTF-16 та же).
    static func presentation(_ model: MarkdownDocumentModel, of text: String, readableText: Bool = false, emojiCandidates: Bool = false,
                             wikiLinks: Bool = false, isCancelled: @escaping () -> Bool = { false }) -> MarkdownPresentation {
        let source = text.utf8.contains(0) ? text.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") : text
        let options = BuildOptions(includeReadableText: readableText, includeEmojiCandidates: emojiCandidates,
                                   includeWikiLinks: wikiLinks, syntax: model.options.syntax)
        return build(model, text: source as NSString, options: options, isCancelled: isCancelled)
    }

    /// При отмене — пустое оформление.
    static func parse(_ text: String, includeReadableText: Bool = false, includeEmojiCandidates: Bool = false, includeUppercaseRuns: Bool = false,
                      includeWikiLinks: Bool = false, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(), detectsFrontMatter: Bool = true,
                      isVaultNote: Bool = false, blocks: ((MarkdownBlockIndex?) -> Void)? = nil,
                      isCancelled: @escaping () -> Bool = { false }) -> MarkdownPresentation {
        let includes = editorIncludes(readableText: includeReadableText, emojiCandidates: includeEmojiCandidates, uppercaseRuns: includeUppercaseRuns,
                                      wikiLinks: includeWikiLinks, blockIndex: blocks != nil)
        guard let parsed = model(of: text, syntax: syntax, includes: includes, isVaultNote: isVaultNote,
                                 detectsFrontMatter: detectsFrontMatter, isCancelled: isCancelled) else {
            blocks?(nil)
            return MarkdownPresentation(spans: [])
        }
        blocks?(parsed.blockIndex)
        return presentation(parsed, of: text, readableText: includeReadableText, emojiCandidates: includeEmojiCandidates,
                            wikiLinks: includeWikiLinks, isCancelled: isCancelled)
    }

    /// Для сервисов и команд: минимальные флаги (без эмодзи, чтения и wiki-ссылок).
    static func presentation(of text: String, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(),
                             isCancelled: @escaping () -> Bool = { false }) -> MarkdownPresentation {
        parse(text, syntax: syntax, isCancelled: isCancelled)
    }
}

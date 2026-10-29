import AppKit

enum SyntaxHighlighter {
    enum TokenKind: String {
        case keyword
        case string
        case number
        case literal
        case comment
        case function
        case typeName
        case punctuation
        case markup
        case heading
        case strong
        case emphasis
        case attribute
        case property
        case selector
        case variable
    }

    struct Token: Equatable {
        let range: NSRange
        let kind: TokenKind
    }

    final class IncrementalContext {
        fileprivate let codeLexicalContext = CodeLexicalScanner.IncrementalContext()
        fileprivate let markupContext = MarkupContext()

        func reset() {
            codeLexicalContext.reset()
            markupContext.reset()
        }

        func invalidate(after location: Int) {
            codeLexicalContext.invalidate(after: location)
            markupContext.invalidate(after: location)
        }

        var preparedThrough: Int {
            max(codeLexicalContext.preparedThrough, markupContext.preparedThrough)
        }
    }

    private struct RuleDefinition {
        let pattern: String
        let kind: TokenKind
        var options: NSRegularExpression.Options = []
        var group = 0
    }

    private struct CompiledRule {
        let expression: NSRegularExpression
        let kind: TokenKind
        let group: Int
    }

    static func apply(
        to storage: NSTextStorage,
        language: EditorLanguage,
        baseFont _: NSFont,
        range requestedRange: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = requestedRange.map {
            NSIntersectionRange($0, fullRange)
        } ?? fullRange
        guard highlightRange.length > 0 else { return }

        let tokens = tokens(
            in: storage.string,
            language: language,
            range: highlightRange
        )
        for layoutManager in storage.layoutManagers {
            apply(tokens: tokens, to: layoutManager, range: highlightRange)
        }
    }

    static func apply(
        tokens: [Token],
        to layoutManager: NSLayoutManager?,
        range requestedRange: NSRange
    ) {
        guard let layoutManager,
              let storage = layoutManager.textStorage else { return }
        let highlightRange = NSIntersectionRange(
            requestedRange,
            NSRange(location: 0, length: storage.length)
        )
        guard highlightRange.length > 0 else { return }

        // Syntax is presentation-only. Temporary layout attributes cannot
        // alter the document, typing attributes, paragraph metrics, undo stack,
        // or IME marked text. Removing first also clears stale colors when a
        // token disappears after an edit.
        let updates = {
            layoutManager.removeTemporaryAttribute(
                .foregroundColor,
                forCharacterRange: highlightRange
            )

            if let color = (layoutManager as? FoldLayoutManager)?.markdownColors.text?.nsColor {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: highlightRange)
            }

            for token in tokens {
                let tokenRange = NSIntersectionRange(token.range, highlightRange)
                guard tokenRange.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: color(for: token.kind),
                    forCharacterRange: tokenRange
                )
            }
        }
        if let editorLayoutManager = layoutManager as? FoldLayoutManager {
            editorLayoutManager.updateTemporaryAttributes(
                in: highlightRange,
                updates
            )
        } else {
            updates()
            layoutManager.invalidateDisplay(forCharacterRange: highlightRange)
        }
    }

    static func tokens(
        in string: String,
        language: EditorLanguage,
        range requestedRange: NSRange? = nil,
        context: IncrementalContext? = nil,
        revision: UInt? = nil,
        documentID: UUID? = nil,
        edit: DocumentEditDelta? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [Token] {
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let highlightRange = requestedRange.map {
            NSIntersectionRange($0, fullRange)
        } ?? fullRange
        guard highlightRange.length > 0 else { return [] }

        let backend: any SyntaxParserBackend = string.utf8.count > 20 * 1_024 * 1_024
            ? LexicalSyntaxParserBackend()
            : SyntaxParserRegistry.backend(for: language)
        return backend.tokens(
            in: string,
            language: language,
            range: highlightRange,
            context: context,
            revision: revision,
            documentID: documentID,
            edit: edit,
            isCancelled: { isCancelled() }
        )
    }

    static func lexicalTokens(
        in string: String,
        language: EditorLanguage,
        range highlightRange: NSRange,
        context: IncrementalContext?,
        revision: UInt?,
        isCancelled: () -> Bool
    ) -> [Token] {
        let nsString = string as NSString

        switch language {
        case .plainText:
            return []
        case .markdown:
            return markdownTokens(in: nsString, range: highlightRange, context: context?.markupContext, revision: revision, isCancelled: isCancelled)
        case .json:
            return jsonTokens(
                in: string,
                range: highlightRange,
                context: context?.codeLexicalContext,
                revision: revision,
                isCancelled: isCancelled
            )
        case .html:
            return cachedHTMLTokens(in: nsString, range: highlightRange, context: context?.markupContext, revision: revision, isCancelled: isCancelled)
        default:
            var result = semanticTokens(
                in: string,
                language: language,
                range: highlightRange
            )
            result.append(contentsOf: CodeLexicalScanner.tokens(
                in: string,
                language: language,
                range: highlightRange,
                context: context?.codeLexicalContext,
                revision: revision,
                isCancelled: isCancelled
            ).map(syntaxToken))
            return result
        }
    }

    private static func markdownTokens(
        in string: NSString,
        range: NSRange,
        context: MarkupContext?,
        revision: UInt?,
        isCancelled: () -> Bool
    ) -> [Token] {
        guard !isCancelled() else { return [] }
        var result = semanticTokens(
            in: string as String,
            language: .markdown,
            range: range
        )
        if context == nil || revision == nil {
            let full = NSRange(location: 0, length: string.length)
            let fenced = matches(expression: markdownFenceExpression, in: string as String,
                                 range: full, kind: .string)
            guard !isCancelled() else { return [] }
            let inline = matches(expression: markdownInlineCodeExpression, in: string as String,
                                 range: full, kind: .string).filter { token in
                !fenced.contains { NSIntersectionRange($0.range, token.range).length > 0 }
            }
            guard !isCancelled() else { return [] }
            result.append(contentsOf: (fenced + inline).filter {
                NSIntersectionRange($0.range, range).length > 0
            })
            return result
        }
        guard let cached = markupTokens(in: string, language: .markdown, range: range,
                                        context: context, revision: revision, isCancelled: isCancelled) else { return [] }
        result.append(contentsOf: cached)
        return result
    }

    private static func jsonTokens(
        in source: String,
        range: NSRange,
        context: CodeLexicalScanner.IncrementalContext?,
        revision: UInt?,
        isCancelled: () -> Bool
    ) -> [Token] {
        let string = source as NSString
        var result = semanticTokens(
            in: source,
            language: .json,
            range: range
        )
        let strings = CodeLexicalScanner.tokens(
            in: source,
            language: .json,
            range: range,
            context: context,
            revision: revision,
            isCancelled: isCancelled
        ).map(syntaxToken)
        result.append(contentsOf: strings)

        for token in strings where token.kind == .string {
            var location = NSMaxRange(token.range)
            while location < string.length,
                  isWhitespace(string.character(at: location)) {
                location += 1
            }
            if location < string.length, string.character(at: location) == 0x3A {
                result.append(Token(range: token.range, kind: .property))
            }
        }
        return result
    }

    private static func syntaxToken(
        _ token: CodeLexicalScanner.Token
    ) -> Token {
        Token(
            range: token.range,
            kind: token.kind == .comment ? .comment : .string
        )
    }

    private static func htmlTokens(
        in string: NSString,
        source: String? = nil,
        range: NSRange,
        isCancelled: () -> Bool
    ) -> [Token] {
        let source = source ?? (string as String)
        let scanRange = range
        let end = NSMaxRange(scanRange)
        var location = scanRange.location
        var result: [Token] = []
        var iterations = 0

        while location < end {
            if iterations.isMultiple(of: 4_096), isCancelled() { return [] }
            iterations += 1
            if hasPrefix("<!--", in: string, at: location, limit: end) {
                let commentEnd = rangeOf(
                    "-->",
                    in: string,
                    from: location + 4,
                    limit: end
                ).map(NSMaxRange) ?? end
                result.append(Token(
                    range: NSRange(location: location, length: commentEnd - location),
                    kind: .comment
                ))
                location = commentEnd
                continue
            }

            guard string.character(at: location) == 0x3C,
                  isHTMLTagStart(in: string, at: location, limit: end),
                  let tagEnd = htmlTagEnd(in: string, from: location, limit: end, isCancelled: isCancelled)
            else {
                location += 1
                continue
            }

            let tagRange = NSRange(location: location, length: tagEnd - location)
            result.append(Token(range: tagRange, kind: .markup))

            let tagText = string.substring(with: tagRange)
            if let nameMatch = htmlTagNameExpression.firstMatch(
                in: tagText,
                range: NSRange(location: 0, length: (tagText as NSString).length)
            ) {
                let nameRange = nameMatch.range(at: 1)
                if nameRange.location != NSNotFound {
                    result.append(Token(
                        range: NSRange(
                            location: tagRange.location + nameRange.location,
                            length: nameRange.length
                        ),
                        kind: .heading
                    ))
                }
            }

            for match in htmlAttributeExpression.matches(
                in: tagText,
                range: NSRange(location: 0, length: (tagText as NSString).length)
            ) {
                let attributeRange = match.range(at: 1)
                guard attributeRange.location != NSNotFound else { continue }
                result.append(Token(
                    range: NSRange(
                        location: tagRange.location + attributeRange.location,
                        length: attributeRange.length
                    ),
                    kind: .attribute
                ))
            }

            result.append(contentsOf: CodeLexicalScanner.tokens(
                in: source,
                language: .html,
                range: tagRange,
                isCancelled: isCancelled
            ).map(syntaxToken))
            location = tagEnd
        }
        guard !isCancelled() else { return [] }
        return result
    }

    fileprivate struct MarkupGroup {
        let range: NSRange
        let tokens: [Token]
    }

    fileprivate struct MarkupCursor: Equatable {
        var position = 0
        var openStart: Int?
        var unresolvedStart: Int?
    }

    // Markdown has separate cursors for fences and inline code, as in the two rules.
    fileprivate final class MarkupContext {
        private let lock = NSLock()
        private var language: EditorLanguage?
        private var revision: UInt?
        private var generation: UInt = 0
        private var acceptsRevisionChange = false
        private var cursors = [MarkupCursor(), MarkupCursor()]
        private var groups: [[MarkupGroup]] = [[], []]

        func reset() {
            lock.lock()
            resetLocked()
            lock.unlock()
        }

        private func resetLocked() {
            generation &+= 1
            language = nil
            revision = nil
            acceptsRevisionChange = false
            cursors = [MarkupCursor(), MarkupCursor()]
            groups = [[], []]
        }

        func invalidate(after location: Int) {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            for index in 0..<2 {
                var safe = min(cursors[index].position, max(0, location - 4))
                if let open = cursors[index].openStart, safe < cursors[index].position {
                    safe = min(safe, open)
                }
                if let unresolved = cursors[index].unresolvedStart {
                    safe = min(safe, unresolved)
                }
                var low = 0
                var high = groups[index].count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(groups[index][middle].range) <= safe { low = middle + 1 }
                    else { high = middle }
                }
                if low < groups[index].count {
                    safe = min(safe, groups[index][low].range.location)
                    groups[index].removeSubrange(low...)
                }
                if safe < cursors[index].position {
                    cursors[index] = MarkupCursor(position: safe)
                }
            }
            acceptsRevisionChange = true
        }

        var preparedThrough: Int {
            lock.lock()
            defer { lock.unlock() }
            return cursors[0].position
        }

        fileprivate func prepare(language newLanguage: EditorLanguage, revision newRevision: UInt)
            -> (cursors: [MarkupCursor], counts: [Int], generation: UInt)? {
            lock.lock()
            defer { lock.unlock() }
            if language == newLanguage, let currentRevision = revision,
               (newRevision < currentRevision || (acceptsRevisionChange && newRevision == currentRevision)) {
                return nil
            }
            if language != newLanguage || (revision != newRevision &&
                !(acceptsRevisionChange && revision.map { $0 &+ 1 == newRevision } == true)) {
                resetLocked()
                language = newLanguage
                revision = newRevision
            } else if revision != newRevision {
                revision = newRevision
                acceptsRevisionChange = false
            }
            return (cursors, groups.map(\.count), generation)
        }

        fileprivate func relevant(_ index: Int, range: NSRange, count: Int,
                                  generation expectedGeneration: UInt) -> [MarkupGroup] {
            lock.lock()
            defer { lock.unlock() }
            guard generation == expectedGeneration else { return [] }
            return SyntaxHighlighter.intersectingGroups(groups[index], range: range, count: count)
        }

        fileprivate func commit(cursors oldCursors: [MarkupCursor], newCursors: [MarkupCursor],
                                additions: [[MarkupGroup]], language expectedLanguage: EditorLanguage,
                                revision expectedRevision: UInt, generation expectedGeneration: UInt) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard language == expectedLanguage, revision == expectedRevision,
                  generation == expectedGeneration else { return false }
            // Another scan of the same version may already have extended the prefix.
            // Its state wins; the locally computed tokens are still valid for this request.
            if cursors == oldCursors {
                cursors = newCursors
                for index in 0..<2 {
                    groups[index].append(contentsOf: additions[index])
                }
            }
            return true
        }
    }

    private static func intersectingGroups(_ groups: [MarkupGroup], range: NSRange, count: Int? = nil) -> [MarkupGroup] {
        var low = 0
        let end = min(count ?? groups.count, groups.count)
        var high = end
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(groups[middle].range) <= range.location { low = middle + 1 }
            else { high = middle }
        }
        var result: [MarkupGroup] = []
        while low < end && groups[low].range.location < NSMaxRange(range) {
            result.append(groups[low])
            low += 1
        }
        return result
    }

    private static func cachedHTMLTokens(in string: NSString, range: NSRange,
                                         context: MarkupContext?, revision: UInt?,
                                         isCancelled: () -> Bool) -> [Token] {
        if context == nil || revision == nil {
            return htmlTokens(in: string, range: NSRange(location: 0, length: string.length),
                              isCancelled: isCancelled).filter {
                NSIntersectionRange($0.range, range).length > 0
            }
        }
        return markupTokens(in: string, language: .html, range: range, context: context,
                            revision: revision, isCancelled: isCancelled) ?? []
    }

    private static func markupTokens(in string: NSString, language: EditorLanguage, range: NSRange,
                                     context: MarkupContext?, revision: UInt?,
                                     isCancelled: () -> Bool) -> [Token]? {
        let cache = revision == nil ? MarkupContext() : (context ?? MarkupContext())
        guard let prepared = cache.prepare(language: language, revision: revision ?? 0) else { return nil }
        let savedCursors = prepared.cursors
        var cursors = savedCursors
        let htmlSource: String? = language == .html ? (string as String) : nil
        do {
            var additions: [[MarkupGroup]] = [[], []]
            let target = NSMaxRange(range)
            let streams = language == .markdown ? [0, 1, 0] : [0]
            var skipInline = false
            var checks = 0
            func cancelled() -> Bool {
                checks += 1
                return checks.isMultiple(of: 4096) && isCancelled()
            }
            func relevant(_ index: Int, _ requested: NSRange) -> [MarkupGroup] {
                cache.relevant(index, range: requested, count: prepared.counts[index],
                               generation: prepared.generation)
                    + intersectingGroups(additions[index], range: requested)
            }
            guard !isCancelled() else { return nil }
            for stream in streams {
                if language == .markdown && stream == 1 {
                    skipInline = relevant(0, range).contains {
                        $0.range.location <= range.location && NSMaxRange($0.range) >= target
                    } || (cursors[0].openStart.map {
                        $0 <= range.location && cursors[0].position >= target
                    } ?? false)
                    if skipInline { continue }
                }
                var cursor = cursors[stream]
                let streamTarget = language == .markdown && stream == 0 && !skipInline
                    ? max(target, relevant(1, range).map { NSMaxRange($0.range) }.max() ?? target)
                    : target
                while cursor.position < streamTarget && cursor.position < string.length {
                    if cancelled() { return nil }
                    let start = cursor.position
                    if let open = cursor.openStart {
                        let closing = language == .markdown ? "```" : "-->"
                        if hasPrefix(closing, in: string, at: start, limit: string.length) {
                            cursor.position += 3
                            let token = Token(range: NSRange(location: open, length: cursor.position - open),
                                              kind: language == .markdown ? .string : .comment)
                            additions[stream].append(MarkupGroup(range: token.range, tokens: [token]))
                            cursor.openStart = nil
                        } else {
                            cursor.position += 1
                        }
                    } else if language == .markdown && stream == 0 &&
                        hasPrefix("```", in: string, at: start, limit: string.length) {
                        cursor.openStart = start
                        cursor.position += 3
                    } else if language == .markdown && stream == 1 && string.character(at: start) == 0x60 {
                        var end = start + 1
                        while end < string.length && string.character(at: end) != 0x60 && string.character(at: end) != 0x0A {
                            if cancelled() { return nil }
                            end += 1
                        }
                        if end > start + 1 && end < string.length && string.character(at: end) == 0x60 {
                            cursor.position = end + 1
                            let token = Token(range: NSRange(location: start, length: cursor.position - start), kind: .string)
                            additions[stream].append(MarkupGroup(range: token.range, tokens: [token]))
                        } else if end == string.length {
                            cursor.unresolvedStart = start
                            cursor.position = end
                        } else if string.character(at: end) == 0x0A {
                            cursor.position = end + 1
                        } else {
                            cursor.position += 1
                        }
                    } else if language == .html && hasPrefix("<!--", in: string, at: start, limit: string.length) {
                        cursor.openStart = start
                        cursor.position += 4
                    } else if language == .html && string.character(at: start) == 0x3C &&
                        isHTMLTagStart(in: string, at: start, limit: string.length) {
                        var end = start + 1
                        var quote: unichar?
                        var foundEnd = false
                        while end < string.length {
                            if cancelled() { return nil }
                            let character = string.character(at: end)
                            if let active = quote {
                                if character == active { quote = nil }
                                else if character == 0x5C { end += 1 }
                            } else if character == 0x22 || character == 0x27 { quote = character }
                            else if character == 0x3E { end += 1; foundEnd = true; break }
                            end += 1
                        }
                        if foundEnd {
                            cursor.position = end
                            let tagRange = NSRange(location: start, length: end - start)
                            let tokens = htmlTokens(in: string, source: htmlSource, range: tagRange, isCancelled: isCancelled)
                            guard !isCancelled() else { return nil }
                            additions[stream].append(MarkupGroup(range: tagRange, tokens: tokens))
                        } else {
                            // Do not repeatedly rescan nested starts in an unfinished tag.
                            cursor.unresolvedStart = start
                            cursor.position = string.length
                        }
                    } else {
                        cursor.position += 1
                    }
                }
                cursors[stream] = cursor
            }
            guard !isCancelled() else { return nil }
            var primary = relevant(0, range)
            if let open = cursors[0].openStart {
                let token = Token(range: NSRange(location: open, length: cursors[0].position - open),
                                  kind: language == .markdown ? .string : .comment)
                if NSIntersectionRange(token.range, range).length > 0 {
                    primary.append(MarkupGroup(range: token.range, tokens: [token]))
                }
            }
            let tokens: [Token]
            if language == .html {
                tokens = primary.flatMap(\.tokens).filter { NSIntersectionRange($0.range, range).length > 0 }
            } else {
                let inline = (skipInline ? [] : relevant(1, range)).filter { group in
                    relevant(0, group.range).isEmpty &&
                        !(cursors[0].openStart.map { $0 < NSMaxRange(group.range) && cursors[0].position > group.range.location } ?? false)
                }
                tokens = primary.flatMap(\.tokens) + inline.flatMap(\.tokens)
            }
            guard !isCancelled(), cache.commit(cursors: savedCursors, newCursors: cursors,
                    additions: additions, language: language, revision: revision ?? 0,
                    generation: prepared.generation) else { return nil }
            return tokens
        }
    }

    private static func semanticTokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange
    ) -> [Token] {
        guard let rules = compiledRules[language] else { return [] }
        var result: [Token] = []
        for rule in rules {
            result.append(contentsOf: matches(
                expression: rule.expression,
                in: string,
                range: range,
                kind: rule.kind,
                group: rule.group
            ))
        }
        return result
    }

    private static func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func matches(
        expression: NSRegularExpression,
        in string: String,
        range: NSRange,
        kind: TokenKind,
        group: Int = 0
    ) -> [Token] {
        expression.matches(in: string, range: range).compactMap { match in
            let matchRange = match.range(at: group)
            guard matchRange.location != NSNotFound else { return nil }
            return Token(range: matchRange, kind: kind)
        }
    }

    private static func hasPrefix(
        _ prefix: String,
        in string: NSString,
        at location: Int,
        limit: Int
    ) -> Bool {
        let length = prefix.utf16.count
        guard location >= 0, location + length <= limit else { return false }
        return string.compare(
            prefix,
            options: [],
            range: NSRange(location: location, length: length)
        ) == .orderedSame
    }

    private static func rangeOf(
        _ value: String,
        in string: NSString,
        from location: Int,
        limit: Int
    ) -> NSRange? {
        guard location < limit else { return nil }
        let range = string.range(
            of: value,
            options: [],
            range: NSRange(location: location, length: limit - location)
        )
        return range.location == NSNotFound ? nil : range
    }

    private static func isCommentBoundary(
        in string: NSString,
        at location: Int
    ) -> Bool {
        guard location > 0 else { return true }
        let previous = string.character(at: location - 1)
        return previous == 0x20
            || previous == 0x09
            || previous == 0x0A
            || previous == 0x0D
            || previous == 0x3B
    }

    private static func isHTMLTagStart(
        in string: NSString,
        at location: Int,
        limit: Int
    ) -> Bool {
        guard location + 1 < limit else { return false }
        var next = string.character(at: location + 1)
        if next == 0x2F {
            guard location + 2 < limit else { return false }
            next = string.character(at: location + 2)
        }
        return next == 0x21
            || next == 0x3F
            || (next >= 0x41 && next <= 0x5A)
            || (next >= 0x61 && next <= 0x7A)
    }

    private static func htmlTagEnd(
        in string: NSString,
        from start: Int,
        limit: Int,
        isCancelled: () -> Bool
    ) -> Int? {
        var quote: unichar?
        var location = start + 1
        while location < limit {
            if (location - start).isMultiple(of: 4_096), isCancelled() { return nil }
            let character = string.character(at: location)
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == 0x5C {
                    location += 1
                }
            } else if character == 0x22 || character == 0x27 {
                quote = character
            } else if character == 0x3E {
                return location + 1
            }
            location += 1
        }
        return nil
    }

    private static func color(for kind: TokenKind) -> NSColor {
        let color: NSColor
        switch kind {
        case .keyword, .markup, .selector:
            color = Palette.keyword
        case .string:
            color = Palette.string
        case .number:
            color = Palette.number
        case .literal, .function, .typeName, .attribute, .property, .variable:
            color = Palette.symbol
        case .punctuation:
            color = NSColor.tertiaryLabelColor
        case .comment:
            color = NSColor.secondaryLabelColor
        case .heading, .strong:
            color = kind == .heading ? Palette.keyword : Palette.symbol
        case .emphasis:
            color = Palette.symbol
        }
        return color
    }

    private enum Palette {
        static let keyword = adaptive(
            light: (0.29, 0.31, 0.62),
            dark: (0.62, 0.67, 0.98)
        )
        static let string = adaptive(
            light: (0.20, 0.46, 0.29),
            dark: (0.48, 0.76, 0.55)
        )
        static let number = adaptive(
            light: (0.68, 0.34, 0.10),
            dark: (0.94, 0.62, 0.34)
        )
        static let symbol = adaptive(
            light: (0.53, 0.28, 0.61),
            dark: (0.80, 0.59, 0.88)
        )

        private static func adaptive(
            light: (CGFloat, CGFloat, CGFloat),
            dark: (CGFloat, CGFloat, CGFloat)
        ) -> NSColor {
            NSColor(name: nil) { appearance in
                let values = appearance.bestMatch(from: [.darkAqua, .aqua])
                    == .darkAqua ? dark : light
                return NSColor(
                    calibratedRed: values.0,
                    green: values.1,
                    blue: values.2,
                    alpha: 1
                )
            }
        }
    }

    private static let compiledRules: [EditorLanguage: [CompiledRule]] = {
        Dictionary(uniqueKeysWithValues: EditorLanguage.allCases.map { language in
            let rules: [CompiledRule] = ruleDefinitions(for: language).compactMap { definition in
                guard let expression = try? NSRegularExpression(
                    pattern: definition.pattern,
                    options: definition.options
                ) else {
                    return nil
                }
                return CompiledRule(
                    expression: expression,
                    kind: definition.kind,
                    group: definition.group
                )
            }
            return (language, rules)
        })
    }()

    private static func ruleDefinitions(
        for language: EditorLanguage
    ) -> [RuleDefinition] {
        switch language {
        case .plainText, .html:
            return []
        case .markdown:
            return [
                RuleDefinition(
                    pattern: #"^#{1,6}\s+.*$"#,
                    kind: .heading,
                    options: .anchorsMatchLines
                ),
                RuleDefinition(
                    pattern: #"^>\s+.*$"#,
                    kind: .emphasis,
                    options: .anchorsMatchLines
                ),
                RuleDefinition(
                    pattern: #"^(\s*)([-*+]|\d+[.)])\s+"#,
                    kind: .markup,
                    options: .anchorsMatchLines
                ),
                RuleDefinition(
                    pattern: #"\[([^\]]+)\]\(([^)]+)\)"#,
                    kind: .keyword
                ),
                RuleDefinition(
                    pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#,
                    kind: .strong
                ),
                RuleDefinition(
                    pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#,
                    kind: .emphasis
                )
            ]
        case .json:
            return [
                RuleDefinition(
                    pattern: #"\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null)\b"#,
                    kind: .literal
                ),
                RuleDefinition(pattern: #"[\{\}\[\]]"#, kind: .punctuation)
            ]
        case .javascript, .typescript:
            let typeScriptKeywords = language == .typescript
                ? "|abstract|any|as|asserts|bigint|boolean|declare|enum|implements|interface|keyof|namespace|never|number|object|private|protected|public|readonly|required|string|symbol|type|unknown"
                : ""
            return [
                RuleDefinition(
                    pattern: #"([A-Za-z_$][\w$]*)\s*(?=\()"#,
                    kind: .function,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b(?:function|class)\s+([A-Za-z_$][\w$]*)"#,
                    kind: .typeName,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)n?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null|undefined|NaN|Infinity)\b"#,
                    kind: .literal
                ),
                RuleDefinition(
                    pattern: "\\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|get|if|import|in|instanceof|let|new|of|return|set|static|super|switch|this|throw|try|typeof|var|void|while|with|yield\(typeScriptKeywords))\\b",
                    kind: .keyword
                )
            ]
        case .css:
            return [
                RuleDefinition(
                    pattern: #"(?m)^[^{@\n][^{\n]*(?=\s*\{)"#,
                    kind: .selector
                ),
                RuleDefinition(
                    pattern: #"(?m)^\s*([-\w]+)(?=\s*:)"#,
                    kind: .property,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"(?m)^\s*@[A-Za-z-]+"#,
                    kind: .keyword
                )
            ]
        case .python:
            return [
                RuleDefinition(
                    pattern: #"\b(?:def|class)\s+([A-Za-z_]\w*)"#,
                    kind: .typeName,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?j?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:True|False|None|NotImplemented|Ellipsis)\b"#,
                    kind: .literal
                ),
                RuleDefinition(
                    pattern: #"\b(?:and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#,
                    kind: .keyword
                )
            ]
        case .swift:
            return [
                RuleDefinition(
                    pattern: #"\b(?:func|class|struct|enum|protocol)\s+([A-Za-z_]\w*)"#,
                    kind: .typeName,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
                    kind: .number
                ),
                RuleDefinition(pattern: #"\b(?:true|false|nil)\b"#, kind: .literal),
                RuleDefinition(
                    pattern: #"\b(?:actor|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|do|else|enum|extension|fallthrough|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|isolated|lazy|let|mutating|nonisolated|open|operator|override|private|protocol|public|repeat|required|rethrows|return|self|set|some|static|struct|subscript|super|switch|throws|try|typealias|var|where|while|willSet|didSet)\b"#,
                    kind: .keyword
                )
            ]
        case .shell:
            return [
                RuleDefinition(
                    pattern: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#,
                    kind: .variable
                ),
                RuleDefinition(pattern: #"\b\d+\b"#, kind: .number),
                RuleDefinition(
                    pattern: #"\b(?:case|do|done|elif|else|esac|fi|for|function|if|in|select|then|time|until|while)\b"#,
                    kind: .keyword
                )
            ]
        case .yaml:
            return [
                RuleDefinition(
                    pattern: #"(?m)^(\s*[-?]?\s*[A-Za-z0-9_.-]+)(?=\s*:)"#,
                    kind: .property,
                    group: 1
                ),
                RuleDefinition(pattern: #"(?m)^\s*-\s+"#, kind: .markup),
                RuleDefinition(pattern: #"\b-?\d+(?:\.\d+)?\b"#, kind: .number),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null|yes|no|on|off|~)\b"#,
                    kind: .literal,
                    options: .caseInsensitive
                )
            ]
        case .cFamily:
            return [
                RuleDefinition(
                    pattern: #"(?m)^\s*#\s*[A-Za-z]+"#,
                    kind: .keyword
                ),
                RuleDefinition(
                    pattern: #"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:alignas|alignof|asm|auto|bool|break|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|export|extern|false|float|for|friend|if|inline|int|long|namespace|new|nullptr|operator|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while)\b"#,
                    kind: .keyword
                )
            ]
        case .sql:
            return [
                RuleDefinition(pattern: #"\b-?\d+(?:\.\d+)?\b"#, kind: .number),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null)\b"#,
                    kind: .literal,
                    options: .caseInsensitive
                ),
                RuleDefinition(
                    pattern: #"\b(?:add|alter|and|as|asc|begin|between|by|case|commit|create|database|default|delete|desc|distinct|drop|else|end|exists|from|full|group|having|in|index|inner|insert|into|is|join|left|like|limit|not|null|on|or|order|outer|primary|references|right|rollback|select|set|table|then|union|unique|update|values|view|when|where|with)\b"#,
                    kind: .keyword,
                    options: .caseInsensitive
                )
            ]
        }
    }

    private static let markdownFenceExpression = try! NSRegularExpression(
        pattern: #"(?s)```.*?(?:```|\z)"#
    )
    private static let markdownInlineCodeExpression = try! NSRegularExpression(
        pattern: #"`[^`\n]+`"#
    )
    private static let htmlTagNameExpression = try! NSRegularExpression(
        pattern: #"^</?\s*([A-Za-z][A-Za-z0-9:-]*)"#
    )
    private static let htmlAttributeExpression = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)(?=\s*(?:=|/?>))"#
    )

}

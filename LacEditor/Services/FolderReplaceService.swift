import Foundation

/// Замена найденного поиском по папке: построение правок и запись закрытых файлов.
enum FolderReplaceService {
    struct Request: Equatable, Sendable {
        var query: String
        var replacement: String
        var options: TextSearchService.Options
        var interpretsEscapes: Bool
    }

    /// Одна замена в координатах UTF-16 исходного текста.
    struct Edit: Equatable, Sendable {
        let range: NSRange
        let original: String
        let replacement: String
    }

    struct Enclosing: Equatable, Sendable {
        let range: NSRange
        let original: String
        let replacement: String
    }

    enum SkipReason: Equatable, Sendable {
        case changed, notExactUTF8, inaccessible, symbolicLink, writeFailed
        case openDocumentBusy, openInEditorFailed
    }

    enum Outcome: Equatable, Sendable {
        case replaced(Int)
        case skipped(SkipReason)
    }

    /// Выбранные совпадения уже не соответствуют тексту.
    enum EditError: Error { case selectionChanged }

    /// Замены для совпадений запроса; `only` оставляет только выбранные диапазоны (регулярка идёт по всему тексту, как при поиске).
    static func edits(in text: String, request: Request, only: Set<NSRange>? = nil,
                      isCancelled: () -> Bool = { false }) throws -> [Edit] {
        guard !request.query.isEmpty else { return [] }
        let source = text as NSString
        var result: [Edit] = []
        if request.options.isPlain {
            let replacement = TextSearchService.interpreted(request.replacement, enabled: request.interpretsEscapes)
            let ranges = TextSearchService.allRanges(in: text, query: request.query,
                                                     caseSensitive: request.options.caseSensitive, isCancelled: isCancelled)
            if isCancelled() { throw CancellationError() }
            for range in ranges where only?.contains(range) ?? true {
                result.append(Edit(range: range, original: source.substring(with: range), replacement: replacement))
            }
        } else {
            let regex = try TextSearchService.regularExpression(query: request.query, options: request.options)
            let template = TextSearchService.template(for: request.replacement, options: request.options,
                                                      interpretsEscapes: request.interpretsEscapes)
            var cancelled = false
            regex.enumerateMatches(in: text, options: [.reportProgress],
                                   range: NSRange(location: 0, length: source.length)) { match, _, stop in
                if isCancelled() { cancelled = true; stop.pointee = true; return }
                // Пустые совпадения пропускаются, как в поиске.
                guard let match, match.range.length > 0, only?.contains(match.range) ?? true else { return }
                result.append(Edit(range: match.range, original: source.substring(with: match.range),
                                   replacement: regex.replacementString(for: match, in: text, offset: 0, template: template)))
            }
            if cancelled { throw CancellationError() }
        }
        if let only, only.count != result.count { throw EditError.selectionChanged }
        return result
    }

    /// Применяет правки к строке; nil, если диапазоны перекрываются, вышли за текст или не совпали с `original`.
    static func apply(_ edits: [Edit], to text: String) -> String? {
        guard let span = Self.enclosing(edits, in: text, allowsNoChange: true) else { return edits.isEmpty ? text : nil }
        let source = text as NSString
        return source.substring(to: span.range.location) + span.replacement + source.substring(from: NSMaxRange(span.range))
    }

    /// Один объемлющий диапазон: невыбранный текст между правками остаётся как есть.
    static func enclosing(_ edits: [Edit], in text: String) -> Enclosing? {
        enclosing(edits, in: text, allowsNoChange: false)
    }

    private static func enclosing(_ edits: [Edit], in text: String, allowsNoChange: Bool) -> Enclosing? {
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first else { return nil }
        let source = text as NSString
        var cursor = first.range.location
        var composed = ""
        for edit in sorted {
            guard edit.range.location != NSNotFound, edit.range.location >= cursor, edit.range.length >= 0,
                  NSMaxRange(edit.range) <= source.length,
                  source.substring(with: edit.range) == edit.original else { return nil }
            composed += source.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)) + edit.replacement
            cursor = NSMaxRange(edit.range)
        }
        let span = NSRange(location: first.range.location, length: cursor - first.range.location)
        let original = source.substring(with: span)
        // Редактор отвергает замену, равную оригиналу.
        if !allowsNoChange, original == composed { return nil }
        return Enclosing(range: span, original: original, replacement: composed)
    }

    /// Закрытый файл: повторное чтение, сверка отметки и точных фрагментов, атомарная запись UTF-8.
    static func replaceOnDisk(file: FolderSearchService.File, expected: FileRevisionSnapshot,
                              matches: [FolderSearchService.Match], request: Request, root: URL,
                              isCancelled: () -> Bool = { false }) throws -> Outcome {
        let text: String
        do { text = try FolderSearchService.readForReplace(url: file.url, root: root, expected: expected, isCancelled: isCancelled) }
        catch let failure as FolderSearchService.ReplaceReadFailure {
            switch failure {
            case .changed: return .skipped(.changed)
            case .notExactUTF8: return .skipped(.notExactUTF8)
            case .symbolicLink: return .skipped(.symbolicLink)
            case .inaccessible: return .skipped(.inaccessible)
            }
        }
        let planned: [Edit]
        do { planned = try edits(in: text, request: request, only: Set(matches.map(\.range)), isCancelled: isCancelled) }
        catch is CancellationError { throw CancellationError() }
        catch { return .skipped(.changed) }
        let originals = Dictionary(matches.map { ($0.range, $0.matchedText) }, uniquingKeysWith: { first, _ in first })
        guard planned.allSatisfy({ originals[$0.range] == $0.original }), let output = apply(planned, to: text) else {
            return .skipped(.changed)
        }
        if isCancelled() { throw CancellationError() }
        // Запущенную атомарную запись отмена не прерывает; окно подмены между проверкой и записью остаётся.
        guard (try? FileRevisionSnapshot.capture(file.url)) == expected else { return .skipped(.changed) }
        if output != text {
            do { try FileService.writeUTF8(output, to: file.url) }
            catch { return .skipped(.writeFailed) }
        }
        return .replaced(planned.count)
    }
}

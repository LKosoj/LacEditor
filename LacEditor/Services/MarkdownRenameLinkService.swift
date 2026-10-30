import Foundation

/// Обновление ссылок на Markdown-файл при переименовании: построение правок и запись закрытых файлов.
/// Правится только имя в wiki-ссылке и сырой путь во вложенной ссылке `[текст](адрес)`; остальное остаётся как есть.
enum MarkdownRenameLinkService {
    /// Пути стандартизованные, оба внутри `root`.
    struct Rename: Equatable, Sendable {
        let oldURL: URL
        let newURL: URL
        let root: URL
    }

    struct Counts: Equatable, Sendable {
        /// Новое имя содержит `#`, `|`, `[`, `]`, `\` и т. п.
        var unsafeName = 0
        /// Wiki-ссылка неоднозначна, и среди вариантов есть старый файл.
        var ambiguous = 0
        /// `file:`, сноски, HTML, сущности, неподтверждённый адрес, перекрытие правок.
        var unsupported = 0
        var total: Int { unsafeName + ambiguous + unsupported }
    }

    struct FilePlan: Equatable, Sendable {
        let file: FolderSearchService.File
        let source: FolderSearchService.Source
        /// По возрастанию, без перекрытий.
        let edits: [FolderReplaceService.Edit]
        var isOpen: Bool { if case .open = source { true } else { false } }
    }

    struct Plan: Equatable, Sendable {
        let rename: Rename
        let files: [FilePlan]
        let skipped: Counts
        let problems: [FolderSearchService.Problem]
        var linkCount: Int { files.reduce(0) { $0 + $1.edits.count } }
        var fileCount: Int { files.count }

        static func empty(_ rename: Rename) -> Plan { Plan(rename: rename, files: [], skipped: Counts(), problems: []) }
    }

    struct SkippedFile: Equatable, Sendable {
        let file: FolderSearchService.File
        let reason: FolderReplaceService.SkipReason
    }

    struct Report: Equatable, Sendable {
        var updatedLinks = 0
        var updatedFiles = 0
        var skipped: [SkippedFile] = []
        var isCancelled = false
    }

    struct Context: Sendable {
        let rename: Rename
        /// Относительные пути от корня, «/».
        let oldPath: String
        let newPath: String
        /// Каталог до переименования.
        let oldResolver: MarkdownWikiLinkResolver
        /// Тот же каталог, где старый путь заменён новым.
        let newResolver: MarkdownWikiLinkResolver
        /// Адрес старый, идентичность снята до переноса.
        let target: FolderSearchService.BacklinkTarget
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()[]<>\\ /$:&")
        return set
    }()

    private static let forbiddenInWikiTarget = CharacterSet(charactersIn: "#|[]\\\0\n\r\u{2028}\u{2029}")

    private static func isMarkdownExtension(_ value: String) -> Bool {
        ["md", "markdown"].contains((value as NSString).pathExtension.lowercased())
    }

    /// Правки ссылок на старый файл в одном тексте. Файл ещё лежит по старому адресу: обычные ссылки подтверждаются по идентичности.
    static func edits(in text: String, file: FolderSearchService.File, context: Context, needles: [String],
                      counts: inout Counts, isCancelled: () -> Bool) throws -> [FolderReplaceService.Edit] {
        if isCancelled() { throw CancellationError() }
        let source = text as NSString
        guard MarkdownBacklinkScanner.mayLink(source, needles: needles) else { return [] }
        // разбор принимает замыкание отмены как escaping, но не сохраняет его после возврата
        let presentation = withoutActuallyEscaping(isCancelled) {
            MarkdownPresentationParser.parse(text, includeWikiLinks: true, syntax: context.target.syntax, isCancelled: $0)
        }
        if isCancelled() { throw CancellationError() }
        var result: [FolderReplaceService.Edit] = []
        for link in presentation.wikiLinks {
            if isCancelled() { throw CancellationError() }
            switch context.oldResolver.resolve(target: link.target) {
            case let .file(path) where path == context.oldPath: break
            case let .ambiguous(paths) where paths.contains(context.oldPath): counts.ambiguous += 1; continue
            default: continue
            }
            guard let range = MarkdownWikiLinkExtractor.targetRange(of: link, in: source) else { counts.unsupported += 1; continue }
            switch wikiTarget(replacing: link.target, context: context) {
            case let .value(value): result.append(.init(range: range, original: source.substring(with: range), replacement: value))
            case .unsafe: counts.unsafeName += 1
            case .unsupported: counts.unsupported += 1
            }
        }
        var tails: [NSRange: NSRange] = [:]
        for span in presentation.spans where span.kind == .link && span.markerRanges.count == 2 { tails[span.range] = span.markerRanges[1] }
        for link in presentation.links {
            if isCancelled() { throw CancellationError() }
            guard MarkdownBacklinkScanner.isLink(link.url, from: file.url, to: context.target) else { continue }
            if let tail = tails[link.range], let edit = linkEdit(link, tail: tail, in: source, file: file, context: context) {
                result.append(edit)
            } else { counts.unsupported += 1 }
        }
        result = result.filter { $0.original != $0.replacement }.sorted { $0.range.location < $1.range.location }
        var kept: [FolderReplaceService.Edit] = []
        for edit in result {
            if let last = kept.last, NSMaxRange(last.range) > edit.range.location { counts.unsupported += 1; continue }
            kept.append(edit)
        }
        return kept
    }

    private enum WikiTarget { case value(String), unsafe, unsupported }

    /// Новая цель в стиле старой: `./`, путь или короткое имя, с расширением или без. Короткая форма — только если однозначна в новом каталоге.
    private static func wikiTarget(replacing old: String, context: Context) -> WikiTarget {
        if context.newPath.unicodeScalars.contains(where: forbiddenInWikiTarget.contains) { return .unsafe }
        let hasDot = old.hasPrefix("./")
        let body = hasDot ? String(old.dropFirst(2)) : old
        let isPath = hasDot || body.contains("/")
        func styled(_ path: String) -> String {
            isMarkdownExtension(body) ? path : (isMarkdownExtension(path) ? (path as NSString).deletingPathExtension : path)
        }
        var candidates: [String] = []
        if !isPath { candidates.append(styled((context.newPath as NSString).lastPathComponent)) }
        candidates.append((hasDot ? "./" : "") + styled(context.newPath))
        for candidate in candidates
        where candidate == candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) &&
            context.newResolver.resolve(target: candidate) == .file(context.newPath) {
            return .value(candidate)
        }
        return .unsupported
    }

    /// Правка сырого пути вложенной ссылки; nil — форма не подтверждена.
    private static func linkEdit(_ link: MarkdownLink, tail: NSRange, in source: NSString, file: FolderSearchService.File,
                                 context: Context) -> FolderReplaceService.Edit? {
        guard tail.location >= 0, tail.length >= 3, NSMaxRange(tail) <= source.length,
              source.substring(with: NSRange(location: tail.location, length: 2)) == "](",
              source.character(at: NSMaxRange(tail) - 1) == 41,
              let (rawRange, isBracketed) = rawDestination(in: source, tail: tail) else { return nil }
        let raw = source.substring(with: rawRange)
        guard !raw.contains("\\"), !raw.contains("&"), raw == link.url else { return nil }
        let rawText = raw as NSString
        let split = rawText.rangeOfCharacter(from: CharacterSet(charactersIn: "#?"))
        let pathLength = split.location == NSNotFound ? rawText.length : split.location
        let oldPath = rawText.substring(to: pathLength), suffix = rawText.substring(from: pathLength)
        guard !oldPath.isEmpty, !oldPath.hasPrefix("//"),
              oldPath.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return nil }
        let isAbsolute = oldPath.hasPrefix("/")
        let hasDot = oldPath.hasPrefix("./")
        let hadExtension = isMarkdownExtension(oldPath)
        var parts: [String]
        if isAbsolute {
            parts = Array(context.rename.newURL.pathComponents.dropFirst())
        } else {
            let directory = (file.relativePath as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            let target = context.newPath.split(separator: "/").map(String.init)
            var common = 0
            while common < directory.count, common < target.count - 1, directory[common] == target[common] { common += 1 }
            parts = Array(repeating: "..", count: directory.count - common) + target[common...]
        }
        if !hadExtension, let last = parts.last, isMarkdownExtension(last) { parts[parts.count - 1] = (last as NSString).deletingPathExtension }
        let percentStyle = oldPath.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil
        let encoded = parts.map { part -> String in
            if part == ".." { return part }
            let needs = percentStyle || part.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || scalar.value == 0x7F || (isBracketed ? "<>\\%#?&" : " ()[]<>\\%#?&").unicodeScalars.contains(scalar)
            }
            return needs ? (part.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? part) : part
        }
        var newPath = encoded.joined(separator: "/")
        if isAbsolute { newPath = "/" + newPath } else if hasDot, !newPath.hasPrefix("..") { newPath = "./" + newPath }
        // Новый адрес обязан вести ровно на новый файл с тем же фрагментом.
        let expected = hadExtension ? context.rename.newURL.path : context.rename.newURL.deletingPathExtension().path
        let newAddress = MarkdownBacklinkScanner.navigableAddress(newPath + suffix)
        guard case let .file(url, fragment)? = try? MarkdownLinkNavigationService.destination(for: newAddress, documentURL: file.url),
              case let .file(_, oldFragment)? = try? MarkdownLinkNavigationService.destination(for: MarkdownBacklinkScanner.navigableAddress(raw), documentURL: file.url),
              fragment == oldFragment, url.path == expected else { return nil }
        return .init(range: NSRange(location: rawRange.location, length: pathLength), original: oldPath, replacement: newPath)
    }

    /// Сырой адрес в хвосте `](…)` (внутри `<>` без скобок). Адрес до пробела или управляющего символа, скобки с `\` не разбираются.
    static func rawDestination(in text: NSString, tail: NSRange) -> (NSRange, Bool)? {
        let end = NSMaxRange(tail) - 1
        var index = tail.location + 2
        while index < end, [32, 9, 10, 13].contains(text.character(at: index)) { index += 1 }
        guard index < end else { return nil }
        if text.character(at: index) == 60 {
            let start = index + 1
            var cursor = start
            while cursor < end {
                let unit = text.character(at: cursor)
                if unit == 92 { cursor += 2; continue }
                if unit == 62 { return cursor > start ? (NSRange(location: start, length: cursor - start), true) : nil }
                if unit == 60 || unit == 10 || unit == 13 { return nil }
                cursor += 1
            }
            return nil
        }
        let start = index
        while index < end {
            let unit = text.character(at: index)
            if unit == 92 { index += 2; continue }
            if unit <= 32 { break }
            index += 1
        }
        return index > start && index <= end ? (NSRange(location: start, length: index - start), false) : nil
    }

    /// Закрытый файл: чтение с отметкой до/после, сверка фрагментов, повторная сверка отметки, атомарная запись UTF-8.
    static func applyOnDisk(_ plan: FilePlan, root: URL, isCancelled: () -> Bool = { false }) throws -> FolderReplaceService.Outcome {
        guard case let .disk(expected) = plan.source else { return .skipped(.changed) }
        let text: String
        do { text = try FolderSearchService.readForReplace(url: plan.file.url, root: root, expected: expected, isCancelled: isCancelled) }
        catch let failure as FolderSearchService.ReplaceReadFailure {
            switch failure {
            case .changed: return .skipped(.changed)
            case .notExactUTF8: return .skipped(.notExactUTF8)
            case .symbolicLink: return .skipped(.symbolicLink)
            case .inaccessible: return .skipped(.inaccessible)
            }
        }
        guard let output = FolderReplaceService.apply(plan.edits, to: text) else { return .skipped(.changed) }
        if isCancelled() { throw CancellationError() }
        // Запущенную атомарную запись отмена не прерывает; окно подмены между проверкой и записью остаётся.
        guard (try? FileRevisionSnapshot.capture(plan.file.url)) == expected else { return .skipped(.changed) }
        do { try FileService.writeUTF8(output, to: plan.file.url) } catch { return .skipped(.writeFailed) }
        return .replaced(plan.edits.count)
    }
}

import Foundation

enum AIAgentEditLimits {
    /// old_text и new_text, UTF-16.
    static let maxTextUnits = 20_000
    /// old_text и new_text вместе, UTF-16: больше - пословное сравнение слишком дорого для главного потока.
    static let maxDiffUnits = 4_000
    static let maxExplanationCharacters = 500
    static let maxPendingEdits = 50
    static let maxCountedMatches = 20
    /// Закрытых файлов с правками в черновике; потолок правок общий.
    static let maxClosedFiles = 10
}

/// Предложенная моделью замена фрагмента. Пока пользователь не принял её, документ не меняется.
struct AIAgentEdit: Identifiable, Equatable, Sendable {
    enum Problem: Error, Equatable, Sendable { case notFound, ambiguous, needsEarlier, dependsOnRejected, fileChanged }
    let id: UUID
    /// Для edit_id модели: "e<number>".
    let number: Int
    let documentID: UUID
    let documentName: String
    /// Относительный путь или open:<id>.
    let path: String
    let oldText: String
    let newText: String
    let explanation: String
    let externalReferences: [String]
    var problem: Problem?
    /// Правка файла, не открытого в редакторе: пишется на диск кнопкой «Применить к файлам».
    var isClosedFile = false

    /// Та же правка в группе открытого документа (файл открыли, пока правки ждали).
    func moved(to document: AIAgentOpenDocument) -> AIAgentEdit {
        AIAgentEdit(id: id, number: number, documentID: document.id, documentName: document.name, path: path, oldText: oldText,
                    newText: newText, explanation: explanation, externalReferences: externalReferences,
                    problem: problem == .dependsOnRejected ? problem : nil, isClosedFile: false)
    }
}

/// Закрытый файл рабочей папки с правками в черновике.
struct AIAgentClosedFile: Equatable, Sendable {
    let url: URL
    let relativePath: String
    /// Отметка файла при первом чтении.
    let snapshot: FileRevisionSnapshot
}

/// Что писать в файл: он сам и его применимые правки по порядку.
struct AIAgentClosedPlan: Equatable, Sendable {
    /// Ключ записи черновика.
    let key: UUID
    let file: AIAgentClosedFile
    let name: String
    let edits: [AIAgentEdit]
}

struct AIAgentEditGroup: Identifiable, Equatable {
    /// documentID.
    let id: UUID
    let name: String
    var edits: [AIAgentEdit]
    var isClosedFile: Bool { edits.first?.isClosedFile == true }
}

struct AIAgentEditDiff {
    let original: AttributedString
    let replacement: AttributedString
}

struct AIAgentEditPlan {
    let text: String
    let applied: [UUID]
    let failed: [(id: UUID, problem: AIAgentEdit.Problem)]
}

/// Чистая логика правок: все диапазоны в UTF-16 (NSRange).
enum AIAgentEditEngine {
    private static func hasCarriageReturn(_ text: String) -> Bool { text.utf16.contains(0x0D) }

    /// Модель пишет переносы как \n: CRLF и одиночный CR приводятся к LF.
    static func normalizedNewlines(_ text: String) -> String {
        guard hasCarriageReturn(text) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Текст ошибки для модели или nil, если аргументы годны.
    static func argumentError(oldText: String, newText: String) -> String? {
        if oldText.isEmpty { return "old_text must not be empty." }
        if oldText.utf16.count > AIAgentEditLimits.maxTextUnits || newText.utf16.count > AIAgentEditLimits.maxTextUnits {
            return "old_text or new_text is longer than \(AIAgentEditLimits.maxTextUnits) characters; split the edit."
        }
        if normalizedNewlines(oldText) == normalizedNewlines(newText) { return "new_text is identical to old_text; nothing to change." }
        return nil
    }

    /// Точное сравнение (.literal), совпадения могут перекрываться; в документе с CR перенос в old_text совпадает с любым окончанием строки.
    static func matches(of oldText: String, in text: String, limit: Int) -> [NSRange] {
        guard !oldText.isEmpty, limit > 0 else { return [] }
        let string = text as NSString
        var result: [NSRange] = []
        var from = 0
        let needle = hasCarriageReturn(text) ? normalizedNewlines(oldText) : oldText
        if needle.contains("\n"), hasCarriageReturn(text) {
            // Группа атомарная: один CRLF не считается двумя переносами; совпадение не начинается внутри CRLF
            let pattern = (needle.hasPrefix("\n") ? "(?!(?<=\\r)\\n)" : "")
                + NSRegularExpression.escapedPattern(for: needle).replacingOccurrences(of: "\n", with: "(?>\\r\\n|\\n|\\r)")
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            while from <= string.length, result.count < limit {
                guard let match = expression.firstMatch(in: text, options: .withTransparentBounds, range: NSRange(location: from, length: string.length - from)) else { break }
                result.append(match.range)
                from = match.range.location + 1
            }
            return result
        }
        while from < string.length, result.count < limit {
            let found = string.range(of: needle, options: .literal, range: NSRange(location: from, length: string.length - from))
            if found.location == NSNotFound { break }
            result.append(found)
            from = found.location + 1
        }
        return result
    }

    /// Первое окончание строки в тексте: CRLF, CR или LF.
    private static func firstTerminator(in text: String) -> String? {
        let units = Array(text.utf16)
        for (index, unit) in units.enumerated() {
            if unit == 0x0D { return index + 1 < units.count && units[index + 1] == 0x0A ? "\r\n" : "\r" }
            if unit == 0x0A { return "\n" }
        }
        return nil
    }

    static func apply(_ edit: AIAgentEdit, to text: String) -> Result<String, AIAgentEdit.Problem> {
        let found = matches(of: edit.oldText, in: text, limit: 2)
        guard let range = found.first else { return .failure(.notFound) }
        guard found.count == 1 else { return .failure(.ambiguous) }
        let string = text as NSString
        var replacement = edit.newText
        if hasCarriageReturn(text) {
            let terminator = firstTerminator(in: string.substring(with: range)) ?? firstTerminator(in: text) ?? "\n"
            replacement = normalizedNewlines(replacement).replacingOccurrences(of: "\n", with: terminator)
        }
        return .success(string.replacingCharacters(in: range, with: replacement))
    }

    /// Выбранные правки применяются по порядку к text. Не нашлось, а ранее есть непринятая — значит, нужна она (needsEarlier).
    static func plan(edits: [AIAgentEdit], on text: String, earlierPending: Set<UUID>) -> AIAgentEditPlan {
        var current = text
        var applied: [UUID] = []
        var failed: [(id: UUID, problem: AIAgentEdit.Problem)] = []
        for edit in edits {
            switch apply(edit, to: current) {
            case let .success(changed):
                current = changed
                applied.append(edit.id)
            case let .failure(problem):
                failed.append((edit.id, problem == .notFound && !earlierPending.isEmpty ? .needsEarlier : problem))
            }
        }
        return AIAgentEditPlan(text: current, applied: applied, failed: failed)
    }

    /// Общие начало и конец отрезаются; граница не режет суррогатную пару. nil — тексты равны.
    static func enclosingChange(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        guard old != new else { return nil }
        let before = Array(old.utf16), after = Array(new.utf16)
        func isHigh(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
        func isLow(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
        let shortest = min(before.count, after.count)
        var prefix = 0
        while prefix < shortest, before[prefix] == after[prefix] { prefix += 1 }
        if prefix > 0, isHigh(before[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < shortest - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, isLow(before[before.count - suffix]) { suffix -= 1 }
        let replacement = String(decoding: after[prefix..<(after.count - suffix)], as: UTF16.self)
        return (NSRange(location: prefix, length: before.count - prefix - suffix), replacement)
    }

    /// Адреса и вставки, которых нет в старом тексте: только подсветка, принятие не блокируется.
    static func externalReferences(old: String, new: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"https?://[^\s<>"'\)\]]+|src\s*=\s*["']?[^"'\s>]*|<iframe\b"#, options: .caseInsensitive) else { return [] }
        let known = old.lowercased()
        let string = new as NSString
        var result: [String] = []
        for match in expression.matches(in: new, range: NSRange(location: 0, length: string.length)) {
            let found = string.substring(with: match.range)
            if !known.contains(found.lowercased()), !result.contains(found) { result.append(found) }
        }
        return Array(result.prefix(3))
    }
}

/// Черновик правок: копия текста открытых документов с предложенными правками. Настоящий документ не трогает.
final class AIAgentEditDraft: @unchecked Sendable {
    enum Proposal {
        case added(AIAgentEdit, pendingInDocument: Int)
        case duplicate(number: Int, pendingInDocument: Int)
        case failed(AIAgentToolError, String)
    }

    /// text = base плюс все правки без проблем, применённые по порядку.
    private struct Entry {
        var base: String
        var edits: [AIAgentEdit]
        var text: String
        /// Не nil у записи закрытого файла; ключ записи - случайный UUID, файл узнаётся по идентичности.
        var closed: AIAgentClosedFile?
    }

    private static let noMatchMessage = "old_text was not found in the document (proposed edits already count as applied). Re-read the lines and copy the text exactly."

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var calls: [String: Int] = [:]
    private var nextNumber = 1
    /// Поколение запуска: правка от уже остановленного запуска в черновик не попадает.
    private var currentEpoch = 0

    var epoch: Int { lock.withLock { currentEpoch } }

    /// Запуск остановлен: его запоздавшие вызовы больше ничего не добавят.
    func retire() { lock.withLock { currentEpoch += 1 } }

    /// Пересобирает текст и проблемы заново; прежняя dependsOnRejected сохраняется, пока правка не применяется, fileChanged - всегда.
    private static func rebuild(_ entry: inout Entry) {
        var text = entry.base
        for index in entry.edits.indices {
            if entry.edits[index].problem == .fileChanged { continue }
            switch AIAgentEditEngine.apply(entry.edits[index], to: text) {
            case let .success(changed):
                text = changed
                entry.edits[index].problem = nil
            case let .failure(problem):
                entry.edits[index].problem = entry.edits[index].problem == .dependsOnRejected ? .dependsOnRejected : problem
            }
        }
        entry.text = text
    }

    private func pendingCount(_ documentID: UUID) -> Int {
        entries[documentID]?.edits.filter { $0.problem == nil }.count ?? 0
    }

    private static func normalizedPath(_ path: String) -> String { path.split(separator: "/").joined(separator: "/") }

    private func closedKey(matching identity: DocumentFileIdentity) -> UUID? {
        order.first { entries[$0]?.closed?.snapshot.identity.matches(identity) == true }
    }

    private func removeEmptyEntries() {
        for (id, entry) in entries where entry.edits.isEmpty { entries[id] = nil }
        order.removeAll { entries[$0] == nil }
    }

    func propose(callKey: String, document: AIAgentOpenDocument, path: String,
                 oldText: String, newText: String, explanation: String, epoch: Int? = nil, closed: AIAgentClosedFile? = nil) -> Proposal {
        lock.withLock { () -> Proposal in
            if let epoch, epoch != currentEpoch { return .failed(.unreadable, "The run was stopped.") }
            // Закрытый файл узнаётся по идентичности, ключ записи выдаётся при первой правке
            let existing = closed.flatMap { closedKey(matching: $0.snapshot.identity) }
            let id = existing ?? document.id
            if let number = calls[callKey] { return .duplicate(number: number, pendingInDocument: pendingCount(id)) }
            var entry: Entry
            if let closed {
                if let existing, let found = entries[existing], !found.edits.isEmpty {
                    if found.closed?.snapshot != closed.snapshot || found.edits.contains(where: { $0.problem == .fileChanged }) {
                        return .failed(.changedDuringRead, "The file changed on disk after your earlier proposals for it; those proposals are no longer valid. Tell the user and do not retry.")
                    }
                    entry = found
                } else {
                    if entries.values.filter({ $0.closed != nil && !$0.edits.isEmpty }).count >= AIAgentEditLimits.maxClosedFiles {
                        return .failed(.limitReached, "Too many closed files have proposals (\(AIAgentEditLimits.maxClosedFiles)). Stop proposing for new files and summarize.")
                    }
                    entry = Entry(base: document.text, edits: [], text: document.text, closed: closed)
                }
            } else if document.isClosedFile, entries[document.id]?.closed == nil {
                return .failed(.unreadable, "The file could not be read.")
            } else {
                // База существующей записи - её собственная; text снимка уже подменён черновиком
                entry = entries[document.id] ?? Entry(base: document.text, edits: [], text: document.text)
            }
            let found = AIAgentEditEngine.matches(of: oldText, in: entry.text, limit: AIAgentEditLimits.maxCountedMatches)
            if found.isEmpty { return .failed(.noMatch, Self.noMatchMessage) }
            if found.count > 1 {
                return .failed(.ambiguousMatch, "old_text matches \(found.count) places (20 or more if N is 20). Include more surrounding text so it matches exactly once.")
            }
            if entries.values.reduce(0, { $0 + $1.edits.count }) >= AIAgentEditLimits.maxPendingEdits {
                return .failed(.limitReached, "Too many proposed edits are waiting for review (\(AIAgentEditLimits.maxPendingEdits)). Stop proposing and summarize.")
            }
            let edit = AIAgentEdit(
                id: UUID(), number: nextNumber, documentID: id, documentName: document.name, path: path,
                oldText: oldText, newText: newText, explanation: explanation,
                externalReferences: AIAgentEditEngine.externalReferences(old: oldText, new: newText), problem: nil,
                isClosedFile: entry.closed != nil)
            guard case let .success(changed) = AIAgentEditEngine.apply(edit, to: entry.text) else { return .failed(.noMatch, Self.noMatchMessage) }
            nextNumber += 1
            calls[callKey] = edit.number
            entry.edits.append(edit)
            entry.text = changed
            if entries[id] == nil { order.append(id) }
            entries[id] = entry
            return .added(edit, pendingInDocument: pendingCount(id))
        }
    }

    /// Открытые документы с записью показывают текст черновика; isDraft — есть ли ожидающие правки.
    func overlay(on scope: AIAgentScope) -> AIAgentScope {
        lock.withLock { () -> AIAgentScope in
            guard !entries.isEmpty else { return scope }
            var documents = scope.openDocuments.map { document -> AIAgentOpenDocument in
                guard let entry = entries[document.id] else { return document }
                return AIAgentOpenDocument(id: document.id, name: document.name, relativePath: document.relativePath, text: entry.text,
                                           revision: document.revision, isDraft: entry.edits.contains { $0.problem == nil })
            }
            // Закрытые файлы с правками выглядят как документы с черновиком; изменённый на диске файл читается с диска
            let openPaths = Set(scope.openDocuments.compactMap { $0.relativePath.map(Self.normalizedPath) })
            for id in order {
                guard let entry = entries[id], let closed = entry.closed, !openPaths.contains(closed.relativePath),
                      !entry.edits.contains(where: { $0.problem == .fileChanged }), entry.edits.contains(where: { $0.problem == nil }) else { continue }
                documents.append(AIAgentOpenDocument(id: id, name: closed.url.lastPathComponent, relativePath: closed.relativePath, text: entry.text,
                                                     revision: 0, isDraft: true, isClosedFile: true))
            }
            return AIAgentScope(root: scope.root, openDocuments: documents)
        }
    }

    func pending(documentID: UUID) -> [AIAgentEdit] {
        lock.withLock { entries[documentID]?.edits ?? [] }
    }

    var edits: [AIAgentEdit] {
        lock.withLock { order.compactMap { entries[$0]?.edits }.flatMap { $0 } }
    }

    /// Новый снимок: база - текущий текст документа; закрытые документы отбрасываются, а закрытые файлы остаются,
    /// пока их не открыли: тогда правки переезжают в группу документа. Возвращает число отброшенных правок.
    @discardableResult
    func rebase(onto scope: AIAgentScope) -> Int {
        lock.withLock { () -> Int in
            var dropped = 0
            var moved: [UUID] = []
            for id in order {
                guard var entry = entries[id] else { continue }
                if let closed = entry.closed {
                    // Другая рабочая папка: тот же относительный путь здесь был бы уже чужим файлом
                    guard let root = scope.root.map(AIAgentTools.normalizedRoot),
                          closed.url.pathComponents == root.pathComponents + closed.relativePath.split(separator: "/").map(String.init) else {
                        dropped += entry.edits.count
                        entries[id] = nil
                        continue
                    }
                    guard let document = scope.openDocuments.first(where: { $0.relativePath.map(Self.normalizedPath) == closed.relativePath }) else { continue }
                    entries[id] = nil
                    if entries[document.id] != nil { dropped += entry.edits.count; continue }
                    entry.closed = nil
                    entry.base = document.text
                    entry.edits = entry.edits.map { $0.moved(to: document) }
                    Self.rebuild(&entry)
                    entries[document.id] = entry
                    moved.append(document.id)
                } else if let document = scope.openDocuments.first(where: { $0.id == id }) {
                    entry.base = document.text
                    Self.rebuild(&entry)
                    entries[id] = entry
                } else {
                    dropped += entry.edits.count
                    entries[id] = nil
                }
            }
            order.removeAll { entries[$0] == nil }
            order.append(contentsOf: moved)
            removeEmptyEntries()
            calls.removeAll()
            return dropped
        }
    }

    /// Снимок диска каждой закрытой записи; не совпал (или файла нет) - правки помечаются fileChanged. Вызывать вне главного потока.
    func refreshClosedFiles() {
        let files = lock.withLock { order.compactMap { id in entries[id]?.closed.map { (id, $0) } } }
        let changed = files.filter { (try? FileRevisionSnapshot.capture($0.1.url)) != $0.1.snapshot }.map(\.0)
        lock.withLock { for id in changed { markFileChangedLocked(id) } }
    }

    func markFileChanged(_ key: UUID) { lock.withLock { markFileChangedLocked(key) } }

    private func markFileChangedLocked(_ key: UUID) {
        guard var entry = entries[key], entry.closed != nil else { return }
        for index in entry.edits.indices { entry.edits[index].problem = .fileChanged }
        entries[key] = entry
    }

    /// Закрытые файлы, которые можно писать: не изменены на диске и есть хотя бы одна применимая правка.
    func closedPlans() -> [AIAgentClosedPlan] {
        lock.withLock {
            order.compactMap { id in
                guard let entry = entries[id], let closed = entry.closed, !entry.edits.contains(where: { $0.problem == .fileChanged }) else { return nil }
                let applicable = entry.edits.filter { $0.problem == nil }
                return applicable.isEmpty ? nil : AIAgentClosedPlan(key: id, file: closed, name: closed.url.lastPathComponent, edits: applicable)
            }
        }
    }

    /// Убирает правки; применявшиеся раньше и ставшие неприменимыми получают dependsOnRejected.
    func reject(_ ids: Set<UUID>) {
        lock.withLock {
            for id in order {
                guard var entry = entries[id], entry.edits.contains(where: { ids.contains($0.id) }) else { continue }
                let wasApplied = Set(entry.edits.filter { $0.problem == nil }.map(\.id))
                entry.edits.removeAll { ids.contains($0.id) }
                Self.rebuild(&entry)
                for index in entry.edits.indices where entry.edits[index].problem != nil && wasApplied.contains(entry.edits[index].id) {
                    entry.edits[index].problem = .dependsOnRejected
                }
                entries[id] = entry
            }
        }
    }

    /// Принятые правки удаляются, база становится реальным текстом после принятия, остальные пересобираются.
    func settle(documentID: UUID, applied: Set<UUID>, newBase: String) {
        lock.withLock {
            guard var entry = entries[documentID] else { return }
            entry.edits.removeAll { applied.contains($0.id) }
            entry.base = newBase
            Self.rebuild(&entry)
            entries[documentID] = entry
        }
    }

    func removeDocument(_ id: UUID) {
        lock.withLock {
            entries[id] = nil
            order.removeAll { $0 == id }
        }
    }

    func clear() {
        lock.withLock {
            entries = [:]; order = []; calls = [:]; nextNumber = 1
        }
    }
}

struct AIAgentFileApplyOutcome: Equatable, Sendable {
    enum Skip: Equatable, Sendable { case changed, openNow, notExactUTF8, symbolicLink, inaccessible, writeFailed, nothingApplicable }
    enum Status: Equatable, Sendable {
        case written(applied: Int, notApplied: Int)
        case skipped(Skip)
    }
    let status: Status
    /// Версию до или после записи сохранить не удалось; на статус записи это не влияет.
    var versionWarning = false
}

/// Запись принятых правок в закрытый файл рабочей папки (только по кнопке пользователя). Файл читается заново и пишется целиком.
enum AIAgentFileWriter {
    /// Бросает только CancellationError, и только до начала записи.
    static func apply(_ plan: AIAgentClosedPlan, root: URL, openFileURLs: [URL],
                      isCancelled: () -> Bool = { false },
                      recordVersion: (URL) -> Error? = { FileVersionService.recordVersion(of: $0) },
                      write: (String, URL) throws -> Void = { try FileService.writeUTF8($0, to: $1) }) throws -> AIAgentFileApplyOutcome {
        if isCancelled() { throw CancellationError() }
        let url = plan.file.url, expected = plan.file.snapshot
        if openFileURLs.contains(where: { DocumentFileIdentity.resolve($0).matches(expected.identity) }) {
            return AIAgentFileApplyOutcome(status: .skipped(.openNow))
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return AIAgentFileApplyOutcome(status: .skipped(.changed)) }
        let text: String
        do { text = try FolderSearchService.readForReplace(url: url, root: root, expected: expected, isCancelled: isCancelled) }
        catch let failure as FolderSearchService.ReplaceReadFailure {
            switch failure {
            case .changed: return AIAgentFileApplyOutcome(status: .skipped(.changed))
            case .notExactUTF8: return AIAgentFileApplyOutcome(status: .skipped(.notExactUTF8))
            case .symbolicLink: return AIAgentFileApplyOutcome(status: .skipped(.symbolicLink))
            case .inaccessible: return AIAgentFileApplyOutcome(status: .skipped(.inaccessible))
            }
        }
        let result = AIAgentEditEngine.plan(edits: plan.edits, on: text, earlierPending: [])
        if result.applied.isEmpty { return AIAgentFileApplyOutcome(status: .skipped(.nothingApplicable)) }
        if isCancelled() { throw CancellationError() }
        // Версия до записи: на диске ещё старое содержимое
        var warning = recordVersion(url) != nil
        // Версия могла сменить дату файла, поэтому при другой отметке решает содержимое: оно должно остаться прочитанным
        let current = try? FileRevisionSnapshot.capture(url)
        if current != expected {
            guard current?.identity.matches(expected.identity) == true, (try? Data(contentsOf: url)) == Data(text.utf8) else {
                return AIAgentFileApplyOutcome(status: .skipped(.changed), versionWarning: warning)
            }
        }
        guard (try? FolderSearchService.pathIsSafe(url, root: root, isCancelled: { false })) == true else {
            return AIAgentFileApplyOutcome(status: .skipped(.symbolicLink), versionWarning: warning)
        }
        // Запущенную атомарную запись отмена не прерывает; окно подмены между проверкой и записью остаётся
        do { try write(result.text, url) }
        catch { return AIAgentFileApplyOutcome(status: .skipped(.writeFailed), versionWarning: warning) }
        if recordVersion(url) != nil { warning = true }
        return AIAgentFileApplyOutcome(status: .written(applied: result.applied.count, notApplied: result.failed.count), versionWarning: warning)
    }
}

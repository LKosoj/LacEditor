import AppKit
import Foundation

/// Правая панель вкладки хранилища: правка шапки заметки, переходы по тексту, сравнение с версией сервера.
extension AppState {
    /// Одна отменяемая правка шапки (один шаг ⌘Z). nil — выполнено или правка не нужна; строка — сообщение под формой.
    @discardableResult
    func applyVaultFrontmatterEdit(_ edit: VaultFrontmatterEdit, documentID: UUID) -> String? {
        let busy = L10n.tr("文档正忙，请重试")
        guard let document = documents.first(where: { $0.id == documentID }), selectedDocument === document,
              document.language == .markdown, document.vaultPageMode == nil, !document.isReadingMode, !document.isLargeFileMode else {
            return L10n.tr("当前文本无法修改")
        }
        guard document.ioState == .idle, !document.hasPendingLiveEdits else { return busy }
        let extraction = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false, allowsWholeDocument: true,
                                                     requiresEditable: true, includesEditorText: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let current = extraction.result else { return busy }
        let text = extraction.editorText ?? current.text
        let patch: VaultFrontmatterPatch
        do {
            guard let found = try VaultFrontmatterEditor.patch(for: edit, in: text) else { return nil }
            patch = found
        } catch let error as VaultFrontmatterEditError {
            switch error {
            case .duplicate, .notFound: return nil
            case let .parseFailed(line): return L10n.tr("无法读取属性：第 %lld 行", line)
            case .readOnlyField: return L10n.tr("复杂的值请在文本中修改")
            case .invalidValue:
                if case .addListItem = edit { return L10n.tr("标签不能包含空格或 , [ ] #") }
                return L10n.tr("无法修改属性：写入未通过检查")
            case .verificationFailed: return L10n.tr("无法修改属性：写入未通过检查")
            }
        } catch {
            return L10n.tr("无法修改属性：写入未通过检查")
        }
        let request = EditorRangeReplacementRequest(
            documentID: documentID, range: patch.range, originalText: (text as NSString).substring(with: patch.range),
            replacementText: patch.replacement, expectedEditorRevision: current.editorRevision, actionName: L10n.tr("修改属性"))
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        guard request.wasHandled else { return request.failureMessage ?? L10n.tr("当前文本无法修改") }
        return nil
    }

    /// «Показать в тексте» для ошибки шапки и нераспознанного поля: курсор на строку N (с 1), фокус в редактор.
    func revealVaultLine(_ line: Int, documentID: UUID) {
        guard line >= 1, let document = documents.first(where: { $0.id == documentID }) else { return }
        let text = document.synchronizedText() as NSString
        var start = 0
        var current = 1
        while current < line, start < text.length {
            while start < text.length, text.character(at: start) != 10, text.character(at: start) != 13 { start += 1 }
            if start < text.length, text.character(at: start) == 13, start + 1 < text.length, text.character(at: start + 1) == 10 { start += 1 }
            start += 1
            current += 1
        }
        var end = start
        while end < text.length, text.character(at: end) != 10, text.character(at: end) != 13 { end += 1 }
        reveal(NSRange(location: min(start, text.length), length: end - min(start, text.length)), in: document, focusEditor: true)
    }

    /// «Показать в тексте» для ссылки: первое вхождение, фокус в редактор.
    func revealVaultRange(_ range: NSRange, documentID: UUID) {
        guard let document = documents.first(where: { $0.id == documentID }) else { return }
        let length = (document.synchronizedText() as NSString).length
        guard range.location >= 0, NSMaxRange(range) <= length else { return }
        reveal(range, in: document, focusEditor: true)
    }

    /// «Показать изменения сервера»: текущий текст сравнивается с версией сервера, которую держит движок, а если её нет, —
    /// с текстом до последнего обновления сервером (из памяти сессии).
    func showVaultServerChanges(for serverPath: String) {
        guard let session = vaultSession else { return }
        Task { @MainActor [weak self] in
            let held = await session.engine.heldServerText(serverPath: serverPath)
            guard let self else { return }
            let source: TextCompareSource
            if let held {
                source = TextCompareSource(id: "vault-held:\(serverPath)", name: L10n.tr("服务器版本"), isUnsaved: false) { held }
            } else if let entry = self.vaultServerUpdates.entry(for: serverPath) {
                let text = entry.previousText
                source = TextCompareSource(id: "vault-before:\(serverPath)", name: L10n.tr("服务器更新前"), isUnsaved: false) { text }
            } else {
                return
            }
            self.presentTextCompare(initial: source)
        }
    }
}

import AppKit

extension WindowManager {
    /// Правка ссылок в открытом документе: одна замена объемлющего диапазона через редактор и одна группа отмены.
    /// Документ становится выбранным, поэтому окно выходит вперёд; на диск ничего не пишется.
    func applyRenameLinkEdits(_ plan: MarkdownRenameLinkService.FilePlan) async -> FolderReplaceService.Outcome {
        guard case let .open(id, revision, _) = plan.source else { return .skipped(.changed) }
        let edits = plan.edits
        if let document = documentsForAI.first(where: { $0.id == id }), let state = stateContaining(document),
           document.ioState != .idle || state.isOpeningPlaceholder(document) || document.isReadingMode {
            return .skipped(.openDocumentBusy)
        }
        func current() -> (document: EditorDocument, state: AppState, snapshot: DocumentTextSnapshot)? {
            guard let document = documentsForAI.first(where: { $0.id == id }), let state = stateContaining(document),
                  document.fileIdentity != nil, document.ioState == .idle,
                  !state.isOpeningPlaceholder(document), !document.hasPendingLiveEdits,
                  (state.hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return nil }
            let snapshot = document.synchronizedSnapshot()
            let text = snapshot.text as NSString
            guard snapshot.revision == revision, !document.hasPendingLiveEdits,
                  edits.allSatisfy({ $0.range.location >= 0 && NSMaxRange($0.range) <= text.length && text.substring(with: $0.range) == $0.original })
            else { return nil }
            return (document, state, snapshot)
        }
        guard let first = current() else { return .skipped(.changed) }
        let text = first.snapshot.text
        let worker = Task.detached(priority: .userInitiated) { FolderReplaceService.enclosing(edits, in: text) }
        let built = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, let second = current(), second.document === first.document,
              second.snapshot == first.snapshot else { return .skipped(.changed) }
        // Уже в нужном виде: редактор отвергает замену, равную оригиналу.
        guard let enclosing = built else { return .replaced(edits.count) }
        focus(second.document, in: second.state)
        func extract() -> EditorTextSelectionSnapshot? {
            let extraction = EditorTextExtractionRequest(documentID: id, allowsTokenAtCaret: false, allowsWholeDocument: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
            return extraction.result
        }
        // Редактор вновь выбранной вкладки готов не сразу.
        var selection = extract()
        var attempts = 0
        while selection == nil, attempts < 20, !Task.isCancelled {
            attempts += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            selection = extract()
        }
        guard let selection, !Task.isCancelled, let third = current(), third.document === first.document,
              third.state.selectedDocument === third.document, third.snapshot == first.snapshot else { return .skipped(.openInEditorFailed) }
        let apply = EditorRangeReplacementRequest(documentID: id, range: enclosing.range, originalText: enclosing.original,
            replacementText: enclosing.replacement, expectedEditorRevision: selection.editorRevision,
            actionName: L10n.tr("更新链接"))
        apply.groupsUndo = true
        // Курсор в начало заменённого участка, а не выделение всего объемлющего диапазона.
        apply.resultingSelection = NSRange(location: enclosing.range.location, length: 0)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: apply)
        return apply.wasHandled ? .replaced(edits.count) : .skipped(.openInEditorFailed)
    }
}

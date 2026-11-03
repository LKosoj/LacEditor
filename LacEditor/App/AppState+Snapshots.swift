import AppKit

extension AppState {
    /// Снимок можно сделать у документа, у которого есть файл на диске.
    var canMakeSnapshot: Bool {
        guard let document = selectedDocument else { return false }
        return document.url != nil && document.ioState == .idle && !isOpeningPlaceholder(document)
    }

    /// Ключ хранения снимков; nil — у документа нет файла.
    func snapshotLocation(for document: EditorDocument) -> DocumentSnapshotLocation? {
        guard let url = document.url else { return nil }
        if let session = writerSession, let node = session.projectStore.node(forFileURL: url) {
            return .project(root: session.rootURL, nodeID: node.id)
        }
        return .file(path: url.standardizedFileURL.path)
    }

    /// Имя по умолчанию: дата и время на языке интерфейса.
    func defaultSnapshotName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.languageCode)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: now)
    }

    /// ⌃⌘S: спрашивает название и делает снимок выбранного документа.
    func makeSnapshot() {
        guard canMakeSnapshot, let document = selectedDocument else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("为这个快照命名")
        alert.informativeText = L10n.tr("快照会保存当前文本，不会改动文件。")
        alert.addButton(withTitle: L10n.tr("制作快照"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultSnapshotName()
        field.placeholderString = L10n.tr("快照名称")
        field.setAccessibilityLabel(L10n.tr("快照名称"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Пока окно было открыто, документ мог смениться.
        guard selectedDocument === document, canMakeSnapshot else { return }
        makeSnapshot(of: document, name: field.stringValue.isEmpty ? defaultSnapshotName() : field.stringValue)
    }

    /// Без диалога. Текст берётся «как на экране» (даже несохранённый), файл на диске не меняется.
    func makeSnapshot(of document: EditorDocument, name: String,
                      completion: ((Result<DocumentSnapshotInfo, Error>) -> Void)? = nil) {
        guard document.ioState == .idle, !isOpeningPlaceholder(document), let location = snapshotLocation(for: document) else {
            completion?(.failure(DocumentSnapshotError.notFound))
            return
        }
        _ = document.synchronizedText()
        if document.hasUnknownMediaTokens {
            document.statusMessage = L10n.tr("文档含无法识别的媒体标记，请撤销最近的修改")
            completion?(.failure(DocumentSnapshotError.io(L10n.tr("文档含无法识别的媒体标记，请撤销最近的修改"))))
            return
        }
        let text = document.synchronizedSnapshot().text
        let encodingName = document.encodingName
        let limit = preferences.snapshotKeepLimit
        let store = DocumentSnapshotStore.shared
        Task { [weak document] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.add(text: text, name: name, encodingName: encodingName, location: location, keepLast: limit) }
            }.value
            switch result {
            case .success:
                document?.statusMessage = L10n.tr("快照已保存")
                AccessibilityNotification.Announcement(L10n.tr("快照已保存")).post()
            case .failure(let error):
                document?.statusMessage = (error as? DocumentSnapshotError) == .readOnly
                    ? L10n.tr("快照由较新版本创建，无法修改")
                    : L10n.tr("无法保存快照")
            }
            completion?(result)
        }
    }

    /// «Вернуть» из секции инспектора: одна отменяемая правка по ревизии текста; на диск ничего не пишется.
    func restoreSnapshot(_ info: DocumentSnapshotInfo, in document: EditorDocument) {
        guard selectedDocument === document, document.ioState == .idle,
              let location = snapshotLocation(for: document) else { return }
        let base = document.synchronizedSnapshot()
        let store = DocumentSnapshotStore.shared
        Task { [weak self, weak document] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.text(id: info.id, location: location) }
            }.value
            guard let self, let document, self.selectedDocument === document else { return }
            switch result {
            case .failure(let error):
                document.statusMessage = error.localizedDescription
            case .success(let text):
                if let failure = self.applyVersionRestore(text, to: document, base: base, actionName: L10n.tr("恢复快照")) {
                    document.statusMessage = failure
                } else {
                    document.statusMessage = L10n.tr("已恢复快照，尚未保存")
                }
            }
        }
    }
}

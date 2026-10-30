import AppKit

@MainActor
extension AppState {
    /// Ссылки обновляем только для Markdown-файла внутри открытой папки окна; иначе nil.
    func renameLinkScope(from old: URL, to new: URL) -> MarkdownRenameLinkService.Rename? {
        guard let folder = folderWorkspace.rootURL else { return nil }
        let base = folder.standardizedFileURL.pathComponents
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        func isInside(_ url: URL) -> Bool { url.pathComponents.count > base.count && url.pathComponents.starts(with: base) }
        func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
        guard old != new, isInside(old), isInside(new), isMarkdown(old), isMarkdown(new) else { return nil }
        // Обычный файл, и по пути до него нет символических ссылок.
        var current = folder.standardizedFileURL
        for component in old.pathComponents.dropFirst(base.count) {
            current.appendPathComponent(component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
        }
        guard (try? old.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return .init(oldURL: old, newURL: new, root: folder)
    }

    /// Поиск ссылок до переноса. nil: поиск не нужен, пропущен кнопкой «Пропустить» или не удался — перенос идёт без обновления ссылок.
    func prepareMarkdownLinkUpdate(from old: URL, to new: URL) async -> MarkdownRenameLinkService.Plan? {
        guard renameLinkTask == nil, let rename = renameLinkScope(from: old, to: new), let manager = windowManager,
              let documents = manager.folderSearchSnapshots(root: rename.root) else { return nil }
        let identity = DocumentFileIdentity.resolve(rename.oldURL)
        let syntax = preferences.markdownSyntax
        let search = Task.detached(priority: .userInitiated) { () -> MarkdownRenameLinkService.Plan? in
            try? FolderSearchService.renameReferences(rename: rename, identity: identity, syntax: syntax, openDocuments: documents,
                                                      isCancelled: { Task.isCancelled })
        }
        // Отмена этой задачи (кнопка «Пропустить», закрытие окна) останавливает обход.
        renameLinkTask = Task { await withTaskCancellationHandler { _ = await search.value } onCancel: { search.cancel() } }
        let alert = NSAlert()
        alert.messageText = L10n.tr("正在查找指向该文件的链接…")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        alert.accessoryView = spinner
        alert.addButton(withTitle: L10n.tr("跳过"))
        let indicator = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, let window = self.hostWindow else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.renameLinkTask?.cancel() }
            }
        }
        let plan = await search.value
        indicator.cancel()
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
        renameLinkTask = nil
        guard folderWorkspace.rootURL == rename.root else { return nil }
        return plan
    }

    /// Вопрос, запись и отчёт после успешного переноса.
    func completeMarkdownLinkUpdate(_ plan: MarkdownRenameLinkService.Plan?) async {
        guard let plan, folderWorkspace.rootURL == plan.rename.root, let manager = windowManager else { return }
        let (old, new) = (plan.rename.oldURL, plan.rename.newURL)
        // Старый путь может вести на тот же файл, если менялся только регистр имени.
        guard FileManager.default.fileExists(atPath: new.path),
              !FileManager.default.fileExists(atPath: old.path) ||
                DocumentFileIdentity.resolve(old).matches(DocumentFileIdentity.resolve(new)) else { return }
        var notes: [String] = []
        if plan.skipped.total > 0 {
            notes.append(L10n.tr("另有 %d 个链接不会修改：新文件名含有 # | [ ]，存在多个同名文件，或写法不受支持。", plan.skipped.total))
        }
        if !plan.problems.isEmpty {
            notes.append(L10n.tr("有 %d 个文件无法检查，其中的链接不会修改。", plan.problems.count))
        }
        guard plan.linkCount > 0 else {
            guard !notes.isEmpty else { return }
            // Не строка обратной связи: она заменила бы кнопку отмены переноса.
            let note = NSAlert()
            note.messageText = L10n.tr("部分文件未更新")
            note.informativeText = notes.joined(separator: "\n\n")
            note.addButton(withTitle: L10n.tr("确定"))
            note.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("更新 %d 个链接（%d 个文件）？", plan.linkCount, plan.fileCount)
        var details = L10n.tr("文件已重命名。“撤销”重命名不会还原这些链接。已关闭的文件将直接写入磁盘，无法撤销；已打开的文档会作为一次编辑修改，可以撤销。")
        if old.deletingLastPathComponent() != new.deletingLastPathComponent() {
            details += "\n\n" + L10n.tr("该文件自身的相对链接不会修改。")
        }
        alert.informativeText = ([details] + notes).joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.tr("不更新"))
        alert.addButton(withTitle: L10n.tr("更新链接"))
        guard alert.runModal() == .alertSecondButtonReturn, folderWorkspace.rootURL == plan.rename.root else { return }
        // Отмена переноса во время записи вернула бы файл, а ссылки остались бы на новом имени.
        sidebarFeedback.show(L10n.tr("正在更新链接…"), symbol: "info.circle")
        let task = Task { await self.applyMarkdownLinkEdits(plan, manager: manager) }
        renameLinkTask = Task { await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() } }
        let report = await task.value
        renameLinkTask = nil
        guard folderWorkspace.rootURL == plan.rename.root else { return }
        folderWorkspace.refresh()
        if report.isCancelled {
            sidebarFeedback.show(L10n.tr("已取消，已更新 %d 个链接", report.updatedLinks), symbol: "info.circle")
        } else if report.skipped.isEmpty {
            sidebarFeedback.show(L10n.tr("已更新 %d 个链接（%d 个文件）", report.updatedLinks, report.updatedFiles), symbol: "checkmark.circle")
        } else {
            sidebarFeedback.show(L10n.tr("已更新 %d 个链接，%d 个文件未处理", report.updatedLinks, report.skipped.count), symbol: "info.circle")
            let list = NSAlert()
            list.messageText = L10n.tr("部分文件未更新")
            var lines = report.skipped.prefix(10).map { "\($0.file.relativePath) — \(skipText($0.reason))" }
            if report.skipped.count > 10 { lines.append(L10n.tr("……还有 %d 个", report.skipped.count - 10)) }
            list.informativeText = lines.joined(separator: "\n")
            list.addButton(withTitle: L10n.tr("确定"))
            list.runModal()
        }
    }

    /// Сначала открытые документы, затем закрытые файлы по одному в фоне; отмена действует между файлами.
    private func applyMarkdownLinkEdits(_ plan: MarkdownRenameLinkService.Plan, manager: WindowManager) async -> MarkdownRenameLinkService.Report {
        let root = plan.rename.root
        var report = MarkdownRenameLinkService.Report()
        func record(_ file: MarkdownRenameLinkService.FilePlan, _ outcome: FolderReplaceService.Outcome) {
            switch outcome {
            case let .replaced(count): report.updatedLinks += count; report.updatedFiles += 1
            case let .skipped(reason): report.skipped.append(.init(file: file.file, reason: reason))
            }
        }
        for file in plan.files where file.isOpen {
            if Task.isCancelled { report.isCancelled = true; break }
            let outcome = await manager.applyRenameLinkEdits(file)
            // Пропуск из-за отмены — не «файл изменился».
            if Task.isCancelled, case .skipped = outcome { report.isCancelled = true; break }
            record(file, outcome)
        }
        for file in plan.files where !file.isOpen {
            if Task.isCancelled { report.isCancelled = true; break }
            // Файл мог открыться в окне, пока шёл диалог: под открытым документом на диск не пишем.
            guard folderWorkspace.rootURL == root, let documents = manager.folderSearchSnapshots(root: root),
                  !documents.contains(where: { $0.url.standardizedFileURL == file.file.url.standardizedFileURL ||
                      $0.identity.matches(DocumentFileIdentity.resolve(file.file.url)) }) else {
                record(file, .skipped(.changed)); continue
            }
            let worker = Task.detached(priority: .userInitiated) { () throws -> FolderReplaceService.Outcome in
                try MarkdownRenameLinkService.applyOnDisk(file, root: root, isCancelled: { Task.isCancelled })
            }
            do {
                record(file, try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }))
            } catch { report.isCancelled = true; break }
        }
        return report
    }

    private func skipText(_ reason: FolderReplaceService.SkipReason) -> String {
        switch reason {
        case .changed: L10n.tr("文件已变化")
        case .notExactUTF8: L10n.tr("不是精确的 UTF-8（含 BOM 等）")
        case .inaccessible: L10n.tr("无法读取")
        case .symbolicLink: L10n.tr("已跳过符号链接")
        case .writeFailed: L10n.tr("无法写入")
        case .openDocumentBusy, .openInEditorFailed: L10n.tr("无法修改已打开的文档")
        }
    }
}

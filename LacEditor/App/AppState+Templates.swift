import AppKit

extension AppState {
    private enum TemplateNoteFailure: Error {
        case read(Error), create(Error)
    }

    func newNoteFromTemplate() {
        guard let manager = windowManager, let window = hostWindow,
              manager.ownsVisibleState(self, window: window) else { return }
        guard let root = folderWorkspace.rootURL else { presentNoWorkspaceAlert(); return }
        let templatesPath = preferences.templatesFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templatesPath.isEmpty else { presentTemplatesFolderNotSetAlert(); return }
        let folder = URL(fileURLWithPath: templatesPath, isDirectory: true)
        let service = fileService
        templateTask?.cancel()
        templateTask = Task { [weak self] in
            let listing = await Task.detached { Result { try NoteTemplateService.listTemplates(in: folder) } }.value
            guard let self, !Task.isCancelled, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            let templates: [URL]
            switch listing {
            case let .failure(error): self.presentError(title: L10n.tr("无法读取模板文件夹"), error: error); return
            case let .success(urls): templates = urls
            }
            guard !templates.isEmpty else {
                let alert = NSAlert()
                alert.messageText = L10n.tr("模板文件夹中没有 Markdown 模板")
                alert.addButton(withTitle: L10n.tr("取消"))
                alert.runModal()
                return
            }
            let alert = NSAlert()
            alert.messageText = L10n.tr("从模板新建笔记")
            alert.addButton(withTitle: L10n.tr("创建"))
            alert.addButton(withTitle: L10n.tr("取消"))
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            let baseNames = templates.map { $0.deletingPathExtension().lastPathComponent }
            for url in templates {
                let base = url.deletingPathExtension().lastPathComponent
                let item = NSMenuItem(title: baseNames.filter { $0 == base }.count > 1 ? url.lastPathComponent : base,
                                      action: nil, keyEquivalent: "")
                item.representedObject = url
                popup.menu?.addItem(item)
            }
            popup.setAccessibilityLabel(L10n.tr("模板"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = L10n.tr("笔记名称")
            let stack = NSStackView(views: [popup, field])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 58)
            alert.accessoryView = stack
            guard alert.runModal() == .alertFirstButtonReturn, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            guard let template = popup.selectedItem?.representedObject as? URL else { return }
            let name = NoteTemplateService.normalizedFileName(field.stringValue)
            let directory = self.folderWorkspace.currentDirectory ?? root
            let title = (name as NSString).deletingPathExtension
            let creation = await Task.detached { () -> Result<URL, TemplateNoteFailure> in
                let text: String
                do { text = try NoteTemplateService.readTemplate(template) }
                catch { return .failure(.read(error)) }
                let contents = NoteTemplateService.render(text, title: title, date: Date())
                do { return .success(try service.createWorkspaceTextFile(named: name, contents: contents, in: directory, root: root)) }
                catch { return .failure(.create(error)) }
            }.value
            guard !Task.isCancelled, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            switch creation {
            case let .failure(.read(error)): self.presentError(title: L10n.tr("无法读取模板"), error: error)
            case let .failure(.create(error)): self.presentError(title: L10n.tr("无法创建文件"), error: error)
            case let .success(url):
                self.folderWorkspace.refresh()
                self.openFile(url)
            }
        }
    }

    func openDailyNote() {
        guard let manager = windowManager, let window = hostWindow,
              manager.ownsVisibleState(self, window: window) else { return }
        guard let root = folderWorkspace.rootURL else { presentNoWorkspaceAlert(); return }
        let subfolder = preferences.dailyNotesFolder
        let templatesFolder = preferences.templatesFolderPath
        let format = preferences.dailyNoteDateFormat
        let service = fileService
        templateTask?.cancel()
        templateTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<URL, Error> in
                Result {
                    let plan = try NoteTemplateService.dailyNotePlan(
                        root: root, subfolder: subfolder, templatesFolder: templatesFolder, date: Date(), format: format,
                        validateDirectory: { try service.validateWorkspaceDirectory($0, root: root) })
                    switch plan {
                    case let .open(url): return url
                    case let .create(url, contents):
                        do {
                            return try service.createWorkspaceTextFile(
                                named: url.lastPathComponent, contents: contents, in: url.deletingLastPathComponent(), root: root)
                        } catch let error as CocoaError where error.code == .fileWriteFileExists {
                            try NoteTemplateService.requireRegularFile(url)
                            return url
                        }
                    }
                }
            }.value
            guard let self, !Task.isCancelled, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            switch result {
            case let .failure(error): self.presentError(title: L10n.tr("每日笔记"), error: error)
            case let .success(url):
                self.folderWorkspace.refresh()
                self.openFile(url)
            }
        }
    }

    private func presentNoWorkspaceAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("需要先打开工作文件夹")
        alert.informativeText = L10n.tr("笔记会创建在工作文件夹中。")
        alert.addButton(withTitle: L10n.tr("打开文件夹…"))
        alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn { openFolder() }
    }

    private func presentTemplatesFolderNotSetAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("未设置模板文件夹")
        alert.informativeText = L10n.tr("在“设置 > 文件”中选择模板文件夹。")
        alert.addButton(withTitle: L10n.tr("打开设置…"))
        alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn, let windowManager {
            SettingsWindowController.shared.present(windowManager: windowManager)
        }
    }
}

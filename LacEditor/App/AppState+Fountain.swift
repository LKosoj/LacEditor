import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Экспорт в Fountain: лист, сбор источников, запись файла и открытие результата в новой вкладке.
@MainActor
extension AppState {
    func presentFountainExport(scope: FountainExportController.Scope) {
        guard fountainSheet == nil, let window = hostWindow, let manager = windowManager, manager.activeState === self,
              window.attachedSheet == nil, manager.ownsVisibleState(self, window: window) else { return }
        var documentName = L10n.tr("未命名")
        switch scope {
        case .document:
            guard let document = selectedDocument, document.language == .markdown else { return }
            if rejectFountainMediaTokens(document) { return }
            documentName = document.url?.deletingPathExtension().lastPathComponent ?? documentName
        case .project:
            guard let session = writerSession else { return }
            documentName = session.projectStore.project?.title ?? session.rootURL.lastPathComponent
        }
        let controller = FountainExportController(
            scope: scope,
            aiAvailability: { [weak self] in self?.aiAvailability(for: .fountainAdaptation) ?? .aiDisabled },
            sources: { [weak self] in await self?.fountainSources(scope: scope) ?? FountainSources(title: "", parts: [], syntax: MarkdownSyntaxOptions()) },
            generate: { [weak self] input, instructions in
                guard let self else { throw CancellationError() }
                let profile = self.preferences.aiProfile(for: .fountainAdaptation)
                let key = try AIKeychainStore().load(for: .text, baseURL: profile.baseURL)
                return try await AIClient().generateText(input: input, instructions: instructions, profile: profile, key: key)
            },
            onFinished: { [weak self] text, warnings, saveToFile in
                self?.finishFountain(text: text, warnings: warnings, saveToFile: saveToFile, baseName: documentName)
            }
        )
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: FountainExportView(
            controller: controller,
            close: { [weak self] in self?.closeFountainExport() }
        ).environmentObject(self).environmentObject(manager)))
        sheet.styleMask.remove(.closable)
        fountainStorage = controller
        fountainSheet = sheet
        window.beginSheet(sheet)
    }

    func closeFountainExport() {
        fountainStorage?.windowClosed()
        fountainStorage = nil
        guard let sheet = fountainSheet else { return }
        fountainSheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Запись, печать и экспорт с токеном media без записи в таблице испортили бы файл. Возвращает true, если операцию надо прервать.
    private func rejectFountainMediaTokens(_ document: EditorDocument) -> Bool {
        _ = document.synchronizedText()
        guard document.hasUnknownMediaTokens else { return false }
        presentError(title: L10n.tr("无法导出"), error: NSError(
            domain: "LacEditor.MediaTokens", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L10n.tr("文档含无法识别的媒体标记，请撤销最近的修改")]
        ))
        return true
    }

    // MARK: Источники

    private func fountainSources(scope: FountainExportController.Scope) async -> FountainSources {
        let syntax = preferences.markdownSyntax
        switch scope {
        case .document:
            let text = selectedDocument?.synchronizedText() ?? ""
            return FountainSources(title: "", parts: [FountainExportService.Part(title: "", text: text, level: 0, synopsis: nil)],
                                   frontMatterText: text, syntax: syntax)
        case .project:
            guard let session = writerSession, let manager = windowManager else {
                return FountainSources(title: "", parts: [], syntax: syntax)
            }
            let store = session.projectStore
            let root = store.rootURL
            let title = store.project?.title ?? root.lastPathComponent
            let nodes = store.project?.nodes ?? []
            let files = store.orderedTextNodes(includedOnly: true).compactMap { node -> FolderSearchService.File? in
                guard let path = node.path, let url = store.fileURL(for: node),
                      ManuscriptProjectFiles.compileExtensions.contains((path as NSString).pathExtension.lowercased()),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return FolderSearchService.File(url: url, relativePath: path)
            }
            guard let documents = manager.folderSearchSnapshots(root: root) else {
                return FountainSources(title: title, parts: [], syntax: syntax)
            }
            let sources = await Task.detached(priority: .userInitiated) {
                try? FolderSearchService.manuscriptSources(root: root, files: files, openDocuments: documents, markdownOnly: false)
            }.value
            var texts: [String: String] = [:]
            for source in sources?.values ?? [] { texts[source.file.relativePath] = source.text }
            let built = FountainExportService.parts(from: nodes, texts: texts)
            var skipped = built.missing
            for problem in sources?.problems ?? [] {
                skipped.append(FolderSearchService.relativePath(problem.url, root: root) ?? problem.url.lastPathComponent)
            }
            var warnings: [FountainExportService.Warning] = []
            if !skipped.isEmpty {
                warnings.append(.init(kind: .skippedFile, count: skipped.count, detail: skipped.joined(separator: ", ")))
            }
            return FountainSources(title: title, parts: built.parts, frontMatterText: built.parts.first { !$0.text.isEmpty }?.text,
                                   syntax: syntax, warnings: warnings)
        }
    }

    // MARK: Результат

    private func finishFountain(text: String, warnings: [FountainExportService.Warning], saveToFile: Bool, baseName: String) {
        guard fountainSheet != nil else { return }
        if saveToFile {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = baseName + ".fountain"
            if let type = UTType(filenameExtension: "fountain") { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let openURLs = windowManager?.openDocumentURLs ?? documents.compactMap(\.url)
            guard !PandocExportService.conflicts(destination: destination, source: selectedDocument?.url, openURLs: openURLs) else {
                presentError(title: L10n.tr("无法导出"), error: PandocExportError.openDocument)
                return
            }
            let data = Data(text.utf8)
            Task { [weak self] in
                let outcome = await Task.detached(priority: .userInitiated) { () -> Error? in
                    do { try data.write(to: destination, options: .atomic); return nil } catch { return error }
                }.value
                guard let self, self.fountainSheet != nil else { return }
                if let outcome {
                    self.presentError(title: L10n.tr("无法导出"), error: outcome)
                    return
                }
                self.closeFountainExport()
                self.selectedDocument?.statusMessage = L10n.tr("导出完成")
                self.showFountainWarnings(warnings)
            }
            return
        }
        closeFountainExport()
        let document = EditorDocument(text: text, language: .plainText, isDirty: true, requiresExplicitSave: true)
        windowManager?.openNativeTab(from: self, with: document, inheritsWriter: writerSession != nil)
        showFountainWarnings(warnings)
    }

    private func showFountainWarnings(_ warnings: [FountainExportService.Warning]) {
        var lines: [String] = []
        for warning in warnings {
            let line: String
            switch warning.kind {
            case .table: line = L10n.tr("%d 个表格已转为文字行", warning.count)
            case .image: line = L10n.tr("%d 张图片已转为注释", warning.count)
            case .formula: line = L10n.tr("%d 个公式已按文字保留", warning.count)
            case .codeBlock: line = L10n.tr("%d 个代码块已缩进保留", warning.count)
            case .html: line = L10n.tr("%d 处 HTML 只保留了文字", warning.count)
            case .footnote: line = L10n.tr("%d 个脚注已转为注释", warning.count)
            case .strikethrough: line = L10n.tr("%d 处删除线已去除", warning.count)
            case .frontMatterUnreadable: line = L10n.tr("文档开头的 YAML 无法读取，未生成标题页")
            case .unclosedNote, .unclosedBoneyard: line = L10n.tr("有未闭合的注释或块注释，请检查")
            case .skippedFile: line = L10n.tr("未导出的文件：") + (warning.detail ?? "")
            case .aiFallback: line = L10n.tr("第 %d 个场景的 AI 结果未通过检查，已改用结构转换。", Int(warning.detail ?? "") ?? warning.count)
            }
            if !lines.contains(line) { lines.append(line) }
        }
        guard !lines.isEmpty else { return }
        let limit = 8
        var shown = Array(lines.prefix(limit))
        if lines.count > limit { shown.append(L10n.tr("……还有 %d 个", lines.count - limit)) }
        let alert = NSAlert()
        alert.messageText = L10n.tr("转换完成，但有需要注意的地方")
        alert.informativeText = shown.joined(separator: "\n")
        alert.runModal()
    }
}

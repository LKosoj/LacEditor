import AppKit
import SwiftUI

@MainActor
extension AppState {
    var manuscript: ManuscriptController {
        if let manuscriptStorage { return manuscriptStorage }
        let controller = ManuscriptController(snapshots: { [weak self] in
            guard let self, let root = self.folderWorkspace.rootURL, let manager = self.windowManager else { return nil }
            return manager.folderSearchSnapshots(root: root)
        }, syntax: { [weak self] in
            self?.preferences.markdownSyntax ?? MarkdownSyntaxOptions()
        }, onBuilt: { [weak self] output in
            self?.finishManuscript(output)
        })
        manuscriptStorage = controller
        return controller
    }

    func presentManuscript() {
        guard manuscriptSheet == nil, let root = folderWorkspace.rootURL,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        let controller = manuscript
        controller.attach(root: root)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ManuscriptView(
            controller: controller,
            folderName: root.lastPathComponent,
            close: { [weak self] in self?.closeManuscript() }
        )))
        sheet.styleMask.remove(.closable)
        manuscriptSheet = sheet
        window.beginSheet(sheet)
    }

    func closeManuscript() {
        manuscriptStorage?.cancel()
        guard let sheet = manuscriptSheet else { return }
        manuscriptSheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Результат применяется, только если лист жив, окно и корень прежние; исходные файлы и документы не меняются.
    private func finishManuscript(_ output: ManuscriptService.Output) {
        guard manuscriptSheet != nil, let window = hostWindow, let manager = windowManager,
              manager.ownsVisibleState(self, window: window),
              folderWorkspace.rootURL == manuscriptStorage?.root else { return }
        let document = EditorDocument(text: output.text, language: .markdown, isDirty: true, requiresExplicitSave: true)
        document.statusMessage = L10n.tr("已合并 %d 个文件", output.report.mergedFiles)
        closeManuscript()
        manager.openNativeTab(from: self, with: document)
        if output.report.hasNotes { showManuscriptNotes(output.report) }
    }

    private func showManuscriptNotes(_ report: ManuscriptService.Report) {
        var parts: [String] = []
        if !report.skipped.isEmpty {
            var lines = [L10n.tr("未合并的文件：")]
            let prefix = (manuscriptStorage?.root?.standardizedFileURL.path ?? "") + "/"
            lines += report.skipped.prefix(10).map { problem in
                let path = problem.url.standardizedFileURL.path
                return "\(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : problem.url.lastPathComponent) — \(manuscriptReason(problem.reason))"
            }
            if report.skipped.count > 10 { lines.append(L10n.tr("……还有 %d 个", report.skipped.count - 10)) }
            parts.append(lines.joined(separator: "\n"))
        }
        if report.unconvertedAddresses > 0 {
            parts.append(L10n.tr("%d 个相对地址未转换（引用式写法、HTML 或无法确认的写法）。", report.unconvertedAddresses))
        }
        if !report.filesWithoutImageCheck.isEmpty {
            parts.append(L10n.tr("无法确认图片写法的文件：%@", report.filesWithoutImageCheck.prefix(10).joined(separator: ", ")))
        }
        if !report.duplicateFootnoteLabels.isEmpty {
            parts.append(L10n.tr("脚注标签重复：%@。文本未改写，请在合并后的文稿中手动改名。",
                                 report.duplicateFootnoteLabels.joined(separator: ", ")))
        }
        if report.blockedByRootURL { parts.append(L10n.tr("第一个文件的元数据设置了 typora-root-url，相对地址未转换。")) }
        let alert = NSAlert()
        alert.messageText = L10n.tr("合并完成，但有需要注意的地方")
        alert.informativeText = parts.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.tr("关闭"))
        alert.runModal()
    }

    private func manuscriptReason(_ reason: FolderSearchService.ProblemReason) -> String {
        switch reason {
        case .inaccessible: L10n.tr("无法读取")
        case .symbolicLink: L10n.tr("已跳过符号链接")
        case .invalidUTF8: L10n.tr("不是有效的 UTF-8")
        case .invalidTags: L10n.tr("无法读取 YAML 标签")
        case .changed: L10n.tr("文件已变化")
        case .conflictingOpenDocuments: L10n.tr("打开的文档冲突")
        }
    }
}

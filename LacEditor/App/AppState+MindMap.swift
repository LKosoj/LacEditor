import AppKit
import SwiftUI

/// Результат правки текста из карты.
enum MindMapEditResult {
    case applied(MindMapTextEdit)
    case failed(String)
}

/// Окно карты следит за темой. Вкладку-открыватель не держит: действия идут через слабую ссылку контроллера.
private struct MindMapWindowRoot: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var controller: MindMapController

    private var scheme: ColorScheme {
        switch preferences.theme {
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some View {
        Group {
            if let state = controller.appState, let manager = controller.windowManager {
                MindMapView(controller: controller).environmentObject(state).environmentObject(manager)
            }
        }
        .preferredColorScheme(scheme)
    }
}

/// Ментальная карта: окно рядом с текстом, по одному на вкладку.
@MainActor
extension AppState {
    /// Почему карту такого вида сейчас нельзя открыть; nil — можно.
    func mindMapUnavailableReason(for kind: MindMapKind) -> String? {
        switch kind {
        case .document:
            guard let document = selectedDocument else { return L10n.tr("导图仅适用于 Markdown 文档") }
            return MindMapController.unavailableReason(of: document)
        case .project, .links:
            return writerSession == nil ? L10n.tr("当前书稿还没有内容。") : nil
        }
    }

    func presentMindMap(kind: MindMapKind) {
        guard let manager = windowManager, mindMapUnavailableReason(for: kind) == nil else { return }
        if let existing = mindMapWindowController, let controller = mindMapController {
            controller.setKind(kind)
            existing.show()
            return
        }
        let controller = MindMapController(appState: self, windowManager: manager, kind: kind)
        let root = MindMapWindowRoot(preferences: preferences, controller: controller)
        let window = WriterAuxiliaryWindowController(
            kind: .mindMap, title: L10n.tr("导图 - %@", controller.windowSubject),
            content: NSHostingView(rootView: root), autosaveName: "LacEditor.MindMap")
        let nsWindow = window.window
        controller.titleChanged = { [weak nsWindow] subject in nsWindow?.title = L10n.tr("导图 - %@", subject) }
        window.onBecomeKey = { [weak controller] in
            guard let controller else { return }
            controller.refresh()
            MindMapZoomRouter.activate(owner: controller) { [weak controller] action in controller?.zoom(action) }
        }
        window.onResignKey = { [weak controller] in
            guard let controller else { return }
            MindMapZoomRouter.deactivate(owner: controller)
        }
        window.onClose = { [weak self, weak controller, weak session = writerSession] in
            if let controller {
                MindMapZoomRouter.deactivate(owner: controller)
                controller.stop()
            }
            self?.mindMapController = nil
            self?.mindMapWindowController = nil
            session?.unregisterAuxiliaryWindow(nsWindow)
        }
        mindMapController = controller
        mindMapWindowController = window
        writerSession?.registerAuxiliaryWindow(nsWindow)
        window.show()
    }

    func closeMindMapWindow() {
        mindMapController?.stop()
        mindMapWindowController?.window.close()
        mindMapController = nil
        mindMapWindowController = nil
    }

    /// Правка документа из карты: один шаг отмены. `build` получает текст редактора и возвращает замену в его координатах.
    func applyMindMapEdit(documentID: UUID, expectedTextRevision: UInt, actionName: String,
                          build: (String) -> MindMapTextEdit?) -> MindMapEditResult {
        guard let document = documents.first(where: { $0.id == documentID }), selectedDocument === document,
              document.language == .markdown else { return .failed(L10n.tr("此文档不可编辑")) }
        if document.isReadingMode { return .failed(L10n.tr("阅读模式下无法修改")) }
        guard document.ioState == .idle else { return .failed(L10n.tr("此文档不可编辑")) }
        guard !document.hasPendingLiveEdits, document.textRevision == expectedTextRevision else {
            return .failed(L10n.tr("文本已变化"))
        }
        let extraction = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false, allowsWholeDocument: true,
                                                     requiresEditable: true, includesEditorText: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let current = extraction.result else { return .failed(L10n.tr("当前文本无法修改")) }
        let text = extraction.editorText ?? current.text
        guard let edit = build(text), edit.range.location >= 0, NSMaxRange(edit.range) <= (text as NSString).length else {
            return .failed(L10n.tr("当前文本无法修改"))
        }
        let request = EditorRangeReplacementRequest(
            documentID: documentID,
            range: edit.range,
            originalText: (text as NSString).substring(with: edit.range),
            replacementText: edit.replacement,
            expectedEditorRevision: current.editorRevision,
            actionName: actionName)
        request.groupsUndo = true
        request.resultingSelection = edit.selection
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        guard request.wasHandled else { return .failed(request.failureMessage ?? L10n.tr("当前文本无法修改")) }
        return .applied(edit)
    }
}

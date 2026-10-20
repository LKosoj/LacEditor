import AppKit
import SwiftUI

enum TextTransformationWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier(
        "LacEditor.TextTransformationWindow"
    )
}

struct TextTransformationPreview: Equatable {
    let documentID: UUID
    let range: NSRange
    let input: String
    let output: String
    let editorRevision: UInt
    let operation: TextTransformationOperation
    let detectedKind: TextCodecKind?

    var title: String { operation.title }
}

@MainActor
final class TextTransformationPreviewState: ObservableObject {
    @Published private(set) var preview: TextTransformationPreview?
    @Published var message: String?
    @Published private(set) var canReplace = false

    func present(_ preview: TextTransformationPreview) {
        self.preview = preview
        message = nil
        canReplace = preview.input != preview.output
    }

    func invalidate(documentID: UUID) {
        guard preview?.documentID == documentID else { return }
        canReplace = false
        message = "编辑内容已变化，请重新执行转换"
    }

    func clear() {
        preview = nil
        message = nil
        canReplace = false
    }
}

struct TextTransformationView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: TextTransformationPreviewState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let preview = state.preview {
                UtilityHeading(title: preview.title, subtitle: "先预览，再决定是否替换正文。", symbol: "arrow.left.arrow.right")
                HSplitView {
                    previewPane(title: "原文", text: preview.input, result: false).frame(minWidth: 260)
                    previewPane(title: "转换结果", text: preview.output, result: true).frame(minWidth: 260)
                }
                HStack(spacing: 10) {
                    Text(state.message ?? "正文保持不变，直到你点击「替换原文」。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).help(state.message ?? "")
                    Spacer(minLength: 12)
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                    Button("复制结果") { appState.copyTextTransformationResult() }
                    Button("替换原文") { appState.applyTextTransformationPreview() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!state.canReplace)
                }.controlSize(.regular)
            } else {
                ContentUnavailableView("没有转换结果", systemImage: "text.badge.xmark")
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 420)
        .background(LacEditorDesign.canvas)
    }

    private func previewPane(title: String, text: String, result: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: result ? "text.badge.checkmark" : "text.alignleft")
                    .foregroundStyle(result ? LacEditorDesign.accent : .secondary)
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\((text as NSString).length) 字符").foregroundStyle(.tertiary).monospacedDigit()
            }.font(.system(size: 11)).padding(12)
            Divider().opacity(0.5)
            ScrollView(.vertical) {
                Text(previewText(text))
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true).padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NativeScrollViewConfigurator())
        }
        .background(LacEditorDesign.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LacEditorDesign.outline, lineWidth: 0.5))
        .padding(.horizontal, 4)
    }

    private func previewText(_ text: String) -> String {
        let limit = 20_000
        let prefix = text.prefix(limit + 1)
        guard prefix.count > limit else { return text }
        return String(prefix.prefix(limit)) + "\n\n…预览已截断，替换仍会使用完整结果"
    }
}

@MainActor
final class TextTransformationWindowController: NSWindowController, NSWindowDelegate {
    private weak var state: TextTransformationPreviewState?

    init(appState: AppState) {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        state = appState.textTransformation
        panel.title = "编码与解码"
        panel.identifier = TextTransformationWindowIdentity.identifier
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .documentWindow
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.contentMinSize = NSSize(width: 640, height: 420)
        panel.tabbingMode = .disallowed
        panel.delegate = self
        let content = TextTransformationView(state: appState.textTransformation,
                                             close: { [weak panel] in panel?.performClose(nil) })
        panel.contentViewController = NSHostingController(
            rootView: UtilityWindowRoot(appState: appState) { content }
        )
    }

    required init?(coder: NSCoder) { nil }

    func present(relativeTo parentWindow: NSWindow) {
        guard let panel = window else { return }
        if !panel.isVisible {
            position(panel, over: parentWindow)
        }
        showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
        state?.clear()
    }

    func dispose() {
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        state?.clear()
        state = nil
    }

    func windowWillClose(_ notification: Notification) {
        state?.clear()
    }

    private func position(_ panel: NSWindow, over parent: NSWindow) {
        var origin = NSPoint(
            x: parent.frame.midX - panel.frame.width / 2,
            y: parent.frame.midY - panel.frame.height / 2
        )
        if let visible = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }
}

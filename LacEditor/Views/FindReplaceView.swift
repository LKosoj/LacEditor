import AppKit
import SwiftUI

enum FindReplaceWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier("LacEditor.FindReplaceWindow")
}

struct FindReplaceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var state: FindReplaceState
    @FocusState private var focusedField: Field?
    private let close: () -> Void
    @State private var showsEscapeHelp = false
    @State private var escapeHelpTask: Task<Void, Never>?
    private enum Field { case query, replacement }

    init(state: FindReplaceState, close: @escaping () -> Void) {
        _state = ObservedObject(wrappedValue: state)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            UtilityHeading(title: "查找与替换",
                           subtitle: appState.selectedDocument.map { "当前文档：\($0.displayName)" } ?? "在当前文档中查找",
                           symbol: "text.magnifyingglass")
            VStack(spacing: 16) {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("查找").font(.system(size: 12, weight: .medium))
                        TextField("输入要查找的内容", text: $state.query)
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .focused($focusedField, equals: .query)
                            .onKeyPress(keys: [.return], phases: .down) { press in
                                guard !actionsDisabled else { return .handled }
                                if press.modifiers.contains(.shift) { appState.findPrevious() }
                                else { appState.findNext() }
                                return .handled
                            }
                    }
                    GridRow {
                        Text("替换为").font(.system(size: 12, weight: .medium))
                        TextField("输入替换内容，留空表示删除", text: $state.replacement)
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .focused($focusedField, equals: .replacement)
                    }
                }
                HStack(spacing: 4) {
                    Toggle("解释转义字符", isOn: $state.interpretsEscapes)
                    escapeInfo
                    Spacer()
                    Toggle("区分大小写", isOn: $state.isCaseSensitive)
                }
                .font(.system(size: 12)).toggleStyle(.checkbox).zIndex(1)
            }
            .padding(18)
            .background(LacEditorDesign.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LacEditorDesign.outline, lineWidth: 0.5))
            .zIndex(1)

            HStack(spacing: 8) {
                if state.isWorking {
                    ProgressView().controlSize(.small)
                    Text(state.message ?? "正在查找…")
                    Button("取消任务") { appState.cancelFindReplaceTask() }.buttonStyle(.borderless)
                } else {
                    if state.message?.hasPrefix("已替换") == true {
                        Image(systemName: "checkmark.circle").accessibilityHidden(true)
                    }
                    Text(state.message ?? "输入关键词，按回车查找下一处")
                        .lineLimit(1).help(state.message ?? "")
                        .accessibilityIdentifier("find.result.message")
                }
                Spacer(minLength: 0)
                if !state.isWorking { Text("⇧↩ 上一个").foregroundStyle(.tertiary) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 20)

            HStack(spacing: 10) {
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Spacer(minLength: 10)
                Button { appState.findPrevious() } label: { Label("上一个", systemImage: "chevron.up") }
                    .disabled(actionsDisabled).help("查找上一处（⇧⌘G）")
                Button { appState.findNext() } label: { Label("下一个", systemImage: "chevron.down") }
                    .keyboardShortcut(.defaultAction).disabled(actionsDisabled).help("查找下一处（⌘G）")
                Button("替换") { appState.replaceCurrentMatch() }.disabled(actionsDisabled)
                Button("全部替换") { appState.replaceAllMatches() }
                    .buttonStyle(.borderedProminent).disabled(actionsDisabled)
            }.controlSize(.regular)
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 350)
        .background(LacEditorDesign.canvas)
        .onAppear { focusRequestedField() }
        .onChange(of: state.focusRequestID) { focusRequestedField() }
        .onDisappear {
            escapeHelpTask?.cancel()
            showsEscapeHelp = false
        }
        .onChange(of: state.query) { appState.cancelFindReplaceTask() }
        .onChange(of: state.replacement) { appState.cancelFindReplaceTask() }
        .onChange(of: state.isCaseSensitive) { appState.cancelFindReplaceTask() }
        .onChange(of: state.interpretsEscapes) { appState.cancelFindReplaceTask() }
    }

    private var escapeInfo: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(width: 24, height: 24).contentShape(Rectangle())
            .onHover { inside in
                escapeHelpTask?.cancel()
                if inside {
                    escapeHelpTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        showsEscapeHelp = true
                    }
                } else { showsEscapeHelp = false }
            }
            .accessibilityLabel("转义字符说明").accessibilityHint(escapeHelp)
            .overlay(alignment: .topLeading) {
                if showsEscapeHelp {
                    Text(escapeHelp).font(.system(size: 12)).padding(12)
                        .frame(width: 310, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LacEditorDesign.outline, lineWidth: 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 28).allowsHitTesting(false)
                }
            }
    }
    private var actionsDisabled: Bool { state.query.isEmpty || state.isWorking }
    private var escapeHelp: String {
        #"可用转义字符：\n 换行，\r 回车，\t 制表符，\s 空格，\0 空字符，\\ 反斜杠。查找与替换内容均适用。"#
    }
    private func focusRequestedField() {
        DispatchQueue.main.async { focusedField = state.mode == .replace ? .replacement : .query }
    }
}

@MainActor
final class FindReplaceWindowController: NSWindowController, NSWindowDelegate {
    private weak var state: FindReplaceState?
    private weak var appState: AppState?
    private var hasPositionedWindow = false

    init(appState: AppState) {
        let findWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 350),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: findWindow)
        state = appState.findReplace
        self.appState = appState

        findWindow.identifier = FindReplaceWindowIdentity.identifier
        findWindow.title = "查找与替换"
        findWindow.isReleasedWhenClosed = false
        findWindow.tabbingMode = .disallowed
        findWindow.contentMinSize = NSSize(width: 620, height: 350)
        findWindow.animationBehavior = .documentWindow
        findWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        findWindow.delegate = self

        let content = FindReplaceView(state: appState.findReplace, close: { [weak self] in
            self?.window?.performClose(nil)
        })
        findWindow.contentViewController = NSHostingController(
            rootView: UtilityWindowRoot(appState: appState) { content }
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(mode: FindReplaceMode, relativeTo parentWindow: NSWindow) {
        guard let findWindow = window else { return }

        state?.mode = mode
        if !hasPositionedWindow {
            position(over: parentWindow)
            hasPositionedWindow = true
        }
        showWindow(nil)
        findWindow.makeKeyAndOrderFront(nil)
        state?.focusRequestID = UUID()
    }

    func dismiss() {
        appState?.cancelFindReplaceTask()
        state?.isWorking = false
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.cancelFindReplaceTask()
    }

    private func position(over parentWindow: NSWindow) {
        guard let panel = window else { return }
        var origin = NSPoint(
            x: parentWindow.frame.midX - panel.frame.width / 2,
            y: parentWindow.frame.midY - panel.frame.height / 2
        )
        if let visibleFrame = parentWindow.screen?.visibleFrame {
            origin.x = min(
                max(origin.x, visibleFrame.minX),
                visibleFrame.maxX - panel.frame.width
            )
            origin.y = min(
                max(origin.y, visibleFrame.minY),
                visibleFrame.maxY - panel.frame.height
            )
        }
        panel.setFrameOrigin(origin)
    }
}

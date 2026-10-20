import AppKit
import SwiftUI

enum FindReplaceWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier(
        "LacEditor.FindReplaceWindow"
    )
}

struct FindReplaceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var state: FindReplaceState
    @FocusState private var focusedField: Field?
    private let close: () -> Void
    @State private var showsEscapeHelp = false

    private enum Field {
        case query
        case replacement
    }

    init(
        state: FindReplaceState,
        close: @escaping () -> Void
    ) {
        _state = ObservedObject(wrappedValue: state)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("查找")
                    TextField("输入要查找的内容", text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .query)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            guard !actionsDisabled else { return .handled }
                            if press.modifiers.contains(.shift) {
                                appState.findPrevious()
                            } else {
                                appState.findNext()
                            }
                            return .handled
                        }
                }
                GridRow {
                    Text("替换为")
                    TextField("输入替换内容，留空表示删除", text: $state.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .replacement)
                }
            }

            HStack(spacing: 8) {
                Toggle("解释转义字符", isOn: $state.interpretsEscapes)
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onHover { showsEscapeHelp = $0 }
                    .accessibilityLabel("转义字符说明")
                    .accessibilityHint(escapeHelp)
                    .overlay(alignment: .topLeading) {
                        if showsEscapeHelp {
                            Text(escapeHelp)
                                .font(.system(size: 12))
                                .padding(10)
                                .frame(width: 330, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(y: 24)
                                .allowsHitTesting(false)
                        }
                    }
                Spacer()
                Toggle("区分大小写", isOn: $state.isCaseSensitive)
            }
            .toggleStyle(.checkbox)
            .zIndex(1)

            HStack {
                if let message = state.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Button("取消") {
                        appState.cancelFindReplaceTask()
                    }
                }
            }
            .frame(minHeight: 18)

            HStack {
                Button("关闭") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    appState.findPrevious()
                } label: {
                    Label("上一个", systemImage: "chevron.up")
                }
                .disabled(actionsDisabled)
                Button {
                    appState.findNext()
                } label: {
                    Label("下一个", systemImage: "chevron.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(actionsDisabled)

                Button("替换") { appState.replaceCurrentMatch() }
                    .disabled(actionsDisabled)
                Button("全部替换") { appState.replaceAllMatches() }
                    .buttonStyle(.borderedProminent)
                    .disabled(actionsDisabled)
            }
        }
        .padding(20)
        .frame(width: 560, height: 244)
        .onAppear {
            focusRequestedField()
        }
        .onChange(of: state.focusRequestID) {
            focusRequestedField()
        }
        .onDisappear { showsEscapeHelp = false }
        .onChange(of: state.query) {
            appState.cancelFindReplaceTask()
        }
        .onChange(of: state.replacement) {
            appState.cancelFindReplaceTask()
        }
        .onChange(of: state.isCaseSensitive) {
            appState.cancelFindReplaceTask()
        }
        .onChange(of: state.interpretsEscapes) {
            appState.cancelFindReplaceTask()
        }
    }

    private var actionsDisabled: Bool { state.query.isEmpty || state.isWorking }

    private var escapeHelp: String {
        #"可用转义字符：\n 换行，\r 回车，\t 制表符，\s 空格，\0 空字符，\\ 反斜杠。查找与替换内容均适用。"#
    }

    private func focusRequestedField() {
        DispatchQueue.main.async {
            focusedField = state.mode == .replace ? .replacement : .query
        }
    }
}

@MainActor
final class FindReplaceWindowController: NSWindowController, NSWindowDelegate {
    private weak var state: FindReplaceState?
    private weak var appState: AppState?
    private var hasPositionedWindow = false

    init(appState: AppState) {
        let findWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 244),
            styleMask: [.titled, .closable],
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
        findWindow.animationBehavior = .documentWindow
        findWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        findWindow.delegate = self

        findWindow.contentViewController = NSHostingController(
            rootView: FindReplaceView(
                state: appState.findReplace,
                close: { [weak self] in
                    self?.window?.performClose(nil)
                }
            )
            .environmentObject(appState)
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

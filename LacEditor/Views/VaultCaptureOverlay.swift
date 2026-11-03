import AppKit
import SwiftUI

/// Плавающая панель «Записать мысль…» (⌃⌥⌘N) поверх области редактора; открыта, пока у контроллера есть `request`.
struct VaultCaptureOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: VaultCaptureController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousResponder: NSResponder?

    var body: some View {
        ZStack(alignment: .top) {
            if controller.request != nil {
                Color.black.opacity(0.001).onTapGesture { dismiss() }
                VaultCapturePanel(controller: controller, dismiss: dismiss)
                    .padding(.top, 56)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? nil : LacEditorDesign.chromeAnimation, value: controller.request)
        .onChange(of: controller.request) { old, new in
            if old == nil, new != nil { previousResponder = capturableResponder() }
            else if old != nil, new == nil { restoreFocus() }
        }
    }

    private func dismiss() {
        if (appState.hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        controller.dismiss()
    }

    /// Прежний ответчик; поле ввода самой панели (field editor) не запоминаем.
    private func capturableResponder() -> NSResponder? {
        let responder = appState.hostWindow?.firstResponder
        if let text = responder as? NSTextView, text.isFieldEditor { return nil }
        return responder
    }

    /// Возвращает фокус прежнему элементу, а если его нет — редактору.
    private func restoreFocus() {
        let previous = previousResponder as? NSView
        previousResponder = nil
        DispatchQueue.main.async {
            guard let window = appState.hostWindow, !appState.commandPalette.isPresented, !appState.snippetPicker.isPresented,
                  !controller.isPresented else { return }
            if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
            if let current = window.firstResponder, !(current is NSWindow),
               !((current as? NSTextView)?.isFieldEditor ?? false) { return }
            if let previous, previous.window === window { window.makeFirstResponder(previous) }
            else if let editor = Self.editorView(in: window.contentView) { window.makeFirstResponder(editor) }
        }
    }

    private static func editorView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is LacTextView { return view }
        for child in view.subviews { if let found = editorView(in: child) { return found } }
        return nil
    }
}

struct VaultCapturePanel: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: VaultCaptureController
    let dismiss: () -> Void
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if controller.availableConnections.isEmpty {
                emptyState
            } else {
                if let notice = controller.notice { noticeRow(notice) }
                editor
                footer
            }
        }
        .padding(12)
        .frame(width: 520)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("记录想法"))
        .onExitCommand { dismiss() }
        .onAppear {
            editorFocused = true
            // Курсор в конец черновика: только в самом поле панели, а не в любом ответчике окна.
            DispatchQueue.main.async {
                if let field = appState.hostWindow?.firstResponder as? NSTextView, !(field is LacTextView),
                   field.string == controller.text {
                    field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.tr("记录想法")).font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help(L10n.tr("关闭"))
            .accessibilityLabel(L10n.tr("关闭"))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("连接 a-second-brain 笔记库")).foregroundStyle(.secondary)
            Button(L10n.tr("连接笔记库…")) {
                controller.dismiss()
                appState.presentVaultConnectionFromCapture()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeRow(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $controller.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .frame(minHeight: 96, maxHeight: 220)
                .accessibilityLabel(L10n.tr("想法"))
                .accessibilityHint(L10n.tr("⌘Return 发送，Esc 关闭"))
            if controller.text.isEmpty {
                Text(L10n.tr("写下想法，它会进入笔记库"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if controller.showsConnectionPicker { connectionPicker }
            counter
            Spacer(minLength: 0)
            microphone
            Button(L10n.tr("发送")) { controller.send() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!controller.canSend)
                .help(L10n.tr("⌘Return 发送，Esc 关闭"))
        }
    }

    private var connectionPicker: some View {
        Menu {
            ForEach(controller.availableConnections) { connection in
                Button(connection.name) { controller.chooseConnection(connection) }
            }
        } label: {
            if let connection = controller.connection {
                Text(L10n.tr("发送到：%@", connection.name))
            } else {
                Text(L10n.tr("选择笔记库"))
            }
        }
        .fixedSize()
        .accessibilityLabel(L10n.tr("选择笔记库"))
        .accessibilityValue(controller.connection?.name ?? "")
    }

    @ViewBuilder private var counter: some View {
        let count = controller.characterCount
        if count > VaultRequestText.maxScalars {
            Text(L10n.tr("想法太长（最多 100000 个字符）")).font(.caption).foregroundStyle(.red)
        } else if count > 90_000 {
            Text(L10n.tr("还可输入 %d 个字符", VaultRequestText.maxScalars - count)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var microphone: some View {
        let dictation = appState.aiDictation
        return Button { controller.toggleDictation() } label: {
            Image(systemName: dictation.buttonSymbol)
        }
        .disabled(!controller.isDictationEnabled)
        .help(dictation.buttonToolTip)
        .accessibilityLabel(AIFeature.voiceDraft.title)
        .accessibilityValue(dictation.state == .recording ? L10n.tr("正在录音") : "")
    }
}

import AppKit
import SwiftUI

extension View {
    func stableHelp(_ text: String, shortcut: String? = nil) -> some View {
        accessibilityHint(shortcut.map { "\(text)，快捷键 \($0)" } ?? text)
            .overlay(StableToolTipBridge(text: text, shortcut: shortcut))
    }
}

private struct StableToolTipBridge: NSViewRepresentable {
    let text: String
    let shortcut: String?

    func makeNSView(context: Context) -> ToolTipTrackingView {
        ToolTipTrackingView(text: text, shortcut: shortcut)
    }

    func updateNSView(_ nsView: ToolTipTrackingView, context: Context) {
        nsView.update(text: text, shortcut: shortcut)
    }

    static func dismantleNSView(_ nsView: ToolTipTrackingView, coordinator: ()) {
        nsView.cancelAndClose()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ToolTipTrackingView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

final class ToolTipTrackingView: NSView {
    // Only one custom tooltip may be pending or visible across the application.
    // A missed mouseExited during clipping/reflow must not leave an old panel.
    private static weak var activeTrackingView: ToolTipTrackingView?
    private var text: String
    private var shortcut: String?
    private var showWorkItem: DispatchWorkItem?
    private var toolTipPanel: ToolTipPanel?
    private var windowObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var generation = UUID()

    var isPresentationPending: Bool { showWorkItem != nil }

    init(text: String, shortcut: String?) {
        self.text = text
        self.shortcut = shortcut
        super.init(frame: .zero)
        // Do not also register an AppKit tooltip: it would overlap this panel.
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        showWorkItem?.cancel()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        closePanel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        schedulePanel()
    }

    override func mouseExited(with event: NSEvent) {
        cancelAndClose()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelAndClose()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        cancelAndClose()
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func observeDismissal() {
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMoveNotification, NSWindow.willStartLiveResizeNotification,
                     NSWindow.didResizeNotification, NSWindow.willMiniaturizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAndClose() }
            })
        }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAndClose() }
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAndClose() }
        })
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAndClose() }
            })
        }
    }

    func update(text: String, shortcut: String?) {
        guard self.text != text || self.shortcut != shortcut else { return }
        self.text = text
        self.shortcut = shortcut
        cancelAndClose()
    }

    private func schedulePanel() {
        Self.activeTrackingView?.cancelAndClose()
        Self.activeTrackingView = self
        observeDismissal()
        let request = UUID()
        generation = request
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.showPanel()
        }
        showWorkItem = workItem
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown
        ]) { [weak self] event in
            guard let self else { return event }
            if event.type != .mouseMoved || event.window !== self.window || !self.containsPointer() {
                self.cancelAndClose()
            }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func containsPointer() -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return visibleRect.contains(point)
    }

    private func showPanel() {
        showWorkItem = nil
        // Adding/ordering a child panel of a background editor can bring the
        // editor back above an auxiliary window. A tooltip never owns focus.
        guard Self.activeTrackingView === self, toolTipPanel == nil, NSApp.isActive,
              let window, window.isKeyWindow, containsPointer() else {
            cancelAndClose()
            return
        }

        let panel = ToolTipPanel(text: text, shortcut: shortcut)
        let targetRect = window.convertToScreen(convert(bounds, to: nil))
        var origin = NSPoint(
            x: targetRect.midX - panel.frame.width / 2,
            y: targetRect.minY - panel.frame.height - 7
        )

        if let visibleFrame = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 6), visibleFrame.maxX - panel.frame.width - 6)
            if origin.y < visibleFrame.minY + 6 {
                origin.y = targetRect.maxY + 7
            }
        }

        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        toolTipPanel = panel
    }

    func cancelAndClose() {
        generation = UUID()
        showWorkItem?.cancel()
        showWorkItem = nil
        if Self.activeTrackingView === self { Self.activeTrackingView = nil }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        closePanel()
    }

    private func closePanel() {
        guard let panel = toolTipPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        toolTipPanel = nil
    }
}

private final class ToolTipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(text: String, shortcut: String?) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        identifier = NSUserInterfaceItemIdentifier("LacEditor.HoverHelp")

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 5
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor

        let displayText = shortcut.map { "\(text)    \($0)" } ?? text
        let label = NSTextField(wrappingLabelWithString: displayText)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 320
        label.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        contentView = effectView
        let fittingSize = effectView.fittingSize
        setContentSize(NSSize(
            width: min(max(fittingSize.width, 40), 338),
            height: max(fittingSize.height, 26)
        ))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
    }
}

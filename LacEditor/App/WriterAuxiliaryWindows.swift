import AppKit
import SwiftUI

/// Немодальное окно проекта рукописи (доска, сводный просмотр): рядом можно продолжать писать.
@MainActor
final class WriterAuxiliaryWindowController: NSObject, NSWindowDelegate {
    enum Kind {
        case board, combined, mindMap

        var identifier: String {
            switch self {
            case .board: "LacEditor.WriterBoard"
            case .combined: "LacEditor.WriterCombined"
            case .mindMap: "LacEditor.MindMap"
            }
        }
    }

    let window: NSWindow
    var onClose: (() -> Void)?
    var onBecomeKey: (() -> Void)?
    var onResignKey: (() -> Void)?

    /// `autosaveName` без идентификатора проекта: положение и размер окна общие для всех проектов.
    init(kind: Kind, title: String, content: NSView, autosaveName: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(kind.identifier)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.delegate = self
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        onBecomeKey = nil
        onResignKey = nil
        handler?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?()
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }
}

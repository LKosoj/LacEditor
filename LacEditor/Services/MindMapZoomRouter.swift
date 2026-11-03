import Foundation

/// Перехват ⌘+, ⌘−, ⌘0: пока окно карты ключевое, они меняют масштаб карты, а не шрифт редактора.
@MainActor
enum MindMapZoomRouter {
    enum Action { case zoomIn, zoomOut, reset }

    private static var owner: AnyObject?
    private static var handler: ((Action) -> Void)?

    static func activate(owner: AnyObject, handler: @escaping (Action) -> Void) {
        self.owner = owner
        self.handler = handler
    }

    /// Снимает перехват, только если он принадлежит этому окну: другое окно карты могло уже стать ключевым.
    static func deactivate(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        handler = nil
    }

    /// true — команду забрала карта.
    static func handle(_ action: Action) -> Bool {
        guard let handler else { return false }
        handler(action)
        return true
    }
}

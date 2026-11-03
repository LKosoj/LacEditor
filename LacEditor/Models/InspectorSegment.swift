import Foundation

/// Сегменты правой панели: «Сцена | Стиль | AI» в писательской вкладке, «Стиль | AI» в обычной.
enum InspectorSegment: String, CaseIterable, Identifiable, Sendable {
    case scene, style, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scene: L10n.tr("书稿场景")
        case .style: L10n.tr("文风")
        case .ai: "AI"
        }
    }

    static func available(isWriter: Bool) -> [InspectorSegment] {
        isWriter ? [.scene, .style, .ai] : [.style, .ai]
    }

    /// Недоступный в этом режиме сегмент (`.scene` в обычной вкладке) заменяется на `.ai`.
    static func resolve(_ segment: InspectorSegment, isWriter: Bool) -> InspectorSegment {
        available(isWriter: isWriter).contains(segment) ? segment : .ai
    }

    private static func key(isWriter: Bool) -> String { isWriter ? "inspectorSegment.writer" : "inspectorSegment.normal" }

    static func stored(isWriter: Bool, defaults: UserDefaults = .standard) -> InspectorSegment {
        let stored = defaults.string(forKey: key(isWriter: isWriter)).flatMap(InspectorSegment.init(rawValue:)) ?? .ai
        return resolve(stored, isWriter: isWriter)
    }

    static func store(_ segment: InspectorSegment, isWriter: Bool, defaults: UserDefaults = .standard) {
        defaults.set(segment.rawValue, forKey: key(isWriter: isWriter))
    }
}

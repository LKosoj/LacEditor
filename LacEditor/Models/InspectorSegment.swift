import Foundation

/// Сегменты правой панели: «Сцена | Стиль | AI» в писательской вкладке, «Стиль | AI» в обычной,
/// «Заметка | Связи | Спросить | AI» во вкладке хранилища.
enum InspectorSegment: String, CaseIterable, Identifiable, Sendable {
    case scene, style, ai, vaultNote, vaultLinks, vaultAsk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scene: L10n.tr("书稿场景")
        case .style: L10n.tr("文风")
        case .ai: "AI"
        case .vaultNote: L10n.tr("笔记")
        case .vaultLinks: L10n.tr("关联")
        case .vaultAsk: L10n.tr("提问")
        }
    }

    /// Писательский и хранилищный режимы взаимоисключающие; если оба, приоритет у писателя.
    static func available(isWriter: Bool, isVault: Bool = false) -> [InspectorSegment] {
        if isWriter { return [.scene, .style, .ai] }
        return isVault ? [.vaultNote, .vaultLinks, .vaultAsk, .ai] : [.style, .ai]
    }

    /// Недоступный в этом режиме сегмент (`.scene` в обычной вкладке) заменяется на `.ai`, во вкладке хранилища — на «Заметку».
    static func resolve(_ segment: InspectorSegment, isWriter: Bool, isVault: Bool = false) -> InspectorSegment {
        if available(isWriter: isWriter, isVault: isVault).contains(segment) { return segment }
        return isVault && !isWriter ? .vaultNote : .ai
    }

    private static func key(isWriter: Bool, isVault: Bool) -> String {
        if isWriter { return "inspectorSegment.writer" }
        return isVault ? "inspectorSegment.vault" : "inspectorSegment.normal"
    }

    static func stored(isWriter: Bool, isVault: Bool = false, defaults: UserDefaults = .standard) -> InspectorSegment {
        let fallback: InspectorSegment = isVault && !isWriter ? .vaultNote : .ai
        let stored = defaults.string(forKey: key(isWriter: isWriter, isVault: isVault)).flatMap(InspectorSegment.init(rawValue:)) ?? fallback
        return resolve(stored, isWriter: isWriter, isVault: isVault)
    }

    static func store(_ segment: InspectorSegment, isWriter: Bool, isVault: Bool = false, defaults: UserDefaults = .standard) {
        defaults.set(segment.rawValue, forKey: key(isWriter: isWriter, isVault: isVault))
    }
}

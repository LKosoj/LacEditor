import Foundation

extension AppState {
    /// Писательская вкладка — привязанная к проекту рукописи.
    var inspectorIsWriterTab: Bool { writerSession != nil }
    /// Вкладка режима хранилища: заметка хранилища или окно с подключением. Писатель важнее (режимы не пересекаются).
    var inspectorIsVaultTab: Bool { vaultNote != nil || vaultSession != nil }
    var effectiveInspectorSegment: InspectorSegment {
        InspectorSegment.resolve(inspectorSegment, isWriter: inspectorIsWriterTab, isVault: inspectorIsVaultTab)
    }

    /// Пункты меню «Свойства заметки», «Связи заметки», «Спросить…»: выбирают сегмент и показывают панель.
    func showVaultInspector(_ segment: InspectorSegment) {
        guard inspectorIsVaultTab, !inspectorIsWriterTab else { return }
        if isDistractionFree { toggleDistractionFree() }
        inspectorSegment = segment
        inspectorSegmentIsExplicit = true
        isAIWritingVisible = true
    }

    /// Запрос функции AI (кнопки, меню): во вкладке хранилища панель открывается на «AI», а не на сегменте заметки.
    func selectAIInspectorSegmentIfVault() {
        guard inspectorIsVaultTab, !inspectorIsWriterTab else { return }
        inspectorSegment = .ai
        inspectorSegmentIsExplicit = true
    }
}

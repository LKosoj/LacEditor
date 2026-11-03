import AppKit
import Combine
import Foundation

/// Всё, что относится к карточкам мира одного писательского проекта: каталог, AI и окно кандидатов.
/// Живёт столько же, сколько `WriterSession`.
@MainActor
final class StoryCardWorld: ObservableObject {
    let catalog = StoryCardCatalog()
    let ai = StoryCardAIController()
    /// Кандидаты, найденные без AI (AI-кандидаты лежат в `ai.candidates`).
    @Published var localCandidates: [StoryCardCandidate] = []
    @Published var candidatesNote = ""
    /// Идёт локальный поиск кандидатов (окно показывает индикатор).
    @Published var isSearchingCandidates = false
    var candidatesWindow: NSWindow?
    private var forwarding: [AnyCancellable] = []

    init() {
        forwarding = [
            catalog.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            ai.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
        ]
    }

    func cancelAll() {
        catalog.cancel()
        ai.cancel()
        if let window = candidatesWindow, let parent = window.sheetParent { parent.endSheet(window) }
        candidatesWindow = nil
    }
}

import Combine
import Foundation

/// Список символов текущего файла для боковой панели. Работает только при раскрытом разделе; результат не хранится в сессии.
@MainActor
final class SymbolOutlineController: ObservableObject {
    enum State: Equatable { case inactive, updating, loaded, tooLarge }

    @Published private(set) var state: State = .inactive
    @Published private(set) var symbols: [OutlineSymbol] = []

    private let maximumUTF8Bytes: Int
    private let pause: TimeInterval
    private weak var document: EditorDocument?
    private var resultRevision: UInt?
    private var generation: UInt = 0
    private var subscriptions: [AnyCancellable] = []

    init(maximumUTF8Bytes: Int = SymbolOutlineService.maximumUTF8Bytes,
         pause: TimeInterval = EditorDocument.typingPause) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.pause = pause
    }

    /// `isActive`: раздел раскрыт и боковая панель видна. Иначе работа останавливается, список очищается.
    func update(document: EditorDocument?, isActive: Bool) {
        guard isActive, let document, SymbolOutlineService.supports(document.language) else {
            return reset()
        }
        if self.document !== document {
            reset()
            self.document = document
            subscribe(to: document)
        }
        start()
    }

    /// Результат относится к текущей версии текста документа.
    func isCurrent(for document: EditorDocument) -> Bool {
        state == .loaded && self.document === document
            && resultRevision == document.textRevision && !document.hasPendingLiveEdits
    }

    func close() { reset() }

    private func subscribe(to document: EditorDocument) {
        subscriptions = [
            // Первая правка серии сразу убирает устаревший список
            document.textEdits.sink { [weak self] in
                guard let self, self.state == .loaded else { return }
                self.state = .updating
            },
            document.textEdits.debounce(for: .seconds(pause), scheduler: DispatchQueue.main).sink { [weak self] in
                self?.start()
            }
        ]
    }

    private func reset() {
        generation &+= 1
        document?.taskCoordinator.cancel(.symbolOutline)
        subscriptions = []
        document = nil
        resultRevision = nil
        if !symbols.isEmpty { symbols = [] }
        if state != .inactive { state = .inactive }
    }

    private func start() {
        guard let document, SymbolOutlineService.supports(document.language) else { return reset() }
        generation &+= 1
        let currentGeneration = generation
        let coordinator = document.taskCoordinator
        let taskGeneration = coordinator.begin(.symbolOutline)
        guard let snapshot = document.symbolOutlineSnapshot(), snapshot.byteCount <= maximumUTF8Bytes else {
            symbols = []
            resultRevision = nil
            state = .tooLarge
            coordinator.finish(.symbolOutline, generation: taskGeneration)
            return
        }
        if state != .loaded || resultRevision != snapshot.revision { state = .updating }
        let language = document.language
        let task = Task.detached(priority: .utility) { [weak self, weak document] in
            let result = SymbolOutlineService.symbols(in: snapshot.text, language: language, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .symbolOutline) else { return }
            await MainActor.run { [weak self, weak document] in
                guard let self, let document, self.generation == currentGeneration, self.document === document,
                      document.textRevision == snapshot.revision, !document.hasPendingLiveEdits,
                      !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .symbolOutline) else { return }
                // разбор не удался без отмены: показываем пустой список
                self.symbols = result ?? []
                self.resultRevision = snapshot.revision
                self.state = .loaded
                coordinator.finish(.symbolOutline, generation: taskGeneration)
            }
        }
        coordinator.attachTask(task, kind: .symbolOutline, generation: taskGeneration)
    }
}

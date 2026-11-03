import AppKit
import Combine

/// Кто запросил запись файла. Автосохранение не открывает окон и сообщает итог через `onOutcome`.
enum SaveOrigin {
    case user
    case autosave(recordsVersion: Bool, onOutcome: (AutosaveController.Outcome) -> Void)

    var outcomeHandler: ((AutosaveController.Outcome) -> Void)? {
        if case let .autosave(_, onOutcome) = self { return onOutcome }
        return nil
    }

    /// Ручное сохранение всегда записывает версию NSFileVersion; автосохранение — не чаще раза в 5 минут.
    var recordsVersion: Bool {
        if case let .autosave(recordsVersion, _) = self { return recordsVersion }
        return true
    }
}

/// Периодически записывает изменённые документы, у которых уже есть путь на диске (по умолчанию выключено).
@MainActor
final class AutosaveController: ObservableObject {
    enum Status: Equatable {
        case saved(Date)
        case pausedExternalChange
        case failed(String)
    }

    enum Outcome: Equatable {
        case saved, pausedExternalChange, failed(String), skipped
    }

    /// Версию NSFileVersion автосохранение записывает не чаще этого.
    static let versionRecordInterval: TimeInterval = 300

    @Published private(set) var statuses: [UUID: Status] = [:]

    private weak var appState: AppState?
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var lastAttempt: [UUID: Date] = [:]
    /// Состояние файла в момент паузы: пока оно не изменилось (перезагрузка, ручная запись), автосохранение не пишет.
    private var pausedBaseline: [UUID: FileRevisionSnapshot?] = [:]
    private var lastVersionRecord: [UUID: Date] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        guard let preferences = appState?.preferences else { return }
        cancellable = Publishers.CombineLatest(preferences.$autosaveEnabled, preferences.$autosaveInterval)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildTimer() }
        rebuildTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellable = nil
    }

    func status(for id: UUID) -> Status? { statuses[id] }

    func forget(_ id: UUID) {
        statuses.removeValue(forKey: id)
        lastAttempt.removeValue(forKey: id)
        pausedBaseline.removeValue(forKey: id)
        lastVersionRecord.removeValue(forKey: id)
    }

    /// Когда последний раз автосохранение просило записать версию файла.
    func lastVersionRecordDate(for id: UUID) -> Date? { lastVersionRecord[id] }

    private var isEnabled: Bool { appState?.preferences.autosaveEnabled == true }
    private var interval: TimeInterval { TimeInterval(appState?.preferences.autosaveInterval ?? 60) }

    private func rebuildTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            // Окно освобождено: таймер больше не нужен.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { _ = self.tick() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Один проход по документам окна. Возвращает число документов, для которых запущена запись.
    @discardableResult
    func tick(now: Date = Date()) -> Int {
        guard let appState, isEnabled,
              appState.windowManager?.terminationApproved != true,
              appState.windowManager?.isConfirmingClose != true,
              !appState.isClosingOrConfirmingDocument else { return 0 }
        var started = 0
        for document in appState.documents {
            let id = document.id
            guard let url = document.url, document.isDirty, document.ioState == .idle,
                  !appState.isOpeningPlaceholder(document) else { continue }
            // Пауза из-за внешнего изменения живёт, пока не изменилось состояние файла в документе.
            if let baseline = pausedBaseline[id] {
                if document.fileRevisionSnapshot != baseline {
                    pausedBaseline.removeValue(forKey: id)
                    statuses.removeValue(forKey: id)
                } else {
                    statuses[id] = .pausedExternalChange
                    continue
                }
            }
            // Идёт системный ввод (например, иероглифы): повторим на следующем проходе.
            if appState.selectedDocument === document,
               (appState.hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { continue }
            if document.externalChange != nil {
                pause(document)
                continue
            }
            _ = document.synchronizedText()
            if document.hasUnknownMediaTokens {
                statuses[id] = .failed(L10n.tr("文档含无法识别的媒体标记，请撤销最近的修改"))
                continue
            }
            if let last = lastAttempt[id], now.timeIntervalSince(last) < interval - 0.5 { continue }
            lastAttempt[id] = now
            let recordsVersion = now.timeIntervalSince(lastVersionRecord[id] ?? .distantPast) >= Self.versionRecordInterval
            let origin = SaveOrigin.autosave(recordsVersion: recordsVersion) { [weak self, weak document] outcome in
                guard let self, let document else { return }
                self.handle(outcome, for: document, recordsVersion: recordsVersion, now: now)
            }
            if appState.write(document, to: url, bypassExternalConflict: false, origin: origin) { started += 1 }
        }
        return started
    }

    private func handle(_ outcome: Outcome, for document: EditorDocument, recordsVersion: Bool, now: Date) {
        let id = document.id
        switch outcome {
        case .saved:
            statuses[id] = .saved(document.lastSavedAt ?? Date())
            pausedBaseline.removeValue(forKey: id)
            if recordsVersion { lastVersionRecord[id] = now }
        case .pausedExternalChange:
            pause(document)
        case .failed(let message):
            statuses[id] = .failed(message)
        case .skipped:
            break
        }
    }

    private func pause(_ document: EditorDocument) {
        pausedBaseline[document.id] = .some(document.fileRevisionSnapshot)
        statuses[document.id] = .pausedExternalChange
    }
}

import Combine
import Foundation

/// Построение регулярного выражения по описанию из поля поиска. В модель уходит только фраза, текст документа не читается.
/// Поле меняется только после проверки выражения; запуск по кнопке, автоповторов нет.
@MainActor
final class AIRegexController: ObservableObject {
    enum Target: Equatable { case findBar, folderSearch }

    @Published private(set) var isWorking = false
    /// Кому принадлежит запрос или сообщение.
    @Published private(set) var target: Target?
    @Published private(set) var message: StatusMessage?

    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Последнее подставленное выражение: подстановка сама меняет поле, и это не должно отменять результат.
    private var appliedPattern: String?
    private var stateObserver: AnyCancellable?
    private let generate: (String, AIModelProfile, String?) async throws -> String
    private let loadKey: (AIRole, String) throws -> String?

    init(appState: AppState,
         generate: @escaping (String, AIModelProfile, String?) async throws -> String = {
             try await AIClient().generateText(input: AIRegexBuilder.input($0), instructions: AIRegexBuilder.instructions, profile: $1, key: $2)
         },
         loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) }) {
        self.appState = appState
        self.generate = generate
        self.loadKey = loadKey
        // Панель поиска и боковая панель слушают AppState, поэтому каждая смена состояния пересылается туда.
        stateObserver = objectWillChange.sink { [weak appState] _ in appState?.objectWillChange.send() }
    }
    deinit { task?.cancel() }

    /// Можно ли показывать кнопку: профиль текста включён, протокол подходит, модель задана.
    static func isAvailable(preferences: AppPreferences) -> Bool {
        let profile = preferences.regexBuilderProfile()
        return profile.isEnabled && profile.supports(.text)
            && !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Запуск по нажатию. Пустая (после обрезки краёв) фраза не запускает ничего.
    /// apply вызывается один раз, на главном потоке, только если выражение проверено и всё ещё актуально.
    func start(phrase: String, target: Target, apply: @escaping (AIRegexBuilder.Result) -> Void) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, let appState, Self.isAvailable(preferences: appState.preferences) else { return }
        cancel()
        self.target = target
        let current = generation
        let profile = appState.preferences.regexBuilderProfile()
        let key: String?
        do { key = try loadKey(.text, profile.baseURL) }
        catch {
            message = StatusMessage(kind: .error, text: error.localizedDescription)
            return
        }
        isWorking = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.generate(phrase, profile, key)
                guard self.generation == current else { return }
                guard !Task.isCancelled, let appState = self.appState,
                      appState.preferences.regexBuilderProfile() == profile,
                      (try? self.loadKey(.text, profile.baseURL)) == key else {
                    self.isWorking = false
                    return
                }
                let result = try AIRegexBuilder.parse(response)
                self.isWorking = false
                // Сначала appliedPattern, потом apply: иначе правка поля отменила бы собственный результат.
                self.appliedPattern = result.pattern
                self.message = StatusMessage(kind: .success,
                                             text: result.explanation.isEmpty ? L10n.tr("已生成正则表达式") : result.explanation)
                apply(result)
            } catch {
                guard self.generation == current else { return }
                self.isWorking = false
                if error is CancellationError { return }
                self.message = StatusMessage(kind: .error, text: Self.text(for: error))
            }
        }
    }

    /// Кнопка отмены, закрытие панели, закрытие окна. Поле запроса не трогается.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isWorking = false
        message = nil
        appliedPattern = nil
    }

    /// Пользователь изменил поле запроса. Совпадение с последним подставленным выражением игнорируется.
    func queryEdited(_ text: String, target: Target) {
        guard target == self.target, text != appliedPattern else { return }
        cancel()
    }

    func windowClosed() { cancel() }

    private static func text(for error: Error) -> String {
        switch error {
        case AIRegexBuilder.Failure.declined(let reason):
            reason.isEmpty ? (AIError.invalidResponse.errorDescription ?? "") : reason
        case AIRegexBuilder.Failure.invalidPattern:
            L10n.tr("AI 生成的正则表达式无效，请换一种说法再试")
        default:
            error.localizedDescription
        }
    }
}

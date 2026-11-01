import Foundation

@MainActor
final class AICompletionController {
    typealias Generate = (String, AIModelProfile, String?) async throws -> String
    private let generate: Generate
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private var coordinator: DocumentTaskCoordinator?
    private var cache = AICompletionCache()
    /// Ключ API последнего запроса: только в памяти, чтобы при его смене сбросить кэш; в кэш и в журнал не попадает.
    private var cachedKey: String??

    init(generate: @escaping Generate = { input, profile, key in
        try await AIClient().generateCompletion(input: input, instructions: AICompletionContext.instructions, profile: profile, key: key)
    }) {
        self.generate = generate
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        coordinator?.cancel(.aiCompletion)
        coordinator = nil
    }

    /// Короткое сообщение об ошибке для строки состояния: только первая строка описания `AIError`, без ответа сервера, ключа и текста документа.
    static func failureMessage(_ error: Error) -> String {
        guard let line = (error as? AIError)?.errorDescription?.components(separatedBy: .newlines).first, !line.isEmpty else {
            return L10n.tr("自动续写失败")
        }
        return L10n.tr("自动续写失败：%@", line)
    }

    func schedule(delay: UInt64, inputProvider: @escaping () -> AICompletionContext?, keyProvider: @escaping () throws -> String?,
                  coordinator: DocumentTaskCoordinator, profile: AIModelProfile,
                  isCurrent: @escaping () -> Bool, show: @escaping (String, String?) -> Void,
                  fail: @escaping (String) -> Void = { _ in }) {
        cancel()
        let current = generation
        self.coordinator = coordinator
        let taskGeneration = coordinator.begin(.aiCompletion)
        task = Task { [weak self] in
            defer { coordinator.finish(.aiCompletion, generation: taskGeneration) }
            func loadKey() throws -> String? {
                do { return try keyProvider() } catch { throw AIError.keychain }
            }
            do {
                try await Task.sleep(nanoseconds: delay)
                guard let self, self.generation == current, coordinator.isCurrent(taskGeneration, for: .aiCompletion), isCurrent() else { return }
                guard let context = inputProvider() else { return }
                let key = try loadKey()
                guard isCurrent() else { return }
                if let known = self.cachedKey, known != key { self.cache = AICompletionCache() }
                self.cachedKey = .some(key)
                let input = context.requestText
                let server = (try? AIModelProfile.normalizedBaseURL(profile.baseURL).absoluteString) ?? profile.baseURL
                let cacheKey = AICompletionCache.key(request: input, model: profile.modelID, server: server)
                let response: String
                if let cached = self.cache.value(for: cacheKey) {
                    response = cached
                } else {
                    response = try await self.generate(input, profile, key)
                    guard !Task.isCancelled, self.generation == current, coordinator.isCurrent(taskGeneration, for: .aiCompletion), isCurrent() else { return }
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.cache.store(response, for: cacheKey) }
                }
                guard try loadKey() == key else { return }
                guard let line = AICompletionContext.clean(response, before: context.before, after: context.after, isProse: context.isProse) else { return }
                show(line, key)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.generation == current, coordinator.isCurrent(taskGeneration, for: .aiCompletion), isCurrent() else { return }
                fail(AICompletionController.failureMessage(error))
            }
        }
        if let task { coordinator.attachTask(task, kind: .aiCompletion, generation: taskGeneration) }
    }
}

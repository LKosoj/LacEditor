import Foundation

@MainActor
final class AICompletionController {
    typealias Generate = (String, AIModelProfile, String?) async throws -> String
    private let generate: Generate
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private var coordinator: DocumentTaskCoordinator?

    init(generate: @escaping Generate = { input, profile, key in
        let result = try await AIWritingService.generate(feature: .completion, input: input, option: "", profile: profile, key: key)
        return result.suggestions.first?.replacement ?? ""
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

    func schedule(inputProvider: @escaping () -> String?, keyProvider: @escaping () throws -> String?,
                  coordinator: DocumentTaskCoordinator, profile: AIModelProfile,
                  isCurrent: @escaping () -> Bool, show: @escaping (String, String?) -> Void) {
        cancel()
        let current = generation
        self.coordinator = coordinator
        let taskGeneration = coordinator.begin(.aiCompletion)
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                guard let self, self.generation == current, coordinator.isCurrent(taskGeneration, for: .aiCompletion), isCurrent() else { return }
                guard let input = inputProvider(), !input.isEmpty else { return }
                guard AIRequestSize.bytes(input) <= AIRequestSize.threshold else { return }
                let key = try keyProvider()
                guard isCurrent() else { return }
                let result = try await self.generate(input, profile, key)
                guard !Task.isCancelled, self.generation == current, coordinator.isCurrent(taskGeneration, for: .aiCompletion), isCurrent() else { return }
                guard try keyProvider() == key else { return }
                let line = result.components(separatedBy: .newlines).first ?? ""
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                show(line, key)
            } catch {}
            coordinator.finish(.aiCompletion, generation: taskGeneration)
        }
        if let task { coordinator.attachTask(task, kind: .aiCompletion, generation: taskGeneration) }
    }
}

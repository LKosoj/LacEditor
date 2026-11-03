import Combine
import Foundation

/// Источники экспорта, подготовленные вызывающим (чтение файлов уже выполнено).
struct FountainSources: Sendable {
    var title: String
    var parts: [FountainExportService.Part]
    /// Текст, из front matter которого строится титульная страница.
    var frontMatterText: String?
    var syntax: MarkdownSyntaxOptions
    /// Предупреждения этапа сбора (например, файлы, которые не удалось прочитать).
    var warnings: [FountainExportService.Warning] = []
}

/// Состояние листа «Экспорт в Fountain»: структурное преобразование или адаптация ИИ по сценам.
/// Живёт столько же, сколько окно; результат отдаётся через `onFinished`.
@MainActor
final class FountainExportController: ObservableObject {
    enum Scope { case document, project }
    enum Mode { case structure, adaptation }
    enum Phase: Equatable {
        case idle, preparing
        case adapting(done: Int, total: Int)
        case confirmingOversize(scene: Int, bytes: Int)
    }

    let scope: Scope
    @Published var mode: Mode = .structure
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: StatusMessage?
    @Published private(set) var aiAvailability: AIAvailability

    private let sources: () async -> FountainSources
    private let generate: (_ input: String, _ instructions: String) async throws -> String
    private let onFinished: (_ text: String, _ warnings: [FountainExportService.Warning], _ saveToFile: Bool) -> Void
    private let availability: () -> AIAvailability
    private var task: Task<Void, Never>?
    private var generation = 0
    private var oversizeAnswer: CheckedContinuation<Bool, Never>?

    init(scope: Scope,
         aiAvailability: @escaping () -> AIAvailability = { .available },
         sources: @escaping () async -> FountainSources,
         generate: @escaping (_ input: String, _ instructions: String) async throws -> String,
         onFinished: @escaping (_ text: String, _ warnings: [FountainExportService.Warning], _ saveToFile: Bool) -> Void) {
        self.scope = scope
        availability = aiAvailability
        self.aiAvailability = aiAvailability()
        self.sources = sources
        self.generate = generate
        self.onFinished = onFinished
    }

    deinit { task?.cancel() }

    var isWorking: Bool { phase != .idle }

    /// Настройки ИИ могли измениться, пока лист открыт.
    func refreshAvailability() {
        let current = availability()
        if aiAvailability != current { aiAvailability = current }
    }

    func start(saveToFile: Bool) {
        guard phase == .idle else { return }
        let adapt = mode == .adaptation
        if adapt {
            refreshAvailability()
            guard aiAvailability == .available else { return }
        }
        generation += 1
        let current = generation
        status = nil
        phase = .preparing
        task = Task { [weak self] in
            if adapt { await self?.runAdaptation(current, saveToFile: saveToFile) } else { await self?.runStructure(current, saveToFile: saveToFile) }
        }
    }

    /// Кнопка «仍然发送».
    func confirmOversize() {
        guard case .confirmingOversize = phase, let answer = oversizeAnswer else { return }
        oversizeAnswer = nil
        answer.resume(returning: true)
    }

    /// Отменяет работу; поздние результаты по счётчику поколений игнорируются.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if let answer = oversizeAnswer {
            oversizeAnswer = nil
            answer.resume(returning: false)
        }
        phase = .idle
    }

    func windowClosed() {
        cancel()
    }

    // MARK: Структурное преобразование

    private func runStructure(_ current: Int, saveToFile: Bool) async {
        let input = await sources()
        guard generation == current, !Task.isCancelled else { return }
        let isProject = scope == .project
        let work = Task.detached(priority: .userInitiated) { () -> (String, [FountainExportService.Warning]) in
            let options = FountainExportService.Options(syntax: input.syntax)
            let result = isProject
                ? FountainExportService.convertProject(title: input.title, titleFrontMatterFrom: input.frontMatterText,
                                                       parts: input.parts, options: options)
                : FountainExportService.convertDocument(input.parts.first?.text ?? "", options: options)
            return (result.text, result.warnings)
        }
        let (text, warnings) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard generation == current, !Task.isCancelled else { return }
        finish(text, warnings: FountainExportService.merge([input.warnings, warnings]), saveToFile: saveToFile)
    }

    // MARK: Адаптация ИИ

    private func runAdaptation(_ current: Int, saveToFile: Bool) async {
        let input = await sources()
        guard generation == current, !Task.isCancelled else { return }
        let isProject = scope == .project
        let work = Task.detached(priority: .userInitiated) { () -> [FountainExportService.Scene] in
            let options = FountainExportService.Options(syntax: input.syntax)
            return input.parts.map { FountainExportService.scene($0, options: options) }
        }
        let scenes = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard generation == current, !Task.isCancelled else { return }

        let total = scenes.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        var sections: [(headerFountain: String, body: String)] = []
        var warnings: [[FountainExportService.Warning]] = [input.warnings]
        var fallbacks: [FountainExportService.Warning] = []
        var number = 0
        for scene in scenes {
            warnings.append(scene.warnings)
            let structural = scene.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !structural.isEmpty else {
                sections.append((scene.header, ""))
                continue
            }
            number += 1
            phase = .adapting(done: number - 1, total: total)
            let language = TextSegmentation.languageCode(for: TextSegmentation.language(of: structural))
            let base = FountainAdaptationService.input(sceneFountain: structural, languageCode: language)
            let instructions = FountainAdaptationService.instructions
            let bytes = AIRequestSize.bytes(base, instructions)
            if bytes > AIRequestSize.threshold {
                phase = .confirmingOversize(scene: number, bytes: bytes)
                status = StatusMessage(kind: .info, text: AIRequestSize.warning(label: L10n.tr("第 %d 个场景", number), bytes: bytes))
                let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    oversizeAnswer = continuation
                }
                guard generation == current, !Task.isCancelled, confirmed else { return }
                status = nil
                phase = .adapting(done: number - 1, total: total)
            }
            var request = base
            var accepted: String?
            for attempt in 0..<2 {
                let response: String
                do {
                    response = try await generate(request, instructions)
                } catch {
                    guard generation == current, !Task.isCancelled else { return }
                    // Сетевая ошибка останавливает работу, частичный результат не открывается.
                    phase = .idle
                    status = StatusMessage(kind: .error, text: L10n.tr("改编在第 %d 个场景中止：%@", number, error.localizedDescription))
                    return
                }
                guard generation == current, !Task.isCancelled else { return }
                var issues = [FountainIssue(kind: .emptyDocument, line: 1)]
                if let text = FountainAdaptationService.parse(response) {
                    let lint = FountainAdaptationService.validate(text)
                    if lint.isValid {
                        accepted = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                    issues = lint.issues
                }
                if attempt == 0 { request = FountainAdaptationService.retryInput(base: base, issues: issues) }
            }
            if let accepted {
                sections.append((scene.header, accepted))
            } else {
                sections.append((scene.header, structural))
                fallbacks.append(FountainExportService.Warning(kind: .aiFallback, count: 1, detail: String(number)))
            }
        }
        guard generation == current, !Task.isCancelled else { return }
        let titlePage = FountainExportService.titlePage(frontMatterFrom: input.frontMatterText, titleOverride: isProject ? input.title : nil)
        warnings.append(titlePage.warnings)
        let text = FountainAdaptationService.assemble(titlePage: titlePage.text, sections: sections)
        finish(text, warnings: FountainExportService.merge(warnings) + fallbacks, saveToFile: saveToFile, adapted: total)
    }

    private func finish(_ text: String, warnings: [FountainExportService.Warning], saveToFile: Bool, adapted: Int? = nil) {
        phase = .idle
        task = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = StatusMessage(kind: .error, text: L10n.tr("没有可导出的内容"))
            return
        }
        if let adapted { status = StatusMessage(kind: .success, text: L10n.tr("已改编 %d 个场景", adapted)) }
        onFinished(text, warnings, saveToFile)
    }
}

import AppKit

/// Prepares a temporary Markdown snapshot with locally rendered images for Pandoc.
@MainActor
final class MarkdownExportImagesService {
    enum PreparationError: LocalizedError {
        case cancelled, stale, rendering, invalidRange
        var errorDescription: String? {
            if case .stale = self { return L10n.tr("文档已更改，导出已取消。") }
            return nil
        }
    }
    @MainActor
    private enum ActiveService {
        case math(MathJaxRenderService)
        case mermaid(MermaidRenderService)
        case legacy(LegacyDiagramRenderService)
        func cancel() {
            switch self {
            case let .math(service): service.cancel()
            case let .mermaid(service): service.cancel()
            case let .legacy(service): service.cancel()
            }
        }
    }
    private let source: String
    private let width: CGFloat
    private let dark: Bool
    private let fontSize: CGFloat
    private let mathOptions: MathJaxRenderService.Options
    private let syntax: MarkdownSyntaxOptions
    private let includeMath: Bool
    private let isCurrent: () -> Bool
    private var completion: ((Result<String, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var active: ActiveService?

    init(source: String, width: CGFloat, dark: Bool, fontSize: CGFloat,
         mathOptions: MathJaxRenderService.Options, syntax: MarkdownSyntaxOptions = .init(), includeMath: Bool = true,
         isCurrent: @escaping () -> Bool,
         completion: @escaping (Result<String, Error>) -> Void) {
        self.source = source
        self.width = width
        self.dark = dark
        self.fontSize = fontSize
        self.mathOptions = mathOptions
        self.syntax = syntax
        self.includeMath = includeMath
        self.isCurrent = isCurrent
        self.completion = completion
    }

    func start() {
        guard completion != nil, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkCurrent()
                let text = self.source
                let syntax = self.syntax, includeMath = self.includeMath
                let parsing = Task.detached(priority: .userInitiated) { () throws -> (MarkdownPresentation, [String: String]) in
                    let presentation = MarkdownPresentationParser.parse(text, includeEmojiCandidates: includeMath, syntax: syntax, isCancelled: { Task.isCancelled })
                    guard !Task.isCancelled else { throw CancellationError() }
                    let values = includeMath ? try EmojiShortcodeResolver.resolve(presentation.emojiCandidates.map(\.name), isCancelled: { Task.isCancelled }) : [:]
                    return (presentation, values)
                }
                let (presentation, emojiValues) = try await withTaskCancellationHandler(operation: { try await parsing.value }, onCancel: { parsing.cancel() })
                try self.checkCurrent()
                let formulas = (includeMath ? (presentation.formulas.map { ($0, true) } + presentation.inlineFormulas.map { ($0, false) }) : [])
                    .sorted { $0.0.range.location < $1.0.range.location }
                var replacements: [(NSRange, String)] = presentation.emojiCandidates.compactMap { candidate in
                    emojiValues[candidate.name].map { (candidate.range, $0) }
                }
                if !formulas.isEmpty {
                    let expressions = formulas.map { MathJaxRenderService.Expression(source: $0.0.source, display: $0.1) }
                    let images = try await self.renderMath(expressions)
                    try self.checkCurrent()
                    guard images.count == formulas.count else { throw PreparationError.rendering }
                    for (index, image) in images.enumerated() {
                        guard let image else { throw PreparationError.rendering }
                        replacements.append((formulas[index].0.range, try Self.markdownImage(image, alt: formulas[index].0.source)))
                    }
                }
                for diagram in presentation.diagrams {
                    try self.checkCurrent()
                    let image = try await self.renderDiagram(diagram)
                    try self.checkCurrent()
                    replacements.append((diagram.range, try Self.markdownImage(image, alt: diagram.source)))
                }
                let input = text as NSString
                let sorted = replacements.sorted { $0.0.location < $1.0.location }
                var previousEnd = 0
                for (range, _) in sorted {
                    guard range.location >= previousEnd, range.location >= 0, range.length > 0,
                          range.location <= input.length, range.length <= input.length - range.location else { throw PreparationError.invalidRange }
                    previousEnd = NSMaxRange(range)
                }
                let output = NSMutableString()
                var position = 0
                for (range, replacement) in sorted {
                    try self.checkCurrent()
                    output.append(input.substring(with: NSRange(location: position, length: range.location - position)))
                    output.append(replacement)
                    position = NSMaxRange(range)
                }
                output.append(input.substring(from: position))
                try self.checkCurrent()
                self.finish(.success(output as String))
            } catch { self.finish(.failure(error)) }
        }
    }

    func cancel() {
        task?.cancel()
        active?.cancel()
        finish(.failure(PreparationError.cancelled))
    }

    private func checkCurrent() throws {
        if Task.isCancelled { throw PreparationError.cancelled }
        guard isCurrent() else { throw PreparationError.stale }
    }

    private func renderMath(_ expressions: [MathJaxRenderService.Expression]) async throws -> [NSImage?] {
        try await withCheckedThrowingContinuation { continuation in
            let service = MathJaxRenderService(expressions: expressions, outputIndices: Array(expressions.indices),
                width: width, dark: dark, fontSize: fontSize, options: mathOptions) { [weak self] result in
                self?.active = nil
                continuation.resume(with: result)
            }
            active = .math(service)
            service.start()
        }
    }

    private func renderDiagram(_ diagram: MarkdownDiagram) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let done: (Result<NSImage, Error>) -> Void = { [weak self] result in
                self?.active = nil
                continuation.resume(with: result)
            }
            switch diagram.kind {
            case .mermaid:
                let service = MermaidRenderService(code: diagram.source, width: width, dark: dark, completion: done)
                active = .mermaid(service)
                service.start()
            case .flow, .sequence:
                let kind: LegacyDiagramRenderService.Kind = diagram.kind == .flow ? .flow : .sequence
                let service = LegacyDiagramRenderService(code: diagram.source, kind: kind, width: width, completion: done)
                active = .legacy(service)
                service.start()
            }
        }
    }

    static func markdownImage(_ image: NSImage, alt: String) throws -> String {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw PreparationError.rendering }
        let plain = alt.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        let label = plain.reduce(into: "") { result, character in
            if punctuation.contains(character) { result.append("\\") }
            result.append(character)
        }
        return "![\(label)](data:image/png;base64,\(png.base64EncodedString()))"
    }

    private func finish(_ result: Result<String, Error>) {
        guard let completion else { return }
        self.completion = nil
        task = nil
        active = nil
        completion(result)
    }
}

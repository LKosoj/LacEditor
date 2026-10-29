import Foundation
import Yams

enum MarkdownTagReader {
    struct Input: Encodable, Sendable {
        let id: UUID
        let frontMatter: String
    }

    enum Outcome: Equatable, Sendable {
        case tags([String])
        case invalid(String)
    }

    enum ReadError: Error { case invalidResult }

    static func read(_ inputs: [Input], isCancelled: () -> Bool = { false }) throws -> [UUID: Outcome] {
        guard Set(inputs.map(\.id)).count == inputs.count else { throw ReadError.invalidResult }
        var output: [UUID: Outcome] = [:]
        for input in inputs {
            if isCancelled() { throw CancellationError() }
            do {
                guard let mapping = try PandocExportService.yamlFrontMatter(input.frontMatter), let node = mapping["tags"] else {
                    output[input.id] = .tags([])
                    continue
                }
                func string(_ value: Node) -> String? {
                    guard value.tag == Tag(.str) else { return nil }
                    return value.scalar?.string
                }
                if let values = node.sequence {
                    var tags: [String] = []
                    for value in values {
                        if isCancelled() { throw CancellationError() }
                        guard let tag = string(value) else { throw ReadError.invalidResult }
                        tags.append(tag)
                    }
                    output[input.id] = .tags(tags)
                } else if let tag = string(node) {
                    output[input.id] = .tags([tag])
                } else {
                    throw ReadError.invalidResult
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                output[input.id] = .invalid(L10n.tr("无法读取 YAML 标签"))
            }
            if isCancelled() { throw CancellationError() }
        }
        if isCancelled() { throw CancellationError() }
        return output
    }
}

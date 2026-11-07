import Foundation

/// Верхнеуровневые блоки Markdown-документа: по ним локальный разбор (T5) находит участок вокруг правки.
/// Строит ядро разбора за тот же проход; позиции в UTF-16.
struct MarkdownBlockIndex: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph, heading, quote, list, table, codeFence, thematicBreak, other

        /// Блок, который локальный разбор умеет пересобирать; остальное (HTML, формулы, сноски, front matter, отступный код) разбирается целиком.
        var isLocal: Bool { self != .other }
    }

    struct Block: Equatable, Sendable {
        /// Целые строки блока, включая конечный перевод строки. Между блоками остаются только пустые строки.
        var range: NSRange
        var kind: Kind
        /// Сколько фрагментов читаемого текста набрано к концу блока (нарастающим итогом); 0, если читаемый текст не строился.
        var readableEnd: Int
    }

    var blocks: [Block]
    var textLength: Int
    /// В документе есть HTML (или его состояние не удалось проследить): разбор HTML связывает блоки между собой.
    let hasHTML: Bool
    let hasFrontMatter: Bool
    /// Читаемый текст построен с узлами без подтверждённой позиции: их диапазоны зависят от длины всего документа, локальный разбор не применяется.
    var hasUnconfirmedReadable = false

    /// Индекс после замены участка: блоки до `kept.lowerBound` остаются, блоки `fragment` (в координатах нового текста) занимают место
    /// `kept`, блоки от `kept.upperBound` сдвигаются на `delta`.
    func replacing(_ kept: Range<Int>, with fragment: [Block], delta: Int, readableDelta: Int) -> MarkdownBlockIndex {
        var result = Array(blocks[..<kept.lowerBound])
        let base = kept.lowerBound > 0 ? blocks[kept.lowerBound - 1].readableEnd : 0
        result.append(contentsOf: fragment.map { Block(range: $0.range, kind: $0.kind, readableEnd: $0.readableEnd + base) })
        result.append(contentsOf: blocks[kept.upperBound...].map {
            Block(range: NSRange(location: $0.range.location + delta, length: $0.range.length), kind: $0.kind, readableEnd: $0.readableEnd + readableDelta)
        })
        return MarkdownBlockIndex(blocks: result, textLength: textLength + delta, hasHTML: hasHTML, hasFrontMatter: hasFrontMatter, hasUnconfirmedReadable: hasUnconfirmedReadable)
    }
}

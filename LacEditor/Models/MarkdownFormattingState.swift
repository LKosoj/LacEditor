import Foundation

/// Оформление под выделением: по нему панель форматирования подсвечивает кнопки.
/// Считается из готового разбора и выделения; блок — по началу выделения, строчные стили — только если элемент охватывает оба конца.
struct MarkdownFormattingState: Equatable, Sendable {
    enum Paragraph: Equatable, Sendable {
        case plain, heading(Int), quote, codeBlock, bulletList, numberedList, taskList, table
    }

    var paragraph: Paragraph = .plain
    var bold = false
    var italic = false
    var strikethrough = false
    var code = false
    var link = false

    init() {}

    init(presentation: MarkdownPresentation, selection: NSRange) {
        let start = selection.location, end = NSMaxRange(selection)
        guard presentation.elements.textLength > 0, start >= 0, end <= presentation.elements.textLength else { return }
        let path = presentation.elements.path(at: start, blocksOnly: true).elements
        // Приоритет: заголовок, код, пункт или задача, цитата, таблица.
        if let heading = path.last(where: { if case .heading = $0.kind { return true } else { return false } }),
           case let .heading(level) = heading.kind {
            paragraph = .heading(level)
        } else if path.contains(where: { if case .codeBlock = $0.kind { return true } else { return false } }) {
            paragraph = .codeBlock
        } else if let item = path.last(where: { $0.kind == .listItem || $0.kind == .task }) {
            if item.kind == .task {
                paragraph = .taskList
            } else {
                // Вид списка — по маркеру ближайшего пункта того же уровня вложенности.
                let marker = presentation.listMarkers.last { $0.range.location <= start && $0.depth <= item.level }
                paragraph = marker?.ordinal != nil ? .numberedList : .bulletList
            }
        } else if path.contains(where: { $0.kind == .quote || $0.kind == .alert }) {
            paragraph = .quote
        } else if path.contains(where: { $0.kind == .table }) {
            paragraph = .table
        }
        // Один проход по элементам: выполняется при каждом перемещении каретки.
        for span in presentation.spans {
            let range = span.range
            let covers = selection.length == 0 ? range.location < start && start < NSMaxRange(range)
                : range.location <= start && end <= NSMaxRange(range)
            guard covers else { continue }
            switch span.kind {
            case .strong: bold = true
            case .emphasis: italic = true
            case .strikethrough: strikethrough = true
            case .code: code = true
            case .link: link = true
            default: break
            }
        }
    }
}

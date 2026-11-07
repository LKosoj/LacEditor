import Foundation

/// Пример из `spec.txt` или `extensions.txt` вместе с ожидаемым HTML спецификации.
struct GFMSpecCase: Equatable {
    let number: Int
    let section: String
    let markdown: String
    let html: String
    /// Тег после `example`: autolink, table, strikethrough, tagfilter, disabled; пусто у обычных примеров.
    let tag: String

    var isDisabled: Bool { tag == "disabled" }
}

/// Читатель корпуса спецификации для сверки результата рендера с ожидаемым HTML.
enum GFMSpecReader {
    static var directory: URL { BaselinePaths.testsDirectory.appendingPathComponent("Fixtures/GFMSpec", isDirectory: true) }

    static func spec() throws -> [GFMSpecCase] {
        parse(try String(contentsOf: directory.appendingPathComponent("spec.txt"), encoding: .utf8))
    }

    static func extensions() throws -> [GFMSpecCase] {
        parse(try String(contentsOf: directory.appendingPathComponent("extensions.txt"), encoding: .utf8))
    }

    /// Формат upstream: ограждение из 32 обратных кавычек + ` example` [+ тег], Markdown, строка `.`, HTML, закрывающее ограждение.
    /// `→` в примерах обозначает табуляцию. Файлы только с `\n`.
    static func parse(_ text: String) -> [GFMSpecCase] {
        let fence = String(repeating: "`", count: 32)
        var cases: [GFMSpecCase] = []
        var section = "", tag = "", inMarkdown = false, inHTML = false
        var markdown: [String] = [], html: [String] = []
        func block(_ lines: [String]) -> String {
            lines.map { $0 + "\n" }.joined().replacingOccurrences(of: "→", with: "\t")
        }
        for line in text.components(separatedBy: "\n") {
            if inMarkdown {
                if line == "." { inMarkdown = false; inHTML = true; html = [] } else { markdown.append(line) }
            } else if inHTML {
                if line == fence {
                    inHTML = false
                    cases.append(GFMSpecCase(number: cases.count + 1, section: section, markdown: block(markdown), html: block(html), tag: tag))
                } else { html.append(line) }
            } else if line.hasPrefix(fence + " example") {
                inMarkdown = true; markdown = []
                tag = line.dropFirst(fence.count + " example".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                section = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            }
        }
        return cases
    }
}

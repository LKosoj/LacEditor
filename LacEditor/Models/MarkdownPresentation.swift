import Foundation

enum MarkdownPresentationKind: Equatable, Sendable {
    case heading(Int), strong, emphasis, strikethrough, code, link, quote, codeBlock
}

struct MarkdownPresentationSpan: Equatable, Sendable {
    let range: NSRange
    let kind: MarkdownPresentationKind
    let markerRanges: [NSRange]
}

struct MarkdownHeading: Identifiable, Equatable, Sendable {
    let level: Int
    let title: String
    let range: NSRange
    var id: Int { range.location }
}

struct MarkdownPresentation: Sendable {
    let spans: [MarkdownPresentationSpan]
    let headings: [MarkdownHeading]

    init(spans: [MarkdownPresentationSpan], headings: [MarkdownHeading] = []) {
        self.spans = spans
        self.headings = headings
    }
}

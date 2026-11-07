import Foundation

/// A limited, source-mapped projection of one selection from the full document.
/// Типы результата (`Run`, `Fragment`) и `Style` вынесены сюда без AppKit, чтобы их использовал проектор на модели
/// (`MarkdownClipboardProjector.swift`) и стенд Linux; остальное — в `MarkdownClipboardCopyService.swift`.
enum MarkdownClipboardCopyService {
    struct Run: Equatable, Sendable {
        let range: NSRange
        let bold: Bool
        let italic: Bool
        let strike: Bool
        let underline: Bool
        let highlight: Bool
        let script: Int
        let code: Bool
        let link: String?
        let inlineStyle: MarkdownInlineStyle?
    }
    struct Fragment: Sendable {
        struct StructuralPart: Sendable {
            enum Kind: Equatable, Sendable {
                case text, image, lineBreak, listItemStart, listItemEnd, emptyListItem
                case quoteStart, quoteEnd, headingStart, headingEnd, tableStart, tableEnd, cellStart, cellEnd, codeStart, codeEnd
                case taskMarker, thematicBreak
            }
            let text: String
            let quoteDepth: Int
            let listDepth: Int
            let headingLevel: Int?
            let tableCell: TableCell?
            let kind: Kind
        }
        struct TableCell: Sendable {
            let table: Int
            let row: Int
            let column: Int
        }
        struct RemoteImage: Sendable {
            let range: NSRange
            let url: URL
        }
        struct MathExpression: Sendable {
            let source: String
            let display: Bool
            let range: NSRange
        }
        struct MathImage: Sendable {
            let token: String
            let expressionIndex: Int
        }
        let text: String
        let html: String
        let runs: [Run]
        let imageLinks: [String?]
        let remoteImages: [RemoteImage]
        let structuralParts: [StructuralPart]
        let mathExpressions: [MathExpression]
        let mathImages: [MathImage]
        let hasUnverifiedHTMLBlocks: Bool

        init(text: String, html: String, runs: [Run], imageLinks: [String?] = [], remoteImages: [RemoteImage] = [], structuralParts: [StructuralPart] = [], mathExpressions: [MathExpression] = [], mathImages: [MathImage] = [], hasUnverifiedHTMLBlocks: Bool = false) {
            self.text = text
            self.html = html
            self.runs = runs
            self.imageLinks = imageLinks
            self.remoteImages = remoteImages
            self.structuralParts = structuralParts
            self.mathExpressions = mathExpressions
            self.mathImages = mathImages
            self.hasUnverifiedHTMLBlocks = hasUnverifiedHTMLBlocks
        }
    }

    /// Накопленное оформление строчных узлов при обходе (жирный, курсив, ссылка и т. п.).
    struct Style {
        var bold = false, italic = false, strike = false, underline = false, highlight = false, code = false, keyboard = false
        var script = 0
        var link: String?
        var inlineStyle: MarkdownInlineStyle?
    }
}

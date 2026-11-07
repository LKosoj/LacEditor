import Foundation

struct MarkdownSyntaxOptions: Equatable, Sendable {
    let strictMode: Bool
    let inlineMath: Bool
    let legacyInlineMath: Bool
    let smartPunctuation: Bool?
    let preserveEditingWhitespace: Bool?
    let preserveExportWhitespace: Bool
    let preserveEditingSoftBreaks: Bool
    let preserveExportSoftBreaks: Bool?

    init(strictMode: Bool = true, inlineMath: Bool = true, legacyInlineMath: Bool = false, smartPunctuation: Bool? = nil,
         preserveEditingWhitespace: Bool? = nil, preserveExportWhitespace: Bool = false,
         preserveEditingSoftBreaks: Bool = true, preserveExportSoftBreaks: Bool? = nil) {
        self.strictMode = strictMode
        self.inlineMath = inlineMath
        self.legacyInlineMath = legacyInlineMath
        self.smartPunctuation = smartPunctuation
        self.preserveEditingWhitespace = preserveEditingWhitespace
        self.preserveExportWhitespace = preserveExportWhitespace
        self.preserveEditingSoftBreaks = preserveEditingSoftBreaks
        self.preserveExportSoftBreaks = preserveExportSoftBreaks
    }
}

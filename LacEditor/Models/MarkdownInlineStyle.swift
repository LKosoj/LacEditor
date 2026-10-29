import Foundation

struct MarkdownInlineStyle: Equatable, Sendable {
    let foreground: MarkdownSRGBColor?
    let background: MarkdownSRGBColor?
    let fontSizeRem: Double?
    let hideOnExport: Bool

    init(foreground: MarkdownSRGBColor? = nil, background: MarkdownSRGBColor? = nil, fontSizeRem: Double? = nil, hideOnExport: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.fontSizeRem = fontSizeRem
        self.hideOnExport = hideOnExport
    }

    init?(css: String) {
        var foreground: MarkdownSRGBColor?, background: MarkdownSRGBColor?, size: Double?
        var hideOnExport = false
        for raw in css.split(separator: ";", omittingEmptySubsequences: false) {
            let declaration = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if declaration.isEmpty { continue }
            let parts = declaration.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty { continue }
            switch property {
            case "display":
                guard value == "none" else { return nil }
                hideOnExport = true
            case "color", "background", "background-color":
                let color: MarkdownSRGBColor
                switch value {
                case "red": color = MarkdownSRGBColor(red: 1, green: 0, blue: 0)!
                case "yellow": color = MarkdownSRGBColor(red: 1, green: 1, blue: 0)!
                default: return nil
                }
                if property == "color" { foreground = color } else { background = color }
            case "font-size":
                guard value.hasSuffix("rem") else { return nil }
                guard value.range(of: #"^[+-]?(?:[0-9]+|[0-9]*\.[0-9]+)(?:e[+-]?[0-9]+)?rem$"#, options: .regularExpression) != nil else { continue }
                guard let number = Double(value.dropLast(3)), number.isFinite else { return nil }
                if number < 0 { continue }
                guard number > 0, (number * 16).isFinite else { return nil }
                size = number
            default: return nil
            }
        }
        self.init(foreground: foreground, background: background, fontSizeRem: size, hideOnExport: hideOnExport)
    }

    func inheriting(_ parent: MarkdownInlineStyle) -> MarkdownInlineStyle {
        MarkdownInlineStyle(foreground: foreground ?? parent.foreground, background: background ?? parent.background,
                            fontSizeRem: fontSizeRem ?? parent.fontSizeRem, hideOnExport: hideOnExport || parent.hideOnExport)
    }

    var fontSize: Double? { fontSizeRem.map { $0 * 16 } }

    var css: String {
        [editingCSS, hideOnExport ? "display:none" : ""].filter { !$0.isEmpty }.joined(separator: ";")
    }

    var editingCSS: String {
        var values: [String] = []
        if let foreground { values.append("color:\(foreground.css)") }
        if let background { values.append("background-color:\(background.css)") }
        if let fontSizeRem { values.append("font-size:\(fontSizeRem)rem") }
        return values.joined(separator: ";")
    }
}

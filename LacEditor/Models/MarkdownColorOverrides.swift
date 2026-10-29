import Foundation
import AppKit

struct MarkdownSRGBColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let color = MarkdownSRGBColor(red: try values.decode(Double.self, forKey: .red),
            green: try values.decode(Double.self, forKey: .green), blue: try values.decode(Double.self, forKey: .blue),
            alpha: try values.decode(Double.self, forKey: .alpha)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid sRGB components"))
        }
        self = color
    }

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }

    var css: String { "rgba(\(red * 255),\(green * 255),\(blue * 255),\(alpha))" }
}

struct MarkdownColorOverrides: Codable, Equatable, Sendable {
    enum Field: String, CaseIterable, Identifiable {
        case text, background, link, codeBackground, quoteBackground
        var id: String { rawValue }
        var label: String {
            switch self {
            case .text: "正文颜色"
            case .background: "背景颜色"
            case .link: "链接颜色"
            case .codeBackground: "代码背景颜色"
            case .quoteBackground: "引用背景颜色"
            }
        }
    }

    var text: MarkdownSRGBColor?
    var background: MarkdownSRGBColor?
    var link: MarkdownSRGBColor?
    var codeBackground: MarkdownSRGBColor?
    var quoteBackground: MarkdownSRGBColor?

    subscript(field: Field) -> MarkdownSRGBColor? {
        get {
            switch field {
            case .text: text
            case .background: background
            case .link: link
            case .codeBackground: codeBackground
            case .quoteBackground: quoteBackground
            }
        }
        set {
            switch field {
            case .text: text = newValue
            case .background: background = newValue
            case .link: link = newValue
            case .codeBackground: codeBackground = newValue
            case .quoteBackground: quoteBackground = newValue
            }
        }
    }

    var cssVariables: [String: String] {
        var values: [String: String] = [:]
        if let text { values["--text"] = text.css }
        if let background { values["--page"] = background.css }
        if let link { values["--accent"] = link.css }
        if let codeBackground { values["--code"] = codeBackground.css }
        if let quoteBackground { values["--quote"] = quoteBackground.css }
        return values
    }

    var isEmpty: Bool { Field.allCases.allSatisfy { self[$0] == nil } }
}

import Foundation

/// Карта в виде SVG-строки: без внешних файлов и шрифтов, светлый фон независимо от темы приложения.
enum MindMapSVGExporter {
    static func svg(layout: MindMapLayoutResult, nodes: [MindMapNode], edges: [(Int, Int, MindMapEdgeStyle)], curved: Bool) -> String {
        let width = max(layout.size.width, 1), height = max(layout.size.height, 1)
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(width))\" height=\"\(number(height))\" viewBox=\"0 0 \(number(width)) \(number(height))\">\n"
        out += "<rect width=\"100%\" height=\"100%\" fill=\"#FFFFFF\"/>\n"
        for (from, to, style) in edges {
            guard let a = layout.placed[from]?.frame, let b = layout.placed[to]?.frame else { continue }
            let dash: String
            switch style {
            case .relation: dash = ""
            case .coMention: dash = " stroke-dasharray=\"6 4\""
            case .wikiLink: dash = " stroke-dasharray=\"2 4\""
            }
            let path: String
            if curved {
                let startX = a.maxX, startY = a.midY, endX = b.minX, endY = b.midY
                let middle = (startX + endX) / 2
                path = "M \(number(startX)) \(number(startY)) C \(number(middle)) \(number(startY)) \(number(middle)) \(number(endY)) \(number(endX)) \(number(endY))"
            } else {
                path = "M \(number(a.midX)) \(number(a.midY)) L \(number(b.midX)) \(number(b.midY))"
            }
            out += "<path d=\"\(path)\" fill=\"none\" stroke=\"#5A5A5A\" stroke-width=\"1.5\"\(dash)/>\n"
        }
        for node in nodes {
            guard let placed = layout.placed[node.id] else { continue }
            let frame = placed.frame
            out += "<g>\n<title>\(escape(node.title))</title>\n"
            out += "<rect x=\"\(number(frame.minX))\" y=\"\(number(frame.minY))\" width=\"\(number(frame.width))\" height=\"\(number(frame.height))\" rx=\"6\" fill=\"#F5F5F7\" stroke=\"#3C3C43\" stroke-width=\"1\"/>\n"
            let lineHeight = (frame.height - MindMapLayout.paddingY * 2) / CGFloat(max(placed.lines.count, 1))
            for (index, line) in placed.lines.enumerated() {
                let y = frame.minY + MindMapLayout.paddingY + lineHeight * (CGFloat(index) + 0.78)
                out += "<text x=\"\(number(frame.minX + MindMapLayout.paddingX))\" y=\"\(number(y))\" font-family=\"-apple-system, sans-serif\" font-size=\"13\" fill=\"#1D1D1F\">\(escape(line))</text>\n"
            }
            out += "</g>\n"
        }
        out += "</svg>\n"
        return out
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // Управляющие символы в XML недопустимы.
                if character.value < 32, character != "\n", character != "\t" { result += " " } else { result.unicodeScalars.append(character) }
            }
        }
        return result
    }

    private static func number(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
}

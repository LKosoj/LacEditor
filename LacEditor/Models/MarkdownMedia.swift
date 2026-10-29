import Foundation

struct MarkdownImageSizing: Equatable, Sendable {
    enum Dimension: Equatable, Sendable {
        case pixels(Double)
        case percent(Double)
    }
    let width: Dimension?
    let height: Dimension?
    let zoom: Double

    init(width: String?, height: String?, style: String?) {
        func number(_ value: String) -> Double? {
            guard !value.isEmpty, value.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == "." }),
                  let result = Double(value), result.isFinite, result >= 0 else { return nil }
            return result
        }
        func dimension(_ raw: String?, css: Bool = false) -> Dimension? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
            if value.hasSuffix("%"), let n = number(String(value.dropLast())) { return .percent(n) }
            let hasUnit = value.hasSuffix("px")
            let pixels = hasUnit ? String(value.dropLast(2)) : value
            guard let n = number(pixels), !css || hasUnit || n == 0 else { return nil }
            return .pixels(n)
        }
        var w = dimension(width), h = dimension(height), z = 1.0
        for declaration in (style ?? "").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key == "width", let parsed = dimension(value, css: true) { w = parsed }
            if key == "height", let parsed = dimension(value, css: true) { h = parsed }
            if key == "zoom" {
                let percent = value.hasSuffix("%")
                let raw = percent ? String(value.dropLast()) : value
                if let parsed = number(raw) { z = parsed == 0 ? 1 : (percent ? parsed / 100 : parsed) }
            }
        }
        self.width = w; self.height = h; self.zoom = z
    }

    func size(intrinsic: CGSize, availableWidth: CGFloat) -> CGSize? {
        func value(_ dimension: Dimension?, base: CGFloat?) -> CGFloat? {
            switch dimension {
            case .pixels(let pixels): return CGFloat(pixels)
            case .percent(let percent): return base.map { $0 * CGFloat(percent) / 100 }
            case nil: return nil
            }
        }
        let w = value(width, base: availableWidth), h = value(height, base: nil)
        var size = intrinsic
        if let w, let h { size = CGSize(width: w, height: h) }
        else if let w, intrinsic.width > 0 { size = CGSize(width: w, height: intrinsic.height * w / intrinsic.width) }
        else if let h, intrinsic.height > 0 { size = CGSize(width: intrinsic.width * h / intrinsic.height, height: h) }
        size.width *= CGFloat(zoom); size.height *= CGFloat(zoom)
        guard size.width.isFinite, size.height.isFinite, availableWidth.isFinite, availableWidth >= 0 else { return nil }
        if size.width > availableWidth, size.width > 0 {
            size.height *= availableWidth / size.width; size.width = availableWidth
        }
        return size.width.isFinite && size.height.isFinite ? size : nil
    }

    var css: String {
        func declaration(_ name: String, _ dimension: Dimension?) -> String {
            switch dimension {
            case .pixels(let value): return "\(name):\(value)px;"
            case .percent(let value): return "\(name):\(value)%;"
            case nil: return ""
            }
        }
        return declaration("width", width) + declaration("height", height) + (zoom == 1 ? "" : "zoom:\(zoom);")
    }
}

struct MarkdownEmbeddedMedia: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case audio, video }
    let kind: Kind
    let sources: [String]
    let controls: Bool
    let width: String?
    let height: String?
}

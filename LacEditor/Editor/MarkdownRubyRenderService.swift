import AppKit
import CoreText

@MainActor
enum MarkdownRubyRenderService {
    enum Orientation { case horizontal, vertical }
    @MainActor
    struct Rendering {
        let image: NSImage
        let advance: CGFloat
        /// Position of the base-text baseline in image coordinates, measured from the top left.
        let baseline: NSPoint
        let attributedBase: NSAttributedString
        let annotation: String
        let line: CTLine
        private let lineToImage: CGAffineTransform
        private let text: NSString

        fileprivate init(image: NSImage, advance: CGFloat, line: CTLine, lineToImage: CGAffineTransform, base: NSAttributedString, annotation: String) {
            self.image = image
            self.advance = advance
            self.baseline = CGPoint.zero.applying(lineToImage)
            self.line = line
            self.lineToImage = lineToImage
            self.attributedBase = NSAttributedString(attributedString: base)
            self.annotation = annotation
            self.text = base.string as NSString
        }

        func caretPositions(at index: Int) -> (primary: NSPoint, secondary: NSPoint)? {
            guard index >= 0, index <= text.length,
                  index == text.length || text.rangeOfComposedCharacterSequence(at: index).location == index else { return nil }
            var secondary: CGFloat = 0
            let primary = CTLineGetOffsetForStringIndex(line, index, &secondary)
            guard primary.isFinite, secondary.isFinite else { return nil }
            return (CGPoint(x: primary, y: 0).applying(lineToImage),
                    CGPoint(x: secondary, y: 0).applying(lineToImage))
        }

        func characterIndex(at point: NSPoint) -> Int? {
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= 0, point.y >= 0, point.x <= image.size.width, point.y <= image.size.height else { return nil }
            let position = point.applying(lineToImage.inverted())
            let index = CTLineGetStringIndexForPosition(line, position)
            guard index != kCFNotFound, index >= 0, index <= text.length else { return nil }
            if index == text.length { return index }
            let range = text.rangeOfComposedCharacterSequence(at: index)
            guard let start = caretPositions(at: range.location), let end = caretPositions(at: NSMaxRange(range)) else { return nil }
            func distance(_ left: NSPoint, _ right: NSPoint) -> CGFloat { hypot(left.x - right.x, left.y - right.y) }
            let startDistance = min(distance(start.primary, point), distance(start.secondary, point))
            let endDistance = min(distance(end.primary, point), distance(end.secondary, point))
            return startDistance <= endDistance ? range.location : NSMaxRange(range)
        }
    }

    /// Core Text rendering; source parsing and editor lifecycle are handled by callers.
    static func render(base: NSAttributedString, annotation: String, scale: CGFloat, availableSize: NSSize,
                       orientation: Orientation = .horizontal, annotationFont: NSFont? = nil,
                       annotationColor: NSColor? = nil) -> Rendering? {
        guard base.length > 0, !annotation.isEmpty, !base.string.utf8.contains(0), !annotation.utf8.contains(0),
              base.string.rangeOfCharacter(from: .newlines) == nil, annotation.rangeOfCharacter(from: .newlines) == nil,
              scale.isFinite, scale > 0, scale < CGFloat(Int.max), availableSize.width.isFinite, availableSize.height.isFinite,
              availableSize.width > 0, availableSize.height > 0 else { return nil }
        let prepared = NSMutableAttributedString(attributedString: base)
        var attributes: [(NSRange, [NSAttributedString.Key: Any])] = [], valid = true
        base.enumerateAttributes(in: NSRange(location: 0, length: base.length)) { values, range, _ in
            guard let font = values[.font] as? NSFont, font.pointSize.isFinite, font.pointSize > 0,
                  let color = (values[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) else { valid = false; return }
            attributes.append((range, [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]))
        }
        guard valid else { return nil }
        for (range, values) in attributes { prepared.addAttributes(values, range: range) }
        var rubyAttributes: [String: Any] = [kCTRubyAnnotationSizeFactorAttributeName as String: 0.5]
        if let annotationFont, let annotationColor = annotationColor?.usingColorSpace(.sRGB) {
            rubyAttributes[kCTFontAttributeName as String] = CTFontCreateCopyWithAttributes(annotationFont as CTFont, annotationFont.pointSize * 0.5, nil, nil)
            rubyAttributes[kCTForegroundColorAttributeName as String] = annotationColor.cgColor
        }
        let ruby = CTRubyAnnotationCreateWithAttributes(.auto, .none, .before, annotation as CFString, rubyAttributes as CFDictionary)
        prepared.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: ruby,
                              range: NSRange(location: 0, length: prepared.length))
        if orientation == .vertical {
            prepared.addAttribute(NSAttributedString.Key(kCTVerticalFormsAttributeName as String), value: true,
                                  range: NSRange(location: 0, length: prepared.length))
        }
        let frame: CTFrame?, line: CTLine, origin: CGPoint
        if orientation == .vertical {
            let setter = CTFramesetterCreateWithAttributedString(prepared as CFAttributedString)
            let path = CGPath(rect: CGRect(origin: .zero, size: availableSize), transform: nil)
            let options = [kCTFrameProgressionAttributeName as String: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            let value = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: prepared.length), path, options)
            let visible = CTFrameGetVisibleStringRange(value)
            let lines = CTFrameGetLines(value) as! [CTLine]
            guard visible.location == 0, visible.length == prepared.length, lines.count == 1,
                  let onlyLine = lines.first else { return nil }
            var point = CGPoint.zero
            CTFrameGetLineOrigins(value, CFRange(location: 0, length: 1), &point)
            guard point.x.isFinite, point.y.isFinite else { return nil }
            frame = value; line = onlyLine; origin = point
        } else {
            frame = nil; line = CTLineCreateWithAttributedString(prepared as CFAttributedString); origin = .zero
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard [advance, ascent, descent, leading].allSatisfy({ $0.isFinite }), advance > 0,
              let measurement = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        measurement.scaleBy(x: scale, y: scale)
        measurement.textMatrix = .identity
        measurement.textPosition = .zero
        let ink = CTLineGetImageBounds(line, measurement)
        guard !ink.isNull, [ink.minX, ink.minY, ink.width, ink.height].allSatisfy({ $0.isFinite }) else { return nil }
        let typographic = CGRect(x: 0, y: -descent, width: advance, height: ascent + descent + max(0, leading))
        let lineBounds = typographic.union(ink)
        let toFrame = orientation == .vertical
            ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: origin.x, ty: origin.y)
            : .identity
        let frameInk = ink.applying(toFrame)
        guard [frameInk.minX, frameInk.minY, frameInk.width, frameInk.height].allSatisfy({ $0.isFinite }),
              orientation != .vertical || CGRect(origin: .zero, size: availableSize).contains(frameInk) else { return nil }
        let bounds = lineBounds.applying(toFrame).integral.insetBy(dx: -1, dy: -1)
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }), bounds.width > 0, bounds.height > 0,
              bounds.width <= availableSize.width, bounds.height <= availableSize.height else { return nil }
        let pixelWidth = ceil(bounds.width * scale), pixelHeight = ceil(bounds.height * scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0,
              pixelWidth < CGFloat(Int.max), pixelHeight < CGFloat(Int.max) else { return nil }
        let width = Int(pixelWidth), height = Int(pixelHeight)
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (_, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.textMatrix = .identity
        context.textPosition = .zero
        if let frame { CTFrameDraw(frame, context) } else { CTLineDraw(line, context) }
        guard let image = context.makeImage() else { return nil }
        let frameToImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -bounds.minX, ty: bounds.maxY)
        let lineToImage = toFrame.concatenating(frameToImage)
        let determinant = lineToImage.a * lineToImage.d - lineToImage.b * lineToImage.c
        guard determinant.isFinite, determinant != 0 else { return nil }
        return Rendering(image: NSImage(cgImage: image, size: bounds.size), advance: advance, line: line, lineToImage: lineToImage,
                         base: base, annotation: annotation)
    }
}

import AppKit
import CoreText
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownRubyRenderServiceTests: XCTestCase {
    private func base(_ text: String, font: NSFont? = nil) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                                                       .foregroundColor: NSColor.black])
    }

    private func render(_ value: NSAttributedString, annotation: String, scale: CGFloat = 2) throws -> MarkdownRubyRenderService.Rendering {
        try XCTUnwrap(MarkdownRubyRenderService.render(base: value, annotation: annotation, scale: scale,
                                                      availableSize: NSSize(width: 1200, height: 300)))
    }

    private func bitmap(_ value: MarkdownRubyRenderService.Rendering) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(value.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: image)
    }

    private func ink(_ image: NSBitmapImageRep, rows: Range<Int>? = nil) -> Int {
        var count = 0
        for y in rows ?? 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { count += 1 }
        }
        return count
    }

    func testRubyIsDrawnAboveItsBaseWithoutClipping() throws {
        let value = base("AB")
        let result = try render(value, annotation: "long annotation")
        let image = try bitmap(result)
        let font = try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let annotationBand = Int(floor((result.baseline.y - font.ascender) * 2))
        XCTAssertGreaterThan(annotationBand, 1)
        XCTAssertGreaterThan(ink(image, rows: 0..<min(annotationBand, image.pixelsHigh)), 0)
        XCTAssertGreaterThan(ink(image), 0)
        XCTAssertEqual(ink(image, rows: 0..<1), 0)
        XCTAssertEqual(ink(image, rows: image.pixelsHigh - 1..<image.pixelsHigh), 0)
        for y in 0..<image.pixelsHigh {
            XCTAssertLessThanOrEqual(image.colorAt(x: 0, y: y)?.alphaComponent ?? 0, 0.05)
            XCTAssertLessThanOrEqual(image.colorAt(x: image.pixelsWide - 1, y: y)?.alphaComponent ?? 0, 0.05)
        }
        XCTAssertEqual(result.attributedBase.string, "AB")
        XCTAssertEqual(result.annotation, "long annotation")
    }

    func testStyledBaseKeepsAnnotationColorAndFontSeparate() throws {
        let font = NSFont.systemFont(ofSize: 24)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let value = NSMutableAttributedString(string: "AB", attributes: [.font: bold, .foregroundColor: NSColor.red])
        value.addAttribute(.font, value: italic, range: NSRange(location: 1, length: 1))
        let result = try XCTUnwrap(MarkdownRubyRenderService.render(base: value, annotation: "reading", scale: 2,
            availableSize: NSSize(width: 1200, height: 300), annotationFont: font, annotationColor: .black))
        let image = try bitmap(result)
        let annotationEnd = min(image.pixelsHigh, max(0, Int(floor((result.baseline.y - font.ascender) * 2))))
        XCTAssertGreaterThan(annotationEnd, 0)
        var blackAnnotation = 0, redBase = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.2 else { continue }
                if y < annotationEnd && pixel.redComponent < 0.3 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3 { blackAnnotation += 1 }
                if y >= annotationEnd && pixel.redComponent > 0.7 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3 { redBase += 1 }
            }
        }
        XCTAssertGreaterThan(blackAnnotation, 0)
        XCTAssertGreaterThan(redBase, 0)
        XCTAssertEqual(result.attributedBase.string, "AB")
    }

    func testBackingScaleKeepsLogicalAdvanceAndComposedCaretBoundaries() throws {
        let value = base("漢😀e\u{301}")
        let one = try render(value, annotation: "annotation", scale: 1)
        let two = try render(value, annotation: "annotation", scale: 2)
        XCTAssertEqual(one.advance, two.advance, accuracy: 0.001)
        XCTAssertGreaterThan(try bitmap(two).pixelsWide, try bitmap(one).pixelsWide)
        let raw = value.string as NSString
        for index in [0, 1, 3, raw.length] {
            let position = try XCTUnwrap(two.caretPositions(at: index))
            let actual = try XCTUnwrap(two.characterIndex(at: position.primary))
            XCTAssertTrue(actual == raw.length || raw.rangeOfComposedCharacterSequence(at: actual).location == actual)
        }
        XCTAssertNil(two.caretPositions(at: 2))
        XCTAssertNil(two.caretPositions(at: 4))
        XCTAssertNil(two.characterIndex(at: NSPoint(x: CGFloat.nan, y: 0)))
    }

    func testOriginalFontDescriptorAndFeaturesReachCoreText() throws {
        let original = NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        let feature: [NSFontDescriptor.FeatureKey: Any] = [
            .typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector
        ]
        let font = try XCTUnwrap(NSFont(descriptor: original.fontDescriptor.addingAttributes([.featureSettings: [feature]]), size: 24))
        let result = try render(base("abc", font: font), annotation: "ABC")
        let runs = CTLineGetGlyphRuns(result.line) as! [CTRun]
        let run = try XCTUnwrap(runs.first)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let actual = try XCTUnwrap(attributes.object(forKey: kCTFontAttributeName) as? NSFont)
        XCTAssertEqual(actual.fontDescriptor.fontAttributes as NSDictionary, font.fontDescriptor.fontAttributes as NSDictionary)
    }

    func testVerticalRubyRetainsInkAndComposedCaretPositions() throws {
        let value = base("漢😀e\u{301}")
        var advances: [CGFloat] = []
        for scale in [CGFloat(1), 2] {
            let result = try XCTUnwrap(MarkdownRubyRenderService.render(base: value, annotation: "long annotation", scale: scale,
                availableSize: NSSize(width: 600, height: 600), orientation: .vertical))
            advances.append(result.advance)
            let image = try bitmap(result)
            XCTAssertGreaterThan(ink(image), 0)
            let annotationStart = min(image.pixelsWide, max(0, Int(ceil((result.baseline.x + 2) * scale))))
            var annotationInk = 0
            for y in 0..<image.pixelsHigh {
                for x in annotationStart..<image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { annotationInk += 1 }
            }
            XCTAssertGreaterThan(annotationInk, 0)
            let blank = try XCTUnwrap(MarkdownRubyRenderService.render(base: value, annotation: " ", scale: scale,
                availableSize: NSSize(width: 600, height: 600), orientation: .vertical))
            let blankImage = try bitmap(blank)
            let blankStart = min(blankImage.pixelsWide, max(0, Int(ceil((blank.baseline.x + 2) * scale))))
            var blankInk = 0
            for y in 0..<blankImage.pixelsHigh {
                for x in blankStart..<blankImage.pixelsWide where (blankImage.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { blankInk += 1 }
            }
            XCTAssertGreaterThan(annotationInk, blankInk)
            let prepared = NSMutableAttributedString(attributedString: value)
            let font = try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            let all = NSRange(location: 0, length: prepared.length)
            prepared.addAttributes([NSAttributedString.Key(kCTFontAttributeName as String): font,
                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
                                    NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true], range: all)
            let ruby = CTRubyAnnotationCreateWithAttributes(.auto, .none, .before, "long annotation" as CFString,
                [kCTRubyAnnotationSizeFactorAttributeName as String: 0.5] as CFDictionary)
            prepared.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: ruby, range: all)
            let setter = CTFramesetterCreateWithAttributedString(prepared as CFAttributedString)
            let path = CGPath(rect: CGRect(x: 100, y: 100, width: 400, height: 400), transform: nil)
            let options = [kCTFrameProgressionAttributeName as String: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: prepared.length), path, options)
            let pixelSize = Int(600 * scale)
            let context = try XCTUnwrap(CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity; context.textPosition = .zero
            CTFrameDraw(frame, context)
            let reference = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            let referenceInk = ink(reference)
            XCTAssertLessThanOrEqual(abs(ink(image) - referenceInk), max(2, referenceInk / 100))
            XCTAssertEqual(ink(image, rows: 0..<1), 0)
            XCTAssertEqual(ink(image, rows: image.pixelsHigh - 1..<image.pixelsHigh), 0)
            for y in 0..<image.pixelsHigh {
                XCTAssertLessThanOrEqual(image.colorAt(x: 0, y: y)?.alphaComponent ?? 0, 0.05)
                XCTAssertLessThanOrEqual(image.colorAt(x: image.pixelsWide - 1, y: y)?.alphaComponent ?? 0, 0.05)
            }
            let raw = value.string as NSString
            for index in [0, 1, 3, raw.length] {
                let caret = try XCTUnwrap(result.caretPositions(at: index))
                let actual = try XCTUnwrap(result.characterIndex(at: caret.primary))
                XCTAssertTrue(actual == raw.length || raw.rangeOfComposedCharacterSequence(at: actual).location == actual)
                XCTAssertEqual(actual, index)
            }
            XCTAssertNil(result.caretPositions(at: 2))
            XCTAssertEqual(result.attributedBase.string, value.string)
            XCTAssertEqual(result.annotation, "long annotation")
        }
        XCTAssertEqual(advances[0], advances[1], accuracy: 0.001)
        let rtl = try XCTUnwrap(MarkdownRubyRenderService.render(base: base("עברית漢"), annotation: "reading", scale: 2,
            availableSize: NSSize(width: 600, height: 600), orientation: .vertical))
        let rtlStart = try XCTUnwrap(rtl.caretPositions(at: 0))
        XCTAssertNotNil(rtl.characterIndex(at: rtlStart.primary))
        XCTAssertNil(MarkdownRubyRenderService.render(base: value, annotation: "long annotation", scale: 2,
            availableSize: NSSize(width: 1, height: 1), orientation: .vertical))
    }

    func testInvalidOrUnavailableGeometryDoesNotProduceAnImage() {
        let value = base("漢")
        for (scale, size) in [(CGFloat.nan, NSSize(width: 100, height: 100)),
                              (0, NSSize(width: 100, height: 100)),
                              (2, NSSize(width: 1, height: 1)),
                              (2, NSSize(width: CGFloat.infinity, height: 100)),
                              (CGFloat.greatestFiniteMagnitude, NSSize(width: 100, height: 100))] {
            XCTAssertNil(MarkdownRubyRenderService.render(base: value, annotation: "kan", scale: scale, availableSize: size))
        }
        XCTAssertNil(MarkdownRubyRenderService.render(base: base(""), annotation: "kan", scale: 2, availableSize: NSSize(width: 100, height: 100)))
        XCTAssertNil(MarkdownRubyRenderService.render(base: value, annotation: "", scale: 2, availableSize: NSSize(width: 100, height: 100)))
        XCTAssertNil(MarkdownRubyRenderService.render(base: base("first\nsecond"), annotation: "kan", scale: 2, availableSize: NSSize(width: 100, height: 100)))
    }
}

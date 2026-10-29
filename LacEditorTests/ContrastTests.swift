import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class ContrastTests: XCTestCase {
    private func luminance(_ color: NSColor, _ name: NSAppearance.Name) -> CGFloat {
        var result: CGFloat = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            result = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        return result
    }

    private func contrast(_ a: NSColor, _ b: NSColor, _ name: NSAppearance.Name) -> CGFloat {
        let la = luminance(a, name), lb = luminance(b, name)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testMutedAndCommentColorsMeetContrastOnEditorBackground() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertGreaterThanOrEqual(contrast(.lacMutedText, .lacEditorBackground, name), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(.lacCommentText, .lacEditorBackground, name), 4.5)
            XCTAssertGreaterThan(
                contrast(.labelColor, .lacEditorBackground, name),
                contrast(.lacMutedText, .lacEditorBackground, name)
            )
        }
    }

    func testRulerLabelIsRightAlignedWithGap() {
        let origin = LineNumberGeometry.labelOrigin(
            rulerWidth: 44, labelSize: NSSize(width: 20, height: 13), lineRect: NSRect(x: 0, y: 0, width: 44, height: 20)
        )
        XCTAssertEqual(origin.x, 16, accuracy: 0.001)
    }

    func testRulerThicknessGrowsWithDigits() {
        XCTAssertEqual(LineNumberGeometry.thickness(forLineCount: 99, digitWidth: 6.6), 44)
        XCTAssertEqual(LineNumberGeometry.thickness(forLineCount: 9_999, digitWidth: 6.6), 44)
        XCTAssertEqual(LineNumberGeometry.thickness(forLineCount: 12_345, digitWidth: 6.6), 49)
        XCTAssertEqual(LineNumberGeometry.thickness(forLineCount: 123_456, digitWidth: 6.6), 56)
    }

    func testRulerUpdateThicknessReportsChangeOnce() {
        let scroll = NSScrollView()
        let textView = NSTextView()
        scroll.documentView = textView
        let ruler = LineNumberRulerView(scrollView: scroll, textView: textView)
        XCTAssertTrue(ruler.updateThickness(lineCount: 123_456))
        XCTAssertFalse(ruler.updateThickness(lineCount: 123_456))
        XCTAssertGreaterThan(ruler.ruleThickness, 44)
    }

    func testTitlePathMenuComponents() {
        let urls = TitlePathMenu.components(for: URL(fileURLWithPath: "/Users/x/a/b.md"))
        XCTAssertEqual(urls.map(\.path), ["/Users/x/a/b.md", "/Users/x/a", "/Users/x", "/Users", "/"])
        XCTAssertEqual(TitlePathMenu.components(for: nil), [])
        XCTAssertEqual(TitlePathMenu.components(for: URL(string: "https://example.com/a")), [])
    }

    func testAccentColorAssetHasNoFixedColor() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor/Assets.xcassets/AccentColor.colorset/Contents.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        let colors = json?["colors"] as? [[String: Any]] ?? []
        XCTAssertTrue(colors.allSatisfy { $0["color"] == nil })
    }
}

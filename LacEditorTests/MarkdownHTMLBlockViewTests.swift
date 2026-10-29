import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownHTMLBlockViewTests: XCTestCase {
    func testNativeBlockMeasuresAndRendersText() throws {
        _ = NSApplication.shared
        let view = MarkdownHTMLBlockView(frame: .zero)
        XCTAssertTrue(view.configure(confirmedHTML: "<div><p>中文 😀 text</p><p>second</p></div>",
                                     font: .systemFont(ofSize: 18), foreground: .black))
        let wide = try XCTUnwrap(view.measuredSize(width: 300))
        let narrow = try XCTUnwrap(view.measuredSize(width: 70))
        XCTAssertGreaterThan(wide.height, 0)
        XCTAssertGreaterThanOrEqual(narrow.height, wide.height)
        view.frame = NSRect(origin: .zero, size: narrow)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { view.invalidate(); window.close() }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let blank = NSView(frame: view.frame); window.contentView = blank
        let empty = try XCTUnwrap(blank.bitmapImageRepForCachingDisplay(in: blank.bounds))
        blank.cacheDisplay(in: blank.bounds, to: empty)
        let pixels = try XCTUnwrap(bitmap.bitmapData), emptyPixels = try XCTUnwrap(empty.bitmapData)
        XCTAssertEqual(bitmap.bytesPerRow * bitmap.pixelsHigh, empty.bytesPerRow * empty.pixelsHigh)
        XCTAssertNotEqual(Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh),
                          Data(bytes: emptyPixels, count: empty.bytesPerRow * empty.pixelsHigh))
    }

    func testNativeTableUsesTextLayoutAtDifferentWidths() throws {
        _ = NSApplication.shared
        let view = MarkdownHTMLBlockView(frame: .zero)
        XCTAssertTrue(view.configure(confirmedHTML: "<table><tr><th>Header</th><td>中文 😀</td></tr><tr><td>A</td><td>B</td></tr></table>",
                                     font: .systemFont(ofSize: 16), foreground: .black))
        let wide = try XCTUnwrap(view.measuredSize(width: 300))
        let narrow = try XCTUnwrap(view.measuredSize(width: 100))
        XCTAssertGreaterThan(wide.height, 0)
        XCTAssertGreaterThanOrEqual(narrow.height, wide.height)
    }

    func testCommandClickRevealsSourceAndInvalidatedViewDropsCallbacks() throws {
        _ = NSApplication.shared
        let view = MarkdownHTMLBlockView(frame: .zero)
        XCTAssertTrue(view.configure(confirmedHTML: "<p>text</p>", font: .systemFont(ofSize: 16), foreground: .black))
        view.frame = NSRect(origin: .zero, size: try XCTUnwrap(view.measuredSize(width: 300)))
        var reveals = 0
        view.revealSource = { reveals += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 2, y: 2),
                                                     modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(reveals, 1)
        view.invalidate()
        view.mouseDown(with: event)
        XCTAssertEqual(reveals, 1)
    }

    func testLinkAndNoninteractiveClickUseExistingCallbacks() throws {
        _ = NSApplication.shared
        let view = MarkdownHTMLBlockView(frame: .zero)
        XCTAssertTrue(view.configure(confirmedHTML: "<p><a href='relative.md'>link</a> tail</p>",
                                     font: .systemFont(ofSize: 16), foreground: .black))
        view.frame = NSRect(origin: .zero, size: try XCTUnwrap(view.measuredSize(width: 300)))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { view.invalidate(); window.close() }
        var address: String?, reveals = 0
        view.openLink = { address = $0 }; view.revealSource = { reveals += 1 }
        func click(_ point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
            let location = view.convert(point, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: modifiers,
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
        }
        try click(NSPoint(x: 3, y: 8))
        XCTAssertNil(address)
        XCTAssertEqual(reveals, 1)
        try click(NSPoint(x: 3, y: 8), modifiers: [.command])
        XCTAssertEqual(address, "relative.md")
        try click(NSPoint(x: 250, y: 8), modifiers: [.command])
        XCTAssertEqual(reveals, 2)
    }
}

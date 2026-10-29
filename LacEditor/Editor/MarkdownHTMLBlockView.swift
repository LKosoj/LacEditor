import AppKit

/// Displays confirmed HTML as noneditable text; the editor keeps the source.
final class MarkdownHTMLBlockView: NSView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(containerSize: .zero)
    var openLink: ((String) -> Void)?
    var revealSource: (() -> Void)?
    var click: (() -> Void)?
    var canInteract: (() -> Bool)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(confirmedHTML: String, font: NSFont, foreground: NSColor, linkColor: NSColor = .linkColor,
                   codeFont: NSFont? = nil, paragraphStyle: NSParagraphStyle? = nil) -> Bool {
        guard let value = MarkdownHTMLMediaService.nativeHTMLContent(confirmedHTML, font: font, foreground: foreground, linkColor: linkColor,
                                                                    codeFont: codeFont, paragraphStyle: paragraphStyle, isCancelled: { false }) else { return false }
        storage.setAttributedString(value)
        needsDisplay = true
        return true
    }

    func measuredSize(width: CGFloat) -> NSSize? {
        guard width.isFinite, width > 0 else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let rect = layout.usedRect(for: container)
        guard rect.height.isFinite, rect.height > 0 else { return nil }
        return NSSize(width: width, height: ceil(rect.maxY))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    override func mouseDown(with event: NSEvent) {
        guard canInteract?() != false else { return }
        guard event.modifierFlags.contains(.command) else { (click ?? revealSource)?(); return }
        let point = convert(event.locationInWindow, from: nil)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndex(for: point, in: container)
        if glyph < layout.numberOfGlyphs,
           layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) {
            let index = layout.characterIndexForGlyph(at: glyph)
            if index < storage.length, let address = storage.attribute(.link, at: index, effectiveRange: nil) as? String {
                openLink?(address); return
            }
        }
        revealSource?()
    }

    func invalidate() {
        openLink = nil; revealSource = nil; click = nil; canInteract = nil
        storage.setAttributedString(NSAttributedString(string: ""))
    }
}

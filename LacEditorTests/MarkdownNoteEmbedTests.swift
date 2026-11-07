import XCTest
@testable import LacEditor

final class MarkdownNoteEmbedTests: XCTestCase {
    private var suite: String?
    private let syntax = MarkdownSyntaxOptions()

    /// Заглушка хранилища: имя → текст; считает обращения.
    private final class StubProvider: MarkdownNoteEmbedProvider, @unchecked Sendable {
        private let lock = NSLock()
        private let notes: [String: String]
        private let addresses: [String: String]
        private var reads: [String] = []
        init(_ notes: [String: String], addresses: [String: String] = [:]) { self.notes = notes; self.addresses = addresses }
        var readLog: [String] { lock.lock(); defer { lock.unlock() }; return reads }
        func embeddedNote(for target: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            reads.append(target)
            return notes[target]
        }
        func openAddress(for target: String, heading: String?) -> String? { addresses[target] }
    }

    override func setUp() {
        super.setUp()
        use("en")
    }

    override func tearDown() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        L10n.configure()
        super.tearDown()
    }

    private func use(_ language: String) {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let name = "MarkdownNoteEmbedTests-\(UUID().uuidString)"
        suite = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(language, forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownNoteEmbedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func items(_ text: String) -> [MarkdownNoteEmbedItem] {
        MarkdownNoteEmbed.items(in: text as NSString, excluded: [])
    }

    private func render(_ text: String, provider: StubProvider?, forExport: Bool = false, vault: Bool = false) -> String {
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: nil, paths: []), documentURL: nil)
        let url = vault ? VaultStateStore.defaultRoot(vaultID: UUID()).appendingPathComponent("open/note.md") : nil
        return MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: url, forExport: forExport, wiki: provider == nil ? nil : context, embeds: provider).body
    }

    // MARK: Поиск

    func testFindsEmbeds() {
        let found = items("![[a]] ![[a#Раздел]] ![[a|псевдоним]] ![[папка/a]] ![[a#Раздел|псевдоним]]")
        XCTAssertEqual(found.map(\.target), ["a", "a", "a", "папка/a", "a"])
        XCTAssertEqual(found.map(\.heading), [nil, "Раздел", nil, nil, "Раздел"])
        XCTAssertEqual(found.map(\.alias), [nil, nil, "псевдоним", nil, "псевдоним"])
        XCTAssertEqual(found[0].range, NSRange(location: 0, length: 6))
    }

    func testNonEmbeds() {
        for text in ["[[a]]", "!\\[[a]]", "![[a", "![[a\nb]]", "![[]]", "![[ ]]", "\\![[a]]", "![[a\\b]]", "![[a]"] {
            XCTAssertTrue(items(text).isEmpty, text)
        }
        let code = "`![[a]]`" as NSString
        XCTAssertTrue(MarkdownNoteEmbed.items(in: code, excluded: [NSRange(location: 0, length: code.length)]).isEmpty)
    }

    func testKinds() {
        for target in ["a", "a.md", "a.markdown", "a.MD"] { XCTAssertEqual(MarkdownNoteEmbed.kind(forTarget: target), .note, target) }
        for target in ["x.PNG", "x.jpg", "x.svg", "x.webp"] { XCTAssertEqual(MarkdownNoteEmbed.kind(forTarget: target), .image, target) }
        for target in ["x.pdf", "x.mp3"] { XCTAssertEqual(MarkdownNoteEmbed.kind(forTarget: target), .attachment, target) }
    }

    func testDottedNoteNamesAreNotAttachments() {
        for target in ["Встреча 2026.11.03", "v1.2 заметки"] { XCTAssertEqual(MarkdownNoteEmbed.kind(forTarget: target), .note, target) }
        XCTAssertEqual(MarkdownNoteEmbed.kind(forTarget: "x.mp3"), .attachment)
        XCTAssertEqual(MarkdownNoteEmbed.kind(forTarget: "x.mp4"), .attachment)
        let html = render("![[v1.2 заметки]]", provider: StubProvider([:]))
        XCTAssertTrue(html.contains("Note not found: v1.2 заметки"))
    }

    func testEmbeddedNoteCannotForgeMarker() {
        let provider = StubProvider(["a": "text LACEMBED1Z end", "b": "second"])
        let html = render("![[a]]\n\n![[b]]", provider: provider)
        XCTAssertTrue(html.contains("LACEMBED1Z end"))
        XCTAssertTrue(html.contains("second"))
        XCTAssertEqual(html.components(separatedBy: "<section class=\"lac-embed\"").count - 1, 2)
    }

    func testBlockDetection() {
        XCTAssertTrue(items("![[a]]")[0].isBlock)
        XCTAssertTrue(items("text\n\n![[a]]\n\nmore")[0].isBlock)
        XCTAssertTrue(items("   ![[a]]  \n")[0].isBlock)
        XCTAssertFalse(items("text ![[a]] text")[0].isBlock)
        XCTAssertFalse(items("- ![[a]]")[0].isBlock)
        XCTAssertFalse(items("> ![[a]]")[0].isBlock)
        XCTAssertFalse(items("    ![[a]]")[0].isBlock)
        XCTAssertFalse(items("text\n![[a]]")[0].isBlock)
        XCTAssertFalse(items("![[a]]\ntext")[0].isBlock)
    }

    // MARK: Разделы

    func testSection() {
        let note = "intro\n\n# Top\ntop text\n## Sub\nsub text\n### Deep\ndeep text\n## Next\nnext text\n# Other\nother"
        XCTAssertEqual(MarkdownNoteEmbed.section(of: note, heading: "Top"), "# Top\ntop text\n## Sub\nsub text\n### Deep\ndeep text\n## Next\nnext text")
        XCTAssertEqual(MarkdownNoteEmbed.section(of: note, heading: "sub"), "## Sub\nsub text\n### Deep\ndeep text")
        XCTAssertEqual(MarkdownNoteEmbed.section(of: note, heading: "Other"), "# Other\nother")
        XCTAssertEqual(MarkdownNoteEmbed.section(of: note, heading: "Top#Sub"), "## Sub\nsub text\n### Deep\ndeep text")
        XCTAssertNil(MarkdownNoteEmbed.section(of: note, heading: "Missing"))
        XCTAssertNil(MarkdownNoteEmbed.section(of: note, heading: "^block-id"))
    }

    func testSectionSkipsFencedHeadings() {
        let note = "# A\n```\n# Fake\n```\ntext\n# B"
        XCTAssertEqual(MarkdownNoteEmbed.section(of: note, heading: "A"), "# A\n```\n# Fake\n```\ntext")
        XCTAssertNil(MarkdownNoteEmbed.section(of: note, heading: "Fake"))
    }

    func testBodyDropsFrontMatter() {
        XCTAssertEqual(MarkdownNoteEmbed.body(of: "---\ntitle: x\n---\nBody"), "Body")
        XCTAssertEqual(MarkdownNoteEmbed.body(of: "No front matter"), "No front matter")
    }

    // MARK: Подстановка

    func testEmbedKeepsLineNumbersOfNeighbours() {
        let provider = StubProvider(["a": "text"])
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: nil, paths: []), documentURL: nil)
        let text = "one\n\n![[a]]\n\nthree\n![[x.png]]\n"
        let html = MarkdownHTMLRenderer.renderPage(text, darkMode: false, includeSourcePositions: true, wiki: context, embeds: provider).body
        XCTAssertEqual(html.components(separatedBy: "class=\"lac-embed\"").count - 1, 1, html)
        XCTAssertFalse(html.contains("![[a]]"), html)
        // Строки соседних абзацев прежние: «one» на 1-й, «three» с 5-й.
        XCTAssertTrue(html.contains("data-sourcepos=\"1:1-1:3\""), html)
        XCTAssertTrue(html.contains("data-sourcepos=\"5:1-"), html)
    }

    func testEmbedRendersCard() {
        let provider = StubProvider(["План": "Hello **world**"], addresses: ["План": "plan.md"])
        let html = render("before\n\n![[План]]\n\nafter", provider: provider)
        XCTAssertTrue(html.contains("<section class=\"lac-embed\" role=\"group\" aria-label=\"Embedded note: План\">"))
        XCTAssertTrue(html.contains("<span class=\"lac-embed-name\">План</span>"))
        XCTAssertTrue(html.contains("<a class=\"lac-embed-open\" href=\"plan.md\" aria-label=\"Open note: План\">Open</a>"))
        XCTAssertTrue(html.contains("Hello <strong>world</strong>"))
        XCTAssertTrue(html.contains("before") && html.contains("after"))
        XCTAssertFalse(html.contains("LACEMBED"))
    }

    func testEmbedSectionAndMissing() {
        let provider = StubProvider(["n": "# One\nfirst\n# Two\nsecond"])
        let html = render("![[n#Two]]\n\n![[n#Nope]]\n\n![[ghost]]", provider: provider)
        XCTAssertTrue(html.contains("<span class=\"lac-embed-name\">n › Two</span>"))
        XCTAssertTrue(html.contains("second"))
        XCTAssertFalse(html.contains("first"))
        XCTAssertTrue(html.contains("Section not found: n › Nope"))
        XCTAssertTrue(html.contains("Note not found: ghost"))
        XCTAssertTrue(html.contains("lac-embed-missing"))
    }

    func testEmbedWithoutProviderStaysText() {
        let html = render("![[a]]", provider: nil)
        XCTAssertTrue(html.contains("![[a]]"))
        XCTAssertFalse(html.contains("lac-embed"))
    }

    func testFrontMatterOfEmbeddedNoteIsDropped() {
        let provider = StubProvider(["a": "---\nsecret: yes\n---\nBody text"])
        let html = render("![[a]]", provider: provider)
        XCTAssertTrue(html.contains("Body text"))
        XCTAssertFalse(html.contains("secret"))
    }

    func testDepthIsOne() {
        let provider = StubProvider(["A": "A text ![[B]]\n\n![[B]]", "B": "B text\n\n![[A]]", "C": "C text\n\n![[D]]", "D": "D text"])
        let first = render("![[B]]", provider: provider)
        XCTAssertTrue(first.contains("B text"))
        XCTAssertTrue(first.contains("![[A]]"))
        XCTAssertEqual(first.components(separatedBy: "lac-embed\"").count - 1, 1)
        let selfEmbed = render("![[A]]", provider: provider)
        XCTAssertEqual(selfEmbed.components(separatedBy: "<section class=\"lac-embed\"").count - 1, 1)
        let chain = render("![[C]]", provider: provider)
        XCTAssertTrue(chain.contains("![[D]]"))
        XCTAssertFalse(chain.contains("D text"))
    }

    func testLimits() {
        let provider = StubProvider(["a": "text", "big": String(repeating: "line of text\n", count: 10_000)])
        let many = (0..<21).map { _ in "![[a]]" }.joined(separator: "\n\n")
        let html = render(many, provider: provider)
        XCTAssertEqual(html.components(separatedBy: "<section class=\"lac-embed\"").count - 1, 20)
        XCTAssertEqual(html.components(separatedBy: "Note not found: a").count - 1, 2)
        XCTAssertEqual(provider.readLog.count, 1, "одна цель читается один раз")
        let big = render("![[big]]", provider: provider)
        XCTAssertTrue(big.contains("Embedded content truncated"))
    }

    func testEmbeddedContentIsProcessed() {
        let note = "> [!warning] Careful\n> text\n\n%%hidden%% shown\n\n![pic](pic.png)\n\n# Heading\n\n[[wiki]]\n\n$x^2$"
        let html = render("![[a]]", provider: StubProvider(["a": note]), vault: true)
        XCTAssertTrue(html.contains("lac-callout-warning"))
        XCTAssertFalse(html.contains("%%") || html.contains(">hidden"), html)
        XCTAssertTrue(html.contains("shown"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("pic"))
        XCTAssertFalse(html.contains(" id=\"lac-heading"), html)
        XCTAssertTrue(html.contains("[[wiki]]"))
    }

    func testExportContainsEmbed() {
        let provider = StubProvider(["a": "export text"], addresses: ["a": "../a.md"])
        let html = render("![[a]]", provider: provider, forExport: true)
        XCTAssertTrue(html.contains("export text"))
        XCTAssertTrue(html.contains("href=\"../a.md\""))
    }

    func testTextsFollowInterfaceLanguage() {
        for language in ["en", "ru", "zh-Hans"] {
            use(language)
            let html = render("![[Заметка 🙂]]", provider: StubProvider([:]))
            XCTAssertTrue(html.contains(L10n.tr("未找到笔记：%@", "Заметка 🙂")), language)
        }
        use("ru")
        XCTAssertTrue(render("![[x]]", provider: StubProvider([:])).contains("Заметка не найдена: x"))
    }

    // MARK: Картинки и вложения

    func testImagesAndAttachments() throws {
        let directory = try temporaryDirectory()
        try Data([1]).write(to: directory.appendingPathComponent("pic.png"))
        try Data([1]).write(to: directory.appendingPathComponent("doc.pdf"))
        let document = directory.appendingPathComponent("note.md")
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: nil, paths: []), documentURL: nil)
        func page(_ text: String, url: URL? = document) -> String {
            MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: url, wiki: context).body
        }
        let image = page("a ![[pic.png]] b")
        XCTAssertTrue(image.contains("<img src=\"pic.png\" alt=\"pic.png\" />"), image)
        XCTAssertTrue(image.contains("a ") && image.contains(" b"), image)
        XCTAssertTrue(page("![[pic.png|300]]").contains("<img src=\"pic.png\" alt=\"pic.png\" />"))
        XCTAssertTrue(page("![[doc.pdf]]").contains("<a href=\"doc.pdf\">doc.pdf</a>"))
        XCTAssertTrue(page("![[missing.png]]").contains("<em>Attachment unavailable: missing.png</em>"))
        XCTAssertTrue(page("![[pic.png]]", url: nil).contains("<em>Attachment unavailable: pic.png</em>"))
        XCTAssertTrue(page("![[a*b_c].png]]").contains("<em>Attachment unavailable: a*b_c].png</em>"))
    }

    func testImageFromRootDirectory() throws {
        let root = try temporaryDirectory()
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("pic.png"))
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: root, paths: []), documentURL: sub.appendingPathComponent("n.md"))
        let result = MarkdownHTMLRenderer.renderPage("![[pic.png]]", darkMode: false, wiki: context).body
        XCTAssertTrue(result.contains("<img src=\"../pic.png\" alt=\"pic.png\" />"), result)
    }

    // MARK: Провайдер папки

    func testFolderProvider() throws {
        let root = try temporaryDirectory()
        try "Hello".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "One".write(to: root.appendingPathComponent("dup.md"), atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "Two".write(to: sub.appendingPathComponent("dup.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0xFD]).write(to: root.appendingPathComponent("binary.md"))
        try String(repeating: "x", count: 300).write(to: root.appendingPathComponent("long.md"), atomically: true, encoding: .utf8)
        let resolver = MarkdownWikiLinkResolver(base: root, paths: ["a.md", "dup.md", "sub/dup.md", "binary.md", "long.md"])
        let context = MarkdownWikiLinkContext(resolver: resolver, documentURL: root.appendingPathComponent("doc.md"))
        var provider = MarkdownFolderNoteEmbedProvider(context: context)
        XCTAssertEqual(provider.embeddedNote(for: "a"), "Hello")
        XCTAssertNil(provider.embeddedNote(for: "dup"), "неоднозначная цель")
        XCTAssertNil(provider.embeddedNote(for: "ghost"))
        XCTAssertNil(provider.embeddedNote(for: "../a"))
        XCTAssertNil(provider.embeddedNote(for: "binary"))
        provider.maxBytes = 100
        XCTAssertNil(provider.embeddedNote(for: "long"))
        XCTAssertEqual(provider.embeddedNote(for: "a"), "Hello")
        let link = MarkdownWikiLink(range: NSRange(location: 0, length: 0), displayRange: NSRange(location: 0, length: 0), target: "a", heading: "H", alias: nil, markerRanges: [])
        XCTAssertEqual(provider.openAddress(for: "a", heading: "H"), context.relativeHref(for: link))
        XCTAssertEqual(provider.openAddress(for: "a", heading: "H"), "a.md#h")
    }

    func testFolderProviderIgnoresSymlinkOutsideBase() throws {
        let outside = try temporaryDirectory()
        try "secret".write(to: outside.appendingPathComponent("out.md"), atomically: true, encoding: .utf8)
        let root = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside.appendingPathComponent("out.md"))
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: root, paths: ["link.md"]), documentURL: root.appendingPathComponent("d.md"))
        XCTAssertNil(MarkdownFolderNoteEmbedProvider(context: context).embeddedNote(for: "link"))
    }

    func testFolderProviderUsedByRenderer() throws {
        let root = try temporaryDirectory()
        try "From disk".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: root, paths: ["a.md"]), documentURL: root.appendingPathComponent("d.md"))
        let html = MarkdownHTMLRenderer.renderPage("![[a]]", darkMode: false, wiki: context).body
        XCTAssertTrue(html.contains("From disk"))
        XCTAssertTrue(html.contains("href=\"a.md\""))
    }
}

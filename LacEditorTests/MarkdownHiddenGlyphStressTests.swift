import AppKit
import XCTest
@testable import LacEditor

/// Стресс-тесты скрытия глифов (baseline этапа 0): длинные скрытые участки, строка из скрытых символов,
/// большой data URI, один документ в двух окнах. Проверяют, что раскладка остаётся конечной, строки не
/// пропадают и не налезают друг на друга, а текст не меняется. Время тяжёлых шагов меряется после вызова.
@MainActor
final class MarkdownHiddenGlyphStressTests: XCTestCase {
    override func setUpWithError() throws {
        // Зависший TextKit изнутри теста не прервать; лимит нужен, чтобы он не вешал весь прогон.
        executionTimeAllowance = 60
    }

    private let tallContainer = NSSize(width: 600, height: 10_000_000)

    // MARK: - Стенды

    /// Без окна и без презентации: `makeLayout` из `MarkdownLayoutTests` с высоким контейнером.
    private func makeLayout(_ source: String, width: CGFloat = 600) -> (NSTextStorage, FoldLayoutManager, NSTextContainer, LacTextView) {
        _ = NSApplication.shared
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: width, height: tallContainer.height))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: width, height: 300), textContainer: container)
        return (storage, layout, container, view)
    }

    /// Редактор с настоящим текстом в хранилище (без `Coordinator`): картинки `data:` ставит `MarkdownPresentationController`,
    /// как в `MarkdownImageTests.testDataImageIsDisplayedWithoutChangingSourceAndClearsAfterEdit`.
    @MainActor private final class ImageStand {
        let source: String
        let storage: NSTextStorage
        let layout = FoldLayoutManager()
        let container: NSTextContainer
        let view: LacTextView
        let scroll: NSScrollView
        let controller: MarkdownPresentationController
        let document: EditorDocument

        init(source: String, size: NSSize = NSSize(width: 400, height: 600)) {
            _ = NSApplication.shared
            self.source = source
            document = EditorDocument(text: source, language: .markdown)
            storage = NSTextStorage(string: source)
            storage.addLayoutManager(layout)
            container = NSTextContainer(containerSize: NSSize(width: size.width, height: 10_000_000))
            layout.addTextContainer(container)
            view = LacTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
            scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            view.setSelectedRange(NSRange(location: 0, length: 0))
            controller = MarkdownPresentationController(textView: view, layout: layout)
            controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
            controller.viewportChanged()
        }

        var images: [Int] { layout.markdownListsSnapshot["images"] ?? [] }

        func point(at location: Int) -> NSPoint {
            layout.ensureLayout(for: container)
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
            return NSPoint(x: rect.minX + container.lineFragmentPadding + 0.5, y: rect.minY + 0.5)
        }

        /// Ждёт, пока картинка с началом `location` будет установлена (опрос, как в соседних тестах).
        func waitForImage(at location: Int) async throws -> Bool {
            // Пока картинка не установлена, раскладку не трогаем: ~1 МБ видимых глифов в одной строке раскладывается очень долго.
            for _ in 0..<30 where images.isEmpty {
                controller.viewportChanged()
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !images.isEmpty else { return false }
            return layout.markdownImageLocation(at: point(at: location), in: container) == location
        }

        func finish() {
            controller.update(document: document, enabled: true, isActive: false, revision: 0, currentRevision: { 0 })
            controller.cancel()
            withExtendedLifetime(scroll) {}
        }
    }

    // MARK: - Общие проверки

    private func elapsed(_ work: () -> Void) -> Duration {
        ContinuousClock().measure(work)
    }

    /// Раскладка после скрытия: текст цел, у скрытого участка есть глифы, фрагменты конечны, идут сверху вниз и не налезают.
    private func assertLayoutIsSane(_ layout: FoldLayoutManager, _ container: NSTextContainer, _ storage: NSTextStorage, _ source: String,
                                    hidden: [NSRange] = [], minFragments: Int = 1, maxUsedHeight: CGFloat, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(storage.string, source, "\(message): текст не должен меняться", file: file, line: line)
        XCTAssertGreaterThan(layout.numberOfGlyphs, 0, message, file: file, line: line)
        for range in hidden {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // Глифов не обязательно столько же, сколько символов (суррогатная пара, `\r\n`), поэтому проверяется только их наличие.
            XCTAssertGreaterThan(glyphs.length, 0, "\(message): глифы скрытого участка \(range)", file: file, line: line)
        }
        var rects: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        XCTAssertGreaterThanOrEqual(rects.count, minFragments, "\(message): число фрагментов", file: file, line: line)
        var previous: NSRect?
        for (index, rect) in rects.enumerated() {
            let finite = rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            XCTAssertTrue(finite, "\(message): фрагмент \(index) конечен", file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.height, 0, "\(message): высота фрагмента \(index)", file: file, line: line)
            if let previous {
                XCTAssertGreaterThanOrEqual(rect.minY, previous.minY - 0.5, "\(message): фрагмент \(index) не выше предыдущего", file: file, line: line)
                if previous.height > 0, rect.height > 0 {
                    XCTAssertGreaterThanOrEqual(rect.minY, previous.maxY - 0.5, "\(message): фрагмент \(index) налезает на предыдущий", file: file, line: line)
                }
            }
            previous = rect
        }
        let used = layout.usedRect(for: container)
        XCTAssertTrue(used.height.isFinite, "\(message): usedRect конечен", file: file, line: line)
        XCTAssertLessThan(used.height, maxUsedHeight, "\(message): высота текста", file: file, line: line)
    }

    private func glyphProperty(_ layout: FoldLayoutManager, at character: Int) -> NSLayoutManager.GlyphProperty {
        layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: character))
    }

    private func lineRect(_ layout: FoldLayoutManager, at character: Int) -> NSRect {
        layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
    }

    /// Выборка символов payload: каждый `stride`-й плюс границы пакета глифов (0, 1, 8191, 8192, 8193) и три последних.
    private func payloadSample(length: Int, stride: Int) -> [Int] {
        var offsets = Set([0, 1, 8191, 8192, 8193].filter { $0 < length })
        offsets.formUnion(Swift.stride(from: 0, to: length, by: stride))
        offsets.formUnion((max(0, length - 3)..<length))
        return offsets.sorted()
    }

    private func base64PNG(_ size: Int) -> String {
        MarkdownBaselineDocuments.png(paddedTo: size).base64EncodedString()
    }

    private func payloadRange(in source: String) -> NSRange {
        let raw = source as NSString
        let start = NSMaxRange(raw.range(of: "base64,"))
        let end = raw.range(of: ")", options: [], range: NSRange(location: start, length: raw.length - start)).location
        return NSRange(location: start, length: end - start)
    }

    // MARK: - S1. Скрытый участок длиннее 8192 глифов подряд

    /// Свёртка 30 000+ символов одним диапазоном: все глифы скрыты, строка после неё встаёт вплотную, разворот возвращает текст.
    func testFoldedRangeLongerThanGlyphPacketIsCollapsedAndRestored() {
        let head = "head 中文\r\n"
        let body = (0..<1800).map { "тело строки \($0) 😀\r\n" }.joined()
        let source = head + body + "tail\r\n"
        let (storage, layout, container, view) = makeLayout(source)
        let raw = source as NSString
        let hidden = NSRange(location: (head as NSString).length, length: (body as NSString).length)
        XCTAssertGreaterThan(hidden.length, 8_192)
        let tailStart = raw.range(of: "tail").location

        layout.setFoldedRange(hidden)
        let time = elapsed { layout.ensureLayout(for: container) }
        XCTAssertLessThan(time, .seconds(10), "свёртка: время раскладки")
        for index in hidden.location..<NSMaxRange(hidden) {
            // Один assert на символ: по месту падения видно, где скрытие оборвалось.
            if glyphProperty(layout, at: index) != .null {
                XCTFail("свёртка: символ \(index) не скрыт")
                break
            }
        }
        let lineHeight = layout.editorLineHeight
        let headRect = lineRect(layout, at: 0)
        let tailRect = lineRect(layout, at: tailStart)
        XCTAssertLessThanOrEqual(tailRect.minY - headRect.minY, 2 * lineHeight + 1, "свёртка: tail стоит рядом с head")
        let glyphs = layout.glyphRange(forCharacterRange: hidden, actualCharacterRange: nil)
        XCTAssertLessThan(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0.5, "свёртка: ширина скрытого участка")
        let tailPoint = NSPoint(x: tailRect.minX + container.lineFragmentPadding + 0.5, y: tailRect.midY)
        XCTAssertGreaterThanOrEqual(layout.characterIndex(for: tailPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil), tailStart, "свёртка: попадание в tail")
        view.setSelectedRange(NSRange(location: tailStart, length: 0))
        XCTAssertEqual(view.selectedRange(), NSRange(location: tailStart, length: 0))
        let foldedHeight = layout.usedRect(for: container).height
        assertLayoutIsSane(layout, container, storage, source, hidden: [hidden], maxUsedHeight: 200, "свёртка")

        layout.setFoldedRange(nil)
        layout.ensureLayout(for: container)
        for index in stride(from: hidden.location, to: NSMaxRange(hidden), by: 997) where glyphProperty(layout, at: index) == .null {
            // Перевод строки может быть управляющим глифом, но не `.null`.
            XCTFail("разворот: символ \(index) остался скрытым")
            break
        }
        XCTAssertGreaterThan(layout.usedRect(for: container).height, max(1_000, foldedHeight * 100), "разворот: высота выросла")
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    /// Payload ~12 000 символов в одной строке под установленной картинкой скрыт целиком и не переносится на сотни строк.
    func testLongPayloadOnOneLineStaysHiddenBehindImage() async throws {
        let source = "head\n\n![x](data:image/png;base64,\(base64PNG(9_000)))\n\nafter"
        let stand = ImageStand(source: source)
        defer { stand.finish() }
        let raw = source as NSString
        let imageStart = raw.range(of: "![x](").location
        let ready = try await stand.waitForImage(at: imageStart)
        XCTAssertTrue(ready, "картинка установлена")
        let payload = payloadRange(in: source)
        XCTAssertGreaterThan(payload.length, 8_192)
        let time = elapsed { stand.layout.ensureLayout(for: stand.container) }
        XCTAssertLessThan(time, .seconds(10))
        for offset in payloadSample(length: payload.length, stride: 97) {
            XCTAssertEqual(glyphProperty(stand.layout, at: payload.location + offset), .null, "payload: смещение \(offset)")
        }
        let imageRect = lineRect(stand.layout, at: imageStart)
        let afterRect = lineRect(stand.layout, at: raw.range(of: "after").location)
        XCTAssertGreaterThan(afterRect.minY, imageRect.minY, "after ниже картинки")
        assertLayoutIsSane(stand.layout, stand.container, stand.storage, source, maxUsedHeight: 2_000, "payload под картинкой")
        // Скрытых маркеров подряд больше 8192 получить нельзя, поэтому вариант с маркерами не проверяется.
    }

    // MARK: - S2. Строка начинается со скрытого символа

    /// Строка, чей первый символ скрыт (маркер `**`, `>`, `#`, список), не должна схлопываться, терять выделение и клик.
    func testLinesStartingWithHiddenMarkersKeepGeometryAndSelection() throws {
        let lines = ["**жирный** хвост", "> цитата 中文", "# Заголовок 😀", "- пункт", "1. номер", "~~зачёрк~~ x", "  ведущие пробелы", "end"]
        for separator in ["\n", "\r\n"] {
            let name = separator == "\n" ? "LF" : "CRLF"
            let source = lines.joined(separator: separator)
            let (storage, layout, container, view) = makeLayout(source)
            let raw = source as NSString
            let presentation = MarkdownPresentationBuilder.parse(source, syntax: .init(preserveEditingWhitespace: false))
            let end = raw.range(of: "end", options: .backwards)
            layout.setMarkdownPresentation(presentation, revealedRange: end, inlineSelection: end)
            let time = elapsed { layout.ensureLayout(for: container) }
            XCTAssertLessThan(time, .seconds(10), name)
            assertLayoutIsSane(layout, container, storage, source, minFragments: lines.count, maxUsedHeight: 2_000, name)

            var hiddenStarts = 0
            var location = 0
            for text in lines.dropLast() {
                let message = "\(name): «\(text)»"
                let lineRange = raw.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(lineRange)
                let start = lineRange.location
                let glyph = layout.glyphIndexForCharacter(at: start)
                let property = layout.propertyForGlyph(at: glyph)
                if layout.isMarkdownMarkerHidden(at: start) || property == .null || property == .controlCharacter { hiddenStarts += 1 }
                var effective = NSRange()
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
                XCTAssertLessThanOrEqual(effective.location, glyph, message)
                XCTAssertGreaterThanOrEqual(rect.height, layout.editorLineHeight - 0.5, "\(message): строка не схлопнута")

                // Первый видимый символ строки имеет ширину, а клик в начало строки попадает в эту же строку.
                var visible: Int?
                for index in start..<NSMaxRange(lineRange) where !layout.isMarkdownMarkerHidden(at: index)
                    && glyphProperty(layout, at: index) != .null && glyphProperty(layout, at: index) != .controlCharacter {
                    visible = index
                    break
                }
                if let visible {
                    let bounds = layout.boundingRect(forGlyphRange: NSRange(location: layout.glyphIndexForCharacter(at: visible), length: 1), in: container)
                    XCTAssertGreaterThan(bounds.width, 0, "\(message): ширина первого видимого символа")
                    XCTAssertGreaterThanOrEqual(bounds.minX, 0, message)
                } else {
                    XCTFail("\(message): нет видимых символов")
                }
                let point = NSPoint(x: rect.minX + container.lineFragmentPadding + 0.5, y: rect.midY)
                let hit = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
                XCTAssertTrue(hit >= lineRange.location && hit <= NSMaxRange(lineRange), "\(message): клик попал в \(hit)")

                view.setSelectedRange(lineRange)
                XCTAssertEqual(view.selectedRange(), lineRange, "\(message): выделение строки")
                view.setSelectedRange(NSRange(location: start, length: 0))
                view.moveRight(nil)
                let caret = view.selectedRange().location
                XCTAssertTrue(caret != NSNotFound && caret >= start && caret <= NSMaxRange(lineRange), "\(message): каретка после moveRight \(caret)")
            }
            XCTAssertGreaterThanOrEqual(hiddenStarts, 3, "\(name): сценарий должен включать строки со скрытым первым символом")

            // Раскрытие первой строки возвращает маркер `**` с шириной.
            let first = raw.lineRange(for: NSRange(location: 0, length: 0))
            layout.updateMarkdownRevealedRange(first)
            layout.ensureLayout(for: container)
            XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 0), "\(name): маркер раскрыт")
            XCTAssertNotEqual(glyphProperty(layout, at: 0), .null, "\(name): глиф маркера виден")
            let markerGlyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 2), actualCharacterRange: nil)
            XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: markerGlyphs, in: container).width, 0, "\(name): ширина раскрытого маркера")

            layout.setMarkdownPresentation(nil, revealedRange: nil)
            layout.ensureLayout(for: container)
            XCTAssertEqual(storage.string, source, name)
            withExtendedLifetime(view) {}
        }
    }

    // MARK: - S3. Строка скрыта целиком

    /// Свёрнутые строки целиком (CRLF, CJK) не оставляют пустого места между соседними строками.
    func testFoldedWholeLinesLeaveNoGap() {
        let source = "верх\r\nсрыто 1\r\nсрыто 2 中\r\nниз\r\n"
        let (storage, layout, container, view) = makeLayout(source)
        let raw = source as NSString
        let start = raw.range(of: "срыто 1").location
        let hidden = NSRange(location: start, length: raw.range(of: "низ").location - start)
        layout.setFoldedRange(hidden)
        layout.ensureLayout(for: container)
        for index in hidden.location..<NSMaxRange(hidden) {
            let rect = lineRect(layout, at: index)
            XCTAssertTrue(rect.minY.isFinite && rect.height.isFinite, "скрытая позиция \(index)")
        }
        let top = lineRect(layout, at: 0)
        let bottom = lineRect(layout, at: raw.range(of: "низ").location)
        XCTAssertLessThanOrEqual(bottom.minY, top.maxY + layout.editorLineHeight, "низ стоит сразу под верхом")
        assertLayoutIsSane(layout, container, storage, source, hidden: [hidden], maxUsedHeight: 200, "две скрытые строки")
        withExtendedLifetime(view) {}
    }

    func testFoldedLastLineWithoutTrailingBreakKeepsLayoutAndSelection() {
        let source = "верх\nсрыто"
        let (storage, layout, container, view) = makeLayout(source)
        let hidden = NSRange(location: 5, length: 5)
        layout.setFoldedRange(hidden)
        layout.ensureLayout(for: container)
        let extra = layout.extraLineFragmentRect
        XCTAssertTrue(extra.origin.x.isFinite && extra.origin.y.isFinite && extra.width.isFinite && extra.height.isFinite, "extraLineFragmentRect конечен")
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        XCTAssertEqual(view.selectedRange(), NSRange(location: (source as NSString).length, length: 0))
        assertLayoutIsSane(layout, container, storage, source, hidden: [hidden], maxUsedHeight: 200, "скрыта последняя строка")
        withExtendedLifetime(view) {}
    }

    /// Строка, состоящая только из блочной картинки, скрыта; следующий абзац стоит ниже.
    func testImageOnlyLineIsHiddenAndNextParagraphIsBelow() async throws {
        let source = "до\n\n![a](data:image/png;base64,\(base64PNG(2_048)))\n\nпосле"
        let stand = ImageStand(source: source)
        defer { stand.finish() }
        let raw = source as NSString
        let imageStart = raw.range(of: "![a](").location
        let ready = try await stand.waitForImage(at: imageStart)
        XCTAssertTrue(ready, "картинка установлена")
        stand.layout.ensureLayout(for: stand.container)
        let payload = payloadRange(in: source)
        for offset in payloadSample(length: payload.length, stride: 97) {
            XCTAssertEqual(glyphProperty(stand.layout, at: payload.location + offset), .null, "payload: смещение \(offset)")
        }
        XCTAssertGreaterThan(lineRect(stand.layout, at: raw.range(of: "после").location).minY, lineRect(stand.layout, at: imageStart).minY)
        assertLayoutIsSane(stand.layout, stand.container, stand.storage, source, maxUsedHeight: 2_000, "строка из картинки")
    }

    /// Строки таблицы скрыты нулевыми глифами; раскладка и текст при этом остаются целыми.
    func testTableLinesHiddenAsZeroGlyphsKeepLayoutSane() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n\nend"
        let (storage, layout, container, view) = makeLayout(source)
        let presentation = MarkdownPresentationBuilder.parse(source)
        XCTAssertEqual(presentation.tables.count, 1)
        let end = (source as NSString).range(of: "end")
        layout.setMarkdownPresentation(presentation, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        let table = presentation.tables.first
        let tableRange = table?.range ?? NSRange(location: 0, length: 0)
        assertLayoutIsSane(layout, container, storage, source, hidden: [tableRange], maxUsedHeight: 2_000, "таблица")
        XCTAssertGreaterThan(lineRect(layout, at: end.location).minY, lineRect(layout, at: 0).minY, "end ниже таблицы")
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        layout.ensureLayout(for: container)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    // MARK: - S4. Большой data URI

    /// ~1 МБ Base64 в одной строке: под картинкой payload скрыт (быстрая ветка), после снятия картинки глифы возвращаются.
    func testMegabyteDataURIIsHiddenWhileImageIsShownAndRestoredAfterRemoval() async throws {
        let source = "до\n\n![a](data:image/png;base64,\(base64PNG(768 * 1_024)))\n\nпосле"
        let stand = ImageStand(source: source, size: NSSize(width: 400, height: 600))
        defer { stand.finish() }
        let raw = source as NSString
        let imageStart = raw.range(of: "![a](").location
        let payload = payloadRange(in: source)
        XCTAssertGreaterThan(payload.length, 1_000_000)
        let ready = try await stand.waitForImage(at: imageStart)
        XCTAssertTrue(ready, "картинка установлена")
        let time = elapsed { stand.layout.ensureLayout(for: stand.container) }
        XCTAssertLessThan(time, .seconds(10), "раскладка с картинкой")
        for offset in payloadSample(length: payload.length, stride: 997) {
            XCTAssertEqual(glyphProperty(stand.layout, at: payload.location + offset), .null, "payload: смещение \(offset)")
        }
        XCTAssertLessThan(stand.layout.usedRect(for: stand.container).height, 2_000, "высота с картинкой")
        XCTAssertEqual(stand.layout.markdownImageLocation(at: stand.point(at: imageStart), in: stand.container), imageStart)
        XCTAssertEqual(stand.storage.string, source)

        stand.controller.update(document: stand.document, enabled: true, isActive: false, revision: 0, currentRevision: { 0 })
        XCTAssertTrue(stand.images.isEmpty, "картинка снята")
        for offset in [0, 1, 8191, 8192, 8193, payload.length / 2, payload.length - 1] {
            XCTAssertNotEqual(glyphProperty(stand.layout, at: payload.location + offset), .null, "payload без картинки: смещение \(offset)")
        }
        XCTAssertEqual(stand.storage.string, source)
    }

    /// Граница пакета глифов (8192) внутри, на краю и за краем payload. Длины Base64 кратны 4, поэтому точные 8191/8193 недостижимы.
    func testPayloadAroundGlyphPacketBoundaryStaysHidden() async throws {
        for bytes in [6_141, 6_144, 6_147] {
            let source = "до\n\n![a](data:image/png;base64,\(base64PNG(bytes)))\n\nпосле"
            let stand = ImageStand(source: source)
            defer { stand.finish() }
            let imageStart = (source as NSString).range(of: "![a](").location
            let ready = try await stand.waitForImage(at: imageStart)
            XCTAssertTrue(ready, "\(bytes) байт: картинка установлена")
            let payload = payloadRange(in: source)
            let time = elapsed { stand.layout.ensureLayout(for: stand.container) }
            XCTAssertLessThan(time, .seconds(10), "\(bytes) байт")
            for offset in payloadSample(length: payload.length, stride: 97) {
                XCTAssertEqual(glyphProperty(stand.layout, at: payload.location + offset), .null, "\(bytes) байт: смещение \(offset)")
            }
            assertLayoutIsSane(stand.layout, stand.container, stand.storage, source, maxUsedHeight: 2_000, "\(bytes) байт")
        }
    }

    // MARK: - Редактор через Coordinator (токены вместо payload)

    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let layout: FoldLayoutManager
        let container: NSTextContainer
        let scroll: NSScrollView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }

        @discardableResult
        func edit(_ range: NSRange, _ text: String) -> Bool {
            guard view.shouldChangeText(in: range, replacementString: text) else { return false }
            view.textStorage?.replaceCharacters(in: range, with: text)
            view.didChangeText()
            return true
        }

        func close() {
            coordinator.updateActivity(false)
            window.orderOut(nil)
            window.close()
        }
    }

    /// Порядок вызовов как в `MarkdownMediaIntegrationTests.makeEditor`, плюс окно (`MarkdownClipboardInteractionTests.makeEditor`).
    private func makeEditor(_ source: String, document: EditorDocument? = nil, formatted: Bool) -> Editor {
        _ = NSApplication.shared
        let document = document ?? EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = formatted
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 10_000_000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.attachLiveTextProvider()
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        return Editor(document: document, coordinator: coordinator, view: view, layout: layout, container: container, scroll: scroll, window: window)
    }

    /// Через `Coordinator` payload в хранилище заменён токеном: в исходном режиме токен — якорь, в оформленном — картинка.
    func testMegabyteDataURIBecomesTokenAnchorAndImage() async throws {
        let payload = base64PNG(768 * 1_024)
        let source = "до\n\n![a](data:image/png;base64,\(payload))\n\nпосле"
        let editor = makeEditor(source, formatted: false)
        defer { editor.close() }
        editor.coordinator.installMediaLabel()
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))

        func assertAnchor(_ message: String) throws {
            XCTAssertTrue(editor.shown.contains("#lac-media-"), message)
            XCTAssertFalse(editor.shown.contains(String(payload.prefix(64))), message)
            let span = try XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first, message)
            let tokenRange = NSRange(location: span.displayStart, length: span.displayLength)
            editor.layout.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: editor.shown.length), changeInLength: 0, actualCharacterRange: nil)
            let glyphs = editor.layout.glyphRange(forCharacterRange: tokenRange, actualCharacterRange: nil)
            XCTAssertEqual(glyphs.length, tokenRange.length, message)
            XCTAssertEqual(editor.layout.propertyForGlyph(at: glyphs.location), .controlCharacter, message)
            for glyph in glyphs.location + 1..<NSMaxRange(glyphs) {
                XCTAssertEqual(editor.layout.propertyForGlyph(at: glyph), .null, message)
            }
        }

        try assertAnchor("после открытия")
        XCTAssertLessThan(editor.shown.length, 1_000, "в хранилище токен, а не 1 МБ")
        XCTAssertTrue(editor.edit(NSRange(location: editor.shown.length, length: 0), "x"))
        editor.coordinator.updateMarkdownPresentation()
        try assertAnchor("после правки")
        XCTAssertEqual(Array(editor.document.synchronizedText().utf16), Array((source + "x").utf16))

        editor.document.isMarkdownFormatted = true
        editor.coordinator.updateMarkdownPresentation()
        let image = editor.shown.range(of: "![a](")
        func point() -> NSPoint {
            editor.layout.ensureLayout(for: editor.container)
            let rect = lineRect(editor.layout, at: image.location)
            return NSPoint(x: rect.minX + editor.container.lineFragmentPadding + 0.5, y: rect.minY + 0.5)
        }
        for _ in 0..<30 {
            if editor.layout.markdownImageLocation(at: point(), in: editor.container) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(editor.layout.markdownImageLocation(at: point(), in: editor.container), image.location)
        XCTAssertTrue(editor.shown.contains("#lac-media-"))
        XCTAssertFalse(editor.shown.contains(String(payload.prefix(64))))
        XCTAssertEqual(Array(editor.document.synchronizedText().utf16), Array((source + "x").utf16))
    }

    // MARK: - S5. Один документ в двух окнах

    /// У каждого окна своя пара storage/layout (как в приложении), общий только `EditorDocument`.
    /// Не проверяются key window и first responder: в параллельном прогоне окно неактивной копии key не становится.
    func testOneDocumentInTwoWindowsKeepsIndependentGlyphState() async throws {
        let body = (0..<200).map { "строка тела \($0) 中文\n" }.joined()
        let source = "**жирный** 中文\n\n![a](data:image/png;base64,\(base64PNG(2_048)))\n\n" + body + "\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let a = makeEditor(source, document: document, formatted: true)
        let b = makeEditor(source, document: document, formatted: true)
        var aClosed = false
        defer { if !aClosed { a.close() }; b.close() }

        func waitForMarkers(_ editor: Editor) async throws -> Bool {
            for _ in 0..<30 {
                if editor.layout.isMarkdownMarkerHidden(at: 0) { return true }
                editor.coordinator.updateMarkdownPresentation()
                try await Task.sleep(for: .milliseconds(100))
            }
            return editor.layout.isMarkdownMarkerHidden(at: 0)
        }
        let aHidden = try await waitForMarkers(a)
        let bHidden = try await waitForMarkers(b)
        XCTAssertTrue(aHidden, "окно A: маркеры скрыты")
        XCTAssertTrue(bHidden, "окно B: маркеры скрыты")
        for (name, editor) in [("A", a), ("B", b)] {
            XCTAssertTrue(editor.shown.contains("#lac-media-"), "окно \(name): токен вместо payload")
            XCTAssertFalse(editor.shown.contains("iVBOR"), "окно \(name)")
            editor.layout.ensureLayout(for: editor.container)
        }

        // Свёртка в A не затрагивает B.
        let bodyRange = a.shown.range(of: "строка тела 0")
        XCTAssertNotEqual(bodyRange.location, NSNotFound)
        let folded = NSRange(location: bodyRange.location, length: 2_000)
        a.layout.setFoldedRange(folded)
        a.layout.ensureLayout(for: a.container)
        XCTAssertTrue(a.layout.isCharacterFolded(folded.location), "A свёрнуто")
        XCTAssertFalse(b.layout.isCharacterFolded(folded.location), "B не свёрнуто")
        XCTAssertNotEqual(glyphProperty(b.layout, at: folded.location), .null, "глиф B виден")
        a.layout.setFoldedRange(nil)

        // Правка в A не меняет текст и глифы B.
        let sampleBefore = stride(from: 0, to: b.shown.length, by: 53).map { glyphProperty(b.layout, at: $0) }
        let shownBefore = b.shown as String
        XCTAssertTrue(a.edit(NSRange(location: a.shown.length, length: 0), "x"))
        a.coordinator.updateMarkdownPresentation()
        b.layout.ensureLayout(for: b.container)
        XCTAssertEqual(b.shown as String, shownBefore, "B: текст не изменился")
        XCTAssertEqual(stride(from: 0, to: b.shown.length, by: 53).map { glyphProperty(b.layout, at: $0) }, sampleBefore, "B: глифы не изменились")
        XCTAssertTrue(a.edit(NSRange(location: a.shown.length - 1, length: 1), ""), "возврат правки")
        a.coordinator.updateMarkdownPresentation()

        // Закрытие A не ломает B.
        let aShown = a.shown as String
        a.close()
        aClosed = true
        b.layout.ensureLayout(for: b.container)
        XCTAssertTrue(b.layout.isMarkdownMarkerHidden(at: 0), "B после закрытия A")
        XCTAssertFalse(document.synchronizedText().isEmpty, "поставщик текста жив")
        XCTAssertEqual(aShown, shownBefore, "A после возврата правки совпадает с исходным показом")
        XCTAssertEqual(document.synchronizedText(), source, "текст документа не изменился")
    }
}

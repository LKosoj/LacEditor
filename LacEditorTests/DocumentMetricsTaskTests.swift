import Combine
import XCTest
@testable import LacEditor

@MainActor
final class DocumentMetricsTaskTests: XCTestCase {
    func testCancellationBeforeTaskAttachmentCancelsLateTask() {
        let coordinator = DocumentTaskCoordinator()
        let generation = coordinator.begin(.metrics)
        coordinator.cancel(.metrics)
        let task = Task<Void, Never> {}
        coordinator.attachTask(task, kind: .metrics, generation: generation)
        XCTAssertTrue(task.isCancelled)
    }

    func testLateTaskDoesNotReplaceCurrentCancellation() {
        let coordinator = DocumentTaskCoordinator()
        let oldGeneration = coordinator.begin(.metrics)
        let generation = coordinator.begin(.metrics)
        let current = Task<Void, Never> {}
        coordinator.attachTask(current, kind: .metrics, generation: generation)
        let old = Task<Void, Never> {}
        coordinator.attachTask(old, kind: .metrics, generation: oldGeneration)
        XCTAssertTrue(old.isCancelled)
        XCTAssertFalse(current.isCancelled)
        coordinator.cancel(.metrics)
        XCTAssertTrue(current.isCancelled)
    }

    func testTypingPauseDefersFullPasses() async throws {
        let document = EditorDocument(text: "old")
        var reads = 0
        document.attachLiveTextProvider(id: UUID(), provider: { reads += 1; return "new text" }, acknowledgement: { _ in })
        document.noteLiveEdit(isEmpty: false)
        try await Task.sleep(for: .milliseconds(450))
        document.noteLiveEdit(isEmpty: false)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(reads, 0)
        for _ in 0..<100 where reads == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(reads, 1)
    }

    func testReadableProjectionWaitsForDeferredModelWrite() {
        let source = "hello world"
        let document = EditorDocument(text: source, language: .markdown)
        var reads = 0
        document.attachLiveTextProvider(id: UUID(), provider: { reads += 1; return source }, acknowledgement: { _ in })
        let projection = MarkdownReadableText(sourceLength: (source as NSString).length, fragments: [
            .init(sourceRange: NSRange(location: 0, length: (source as NSString).length), text: source, matchesSource: true)
        ], unsupportedRanges: [])
        document.noteLiveEdit(isEmpty: false)
        XCTAssertFalse(document.installMarkdownReadableText(projection, source: source))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(document.synchronizeLiveText())
        XCTAssertTrue(document.installMarkdownReadableText(projection, source: source))
        document.cancelMetricsRefresh()
    }

    func testOnlyLatestTextAndSelectionAreCounted() async {
        let document = EditorDocument()
        let updated = expectation(description: "latest selection")
        let subscription = document.$statistics.dropFirst().sink { result in
            guard let result else { return }
            XCTAssertEqual(result.characters, 2)
            XCTAssertEqual(result.words, 1)
            updated.fulfill()
        }
        document.text = "old text"
        document.text = "one two"
        document.selectionRange = NSRange(location: 0, length: 3)
        document.selectionRange = NSRange(location: 4, length: 2)
        await fulfillment(of: [updated], timeout: 5)
        withExtendedLifetime(subscription) {}
    }

    func testLiveEditInvalidatesBeforeDelayedSnapshot() async {
        let document = EditorDocument(text: "old")
        var reads = 0
        document.attachLiveTextProvider(id: UUID(), provider: { reads += 1; return "new text" }, acknowledgement: { _ in })
        let updated = expectation(description: "live text")
        let subscription = document.$statistics.dropFirst().sink { result in
            guard let result else { return }
            XCTAssertEqual(result.words, 2)
            updated.fulfill()
        }
        document.noteLiveEdit(isEmpty: false)
        XCTAssertNil(document.statistics)
        XCTAssertEqual(reads, 0)
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertEqual(reads, 1)
        withExtendedLifetime(subscription) {}
    }

    func testSelectionAcrossCRLFAndCompositeCharacter() async {
        let text = "before 👨‍👩‍👧‍👦\r\nafter"
        let document = EditorDocument(text: text)
        let updated = expectation(description: "selected text")
        let subscription = document.$statistics.dropFirst().sink { result in
            guard let result else { return }
            XCTAssertEqual(result.characters, 3)
            XCTAssertEqual(result.charactersWithoutWhitespace, 2)
            XCTAssertEqual(result.lines, 2)
            updated.fulfill()
        }
        document.selectionRange = (text as NSString).range(of: "👨‍👩‍👧‍👦\r\na")
        await fulfillment(of: [updated], timeout: 5)
        withExtendedLifetime(subscription) {}
    }

    func testInvalidSelectionIsUnavailable() async {
        let document = EditorDocument(text: "👨‍👩‍👧‍👦")
        let unavailable = expectation(description: "invalid selection")
        let subscription = document.$statisticsUnavailable.dropFirst().sink { if $0 { unavailable.fulfill() } }
        document.selectionRange = NSRange(location: 1, length: 1)
        await fulfillment(of: [unavailable], timeout: 5)
        XCTAssertNil(document.statistics)
        XCTAssertTrue(document.statisticsUnavailable)
        withExtendedLifetime(subscription) {}
    }

    func testCaretMovementKeepsStatisticsAndPendingDocumentScope() async {
        let document = EditorDocument(text: "😀")
        let initial = document.statistics
        document.selectionRange = NSRange(location: 1, length: 0)
        XCTAssertEqual(document.statistics, initial)
        XCTAssertFalse(document.statisticsUnavailable)
        document.text = "😀a"
        let updated = expectation(description: "count despite cursor movement")
        let subscription = document.$statistics.dropFirst().sink { result in
            if result?.characters == 2 { updated.fulfill() }
        }
        document.selectionRange = NSRange(location: 2, length: 0)
        document.selectionRange = NSRange(location: 1, length: 0)
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertEqual(document.statistics?.characters, 2)
        withExtendedLifetime(subscription) {}
    }

    func testCancelBeforeDelayAndResumeRetainedDocument() async {
        let document = EditorDocument(text: "old")
        document.text = "new text"
        document.cancelMetricsRefresh()
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(document.statistics)
        let resumed = expectation(description: "resumed")
        let subscription = document.$statistics.dropFirst().sink { result in
            if result?.words == 2 { resumed.fulfill() }
        }
        document.resumeMetricsRefresh()
        await fulfillment(of: [resumed], timeout: 5)
        withExtendedLifetime(subscription) {}
    }

    func testLargeProfileAndManualOverride() async {
        let document = EditorDocument(text: "hello world", performanceProfile: .large)
        XCTAssertNil(document.statistics)
        let updated = expectation(description: "manual statistics")
        let subscription = document.$statistics.dropFirst().sink { result in
            if result?.words == 2 { updated.fulfill() }
        }
        document.setOverride(true, for: .wordCount)
        await fulfillment(of: [updated], timeout: 5)
        document.setOverride(false, for: .wordCount)
        XCTAssertNil(document.statistics)
        withExtendedLifetime(subscription) {}
    }
    func testMarkdownWaitsForConfirmedProjectionAndKeepsRawCharacters() async {
        let source = "**hello** [world](https://example.com)"
        let document = EditorDocument(text: source, language: .markdown)
        XCTAssertNil(document.statistics)
        let projection = MarkdownReadableText(sourceLength: (source as NSString).length, fragments: [
            .init(sourceRange: (source as NSString).range(of: "hello"), text: "hello", matchesSource: true),
            .init(sourceRange: NSRange(location: 9, length: 1), text: " ", matchesSource: true),
            .init(sourceRange: (source as NSString).range(of: "world"), text: "world", matchesSource: true)
        ], unsupportedRanges: [])
        XCTAssertFalse(document.installMarkdownReadableText(projection, source: "stale source"))
        let updated = expectation(description: "readable words and raw characters")
        let subscription = document.$statistics.dropFirst().sink { result in
            guard let result else { return }
            XCTAssertEqual(result.words, 2)
            XCTAssertEqual(result.characters, source.count)
            updated.fulfill()
        }
        XCTAssertTrue(document.installMarkdownReadableText(projection, source: source))
        await fulfillment(of: [updated], timeout: 5)
        document.noteLiveEdit(isEmpty: false)
        XCTAssertNil(document.statistics)
        withExtendedLifetime(subscription) {}
    }

    func testUnsupportedReadableSelectionDoesNotPublishSourceWordCount() async {
        let source = "<div>hidden</div>"
        let document = EditorDocument(text: source, language: .markdown)
        let projection = MarkdownReadableText(sourceLength: (source as NSString).length, fragments: [],
                                              unsupportedRanges: [NSRange(location: 0, length: (source as NSString).length)])
        let unavailable = expectation(description: "unsupported HTML projection")
        let subscription = document.$statisticsUnavailable.dropFirst().sink { if $0 { unavailable.fulfill() } }
        XCTAssertTrue(document.installMarkdownReadableText(projection, source: source))
        await fulfillment(of: [unavailable], timeout: 5)
        XCTAssertNil(document.statistics)
        withExtendedLifetime(subscription) {}
    }

    func testReadableProjectionRequiresExactSourceUnits() {
        let current = "a\u{301}\u{323}", reordered = "a\u{323}\u{301}"
        XCTAssertEqual(current, reordered)
        let document = EditorDocument(text: current, language: .markdown)
        let projection = MarkdownReadableText(sourceLength: (reordered as NSString).length,
            fragments: [.init(sourceRange: NSRange(location: 0, length: (reordered as NSString).length), text: reordered, matchesSource: true)], unsupportedRanges: [])
        XCTAssertFalse(document.installMarkdownReadableText(projection, source: reordered))
        XCTAssertTrue(document.installMarkdownReadableText(projection, source: current))
    }

    func testReadableProjectionOfDisplayTextInstallsInSourceCoordinates() {
        var table = MarkdownMediaTable()
        let projected = table.project("![a](data:image/png;base64,iVBORw0KGgo=) after")
        let file = table.restore(projected.text).text
        let display = projected.text as NSString
        let map = MarkdownMediaMap(spans: projected.spans)
        let document = EditorDocument(text: file, language: .markdown)
        document.mediaTable = table
        let projection = MarkdownReadableText(sourceLength: display.length, fragments: [
            .init(sourceRange: display.range(of: "after"), text: "after", matchesSource: true)
        ], unsupportedRanges: [])
        // Экранные координаты и длина не подходят файловому тексту.
        XCTAssertFalse(document.installMarkdownReadableText(projection, source: file))
        let converted = projection.inSource(map, sourceLength: (file as NSString).length)
        XCTAssertTrue(document.installMarkdownReadableText(converted, source: file))
        XCTAssertEqual(converted.fragments[0].sourceRange, (file as NSString).range(of: "after"))
    }

}

import AppKit
import Foundation
import XCTest
@testable import LacEditor

// Переключение «исходный текст → оформленный вид → исходный текст» без правок не должно менять ни байта.
// Стенд взят из MarkdownLayoutTests.testCodeBlockColorsSurviveMarkdownHighlightAndRestoreSourceColors.
@MainActor
final class MarkdownSemanticRoundTripTests: XCTestCase {
    private func makeLayout(_ source: String) -> (NSTextStorage, FoldLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 2_000))
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private func documents() throws -> [(name: String, text: String)] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var result: [(String, String)] = []
        for folder in [tests.deletingLastPathComponent().appendingPathComponent("Verification/Fixtures"), tests.appendingPathComponent("Fixtures/MarkdownBaseline")] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
            for name in names { result.append((name, try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8))) }
        }
        // Не-ASCII (CJK, эмодзи, комбинируемый символ, неразрывный пробел) без завершающего перевода строки.
        result.append(("unicode", "# 中文 😀 e\u{301}\n\nnbsp\u{00A0}text **жирный** [ссылка](https://example.com)"))
        return result
    }

    func testSourceFormattedSourceKeepsTextBytes() async throws {
        _ = NSApplication.shared
        let documents = try documents()
        XCTAssertGreaterThan(documents.count, 1)
        for item in documents {
            for (variant, source) in [("LF", item.text), ("CRLF", item.text.replacingOccurrences(of: "\n", with: "\r\n"))] {
                let message = "\(item.name) \(variant)"
                let document = EditorDocument(text: source, language: .markdown)
                let coordinator = EditorTextView.Coordinator(document: document)
                let (storage, layout, container) = makeLayout(source)
                let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
                let scroll = NSScrollView(frame: view.frame)
                scroll.documentView = view
                coordinator.textView = view
                coordinator.foldLayoutManager = layout
                view.delegate = coordinator
                coordinator.installObservers(scrollView: scroll)
                coordinator.attachLiveTextProvider()
                coordinator.updateActivity(true)
                defer { coordinator.updateActivity(false) }
                view.setSelectedRange(NSRange(location: 0, length: 0))
                document.isMarkdownFormatted = true
                coordinator.updateMarkdownPresentation()
                // Ждём, пока оформление применится: у layoutManager появляются маркеры или заголовки (опрос с пределом).
                func presentationApplied() -> Bool {
                    let snapshot = layout.markdownListsSnapshot
                    return ["markers", "headings", "replacements"].contains { snapshot[$0]?.isEmpty == false }
                }
                for _ in 0..<30 where !presentationApplied() { try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertTrue(presentationApplied(), "оформление не применилось: \(message)")
                document.isMarkdownFormatted = false
                coordinator.updateMarkdownPresentation()
                // Ждём, пока оформление снимется.
                for _ in 0..<30 where presentationApplied() { try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertFalse(presentationApplied(), "оформление не снялось: \(message)")
                // Сравнение по байтам: String == считает «é» и «e + U+0301» равными.
                XCTAssertEqual(Array(storage.string.utf8), Array(source.utf8), message)
                XCTAssertEqual(Array(document.text.utf8), Array(source.utf8), message)
                XCTAssertFalse(document.isDirty, message)
                withExtendedLifetime(scroll) {}
            }
        }
    }
}

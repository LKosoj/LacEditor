import XCTest
@testable import LacEditor

/// Объявление VoiceOver о смене «исходник ↔ оформленный текст»: тексты и вызов только из явных команд.
@MainActor
final class MarkdownModeAnnouncementTests: XCTestCase {
    private func appState(_ document: EditorDocument) throws -> AppState {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditorModeAnnouncement.\(UUID())"))
        return AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                        preferences: AppPreferences(defaults: defaults))
    }

    func testTextsDifferPerMode() {
        let formatted = MarkdownModeAnnouncement.text(formatted: true)
        let source = MarkdownModeAnnouncement.text(formatted: false)
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertFalse(source.isEmpty)
        XCTAssertNotEqual(formatted, source)
    }

    func testTextsExistInAllCatalogs() throws {
        let keys = ["已切换到 Markdown 源码", "已切换到格式化文本"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
            }
        }
    }

    // Кнопка и меню идут через `toggleMarkdownPresentation`: каждое переключение объявляется один раз и называет новый режим.
    func testToggleAnnouncesNewModeOnce() throws {
        let document = EditorDocument(text: "# заголовок 😀", language: .markdown)
        document.isMarkdownFormatted = false
        let state = try appState(document)
        var spoken: [String] = []
        state.toggleMarkdownPresentation { spoken.append($0) }
        XCTAssertEqual(spoken, [MarkdownModeAnnouncement.text(formatted: true)])
        state.toggleMarkdownPresentation { spoken.append($0) }
        XCTAssertEqual(spoken, [MarkdownModeAnnouncement.text(formatted: true), MarkdownModeAnnouncement.text(formatted: false)])
    }

    // Выход из чтения в исходник объявляет исходник; режим чтения сам по себе ничего не объявляет.
    func testExitFromReadingAnnouncesSourceOnly() throws {
        let document = EditorDocument(text: "# a", language: .markdown)
        let state = try appState(document)
        state.toggleReadingMode()
        XCTAssertTrue(document.isReadingMode)
        var spoken: [String] = []
        state.exitReadingModeToSource { spoken.append($0) }
        XCTAssertEqual(spoken, [MarkdownModeAnnouncement.text(formatted: false)])
    }

    // Ничего не меняется (не Markdown, нет чтения, занятый документ) - ничего не объявляется.
    func testNoAnnouncementWhenNothingSwitches() throws {
        var spoken: [String] = []
        let plain = EditorDocument(text: "a", language: .plainText)
        try appState(plain).toggleMarkdownPresentation { spoken.append($0) }
        let markdown = EditorDocument(text: "# a", language: .markdown)
        let state = try appState(markdown)
        state.exitReadingModeToSource { spoken.append($0) }
        state.toggleReadingMode()
        markdown.ioState = .saving
        state.exitReadingModeToSource { spoken.append($0) }
        XCTAssertTrue(spoken.isEmpty, "объявлено: \(spoken)")
    }
}

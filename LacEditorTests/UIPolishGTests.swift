import XCTest
@testable import LacEditor

final class UIPolishGTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("LacEditor/" + relative), encoding: .utf8)
    }

    private func file(_ path: String) -> FolderSearchController.QuickOpenItem {
        let url = URL(fileURLWithPath: "/r/" + path)
        return .file(FolderSearchService.File(url: url, relativePath: path))
    }

    func testQuickOpenItemIDDistinguishesFilesAndFolders() {
        let url = URL(fileURLWithPath: "/r/a.md")
        XCTAssertNotEqual(file("a.md").id, FolderSearchController.QuickOpenItem.folder(url).id)
        XCTAssertEqual(file("a.md").id, file("a.md").id)
        XCTAssertNotEqual(file("a/x.md").id, file("b/x.md").id)
    }

    func testQuickOpenItemIDIsStableAcrossReorder() {
        let a = file("a.md"), b = file("b.md")
        let first = [a, b].map(\.id), second = [b, a].map(\.id)
        XCTAssertEqual(Set(first), Set(second))
        XCTAssertEqual(Set(first).count, first.count)
    }

    func testQuickOpenRowsUseStableIdentity() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertTrue(text.contains("id: \\.element.id"))
        XCTAssertFalse(text.contains("id: \\.offset"))
    }

    func testQuickOpenRowIsButton() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertTrue(text.contains("Button { controller.select(item) }"))
        XCTAssertFalse(text.contains("onTapGesture { controller.select"))
    }

    func testQuickOpenEscapeHandledOnContainer() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: ".onExitCommand { dismiss() }").count - 1, 2)
    }

    func testQuickOpenAccessibilityLabels() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertTrue(text.contains("accessibilityHidden(true)"))
        XCTAssertTrue(text.contains("ProgressView().controlSize(.small).accessibilityLabel(L10n.tr(\"正在查找…\"))"))
        XCTAssertTrue(text.contains(".accessibilityLabel(QuickOpenRowText.title(item))"))
        XCTAssertTrue(text.contains(".accessibilityValue(QuickOpenRowText.subtitle(item))"))
    }

    func testQuickOpenSelectionColorsMatch() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertTrue(text.contains("alternateSelectedControlTextColor"))
        XCTAssertTrue(text.contains("selectedContentBackgroundColor"))
        XCTAssertFalse(text.contains("selectedMenuItemTextColor"))
    }

    func testQuickOpenUsesGlass() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertTrue(text.contains(".glassEffect("))
        XCTAssertFalse(text.contains(".regularMaterial"))
    }

    func testQuickOpenLocalizedStringsExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("\"正在查找…\""), language)
        }
    }
}

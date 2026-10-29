import XCTest
@testable import LacEditor

final class UIPolishITests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("LacEditor/" + relative), encoding: .utf8)
    }

    func testSidebarNamesTruncateInMiddle() throws {
        XCTAssertGreaterThanOrEqual(try source("Views/SidebarLibraryView.swift").components(separatedBy: "truncationMode(.middle)").count - 1, 4)
        XCTAssertGreaterThanOrEqual(try source("Views/FolderSearchView.swift").components(separatedBy: "truncationMode(.middle)").count - 1, 4)
        XCTAssertGreaterThanOrEqual(try source("Views/FolderWorkspaceView.swift").components(separatedBy: "truncationMode(.middle)").count - 1, 3)
    }

    func testExperimentSampleErrorIsLocalized() throws {
        let text = try source("Services/ExperimentSampleLibrary.swift")
        XCTAssertTrue(text.contains("L10n.tr(\"示例准备失败：%@\""))
        XCTAssertFalse(text.contains("\"示例准备失败：\\("))
        XCTAssertTrue(L10n.tr("示例准备失败：%@", "x").contains("x"))
    }

    func testSearchProblemUsesLocalizedFormat() throws {
        let text = try source("Views/FolderSearchView.swift")
        XCTAssertTrue(text.contains("L10n.tr(\"%@：%@\""))
        XCTAssertFalse(text.contains("\"\\(problem.url.path): "))
    }

    func testSidebarUsesStableHelpOnly() throws {
        for file in ["SidebarLibraryView", "SidebarView", "FolderWorkspaceView", "FolderSearchView"] {
            XCTAssertFalse(try source("Views/\(file).swift").contains(".help("), file)
        }
    }

    func testFolderRowsExposeActionHints() throws {
        let library = try source("Views/SidebarLibraryView.swift")
        let help = try XCTUnwrap(library.range(of: "stableHelp(url.path)"))
        let hint = try XCTUnwrap(library.range(of: "accessibilityHint(L10n.tr(\"打开此文件夹\"))"))
        XCTAssertLessThan(help.lowerBound, hint.lowerBound)
        let workspace = try source("Views/FolderWorkspaceView.swift")
        XCTAssertTrue(workspace.contains("展开或收起文件夹"))
        XCTAssertTrue(workspace.contains("显示此文件夹的内容"))
    }

    func testReorderLogic() {
        XCTAssertFalse(SidebarReorder.canMove(at: 0, offset: -1, count: 3))
        XCTAssertFalse(SidebarReorder.canMove(at: 2, offset: 1, count: 3))
        XCTAssertTrue(SidebarReorder.canMove(at: 1, offset: -1, count: 3))
        XCTAssertTrue(SidebarReorder.canMove(at: 1, offset: 1, count: 3))
        XCTAssertFalse(SidebarReorder.canMove(at: 0, offset: 1, count: 0))
        let items = ["a", "b", "c"]
        XCTAssertEqual(SidebarReorder.insertionTarget(at: 2, offset: -1, in: items), "b")
        XCTAssertEqual(SidebarReorder.insertionTarget(at: 0, offset: 1, in: items), "c")
        XCTAssertNil(SidebarReorder.insertionTarget(at: 1, offset: 1, in: items))
    }

    func testReorderMenuUsesStoreAndFeedback() throws {
        let text = try source("Views/SidebarLibraryView.swift")
        for needle in ["L10n.tr(\"上移\")", "L10n.tr(\"下移\")", "L10n.tr(\"已调整顺序\")", "restoreFavorites(",
                       "restoreGroupFiles(", "moveFavorite(", "moveFile(", "moveGroup(", ".disabled("] {
            XCTAssertTrue(text.contains(needle), needle)
        }
    }

    func testFolderStatusUsesStatusMessageView() throws {
        let text = try source("Views/FolderWorkspaceView.swift")
        XCTAssertTrue(text.contains("StatusMessageView(kind: .error, text: error)"))
        XCTAssertTrue(text.contains("StatusMessageView(kind: .info, text: notice)"))
        XCTAssertTrue(text.contains("AccessibilityNotification.Announcement"))
        XCTAssertFalse(text.contains("Text(error).font(.caption)"))
    }

    func testOutlineEstimatesHeightBeforeMeasurement() throws {
        XCTAssertEqual(MarkdownOutlineView.estimatedHeight(rowCount: 0), 24)
        XCTAssertEqual(MarkdownOutlineView.estimatedHeight(rowCount: 3), 72)
        XCTAssertEqual(MarkdownOutlineView.estimatedHeight(rowCount: 1000), MarkdownOutlineView.maximumHeight)
        XCTAssertFalse(try source("Views/MarkdownOutlineView.swift").contains("contentHeight > 0 ? contentHeight : 320"))
    }

    func testSectionFocusKeysAreNotLocalizedTitles() throws {
        let text = try source("Views/SidebarLibraryView.swift")
        XCTAssertFalse(text.contains("hasPrefix(title)"))
        XCTAssertFalse(text.contains("equals: title"))
        XCTAssertFalse(text.contains("focusedHeader == title"))
        XCTAssertTrue(text.contains("section.rawValue"))
    }

    func testFilterHintNotDuplicated() throws {
        let text = try source("Views/SidebarView.swift")
        XCTAssertTrue(text.contains("accessibilityHint(filterQuery.isEmpty ?"))
        XCTAssertFalse(text.contains(".accessibilityHint(L10n.tr(\"仅筛选资料库文件，不含工作文件夹\"))"))
    }

    func testReopenIdentityKept() throws {
        XCTAssertTrue(try source("Views/SidebarView.swift").contains(".id(windowManager.primaryReopenGeneration)"))
    }

    func testNewKeysExistInAllCatalogs() throws {
        let keys = ["示例准备失败：%@", "%@：%@", "打开此文件夹", "展开或收起文件夹", "显示此文件夹的内容", "已调整顺序"]
        var counts: [String: [Int]] = [:]
        for language in ["zh-Hans", "en", "ru"] {
            let text = try source("\(language).lproj/Localizable.strings")
            let dictionary = try XCTUnwrap(NSDictionary(contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings").path) as? [String: String], text)
            for key in keys {
                let value = try XCTUnwrap(dictionary[key], "\(language): \(key)")
                counts[key, default: []].append(value.components(separatedBy: "%@").count - 1)
            }
        }
        for (key, list) in counts { XCTAssertEqual(Set(list).count, 1, key) }
    }
}

import XCTest

/// Проверка исходников боковой панели (чистая вёрстка, логики для отдельного теста нет).
final class UIPolishETests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSectionControlsAreAlwaysVisible() throws {
        let library = try source("SidebarLibraryView.swift")
        XCTAssertFalse(library.contains("allowsHitTesting(isHovering)"))
        XCTAssertFalse(library.contains(".opacity(isHovering ? 1 : 0)"))
        XCTAssertFalse(library.contains(".opacity(isHovering || isFocused ? 1 : 0)"))
    }

    func testClearButtonHasMinimumHitAreaAndNoTrash() throws {
        let library = try source("SidebarLibraryView.swift")
        XCTAssertTrue(library.contains(".frame(width: 24, height: 24)"))
        XCTAssertFalse(library.contains(".frame(width: 20, height: 20)"))
        XCTAssertFalse(library.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(library.contains("L10n.tr(\"从最近文件中删除\"), systemImage: \"minus.circle\""))
    }

    func testFolderTreeMenu() throws {
        let folder = try source("FolderWorkspaceView.swift")
        XCTAssertTrue(folder.contains("role: .destructive"))
        XCTAssertTrue(folder.contains("L10n.tr(\"重命名…\")"))
        XCTAssertTrue(folder.contains("L10n.tr(\"打开\")"))
        XCTAssertFalse(folder.contains("L10n.tr(\"重命名\")"))
    }

    func testFolderEmptyAndErrorRecovery() throws {
        let folder = try source("FolderWorkspaceView.swift")
        let search = try source("FolderSearchView.swift")
        XCTAssertTrue(folder.contains("L10n.tr(\"选择其他文件夹…\")"))
        XCTAssertTrue(search.contains("L10n.tr(\"选择其他文件夹…\")"))
        XCTAssertTrue(folder.contains("L10n.tr(\"选择包含文档的文件夹\")"))
    }

    func testSidebarGeometryUsesOneInset() throws {
        let sidebar = try source("SidebarView.swift")
        let library = try source("SidebarLibraryView.swift")
        let folder = try source("FolderWorkspaceView.swift")
        XCTAssertFalse(sidebar.contains(".padding(.horizontal, 14)"))
        XCTAssertTrue(sidebar.contains(".font(.subheadline.weight(.semibold)).tracking(0.5)"))
        XCTAssertTrue(library.contains("sidebarHeadingStyle()"))
        XCTAssertTrue(folder.contains("sidebarHeadingStyle()"))
        XCTAssertFalse(library.contains("Color.orange"))
        XCTAssertTrue(library.contains(".systemOrange"))
    }

    func testFilterFieldIsVisibleAndScoped() throws {
        let sidebar = try source("SidebarView.swift")
        XCTAssertTrue(sidebar.contains("textBackgroundColor"))
        XCTAssertTrue(sidebar.contains("separatorColor"))
        XCTAssertFalse(sidebar.contains(".tertiary"))
        XCTAssertTrue(sidebar.contains("L10n.tr(\"仅筛选资料库文件，不含工作文件夹\")"))
    }

    func testSearchScopeIsTruncated() throws {
        let search = try source("FolderSearchView.swift")
        XCTAssertTrue(search.contains("lineLimit(1).truncationMode(.middle)"))
    }

    func testAccessibilityAdditions() throws {
        XCTAssertTrue(try source("MarkdownOutlineView.swift").contains("accessibilityValue(L10n.tr(\"标题 %@ 级\""))
        XCTAssertTrue(try source("SidebarView.swift").contains("AccessibilityNotification.Announcement"))
        let folder = try source("FolderWorkspaceView.swift")
        XCTAssertTrue(folder.contains("accessibilityHidden(true)"))
        XCTAssertTrue(folder.contains(".isHeader"))
    }
}

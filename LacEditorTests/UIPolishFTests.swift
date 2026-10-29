import XCTest
@testable import LacEditor

final class UIPolishFTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("LacEditor/" + relative), encoding: .utf8)
    }

    func testSaveToolbarItemUsesNonDriveSymbol() throws {
        let text = try source("Views/TitleToolbar.swift")
        XCTAssertTrue(text.contains("symbol: \"tray.and.arrow.down\""))
        XCTAssertFalse(text.contains("externaldrive"))
    }

    func testFindBarReplaceToggleUsesDisclosureChevron() throws {
        let text = try source("Views/FindReplaceView.swift")
        XCTAssertTrue(text.contains("chevron.right"))
        XCTAssertTrue(text.contains("chevron.down"))
        XCTAssertFalse(text.contains("arrow.triangle.2.circlepath"))
    }

    func testMarkdownPresentationItemDescribesAction() throws {
        let text = try source("Views/TitleToolbar.swift")
        XCTAssertTrue(text.contains("\"chevron.left.forwardslash.chevron.right\""))
        XCTAssertTrue(text.contains("\"textformat\""))
        XCTAssertTrue(text.contains("L10n.tr(\"显示 Markdown 源码\")"))
        XCTAssertTrue(text.contains("L10n.tr(\"显示格式化文本\")"))
        XCTAssertFalse(text.contains("text.document"))
    }

    func testDroppedDirectoryDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UIPolishF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(DroppedURLKind.isDirectory(URL(fileURLWithPath: dir.path)))
        XCTAssertFalse(DroppedURLKind.isDirectory(file))
        XCTAssertFalse(DroppedURLKind.isDirectory(dir.appendingPathComponent("missing")))
        let text = try source("Views/MainWindowView.swift")
        XCTAssertFalse(text.contains("hasDirectoryPath"))
        XCTAssertTrue(text.contains("appState.openFolder(folder)"))
    }

    func testRecentHintsLimitAndExistence() {
        let urls = (1...5).map { URL(fileURLWithPath: "/tmp/f\($0).md") }
        let missing = Set([urls[1], urls[2]])
        XCTAssertEqual(RecentHints.urls(urls, exists: { !missing.contains($0) }), [urls[0], urls[3], urls[4]])
        XCTAssertEqual(RecentHints.urls([], exists: { _ in true }), [])
    }

    func testStartHintsHaveFlexibleWidthAndFolderAction() throws {
        let text = try source("Views/MainWindowView.swift")
        XCTAssertFalse(text.contains(".frame(width: 310)"))
        XCTAssertTrue(text.contains("minWidth: 240"))
        XCTAssertTrue(text.contains("appState.openFolder() }"))
    }

    func testMarkdownShortcutsAreUniqueAcrossCommands() throws {
        let text = try source("App/LacEditorCommands.swift")
        let regex = try NSRegularExpression(pattern: #"\.keyboardShortcut\(\s*"([^"]+)",\s*modifiers:\s*(\[[^\]]*\]|\.[a-z]+)\)"#)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        for match in regex.matches(in: text, range: range) {
            let key = (text as NSString).substring(with: match.range(at: 1))
            let mods = (text as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: " ", with: "")
            let normalized = mods.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").sorted().joined(separator: ",")
            XCTAssertTrue(seen.insert(key + "|" + normalized).inserted, "duplicate shortcut \(key) \(mods)")
        }
        XCTAssertTrue(text.contains("(\"k\", modifiers: .command)"))
        XCTAssertTrue(text.contains("(\"k\", modifiers: [.command, .shift])"))
        XCTAssertTrue(text.contains("(\"x\", modifiers: [.command, .shift])"))
        XCTAssertTrue(text.contains("modifiers: [.command, .option])"))
    }

    func testHelpMenuOpensProjectPage() throws {
        let text = try source("App/LacEditorCommands.swift")
        XCTAssertTrue(text.contains("CommandGroup(replacing: .help)"))
        XCTAssertTrue(text.contains("https://github.com/LKosoj/LacEditor"))
        XCTAssertTrue(text.contains("L10n.tr(\"LacEditor 帮助\")"))
    }

    func testImageCommandsLiveInSubmenu() throws {
        let text = try source("App/LacEditorCommands.swift")
        let start = try XCTUnwrap(text.range(of: "Menu(L10n.tr(\"图片管理\"))"))
        let tail = String(text[start.upperBound...])
        let end = try XCTUnwrap(tail.range(of: "ForEach(1...6"))
        let block = String(tail[..<end.lowerBound])
        for key in ["设置图片资源根路径…", "复制选中图片到…", "复制全部图片到…", "下载全部网络图片到…",
                    "移动或重命名图片…", "移动全部图片到…", "删除图片及原文件…", "上传选中图片", "上传全部本地图片"] {
            XCTAssertTrue(block.contains("L10n.tr(\"\(key)\")"), key)
        }
        XCTAssertFalse(block.contains("L10n.tr(\"图片…\")"))
    }

    func testQuickOpenHighlightMatching() {
        XCTAssertEqual(QuickOpenHighlight.matchedOffsets(query: "rea", in: "README.md"), [0, 1, 2])
        XCTAssertEqual(QuickOpenHighlight.matchedOffsets(query: "rdm", in: "README.md"), [0, 3, 4])
        XCTAssertEqual(QuickOpenHighlight.matchedOffsets(query: "zz", in: "a.md"), [])
        XCTAssertEqual(QuickOpenHighlight.matchedOffsets(query: "", in: "a.md"), [])
        XCTAssertEqual(QuickOpenHighlight.matchedOffsets(query: "记", in: "笔记.md"), [1])
        XCTAssertEqual(QuickOpenHighlight.matchedOffsets(query: "a", in: "👨‍👩‍👧a.md"), [1])
    }

    func testQuickOpenRowUsesSystemSelectionAndHover() throws {
        let text = try source("Views/QuickOpenPanel.swift")
        XCTAssertTrue(text.contains("selectedContentBackgroundColor"))
        XCTAssertTrue(text.contains("onHover"))
        XCTAssertFalse(text.contains("selectionFill"))
    }

    func testStatusCursorButtonShowsHoverFeedback() throws {
        let text = try source("Views/StatusBarView.swift")
        let marker = try XCTUnwrap(text.range(of: "status.cursor"))
        let before = String(text[..<marker.lowerBound].suffix(900))
        XCTAssertTrue(before.contains("QuietActionButtonStyle()"))
        XCTAssertFalse(before.contains(".buttonStyle(.plain)"))
    }
}

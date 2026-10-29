import XCTest
@testable import LacEditor

final class UIPolishKTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("LacEditor/" + relative), encoding: .utf8)
    }

    private func catalog(_ lang: String) throws -> String { try source("\(lang).lproj/Localizable.strings") }

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testFindQueryFieldHasSearchAppearance() throws {
        let text = try source("Views/FindReplaceView.swift")
        XCTAssertTrue(text.contains("magnifyingglass"))
        XCTAssertTrue(text.contains("xmark.circle.fill"))
        XCTAssertTrue(text.contains("find.clear"))
        XCTAssertTrue(text.contains("find.query"))
        XCTAssertEqual(count(of: ".onKeyPress(keys: [.escape]", in: text), 3)
        XCTAssertEqual(count(of: ".onKeyPress(keys: [.return]", in: text), 3)
        let lines = text.components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex { $0.contains("TextField(L10n.tr(\"输入要查找的内容\")") })
        for line in lines[index...min(index + 2, lines.count - 1)] {
            XCTAssertFalse(line.contains("roundedBorder"))
        }
    }

    func testNoMatchesMessageIsNeutral() throws {
        let text = try source("Views/FindReplaceView.swift")
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains("L10n.tr(\"未找到匹配内容\")") })
        XCTAssertTrue(line.contains(".secondary"))
        XCTAssertFalse(line.contains(".red"))
    }

    func testClearButtonDoesNotBypassQueryObserver() throws {
        let text = try source("Views/FindReplaceView.swift")
        XCTAssertTrue(text.contains("state.query = \"\""))
        XCTAssertTrue(text.contains(".onChange(of: state.query) { queryOptionsChanged() }"))
    }

    func testAcceptAllUsesSingleParameterizedKey() throws {
        let text = try source("Views/AIWritingView.swift")
        XCTAssertFalse(text.contains("L10n.tr(\"全部接受\") +"))
        XCTAssertTrue(text.contains("L10n.tr(\"全部接受（%lld）\""))
        XCTAssertTrue(L10n.tr("全部接受（%lld）", 3).contains("3"))
    }

    func testAIPanelHeadingsAreHeaders() throws {
        for (file, title) in [("Views/AIWritingView.swift", "AI 写作助手"), ("Views/AIDocumentToolsView.swift", "文本差异")] {
            let line = try XCTUnwrap(try source(file).components(separatedBy: "\n").first { $0.contains("L10n.tr(\"\(title)\")") })
            XCTAssertTrue(line.contains(".isHeader"), file)
        }
    }

    func testDocumentToolsRemoveButtonNamesItsInput() throws {
        let tools = try source("Views/AIDocumentToolsView.swift")
        XCTAssertTrue(tools.contains("L10n.tr(\"移除 %@\""))
        XCTAssertGreaterThanOrEqual(count(of: "truncationMode(.middle)", in: tools), 2)
        XCTAssertTrue(try source("Views/AIWritingView.swift").contains(".accessibilityLabel(L10n.tr(\"图片\"))"))
    }

    func testNewKeysPresentInAllCatalogs() throws {
        let keys = ["全部接受（%lld）", "移除 %@", "清除", "图片"]
        for key in keys {
            var placeholders: [Int] = []
            for lang in ["zh-Hans", "en", "ru"] {
                let text = try catalog(lang)
                let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("\"\(key)\" = \"") }, "\(lang): \(key)")
                let value = String(line.dropFirst("\"\(key)\" = \"".count))
                placeholders.append(count(of: "%@", in: value) + count(of: "%lld", in: value))
            }
            XCTAssertEqual(Set(placeholders).count, 1, key)
        }
    }
}

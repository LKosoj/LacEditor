import XCTest
@testable import LacEditor

final class CriticMarkupRenderTests: XCTestCase {
    private func body(_ text: String, _ mode: CriticMarkupRenderMode?) -> String {
        MarkdownRenderer.renderPage(text, darkMode: false, critic: mode).body
    }

    func testShowWrapsEditsInTags() {
        let html = body("a {++new++} {--old--} {==mark==}{>>note<<} b", .show)
        XCTAssertTrue(html.contains("<ins class=\"critic-ins\">new</ins>"))
        XCTAssertTrue(html.contains("<del class=\"critic-del\">old</del>"))
        XCTAssertTrue(html.contains("<mark class=\"critic-hl\">mark</mark>"))
        XCTAssertTrue(html.contains("class=\"critic-comment\""))
        XCTAssertFalse(html.contains("{++"))
    }

    func testResultAndOriginalResolveEdits() {
        let text = "a {++new++}{--old--} b {~~x~>y~~}"
        let result = body(text, .result), original = body(text, .original)
        XCTAssertTrue(result.contains("new") && result.contains("y") && !result.contains("old") && !result.contains("<ins"))
        XCTAssertTrue(original.contains("old") && original.contains("x") && !original.contains("new") && !original.contains("<del"))
    }

    func testCodeIsUntouched() {
        let html = body("`{++a++}`\n\n```\n{--b--}\n```\n", .show)
        XCTAssertTrue(html.contains("{++a++}"))
        XCTAssertTrue(html.contains("{--b--}"))
        XCTAssertFalse(html.contains("critic-ins"))
    }

    func testNilModeAndPlainTextAreUnchanged() {
        XCTAssertTrue(body("{++a++}", nil).contains("{++a++}"))
        let prepared = CriticMarkupRender.prepare("plain", mode: .show, syntax: .init())
        XCTAssertNil(prepared.markerBase)
        XCTAssertEqual(prepared.text, "plain")
    }

    func testShowKeepsLineCount() {
        let text = "a {>>one\ntwo\nthree<<} b\n{++x\ny++}\n"
        let prepared = CriticMarkupRender.prepare(text, mode: .show, syntax: .init())
        XCTAssertEqual(prepared.text.filter { $0 == "\n" }.count, text.filter { $0 == "\n" }.count)
    }

    func testCommentLabelIsEscaped() {
        let html = body("x {>>say \"hi\" <b>&[1]<<}", .show)
        XCTAssertFalse(html.contains("<b>&"))
        XCTAssertTrue(html.contains("&quot;hi&quot;"))
    }

    func testUserPrivateUseCharactersSurvive() {
        let user = "\u{E010}\u{E011}"
        let html = body("\(user) {++a++}", .show)
        XCTAssertTrue(html.contains(user))
        XCTAssertTrue(html.contains("<ins class=\"critic-ins\">a</ins>"))
    }

    func testResolvedSelectionMapping() {
        let text = "ab{++XY++}cd"
        let result = CriticMarkupRender.resolved(text, accept: true, selection: NSRange(location: 0, length: 12), syntax: .init())
        XCTAssertEqual(result.text, "abXYcd")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 6))
        let tail = CriticMarkupRender.resolved(text, accept: false, selection: NSRange(location: 10, length: 2), syntax: .init())
        XCTAssertEqual(tail.text, "abcd")
        XCTAssertEqual(tail.selection, NSRange(location: 2, length: 2))
    }

    func testPreviewColorsMeetContrast() {
        func lum(_ hex: String) -> Double {
            let value = Int(hex.dropFirst(), radix: 16)!
            func lin(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(value >> 16) + 0.7152 * lin((value >> 8) & 255) + 0.0722 * lin(value & 255)
        }
        func ratio(_ pair: CriticMarkupPreviewStyle.Pair) -> Double {
            let a = lum(pair.text), b = lum(pair.background)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for palette in [CriticMarkupPreviewStyle.light, CriticMarkupPreviewStyle.dark, CriticMarkupPreviewStyle.contrast] {
            for pair in [palette.ins, palette.del, palette.hl, palette.comment] {
                XCTAssertGreaterThanOrEqual(ratio(pair), 4.5, "\(pair.text) on \(pair.background)")
            }
        }
    }

    func testMarkersNeverLeakAndHeadingIdsStayPlain() {
        let page = MarkdownRenderer.renderPage("# Title {++add++}\n\n[l](#title-add)\n", darkMode: false, critic: .show)
        let leaked = page.body.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }
        XCTAssertFalse(leaked)
        for id in page.headingIDs {
            XCTAssertTrue(id.unicodeScalars.allSatisfy { !(0xE000...0xF8FF).contains($0.value) }, id)
        }
    }

    func testEditAcrossBlocksStaysBalanced() {
        let html = body("{++one\n\ntwo++}", .show)
        // Правка не пересекает пустую строку: сервис её не разбирает, служебных символов быть не должно.
        XCTAssertFalse(html.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        let crossing = body("**bold {++one** two++}", .show)
        XCTAssertEqual(crossing.components(separatedBy: "<ins").count, crossing.components(separatedBy: "</ins>").count)
        XCTAssertEqual(crossing.components(separatedBy: "<strong>").count, crossing.components(separatedBy: "</strong>").count)
    }

    func testTablesFrontMatterAndMathAreUntouched() {
        let text = "---\ntitle: {++x++}\n---\n\n| A |\n|---|\n| {--b--} |\n\n$$\n{++m++}\n$$\n"
        let prepared = CriticMarkupRender.prepare(text, mode: .result, syntax: .init())
        XCTAssertEqual(prepared.text, text)
    }

    func testMarkerInLinkTargetAndAltIsRemoved() {
        let html = body("[a {++b++}](http://x.test/p) ![alt {++c++}](http://x.test/i.png)", .show)
        XCTAssertFalse(html.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
    }

    func testUnsavedTextGoesThroughPrepare() {
        let prepared = CriticMarkupRender.prepare("not saved {++yet++}", mode: .result, syntax: .init())
        XCTAssertEqual(prepared.text, "not saved yet")
    }

    func testStageSixStringsExistInAllCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let keys = ["预览中的修订", "显示修订", "仅看结果", "仅看原文", "修订导出", "干净版本（接受所有修订）", "原文（拒绝所有修订）",
                    "带修订（Word 修订与批注）", "此格式不支持修订，将保留原始标记", "批注：%@"]
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys { XCTAssertFalse(dictionary[key]?.isEmpty ?? true, "\(language): \(key)") }
        }
    }
}

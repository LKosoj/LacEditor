import XCTest
@testable import LacEditor

final class VaultOwnerZoneTests: XCTestCase {
    private let start = VaultOwnerZone.startMarker
    private let end = VaultOwnerZone.endMarker

    private func page(zone: String, nl: String = "\n") -> String {
        "---\ntype: compiled\n---\n# Тема\(nl)\(nl)## Owner Notes\(nl)\(start)\(nl)\(zone)\(end)\(nl)Хвост\(nl)"
    }

    private func zone(_ text: String) -> NSRange? {
        if case .editable(let range) = VaultOwnerZone.state(of: text) { return range }
        return nil
    }

    private func sub(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    // MARK: state

    func testEditableRangeIsBetweenMarkers() {
        let text = page(zone: "моя заметка\n")
        let range = zone(text)
        XCTAssertNotNil(range)
        XCTAssertEqual(sub(text, range!), "\nмоя заметка\n")
    }

    func testNoMarkersNoHeadingIsMissing() {
        XCTAssertEqual(VaultOwnerZone.state(of: "# Просто текст\n"), .missing)
        XCTAssertEqual(VaultOwnerZone.state(of: ""), .missing)
    }

    func testSingleMarkerMentionedInProseIsDamaged() {
        XCTAssertEqual(VaultOwnerZone.state(of: "Метка \(start) в тексте\n"), .damaged)
    }

    func testHeadingWithoutMarkersIsDamaged() {
        XCTAssertEqual(VaultOwnerZone.state(of: "## Owner Notes\nтекст\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "##   Owner Notes  \nтекст\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "## Owner Notes\r\nтекст\r\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "# A\r## Owner Notes\rтекст"), .damaged)
    }

    func testPopulatedFlagWithoutMarkersIsDamaged() {
        XCTAssertEqual(VaultOwnerZone.state(of: "---\nhuman_zone_populated: true\n---\nтекст\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "---\nhuman_zone_populated: false\n---\nтекст\n"), .missing)
        XCTAssertEqual(VaultOwnerZone.state(of: "---\ntype: x\n---\nhuman_zone_populated: true\n"), .missing)
    }

    func testBrokenMarkerCombinationsAreDamaged() {
        XCTAssertEqual(VaultOwnerZone.state(of: "\(start)\na\n\(end)\n\(start)\nb\n\(end)\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "\(start)\nтекст\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "текст\n\(end)\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "\(start)\n\(start)\n\(end)\n"), .damaged)
        XCTAssertEqual(VaultOwnerZone.state(of: "\(end)\nтекст\n\(start)\n"), .damaged)
    }

    func testEmptyZone() {
        let text = "a\n\(start)\(end)\nb"
        let range = zone(text)
        XCTAssertEqual(range, NSRange(location: 2 + start.utf16.count, length: 0))
    }

    func testCRLFPageZoneRange() {
        let text = page(zone: "строка\r\n", nl: "\r\n")
        XCTAssertEqual(sub(text, zone(text)!), "\r\nстрока\r\n")
    }

    func testUTF16OffsetsWithEmojiAndChinese() {
        let text = "😀 笔记\n\(start)\n😀 тест 汉字\n\(end)\n"
        let range = zone(text)!
        XCTAssertEqual(sub(text, range), "\n😀 тест 汉字\n")
        XCTAssertEqual(range.location, "😀 笔记\n".utf16.count + start.utf16.count)
    }

    func testMarkersInsideHeaderCountedLikeServer() {
        let text = "---\nnote: \(start)\n---\n\(start)\nx\n\(end)\n"
        XCTAssertEqual(VaultOwnerZone.state(of: text), .damaged)
    }

    func testUnixLineSeparatorsOnlyForRegex() {
        // \u{85} и \u{2028} не границы строк, как "^" и "$" в Python
        XCTAssertEqual(VaultOwnerZone.state(of: "x\u{2028}## Owner Notes\n"), .missing)
        XCTAssertEqual(VaultOwnerZone.state(of: "x\u{85}## Owner Notes\n"), .missing)
        XCTAssertEqual(VaultOwnerZone.state(of: "## Owner Notes\u{2028}y\n"), .missing)
        XCTAssertEqual(VaultOwnerZone.state(of: "x\n## Owner Notes\n"), .damaged)
    }

    // MARK: allowsEdit

    private func allowed(_ text: String, _ location: Int, _ length: Int, _ replacement: String) -> Bool {
        VaultOwnerZone.allowsEdit(in: text, range: NSRange(location: location, length: length), replacement: replacement)
    }

    func testTypingInsideAndEmptyZone() {
        let text = page(zone: "abc\n")
        let z = zone(text)!
        XCTAssertTrue(allowed(text, z.location + 2, 0, "x"))
        let empty = "a\n\(start)\(end)\nb"
        XCTAssertTrue(allowed(empty, zone(empty)!.location, 0, "x"))
    }

    func testInsertAtZoneBoundsAllowed() {
        let text = page(zone: "abc\n")
        let z = zone(text)!
        XCTAssertTrue(allowed(text, z.location, 0, "x"))
        XCTAssertTrue(allowed(text, NSMaxRange(z), 0, "x"))
    }

    func testInsertOutsideDenied() {
        let text = page(zone: "abc\n")
        let z = zone(text)!
        XCTAssertFalse(allowed(text, z.location - start.utf16.count, 0, "x"))
        XCTAssertFalse(allowed(text, NSMaxRange(z) + end.utf16.count, 0, "x"))
        XCTAssertFalse(allowed(text, 0, 0, "x"))
    }

    func testDeleteAcrossMarkerDenied() {
        let text = page(zone: "abc\n")
        let z = zone(text)!
        XCTAssertFalse(allowed(text, z.location - 1, 2, ""))
        XCTAssertFalse(allowed(text, NSMaxRange(z) - 1, 2, ""))
        XCTAssertFalse(allowed(text, z.location - 1, z.length + 2, "x"))
    }

    func testReplaceWholeZoneAllowed() {
        let text = page(zone: "abc\n")
        XCTAssertTrue(allowed(text, zone(text)!.location, zone(text)!.length, "новый"))
    }

    func testDeleteOneCharacterOfMarkerDenied() {
        let text = page(zone: "abc\n")
        let z = zone(text)!
        for location in [z.location - start.utf16.count, z.location - 1, NSMaxRange(z), NSMaxRange(z) + end.utf16.count - 1] {
            XCTAssertFalse(allowed(text, location, 1, ""), "\(location)")
        }
    }

    func testEditOutsideZoneDenied() {
        let text = page(zone: "abc\n")
        XCTAssertFalse(allowed(text, 5, 1, "x"))
        XCTAssertFalse(allowed(text, (text as NSString).length - 3, 1, "x"))
        XCTAssertFalse(allowed(text, (text as NSString).range(of: "Owner").location, 5, ""))
    }

    func testPasteContainingMarkerDenied() {
        let text = page(zone: "abc\n")
        let z = zone(text)!
        XCTAssertFalse(allowed(text, z.location + 1, 0, end))
        XCTAssertFalse(allowed(text, z.location + 1, 0, start))
        XCTAssertTrue(allowed(text, z.location + 1, 0, "<!-- человек -->"))
        let split = "a\n\(start)\n<!-- human:e" + "x" + "nd -->\n\(end)\n"
        let xAt = (split as NSString).range(of: "x").location
        XCTAssertFalse(allowed(split, xAt, 1, ""))
    }

    func testNoZoneStatesDenyNonEmptyEdits() {
        let texts = ["просто\n", "## Owner Notes\nx\n", "\(start)\na\n\(end)\n\(start)\nb\n\(end)\n", "\(end)\n\(start)\n"]
        for text in texts {
            XCTAssertFalse(allowed(text, 0, 0, "x"), text)
            XCTAssertTrue(allowed(text, 0, 0, ""), text)
        }
    }

    func testRangeOutOfBoundsDenied() {
        let text = page(zone: "abc\n")
        XCTAssertFalse(allowed(text, -1, 1, ""))
        XCTAssertFalse(allowed(text, 0, -1, ""))
        XCTAssertFalse(allowed(text, (text as NSString).length, 1, ""))
    }

    func testCRLFEditAtBoundary() {
        let text = page(zone: "abc\r\n", nl: "\r\n")
        let z = zone(text)!
        XCTAssertTrue(allowed(text, NSMaxRange(z), 0, "\r\n"))
        XCTAssertTrue(allowed(text, NSMaxRange(z) - 2, 2, ""))
        XCTAssertFalse(allowed(text, z.location - 1, 1, ""))
        XCTAssertFalse(allowed(text, NSMaxRange(z), 1, ""))
    }

    func testEmojiAndSurrogatePairBoundaries() {
        let text = page(zone: "😀 тест\n")
        let z = zone(text)!
        XCTAssertTrue(allowed(text, z.location + 2, 1, "x"))
        XCTAssertFalse(allowed(text, z.location - 1, 3, ""))
        XCTAssertTrue(allowed(text, z.location, 0, "😀"))
        XCTAssertTrue(allowed(text, NSMaxRange(z), 0, "😀"))
    }

    func testThreeLanguagesInZone() {
        let text = page(zone: "Привет\nHello\n你好\n")
        let z = zone(text)!
        XCTAssertTrue(allowed(text, z.location + 3, 2, "你"))
        XCTAssertTrue(allowed(text, NSMaxRange(z) - 2, 1, "好"))
        XCTAssertFalse(allowed(text, 0, 3, "Привет"))
    }

    // MARK: onlyOwnerZoneChanged

    func testOnlyOwnerZoneChanged() {
        let base = page(zone: "abc\n")
        XCTAssertTrue(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: base))
        XCTAssertTrue(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: page(zone: "другое\nещё\n")))
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: base.replacingOccurrences(of: "Тема", with: "Тема2")))
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: base.replacingOccurrences(of: end, with: "<!-- human:End -->")))
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: base.replacingOccurrences(of: "Хвост", with: "Хвост2")))
        let moved = base.replacingOccurrences(of: "abc\n\(end)", with: "abc\n").replacingOccurrences(of: "Хвост", with: "\(end)Хвост")
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: moved))
    }

    func testOnlyOwnerZoneChangedWithoutZone() {
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: "a\n", candidate: "b\n"))
        XCTAssertTrue(VaultOwnerZone.onlyOwnerZoneChanged(base: "a\n", candidate: "a\n"))
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: "## Owner Notes\n", candidate: "x\n"))
        XCTAssertFalse(VaultOwnerZone.onlyOwnerZoneChanged(base: page(zone: "a\n"), candidate: "b\n"))
    }

    func testOnlyOwnerZoneChangedCRLFInZone() {
        let base = page(zone: "a\n")
        XCTAssertTrue(VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: page(zone: "a\r\n")))
    }

    // MARK: pageKind

    func testPageKind() {
        for path in ["compiled/топик.md", "compiled/a/b.md"] {
            XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: path), .compiled, path)
        }
        for path in ["summaries/2026-W44-summary.md", "MOC/compiled-index.md"] {
            XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: path), .serverReport, path)
        }
        XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: "compiled/\u{301}x.md"), .compiled)
        XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: "compiled/x.txt"), .regular)
        XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: "compiled/"), .regular)
        XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: "compiled/a/b.png"), .regular)
        for path in ["compiled.md", "my/compiled/x.md", "MOC/index.md", "daily/2026-11-03.md", "Compiled/x.md"] {
            XCTAssertEqual(VaultOwnerZone.pageKind(forServerPath: path), .regular, path)
        }
    }
}

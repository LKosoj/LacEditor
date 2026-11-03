import XCTest
@testable import LacEditor

final class VaultOwnerZoneEditorTests: XCTestCase {
    private let start = VaultOwnerZone.startMarker
    private let end = VaultOwnerZone.endMarker

    private func page(zone: String, nl: String = "\n") -> String {
        "---\ntype: compiled\n---\n# Тема\(nl)\(nl)## Owner Notes\(nl)\(start)\(nl)\(zone)\(end)\(nl)Хвост\(nl)"
    }

    private func zone(_ text: String) -> NSRange? {
        if case .editable(let range) = VaultOwnerZone.state(of: text) { return range }
        return nil
    }

    private func make(_ text: String, path: String = "compiled/x.md") -> VaultPageGuard {
        VaultPageGuard.make(serverPath: path, text: NSString(string: text))!
    }

    private func decide(_ g: VaultPageGuard, _ text: String, _ range: NSRange, _ replacement: String) -> VaultEditDecision {
        g.decide(range: range, replacement: replacement, in: NSString(string: text))
    }

    func testModeForEachPageKind() {
        XCTAssertNil(VaultPageGuard.make(serverPath: "notes/a.md", text: "x"))
        XCTAssertNil(VaultPageGuard.make(serverPath: "compiled/x.json", text: "x"))
        XCTAssertEqual(make(page(zone: "a\n")).mode, .ownerZone)
        XCTAssertEqual(make("# Просто\n").mode, .noZone)
        XCTAssertEqual(make("## Owner Notes\nтекст\n").mode, .damaged)
        XCTAssertEqual(make("\(start)\na\n\(end)\n\(start)\nb\n\(end)\n").mode, .damaged)
        XCTAssertEqual(make("текст", path: "summaries/a.md").mode, .serverReport)
        XCTAssertEqual(make("текст", path: "MOC/compiled-index.md").mode, .serverReport)
    }

    func testAllowInsideZoneDenyOutside() {
        let text = page(zone: "моя заметка\n")
        let z = zone(text)!
        let g = make(text)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location + 5, length: 0), "x"), .allow)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location, length: 0), "x"), .allow)
        XCTAssertEqual(decide(g, text, NSRange(location: NSMaxRange(z), length: 0), "x"), .allow)
        XCTAssertEqual(decide(g, text, NSRange(location: 2, length: 0), "x"), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location - 3, length: 0), "x"), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, NSRange(location: NSMaxRange(z) + 2, length: 0), "x"), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, NSRange(location: (text as NSString).length, length: 0), "x"), .denyOutsideZone)

        let empty = "a\n\(start)\(end)\nb"
        let ge = make(empty)
        XCTAssertEqual(decide(ge, empty, NSRange(location: 2 + start.utf16.count, length: 0), "x"), .allow)
    }

    func testSelectionCrossingBoundaryDenied() {
        let text = page(zone: "заметка\n")
        let z = zone(text)!
        let g = make(text)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location - 1, length: 2), ""), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, NSRange(location: NSMaxRange(z) - 1, length: 2), ""), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, z, "новое"), .allow)
        XCTAssertEqual(decide(g, text, z, ""), .allow)
    }

    func testMarkerFormationDenied() {
        let text = page(zone: "a\n")
        let z = zone(text)!
        let g = make(text)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location + 1, length: 0), end), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location + 1, length: 0), start), .denyOutsideZone)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location + 1, length: 0), "<!-- человек -->"), .allow)

        // сборка метки из частей: «<!-- human:e» + «x» + «nd -->», затем удаление «x»
        let part = page(zone: "<!-- human:ex" + "nd -->\n")
        let zp = zone(part)!
        let gp = make(part)
        let xAt = zp.location + 1 + "<!-- human:e".utf16.count
        XCTAssertEqual(decide(gp, part, NSRange(location: xAt, length: 1), ""), .denyOutsideZone)
    }

    func testEquivalenceWithAllowsEditExhaustive() {
        let text = "ab\n\(start)\nэ😀x <!-- human:e nd -->\n<!-- human\(end)\nzz"
        let zr = zone(text)
        XCTAssertNotNil(zr)
        let length = (text as NSString).length
        let replacements = ["", "x", "\n", "😀", "<!-- human:", "nd -->", start, end, "-->", "<", "human:end -->", "e"]
        for loc in 0...length {
            for len in 0...(length - loc) {
                for r in replacements {
                    let g = make(text)
                    let range = NSRange(location: loc, length: len)
                    let expected = VaultOwnerZone.allowsEdit(in: text, range: range, replacement: r)
                    let got = decide(g, text, range, r) == .allow
                    XCTAssertEqual(got, expected, "range \(range) replacement \(r)")
                }
            }
        }
    }

    func testReadOnlyModesDenyAnyNonEmptyEdit() {
        let cases: [(String, String)] = [("# Просто\n", "compiled/x.md"), ("## Owner Notes\nt\n", "compiled/x.md"), ("отчёт", "summaries/a.md")]
        for (text, path) in cases {
            let g = make(text, path: path)
            XCTAssertEqual(decide(g, text, NSRange(location: 0, length: 0), "x"), .denyReadOnly)
            XCTAssertEqual(decide(g, text, NSRange(location: 0, length: 1), ""), .denyReadOnly)
            XCTAssertEqual(decide(g, text, NSRange(location: 0, length: 0), ""), .allow)
            XCTAssertTrue(g.isReadOnly)
            XCTAssertNil(g.ownerZone)
        }
    }

    func testCacheShiftOnTyping() {
        var text = page(zone: "начало\n")
        let g = make(text)
        XCTAssertEqual(g.fullScanCount, 1)
        for i in 0..<1000 {
            let z = zone(text)!
            let ns = NSMutableString(string: text)
            let range: NSRange
            let rep: String
            if i % 3 == 2 {
                range = NSRange(location: z.location + 1, length: 1)
                rep = ""
            } else {
                range = NSRange(location: NSMaxRange(z) - (i % 2), length: 0)
                rep = i % 5 == 0 ? "ё\n" : "б"
            }
            XCTAssertEqual(g.decide(range: range, replacement: rep, in: ns), .allow)
            ns.replaceCharacters(in: range, with: rep)
            text = ns as String
            g.textDidChange(in: NSString(string: text))
            if i % 100 == 0 { XCTAssertEqual(g.ownerZone, zone(text)) }
        }
        XCTAssertEqual(g.ownerZone, zone(text))
        XCTAssertEqual(g.fullScanCount, 1)
    }

    func testCacheSelfHealsAfterForeignEdit() {
        let text = page(zone: "a\n")
        let g = make(text)
        // внешняя правка другой длины: добавлены символы в шапку
        let changed = "XX" + text
        let z = zone(changed)!
        XCTAssertEqual(decide(g, changed, NSRange(location: z.location, length: 0), "x"), .allow)
        XCTAssertEqual(g.fullScanCount, 2)
        XCTAssertEqual(g.ownerZone, zone(changed))
        XCTAssertEqual(decide(g, changed, NSRange(location: 0, length: 0), "x"), .denyOutsideZone)

        // та же длина, но метки сдвинулись: «XX» убрали из начала и дописали в конец
        let moved = String(changed.dropFirst(2)) + "YY"
        XCTAssertEqual((moved as NSString).length, (changed as NSString).length)
        let zm = zone(moved)!
        XCTAssertEqual(decide(g, moved, NSRange(location: zm.location, length: 0), "x"), .allow)
        XCTAssertEqual(g.fullScanCount, 3)
        XCTAssertEqual(g.ownerZone, zm)
    }

    func testTextDidChangeWithoutDecideDoesNotRescan() {
        let text = page(zone: "a\n")
        let g = make(text)
        let z = zone(text)!
        // правка внутри раздела мимо decide (IME, отмена): сдвиг по длине и сверка меток, без полного прохода
        let ns = NSMutableString(string: text)
        ns.insert("привет", at: z.location + 1)
        g.textDidChange(in: ns)
        XCTAssertEqual(g.fullScanCount, 1)
        XCTAssertEqual(g.ownerZone, zone(ns as String))
        // правка до раздела сдвигает метки: метки не на месте, нужен пересчёт
        ns.insert("XX", at: 0)
        g.textDidChange(in: ns)
        XCTAssertEqual(g.fullScanCount, 2)
        XCTAssertEqual(g.ownerZone, zone(ns as String))
    }

    func testRefreshPublishesModeOnce() {
        let withZone = page(zone: "a\n")
        let g = make(withZone)
        var modes: [VaultPageMode] = []
        g.onModeChange = { modes.append($0) }
        g.refresh(in: NSString(string: "# Страница без раздела\n"))
        XCTAssertEqual(modes, [.noZone])
        g.refresh(in: NSString(string: "# Страница без раздела 2\n"))
        XCTAssertEqual(modes, [.noZone])
        g.refresh(in: NSString(string: "## Owner Notes\n"))
        XCTAssertEqual(modes, [.noZone, .damaged])
        g.refresh(in: NSString(string: withZone))
        XCTAssertEqual(modes, [.noZone, .damaged, .ownerZone])
    }

    func testServerUpdateBypass() {
        let text = page(zone: "a\n")
        let g = make(text)
        g.allowsServerUpdate = true
        XCTAssertEqual(decide(g, text, NSRange(location: 0, length: 3), "Z"), .allow)
        let changed = "Z" + String(text.dropFirst(3))
        g.textDidChange(in: NSString(string: changed))
        g.allowsServerUpdate = false
        XCTAssertEqual(g.ownerZone, zone(changed))
        XCTAssertEqual(decide(g, changed, NSRange(location: 0, length: 0), "q"), .denyOutsideZone)
    }

    func testInvalidateForcesRescan() {
        let text = page(zone: "a\n")
        let g = make(text)
        g.invalidate()
        let z = zone(text)!
        XCTAssertEqual(decide(g, text, NSRange(location: z.location, length: 0), "x"), .allow)
        XCTAssertEqual(g.fullScanCount, 2)
    }

    func testDimRanges() {
        let text = page(zone: "😀 зона\n")
        let z = zone(text)!
        let g = make(text)
        let length = (text as NSString).length
        let startMarkerAt = z.location - start.utf16.count
        let endMarkerEnd = NSMaxRange(z) + end.utf16.count
        XCTAssertEqual(g.dimRanges(intersecting: NSRange(location: 0, length: length), textLength: length),
                       [NSRange(location: 0, length: z.location), NSRange(location: NSMaxRange(z), length: length - NSMaxRange(z))])
        XCTAssertEqual(g.dimRanges(intersecting: NSRange(location: 3, length: 5), textLength: length), [NSRange(location: 3, length: 5)])
        XCTAssertEqual(g.dimRanges(intersecting: NSRange(location: z.location + 1, length: 2), textLength: length), [])
        XCTAssertEqual(g.dimRanges(intersecting: NSRange(location: startMarkerAt, length: endMarkerEnd - startMarkerAt), textLength: length),
                       [NSRange(location: startMarkerAt, length: start.utf16.count), NSRange(location: NSMaxRange(z), length: end.utf16.count)])
        XCTAssertEqual(g.dimRanges(intersecting: NSRange(location: length - 2, length: 10), textLength: length), [NSRange(location: length - 2, length: 2)])
        // суррогатная пара внутри зоны не режется: границы зоны стоят на метках
        XCTAssertEqual(g.dimRanges(intersecting: NSRange(location: z.location, length: 1), textLength: length), [])
        XCTAssertEqual(make("# нет\n").dimRanges(intersecting: NSRange(location: 0, length: 3), textLength: 5), [])
        XCTAssertEqual(make("отчёт", path: "summaries/a.md").dimRanges(intersecting: NSRange(location: 0, length: 3), textLength: 5), [])
    }

    func testDenialThrottle() {
        let g = make(page(zone: "a\n"))
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(g.registerDenial(now: t))
        XCTAssertFalse(g.registerDenial(now: t.addingTimeInterval(0.2)))
        XCTAssertFalse(g.registerDenial(now: t.addingTimeInterval(0.9)))
        XCTAssertTrue(g.registerDenial(now: t.addingTimeInterval(1.1)))
    }

    func testAnnouncementOncePerMode() {
        let g = make(page(zone: "a\n"))
        XCTAssertTrue(g.takeAnnouncement(for: .ownerZone))
        XCTAssertFalse(g.takeAnnouncement(for: .ownerZone))
        XCTAssertTrue(g.takeAnnouncement(for: .noZone))
        XCTAssertTrue(g.takeAnnouncement(for: .ownerZone))
    }

    func testUTF16AndCRLF() {
        for nl in ["\n", "\r\n"] {
            let text = page(zone: "Привет 😀 世界\(nl)", nl: nl)
            let z = zone(text)!
            let g = make(text)
            XCTAssertEqual(decide(g, text, NSRange(location: z.location + 3, length: 0), "я"), .allow)
            XCTAssertEqual(decide(g, text, NSRange(location: z.location - 1, length: 0), "я"), .denyOutsideZone)
            XCTAssertEqual(decide(g, text, NSRange(location: NSMaxRange(z) + 1, length: 0), "я"), .denyOutsideZone)
        }
        // половина пары \r|\n на границе: перенос строки сразу после начальной метки лежит в зоне, \r перед меткой — нет
        let text = page(zone: "z\r\n", nl: "\r\n")
        let z = zone(text)!
        let g = make(text)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location, length: 1), ""), .allow)
        XCTAssertEqual(decide(g, text, NSRange(location: z.location - 1, length: 1), ""), .denyOutsideZone)
    }

    func testUploadCheckMatrix() {
        let base = page(zone: "моё\n")
        XCTAssertTrue(VaultUploadCheck.allows(serverPath: "notes/a.md", base: "a", candidate: "b"))
        XCTAssertTrue(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: base, candidate: base))
        XCTAssertTrue(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: base, candidate: page(zone: "моё\nещё\n")))
        XCTAssertFalse(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: base, candidate: base.replacingOccurrences(of: "Тема", with: "Тема2")))
        XCTAssertFalse(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: base, candidate: base.replacingOccurrences(of: end, with: "")))
        XCTAssertFalse(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: "# нет\n", candidate: "# есть\n"))
        XCTAssertTrue(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: "# нет\n", candidate: "# нет\n"))
        XCTAssertFalse(VaultUploadCheck.allows(serverPath: "compiled/x.md", base: "## Owner Notes\n", candidate: "## Owner Notes\nx"))
        XCTAssertTrue(VaultUploadCheck.allows(serverPath: "summaries/a.md", base: "отчёт", candidate: "отчёт"))
        XCTAssertFalse(VaultUploadCheck.allows(serverPath: "summaries/a.md", base: "отчёт", candidate: "отчёт!"))
    }
}

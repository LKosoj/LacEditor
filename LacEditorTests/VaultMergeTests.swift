import XCTest
@testable import LacEditor

final class VaultMergeTests: XCTestCase {
    private func merge(_ base: String, _ mine: String, _ server: String) -> VaultMergeOutcome {
        VaultMerge.merge(base: base, mine: mine, server: server)
    }

    private func mergedText(_ outcome: VaultMergeOutcome, file: StaticString = #filePath, line: UInt = #line) -> String {
        if case .merged(let text) = outcome { return text }
        XCTFail("ожидалось чистое объединение: \(outcome)", file: file, line: line)
        return ""
    }

    private func conflict(_ outcome: VaultMergeOutcome, file: StaticString = #filePath, line: UInt = #line) -> VaultMergeConflict {
        if case .conflict(let value) = outcome { return value }
        XCTFail("ожидался конфликт: \(outcome)", file: file, line: line)
        return VaultMergeConflict(chunks: [], autoMergedCount: 0)
    }

    private func conflictChunks(_ value: VaultMergeConflict) -> [(id: Int, mine: String, server: String, base: String)] {
        value.chunks.compactMap { chunk in
            if case .conflict(let id, let mine, let server, let base) = chunk { return (id, mine, server, base) }
            return nil
        }
    }

    private func count(_ text: String, _ part: String) -> Int { text.components(separatedBy: part).count - 1 }

    private let daily = "---\ntype: daily\n---\n- 09:00 завтрак\n- 12:00 встреча\n- 18:00 ужин\n"

    // MARK: базовое

    func testIdenticalMineAndServerReturnsMine() {
        XCTAssertEqual(merge("a\n", "b\n", "b\n"), .merged("b\n"))
    }

    func testServerUnchangedReturnsMine() {
        XCTAssertEqual(merge("a\r\nb", "a\r\nB", "a\r\nb"), .merged("a\r\nB"))
    }

    func testMineUnchangedTakesServer() {
        XCTAssertEqual(mergedText(merge("a\nb\nc\n", "a\nb\nc\n", "a\nX\nc\n")), "a\nX\nc\n")
    }

    // MARK: daily

    func testDailyServerAppendsWhileUserEditsMiddle() {
        let mine = daily.replacingOccurrences(of: "12:00 встреча", with: "12:30 встреча с Аней")
        let server = daily + "- 14:05 запись бота\n"
        let text = mergedText(merge(daily, mine, server))
        XCTAssertEqual(text, mine + "- 14:05 запись бота\n")
        XCTAssertEqual(count(text, "запись бота"), 1)
    }

    func testDailyServerAppendsWhileUserEditsLastLine() {
        let mine = daily.replacingOccurrences(of: "18:00 ужин", with: "19:00 ужин с друзьями")
        let server = daily + "- 20:00 бот\n"
        guard case .merged(let text) = merge(daily, mine, server) else { return XCTFail("конфликт") }
        XCTAssertEqual(text, mine + "- 20:00 бот\n")
    }

    func testDailyAutoMergedCount() {
        let mine = "a\nb\nc\n"
        let server = "a\nb\nc\nd\n"
        XCTAssertEqual(mergedText(merge("a\nb\nc\n", "a\nb\nC\n", server)), "a\nb\nC\nd\n")
        _ = mine
    }

    func testDailyAppendWhenBaseHasNoTrailingNewline() {
        let text = mergedText(merge("a\nb", "A\nb", "a\nb\n- запись\n"))
        XCTAssertEqual(text, "A\nb\n- запись\n")
    }

    func testUserAppendsWhileServerEditsLastLine() {
        XCTAssertEqual(mergedText(merge("a\nb\n", "a\nb\nмоё\n", "a\nB\n")), "a\nB\nмоё\n")
    }

    func testBothAppendDifferentTextIsConflict() {
        let value = conflict(merge("a\n", "a\nмоё\n", "a\nсервер\n"))
        let chunks = conflictChunks(value)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].mine, "моё\n")
        XCTAssertEqual(chunks[0].server, "сервер\n")
        XCTAssertEqual(chunks[0].base, "")
        XCTAssertNil(value.resolved(choices: [:]))
        XCTAssertEqual(value.resolved(choices: [0: .both]), "a\nсервер\nмоё\n")
        XCTAssertEqual(value.resolved(choices: [0: .mine]), "a\nмоё\n")
        XCTAssertEqual(value.resolved(choices: [0: .server]), "a\nсервер\n")
    }

    func testBothSideWithoutTrailingNewlineKeepsLines() {
        let value = conflict(merge("a\n", "a\nмоё", "a\nсервер"))
        XCTAssertEqual(value.resolved(choices: [0: .both]), "a\nсервер\nмоё")
    }

    func testBothAppendSameTextNoDuplicate() {
        XCTAssertEqual(mergedText(merge("a\n", "a\nодно\n", "a\nодно\n")), "a\nодно\n")
        XCTAssertEqual(mergedText(merge("a\nz\n", "a\nодно\nz\n", "a\nодно\nz\n")), "a\nодно\nz\n")
    }

    // MARK: шапка

    func testServerChangesHeaderFieldUserChangesBody() {
        let base = "---\ntitle:  Заметка\nlast_accessed: 2026-10-01\nrelevance: 0.5\ntier: warm\n---\nабзац\n"
        let mine = base.replacingOccurrences(of: "абзац", with: "мой абзац")
        let server = base.replacingOccurrences(of: "2026-10-01", with: "2026-11-02")
            .replacingOccurrences(of: "0.5", with: "0.9").replacingOccurrences(of: "warm", with: "hot")
        XCTAssertEqual(mergedText(merge(base, mine, server)),
                       "---\ntitle:  Заметка\nlast_accessed: 2026-11-02\nrelevance: 0.9\ntier: hot\n---\nмой абзац\n")
    }

    func testDifferentHeaderFieldsOnBothSides() {
        let base = "---\ntags:\n  - a\ntier: warm\n---\nтекст\n"
        let mine = "---\ntags:\n  - a\n  - b\ntier: warm\n---\nтекст\n"
        let server = "---\ntags:\n  - a\ntier: hot\n---\nтекст\n"
        XCTAssertEqual(mergedText(merge(base, mine, server)), "---\ntags:\n  - a\n  - b\ntier: hot\n---\nтекст\n")
    }

    func testSameHeaderFieldChangedDifferentlyIsFieldConflict() {
        let base = "---\ntier: warm\n---\nt\n"
        let value = conflict(merge(base, "---\ntier: active\n---\nt\n", "---\ntier: cold\n---\nt\n"))
        let chunks = conflictChunks(value)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].mine, "tier: active\n")
        XCTAssertEqual(chunks[0].server, "tier: cold\n")
        XCTAssertEqual(chunks[0].base, "tier: warm\n")
        XCTAssertEqual(value.resolved(choices: [0: .mine]), "---\ntier: active\n---\nt\n")
        XCTAssertEqual(value.resolved(choices: [0: .server]), "---\ntier: cold\n---\nt\n")
    }

    func testHeaderFieldAddedByServerInsertedAfterPredecessor() {
        let base = "---\ntype: a\ntier: x\n---\nt\n"
        let server = "---\ntype: a\ndescription: new\ntier: x\n---\nt\n"
        let mine = "---\ntype: a\ntier: x\n---\nt!\n"
        XCTAssertEqual(mergedText(merge(base, mine, server)), "---\ntype: a\ndescription: new\ntier: x\n---\nt!\n")
    }

    func testHeaderFieldDeletedByUserStaysDeleted() {
        let base = "---\ntype: a\ntier: x\n---\nt\n"
        let mine = "---\ntype: a\n---\nt\n"
        let server = "---\ntype: a\ntier: x\n---\nt\nещё\n"
        XCTAssertEqual(mergedText(merge(base, mine, server)), "---\ntype: a\n---\nt\nещё\n")
    }

    func testHeaderFieldDeletedByServerEditedByUserIsConflict() {
        let base = "---\ntype: a\ntier: x\n---\nt\n"
        let value = conflict(merge(base, "---\ntype: a\ntier: y\n---\nt\n", "---\ntype: a\n---\nt\n"))
        XCTAssertEqual(value.resolved(choices: [0: .server]), "---\ntype: a\n---\nt\n")
        XCTAssertEqual(value.resolved(choices: [0: .mine]), "---\ntype: a\ntier: y\n---\nt\n")
    }

    func testMultilineHeaderFieldEditedByOneSide() {
        let base = "---\ndescription: |\n  one\n  two\naliases:\n- a\ntier: x\n---\nt\n"
        let mine = base.replacingOccurrences(of: "  two", with: "  two!")
        let server = base.replacingOccurrences(of: "- a\n", with: "- a\n- b\n")
        XCTAssertEqual(mergedText(merge(base, mine, server)),
                       "---\ndescription: |\n  one\n  two!\naliases:\n- a\n- b\ntier: x\n---\nt\n")
    }

    func testHorizontalRuleInBodyIsNotHeaderEnd() {
        let base = "---\ntype: a\n---\nверх\n---\nниз\n"
        let mine = base.replacingOccurrences(of: "верх", with: "ВЕРХ")
        let server = base.replacingOccurrences(of: "низ", with: "НИЗ")
        XCTAssertEqual(mergedText(merge(base, mine, server)), "---\ntype: a\n---\nВЕРХ\n---\nНИЗ\n")
    }

    func testHeaderOnlyOnOneSideMergesAsPlainText() {
        let text = mergedText(merge("тело\nконец\n", "тело\nконец\nмоё\n", "---\ntype: a\n---\nтело\nконец\n"))
        XCTAssertEqual(count(text, "тело"), 1)
        XCTAssertEqual(count(text, "моё"), 1)
        XCTAssertEqual(count(text, "type: a"), 1)
    }

    // MARK: пересечения и удаления

    func testOverlappingBodyEditsAreConflict() {
        let value = conflict(merge("a\nb\nc\nd\ne\n", "a\nb\nM\nd\ne\n", "a\nb\nS\nd\ne\n"))
        let chunks = conflictChunks(value)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].mine, "M\n")
        XCTAssertEqual(chunks[0].server, "S\n")
        XCTAssertEqual(chunks[0].base, "c\n")
        XCTAssertEqual(value.chunks.first, .stable("a\nb\n"))
        XCTAssertEqual(value.chunks.last, .stable("d\ne\n"))
    }

    func testTwoSeparateConflictsHaveSequentialIDs() {
        let base = "a\n1\nb\n2\nc\n"
        let value = conflict(merge(base, "a\nM1\nb\nM2\nc\n", "a\nS1\nb\nS2\nc\n"))
        XCTAssertEqual(conflictChunks(value).map(\.id), [0, 1])
        XCTAssertNil(value.resolved(choices: [0: .mine]))
        XCTAssertEqual(value.resolved(choices: [0: .mine, 1: .mine]), "a\nM1\nb\nM2\nc\n")
        XCTAssertEqual(value.resolved(choices: [0: .mine, 1: .server]), "a\nM1\nb\nS2\nc\n")
        XCTAssertEqual(value.resolved(choices: [0: .server, 1: .mine]), "a\nS1\nb\nM2\nc\n")
        XCTAssertEqual(value.resolved(choices: [0: .server, 1: .server]), "a\nS1\nb\nS2\nc\n")
        XCTAssertEqual(value.resolved(choices: [0: .mine, 1: .mine, 7: .mine]), "a\nM1\nb\nM2\nc\n")
    }

    func testAdjacentLineEditsAreConflict() {
        _ = conflict(merge("a\nb\nc\nd\n", "a\nB\nc\nd\n", "a\nb\nC\nd\n"))
    }

    func testDeletionsMergeCleanly() {
        XCTAssertEqual(mergedText(merge("a\nb\nc\nd\ne\n", "a\nc\nd\ne\n", "a\nb\nc\nd\nE\n")), "a\nc\nd\nE\n")
        XCTAssertEqual(mergedText(merge("a\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n", "a\nc\nd\ne\n")), "a\nc\nd\nE\n")
    }

    func testDeletedOnOneSideEditedOnOtherIsConflict() {
        _ = conflict(merge("a\nb\nc\nd\n", "a\nd\n", "a\nb\nC\nd\n"))
    }

    func testIdenticalEditsOnBothSidesAreNotDuplicated() {
        let value = merge("a\nb\nc\nd\ne\n", "a\nX\nc\nd\nM\n", "a\nX\nc\nd\ne\n")
        XCTAssertEqual(mergedText(value), "a\nX\nc\nd\nM\n")
        XCTAssertEqual(mergedText(merge("a\nb\nc\nd\ne\n", "a\nX\nc\nd\ne\nm\n", "a\nb\nc\nd\nX\ne\n")), "a\nX\nc\nd\nX\ne\nm\n")
    }

    func testIdenticalPrefixOfConflictIsMovedToStable() {
        let value = conflict(merge("a\nb\nz\n", "a\nSAME\nM\nSAME2\nz\n", "a\nSAME\nS\nSAME2\nz\n"))
        let chunks = conflictChunks(value)
        XCTAssertEqual(chunks[0].mine, "M\n")
        XCTAssertEqual(chunks[0].server, "S\n")
        XCTAssertEqual(value.chunks.first, .stable("a\nSAME\n"))
        XCTAssertEqual(value.chunks.last, .stable("SAME2\nz\n"))
    }

    func testAutoMergedCountCountsOnlyServerChanges() {
        let base = (1...12).map { "l\($0)\n" }.joined()
        let server = base.replacingOccurrences(of: "l3\n", with: "S3\n").replacingOccurrences(of: "l6\n", with: "S6\n")
            .replacingOccurrences(of: "l9\n", with: "S9\n")
        let mine = base.replacingOccurrences(of: "l12\n", with: "M12\n")
        XCTAssertEqual(mergedText(merge(base, mine, server)), server.replacingOccurrences(of: "l12\n", with: "M12\n"))
        // чистое объединение счётчик не хранит; проверяем его через конфликт в начале текста
        let value = conflict(merge(base, mine.replacingOccurrences(of: "l1\n", with: "M1\n"),
                                   server.replacingOccurrences(of: "l1\n", with: "S1\n")))
        XCTAssertEqual(value.autoMergedCount, 3)
    }

    // MARK: переводы строк и BOM

    func testCRLFMineWithLFServerInsertionKeepsCRLF() {
        let text = mergedText(merge("a\r\nb\r\nc\r\n", "A\r\nb\r\nc\r\n", "a\r\nb\r\nc\r\nd\n"))
        XCTAssertEqual(text, "A\r\nb\r\nc\r\nd\r\n")
    }

    func testLFMineWithCRLFServerGivesLF() {
        let text = mergedText(merge("a\nb\nc\n", "a\nb\nc\nm\n", "A\r\nb\r\nc\r\n"))
        XCTAssertFalse(text.utf8.contains(13))
        XCTAssertEqual(text, "A\nb\nc\nm\n")
    }

    func testMixedEndingsOfMineArePreservedForUntouchedLines() {
        let text = mergedText(merge("a\nb\r\nc\nd\n", "a\nb\r\nc\nd\nm\n", "A\nb\r\nc\nd\n"))
        XCTAssertEqual(text, "A\nb\r\nc\nd\nm\n")
        let kept = mergedText(merge("a\nb\r\nc\nd\ne\n", "a\nb\r\nc\nd\nE\n", "X\nb\r\nc\nd\ne\n"))
        XCTAssertEqual(kept, "X\nb\r\nc\nd\nE\n")
    }

    func testCRLFAndLFOfSameContentAreNotAChange() {
        XCTAssertEqual(mergedText(merge("a\r\nb\r\n", "A\r\nb\r\n", "a\nb\n")), "A\r\nb\r\n")
    }

    func testLoneCarriageReturnIsNotLineBreak() {
        let text = mergedText(merge("a\rb\nx\ny\nz\n", "a\rb\nx\ny\nZ\n", "A\rb\nx\ny\nz\n"))
        XCTAssertEqual(text, "A\rb\nx\ny\nZ\n")
        let sep = mergedText(merge("a\u{2028}b\nx\ny\nz\n", "a\u{2028}b\nx\ny\nZ\n", "A\u{2028}b\nx\ny\nz\n"))
        XCTAssertEqual(sep, "A\u{2028}b\nx\ny\nZ\n")
    }

    func testBOMOfMineIsKeptOnce() {
        let withBOM = mergedText(merge("a\nb\nc\n", "\u{FEFF}a\nb\nc\nm\n", "A\nb\nc\n"))
        XCTAssertTrue(withBOM.hasPrefix("\u{FEFF}A"))
        XCTAssertEqual(withBOM.unicodeScalars.filter { $0 == "\u{FEFF}" }.count, 1)
        let without = mergedText(merge("a\nb\nc\n", "a\nb\nc\nm\n", "\u{FEFF}A\nb\nc\n"))
        XCTAssertFalse(without.unicodeScalars.contains("\u{FEFF}"))
    }

    func testBOMKeptWhenFirstChunkIsConflict() {
        let value = conflict(merge("a\nz\n", "\u{FEFF}M\nz\n", "S\nz\n"))
        XCTAssertEqual(value.chunks[0], .stable("\u{FEFF}"))
        XCTAssertEqual(value.resolved(choices: [0: .server]), "\u{FEFF}S\nz\n")
    }

    func testConflictChunksUseMineLineEnding() {
        let value = conflict(merge("a\r\nb\r\nc\r\n", "a\r\nM\r\nc\r\n", "a\nS\nc\n"))
        let chunk = conflictChunks(value)[0]
        XCTAssertEqual(chunk.server, "S\r\n")
        XCTAssertEqual(chunk.base, "b\r\n")
        XCTAssertEqual(value.resolved(choices: [0: .server]), "a\r\nS\r\nc\r\n")
    }

    // MARK: пустое и редкое

    func testEmptyCases() {
        XCTAssertEqual(merge("", "", ""), .merged(""))
        XCTAssertEqual(merge("", "", "серв\n"), .merged("серв\n"))
        XCTAssertEqual(merge("", "моё\n", ""), .merged("моё\n"))
        let both = conflict(merge("", "моё\n", "серв\n"))
        XCTAssertEqual(conflictChunks(both)[0].base, "")
        _ = conflict(merge("a\n", "", "a\nb\n"))
        XCTAssertEqual(mergedText(merge("\n\n", "\n\n\n", "\n\n")), "\n\n\n")
    }

    func testMissingFinalNewlineKept() {
        XCTAssertEqual(mergedText(merge("a\nb\nc", "A\nb\nc", "a\nb\nc")), "A\nb\nc")
        XCTAssertEqual(mergedText(merge("a\nb\nc\nd", "A\nb\nc\nd", "a\nb\nc\nD")), "A\nb\nc\nD")
    }

    // MARK: юникод

    func testRussianChineseEnglishLines() {
        let base = "---\ntitle: Заметка\ndescription: 笔记\n---\nHello world\nПривет мир\n你好世界\n"
        let mine = base.replacingOccurrences(of: "Привет мир", with: "Привет, мир!")
        let server = base + "新的一行\n"
        XCTAssertEqual(mergedText(merge(base, mine, server)), mine + "新的一行\n")
    }

    func testEmojiAndSurrogatePairsAreNotSplit() {
        let base = "😀 a\nmid\n👨‍👩‍👧 b\nmid2\n🇷🇺 c\ne\u{301} d\n"
        let mine = base.replacingOccurrences(of: "😀 a", with: "😀 A")
        let server = base.replacingOccurrences(of: "🇷🇺 c", with: "🇷🇺 C")
        let text = mergedText(merge(base, mine, server))
        XCTAssertEqual(text, "😀 A\nmid\n👨‍👩‍👧 b\nmid2\n🇷🇺 C\ne\u{301} d\n")
        XCTAssertEqual(Array(text.utf8), Array(String(decoding: Array(text.utf8), as: UTF8.self).utf8))
    }

    func testCanonicallyEquivalentLinesAreDifferentBytes() {
        let base = "x\nline\nz\n"
        let mine = "x\n\u{E9}\nz\n"
        let server = "x\ne\u{301}\nz\n"
        _ = conflict(merge(base, mine, server))
        XCTAssertEqual(mergedText(merge(base, mine, base)), mine)
    }

    // MARK: прочее

    func testMergeIsIdempotent() {
        let base = daily
        let server = daily + "- бот\n"
        let mine = daily.replacingOccurrences(of: "завтрак", with: "кофе")
        let result = mergedText(merge(base, mine, server))
        XCTAssertEqual(merge(server, result, server), .merged(result))
    }

    func testDeterministicRandomEditsMatchExpected() {
        var seed: UInt64 = 12345
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let join: ([String]) -> String = { $0.map { $0 + "\n" }.joined() }
        for _ in 0..<200 {
            let base = (0..<30).map { "base\($0)" }
            var mine: [String] = [], server: [String] = [], expected: [String] = []
            // Десять блоков по две строки; между блоками нетронутая строка-разделитель.
            for i in stride(from: 0, to: 30, by: 3) {
                let block = Array(base[i..<(i + 2)])
                var edited = block
                switch next(4) {
                case 1: edited = block.map { $0 + "!" }
                case 2: edited = [block[0], "new\(i)", block[1]]
                case 3: edited = [block[1]]
                default: break
                }
                let byMine = next(2) == 0
                mine += byMine ? edited : block
                server += byMine ? block : edited
                expected += edited
                for list in [0, 1, 2] where list >= 0 {
                    let separator = base[i + 2]
                    if list == 0 { mine.append(separator) } else if list == 1 { server.append(separator) } else { expected.append(separator) }
                }
            }
            XCTAssertEqual(merge(join(base), join(mine), join(server)), .merged(join(expected)))
        }
    }

    func testHugeInputFallsBackToSingleConflict() {
        let line = "x\n"
        let base = String(repeating: line, count: 20_001)
        let mine = "m\n" + base
        let server = "s\n" + base
        let value = conflict(merge(base, mine, server))
        XCTAssertEqual(value.chunks, [.conflict(id: 0, mine: mine, server: server, base: base)])
        XCTAssertEqual(value.autoMergedCount, 0)
    }

    func testFiveThousandLinesFinishesQuickly() {
        let base = (0..<5000).map { "line \($0)\n" }
        var mine = base, server = base
        mine[100] = "mine\n"
        server[4000] = "server\n"
        let started = Date()
        let text = mergedText(merge(base.joined(), mine.joined(), server.joined()))
        XCTAssertTrue(text.contains("mine\n") && text.contains("server\n"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testScatteredEditsInLargeFileMerge() {
        let base = (0..<5000).map { "line \($0)\n" }
        var mine = base, server = base
        mine[10] = "mine10\n"
        mine[4990] = "mine4990\n"
        server[2500] = "server2500\n"
        var expected = mine
        expected[2500] = "server2500\n"
        XCTAssertEqual(merge(base.joined(), mine.joined(), server.joined()), .merged(expected.joined()))
        // зеркальный случай: две правки сервера и одна моя
        XCTAssertEqual(merge(base.joined(), server.joined(), mine.joined()), .merged(expected.joined()))
    }

    func testWorstCaseManyDifferencesFallsBackToSingleConflict() {
        let base = (0..<8000).map { "b\($0)\n" }.joined()
        let mine = (0..<8000).map { "m\($0)\n" }.joined()
        let server = (0..<8000).map { "s\($0)\n" }.joined()
        let started = Date()
        let value = conflict(merge(base, mine, server))
        XCTAssertEqual(value.chunks, [.conflict(id: 0, mine: mine, server: server, base: base)])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testServerLineAppearsExactlyOnce() {
        let cases: [(String, String, String)] = [
            (daily, daily.replacingOccurrences(of: "встреча", with: "звонок"), daily + "- СЕРВЕР\n"),
            ("a\nb\nc\n", "a\nb\nC\n", "a\nb\nc\n- СЕРВЕР\n"),
            ("a\n", "a\n- СЕРВЕР\n", "a\n- СЕРВЕР\n"),
            ("a\nb\nc\nd\n", "a\nB\nc\nd\n", "a\nb\nc\nd\n- СЕРВЕР\n")
        ]
        for (base, mine, server) in cases {
            XCTAssertEqual(count(mergedText(merge(base, mine, server)), "- СЕРВЕР"), 1)
        }
    }
}

import XCTest
@testable import LacEditor

fileprivate struct MediaTestRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

final class MarkdownMediaProjectionTests: XCTestCase {
    func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        XCTAssertTrue(condition, message(), line: line)
    }

    /// Круг project -> restore побайтный, токены находятся обратно теми же spans.
    @discardableResult
    func roundTrip(_ source: String, _ table: inout MarkdownMediaTable, line: UInt = #line)
        -> MarkdownMediaTable.Projection {
        let projection = table.project(source)
        let restored = table.restore(projection.text)
        check(Array(restored.text.utf16) == Array(source.utf16), "круг не побайтный: \(source.prefix(80))", line: line)
        check(restored.unknownTokens.isEmpty, "лишние неизвестные токены: \(source.prefix(80))", line: line)
        check(table.spans(in: Array(projection.text.utf16)) == projection.spans, "spans не совпали: \(source.prefix(80))", line: line)
        check(table.unknownTokens(in: Array(projection.text.utf16)).isEmpty, "unknownTokens не пуст", line: line)
        return projection
    }

    func replaced(_ source: String, count: Int = 1, line: UInt = #line) {
        var table = MarkdownMediaTable()
        let projection = roundTrip(source, &table, line: line)
        check(projection.spans.count == count, "ожидалось \(count) токенов, найдено \(projection.spans.count): \(source.prefix(80))", line: line)
        check(count == 0 || projection.text != source, "display не изменился", line: line)
    }

    func untouched(_ source: String, line: UInt = #line) {
        var table = MarkdownMediaTable()
        let projection = table.project(source)
        check(projection.text == source && projection.spans.isEmpty && table.isEmpty, "не должно подменяться: \(source)", line: line)
    }

    // 1-11
    func testRoundTrips() {
        var table = MarkdownMediaTable()
        let first = roundTrip("![a](data:image/png;base64,iVBORw0KGgo=)", &table)
        check(first.spans.count == 1 && !first.text.contains("iVBOR"), "1: токен вместо base64")
        replaced("<img src=\"data:image/png;base64,AAAA\r\nBBBB\r\nCCCC\">")
        replaced("(data:image/png;base64,AAAA")
        replaced("(( data:image/png,%89PNG))")
        replaced("(a (b data:image/png;base64,AAAA) c)")
        replaced("😀data:image/gif;base64,R0lGOD=😀")
        replaced("😀![x](data:image/gif;base64,R0lGOD=)😀")
        replaced("![s](data:image/svg+xml,%3Csvg%3E%3C/svg%3E)")
        replaced("<img src='data:image/svg+xml;utf8,<svg xmlns=\"x\"></svg>'>")
        replaced("DATA:IMAGE/PNG;BASE64,AAAA")
        replaced("Data:Image/Png;Base64,AAAA")
        replaced("data:audio/mpeg;base64,AAAA\ndata:video/mp4;base64,BBBB\ndata:application/pdf;base64,CCCC", count: 3)
        replaced("data:image/png;charset=utf-8;base64,AAAA")
        // решение пользователя: подменяется любой data:тип/подтип
        replaced("data:text/plain,hello")
        replaced("data:text/html;base64,AAAA")
        replaced("data:application/json,{}")
        replaced("data:application/octet-stream;base64,AAAA")
        // токен уже в файле
        let existing = "data:image/png;base64,AA==#lac-media-0123456789abcdef"
        var t = MarkdownMediaTable()
        let p = roundTrip("x \(existing) y", &t)
        check(p.spans.count == 1 && p.text != "x \(existing) y", "8: токен в файле подменяется")
        replaced("[отчёт](data:application/pdf;base64,AAAA)")
        replaced("<data:image/png;base64,AAAA>")
        // 10
        replaced("", count: 0)
        replaced("просто текст\nбез media", count: 0)
        var empty = MarkdownMediaTable()
        check(empty.project("текст").text == "текст" && empty.isEmpty, "10: пустая таблица")
        replaced("<img srcset=\"data:image/png;base64,AAAA 1x, data:image/png;base64,BBBB 2x\">", count: 2)
        var srcset = MarkdownMediaTable()
        let sp = srcset.project("<img srcset=\"data:image/png;base64,AAAA 1x, data:image/png;base64,BBBB 2x\">")
        check(sp.text.contains(" 1x, ") && sp.text.contains(" 2x\">"), "11: хвост 1x не входит в адрес")
        replaced("<img src=\"data:image/png;base64,AAAA\nBBBB\">")
    }

    // 12
    func testNotReplaced() {
        untouched("metadata:image/png,abc")
        untouched("xdata:image/png;base64,AAAA")
        untouched("data:image/png;base64,")
        untouched("![a](data:image/png;base64,)")
        untouched("data:image,..")
        untouched("data:;base64,AAAA")
        untouched("data:image/png base64,AAAA")
        untouched("data:/png,abc")
        untouched("data:image/,abc")
        untouched("data:image/png;base64")
    }

    // 13-16
    func testTable() {
        var table = MarkdownMediaTable()
        let a = "data:image/png;base64,AAAA"
        let two = table.project("\(a) и \(a) и data:image/png;base64,BBBB")
        check(table.entries.count == 2, "13: одна запись на одинаковый адрес")
        check(two.spans[0].entry == two.spans[1].entry && two.spans[0].entry != two.spans[2].entry, "13: токены")
        let again = table.project("\(a) и \(a) и data:image/png;base64,BBBB")
        check(again.text == two.text && table.entries.count == 2, "15: повторный project даёт те же токены")
        var copy = table
        _ = copy.project("data:image/png;base64,CCCC")
        check(copy.entries.count == 3 && table.entries.count == 2, "15: копия независима")
        let token = table.entries[two.spans[0].entry].token
        check(table.source(forToken: token) == a && table.source(forToken: "нет") == nil, "16: source(forToken:)")

        // 14: совпадение хэша
        var clash = MarkdownMediaTable()
        let u1 = Array("data:image/png,aaa".utf8)
        let u2 = Array("data:image/png,bbb".utf8)
        let e1 = u1.withUnsafeBufferPointer { clash.intern($0, headerLength: 14, hash: 5) }
        let e2 = u2.withUnsafeBufferPointer { clash.intern($0, headerLength: 14, hash: 5) }
        let e1again = u1.withUnsafeBufferPointer { clash.intern($0, headerLength: 14, hash: 5) }
        check(e1 != e2 && e1 == e1again, "14: разные записи, повтор находится")
        let t1 = clash.entries[e1].token
        let t2 = clash.entries[e2].token
        check(t1 != t2 && t2.hasSuffix("-1") && !t1.hasSuffix("-1"), "14: суффикс \(t1) \(t2)")
        let restored = clash.restore("\(t1) \(t2)")
        check(restored.text == "data:image/png,aaa data:image/png,bbb" && restored.unknownTokens.isEmpty, "14: оба восстанавливаются")
    }

    func twoTokenSetup() -> (MarkdownMediaTable, MarkdownMediaTable.Projection, [UInt16]) {
        var table = MarkdownMediaTable()
        let projection = table.project("ab data:image/png;base64,AAAAAAAAAAAAAAAAAAAA cd![x](data:audio/mpeg;base64,BBBBBBBBBBBBBBBBBBBBBBBB)ef")
        return (table, projection, Array(projection.text.utf16))
    }

    // 17-22
    func testMapAndEdits() {
        let (table, projection, display) = twoTokenSetup()
        let map = MarkdownMediaMap(spans: projection.spans)
        let s0 = projection.spans[0], s1 = projection.spans[1]
        let d0 = s0.sourceLength - s0.displayLength
        let d1 = s1.sourceLength - s1.displayLength
        check(s0.displayStart == 3 && d0 != 0, "17: настройка")
        check(map.sourcePosition(forDisplay: 0) == 0 && map.sourcePosition(forDisplay: 3) == 3, "17: до токена и на начале")
        check(map.sourcePosition(forDisplay: 10) == 3, "17: внутри, leading")
        check(map.sourcePosition(forDisplay: 10, affinity: .trailing) == 3 + s0.sourceLength, "17: внутри, trailing")
        check(map.sourcePosition(forDisplay: s0.displayEnd) == 3 + s0.sourceLength, "17: на конце токена")
        check(map.sourcePosition(forDisplay: s0.displayEnd + 2) == s0.displayEnd + 2 + d0, "17: после токена")
        check(map.sourcePosition(forDisplay: s1.displayEnd + 1) == s1.displayEnd + 1 + d0 + d1, "17: после двух токенов")
        for p in [0, 3, s0.displayEnd, s0.displayEnd + 2, s1.displayStart, s1.displayEnd, display.count] {
            check(map.displayPosition(forSource: map.sourcePosition(forDisplay: p)) == p, "17: обратное преобразование \(p)")
        }
        check(map.displayPosition(forSource: 10) == 3 && map.displayPosition(forSource: 10, affinity: .trailing) == s0.displayEnd,
              "17: displayPosition внутри адреса")
        // 18
        let whole = NSRange(location: s0.displayStart, length: s0.displayLength)
        check(map.sourceRange(forDisplay: whole) == NSRange(location: 3, length: s0.sourceLength), "18: диапазон токена")
        let partial = NSRange(location: s0.displayStart + 4, length: 3)
        check(map.sourceRange(forDisplay: partial) == NSRange(location: 3, length: s0.sourceLength), "18: диапазон внутри токена")
        let cutting = NSRange(location: 1, length: s0.displayStart + 4 - 1)
        check(map.sourceRange(forDisplay: cutting) == NSRange(location: 1, length: 3 - 1 + s0.sourceLength), "18: обрыв внутри токена")
        check(map.displayRange(forSource: NSRange(location: 3, length: s0.sourceLength)) == whole, "18: displayRange токена")
        check(map.displayRange(forSource: NSRange(location: 6, length: 4)) == whole, "18: displayRange внутри адреса")
        check(map.sourceRange(forDisplay: NSRange(location: 8, length: 0)) == NSRange(location: 3, length: 0), "18: пустой диапазон внутри")
        // 19
        var m = map
        check(m.applyEdit(replacing: NSRange(location: 1, length: 0), withLength: 4) && m.spans[0].displayStart == 7, "19: вставка перед")
        m = map
        check(m.applyEdit(replacing: NSRange(location: s1.displayEnd, length: 0), withLength: 4) && m.spans == map.spans, "19: вставка после")
        m = map
        check(!m.applyEdit(replacing: NSRange(location: s0.displayStart + 5, length: 0), withLength: 1) && m == map, "19: вставка внутри")
        check(!m.applyEdit(replacing: NSRange(location: 1, length: 4), withLength: 0) && m == map, "19: частичное пересечение слева")
        check(!m.applyEdit(replacing: NSRange(location: s0.displayEnd - 1, length: 3), withLength: 0) && m == map, "19: частичное пересечение справа")
        check(m.applyEdit(replacing: NSRange(location: s0.displayStart, length: s0.displayLength), withLength: 0)
              && m.spans.count == 1 && m.spans[0].displayStart == s1.displayStart - s0.displayLength, "19: удаление токена")
        m = map
        check(m.applyEdit(replacing: NSRange(location: 0, length: s1.displayEnd), withLength: 2) && m.isEmpty, "19: замена обоих токенов")
        m = map
        check(m.applyEdit(replacing: NSRange(location: 0, length: 2), withLength: 5) && m.spans[0].displayStart == 6, "19: замена длиннее")
        m = map
        check(m.applyEdit(replacing: NSRange(location: 0, length: 3), withLength: 1) && m.spans[0].displayStart == 1, "19: замена короче")
        // 21
        check(map.intersectsToken(NSRange(location: s0.displayStart + 3, length: 0)), "21: ноль внутри")
        check(!map.intersectsToken(NSRange(location: s0.displayStart, length: 0)) && !map.intersectsToken(NSRange(location: s0.displayEnd, length: 0)), "21: ноль на границах")
        check(map.intersectsToken(NSRange(location: 0, length: 4)) && !map.intersectsToken(NSRange(location: 0, length: 3)), "21: длина>0")
        check(!map.intersectsToken(NSRange(location: s0.displayEnd, length: 2)), "21: сразу после токена")
        check(map.spanIndices(intersecting: NSRange(location: 0, length: display.count)) == 0..<2, "21: оба токена")
        // 22
        let hex = String(table.entries[s0.entry].token.suffix(16))
        let token0 = table.entries[s0.entry].token
        check(table.unknownTokens(in: display).isEmpty, "22: известные не помечаются")
        let unknownHex = token0.replacingOccurrences(of: hex, with: "ffffffffffffffff")
        let broken = token0.dropLast(1)
        let wrongHeader = token0.replacingOccurrences(of: "image/png", with: "image/gif")
        for (name, bad) in [("hex", unknownHex), ("оборванный", String(broken)), ("заголовок", wrongHeader)] {
            let text = "x " + bad + " y"
            let found = table.unknownTokens(in: Array(text.utf16))
            if name == "оборванный" {
                check(found.isEmpty && table.restore(text).text == text, "22: оборванный hex не токен")
            } else {
                check(found == [NSRange(location: 2, length: bad.utf16.count)], "22: \(name) \(found)")
                check(table.restore(text).unknownTokens == found && table.restore(text).text == text, "22: restore оставляет неизвестный \(name)")
            }
        }
        check(table.spans(in: display as [UInt16]) == projection.spans, "22: spans")
        check(table.spans(in: projection.text as NSString) == projection.spans, "22: spans(NSString)")
    }

    // 23
    func testClipboardText() {
        var table = MarkdownMediaTable()
        let p = table.project("data:image/png;base64,AAAAAAAAAAAAAAAAAAAA")
        let token = p.text
        func clip(_ text: String, _ range: NSRange? = nil) -> String {
            let u = Array(text.utf16)
            return table.clipboardText(u, range: range ?? NSRange(location: 0, length: u.count))
        }
        check(clip("текст ![a](\(token)) после") == "текст  после", "23: картинка: \(clip("текст ![a](\(token)) после"))")
        check(clip("![a [b]](\(token) \"t\")x") == "x", "23: картинка с title")
        check(clip("<img src=\"\(token)\" alt=\"x\"> после") == " после", "23: img")
        check(clip("до [отчёт](\(token)) после") == "до отчёт после", "23: ссылка")
        check(clip("<audio src=\"\(token)\"></audio>!") == "!", "23: audio")
        check(clip("<VIDEO controls src='\(token)'>fallback</Video>!") == "!", "23: video")
        check(clip("a \(token) b") == "a  b", "23: голый")
        check(clip("a <\(token)> b") == "a <> b", "23: в угловых")
        check(clip("<img src=\"\(token)\" srcset=\"\(token) 1x\">z") == "z", "23: два токена в теге")
        check(clip("abc \(token)def", NSRange(location: 1, length: 8)) == "bc ", "23: диапазон обрывается внутри токена")
        check(clip("abc \(token)def", NSRange(location: 8, length: token.utf16.count - 1)) == "def", "23: диапазон начинается внутри токена")
        check(clip("просто текст") == "просто текст", "23: без токенов")
    }

    // Буфер обмена: границы токенов и исходник выделения
    func testClipboardRangeSnapsToTokens() {
        var table = MarkdownMediaTable()
        let source = "до ![a](data:image/png;base64,AAAAAAAAAAAAAAAAAAAA) после <audio src=\"data:audio/mp3;base64,BBBBBBBBBBBBBBBB\"></audio>"
        let projection = table.project(source)
        let map = MarkdownMediaMap(spans: projection.spans)
        let display = projection.text as NSString
        let token = display.range(of: "#lac-media-")
        XCTAssertNotEqual(token.location, NSNotFound)
        let partial = NSRange(location: token.location + 3, length: 5)
        XCTAssertTrue(map.intersectsToken(partial))
        let extended = map.displayRange(forSource: map.sourceRange(forDisplay: partial))
        XCTAssertLessThanOrEqual(extended.location, projection.spans[0].displayStart)
        XCTAssertGreaterThanOrEqual(NSMaxRange(extended), projection.spans[0].displayEnd)
        let plain = table.clipboardText(Array(projection.text.utf16), range: extended)
        check(!plain.contains("#lac-media-") && !plain.contains("AAAA"), "E: plain \(plain)")
        let restored = table.restore(display.substring(with: extended)).text
        check(source.contains(restored) && restored.contains("AAAAAAAAAAAAAAAAAAAA"), "E: исходник \(restored)")
        let all = NSRange(location: 0, length: display.length)
        let plainAll = table.clipboardText(Array(projection.text.utf16), range: all)
        check(!plainAll.contains("#lac-media-") && !plainAll.contains("BBBB") && !plainAll.contains("<audio"), "E: весь текст \(plainAll)")
        check(table.restore(projection.text).text == source, "E: restore всего")
    }

    // Замечания ревью
    func testReviewFixes() {
        // 1: `xdata:` с токеноподобным хвостом не неизвестный токен
        for text in ["xdata:image/png,AA==#lac-media-0123456789abcdef", "xdata:image/png;base64,AA==#lac-media-0123456789abcdef",
                     "_data:image/png,AA==#lac-media-0123456789abcdef y"] {
            let table = MarkdownMediaTable()
            check(table.unknownTokens(in: Array(text.utf16)).isEmpty, "ревью 1: не токен: \(text)")
            let restored = table.restore(text)
            check(restored.text == text && restored.unknownTokens.isEmpty, "ревью 1: restore не должен сообщать о неизвестном")
        }
        var known = MarkdownMediaTable()
        let knownToken = known.project("data:image/png;base64,AAAA").text
        check(known.restore("x" + knownToken).text == "xdata:image/png;base64,AAAA", "ревью 1: известный токен после буквы узнаётся")
        check(known.unknownTokens(in: Array(("x" + knownToken).utf16)).isEmpty, "ревью 1: известный после буквы не неизвестный")
        check(known.unknownTokens(in: Array(knownToken.replacingOccurrences(of: "image/png", with: "image/gif").utf16)).count == 1,
              "ревью 1: на границе слова чужой заголовок остаётся неизвестным")

        // 2: незакрытая кавычка
        var quote = MarkdownMediaTable()
        let open = quote.project("<img src=\"data:image/svg+xml,abc def\r\n\r\nтекст \"x\"")
        check(open.spans.count == 1 && quote.entries[0].source == "data:image/svg+xml,abc" && open.text.contains("def\r\n\r\nтекст"),
              "ревью 2: адрес не уходит за пустую строку")
        var quoteBase = MarkdownMediaTable()
        let openBase = quoteBase.project("<img src=\"data:image/png;base64,AAAA\n\nBBBB\">")
        check(openBase.spans.count == 1 && quoteBase.entries[0].source == "data:image/png;base64,AAAA" && openBase.text.contains("BBBB"),
              "ревью 2: base64 не уходит за пустую строку")
        roundTrip("<img src=\"data:image/svg+xml,abc def\n\n\"> и '", &quote)
        var quoteOk = MarkdownMediaTable()
        check(quoteOk.project("<img src='data:image/svg+xml,a b\nc d'>").spans.count == 1 && quoteOk.entries[0].source == "data:image/svg+xml,a b\nc d",
              "ревью 2: закрытая кавычка до пустой строки работает")

        // 3-6: буфер
        var table = MarkdownMediaTable()
        let token = table.project("data:image/png;base64,AAAAAAAAAAAAAAAAAAAA").text
        func clip(_ text: String, _ range: NSRange? = nil) -> String {
            let u = Array(text.utf16)
            return table.clipboardText(u, range: range ?? NSRange(location: 0, length: u.count))
        }
        check(clip("a [![x](\(token))](\(token)) b") == "a  b", "ревью 3: вложенная ссылка: \(clip("a [![x](\(token))](\(token)) b"))")
        check(clip("a [![x](\(token))](\(token) \"t\") b") == "a  b", "ревью 3: вложенная ссылка с title")
        check(clip("x<y \(token) tail") == "x<y  tail", "ревью 4: x<y не тег")
        check(clip("<img\nsrc=\"\(token)\"\nalt=\"x\">!") == "!", "ревью 4: многострочный тег")
        check(clip("<img\n\nsrc=\"\(token)\">") == "<img\n\nsrc=\"\">", "ревью 4: пустая строка прерывает тег")
        check(clip("a > <img src=\"\(token)\"> b") == "a >  b", "ревью 4: лишний > перед тегом")
        check(clip("<video src=\"\(token)\"> <video>x</video>") == " <video>x</video>", "ревью 5: чужой закрывающий тег остаётся")
        check(clip("<video><source src=\"\(token)\"></video>!") == "!", "ревью 5: source внутри video")
        check(clip("<audio controls>\n<source src='\(token)'>\n</AUDIO>!") == "!", "ревью 5: source внутри audio с переносами")
        check(clip("<video src=\"\(token)\">\n\n</video>") == "\n\n</video>", "ревью 5: закрывающий дальше пустой строки не трогаем")
        let link = "[report](\(token))"
        let tokenStart = 9
        check(clip(link, NSRange(location: tokenStart, length: token.utf16.count)) == "", "ревью 6: выделен только токен")
        check(clip(link, NSRange(location: 3, length: link.utf16.count - 3)) == "port", "ревью 6: выделена часть текста ссылки: \(clip(link, NSRange(location: 3, length: link.utf16.count - 3)))")
        check(clip("[a\nb](\(token))") == "[a\nb]()", "ревью 6: `[` ищется только в текущей строке")
        var rng = MediaTestRandom(state: 99)
        for _ in 0..<50 {
            var t = MarkdownMediaTable()
            let projection = t.project(realMediaText(&rng) + " [![x](" + realMediaText(&rng) + ")](data:image/png;base64,ZZZZ)")
            let display = Array(projection.text.utf16)
            for _ in 0..<20 {
                let location = rng.below(display.count)
                let range = NSRange(location: location, length: rng.below(display.count - location + 1))
                let out = t.clipboardText(display, range: range)
                check(!out.contains("#lac-media-") && !out.contains("data:"), "ревью 3: токен в буфере: \(out.prefix(120))")
            }
        }

        // 7: NSString с не-ASCII перед токеном
        var emoji = MarkdownMediaTable()
        let withEmoji = emoji.project("😀 текст ![a](data:image/png;base64,AAAA) 😀")
        check(emoji.spans(in: withEmoji.text as NSString) == withEmoji.spans && withEmoji.spans.count == 1, "ревью 7: spans(NSString)")

        // 8: карта
        let (_, projection, display) = twoTokenSetup()
        let map = MarkdownMediaMap(spans: projection.spans)
        let s0 = projection.spans[0], s1 = projection.spans[1]
        check(map.cutsToken(NSRange(location: s0.displayStart + 3, length: 0)), "ревью 8: точка внутри режет")
        check(map.cutsToken(NSRange(location: 1, length: s0.displayStart + 2 - 1)), "ревью 8: перекрытие слева режет")
        check(map.cutsToken(NSRange(location: s0.displayEnd - 2, length: 5)), "ревью 8: перекрытие справа режет")
        check(!map.cutsToken(NSRange(location: s0.displayStart, length: s0.displayLength)), "ревью 8: накрытие целиком не режет")
        check(!map.cutsToken(NSRange(location: s0.displayStart - 1, length: s0.displayLength + 3)), "ревью 8: накрытие с запасом не режет")
        check(!map.cutsToken(NSRange(location: s0.displayStart, length: 0)) && !map.cutsToken(NSRange(location: s0.displayEnd, length: 0)), "ревью 8: границы не режут")
        check(!map.cutsToken(NSRange(location: 0, length: 3)) && map.cutsToken(NSRange(location: 0, length: display.count)) == false, "ревью 8: вне токенов и весь текст")
        var m = map
        let added = MarkdownMediaSpan(displayStart: 3, displayLength: 5, sourceLength: 50, entry: 7)
        check(m.applyEdit(replacing: NSRange(location: 0, length: 2), withLength: 10, inserting: [added]), "ревью 8: вставка со spans принята")
        check(m.spans.count == 3 && m.spans[0] == added && m.spans[1].displayStart == s0.displayStart + 8
              && m.spans[2].displayStart == s1.displayStart + 8, "ревью 8: порядок и сдвиг \(m.spans)")
        check(m == MarkdownMediaMap(spans: m.spans), "ревью 8: delta пересчитана")
        let before = m
        check(!m.applyEdit(replacing: NSRange(location: s0.displayStart + 2, length: 0), withLength: 1, inserting: [added]) && m == before, "ревью 8: отказ ничего не меняет")
        m = map
        m.applyEdit(replacing: NSRange(location: s0.displayStart, length: s0.displayLength), withLength: 4,
                    inserting: [MarkdownMediaSpan(displayStart: s0.displayStart, displayLength: 4, sourceLength: 9, entry: 3)])
        check(m.spans.count == 2 && m.spans[0].entry == 3 && m.spans[1].displayStart == s1.displayStart - s0.displayLength + 4,
              "ревью 8: замена токена новым")
        m = map
        m.applyEdit(replacing: NSRange(location: s0.displayStart, length: s0.displayLength), withLength: 0)
        check(m.spans.count == 1 && m.spans[0].entry == s1.entry, "ревью 8: удалённый токен исчез из карты")
    }

    // 24-25
    let pieces = ["data:", "image/png", ";base64,", "AAAA", "\r\n", "\n", "(", ")", "\"", "'", "<", ">", "![x](",
                         "<img src=", "😀", " ", "%", "#lac-media-", "0123456789abcdef", ",", ";"]

    fileprivate func randomText(_ rng: inout MediaTestRandom, extra: Bool) -> String {
        let alphabet = extra ? pieces + ["data:image/png;base64,AAAA", "data:image/svg+xml,", "data:text/plain,x", "data:application/pdf;base64,"] : pieces
        var s = ""
        for _ in 0..<rng.below(200) { s += alphabet[rng.below(alphabet.count)] }
        return s
    }

    fileprivate func base64(_ rng: inout MediaTestRandom, length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var s = ""
        for i in 0..<length {
            s.append(alphabet[rng.below(alphabet.count)])
            if i % 76 == 75 { s += rng.below(2) == 0 ? "\n" : "\r\n" }
        }
        return s + "=="
    }

    fileprivate func realMediaText(_ rng: inout MediaTestRandom) -> String {
        let types = ["image/png", "image/jpeg", "audio/mpeg", "video/mp4", "application/pdf", "text/plain"]
        var s = ""
        for _ in 0..<(1 + rng.below(8)) {
            s += ["текст ", "\n\n", "😀 ", "# заголовок\n", "`код` "][rng.below(5)]
            let type = types[rng.below(types.count)]
            let data = "data:\(type);base64," + base64(&rng, length: rng.below(400))
            let flat = data.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            switch rng.below(5) {
            case 0: s += "![a](\(flat))"
            case 1: s += "<img src=\"\(data)\" alt=\"x\">"
            case 2: s += "<audio controls src='\(data)'></audio>"
            case 3: s += "[файл](\(flat)) и <\(flat)>"
            default: s += "![](<\(flat)>) \(flat)"
            }
        }
        return s
    }

    func testRandomRoundTripsAndEdits() {
        var rng = MediaTestRandom(state: 20261101)
        var table = MarkdownMediaTable()
        var withSpans = 0
        for round in 0..<2000 {
            // вторая тысяча: в алфавите есть готовые адреса, чтобы токенов было много
            let text = randomText(&rng, extra: round >= 1000)
            let projection = roundTrip(text, &table)
            if !projection.spans.isEmpty { withSpans += 1 }
            let map = MarkdownMediaMap(spans: projection.spans)
            let display = Array(projection.text.utf16)
            for p in 0...display.count where !map.intersectsToken(NSRange(location: p, length: 0)) {
                let source = map.sourcePosition(forDisplay: p)
                if map.displayPosition(forSource: source) != p { check(false, "24: позиция \(p) в \(text.prefix(60))"); break }
            }
        }
        check(withSpans > 50, "24: случайные тексты должны содержать адреса, нашлось \(withSpans)")
        var edits = 0
        for _ in 0..<50 {
            let text = realMediaText(&rng)
            let projection = roundTrip(text, &table)
            check(!projection.spans.isEmpty, "24: media не найдены")
            var display = Array(projection.text.utf16)
            var source = Array(text.utf16)
            var map = MarkdownMediaMap(spans: projection.spans)
            let inserts = ["", " ", "\n", "😀", "ab ", "слово "].map { Array($0.utf16) }
            for _ in 0..<60 {
                let location = rng.below(display.count + 1)
                let length = rng.below(min(6, display.count - location) + 1)
                let insert = inserts[rng.below(inserts.count)]
                // Одиночные суррогаты в String невозможны, такие правки не делаем.
                func splitsPair(_ p: Int) -> Bool { p > 0 && p < display.count && (0xD800..<0xDC00).contains(display[p - 1]) }
                if splitsPair(location) || splitsPair(location + length) { continue }
                let range = NSRange(location: location, length: length)
                let expectedSource = map.sourceRange(forDisplay: range)
                var next = map
                guard next.applyEdit(replacing: range, withLength: insert.count) else {
                    check(map.spanIndices(intersecting: range).count > 0, "25: отказ без пересечения")
                    continue
                }
                edits += 1
                display.replaceSubrange(location..<(location + length), with: insert)
                source.replaceSubrange(expectedSource.location..<(expectedSource.location + expectedSource.length), with: insert)
                map = next
                check(map == MarkdownMediaMap(spans: table.spans(in: display)), "25: map разошёлся с spans(in:)")
                let restored = table.restore(String(decoding: display, as: UTF16.self))
                check(Array(restored.text.utf16) == source, "25: restore после правок не равен ожидаемому файлу")
            }
        }
        check(edits > 300, "25: принятых правок \(edits)")
    }

    // 26
    func testLargeDocumentTiming() {
        var rng = MediaTestRandom(state: 7)
        let chunk = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=", count: 11_000)
        var text = ""
        let filler = String(repeating: "Строка текста для заполнения файла, пока нет media.\n", count: 20)
        for i in 0..<50 {
            text += filler + "![картинка \(i)](data:image/png;base64,\(chunk)\(rng.below(10)))\n"
        }
        var table = MarkdownMediaTable()
        let start = Date()
        let projection = table.project(text)
        let projectTime = Date().timeIntervalSince(start)
        let restoreStart = Date()
        let restored = table.restore(projection.text)
        let restoreTime = Date().timeIntervalSince(restoreStart)
        check(restored.text.utf16.elementsEqual(text.utf16) && restored.unknownTokens.isEmpty, "26: круг на 20 МБ побайтный")
        check(projection.spans.count == 50 && projection.text.utf16.count < 100_000, "26: display короткий (\(projection.text.utf16.count))")
        let again = Date()
        _ = table.project(text)
        let againTime = Date().timeIntervalSince(again)
        print(String(format: "26: %.1f МБ (UTF-16 %d), 50 media; project %.3f с, повторный project %.3f с, restore %.3f с",
                     Double(text.utf8.count) / 1_048_576, text.utf16.count, projectTime, againTime, restoreTime))
        check(projectTime < 5 && restoreTime < 5, "26: слишком медленно")
    }

    func testSuffixAfterTokenStaysKnownToken() {
        var table = MarkdownMediaTable()
        let token = table.project("![a](data:image/png;base64,AAAA)").text
        let typed = token.replacingOccurrences(of: ")", with: "-1)")
        let units = Array(typed.utf16)
        check(table.spans(in: units).count == 1, "токен с набранным -1 узнан")
        check(table.unknownTokens(in: units).isEmpty, "не неизвестный")
        let restored = table.restore(typed)
        check(restored.text == "![a](data:image/png;base64,AAAA-1)" && restored.unknownTokens.isEmpty, "суффикс вернулся текстом")
    }

    func testSourceBreaksAndSourceLine() {
        var table = MarkdownMediaTable()
        let text = "a\n<img src=\"data:image/png;base64,AA\r\nBB\rCC\nDD\">\nb\n![y](data:image/png;base64,EE)\nc"
        let projection = table.project(text)
        check(projection.spans.map { $0.sourceBreaks } == [3, 0], "sourceBreaks")
        let map = MarkdownMediaMap(spans: projection.spans)
        let cLocation = (projection.text as NSString).range(of: "c", options: .backwards).location
        check(map.sourceLine(forDisplayLine: 4, atDisplayLocation: cLocation) == 7, "строка файла после токенов")
        let measured = MarkdownMediaTable.measureMedia(in: text)
        check(measured.breaks == 3 && measured.bytes == table.entries.reduce(0) { $0 + $1.bytes.count }, "measureMedia")
    }

    func testSnappedRangeKeepsCaretOutsideToken() {
        var table = MarkdownMediaTable()
        let projection = table.project("x ![a](data:image/png;base64,AAAA) y")
        let span = projection.spans[0]
        let map = MarkdownMediaMap(spans: projection.spans)
        let inside = NSRange(location: span.displayStart + 1, length: 0)
        check(map.snappedRange(inside, from: NSRange(location: span.displayStart, length: 0)).location == span.displayEnd, "с левого края вправо")
        check(map.snappedRange(inside, from: NSRange(location: span.displayEnd, length: 0)).location == span.displayStart, "с правого края влево")
        let range = map.snappedRange(NSRange(location: span.displayStart + 2, length: 3), from: NSRange(location: 0, length: 0))
        check(range == NSRange(location: span.displayStart, length: span.displayLength), "выделение расширено до границ токена")
        // Shift+стрелка: сужение через токен не залипает, расширение перепрыгивает токен
        let ds = span.displayStart, de = span.displayEnd
        check(map.snappedRange(NSRange(location: 0, length: de - 1), from: NSRange(location: 0, length: de)) == NSRange(location: 0, length: ds), "конец сужается влево")
        check(map.snappedRange(NSRange(location: 0, length: ds + 1), from: NSRange(location: 0, length: ds)) == NSRange(location: 0, length: de), "конец расширяется вправо")
        let total = (projection.text as NSString).length
        check(map.snappedRange(NSRange(location: ds + 1, length: total - ds - 1), from: NSRange(location: ds, length: total - ds)) == NSRange(location: de, length: total - de), "начало сужается вправо")
        check(map.snappedRange(NSRange(location: de - 1, length: total - de + 1), from: NSRange(location: de, length: total - de)) == NSRange(location: ds, length: total - ds), "начало расширяется влево")
    }

    // MARK: G: входящий текст и расширение правки

    private func token(of projection: MarkdownMediaTable.Projection, _ index: Int = 0) -> String {
        let span = projection.spans[index]
        return (projection.text as NSString).substring(with: NSRange(location: span.displayStart, length: span.displayLength))
    }

    func testIncomingKeepsKnownTokenAndSubstitutesRealData() {
        var table = MarkdownMediaTable()
        let source = "до ![a](data:image/png;base64,AAAAAAAAAAAAAAAA) после"
        let shown = table.project(source)
        let kept = table.incoming(shown.text)
        check(kept.text == shown.text && kept.invalid.isEmpty && kept.spans == shown.spans && table.entries.count == 1, "известный токен")
        check(table.restore(kept.text).text == source, "круг известного токена")
        var other = MarkdownMediaTable()
        let real = other.incoming("![x](data:image/png;base64,QUJDREVGRw==) и <img src=\"data:image/gif;base64,R0lGOD==\">")
        check(real.spans.count == 2 && real.invalid.isEmpty && !real.text.contains("QUJD"), "настоящий data:")
        check(other.incoming(real.text).text == real.text, "повторный вход без изменений")
        let mixed = table.incoming("😀" + shown.text + "é ![y](data:image/png;base64,ZZZZ) 😀")
        check(mixed.spans.count == 2 && mixed.invalid.isEmpty, "смесь")
        check(table.spans(in: Array(mixed.text.utf16)) == mixed.spans, "spans смеси совпали с поиском")
        check(table.restore(mixed.text).text == "😀" + source + "é ![y](data:image/png;base64,ZZZZ) 😀", "круг смеси")
        check(table.incoming("обычный текст").text == "обычный текст", "без data: текст как есть")
    }

    func testIncomingReportsInventedAndDamagedTokens() {
        var table = MarkdownMediaTable()
        let shown = table.project("![a](data:image/png;base64,AAAAAAAAAAAAAAAA)")
        let known = token(of: shown)
        let fake = "![z](data:image/png;base64,AA==#lac-media-0123456789abcdef)"
        check(!table.incoming(fake).invalid.isEmpty, "выдуманный токен")
        check(!table.incoming("![z](" + String(known.dropLast(3)) + ")").invalid.isEmpty, "обрезанный хэш")
        check(!table.incoming("![z](" + known.replacingOccurrences(of: "image/png", with: "image/jpeg") + ")").invalid.isEmpty, "другой заголовок")
        check(!table.incoming("![z](data:image/png;base64,AA==#lac-media-)").invalid.isEmpty, "пустой хэш")
        check(table.incoming("![k](" + known + ") ![z](" + known + ")").invalid.isEmpty, "два одинаковых известных")
        check(table.incoming("![k](" + known + "xyz)").invalid.isEmpty, "хвост после известного токена")
        // Для вставки из буфера выдуманный токен - обычные данные: он обёрнут и восстанавливается побайтно.
        let wrapped = table.incoming(fake)
        check(wrapped.spans.count == 1 && wrapped.text != fake && table.restore(wrapped.text).text == fake, "выдуманный обёрнут как данные")
    }

    func testIncomingDoesNotNestTokens() {
        var table = MarkdownMediaTable()
        let first = table.incoming("![a](data:image/png;base64,AAAA)")
        let again = table.incoming("![b](" + token(of: MarkdownMediaTable.Projection(text: first.text, spans: first.spans)) + ")")
        check(table.entries.count == 1 && again.spans.count == 1 && again.invalid.isEmpty, "токен в токене")
    }

    func testCoveringRangeExtendsToWholeTokens() {
        var table = MarkdownMediaTable()
        let shown = table.project("a ![x](data:image/png;base64,AAAAAAAAAAAAAAAA) b")
        let map = MarkdownMediaMap(spans: shown.spans)
        let s = shown.spans[0]
        let whole = NSRange(location: s.displayStart, length: s.displayLength)
        func cover(_ l: Int, _ n: Int) -> NSRange { map.coveringRange(NSRange(location: l, length: n)) }
        check(cover(s.displayStart + 3, 0) == whole, "точка внутри")
        check(cover(s.displayStart - 2, 4) == NSRange(location: s.displayStart - 2, length: s.displayLength + 2), "левый край")
        check(cover(s.displayEnd - 2, 5) == NSRange(location: s.displayStart, length: s.displayLength + 3), "правый край")
        check(cover(s.displayStart, s.displayLength) == whole, "ровно токен")
        check(cover(s.displayStart, 0) == NSRange(location: s.displayStart, length: 0), "точка на границе")
        check(cover(0, 2) == NSRange(location: 0, length: 2), "не задевает токен")
        check(!map.cutsToken(cover(s.displayStart + 3, 1)), "результат токен не режет")
        check(MarkdownMediaMap().coveringRange(NSRange(location: 3, length: 2)) == NSRange(location: 3, length: 2), "пустая карта")
    }

    func testSanitizerHidesEditorTokenAndOmitsOtherMedia() {
        var table = MarkdownMediaTable()
        let shown = table.project("![a](data:image/png;base64,AAAAAAAAAAAAAAAA) ![b](data:image/svg+xml,%3Csvg%3E)")
        let output = AIRequestMediaSanitizer.sanitize(shown.text)
        check(!output.contains("lac-media") && !output.contains("AA=="), "токены не уходят в модель: \(output)")
        check(!output.contains("[media omitted]"), "токены заменены метками, а не удалены")
        check(AIMediaPlaceholders.shared.restore(output) == shown.text, "метки возвращаются в токены")
        let raw = AIRequestMediaSanitizer.sanitize("![a](data:image/png;base64,AAAA) и " + token(of: shown, 0))
        check(raw.hasPrefix("![a]([media omitted]) и ⟦image "), "настоящие media по-прежнему скрыты: \(raw)")
    }

    func testProfileIgnoresMediaPayload() {
        let payload = String(repeating: "A", count: 21 * 1_048_576)
        let text = "# t\n![a](data:image/png;base64,\(payload))\n"
        let markdown = EditorDocument(text: text, language: .markdown)
        check(markdown.performanceProfile == .standard, "Markdown с 21 МБ media остаётся обычным")
        let plain = EditorDocument(text: text, language: .plainText)
        check(plain.performanceProfile == .large, "обычный текст того же размера большой")
    }

    func testPlaceholderProfileReturnsToStandardWithPreviewAndKeepsOverrides() {
        let document = EditorDocument(language: .markdown, byteCount: 21 * 1_048_576, performanceProfile: .large)
        check(document.performanceProfile == .large && !document.isPreviewVisible, "заполнитель большой, предпросмотр выключен")
        check(!document.isWordCountEnabled && !document.isFoldingEnabled && !document.effectiveWordWrap(globalDefault: true), "функции выключены профилем")
        document.setOverride(false, for: .folding)
        document.updatePerformanceProfile(byteCount: 1_000, lineCount: 10)
        check(document.performanceProfile == .standard, "профиль обычный")
        check(document.isPreviewVisible, "предпросмотр включился обратно")
        check(document.isWordCountEnabled && document.effectiveWordWrap(globalDefault: true), "счёт символов и перенос вернулись")
        check(!document.isFoldingEnabled, "ручное исключение сохранилось")
        // Выключенный пользователем предпросмотр не включается сам.
        let manual = EditorDocument(language: .markdown)
        manual.isPreviewVisible = false
        manual.updatePerformanceProfile(byteCount: 21 * 1_048_576, lineCount: 10)
        manual.updatePerformanceProfile(byteCount: 1_000, lineCount: 10)
        check(!manual.isPreviewVisible, "выбор пользователя сохранён")
        // Ручное переключение при большом профиле отменяет возврат предпросмотра.
        let toggled = EditorDocument(language: .markdown)
        toggled.updatePerformanceProfile(byteCount: 21 * 1_048_576, lineCount: 10)
        toggled.setOverride(false, for: .preview)
        toggled.updatePerformanceProfile(byteCount: 1_000, lineCount: 10)
        check(!toggled.isPreviewVisible, "ручное переключение в большом режиме не отменяется возвратом профиля")
    }
}

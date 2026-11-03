import Foundation

/// Итог трёхстороннего объединения: чистый текст или список кусков с конфликтами.
enum VaultMergeOutcome: Equatable, Sendable {
    case merged(String)
    case conflict(VaultMergeConflict)
}

/// Объединение с конфликтами: куски по порядку текста и число автоматически объединённых участков.
struct VaultMergeConflict: Equatable, Sendable {
    var chunks: [VaultMergeChunk]
    /// Число участков (часть тела или поле шапки), где применена правка сервера без вопроса пользователю.
    var autoMergedCount: Int

    /// Собирает итоговый текст. nil, если не для каждого конфликтного куска есть выбор; лишние ключи игнорируются.
    func resolved(choices: [Int: VaultMergeSide]) -> String? {
        var result = ""
        for chunk in chunks {
            switch chunk {
            case .stable(let text):
                result += text
            case .conflict(let id, let mine, let server, _):
                guard let side = choices[id] else { return nil }
                switch side {
                case .mine: result += mine
                case .server: result += server
                case .both: result += VaultMerge.both(server: server, mine: mine)
                }
            }
        }
        return result
    }
}

/// Кусок результата: общий текст или конфликтное место с тремя версиями (в окончательном виде, с переводами строк).
enum VaultMergeChunk: Equatable, Sendable {
    case stable(String)
    case conflict(id: Int, mine: String, server: String, base: String)
}

/// Выбор в конфликтном куске. `both`: сначала текст сервера, потом мой (оба дописали в конец).
enum VaultMergeSide: Equatable, Sendable { case mine, server, both }

/// Трёхстороннее объединение текста заметки (как diff3): строки сравниваются по байтам, делятся только по `\n`.
enum VaultMerge {
    /// Предел суммы строк трёх текстов, выше которого объединение не считается: один конфликт на весь текст.
    static let maxTotalLines = 20_000
    /// Предел числа правок (вставок и удалений) между базой и каждой из сторон: больше — один общий конфликт.
    static let maxEdits = 2_000

    /// Вызывать только вне главного потока: на больших текстах считает заметное время.
    static func merge(base: String, mine: String, server: String) -> VaultMergeOutcome {
        if mine.utf8.elementsEqual(server.utf8) || server.utf8.elementsEqual(base.utf8) {
            return .merged(mine)
        }
        var interner = Interner()
        let b = split(base, &interner)
        let m = split(mine, &interner)
        let s = split(server, &interner)
        if b.lines.count + m.lines.count + s.lines.count > maxTotalLines {
            return .conflict(VaultMergeConflict(
                chunks: [.conflict(id: 0, mine: mine, server: server, base: base)], autoMergedCount: 0))
        }
        var builder = Builder(dominant: dominantEnding(mine: m, server: s, base: b))
        if let hb = headerEnd(b.lines), let hm = headerEnd(m.lines), let hs = headerEnd(s.lines) {
            mergeHeader(base: b.lines[...hb], mine: m.lines[...hm], server: s.lines[...hs], into: &builder)
            diff3(base: Array(b.lines[(hb + 1)...]), mine: Array(m.lines[(hm + 1)...]),
                  server: Array(s.lines[(hs + 1)...]), into: &builder)
        } else {
            diff3(base: b.lines, mine: m.lines, server: s.lines, into: &builder)
        }
        if builder.tooBig {
            return .conflict(VaultMergeConflict(
                chunks: [.conflict(id: 0, mine: mine, server: server, base: base)], autoMergedCount: 0))
        }
        return builder.finish(bom: m.hasBOM)
    }

    /// Склейка «и то и другое» для конфликтного куска: сначала сервер, потом моё, общая часть один раз.
    fileprivate static func both(server: String, mine: String) -> String {
        if mine == server || server.isEmpty { return mine }
        if mine.isEmpty { return server }
        if server.utf8.last == 10 { return server + mine }
        return server + (mine.utf8.contains(13) || server.utf8.contains(13) ? "\r\n" : "\n") + mine
    }

    // MARK: - Разбор на строки

    private enum LineEnding: Equatable { case none, lf, crlf }

    /// Строка без перевода строки; `key` — номер содержимого (одинаковые байты — одинаковый номер).
    private struct Line {
        var bytes: [UInt8]
        var ending: LineEnding
        var key: Int
    }

    private struct Document {
        var hasBOM: Bool
        var lines: [Line]
    }

    private struct Interner {
        var ids: [[UInt8]: Int] = [:]
        mutating func id(_ bytes: [UInt8]) -> Int {
            if let known = ids[bytes] { return known }
            let next = ids.count
            ids[bytes] = next
            return next
        }
    }

    /// Работа по байтам UTF-8: `\r\n` в Swift один `Character`, а делить нужно только по `\n`.
    private static func split(_ text: String, _ interner: inout Interner) -> Document {
        let bytes = Array(text.utf8)
        var start = 0
        var hasBOM = false
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            hasBOM = true
            start = 3
        }
        var lines: [Line] = []
        var lineStart = start
        var i = start
        while i < bytes.count {
            if bytes[i] == 10 {
                var end = i
                var ending = LineEnding.lf
                if end > lineStart, bytes[end - 1] == 13 {
                    end -= 1
                    ending = .crlf
                }
                let content = Array(bytes[lineStart..<end])
                lines.append(Line(bytes: content, ending: ending, key: interner.id(content)))
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart < bytes.count {
            let content = Array(bytes[lineStart...])
            lines.append(Line(bytes: content, ending: .none, key: interner.id(content)))
        }
        return Document(hasBOM: hasBOM, lines: lines)
    }

    /// Окончание строк результата: как у «моей» версии, при их отсутствии — у сервера, затем базы.
    private static func dominantEnding(mine: Document, server: Document, base: Document) -> LineEnding {
        for doc in [mine, server, base] {
            let crlf = doc.lines.filter { $0.ending == .crlf }.count
            let lf = doc.lines.filter { $0.ending == .lf }.count
            if crlf + lf > 0 { return crlf > lf ? .crlf : .lf }
        }
        return .lf
    }

    // MARK: - Сборка результата

    /// Строка результата с уже решённым окончанием.
    private struct Out {
        var bytes: [UInt8]
        var ending: LineEnding
    }

    private enum Item {
        case lines([Out])
        case conflict(mine: [Out], server: [Out], base: [Out])
    }

    private struct Builder {
        var dominant: LineEnding
        var items: [Item] = []
        var autoMerged = 0
        var tooBig = false

        /// Строки «моей» версии идут как есть.
        func mineOut(_ lines: ArraySlice<Line>) -> [Out] {
            lines.map { Out(bytes: $0.bytes, ending: $0.ending) }
        }

        /// Строки сервера или базы получают окончание «моей» версии.
        func otherOut(_ lines: ArraySlice<Line>) -> [Out] {
            lines.map { Out(bytes: $0.bytes, ending: $0.ending == .none ? .none : dominant) }
        }

        mutating func stable(_ lines: [Out]) {
            guard !lines.isEmpty else { return }
            if case .lines(let previous)? = items.last {
                items[items.count - 1] = .lines(previous + lines)
            } else {
                items.append(.lines(lines))
            }
        }

        mutating func stableMine(_ lines: ArraySlice<Line>) { stable(mineOut(lines)) }
        mutating func stableServer(_ lines: ArraySlice<Line>) { stable(otherOut(lines)) }

        mutating func conflict(mine: ArraySlice<Line>, server: ArraySlice<Line>, base: ArraySlice<Line>) {
            items.append(.conflict(mine: mineOut(mine), server: otherOut(server), base: otherOut(base)))
        }

        private func endingBytes(_ ending: LineEnding) -> [UInt8] {
            switch ending {
            case .none: return []
            case .lf: return [10]
            case .crlf: return [13, 10]
            }
        }

        private func text(_ lines: [Out]) -> String {
            var bytes: [UInt8] = []
            for line in lines {
                bytes += line.bytes
                bytes += endingBytes(line.ending)
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// Строке без перевода строки, за которой что-то идёт, добавляется окончание: иначе записи склеятся.
        private func fixed(_ lines: [Out], laterContent: Bool) -> [Out] {
            var result = lines
            for index in result.indices where result[index].ending == .none {
                if index < result.count - 1 || laterContent { result[index].ending = dominant }
            }
            return result
        }

        func finish(bom: Bool) -> VaultMergeOutcome {
            var later = [Bool](repeating: false, count: items.count)
            var seen = false
            for index in items.indices.reversed() {
                later[index] = seen
                switch items[index] {
                case .lines(let lines): if !lines.isEmpty { seen = true }
                case .conflict(let mine, let server, let base):
                    if !mine.isEmpty || !server.isEmpty || !base.isEmpty { seen = true }
                }
            }
            var chunks: [VaultMergeChunk] = []
            func appendStable(_ string: String) {
                guard !string.isEmpty else { return }
                if case .stable(let previous)? = chunks.last {
                    chunks[chunks.count - 1] = .stable(previous + string)
                } else {
                    chunks.append(.stable(string))
                }
            }
            if bom { appendStable("\u{FEFF}") }
            var nextID = 0
            var hasConflict = false
            for (index, item) in items.enumerated() {
                switch item {
                case .lines(let lines):
                    appendStable(text(fixed(lines, laterContent: later[index])))
                case .conflict(let mine, let server, let base):
                    hasConflict = true
                    chunks.append(.conflict(
                        id: nextID,
                        mine: text(fixed(mine, laterContent: later[index])),
                        server: text(fixed(server, laterContent: later[index])),
                        base: text(fixed(base, laterContent: later[index]))))
                    nextID += 1
                }
            }
            if !hasConflict {
                var merged = ""
                for chunk in chunks { if case .stable(let string) = chunk { merged += string } }
                return .merged(merged)
            }
            return .conflict(VaultMergeConflict(chunks: chunks, autoMergedCount: autoMerged))
        }
    }

    // MARK: - Сравнение строк

    /// Для каждой строки `old` — номер совпавшей строки `new` или -1. Алгоритм Майерса с жёсткой границей
    /// `maxEdits`; сравниваются номера строк. nil — отличий слишком много.
    private static func matches(_ old: [Int], _ new: [Int]) -> [Int]? {
        var result = [Int](repeating: -1, count: old.count)
        var low = 0
        while low < old.count, low < new.count, old[low] == new[low] {
            result[low] = low
            low += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > low, newEnd > low, old[oldEnd - 1] == new[newEnd - 1] {
            result[oldEnd - 1] = newEnd - 1
            oldEnd -= 1
            newEnd -= 1
        }
        let a = Array(old[low..<oldEnd])
        let b = Array(new[low..<newEnd])
        guard !a.isEmpty, !b.isEmpty else { return result }
        let n = a.count, m = b.count
        let limit = min(maxEdits, n + m)
        // v[k + offset] — самый дальний x на диагонали k = x - y; trace[d] — копия окна перед шагом d (память O(D²)).
        let offset = limit + 1
        var v = [Int32](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int32]] = []
        var found = -1
        search: for d in 0...limit {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = Int(v[offset + k + 1])
                } else {
                    x = Int(v[offset + k - 1]) + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = Int32(x)
                if x >= n && y >= m { found = d; break search }
            }
        }
        guard found >= 0 else { return nil }
        var x = n, y = m
        for d in stride(from: found, through: 0, by: -1) {
            let window = trace[d]
            func at(_ k: Int) -> Int { Int(window[k + d + 1]) }
            let k = x - y
            let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let previousX = at(previousK)
            let previousY = previousX - previousK
            while x > previousX && y > previousY {
                result[low + x - 1] = low + y - 1
                x -= 1
                y -= 1
            }
            if d > 0 { x = previousX; y = previousY }
        }
        return result
    }

    private static func keys(_ lines: ArraySlice<Line>) -> [Int] { lines.map(\.key) }

    // MARK: - Тело: diff3

    private static func diff3(base: [Line], mine: [Line], server: [Line], into builder: inout Builder) {
        let baseKeys = base.map(\.key)
        guard let toMine = matches(baseKeys, mine.map(\.key)),
              let toServer = matches(baseKeys, server.map(\.key)) else {
            builder.tooBig = true
            return
        }
        var anchors: [(Int, Int, Int)] = []
        for i in base.indices where toMine[i] >= 0 && toServer[i] >= 0 {
            anchors.append((i, toMine[i], toServer[i]))
        }
        anchors.append((base.count, mine.count, server.count))
        var pb = 0, pm = 0, ps = 0
        for (index, anchor) in anchors.enumerated() {
            let isLast = index == anchors.count - 1
            gap(base: base[pb..<anchor.0], mine: mine[pm..<anchor.1], server: server[ps..<anchor.2],
                isLast: isLast, into: &builder)
            if !isLast {
                builder.stableMine(mine[anchor.1...anchor.1])
                pb = anchor.0 + 1
                pm = anchor.1 + 1
                ps = anchor.2 + 1
            }
        }
    }

    /// Промежуток между опорными строками. `isLast` — хвост текста после последней опорной строки.
    private static func gap(base: ArraySlice<Line>, mine: ArraySlice<Line>, server: ArraySlice<Line>,
                            isLast: Bool, into builder: inout Builder) {
        let kb = keys(base), km = keys(mine), ks = keys(server)
        if kb == km && kb == ks { builder.stableMine(mine); return }
        if km == kb { builder.autoMerged += 1; builder.stableServer(server); return }
        if ks == kb { builder.stableMine(mine); return }
        if km == ks { builder.stableMine(mine); return }
        if isLast {
            let serverExtends = ks.count > kb.count && ks.starts(with: kb)
            let mineExtends = km.count > kb.count && km.starts(with: kb)
            if serverExtends && !km.isEmpty && !mineExtends {
                builder.autoMerged += 1
                builder.stableMine(mine)
                builder.stableServer(server[(server.startIndex + kb.count)...])
                return
            }
            if mineExtends && !ks.isEmpty && !serverExtends {
                builder.autoMerged += 1
                builder.stableServer(server)
                builder.stableMine(mine[(mine.startIndex + kb.count)...])
                return
            }
        }
        // Общие начало и конец сторон согласованы — в конфликт не идут.
        var prefix = 0
        while prefix < km.count, prefix < ks.count, km[prefix] == ks[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < km.count - prefix, suffix < ks.count - prefix,
              km[km.count - 1 - suffix] == ks[ks.count - 1 - suffix] { suffix += 1 }
        builder.stableMine(mine[mine.startIndex..<(mine.startIndex + prefix)])
        builder.conflict(mine: mine[(mine.startIndex + prefix)..<(mine.endIndex - suffix)],
                         server: server[(server.startIndex + prefix)..<(server.endIndex - suffix)],
                         base: base)
        builder.stableMine(mine[(mine.endIndex - suffix)...])
    }

    // MARK: - Шапка YAML

    private static let dashes: [UInt8] = [45, 45, 45]

    /// Номер закрывающей `---`, если текст начинается с шапки; иначе nil.
    private static func headerEnd(_ lines: [Line]) -> Int? {
        guard lines.count >= 2, lines[0].bytes == dashes else { return nil }
        for index in 1..<lines.count where lines[index].bytes == dashes { return index }
        return nil
    }

    private struct Record {
        var key: String
        var lines: ArraySlice<Line>
    }

    private static let preambleKey = "\u{0}pre"

    /// Запись шапки: строка `ключ:` и все следующие до нового ключа (отступы, списки, пустые, комментарии).
    private static func records(_ lines: ArraySlice<Line>) -> [Record] {
        var result: [Record] = []
        var seen: [String: Int] = [:]
        var start = lines.startIndex
        var currentKey: String?
        func close(at end: Int) {
            if let key = currentKey, end > start {
                result.append(Record(key: key, lines: lines[start..<end]))
            }
        }
        for index in lines.indices {
            let bytes = lines[index].bytes
            if let first = bytes.first, ![32, 9, 35, 45].contains(first),
               let colon = bytes.firstIndex(of: 58) {
                close(at: index)
                let name = String(decoding: bytes[..<colon], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let count = (seen[name] ?? 0) + 1
                seen[name] = count
                currentKey = count == 1 ? name : "\(name)\u{0}#\(count)"
                start = index
            } else if currentKey == nil {
                currentKey = preambleKey
                start = index
            }
        }
        close(at: lines.endIndex)
        return result
    }

    private static func mergeHeader(base: ArraySlice<Line>, mine: ArraySlice<Line>, server: ArraySlice<Line>,
                                    into builder: inout Builder) {
        func inner(_ lines: ArraySlice<Line>) -> ArraySlice<Line> {
            lines[(lines.startIndex + 1)..<(lines.endIndex - 1)]
        }
        let baseRecords = records(inner(base))
        let mineRecords = records(inner(mine))
        let serverRecords = records(inner(server))
        func table(_ list: [Record]) -> [String: ArraySlice<Line>] {
            Dictionary(list.map { ($0.key, $0.lines) }, uniquingKeysWith: { first, _ in first })
        }
        let b = table(baseRecords), m = table(mineRecords), s = table(serverRecords)
        func same(_ x: ArraySlice<Line>?, _ y: ArraySlice<Line>?) -> Bool {
            switch (x, y) {
            case (nil, nil): return true
            case (let x?, let y?): return keys(x) == keys(y)
            default: return false
            }
        }

        // Порядок полей — «мой»; добавленные сервером поля встают после своего предшественника у сервера.
        var order = mineRecords.map(\.key)
        let serverOrder = serverRecords.map(\.key)
        for (position, key) in serverOrder.enumerated() where m[key] == nil {
            if let inBase = b[key], same(inBase, s[key]) { continue }
            var at = order.first == preambleKey ? 1 : 0
            for previous in serverOrder[..<position].reversed() {
                if let found = order.firstIndex(of: previous) { at = found + 1; break }
            }
            order.insert(key, at: at)
        }

        builder.stableMine(mine[mine.startIndex...mine.startIndex])
        for key in order {
            let bk = b[key], mk = m[key], sk = s[key]
            if same(mk, bk) && same(sk, bk) || !same(mk, bk) && same(sk, bk) || same(mk, sk) {
                if let mk { builder.stableMine(mk) }
            } else if same(mk, bk) {
                builder.autoMerged += 1
                if let sk { builder.stableServer(sk) }
            } else {
                builder.conflict(mine: mk ?? [], server: sk ?? [], base: bk ?? [])
            }
        }
        builder.stableMine(mine[(mine.endIndex - 1)...])
    }
}

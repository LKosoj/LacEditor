import Foundation

/// Один токен в экранном тексте. Позиции в UTF-16.
struct MarkdownMediaSpan: Equatable, Sendable {
    var displayStart: Int
    let displayLength: Int
    let sourceLength: Int
    let entry: Int
    /// Переводы строки внутри адреса в файле: на экране токен в одну строку.
    var sourceBreaks: Int = 0
    var displayEnd: Int { displayStart + displayLength }
}

/// Таблица токенов документа. Токен вместо любого адреса `data:тип/подтип,...`:
/// `data:тип/подтип;...,AA==#lac-media-<хэш>`. Записи не удаляются, поэтому undo вернёт media.
struct MarkdownMediaTable: Sendable {
    struct Entry: Sendable {
        let token: String
        let tokenBytes: [UInt8]
        /// Адрес как есть, в UTF-8: восстановление копирует его без перекодирования.
        let bytes: [UInt8]
        /// Длина адреса в UTF-16, для позиций в экранном тексте.
        let sourceLength: Int
        /// Переводы строки внутри адреса: LF, CR, CRLF одним, LS и PS (как в `FileService.countLines`).
        let sourceBreaks: Int
        var source: String { String(decoding: bytes, as: UTF8.self) }
    }

    struct Projection: Sendable {
        var text: String
        var spans: [MarkdownMediaSpan]
    }

    struct Restored: Sendable {
        var text: String
        var unknownTokens: [NSRange]
    }

    /// Входящий текст (вставка, ответ ИИ) после подмены адресов `data:`.
    struct Incoming: Sendable {
        var text: String
        var spans: [MarkdownMediaSpan]
        /// Токен-подобные места не из таблицы и повреждённые токены; диапазоны в UTF-16 исходной строки.
        var invalid: [NSRange]
    }

    private(set) var entries: [Entry] = []
    private var byToken: [String: Int] = [:]
    /// Индекс по хэшу: целые строки по несколько МБ ключами не хранятся.
    private var byHash: [UInt64: [Int]] = [:]

    private static let marker = Array("#lac-media-".utf8)
    private static let tail = Array(",AA==".utf8)
    private static let maximumHeaderLength = 256

    var isEmpty: Bool { entries.isEmpty }

    func source(forToken token: String) -> String? {
        byToken[token].map { entries[$0].source }
    }

    // MARK: Проекция и восстановление

    /// Работает по байтам UTF-8; позиции spans считаются в UTF-16.
    mutating func project(_ source: String) -> Projection {
        var text = source
        return text.withUTF8 { project(bytes: $0) } ?? Projection(text: source, spans: [])
    }

    private mutating func project(bytes: UnsafeBufferPointer<UInt8>) -> Projection? {
        let addresses = Self.addresses(in: bytes)
        guard !addresses.isEmpty else { return nil }
        var spans: [MarkdownMediaSpan] = []
        var found: [Int] = []
        var total = bytes.count
        var displayLength = 0
        var cursor = 0
        for address in addresses {
            let slice = UnsafeBufferPointer(rebasing: bytes[address.start..<address.end])
            let entry = intern(slice, headerLength: address.comma - address.start, hash: Self.hash(slice))
            let tokenLength = entries[entry].tokenBytes.count
            displayLength += Self.utf16Length(UnsafeBufferPointer(rebasing: bytes[cursor..<address.start]))
            spans.append(MarkdownMediaSpan(displayStart: displayLength, displayLength: tokenLength,
                                           sourceLength: entries[entry].sourceLength, entry: entry,
                                           sourceBreaks: entries[entry].sourceBreaks))
            displayLength += tokenLength
            total += tokenLength - slice.count
            cursor = address.end
            found.append(entry)
        }
        let text = String(unsafeUninitializedCapacity: total) { out in
            var written = 0
            cursor = 0
            for (address, entry) in zip(addresses, found) {
                Self.copy(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[cursor..<address.start]), to: out, at: &written)
                entries[entry].tokenBytes.withUnsafeBytes { Self.copy($0, to: out, at: &written) }
                cursor = address.end
            }
            Self.copy(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[cursor...]), to: out, at: &written)
            return written
        }
        return Projection(text: text, spans: spans)
    }

    /// Известный токен остаётся токеном, настоящий `data:` подменяется как в `project`.
    /// Токен-подобное место не из таблицы подменяется тоже (как данные), но попадает в `invalid`:
    /// вставка из буфера его игнорирует, ответ ИИ из-за него отклоняется.
    mutating func incoming(_ text: String) -> Incoming {
        guard text.range(of: "data:", options: .caseInsensitive) != nil else {
            return Incoming(text: text, spans: [], invalid: [])
        }
        let units = Array(text.utf16)
        var invalid: [NSRange] = []
        var known: [(start: Int, end: Int)] = []
        var addresses: [(start: Int, comma: Int, end: Int)] = []
        Self.withUnits(units) { bytes in
            for token in tokens(in: bytes) {
                if token.entry == nil {
                    invalid.append(NSRange(location: token.start, length: token.end - token.start))
                } else {
                    known.append((token.start, token.end))
                }
            }
            if text.contains("#lac-media-") { addresses = Self.addresses(in: bytes) }
        }
        // Повреждённый токен: адрес с меткой, внутри которого нет ни одного известного токена.
        for address in addresses where !known.contains(where: { $0.start >= address.start && $0.end <= address.end })
            && !invalid.contains(where: { $0.location < address.end && NSMaxRange($0) > address.start }) {
            let marker = Self.marker.map { UInt16($0) }
            let inside = (address.start..<address.end).contains { i in
                i + marker.count <= address.end && units[i] == marker[0] && Array(units[i..<(i + marker.count)]) == marker
            }
            if inside { invalid.append(NSRange(location: address.start, length: address.end - address.start)) }
        }
        invalid.sort { $0.location < $1.location }
        guard !known.isEmpty else {
            let projection = project(text)
            return Incoming(text: projection.text, spans: projection.spans, invalid: invalid)
        }
        var result = ""
        var spans: [MarkdownMediaSpan] = []
        var length = 0
        var cursor = 0
        func appendPlain(to end: Int) {
            guard end > cursor else { return }
            let projection = project(String(decoding: units[cursor..<end], as: UTF16.self))
            for var span in projection.spans {
                span.displayStart += length
                spans.append(span)
            }
            result += projection.text
            length += projection.text.utf16.count
        }
        for token in known {
            appendPlain(to: token.start)
            let value = String(decoding: units[token.start..<token.end], as: UTF16.self)
            let entry = byToken[value]!
            spans.append(MarkdownMediaSpan(displayStart: length, displayLength: token.end - token.start,
                                           sourceLength: entries[entry].sourceLength, entry: entry,
                                           sourceBreaks: entries[entry].sourceBreaks))
            result += value
            length += token.end - token.start
            cursor = token.end
        }
        appendPlain(to: units.count)
        return Incoming(text: result, spans: spans, invalid: invalid)
    }

    /// Для проверки совпадений хэша хэш передаётся снаружи.
    mutating func intern(_ bytes: UnsafeBufferPointer<UInt8>, headerLength: Int, hash: UInt64) -> Int {
        let sameHash = byHash[hash] ?? []
        for index in sameHash where entries[index].bytes.withUnsafeBufferPointer({
            $0.count == bytes.count && memcmp($0.baseAddress!, bytes.baseAddress!, bytes.count) == 0
        }) {
            return index
        }
        let hex = String(hash, radix: 16)
        var token = String(decoding: bytes.prefix(headerLength), as: UTF8.self)
            + String(decoding: Self.tail, as: UTF8.self) + String(decoding: Self.marker, as: UTF8.self)
            + String(repeating: "0", count: 16 - hex.count) + hex
        if !sameHash.isEmpty { token += "-\(sameHash.count)" }
        entries.append(Entry(token: token, tokenBytes: Array(token.utf8), bytes: Array(bytes),
                             sourceLength: Self.utf16Length(bytes), sourceBreaks: Self.breakCount(bytes)))
        byToken[token] = entries.count - 1
        byHash[hash, default: []].append(entries.count - 1)
        return entries.count - 1
    }

    /// Работает по байтам UTF-8 без копии в UTF-16. Строка без токенов возвращается как есть.
    func restore(_ display: String) -> Restored {
        var text = display
        let restored: (text: String, hasUnknown: Bool)? = text.withUTF8 { bytes in
            let found = tokens(in: bytes)
            guard !found.isEmpty else { return nil }
            var total = bytes.count
            for token in found {
                if let entry = token.entry { total += entries[entry].bytes.count - (token.end - token.start) }
            }
            let result = String(unsafeUninitializedCapacity: total) { out in
                var written = 0
                var cursor = 0
                for token in found {
                    guard let entry = token.entry else { continue }
                    Self.copy(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[cursor..<token.start]), to: out, at: &written)
                    entries[entry].bytes.withUnsafeBytes { Self.copy($0, to: out, at: &written) }
                    cursor = token.end
                }
                Self.copy(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[cursor...]), to: out, at: &written)
                return written
            }
            return (result, found.contains { $0.entry == nil })
        }
        guard let restored else { return Restored(text: display, unknownTokens: []) }
        // Диапазоны в UTF-16 нужны только для редкого неизвестного токена.
        return Restored(text: restored.text, unknownTokens: restored.hasUnknown ? unknownTokens(in: Array(display.utf16)) : [])
    }

    private static func copy(_ source: UnsafeRawBufferPointer, to out: UnsafeMutableBufferPointer<UInt8>, at written: inout Int) {
        guard let base = source.baseAddress, !source.isEmpty else { return }
        UnsafeMutableRawPointer(out.baseAddress! + written).copyMemory(from: base, byteCount: source.count)
        written += source.count
    }

    private static func utf16Length(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var count = 0
        for byte in bytes { count += (byte & 0xC0 != 0x80 ? 1 : 0) + (byte >= 0xF0 ? 1 : 0) }
        return count
    }

    private static func breakCount(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var count = 0
        var previousWasCR = false
        for i in bytes.indices {
            let byte = bytes[i]
            if byte == 10 {
                if !previousWasCR { count += 1 }
            } else if byte == 13 {
                count += 1
            } else if byte == 0xE2, i + 2 < bytes.count, bytes[i + 1] == 0x80, bytes[i + 2] == 0xA8 || bytes[i + 2] == 0xA9 {
                count += 1
            }
            previousWasCR = byte == 13
        }
        return count
    }

    /// Диапазоны UTF-16 адресов `data:` в тексте файла по порядку: поиск их пропускает.
    static func addressRanges(in text: String) -> [NSRange] {
        var text = text
        return text.withUTF8 { bytes in
            var ranges: [NSRange] = []
            var location = 0
            var cursor = 0
            for address in addresses(in: bytes) {
                location += utf16Length(UnsafeBufferPointer(rebasing: bytes[cursor..<address.start]))
                let length = utf16Length(UnsafeBufferPointer(rebasing: bytes[address.start..<address.end]))
                ranges.append(NSRange(location: location, length: length))
                location += length
                cursor = address.end
            }
            return ranges
        }
    }

    /// Сколько байт занимают адреса `data:` в тексте файла и сколько переводов строки в них.
    /// По ним профиль большого файла не считает media: на экране они короткие токены.
    static func measureMedia(in text: String) -> (bytes: Int, breaks: Int) {
        var text = text
        return text.withUTF8 { bytes in
            var total = 0
            var breaks = 0
            for address in addresses(in: bytes) {
                total += address.end - address.start
                breaks += breakCount(UnsafeBufferPointer(rebasing: bytes[address.start..<address.end]))
            }
            return (total, breaks)
        }
    }

    /// Хэш по словам по 8 байт: адреса бывают в мегабайты. Совпадения всё равно проверяются сравнением.
    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        let raw = UnsafeRawBufferPointer(bytes)
        var hash: UInt64 = 0xcbf29ce484222325
        var i = 0
        while i + 8 <= raw.count {
            hash = (hash ^ raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x100000001b3
            hash ^= hash >> 29
            i += 8
        }
        while i < raw.count {
            hash = (hash ^ UInt64(raw[i])) &* 0x100000001b3
            i += 1
        }
        return hash
    }

    // MARK: Токены в экранном тексте

    func spans(in display: [UInt16]) -> [MarkdownMediaSpan] {
        Self.withUnits(display) { spans(in: $0) }
    }

    private func spans(in units: UnsafeBufferPointer<UInt8>) -> [MarkdownMediaSpan] {
        tokens(in: units).compactMap { token in
            token.entry.map {
                MarkdownMediaSpan(displayStart: token.start, displayLength: token.end - token.start,
                                  sourceLength: entries[$0].sourceLength, entry: $0,
                                  sourceBreaks: entries[$0].sourceBreaks)
            }
        }
    }

    func spans(in display: NSString) -> [MarkdownMediaSpan] {
        var units = [UInt8](repeating: 0, count: display.length)
        var chunk = [UInt16](repeating: 0, count: 4096)
        var offset = 0
        while offset < units.count {
            let length = min(chunk.count, units.count - offset)
            display.getCharacters(&chunk, range: NSRange(location: offset, length: length))
            for i in 0..<length { units[offset + i] = chunk[i] < 128 ? UInt8(chunk[i]) : 0x80 }
            offset += length
        }
        return units.withUnsafeBufferPointer { spans(in: $0) }
    }

    /// Похожее на токен место без записи в таблице: перед сохранением или печатью такой текст опасен.
    func unknownTokens(in display: [UInt16]) -> [NSRange] {
        Self.withUnits(display) { tokens(in: $0) }.filter { $0.entry == nil }
            .map { NSRange(location: $0.start, length: $0.end - $0.start) }
    }

    /// Всё, что не ASCII, ничего не значит для поиска, поэтому каждая единица UTF-16 становится байтом
    /// (не ASCII заменяется на 0x80), а позиции остаются прежними.
    private static func withUnits<R>(_ display: [UInt16], _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        display.map { $0 < 128 ? UInt8($0) : 0x80 }.withUnsafeBufferPointer(body)
    }

    /// Ищет `#lac-media-<16 hex>[-N]`, перед ним `,AA==` и заголовок от `data:`.
    private func tokens(in u: UnsafeBufferPointer<UInt8>) -> [(start: Int, end: Int, entry: Int?)] {
        var result: [(start: Int, end: Int, entry: Int?)] = []
        let marker = Self.marker
        let tail = Self.tail
        var i = 0
        var floor = 0
        while let base = u.baseAddress, i + marker.count + 16 <= u.count {
            guard let hit = memchr(base + i, 35, u.count - i) else { break }
            i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            guard i + marker.count + 16 <= u.count else { break }
            guard u[i..<(i + marker.count)].elementsEqual(marker) else { i += 1; continue }
            var end = i + marker.count
            guard (end..<(end + 16)).allSatisfy({ Self.isLowerHex(u[$0]) }) else { i += 1; continue }
            end += 16
            let hexEnd = end
            if end + 1 < u.count, u[end] == 45, Self.isDigit(u[end + 1]) {
                end += 1
                while end < u.count, Self.isDigit(u[end]) { end += 1 }
            }
            let comma = i - tail.count
            guard comma >= floor, u[comma..<i].elementsEqual(tail) else { i += 1; continue }
            var low = comma
            while low > floor, comma - low < Self.maximumHeaderLength + 5, Self.isHeaderUnit(u[low - 1]) { low -= 1 }
            var unknownStart: Int?
            var known: (start: Int, end: Int, entry: Int)?
            // Границу слова не проверяем: после правки перед токеном может встать буква, токен остаётся токеном.
            for start in low..<max(low, comma - 4) where Self.hasDataMarker(u, at: start)
                && Self.parseHeader(u, from: start + 5) == comma {
                // Неизвестным считаем только адрес на границе слова: `xdata:...` в файле обычный текст.
                if start == 0 || !Self.isWord(u[start - 1]) { unknownStart = unknownStart ?? start }
                let token = String(decoding: UnsafeBufferPointer(rebasing: u[start..<end]), as: UTF8.self)
                if let entry = byToken[token] { known = (start, end, entry); break }
                // Набор `-1` сразу после токена: `hex-N` в таблице нет, а `hex` есть, суффикс остаётся текстом.
                if hexEnd != end {
                    let short = String(decoding: UnsafeBufferPointer(rebasing: u[start..<hexEnd]), as: UTF8.self)
                    if let entry = byToken[short] { known = (start, hexEnd, entry); break }
                }
            }
            if let known {
                result.append((known.start, known.end, known.entry))
                floor = known.end
                i = known.end
                continue
            } else if let unknownStart {
                result.append((unknownStart, end, nil))
            } else {
                i += 1
                continue
            }
            floor = end
            i = end
        }
        return result
    }

    // MARK: Поиск адресов в тексте файла

    private static func isLowerHex(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...102).contains(c) }
    private static func isDigit(_ c: UInt8) -> Bool { (48...57).contains(c) }
    private static func isWord(_ c: UInt8) -> Bool {
        isDigit(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95
    }
    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
    private static func isNameUnit(_ c: UInt8) -> Bool { isWord(c) || c == 46 || c == 43 || c == 45 }
    private static func isHeaderUnit(_ c: UInt8) -> Bool {
        isNameUnit(c) || c == 47 || c == 59 || c == 61 || c == 37 || c == 58
    }
    private static func isPayload(_ c: UInt8) -> Bool { isWord(c) || c == 43 || c == 47 || c == 61 || c == 45 || c == 37 }
    private static func isStop(_ c: UInt8) -> Bool { isSpace(c) || c == 34 || c == 39 || c == 60 || c == 62 || c == 41 }

    private static func hasDataMarker(_ u: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        i + 5 <= u.count && u[i] | 0x20 == 100 && u[i + 1] | 0x20 == 97 && u[i + 2] | 0x20 == 116
            && u[i + 3] | 0x20 == 97 && u[i + 4] == 58
    }

    /// Заголовок после `data:`: `тип/подтип[;параметры]` до запятой. Возвращает позицию запятой.
    private static func parseHeader(_ u: UnsafeBufferPointer<UInt8>, from p: Int) -> Int? {
        var q = p
        let limit = min(u.count, p + maximumHeaderLength)
        while q < limit, isNameUnit(u[q]) { q += 1 }
        guard q > p, q < limit, u[q] == 47 else { return nil }
        let subtype = q + 1
        q = subtype
        while q < limit, isNameUnit(u[q]) { q += 1 }
        guard q > subtype else { return nil }
        while q < limit, isHeaderUnit(u[q]) { q += 1 }
        return q < u.count && u[q] == 44 ? q : nil
    }

    /// `j` указывает на перевод строки, за которым (через `\r`, пробелы, табы) идёт ещё один.
    private static func isBlankLine(_ u: UnsafeBufferPointer<UInt8>, at j: Int) -> Bool {
        guard u[j] == 10 else { return false }
        var k = j + 1
        while k < u.count, u[k] == 13 || u[k] == 32 || u[k] == 9 { k += 1 }
        return k < u.count && u[k] == 10
    }

    private static func isBase64(_ u: UnsafeBufferPointer<UInt8>, headerEnd: Int) -> Bool {
        headerEnd >= 7 && Array("base64".utf8).enumerated().allSatisfy { u[headerEnd - 6 + $0.offset] | 0x20 == $0.element }
            && u[headerEnd - 7] == 59
    }

    private static func addresses(in u: UnsafeBufferPointer<UInt8>) -> [(start: Int, comma: Int, end: Int)] {
        var result: [(start: Int, comma: Int, end: Int)] = []
        var i = 0
        while i + 5 < u.count {
            guard u[i] | 0x20 == 100, hasDataMarker(u, at: i), i == 0 || !isWord(u[i - 1]),
                  let comma = parseHeader(u, from: i + 5) else { i += 1; continue }
            let end = addressEnd(u, start: i, comma: comma)
            if end > comma + 1 {
                result.append((i, comma, end))
                i = end
            } else {
                i += 5
            }
        }
        return result
    }

    /// Конец адреса зависит от того, что стоит перед `data:`: кавычка, `<`, `(` или ничего.
    private static func addressEnd(_ u: UnsafeBufferPointer<UInt8>, start: Int, comma: Int) -> Int {
        let valueStart = comma + 1
        var closer: UInt8?
        var isParen = false
        if start > 0 {
            switch u[start - 1] {
            case 34, 39: closer = u[start - 1]
            case 60: closer = 62
            default:
                var p = start - 1
                while p > 0, isSpace(u[p]) { p -= 1 }
                isParen = u[p] == 40
            }
        }
        if let closer {
            if isBase64(u, headerEnd: comma) {
                var j = valueStart
                var last = valueStart
                while j < u.count {
                    if isPayload(u[j]) { last = j + 1 } else if isBlankLine(u, at: j) || !isSpace(u[j]) { break }
                    j += 1
                }
                if j < u.count, u[j] == closer, last > valueStart { return last }
            } else {
                // Незакрытая кавычка не должна тянуться через документ: дальше пустой строки не ищем.
                var close = valueStart
                while close < u.count, u[close] != closer, !isBlankLine(u, at: close) { close += 1 }
                if close < u.count, u[close] == closer {
                    var end = close
                    while end > valueStart, isSpace(u[end - 1]) { end -= 1 }
                    return end
                }
            }
        }
        var j = valueStart
        var depth = 0
        while j < u.count, !isSpace(u[j]) {
            if isParen {
                if u[j] == 92 { j += 1 } else if u[j] == 40 { depth += 1 } else if u[j] == 41 {
                    if depth == 0 { break }
                    depth -= 1
                }
            } else if isStop(u[j]) {
                break
            }
            j += 1
        }
        return min(j, u.count)
    }

    // MARK: Обычный текст для буфера обмена

    /// Текст диапазона без токенов: `![..](TOKEN)` и HTML-тег с токеном убираются целиком
    /// (у `audio` и `video` вместе с закрывающим тегом), у `[текст](TOKEN)` остаётся текст.
    /// Токен в результат не попадает никогда.
    func clipboardText(_ display: [UInt16], range: NSRange) -> String {
        let upper = min(range.location + range.length, display.count)
        guard range.location >= 0, range.location <= upper else { return "" }
        let all = spans(in: display)
        var edits: [(start: Int, end: Int, replacement: ArraySlice<UInt16>)] = []
        for span in all where span.displayStart < upper && span.displayEnd > range.location {
            var edit = Self.enclosing(display, start: span.displayStart, end: span.displayEnd)
            // Текст ссылки с вложенным токеном не оставляем: убирается вся конструкция.
            let text = edit.replacement
            if all.contains(where: { $0.displayStart >= text.startIndex && $0.displayEnd <= text.endIndex && !text.isEmpty }) {
                edit.replacement = display[0..<0]
            }
            if let last = edits.last, edit.start < last.end {
                edits[edits.count - 1] = (min(edit.start, last.start), max(edit.end, last.end), display[0..<0])
            } else {
                edits.append(edit)
            }
        }
        var output: [UInt16] = []
        var cursor = range.location
        for edit in edits {
            output.append(contentsOf: display[cursor..<max(cursor, min(edit.start, upper))])
            // Текст ссылки берём только из выделенной части.
            let low = max(edit.replacement.startIndex, range.location)
            let high = min(edit.replacement.endIndex, upper)
            if low < high { output.append(contentsOf: display[low..<high]) }
            cursor = max(cursor, edit.end)
        }
        if cursor < upper { output.append(contentsOf: display[cursor..<upper]) }
        // Остатки токенов (например, от обрезанных конструкций) не пропускаем.
        while case let left = spans(in: output), !left.isEmpty {
            for span in left.reversed() { output.removeSubrange(span.displayStart..<span.displayEnd) }
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || (9...13).contains(c) }
    private static func isLetter(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) }
    private static func isWord(_ c: UInt16) -> Bool { c < 128 && isWord(UInt8(c)) }

    private static func matches(_ u: [UInt16], at i: Int, _ text: String) -> Bool {
        let pattern = Array(text.utf16)
        guard i >= 0, i + pattern.count <= u.count else { return false }
        return pattern.indices.allSatisfy { u[i + $0] == pattern[$0] || (isLetter(pattern[$0]) && u[i + $0] | 0x20 == pattern[$0]) }
    }

    /// Начало тега перед позицией: `<` с буквой или `/` после него, без другого `>` и пустой строки между.
    private static func tagStart(_ u: [UInt16], before i: Int) -> Int? {
        var p = i - 1
        while p >= 0 {
            switch u[p] {
            case 62:
                return nil
            case 60:
                guard p + 1 < u.count, isLetter(u[p + 1]) || u[p + 1] == 47, p == 0 || !isWord(u[p - 1]) else { return nil }
                return p
            case 10:
                var q = p - 1
                while q >= 0, u[q] == 13 || u[q] == 32 || u[q] == 9 { q -= 1 }
                if q >= 0, u[q] == 10 { return nil }
            default:
                break
            }
            p -= 1
        }
        return nil
    }

    /// Конец тега: первый `>` вне кавычек. Другой `<` или пустая строка раньше означают, что это не тег.
    private static func tagEnd(_ u: [UInt16], from i: Int, quote: UInt16) -> Int? {
        var j = i
        var quote = quote
        while j < u.count {
            let c = u[j]
            if c == 10 {
                var k = j + 1
                while k < u.count, u[k] == 13 || u[k] == 32 || u[k] == 9 { k += 1 }
                if k < u.count, u[k] == 10 { return nil }
            }
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 34 || c == 39 {
                quote = c
            } else if c == 62 {
                return j
            } else if c == 60 {
                return nil
            }
            j += 1
        }
        return nil
    }

    private static func tagName(_ u: [UInt16], _ open: Int) -> String {
        var p = open + 1
        if p < u.count, u[p] == 47 { p += 1 }
        let start = p
        while p < u.count, isWord(u[p]) { p += 1 }
        return String(decoding: u[start..<p], as: UTF16.self).lowercased()
    }

    /// Закрывающий `</name>` после тега, без копирования текста. Не дальше пустой строки;
    /// если раньше встретился ещё один такой же открывающий тег, закрывающий не наш.
    private static func closingTag(_ u: [UInt16], name: String, from i: Int) -> Int? {
        let closing = "</\(name)>"
        var j = i
        while j < u.count {
            if u[j] == 10 {
                var k = j + 1
                while k < u.count, u[k] == 13 || u[k] == 32 || u[k] == 9 { k += 1 }
                if k < u.count, u[k] == 10 { return nil }
            } else if u[j] == 60 {
                if matches(u, at: j, closing) { return j + closing.utf16.count }
                if matches(u, at: j, "<" + name), j + 1 + name.utf16.count >= u.count || !isWord(u[j + 1 + name.utf16.count]) { return nil }
            }
            j += 1
        }
        return nil
    }

    private static func enclosing(_ u: [UInt16], start: Int, end: Int) -> (start: Int, end: Int, replacement: ArraySlice<UInt16>) {
        let bare = (start: start, end: end, replacement: u[0..<0])
        if start > 0, end < u.count, u[start - 1] == 60, u[end] == 62 { return bare }
        // Markdown: ](TOKEN) или ](TOKEN "title")
        if start >= 2, u[start - 2] == 93, u[start - 1] == 40 {
            var close = end
            while close < u.count, u[close] != 41, u[close] != 10 { close += 1 }
            var open = start - 2
            var depth = 0
            var matched = false
            while open >= 0, u[open] != 10 {
                if u[open] == 93 { depth += 1 } else if u[open] == 91 {
                    depth -= 1
                    if depth == 0 { matched = true; break }
                }
                open -= 1
            }
            guard matched, close < u.count, u[close] == 41 else { return bare }
            if open > 0, u[open - 1] == 33 { return (open - 1, close + 1, u[0..<0]) }
            return (open, close + 1, u[(open + 1)..<(start - 2)])
        }
        // HTML: тег `<имя ... TOKEN ...>`
        let quote: UInt16 = start > 0 && (u[start - 1] == 34 || u[start - 1] == 39) ? u[start - 1] : 0
        guard let open = tagStart(u, before: start), let close = tagEnd(u, from: end, quote: quote) else { return bare }
        let name = tagName(u, open)
        if name == "audio" || name == "video" {
            return (open, closingTag(u, name: name, from: close + 1) ?? close + 1, u[0..<0])
        }
        if name == "source" {
            // `<video><source src="TOKEN"></video>`: убирается вместе с внешними тегами.
            var before = open - 1
            while before >= 0, isSpace(u[before]) { before -= 1 }
            var after = close + 1
            while after < u.count, isSpace(u[after]) { after += 1 }
            if before >= 0, u[before] == 62, let outer = tagStart(u, before: before) {
                let outerName = tagName(u, outer)
                let closing = "</\(outerName)>"
                if outerName == "audio" || outerName == "video", matches(u, at: after, closing) {
                    return (outer, after + closing.utf16.count, u[0..<0])
                }
            }
        }
        return (open, close + 1, u[0..<0])
    }
}

/// Позиции между экранным текстом и файлом: токены короче адресов, разница копится слева направо.
struct MarkdownMediaMap: Equatable, Sendable {
    enum Affinity { case leading, trailing }

    private(set) var spans: [MarkdownMediaSpan]
    /// delta[i] = сумма (sourceLength - displayLength) по spans[..<i].
    private var delta: [Int]
    /// breaks[i] = сумма sourceBreaks по spans[..<i].
    private var breaks: [Int]

    init(spans: [MarkdownMediaSpan] = []) {
        self.spans = spans
        delta = [0]
        breaks = [0]
        for span in spans {
            delta.append(delta[delta.count - 1] + span.sourceLength - span.displayLength)
            breaks.append(breaks[breaks.count - 1] + span.sourceBreaks)
        }
    }

    var isEmpty: Bool { spans.isEmpty }

    func sourcePosition(forDisplay p: Int, affinity: Affinity = .leading) -> Int {
        let i = firstIndex { spans[$0].displayEnd > p }
        guard i < spans.count, p > spans[i].displayStart else { return p + delta[i] }
        let start = spans[i].displayStart + delta[i]
        return affinity == .leading ? start : start + spans[i].sourceLength
    }

    func displayPosition(forSource p: Int, affinity: Affinity = .leading) -> Int {
        let i = firstIndex { spans[$0].displayEnd + delta[$0 + 1] > p }
        guard i < spans.count, p > spans[i].displayStart + delta[i] else { return p - delta[i] }
        return affinity == .leading ? spans[i].displayStart : spans[i].displayEnd
    }

    func sourceRange(forDisplay r: NSRange) -> NSRange {
        let start = sourcePosition(forDisplay: r.location)
        let end = sourcePosition(forDisplay: r.location + r.length, affinity: r.length == 0 ? .leading : .trailing)
        return NSRange(location: start, length: end - start)
    }

    func displayRange(forSource r: NSRange) -> NSRange {
        let start = displayPosition(forSource: r.location)
        let end = displayPosition(forSource: r.location + r.length, affinity: r.length == 0 ? .leading : .trailing)
        return NSRange(location: start, length: end - start)
    }

    /// Первый токен, пересекающий символы `first...last` (границы включены).
    func firstSpan(from first: Int, through last: Int) -> MarkdownMediaSpan? {
        let i = firstIndex { spans[$0].displayEnd > first }
        return i < spans.count && spans[i].displayStart <= last ? spans[i] : nil
    }

    /// Номер строки в файле: к экранному номеру добавляются переводы строки внутри токенов левее позиции.
    func sourceLine(forDisplayLine line: Int, atDisplayLocation p: Int) -> Int {
        guard !spans.isEmpty else { return line }
        return line + breaks[firstIndex { spans[$0].displayEnd > p }]
    }

    /// Выделение без захода внутрь токена. Каретка внутри токена идёт к краю: от края, где стояла,
    /// на противоположный (стрелка перешагивает токен), иначе на ближайший. Подвижный край диапазона
    /// прыгает на границу токена в сторону своего движения, неподвижный расширяется до границы.
    func snappedRange(_ r: NSRange, from old: NSRange) -> NSRange {
        guard !spans.isEmpty else { return r }
        func inside(_ p: Int) -> MarkdownMediaSpan? {
            let i = firstIndex { spans[$0].displayEnd > p }
            return i < spans.count && p > spans[i].displayStart ? spans[i] : nil
        }
        if r.length == 0 {
            guard let span = inside(r.location) else { return r }
            let edge: Int
            if old.length == 0, old.location == span.displayStart {
                edge = span.displayEnd
            } else if old.length == 0, old.location == span.displayEnd {
                edge = span.displayStart
            } else {
                edge = r.location - span.displayStart <= span.displayEnd - r.location ? span.displayStart : span.displayEnd
            }
            return NSRange(location: edge, length: 0)
        }
        // Подвижный край виден по старому диапазону: другой край не менялся. Край внутри токена прыгает на границу
        // в сторону своего движения (сужение и расширение), неподвижный край расширяется до границы токена.
        var start = r.location, end = r.location + r.length
        let endMoves = r.location == old.location && r.length != old.length
        let startMoves = !endMoves && end == old.location + old.length && r.location != old.location
        if let span = inside(start) {
            start = startMoves && start > old.location ? span.displayEnd : span.displayStart
        }
        if let span = inside(end) {
            end = endMoves && end < old.location + old.length ? span.displayStart : span.displayEnd
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Диапазон, расширенный до целых токенов, которых он касается.
    func coveringRange(_ r: NSRange) -> NSRange {
        var start = r.location
        var end = r.location + r.length
        for i in spanIndices(intersecting: r) {
            start = min(start, spans[i].displayStart)
            end = max(end, spans[i].displayEnd)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Токены, которых касается диапазон. При нулевой длине только токен, в который попала точка.
    func spanIndices(intersecting r: NSRange) -> Range<Int> {
        let low = firstIndex { spans[$0].displayEnd > r.location }
        if r.length == 0 {
            return low < spans.count && spans[low].displayStart < r.location ? low..<(low + 1) : low..<low
        }
        let high = firstIndex { spans[$0].displayStart >= r.location + r.length }
        return low..<max(low, high)
    }

    func intersectsToken(_ r: NSRange) -> Bool { !spanIndices(intersecting: r).isEmpty }

    /// Правка режет токен: точка строго внутри или частичное перекрытие границы.
    /// Диапазон, целиком накрывающий токен, не режет.
    func cutsToken(_ range: NSRange) -> Bool {
        spanIndices(intersecting: range).contains {
            spans[$0].displayStart < range.location || spans[$0].displayEnd > range.location + range.length
        }
    }

    /// Вставка вплотную к токену приклеивается к его адресу в файле (`xdata:…`, `…Base64x`), и изображение перестаёт открываться.
    /// Вплотную можно только пробел, кавычку, скобку, `<`, `>` или `=`; пустая вставка (удаление) токен не склеивает.
    func joinsToken(_ range: NSRange, replacement: String) -> Bool {
        guard !spans.isEmpty, let first = replacement.utf16.first, let last = replacement.utf16.last else { return false }
        let end = range.location + range.length
        let before = firstIndex { spans[$0].displayEnd >= range.location }
        if before < spans.count, spans[before].displayEnd == range.location, !Self.isAddressBoundary(first) { return true }
        let after = firstIndex { spans[$0].displayStart >= end }
        return after < spans.count && spans[after].displayStart == end && !Self.isAddressBoundary(last)
    }

    /// Защищённая часть вокруг якоря: `](`…`)` с необязательным заголовком у Markdown, `name="`…`"` значения атрибута у HTML.
    /// Вставка внутрь отклоняется; удаление или замена, задевшие её хоть одним символом, забирают всю конструкцию
    /// (`![…](…)` или тег `<…>`). Подпись `![…]` остаётся обычным текстом. Смотрятся только соседние токены и ограниченный участок рядом.
    func decideEdit(_ range: NSRange, replacement: String = "", length: Int, unit: (Int) -> UInt16) -> MarkdownMediaEditDecision {
        guard !spans.isEmpty else { return .allow }
        let end = range.location + range.length
        var i = firstIndex { spans[$0].displayEnd + MarkdownMediaZone.reach >= range.location }
        var cover = range
        while i < spans.count, spans[i].displayStart - MarkdownMediaZone.reach <= end {
            let span = spans[i]
            i += 1
            guard let zone = MarkdownMediaZone.around(NSRange(location: span.displayStart, length: span.displayLength),
                                                      length: length, unit: unit) else { continue }
            let p = zone.protected
            if range.length == 0 {
                if range.location > p.location && range.location < NSMaxRange(p) { return .deny }
                // Перед именем HTML-атрибута: буква или цифра приклеилась бы к имени (`xsrc=`), поэтому вставка должна кончаться пробелом.
                if zone.isAttribute, range.location == p.location, let last = replacement.utf16.last,
                   !(last == 32 || (9...13).contains(last)) { return .deny }
            } else if NSIntersectionRange(range, p).length > 0 {
                cover = NSUnionRange(cover, zone.construct)
            } else if zone.isDefinition, range.location == NSMaxRange(p) {
                // Правка сразу после адреса определения ссылки (Delete на переводе строки) не должна приклеить к нему следующий текст.
                let isSpace: (UInt16) -> Bool = { $0 == 32 || (9...13).contains($0) }
                let next = range.location + range.length < length ? unit(range.location + range.length) : 0
                if !(replacement.utf16.first.map(isSpace) ?? (next == 0 || isSpace(next))) { return .deny }
            } else if zone.isAttribute, end == p.location {
                // Правка кончается перед именем атрибута: после неё прямо перед именем должен остаться пробельный символ (`<imgsrc=`, `xsrc=`).
                let isSpace: (UInt16) -> Bool = { $0 == 32 || (9...13).contains($0) }
                let kept = replacement.utf16.last ?? (range.location > 0 && range.location <= length ? unit(range.location - 1) : 0)
                if !isSpace(kept) { return .deny }
            }
        }
        return cover == range ? .allow : .expand(cover)
    }

    private static func isAddressBoundary(_ c: UInt16) -> Bool {
        c == 32 || (9...13).contains(c) || c == 34 || c == 39 || c == 40 || c == 41 || c == 60 || c == 61 || c == 62
    }

    /// Сдвигает токены после правки. Токены внутри заменяемого диапазона исчезают из карты
    /// (запись в таблице остаётся). `inserted` - токены новой вставки, displayStart в координатах нового текста.
    /// Если правка режет токен, возвращает false и ничего не меняет.
    @discardableResult
    mutating func applyEdit(replacing range: NSRange, withLength newLength: Int,
                            inserting inserted: [MarkdownMediaSpan] = []) -> Bool {
        guard !cutsToken(range) else { return false }
        let end = range.location + range.length
        var left: [MarkdownMediaSpan] = []
        var right: [MarkdownMediaSpan] = []
        for var span in spans {
            if span.displayEnd <= range.location {
                left.append(span)
            } else if span.displayStart >= end {
                span.displayStart += newLength - range.length
                right.append(span)
            }
        }
        self = MarkdownMediaMap(spans: left + inserted.sorted { $0.displayStart < $1.displayStart } + right)
        return true
    }

    private func firstIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

enum MarkdownMediaEditDecision: Equatable, Sendable {
    case allow
    /// Правку нужно делать над этим, более широким диапазоном.
    case expand(NSRange)
    case deny
}

/// Конструкция вокруг одного адреса: что защищено и что удаляется целиком.
struct MarkdownMediaZone: Equatable, Sendable {
    var protected: NSRange
    var construct: NSRange
    /// Значение HTML-атрибута (а не адрес в круглых скобках Markdown).
    var isAttribute = false
    /// Определение ссылки `[id]: адрес`.
    var isDefinition = false

    /// Насколько далеко от токена ищется конструкция (единицы UTF-16).
    static let reach = 600

    private static func isAttributeNameUnit(_ c: UInt16) -> Bool {
        (48...58).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 95
    }

    /// `address` — диапазон токена (или адреса в тексте файла), `unit(i)` — единица UTF-16 по позиции (`0 ..< length`).
    static func around(_ address: NSRange, length: Int, unit: (Int) -> UInt16) -> MarkdownMediaZone? {
        func u(_ i: Int) -> UInt16 { i >= 0 && i < length ? unit(i) : 0 }
        let s = address.location, e = address.location + address.length
        let quote = u(s - 1)
        if quote == 34 || quote == 39 {
            // HTML: `<… src="адрес" …>`, защищены имя атрибута, `=`, кавычки и значение.
            guard u(e) == quote else { return nil }
            // Защищены имя атрибута, `=` (с пробелами вокруг), кавычки и значение: правка любого из них ломает картинку.
            var eq = s - 2
            var gap = 0
            while gap < 8, u(eq) == 32 || u(eq) == 9 { eq -= 1; gap += 1 }
            guard u(eq) == 61 else { return nil }
            var first = eq
            gap = 0
            while gap < 8, u(first - 1) == 32 || u(first - 1) == 9 { first -= 1; gap += 1 }
            while first > 0, isAttributeNameUnit(u(first - 1)) { first -= 1 }
            var a = first - 1
            let low = max(0, s - reach)
            while a >= low, u(a) != 60 {
                if u(a) == 62 { return nil }
                a -= 1
            }
            guard a >= low else { return nil }
            var b = e + 1
            let high = min(length, e + reach)
            while b < high, u(b) != 62 { b += 1 }
            guard b < high else { return nil }
            return MarkdownMediaZone(protected: NSRange(location: first, length: e + 1 - first),
                                     construct: NSRange(location: a, length: b + 1 - a), isAttribute: true)
        }
        var p = s
        if u(p - 1) == 60 { p -= 1 }
        var spaces = 0
        while spaces < 8, u(p - 1) == 32 || u(p - 1) == 9 { p -= 1; spaces += 1 }
        guard u(p - 1) == 40, u(p - 2) == 93 else {
            // Определение ссылки `[id]: адрес` в начале строки: защищены `]`, `:`, пробелы и адрес, удаляется вся запись.
            guard u(p - 1) == 58, u(p - 2) == 93 else { return nil }
            var j = p - 3
            while j >= 0, u(j) != 91, u(j) != 93, u(j) != 10, u(j) != 13 { j -= 1 }
            guard j >= 0, u(j) == 91, j == 0 || u(j - 1) == 10 || u(j - 1) == 13 else { return nil }
            return MarkdownMediaZone(protected: NSRange(location: p - 2, length: e - (p - 2)),
                                     construct: NSRange(location: j, length: e - j), isDefinition: true)
        }
        let open = p - 2
        var f = e
        var inQuote: UInt16 = 0
        let high = min(length, e + reach)
        var close: Int?
        while f < high {
            let c = u(f)
            if inQuote != 0 {
                if c == inQuote { inQuote = 0 }
            } else if c == 34 || c == 39 {
                inQuote = c
            } else if c == 41 {
                close = f
                break
            } else if c == 10 || c == 13 {
                return nil
            }
            f += 1
        }
        guard let close else { return nil }
        // Начало конструкции: парная `[` слева на той же строке (`![` включается).
        var start = open
        var depth = 0
        var j = open - 1
        let low = max(0, open - reach)
        while j >= low, u(j) != 10, u(j) != 13 {
            if u(j) == 93 {
                depth += 1
            } else if u(j) == 91 {
                if depth == 0 { start = u(j - 1) == 33 ? j - 1 : j; break }
                depth -= 1
            }
            j -= 1
        }
        return MarkdownMediaZone(protected: NSRange(location: open, length: close + 1 - open),
                                 construct: NSRange(location: start, length: close + 1 - start))
    }
}

import Foundation

/// Состояние раздела владельца (между метками `human:start` и `human:end`) на странице `compiled/`.
enum VaultOwnerZoneState: Equatable, Sendable {
    /// UTF-16 диапазон текста МЕЖДУ метками (без самих меток).
    case editable(NSRange)
    /// Меток нет и нет признаков повреждения.
    case missing
    /// Пар больше одной, метка без пары, обратный порядок или признаки повреждения.
    case damaged
}

/// Как сервер относится к странице.
enum VaultPageKind: Equatable, Sendable { case regular, compiled, serverReport }

/// Правила раздела владельца: те же, что проверяет сервер при записи страниц `compiled/`.
enum VaultOwnerZone {
    static let startMarker = "<!-- human:start -->"
    static let endMarker = "<!-- human:end -->"

    private static let start = Array(startMarker.utf16)
    private static let end = Array(endMarker.utf16)

    /// `.compiled` только для `compiled/**/*.md` (как `_is_owner_notes_file` на сервере); сравнение по байтам UTF-8.
    static func pageKind(forServerPath path: String) -> VaultPageKind {
        let compiled = VaultServerRules.compiledPrefix.utf8
        if path.utf8.starts(with: compiled), path.utf8.count > compiled.count, path.utf8.reversed().starts(with: ".md".utf8.reversed()) {
            return .compiled
        }
        if path.utf8.starts(with: VaultServerRules.summariesPrefix.utf8)
            || path.utf8.elementsEqual(VaultServerRules.compiledIndexPath.utf8) {
            return .serverReport
        }
        return .regular
    }

    /// Работает по всему тексту страницы (с шапкой), как серверная проверка записи.
    static func state(of text: String) -> VaultOwnerZoneState {
        zoneState(Array(text.utf16), text: text)
    }

    /// Разрешена ли замена `range` строкой `replacement`: только внутри зоны и без появления в ней метки.
    static func allowsEdit(in text: String, range: NSRange, replacement: String) -> Bool {
        let units = Array(text.utf16)
        guard range.location >= 0, range.length >= 0, range.location + range.length <= units.count else { return false }
        if range.length == 0 && replacement.isEmpty { return true }
        guard case .editable(let zone) = zoneState(units, text: text) else { return false }
        guard range.location >= zone.location, NSMaxRange(range) <= NSMaxRange(zone) else { return false }
        var newZone = Array(units[zone.location..<NSMaxRange(zone)])
        let local = NSRange(location: range.location - zone.location, length: range.length)
        newZone.replaceSubrange(local.location..<(local.location + local.length), with: Array(replacement.utf16))
        return positions(of: start, in: newZone).isEmpty && positions(of: end, in: newZone).isEmpty
    }

    /// Изменилась ли только зона: всё до неё и после неё (вместе с метками) совпадает.
    static func onlyOwnerZoneChanged(base: String, candidate: String) -> Bool {
        if base.utf8.elementsEqual(candidate.utf8) { return true }
        let a = Array(base.utf16), b = Array(candidate.utf16)
        guard case .editable(let za) = zoneState(a, text: base),
              case .editable(let zb) = zoneState(b, text: candidate) else { return false }
        return a[..<za.location] == b[..<zb.location] && a[NSMaxRange(za)...] == b[NSMaxRange(zb)...]
    }

    // MARK: - Внутреннее

    private static func zoneState(_ units: [UInt16], text: String) -> VaultOwnerZoneState {
        let starts = positions(of: start, in: units)
        let ends = positions(of: end, in: units)
        if starts.isEmpty && ends.isEmpty { return looksCorrupted(text) ? .damaged : .missing }
        guard starts.count == 1, ends.count == 1, ends[0] >= starts[0] + start.count else { return .damaged }
        let from = starts[0] + start.count
        return .editable(NSRange(location: from, length: ends[0] - from))
    }

    /// Простой поиск по массиву UTF-16: без влияния канонической эквивалентности и склейки `\r\n`.
    private static func positions(of marker: [UInt16], in units: [UInt16]) -> [Int] {
        guard units.count >= marker.count else { return [] }
        var result: [Int] = []
        var i = 0
        while i <= units.count - marker.count {
            if units[i] == marker[0], units[i..<(i + marker.count)].elementsEqual(marker) {
                result.append(i)
            }
            i += 1
        }
        return result
    }

    private static let headingRegex = try? NSRegularExpression(
        pattern: "^##\\s+Owner Notes\\s*$", options: [.anchorsMatchLines, .useUnixLineSeparators])
    private static let populatedRegex = try? NSRegularExpression(
        pattern: "^human_zone_populated:\\s*true\\s*$", options: [.anchorsMatchLines, .useUnixLineSeparators])

    private static func matches(_ regex: NSRegularExpression?, in string: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    /// Меток нет, но есть следы раздела: заголовок «Owner Notes» или флаг `human_zone_populated: true` в шапке.
    private static func looksCorrupted(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if matches(headingRegex, in: normalized) { return true }
        var body = normalized as NSString
        if body.length > 0, body.character(at: 0) == 0xFEFF { body = body.substring(from: 1) as NSString }
        guard body.hasPrefix("---\n") else { return false }
        let rest = body.substring(from: 4) as NSString
        let close = rest.range(of: "\n---")
        guard close.location != NSNotFound else { return false }
        return matches(populatedRegex, in: rest.substring(to: close.location))
    }
}

import Foundation

/// Как редактор обращается со страницей хранилища, которую собирает сервер.
enum VaultPageMode: Equatable, Sendable {
    /// Есть рабочий раздел «Owner Notes»: печатать можно только в нём.
    case ownerZone
    /// Страница `compiled/` без раздела: только чтение.
    case noZone
    /// Метки раздела повреждены (сервер такую страницу не обновляет): только чтение.
    case damaged
    /// Отчёт сервера (`summaries/`, `MOC/compiled-index.md`): только чтение.
    case serverReport
}

/// Решение охранника по одной правке текста.
enum VaultEditDecision: Equatable, Sendable {
    case allow
    case denyOutsideZone
    case denyReadOnly
}

/// Охранник собранной сервером страницы: решает, можно ли заменить диапазон текста.
/// Хранит кэш раздела владельца и сдвигает его за O(1) при наборе внутри раздела,
/// полный проход по тексту делает только при открытии, внешней замене и самолечении кэша.
/// Только главный поток.
final class VaultPageGuard {
    /// `.compiled` или `.serverReport`.
    let kind: VaultPageKind
    private(set) var mode: VaultPageMode
    /// Зовётся только при смене режима.
    var onModeChange: ((VaultPageMode) -> Void)?
    /// Пока `true`, охранник пропускает любые правки (одна серверная замена страницы); после неё кэш пересчитывается.
    var allowsServerUpdate = false

    /// Сколько раз считали весь текст (для тестов).
    private(set) var fullScanCount = 0

    private var zone: NSRange?
    private var cachedLength = -1
    private var lastDenial: Date?
    private var lastAnnounced: VaultPageMode?

    private static let start = Array(VaultOwnerZone.startMarker.utf16)
    private static let end = Array(VaultOwnerZone.endMarker.utf16)

    var isReadOnly: Bool { mode != .ownerZone }

    /// Раздел владельца по кэшу (без метки с обеих сторон); `nil`, если режим не `.ownerZone`.
    var ownerZone: NSRange? { mode == .ownerZone ? zone : nil }

    private init(kind: VaultPageKind, text: NSString) {
        self.kind = kind
        self.mode = kind == .serverReport ? .serverReport : .noZone
        rescan(text)
    }

    /// `nil` для обычных заметок (`.regular`).
    static func make(serverPath: String, text: NSString) -> VaultPageGuard? {
        let kind = VaultOwnerZone.pageKind(forServerPath: serverPath)
        guard kind != .regular else { return nil }
        return VaultPageGuard(kind: kind, text: text)
    }

    // MARK: - Решение

    func decide(range: NSRange, replacement: String, in text: NSString) -> VaultEditDecision {
        if allowsServerUpdate { return .allow }
        if range.length == 0 && replacement.isEmpty { return .allow }
        if mode != .ownerZone { return .denyReadOnly }
        if !cacheIsValid(text) { refresh(in: text) }
        guard mode == .ownerZone, let zone else { return .denyReadOnly }
        guard range.location >= zone.location, range.length >= 0, NSMaxRange(range) <= NSMaxRange(zone) else {
            return .denyOutsideZone
        }
        if formsMarker(range: range, replacement: replacement, zone: zone, in: text) { return .denyOutsideZone }
        return .allow
    }

    /// Вызывается после правки. Кэш сдвигается на изменение длины и сверяется по меткам за O(1);
    /// полный проход только когда метки на ожидаемых местах не нашлись (правка мимо охранника: IME, отмена).
    func textDidChange(in text: NSString) {
        if allowsServerUpdate { refresh(in: text); return }
        if mode == .ownerZone, var z = zone, cachedLength >= 0 {
            z.length += text.length - cachedLength
            if z.length >= 0, markersMatch(z, in: text) {
                zone = z
                cachedLength = text.length
                return
            }
            refresh(in: text)
        } else if text.length != cachedLength {
            refresh(in: text)
        }
    }

    /// Полный пересчёт: внешняя замена текста, серверная правка.
    func refresh(in text: NSString) {
        let old = mode
        rescan(text)
        if mode != old { onModeChange?(mode) }
    }

    /// Следующая проверка или смена текста пересчитают кэш.
    func invalidate() {
        cachedLength = -1
    }

    // MARK: - Приглушение

    /// До двух диапазонов вне раздела (до него и после него), пересечённых с `range`; пусто, если режим не `.ownerZone`.
    func dimRanges(intersecting range: NSRange, textLength: Int) -> [NSRange] {
        guard mode == .ownerZone, let zone else { return [] }
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: textLength))
        guard bounded.length > 0 else { return [] }
        var result: [NSRange] = []
        let before = NSIntersectionRange(bounded, NSRange(location: 0, length: min(zone.location, textLength)))
        if before.length > 0 { result.append(before) }
        let afterStart = min(NSMaxRange(zone), textLength)
        let after = NSIntersectionRange(bounded, NSRange(location: afterStart, length: textLength - afterStart))
        if after.length > 0 { result.append(after) }
        return result
    }

    // MARK: - Обратная связь

    /// `true` — пора подать звук и подсказку: не чаще раза в секунду.
    func registerDenial(now: Date) -> Bool {
        if let last = lastDenial, now.timeIntervalSince(last) < 1 { return false }
        lastDenial = now
        return true
    }

    /// `true` один раз на каждую смену режима (озвучивание плашки).
    func takeAnnouncement(for mode: VaultPageMode) -> Bool {
        if lastAnnounced == mode { return false }
        lastAnnounced = mode
        return true
    }

    // MARK: - Внутреннее

    private func rescan(_ text: NSString) {
        fullScanCount += 1
        cachedLength = text.length
        if kind == .serverReport {
            mode = .serverReport
            zone = nil
            return
        }
        switch VaultOwnerZone.state(of: text as String) {
        case .editable(let range): mode = .ownerZone; zone = range
        case .missing: mode = .noZone; zone = nil
        case .damaged: mode = .damaged; zone = nil
        }
    }

    /// Длина текста та же, и на ожидаемых местах лежат обе метки.
    private func cacheIsValid(_ text: NSString) -> Bool {
        guard let zone, text.length == cachedLength else { return false }
        return markersMatch(zone, in: text)
    }

    /// На местах вокруг `zone` лежат обе метки.
    private func markersMatch(_ zone: NSRange, in text: NSString) -> Bool {
        let startAt = zone.location - Self.start.count
        guard startAt >= 0, NSMaxRange(zone) + Self.end.count <= text.length else { return false }
        return Self.matches(Self.start, at: startAt, in: text) && Self.matches(Self.end, at: NSMaxRange(zone), in: text)
    }

    private static func matches(_ marker: [UInt16], at location: Int, in text: NSString) -> Bool {
        for (i, unit) in marker.enumerated() where text.character(at: location + i) != unit { return false }
        return true
    }

    /// Окно «до 19 единиц слева + замена + до 19 справа» (в пределах раздела): метка могла появиться только здесь.
    private func formsMarker(range: NSRange, replacement: String, zone: NSRange, in text: NSString) -> Bool {
        let reach = Self.start.count - 1
        var window: [UInt16] = []
        let leftFrom = max(zone.location, range.location - reach)
        window.append(contentsOf: Self.units(text, NSRange(location: leftFrom, length: range.location - leftFrom)))
        window.append(contentsOf: replacement.utf16)
        let rightTo = min(NSMaxRange(zone), NSMaxRange(range) + reach)
        window.append(contentsOf: Self.units(text, NSRange(location: NSMaxRange(range), length: rightTo - NSMaxRange(range))))
        return Self.contains(Self.start, in: window) || Self.contains(Self.end, in: window)
    }

    private static func units(_ text: NSString, _ range: NSRange) -> [UInt16] {
        guard range.length > 0 else { return [] }
        var buffer = [UInt16](repeating: 0, count: range.length)
        text.getCharacters(&buffer, range: range)
        return buffer
    }

    private static func contains(_ marker: [UInt16], in units: [UInt16]) -> Bool {
        guard units.count >= marker.count else { return false }
        var i = 0
        while i <= units.count - marker.count {
            if units[i] == marker[0], units[i..<(i + marker.count)].elementsEqual(marker) { return true }
            i += 1
        }
        return false
    }
}

/// Проверка перед отправкой страницы на сервер: что-то вне разрешённого меняться не должно.
enum VaultUploadCheck {
    /// `false` — отправлять нельзя (ошибка программы или правка вне разрешённого).
    static func allows(serverPath: String, base: String, candidate: String) -> Bool {
        switch VaultOwnerZone.pageKind(forServerPath: serverPath) {
        case .regular: return true
        case .compiled: return VaultOwnerZone.onlyOwnerZoneChanged(base: base, candidate: candidate)
        case .serverReport: return base.utf8.elementsEqual(candidate.utf8)
        }
    }
}

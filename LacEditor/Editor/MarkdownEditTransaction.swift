import Foundation

/// Одна программная правка текста редактора: что заменить, почему, и что проверить до замены.
/// Текст редактора — строка `NSTextStorage` (с токенами media), все диапазоны — UTF-16.
/// Саму замену, группу отмены и проверки выполняет `EditorCoordinator.perform(_:)`; здесь только описание правки и чистые проверки.
struct MarkdownEditTransaction {
    /// Причина правки: от неё зависят проверки и поведение отмены.
    enum Reason: Equatable, Sendable {
        /// Команды форматирования, строковые команды, чекбокс, видео, забор кода, язык блока, перетаскивание таблицы, CriticMarkup, текстовые команды.
        case formatting
        /// Отступ/выступ элемента списка и перенумерация.
        case listContinuation
        /// Запись текста активной ячейки таблицы в хранилище.
        case tableCell
        /// Программная вставка (Markdown из буфера, «наш» исходник с media).
        case paste
        /// Ответ ИИ, сниппеты, диктовка, автодополнение, замена из поиска.
        case aiReplacement
    }

    struct Edit: Equatable, Sendable {
        var range: NSRange
        var replacement: String
    }

    enum Refusal: Equatable, Sendable {
        /// Режим чтения, нет текстового вида или хранилища.
        case notEditable
        /// Идёт ввод через IME.
        case markedText
        /// Версия текста изменилась после подготовки правки.
        case staleRevision
        /// Диапазон вне текста, `NSNotFound`, пустой список правок или неверный порядок.
        case outOfBounds
        /// Текст по диапазону не совпал с ожидаемым.
        case textChanged
        /// Замена равна тексту по диапазону.
        case unchanged
        /// Правка режет токен media (задевает его лишь частью).
        case protectedMedia
        /// Правка внутри защищённой части адреса media или склеивает токен с соседним символом.
        case protectedAddress
        /// Граница внутри картинки или формулы (карта текста).
        case insideReplacement(NSRange)
        /// Граница внутри скрытого маркера (`**`, `## `): пользователь видит текст без него.
        case insideHiddenSyntax(NSRange)
        /// `shouldChangeText` вернул false (охранник хранилища, редактор ячейки и др.).
        case rejectedByTextSystem
    }

    enum Outcome: Equatable, Sendable {
        /// Диапазон вставленного текста в новом тексте (последняя правка пачки).
        case applied(NSRange)
        case refused(Refusal)
    }

    var reason: Reason
    /// Одна правка в обычном случае; несколько — только от конца к началу и без пересечений.
    var edits: [Edit]
    /// nil — версию не сверять (правка собрана в том же вызове).
    var expectedRevision: UInt? = nil
    /// Что должно лежать по `edits[0].range`; сравнение по UTF-16.
    var expectedOriginal: String? = nil
    var selectionAfter: NSRange? = nil
    /// Выделение пользователя до правки: `undo` возвращает его после отката текста (AppKit сам выделяет восстановленный диапазон правки).
    /// nil — отмена ничего не добавляет. Повтор (`redo`) остаётся на AppKit.
    var selectionBefore: NSRange? = nil
    var scrollsToSelection = false
    /// Имя в меню «Отменить …».
    var actionName: String? = nil
    /// false — без своей группы отмены (как у перенумерации списка и замены текста целиком).
    var groupsUndo = true
    /// Не записывать правку в историю отмены (серверное обновление хранилища).
    var suppressUndoRegistration = false
    /// true — после проверок вставить обычным `insertText` (не автоправкой): работают сдвиг оформления и перенумерация списка, как при наборе.
    /// Только для одной правки; `selectionAfter` не задавать, каретку ставит сам `insertText`.
    var usesTextInput = false
    /// Между `replaceCharacters` и `didChangeText` (нужно только записи ячейки таблицы).
    var afterReplace: (() -> Void)? = nil
    /// После замены, до `setActionName`: выделение, которое зависит от уже сдвинутой карты, и регистрация отмены файла картинки.
    var afterApply: (() -> Void)? = nil

    init(_ reason: Reason, range: NSRange, replacement: String) {
        self.reason = reason
        edits = [Edit(range: range, replacement: replacement)]
    }

    init(_ reason: Reason, edits: [Edit]) {
        self.reason = reason
        self.edits = edits
    }

    /// nil — диапазоны годятся; иначе причина отказа. Правки идут от конца к началу, без пересечений.
    static func geometryRefusal(_ edits: [Edit], textLength: Int) -> Refusal? {
        guard !edits.isEmpty else { return .outOfBounds }
        var previousStart = textLength
        for edit in edits {
            let range = edit.range
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                  range.location + range.length <= previousStart else { return .outOfBounds }
            previousStart = range.location
        }
        return nil
    }

    /// Диапазоны внутри `enclosing`, которые Writing Tools (системные «Инструменты письма») нельзя менять:
    /// токены media с защищённой частью адреса, скрытые маркеры и замены из карты текста, исключённые части (код, формулы, HTML, таблицы).
    /// Результат отсортирован, без пустых и пересекающихся диапазонов, в координатах всего текста.
    static func protectedRanges(in enclosing: NSRange, textLength: Int, mediaMap: MarkdownMediaMap,
                                unit: (Int) -> UInt16, displayMap: MarkdownDisplayMap?, excluded: [NSRange]) -> [NSRange] {
        guard enclosing.location != NSNotFound, enclosing.location >= 0, enclosing.length > 0,
              enclosing.location < textLength else { return [] }
        let window = NSRange(location: enclosing.location, length: min(enclosing.length, textLength - enclosing.location))
        var found: [NSRange] = []

        if !mediaMap.isEmpty {
            let reach = MarkdownMediaZone.reach
            let wide = NSRange(location: max(0, window.location - reach),
                               length: min(textLength, NSMaxRange(window) + reach) - max(0, window.location - reach))
            let spans = mediaMap.spans
            for index in mediaMap.spanIndices(intersecting: wide) {
                let token = NSRange(location: spans[index].displayStart, length: spans[index].displayLength)
                found.append(token)
                if let zone = MarkdownMediaZone.around(token, length: textLength, unit: unit) { found.append(zone.protected) }
            }
        }

        if let entries = displayMap?.entries {
            var low = 0
            var high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(entries[mid].source) > window.location { high = mid } else { low = mid + 1 }
            }
            while low < entries.count, entries[low].source.location < NSMaxRange(window) {
                found.append(entries[low].source)
                low += 1
            }
        }
        found.append(contentsOf: excluded)

        var clipped: [NSRange] = []
        for range in found {
            let part = NSIntersectionRange(range, window)
            if part.length > 0 { clipped.append(part) }
        }
        clipped.sort { $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length }
        var merged: [NSRange] = []
        for range in clipped {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

import Foundation

/// Место в документе: строка и столбец с 1 по тексту файла, а не смещение. После правок это «примерно там же».
struct NavigationLocation: Equatable {
    let documentID: UUID
    let line: Int
    let column: Int

    /// `location` — UTF-16 в тексте файла; за пределами текста ограничивается его концом.
    static func make(documentID: UUID, text: String, location: Int) -> NavigationLocation {
        let position = LogicalLineIndex(text: text).position(at: location, in: text as NSString)
        return NavigationLocation(documentID: documentID, line: position.line, column: position.column)
    }

    /// UTF-16 позиция для текущего текста. Строка за концом даёт последнюю строку, столбец ограничен длиной строки.
    func location(in text: String) -> Int {
        let index = LogicalLineIndex(text: text)
        return index.location(line: min(max(line, 1), index.lineCount), column: column, in: text as NSString) ?? 0
    }
}

/// Два стека (назад и вперёд). Не сохраняется в сессию.
struct NavigationHistory {
    static let limit = 50
    private(set) var back: [NavigationLocation] = []
    private(set) var forward: [NavigationLocation] = []
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Новый переход: старое место в «назад» (не повторяя последнее), «вперёд» очищается, лимит 50.
    mutating func record(_ origin: NavigationLocation) {
        forward.removeAll()
        guard back.last != origin else { return }
        back.append(origin)
        Self.trim(&back)
    }

    /// Берёт ближайшее подходящее место из «назад»; текущее кладёт в «вперёд». Непригодные и равные текущему отбрасывает.
    mutating func goBack(from current: NavigationLocation, isValid: (NavigationLocation) -> Bool) -> NavigationLocation? {
        guard let target = Self.take(&back, current: current, isValid: isValid) else { return nil }
        if forward.last != current { forward.append(current) }
        Self.trim(&forward)
        return target
    }

    /// Симметрично `goBack`: текущее место кладётся в «назад».
    mutating func goForward(from current: NavigationLocation, isValid: (NavigationLocation) -> Bool) -> NavigationLocation? {
        guard let target = Self.take(&forward, current: current, isValid: isValid) else { return nil }
        if back.last != current { back.append(current) }
        Self.trim(&back)
        return target
    }

    private static func take(_ stack: inout [NavigationLocation], current: NavigationLocation,
                             isValid: (NavigationLocation) -> Bool) -> NavigationLocation? {
        while let candidate = stack.popLast() {
            if candidate != current, isValid(candidate) { return candidate }
        }
        return nil
    }

    private static func trim(_ stack: inout [NavigationLocation]) {
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }
}

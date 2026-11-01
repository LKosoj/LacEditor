import Foundation

/// Метки вместо токенов media в запросах к модели: `⟦image 1⟧`, с описанием `⟦image 1: кот на диване⟧`.
/// Номер живёт до выхода из приложения, поэтому в разговоре и шагах агента метка одного токена не меняется.
final class AIMediaPlaceholders: @unchecked Sendable {
    static let shared = AIMediaPlaceholders()

    /// Для номера, которого не выдавали: такого токена нет в таблице, и проверка `incoming` отклонит ответ.
    private static let unknownToken = "data:image/png;base64,AA==#lac-media-0000000000000000"
    private static let pattern = try! NSRegularExpression(pattern: "⟦(?:image|media) ([0-9]{1,9})(?::[^⟧]*)?⟧")

    private let lock = NSLock()
    private var tokens: [String] = []
    private var numbers: [String: Int] = [:]

    func placeholder(for token: String, description: String?) -> String {
        lock.lock(); defer { lock.unlock() }
        let number: Int
        if let known = numbers[token] {
            number = known
        } else {
            tokens.append(token)
            number = tokens.count
            numbers[token] = number
        }
        let kind = token.lowercased().hasPrefix("data:image/") ? "image" : "media"
        return description.map { "⟦\(kind) \(number): \($0)⟧" } ?? "⟦\(kind) \(number)⟧"
    }

    /// Ответ модели: метки снова становятся токенами, дальше текст идёт обычным путём ответов ИИ.
    func restore(_ text: String) -> String {
        guard text.contains("⟦") else { return text }
        lock.lock(); defer { lock.unlock() }
        let result = NSMutableString(string: text)
        let matches = Self.pattern.matches(in: text, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let number = Int(result.substring(with: match.range(at: 1))) ?? 0
            let token = tokens.indices.contains(number - 1) ? tokens[number - 1] : Self.unknownToken
            result.replaceCharacters(in: match.range, with: token)
        }
        return result as String
    }
}

/// Изображение из запроса. У токена адрес берётся из таблицы документа, настоящий адрес лежит в самом тексте.
struct AIMediaImage: Sendable {
    let anchor: String
    let token: String?
    let address: String?
}

/// Описания изображений по якорю `lac-media-<хэш>`: хэш считается по адресу, поэтому одно изображение
/// в любом документе получает одно описание. Файл общий на приложение, документы его не касаются.
final class AIImageDescriptionStore: @unchecked Sendable {
    static let shared = AIImageDescriptionStore(url: defaultStorageURL())

    private let lock = NSLock()
    private let url: URL
    private var items: [String: String]?

    init(url: URL) { self.url = url }

    func description(for anchor: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[anchor]
    }

    func save(_ description: String, for anchor: String) {
        lock.lock(); defer { lock.unlock() }
        var values = loaded()
        values[anchor] = description
        items = values
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func loaded() -> [String: String] {
        if let items { return items }
        let values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        items = values
        return values
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("AIImageDescriptions.json")
    }
}

/// Перед текстовым запросом получает недостающие описания изображений, если выключатель включён.
enum AIImageDescriber {
    struct Source: Sendable {
        var tables: [MarkdownMediaTable]
        var store: AIImageDescriptionStore
        var describe: @Sendable (Data) async throws -> String
    }

    private static let maximumLength = 500
    private static let describableTypes = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"]

    @MainActor private static let states = NSHashTable<AppState>.weakObjects()

    /// Окон несколько, а токены разных документов лежат в таблицах этих документов.
    @MainActor static func register(_ state: AppState) { states.add(state) }

    @MainActor static var source: @MainActor () throws -> Source? = {
        let alive = states.allObjects
        guard let preferences = alive.first?.preferences, preferences.aiImageDescriptionsEnabled else { return nil }
        let profile = preferences.aiProfile(for: .imageDescription)
        guard profile.isEnabled else { return nil }
        let key = try AIKeychainStore().load(for: AIFeature.imageDescription.role, baseURL: profile.baseURL)
        return Source(tables: alive.flatMap { $0.documents.map(\.mediaTable) }, store: .shared) {
            try await AIWritingService.describeImage(data: $0, profile: profile, key: key)
        }
    }

    /// Описания по якорю для изображений запроса. Сбой сети или настроек виден как ошибка запроса;
    /// изображение, которое модель не приняла, идёт без описания и не мешает тексту.
    static func descriptions(for content: Any) async throws -> [String: String] {
        guard let source = try await MainActor.run(body: { try Self.source() }) else { return [:] }
        var found: [AIMediaImage] = []
        _ = AIRequestMediaSanitizer.sanitize(content, descriptions: [:]) { found.append($0) }
        var result: [String: String] = [:]
        for image in found where result[image.anchor] == nil {
            if let stored = source.store.description(for: image.anchor) {
                result[image.anchor] = stored
                continue
            }
            let address = image.address ?? image.token.flatMap { token in
                source.tables.lazy.compactMap { $0.source(forToken: token) }.first
            }
            // Обрывок токена выглядит как адрес из одного байта `AA==`: описывать там нечего.
            guard let data = address.flatMap(imageData), data.count > 1 else { continue }
            try Task.checkCancellation()
            do {
                let description = cleaned(try await source.describe(data))
                guard !description.isEmpty else { continue }
                source.store.save(description, for: image.anchor)
                result[image.anchor] = description
            } catch AIError.invalidResponse {
                continue
            } catch AIError.refused {
                continue
            }
        }
        return result
    }

    /// Только растровые изображения в Base64: остальное модель описания не принимает.
    private static func imageData(_ address: String) -> Data? {
        guard let comma = address.firstIndex(of: ",") else { return nil }
        let parts = address[..<comma].dropFirst(5).lowercased().split(separator: ";")
        guard let type = parts.first, describableTypes.contains(String(type)), parts.last == "base64" else { return nil }
        return Data(base64Encoded: String(address[address.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    /// Описание встаёт внутрь метки и внутрь JSON источников: одна строка без знаков, ломающих то и другое.
    private static func cleaned(_ text: String) -> String {
        let line = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(line.filter { !"⟦⟧\"\\".contains($0) }.prefix(maximumLength))
    }
}

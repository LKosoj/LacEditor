import Foundation

/// Проверка путей, пришедших от сервера хранилища: клиент строже сервера.
enum VaultPath {
    /// Возвращает путь как есть, если он безопасен, иначе nil.
    static func validated(_ serverPath: String) -> String? {
        // Всё по байтам UTF-8: сочетаемый знак после «/» не должен менять смысл разделителя.
        let bytes = serverPath.utf8
        guard let first = bytes.first, first != 0x2F, !bytes.contains(0), !bytes.contains(0x5C) else { return nil }
        for component in bytes.split(separator: 0x2F, omittingEmptySubsequences: false) {
            if component.isEmpty || component.first == 0x2E { return nil }
        }
        return serverPath
    }

    /// Адрес файла внутри `root` или nil, если путь небезопасен либо выходит за корень. Диска не касается.
    static func localURL(for serverPath: String, under root: URL) -> URL? {
        guard let path = validated(serverPath) else { return nil }
        let rootURL = root.standardizedFileURL
        var url = rootURL
        for component in path.utf8.split(separator: 0x2F) {
            url = url.appendingPathComponent(String(decoding: component, as: UTF8.self), isDirectory: false)
        }
        url = url.standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return url.path.hasPrefix(prefix) ? url : nil
    }
}

/// Какие страницы хранилища пересобирает сервер и какие поля шапки он меняет сам.
enum VaultServerRules {
    static let compiledPrefix = "compiled/"
    static let summariesPrefix = "summaries/"
    static let compiledIndexPath = "MOC/compiled-index.md"

    /// Страница, которую сервер пересобирает сам (путь уже проверен `VaultPath.validated`; регистр важен).
    static func isServerManaged(_ path: String) -> Bool {
        path.utf8.starts(with: compiledPrefix.utf8) || path.utf8.starts(with: summariesPrefix.utf8)
            || path.utf8.elementsEqual(compiledIndexPath.utf8)
    }

    /// Поля шапки, которые сервер пересчитывает по давности обращения.
    static let systemFrontmatterFields: Set<String> = ["last_accessed", "relevance", "tier", "access_count"]
}

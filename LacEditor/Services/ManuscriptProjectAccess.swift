import Foundation

/// Правила файлов проекта рукописи: какие расширения допустимы и какой путь считается безопасным.
enum ManuscriptProjectFiles {
    /// Расширения, на которые может ссылаться узел.
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "fountain"]
    /// Расширения, которые берёт сборка Markdown-книги (`.fountain` в сборку не попадает).
    static let compileExtensions: Set<String> = ["md", "markdown", "txt"]
    static let serviceFolderName = ".laceditor"

    /// Относительный путь внутри корня либо nil (вне корня, служебная папка, неподдерживаемое расширение).
    static func relativePath(for url: URL, root: URL) -> String? {
        guard let relative = FolderSearchService.relativePath(url, root: root),
              ManuscriptProjectValidation.isSafeRelativePath(relative),
              !isServiceFolder(relativePath: relative),
              textExtensions.contains((relative as NSString).pathExtension.lowercased()) else { return nil }
        return relative
    }

    /// Скрытая служебная папка: относительный путь начинается с `.laceditor`.
    static func isServiceFolder(relativePath: String) -> Bool {
        relativePath == serviceFolderName || relativePath.hasPrefix(serviceFolderName + "/")
    }
}

import XCTest

/// Проверка исходников: шрифты в Views задаются текстовыми стилями macOS, а не фиксированным размером.
final class SemanticFontTests: XCTestCase {
    /// Исключения: значки и геометрия, не текст. Ключ — файл, значение — фрагменты строк.
    private let allowed: [String: [String]] = [
        "StatusBarView.swift": [".font(.system(size: 6))", ".font(.system(size: 8))"], // точка и значок статуса
        "SidebarView.swift": ["Image(systemName: \"arrow.up.right\").font(.system(size: 9))"],
        "SidebarLibraryView.swift": [
            ".font(.system(size: 8, weight: .semibold))",   // вращающиеся шевроны
            ".font(.system(size: 10))",                      // значок очистки в рамке 24x24
            ".font(.system(size: 14, weight: .medium))"      // значок в плитке 28x28
        ],
        "SettingsView.swift": ["section.symbol).font(.system(size: 14))"],            // значок в рамке шириной 20
        "LacEditorDesign.swift": [".font(.system(size: 18, weight: .medium))"]        // значок в плитке 40x40
    ]

    func testViewsUseSemanticFontsOutsideAllowlist() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var violations: [String] = []
        for file in files {
            let name = file.lastPathComponent
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("system(size:") || line.contains("systemFont(ofSize:") {
                if allowed[name]?.contains(where: { line.contains($0) }) != true {
                    violations.append("\(name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Фиксированный размер шрифта вне списка исключений:\n" + violations.joined(separator: "\n"))
    }
}

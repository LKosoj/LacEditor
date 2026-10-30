import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class NoteTemplateTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-30 14:05:00 UTC
    private var date: Date { Date(timeIntervalSince1970: 1_793_369_100) }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    func testRenderSubstitutesKnownTokens() {
        let result = NoteTemplateService.render("# {{title}}\n{{date}} {{time}} {{title}}", title: "笔记😀", date: date, timeZone: utc)
        XCTAssertEqual(result, "# 笔记😀\n2026-10-30 14:05 笔记😀")
    }

    func testRenderLeavesUnknownAndDoesNotRescanValues() {
        XCTAssertEqual(NoteTemplateService.render("{{x}} {{ title }} {{Title}} {{", title: "t", date: date, timeZone: utc),
                       "{{x}} {{ title }} {{Title}} {{")
        XCTAssertEqual(NoteTemplateService.render("{{title}}", title: "{{date}}", date: date, timeZone: utc), "{{date}}")
        XCTAssertEqual(NoteTemplateService.render("", title: "t", date: date, timeZone: utc), "")
        XCTAssertEqual(NoteTemplateService.render("a\r\n{{title}}\r\n", title: "t", date: date, timeZone: utc), "a\r\nt\r\n")
    }

    func testRenderMatchesTokensByUnicodeScalars() {
        XCTAssertEqual(NoteTemplateService.render("{{title}}\u{301} {{title\u{301}}}", title: "t", date: date, timeZone: utc),
                       "t\u{301} {{title\u{301}}}")
    }

    func testDailyNotePlanRejectsDirectoryAndSymlink() throws {
        let root = try temporaryDirectory()
        let service = FileService()
        func plan() throws -> NoteTemplateService.DailyNotePlan {
            try NoteTemplateService.dailyNotePlan(
                root: root, subfolder: "", templatesFolder: "", date: date, format: "yyyy-MM-dd",
                timeZone: utc, validateDirectory: { try service.validateWorkspaceDirectory($0, root: root) })
        }
        let url = root.appendingPathComponent("2026-10-30.md")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try plan())
        XCTAssertThrowsError(try NoteTemplateService.requireRegularFile(url))
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("target.md")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try plan())
        XCTAssertThrowsError(try NoteTemplateService.requireRegularFile(url))
        try FileManager.default.removeItem(at: url)
        XCTAssertNoThrow(try NoteTemplateService.requireRegularFile(target))
    }

    func testDailyNoteFileName() {
        XCTAssertEqual(NoteTemplateService.dailyNoteFileName(date: date, format: "yyyy-MM-dd", timeZone: utc), "2026-10-30.md")
        XCTAssertEqual(NoteTemplateService.dailyNoteFileName(date: date, format: "yyyyMMdd", timeZone: utc), "20261030.md")
        XCTAssertEqual(NoteTemplateService.dailyNoteFileName(date: date, format: "", timeZone: utc), "2026-10-30.md")
        XCTAssertEqual(NoteTemplateService.dailyNoteFileName(date: date, format: "yyyy/MM/dd", timeZone: utc), "2026-10-30.md")
        XCTAssertEqual(NoteTemplateService.dailyNoteFileName(date: date, format: "HH:mm", timeZone: utc), "2026-10-30.md")
        XCTAssertFalse(NoteTemplateService.dailyNoteFileName(date: date, format: "yyyy-'W'ww", timeZone: utc).isEmpty)
    }

    func testNormalizedFileName() {
        XCTAssertEqual(NoteTemplateService.normalizedFileName("a"), "a.md")
        XCTAssertEqual(NoteTemplateService.normalizedFileName("a.markdown"), "a.markdown")
        XCTAssertEqual(NoteTemplateService.normalizedFileName("a.MD"), "a.MD")
        XCTAssertEqual(NoteTemplateService.normalizedFileName("  a  "), "a.md")
        XCTAssertEqual(NoteTemplateService.normalizedFileName("a.txt"), "a.txt.md")
        XCTAssertEqual(NoteTemplateService.normalizedFileName("  "), "")
    }

    func testListTemplates() throws {
        let folder = try temporaryDirectory()
        for name in ["b10.md", "b2.md", "c.MARKDOWN", "skip.txt"] {
            try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.md"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.md"),
                                                   withDestinationURL: folder.appendingPathComponent("b2.md"))
        XCTAssertEqual(try NoteTemplateService.listTemplates(in: folder).map(\.lastPathComponent), ["b2.md", "b10.md", "c.MARKDOWN"])
        XCTAssertThrowsError(try NoteTemplateService.listTemplates(in: folder.appendingPathComponent("missing")))
    }

    func testReadTemplateAcceptsOnlyUTF8() throws {
        let folder = try temporaryDirectory()
        let good = folder.appendingPathComponent("good.md")
        try Data("привет 😀".utf8).write(to: good)
        XCTAssertEqual(try NoteTemplateService.readTemplate(good), "привет 😀")
        let utf16 = folder.appendingPathComponent("utf16.md")
        // BOM FF FE не является корректным UTF-8 (байты одной кириллицы в UTF-16LE случайно корректны).
        try (Data([0xFF, 0xFE]) + "привет".data(using: .utf16LittleEndian)!).write(to: utf16)
        XCTAssertThrowsError(try NoteTemplateService.readTemplate(utf16)) {
            guard case NoteTemplateService.TemplateError.notUTF8 = $0 else { return XCTFail("\($0)") }
        }
        let latin1 = folder.appendingPathComponent("latin1.md")
        try Data([0xE9, 0xE8]).write(to: latin1)
        XCTAssertThrowsError(try NoteTemplateService.readTemplate(latin1))
    }

    func testResolveSubfolder() {
        let root = URL(fileURLWithPath: "/tmp/root", isDirectory: true)
        XCTAssertEqual(NoteTemplateService.resolveSubfolder("", root: root), root)
        XCTAssertEqual(NoteTemplateService.resolveSubfolder("notes/daily", root: root)?.path, "/tmp/root/notes/daily")
        XCTAssertNil(NoteTemplateService.resolveSubfolder("../x", root: root))
        XCTAssertNil(NoteTemplateService.resolveSubfolder("a/../../x", root: root))
        XCTAssertNil(NoteTemplateService.resolveSubfolder("/abs", root: root))
    }

    func testCreateWorkspaceTextFileDoesNotOverwrite() throws {
        let root = try temporaryDirectory()
        let service = FileService()
        let url = try service.createWorkspaceTextFile(named: "n.md", contents: "первый", in: root, root: root)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "первый")
        XCTAssertThrowsError(try service.createWorkspaceTextFile(named: "n.md", contents: "второй", in: root, root: root))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "первый")
        XCTAssertThrowsError(try service.createWorkspaceTextFile(named: "a/b.md", contents: "", in: root, root: root))
        XCTAssertThrowsError(try service.createWorkspaceTextFile(named: "..", contents: "", in: root, root: root))
        let outside = try temporaryDirectory()
        XCTAssertThrowsError(try service.createWorkspaceTextFile(named: "o.md", contents: "", in: outside, root: root))
    }

    func testPreferencesDefaultsAndPersistence() throws {
        let suite = "NoteTemplateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.templatesFolderPath, "")
        XCTAssertEqual(preferences.dailyNotesFolder, "")
        XCTAssertEqual(preferences.dailyNoteDateFormat, "yyyy-MM-dd")
        preferences.templatesFolderPath = "/t"
        preferences.dailyNotesFolder = "daily"
        preferences.dailyNoteDateFormat = "yyyyMMdd"
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.templatesFolderPath, "/t")
        XCTAssertEqual(reloaded.dailyNotesFolder, "daily")
        XCTAssertEqual(reloaded.dailyNoteDateFormat, "yyyyMMdd")
        XCTAssertEqual(reloaded.startupFolderPath, "")
    }

    func testDailyNotePlan() throws {
        let root = try temporaryDirectory()
        let templates = try temporaryDirectory()
        let service = FileService()
        func plan(subfolder: String = "", templatesFolder: String = "") throws -> NoteTemplateService.DailyNotePlan {
            try NoteTemplateService.dailyNotePlan(
                root: root, subfolder: subfolder, templatesFolder: templatesFolder, date: date, format: "yyyy-MM-dd",
                timeZone: utc, validateDirectory: { try service.validateWorkspaceDirectory($0, root: root) })
        }
        let url = root.appendingPathComponent("2026-10-30.md")
        XCTAssertEqual(try plan(), .create(url, ""))
        XCTAssertEqual(try plan(templatesFolder: templates.path), .create(url, ""))
        try Data("# {{title}} {{date}}".utf8).write(to: templates.appendingPathComponent("daily.md"))
        XCTAssertEqual(try plan(templatesFolder: templates.path), .create(url, "# 2026-10-30 2026-10-30"))
        try Data([0xFF, 0xFE, 0x00]).write(to: templates.appendingPathComponent("daily.md"))
        XCTAssertThrowsError(try plan(templatesFolder: templates.path))
        try "готово".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try plan(templatesFolder: templates.path), .open(url))
        XCTAssertThrowsError(try plan(subfolder: "missing"))
        XCTAssertThrowsError(try plan(subfolder: "../x"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
        XCTAssertEqual(try plan(subfolder: "daily"), .create(root.appendingPathComponent("daily/2026-10-30.md"), ""))
    }
}

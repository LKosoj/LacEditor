import XCTest
@preconcurrency @testable import LacEditor

final class FountainExportTests: XCTestCase {
    private let options = FountainExportService.Options(syntax: MarkdownSyntaxOptions())

    private func convert(_ markdown: String) -> String {
        FountainExportService.convertDocument(markdown, options: options).text
    }

    // MARK: Структура

    func testHeadingAndAction() {
        XCTAssertEqual(convert("# Chapter\n\nHe walks in.\n"), "# Chapter\n\nHe walks in.\n")
    }

    func testTitlePageFromFrontMatter() {
        let text = convert("---\ntitle: Моя пьеса\nauthor: Анна\n---\n\nТекст.\n")
        XCTAssertTrue(text.hasPrefix("Title: Моя пьеса\nAuthor: Анна\n\n"))
        XCTAssertTrue(text.hasSuffix("Текст.\n"))
    }

    func testEmphasisAndEscapedUnderscore() {
        let text = convert("He *really* meant **it** in snake_case.\n")
        XCTAssertTrue(text.contains("*really*"))
        XCTAssertTrue(text.contains("**it**"))
        XCTAssertTrue(text.contains("snake\\_case"))
    }

    func testSoftBreakJoinsAndHardBreakStays() {
        XCTAssertTrue(convert("first\nsecond\n").contains("first second"))
        XCTAssertTrue(convert("first  \nsecond\n").contains("first\nsecond"))
        XCTAssertTrue(convert("你好\n世界\n").contains("你好世界"))
    }

    func testThematicBreakAndPageBreak() {
        XCTAssertTrue(convert("a\n\n---\n\nb\n").contains("\n===\n"))
        XCTAssertTrue(convert("a\n\n<div style=\"page-break-after: always;\"></div>\n\nb\n").contains("\n===\n"))
    }

    // MARK: Сценарные строки

    func testNativeRussianAndChineseScenes() {
        XCTAssertTrue(convert("INT. KITCHEN - DAY\n\nHe pours tea.\n").hasPrefix("INT. KITCHEN - DAY\n\nHe pours tea."))
        XCTAssertTrue(convert("ИНТ. КУХНЯ - ДЕНЬ\n\nОна наливает чай.\n").hasPrefix(".ИНТ. КУХНЯ - ДЕНЬ\n\n"))
        XCTAssertTrue(convert("内景. 厨房 - 白天\n\n她倒茶。\n").hasPrefix(".内景. 厨房 - 白天\n\n"))
    }

    func testDialogueInThreeLanguages() {
        XCTAssertEqual(convert("JOHN: Hello there.\n"), "JOHN\nHello there.\n")
        XCTAssertEqual(convert("АННА: Привет.\n"), "АННА\nПривет.\n")
        XCTAssertEqual(convert("JOHN (quietly): Hi.\n"), "JOHN\n(quietly)\nHi.\n")
    }

    func testChineseNameNeedsTwoOccurrences() {
        let text = convert("李雷：你好。\n\n韩梅梅：你好。\n\n李雷：再见。\n")
        XCTAssertTrue(text.contains("@李雷\n你好。"))
        XCTAssertTrue(text.contains("@李雷\n再见。"))
        XCTAssertFalse(text.contains("@韩梅梅"))
    }

    func testLowercaseColonProseIsActionAndFirstKeyLineIsProtected() {
        XCTAssertEqual(convert("He waits.\n\nNote: remember this.\n"), "He waits.\n\nNote: remember this.\n")
        // Первая строка вида «Ключ:» без титульной страницы иначе стала бы ею.
        XCTAssertEqual(convert("Note: remember this.\n"), "!Note: remember this.\n")
    }

    func testTransitions() {
        XCTAssertTrue(convert("He leaves.\n\nCUT TO:\n").contains("\n\nCUT TO:"))
        XCTAssertFalse(convert("He leaves.\n\nCUT TO:\n").contains("> CUT"))
        XCTAssertTrue(convert("FADE OUT.\n").contains("> FADE OUT."))
        XCTAssertTrue(convert("淡入\n").contains("> 淡入"))
    }

    // MARK: Защита `!`

    func testProseThatLooksLikeFountainGetsBang() {
        XCTAssertEqual(convert("= not a synopsis\n"), "!= not a synopsis\n")
        XCTAssertEqual(convert("~ not lyrics\n"), "!~ not lyrics\n")
        XCTAssertEqual(convert("@home\n"), "!@home\n")
        XCTAssertEqual(convert("#hashtag\n"), "!#hashtag\n")
        XCTAssertEqual(convert("!Wow\n"), "!!Wow\n")
        XCTAssertEqual(convert(".NET is great\n"), "!.NET is great\n")
        XCTAssertEqual(convert("# .NET Tips\n"), "# .NET Tips\n")
        XCTAssertEqual(convert(".INT. ROOM - DAY\n"), ".INT. ROOM - DAY\n")
        XCTAssertEqual(convert("Int the house he sat.\n"), "!Int the house he sat.\n")
    }

    func testEveryOutputBlockSurvivesTheOracle() {
        let markdown = "= a\n\n~ b\n\n@c\n\n#d\n\n> e\n\n.f\n\nint g\n\nHello world.\n"
        let result = FountainExportService.convertDocument(markdown, options: options)
        XCTAssertTrue(result.lint.isValid)
        XCTAssertFalse(result.lint.lines.contains { $0.kind == .synopsis || $0.kind == .lyrics || $0.kind == .character })
    }

    // MARK: Заметки и предупреждения

    func testImageBecomesNoteWithWarning() {
        let result = FountainExportService.convertDocument("![Cat](cat.png)\n", options: options)
        XCTAssertEqual(result.text, "[[Cat (cat.png)]]\n")
        XCTAssertEqual(result.warnings.first { $0.kind == .image }?.count, 1)
    }

    func testCriticCommentBecomesNoteAndEditsAreAccepted() {
        let result = FountainExportService.convertDocument("Hello {++world++}{--old--}{>>check this<<}\n", options: options)
        XCTAssertTrue(result.text.contains("Hello world"))
        XCTAssertTrue(result.text.contains("[[check this]]"))
        XCTAssertFalse(result.text.contains("{++"))
        XCTAssertFalse(result.text.contains("old"))
    }

    func testCleanSourceSkipsCriticPass() {
        let clean = FountainExportService.Options(syntax: MarkdownSyntaxOptions(), sourceTextIsClean: true)
        XCTAssertTrue(FountainExportService.convertDocument("a {++b++}\n", options: clean).text.contains("{++b++}"))
    }

    func testNoteBracketsAreSeparated() {
        let text = convert("see [[Target|alias]] and [[Plain]] and ]] end\n")
        XCTAssertTrue(text.contains("alias"))
        XCTAssertTrue(text.contains("Plain"))
        XCTAssertFalse(text.contains("[["))
        XCTAssertFalse(text.contains("]]"))
    }

    func testPrivateUseCharactersInSourceDisableComments() {
        let result = FountainExportService.convertDocument("a \u{E010}0\u{E011} {>>note<<}\n", options: options)
        XCTAssertFalse(result.text.contains("[[note]]"))
    }

    func testTableBecomesTextLines() {
        let result = FountainExportService.convertDocument("| a | b |\n|---|---|\n| 1 | 2 |\n", options: options)
        XCTAssertTrue(result.text.contains("a | b"))
        XCTAssertTrue(result.text.contains("1 | 2"))
        XCTAssertEqual(result.warnings.first { $0.kind == .table }?.count, 1)
    }

    func testCodeBlockIsIndented() {
        let result = FountainExportService.convertDocument("```\nlet a = 1\n\nlet b = 2\n```\n", options: options)
        XCTAssertTrue(result.text.contains("    let a = 1\n\n    let b = 2"))
        XCTAssertEqual(result.warnings.first { $0.kind == .codeBlock }?.count, 1)
    }

    func testEmptyDocumentGivesEmptyText() {
        XCTAssertEqual(convert(""), "")
    }

    // MARK: Проект

    func testPartsFollowTreeAndSkipHiddenBranches() {
        let nodes = [
            ManuscriptNode(kind: .group, title: "Часть 1", children: [
                ManuscriptNode(kind: .text, title: "Глава 1", path: "a.md"),
                ManuscriptNode(kind: .text, title: "Нет файла", path: "x.md")
            ]),
            ManuscriptNode(kind: .group, title: "Скрыто", include: false, children: [
                ManuscriptNode(kind: .text, title: "Тайна", path: "h.md")
            ]),
            ManuscriptNode(kind: .group, title: "Пусто"),
            ManuscriptNode(kind: .text, title: "", path: "dir/b.md")
        ]
        let built = FountainExportService.parts(from: nodes, texts: ["a.md": "A", "h.md": "H", "dir/b.md": "B"])
        XCTAssertEqual(built.parts.map(\.title), ["Часть 1", "Глава 1", "b"])
        XCTAssertEqual(built.parts.map(\.level), [0, 1, 0])
        XCTAssertEqual(built.missing, ["Нет файла"])
    }

    func testProjectOutputHasSectionsSynopsisAndTitlePage() {
        let parts = [
            FountainExportService.Part(title: "Часть 1", text: "", level: 0, synopsis: nil),
            FountainExportService.Part(title: "Глава 1", text: "# Глава 1\n\nОн вошёл.\n", level: 1, synopsis: "Кратко"),
            FountainExportService.Part(title: "Сцена 2", text: "Она ушла.\n", level: 1, synopsis: nil)
        ]
        let result = FountainExportService.convertProject(title: "Книга", titleFrontMatterFrom: nil, parts: parts, options: options)
        XCTAssertEqual(result.text, "Title: Книга\n\n# Часть 1\n\n## Глава 1\n\n= Кратко\n\nОн вошёл.\n\n## Сцена 2\n\nОна ушла.\n")
    }

    func testSceneSeparatesHeaderFromBody() {
        let part = FountainExportService.Part(title: "Сцена", text: "Он вошёл.\n", level: 0, synopsis: "Вход")
        let scene = FountainExportService.scene(part, options: options)
        XCTAssertEqual(scene.header, "# Сцена\n\n= Вход")
        XCTAssertEqual(scene.body, "Он вошёл.")
    }

    func testMergeSumsCountsAndJoinsDetails() {
        let merged = FountainExportService.merge([
            [.init(kind: .table, count: 1, detail: nil), .init(kind: .skippedFile, count: 1, detail: "a.md")],
            [.init(kind: .table, count: 2, detail: nil), .init(kind: .skippedFile, count: 1, detail: "b.md")]
        ])
        XCTAssertEqual(merged.first { $0.kind == .table }?.count, 3)
        XCTAssertEqual(merged.first { $0.kind == .skippedFile }?.detail, "a.md, b.md")
    }

    // MARK: Адаптация (чистая часть)

    func testAdaptationParse() {
        XCTAssertEqual(FountainAdaptationService.parse(#"{"fountain":"JOHN\nHi."}"#), "JOHN\nHi.")
        XCTAssertEqual(FountainAdaptationService.parse("```fountain\nJOHN\nHi.\n```"), "JOHN\nHi.")
        XCTAssertEqual(FountainAdaptationService.parse("```json\n{\"fountain\":\"x\"}\n```"), "x")
        XCTAssertEqual(FountainAdaptationService.parse("Plain text"), "Plain text")
        XCTAssertNil(FountainAdaptationService.parse(#"{"other":1}"#))
        XCTAssertNil(FountainAdaptationService.parse("  "))
    }

    func testAdaptationValidateRejectsFenceAndTitlePage() {
        XCTAssertFalse(FountainAdaptationService.validate("```\nx\n```").isValid)
        XCTAssertFalse(FountainAdaptationService.validate("Title: X\n\nHello.").isValid)
        XCTAssertTrue(FountainAdaptationService.validate("JOHN\nHello.").isValid)
    }

    func testAdaptationInputAndRetry() {
        XCTAssertTrue(FountainAdaptationService.input(sceneFountain: "Text", languageCode: "ru").hasPrefix("Language: ru"))
        XCTAssertEqual(FountainAdaptationService.input(sceneFountain: "Text", languageCode: nil), "Text")
        let retry = FountainAdaptationService.retryInput(base: "BASE", issues: [FountainIssue(kind: .codeFence, line: 3)])
        XCTAssertTrue(retry.hasPrefix("BASE"))
        XCTAssertTrue(retry.contains("line 3"))
    }

    func testAdaptationAssemble() {
        let text = FountainAdaptationService.assemble(titlePage: "Title: X", sections: [("# A", "Body A"), ("# B", "")])
        XCTAssertEqual(text, "Title: X\n\n# A\n\nBody A\n\n# B\n")
        XCTAssertEqual(FountainAdaptationService.assemble(titlePage: "", sections: []), "")
    }

    // MARK: Локализация

    func testFountainStringsHaveMatchingPlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func load(_ language: String) throws -> [String: String] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        }
        let zh = try load("zh-Hans"), en = try load("en"), ru = try load("ru")
        let keys = ["Fountain 剧本…", "将项目导出为 Fountain 剧本…", "导出为 Fountain 剧本", "开始改编", "第 %d 个场景",
                    "正在改编第 %d 个场景，共 %d 个", "改编在第 %d 个场景中止：%@", "已改编 %d 个场景", "%d 个表格已转为文字行",
                    "第 %d 个场景的 AI 结果未通过检查，已改用结构转换。", "没有可导出的内容"]
        func placeholders(_ text: String) -> [String] {
            text.components(separatedBy: "%").dropFirst().compactMap { $0.first.map(String.init) }
        }
        for key in keys {
            let reference = placeholders(key)
            for table in [zh, en, ru] {
                let value = try XCTUnwrap(table[key], key)
                XCTAssertEqual(placeholders(value), reference, key)
            }
        }
    }
}

@MainActor
final class FountainExportControllerTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var inputs: [String] = []
        var responses: [String] = []
        var failure: Error?
        var pending: [CheckedContinuation<String, Error>] = []
        var hold = false
        var finished: [(text: String, warnings: [FountainExportService.Warning], save: Bool)] = []
    }

    private func sources(_ text: String = "Он вошёл.\n") -> FountainSources {
        FountainSources(title: "", parts: [FountainExportService.Part(title: "", text: text, level: 0, synopsis: nil)],
                        frontMatterText: nil, syntax: MarkdownSyntaxOptions())
    }

    private func makeController(_ box: Box, text: String = "Он вошёл.\n",
                                availability: AIAvailability = .available) -> FountainExportController {
        let source = sources(text)
        return FountainExportController(
            scope: .document,
            aiAvailability: { availability },
            sources: { source },
            generate: { input, _ in
                box.inputs.append(input)
                if let failure = box.failure { throw failure }
                if box.hold { return try await withCheckedThrowingContinuation { box.pending.append($0) } }
                return box.responses.isEmpty ? #"{"fountain":"Он вошёл."}"# : box.responses.removeFirst()
            },
            onFinished: { text, warnings, save in box.finished.append((text, warnings, save)) }
        )
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Условие не выполнилось", file: file, line: line)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testStructureModeFinishesWithoutAI() async {
        let box = Box()
        let controller = makeController(box)
        controller.start(saveToFile: true)
        await wait { !box.finished.isEmpty }
        XCTAssertEqual(box.finished.first?.text, "Он вошёл.\n")
        XCTAssertEqual(box.finished.first?.save, true)
        XCTAssertTrue(box.inputs.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testEmptySourceReportsNothingToExport() async {
        let box = Box()
        let controller = makeController(box, text: "")
        controller.start(saveToFile: false)
        await wait { controller.status != nil }
        XCTAssertTrue(box.finished.isEmpty)
        XCTAssertEqual(controller.status?.kind, .error)
    }

    func testAdaptationSuccess() async {
        let box = Box()
        let controller = makeController(box)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait { !box.finished.isEmpty }
        XCTAssertEqual(box.inputs.count, 1)
        XCTAssertEqual(box.finished.first?.text, "Он вошёл.\n")
        XCTAssertEqual(box.finished.first?.save, false)
        XCTAssertTrue(box.finished.first?.warnings.isEmpty ?? false)
    }

    func testAdaptationRetriesOnceAfterRejection() async {
        let box = Box()
        box.responses = [#"{"fountain":"```\nx\n```"}"#, #"{"fountain":"Он вошёл."}"#]
        let controller = makeController(box)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait { !box.finished.isEmpty }
        XCTAssertEqual(box.inputs.count, 2)
        XCTAssertTrue(box.inputs[1].contains("rejected"))
        XCTAssertTrue(box.finished.first?.warnings.isEmpty ?? false)
    }

    func testAdaptationFallsBackToStructureAfterTwoRejections() async {
        let box = Box()
        box.responses = [#"{"fountain":"```\nx\n```"}"#, #"{"fountain":"```\ny\n```"}"#]
        let controller = makeController(box)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait { !box.finished.isEmpty }
        XCTAssertEqual(box.inputs.count, 2)
        XCTAssertEqual(box.finished.first?.text, "Он вошёл.\n")
        let fallback = box.finished.first?.warnings.first { $0.kind == .aiFallback }
        XCTAssertEqual(fallback?.detail, "1")
    }

    func testNetworkErrorStopsWithoutResult() async {
        let box = Box()
        box.failure = URLError(.notConnectedToInternet)
        let controller = makeController(box)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait { controller.status != nil }
        XCTAssertTrue(box.finished.isEmpty)
        XCTAssertEqual(box.inputs.count, 1)
        XCTAssertEqual(controller.status?.kind, .error)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCancelIgnoresLateResponse() async {
        let box = Box()
        box.hold = true
        let controller = makeController(box)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait { !box.pending.isEmpty }
        controller.cancel()
        box.pending.forEach { $0.resume(returning: #"{"fountain":"Он вошёл."}"#) }
        await settle()
        XCTAssertTrue(box.finished.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testOversizeSceneWaitsForConfirmation() async {
        let box = Box()
        let text = String(repeating: "слово ", count: 12_000) + "\n"
        let controller = makeController(box, text: text)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait {
            if case .confirmingOversize = controller.phase { return true }
            return false
        }
        XCTAssertTrue(box.inputs.isEmpty)
        controller.confirmOversize()
        await wait { !box.finished.isEmpty }
        XCTAssertEqual(box.inputs.count, 1)
    }

    func testCancelDuringOversizeSendsNothing() async {
        let box = Box()
        let controller = makeController(box, text: String(repeating: "слово ", count: 12_000) + "\n")
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await wait {
            if case .confirmingOversize = controller.phase { return true }
            return false
        }
        controller.cancel()
        await settle()
        XCTAssertTrue(box.inputs.isEmpty)
        XCTAssertTrue(box.finished.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAdaptationRequiresAvailableAI() async {
        let box = Box()
        let controller = makeController(box, availability: .noModel)
        controller.mode = .adaptation
        controller.start(saveToFile: false)
        await settle()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(box.inputs.isEmpty)
        XCTAssertTrue(box.finished.isEmpty)
    }
}

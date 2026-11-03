import XCTest
import Yams
@testable import LacEditor

final class VaultFrontmatterEditorTests: XCTestCase {
    /// Применяет заплатку к тексту и возвращает результат целиком: сравнивается весь текст, а не его часть.
    private func apply(_ edit: VaultFrontmatterEdit, to text: String) throws -> String {
        guard let patch = try VaultFrontmatterEditor.patch(for: edit, in: text) else { return text }
        return (text as NSString).replacingCharacters(in: patch.range, with: patch.replacement)
    }

    private func fields(_ text: String) -> [VaultFrontmatterField] {
        guard case let .parsed(front) = VaultFrontmatterEditor.parse(text) else { return [] }
        return front.fields
    }

    private func set(_ key: String, _ value: String) -> VaultFrontmatterEdit { .setScalar(key: key, value: value) }

    // MARK: 1. Значение в строке: меняется только оно

    func testSetScalarKeepsQuotesCommentAndSpacing() throws {
        XCTAssertEqual(try apply(set("type", "idea"), to: "---\ntype: note\nstatus: a\n---\nТекст\n"), "---\ntype: idea\nstatus: a\n---\nТекст\n")
        XCTAssertEqual(try apply(set("type", "idea"), to: "---\ntype: \"note\"\n---\n"), "---\ntype: \"idea\"\n---\n")
        XCTAssertEqual(try apply(set("type", "idea"), to: "---\ntype: 'note'\n---\n"), "---\ntype: 'idea'\n---\n")
        XCTAssertEqual(try apply(set("type", "idea"), to: "---\ntype: note # комментарий\n---\n"), "---\ntype: idea # комментарий\n---\n")
        XCTAssertEqual(try apply(set("type", "idea"), to: "---\ntype:   note\n---\n"), "---\ntype:   idea\n---\n")
        XCTAssertEqual(try apply(set("type", "idea"), to: "---\ntype: \"note\"  # c\n---\n"), "---\ntype: \"idea\"  # c\n---\n")
    }

    func testSetScalarOnEmptyValueKeepsComment() throws {
        XCTAssertEqual(try apply(set("status", "active"), to: "---\nstatus:\n---\n"), "---\nstatus: active\n---\n")
        XCTAssertEqual(try apply(set("status", "active"), to: "---\nstatus:  # позже\n---\n"), "---\nstatus: active  # позже\n---\n")
    }

    // MARK: 2. Значения, которым нужны кавычки

    func testValuesNeedingQuotes() throws {
        let base = "---\ndescription: old\n---\n"
        XCTAssertEqual(try apply(set("description", "a: b"), to: base), "---\ndescription: \"a: b\"\n---\n")
        XCTAssertEqual(try apply(set("description", "a # b"), to: base), "---\ndescription: \"a # b\"\n---\n")
        XCTAssertEqual(try apply(set("description", "[x]"), to: base), "---\ndescription: \"[x]\"\n---\n")
        XCTAssertEqual(try apply(set("description", "true"), to: base), "---\ndescription: \"true\"\n---\n")
        XCTAssertEqual(try apply(set("description", "123"), to: base), "---\ndescription: \"123\"\n---\n")
        let tricky = try apply(set("description", "say \"hi\" \\ x"), to: base)
        XCTAssertEqual(fields(tricky).first?.value, .scalar("say \"hi\" \\ x"))
        let result = try apply(set("description", "a: b"), to: base)
        XCTAssertEqual(fields(result).first?.value, .scalar("a: b"))
    }

    func testSingleQuotedStaysSingleAndDoublesApostrophe() throws {
        XCTAssertEqual(try apply(set("description", "it's"), to: "---\ndescription: 'x'\n---\n"), "---\ndescription: 'it''s'\n---\n")
    }

    func testNumberStaysPlainWhenOldWasNumber() throws {
        XCTAssertEqual(try apply(set("rank", "7"), to: "---\nrank: 5\n---\n"), "---\nrank: 7\n---\n")
    }

    func testEmptyValueRemovesField() throws {
        XCTAssertEqual(try apply(set("status", ""), to: "---\ntype: a\nstatus: b\ntier: c\n---\n"), "---\ntype: a\ntier: c\n---\n")
        XCTAssertNil(try VaultFrontmatterEditor.patch(for: set("status", ""), in: "---\ntype: a\n---\n"))
    }

    // MARK: 3. Окончания строк

    func testCRLFKeepsEndingsForNewLines() throws {
        let text = "---\r\ntype: a\r\n---\r\nТекст\r\n"
        XCTAssertEqual(try apply(set("status", "x"), to: text), "---\r\ntype: a\r\nstatus: x\r\n---\r\nТекст\r\n")
        XCTAssertEqual(try apply(set("type", "b"), to: text), "---\r\ntype: b\r\n---\r\nТекст\r\n")
    }

    func testMixedEndingsStayAsTheyWere() throws {
        let text = "---\ntype: a\r\nstatus: b\n---\n"
        XCTAssertEqual(try apply(set("status", "c"), to: text), "---\ntype: a\r\nstatus: c\n---\n")
    }

    // MARK: 4. BOM

    func testBOMIsKeptAndLinesAreCorrect() throws {
        let text = "\u{FEFF}---\ntype: a\nstatus: b\n---\nТекст\n"
        XCTAssertEqual(fields(text).map(\.line), [2, 3])
        XCTAssertEqual(try apply(set("status", "c"), to: text), "\u{FEFF}---\ntype: a\nstatus: c\n---\nТекст\n")
        guard case let .parsed(front) = VaultFrontmatterEditor.parse(text) else { return XCTFail() }
        XCTAssertEqual(front.range.location, 1)
    }

    // MARK: 5-6. Комментарии, порядок

    func testCommentsAndBlankLinesStay() throws {
        let text = "---\n# про тип\ntype: a\n\n# про статус\nstatus: b\n---\n"
        XCTAssertEqual(try apply(set("type", ""), to: text), "---\n# про тип\n\n# про статус\nstatus: b\n---\n")
        XCTAssertEqual(try apply(set("status", "c"), to: text), "---\n# про тип\ntype: a\n\n# про статус\nstatus: c\n---\n")
    }

    func testAddedFieldGoesToTheEndAfterContent() throws {
        let text = "---\ntype: a\ntags: [x]\n# хвост\n---\n"
        XCTAssertEqual(try apply(set("status", "s"), to: text), "---\ntype: a\ntags: [x]\nstatus: s\n# хвост\n---\n")
        XCTAssertEqual(try apply(set("status", "s"), to: "---\n---\n"), "---\nstatus: s\n---\n")
    }

    func testTextAfterHeaderAndSpacingOutsideEditAreUntouched() throws {
        let text = "---\nz:   1\na: 'q'\n---\n\n# Заголовок\n---\nне шапка\n"
        XCTAssertEqual(try apply(set("a", "w"), to: text), "---\nz:   1\na: 'w'\n---\n\n# Заголовок\n---\nне шапка\n")
    }

    // MARK: 7. Теги

    func testInlineTags() throws {
        let text = "---\ntags: [a, b]\n---\n"
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "c"), to: text), "---\ntags: [a, b, c]\n---\n")
        XCTAssertEqual(try apply(.removeListItem(key: "tags", item: "a"), to: text), "---\ntags: [b]\n---\n")
        XCTAssertEqual(try apply(.removeListItem(key: "tags", item: "b"), to: text), "---\ntags: [a]\n---\n")
        XCTAssertEqual(try apply(.removeListItem(key: "tags", item: "b"), to: "---\ntags: [a, \"b\", 'c']\n---\n"), "---\ntags: [a, 'c']\n---\n")
        XCTAssertEqual(try apply(.removeListItem(key: "tags", item: "a"), to: "---\ntags: [a]\n---\n"), "---\ntags: []\n---\n")
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "x"), to: "---\ntags: []\n---\n"), "---\ntags: [x]\n---\n")
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "x"), to: "---\ntags: [ ]\n---\n"), "---\ntags: [x]\n---\n")
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "x"), to: "---\ntags: [a]   # c\n---\n"), "---\ntags: [a, x]   # c\n---\n")
    }

    func testBlockTags() throws {
        let text = "---\ntags:\n  - a\n  - \"b\"\ntype: t\n---\n"
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "c"), to: text), "---\ntags:\n  - a\n  - \"b\"\n  - \"c\"\ntype: t\n---\n")
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "c"), to: "---\ntags:\n- a\n---\n"), "---\ntags:\n- a\n- c\n---\n")
        XCTAssertEqual(try apply(.removeListItem(key: "tags", item: "a"), to: text), "---\ntags:\n  - \"b\"\ntype: t\n---\n")
        XCTAssertEqual(try apply(.removeListItem(key: "tags", item: "a"), to: "---\ntags:\n  - a\n---\n"), "---\ntags: []\n---\n")
    }

    func testEmptyTagsFieldBecomesBlock() throws {
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "x"), to: "---\ntags:\ntype: t\n---\n"), "---\ntags:\n  - x\ntype: t\n---\n")
    }

    func testMissingTagsFieldIsCreatedAndDuplicatesAreRejected() throws {
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "#idea"), to: "---\ntype: a\n---\n"), "---\ntype: a\ntags: [idea]\n---\n")
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: .addListItem(key: "tags", item: "A"), in: "---\ntags: [a]\n---\n")) {
            XCTAssertEqual($0 as? VaultFrontmatterEditError, .duplicate)
        }
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: .removeListItem(key: "tags", item: "z"), in: "---\ntags: [a]\n---\n")) {
            XCTAssertEqual($0 as? VaultFrontmatterEditError, .notFound)
        }
    }

    func testTagNames() {
        XCTAssertEqual(VaultFrontmatterEditor.normalizedTag("#idea"), "idea")
        XCTAssertEqual(VaultFrontmatterEditor.normalizedTag("  проект/x "), "проект/x")
        for bad in ["", " ", "#", "a b", "a,b", "123", "a[b]", "a\"b", "##a", "a#b"] {
            XCTAssertNil(VaultFrontmatterEditor.normalizedTag(bad), bad)
        }
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: .addListItem(key: "tags", item: "a b"), in: "---\ntags: []\n---\n")) {
            XCTAssertEqual($0 as? VaultFrontmatterEditError, .invalidValue)
        }
    }

    // MARK: 8. Только чтение

    func testComplexFieldsAreReadOnly() throws {
        let text = "---\ndescription: |\n  строка 1\n  строка 2\ntype: a\nlist: [\n  x,\n  y]\nmap:\n  k: v\nanchor: &a v\nindustry: [FMCG|Electronics|…]\ntags: идея\n---\n"
        let result = fields(text)
        XCTAssertEqual(result.map(\.key), ["description", "type", "list", "map", "anchor", "industry", "tags"])
        for key in ["description", "list", "map", "anchor", "industry", "tags"] {
            guard case .readOnly = result.first(where: { $0.key == key })?.value else { return XCTFail(key) }
        }
        XCTAssertEqual(result[1].value, .scalar("a"))
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: set("description", "x"), in: text)) {
            XCTAssertEqual($0 as? VaultFrontmatterEditError, .readOnlyField("description"))
        }
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: .addListItem(key: "tags", item: "x"), in: text))
    }

    func testDuplicateKeysAreYAMLError() throws {
        // Yams отвергает повторный ключ: форма показывает ошибку шапки, правка отклоняется.
        let text = "---\ntype: a\ntype: b\n---\n"
        guard case .failed = VaultFrontmatterEditor.parse(text) else { return XCTFail() }
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: set("type", "c"), in: text))
    }

    // MARK: 9. Нет шапки

    func testNoHeader() throws {
        XCTAssertEqual(VaultFrontmatterEditor.parse("Просто текст\n"), .none)
        XCTAssertEqual(VaultFrontmatterEditor.parse(""), .none)
        XCTAssertEqual(VaultFrontmatterEditor.parse("---\ntype: a\nбез закрытия\n"), .none)
        XCTAssertEqual(try apply(set("type", "a"), to: "Текст\n"), "---\ntype: a\n---\nТекст\n")
        XCTAssertEqual(try apply(set("type", "a"), to: "\u{FEFF}Текст\r\nвторая\r\n"), "\u{FEFF}---\r\ntype: a\r\n---\r\nТекст\r\nвторая\r\n")
        XCTAssertEqual(try apply(set("type", "a"), to: ""), "---\ntype: a\n---\n")
        XCTAssertEqual(try apply(.addListItem(key: "tags", item: "x"), to: "Текст"), "---\ntags: [x]\n---\nТекст")
        XCTAssertNil(try VaultFrontmatterEditor.patch(for: set("type", ""), in: "Текст"))
    }

    // MARK: 10. Ошибки YAML

    func testYAMLErrorsReportLineInFile() throws {
        guard case let .failed(line, _) = VaultFrontmatterEditor.parse("---\ntype: a\n: oops\n---\n") else { return XCTFail("пустой ключ") }
        XCTAssertEqual(line, 3)
        guard case let .failed(tabLine, _) = VaultFrontmatterEditor.parse("---\ntype: a\ntags:\n\t- x\n---\n") else { return XCTFail("табуляция") }
        XCTAssertEqual(tabLine, 4)
        guard case let .failed(quoteLine, _) = VaultFrontmatterEditor.parse("---\ntype: \"a\nstatus: b\n---\n") else { return XCTFail("кавычка") }
        XCTAssertGreaterThanOrEqual(quoteLine, 2)
        guard case let .failed(bomLine, _) = VaultFrontmatterEditor.parse("\u{FEFF}---\r\ntype: a\r\n: oops\r\n---\r\n") else { return XCTFail("BOM") }
        XCTAssertEqual(bomLine, 3)
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: set("type", "b"), in: "---\ntype: a\n: oops\n---\n")) {
            XCTAssertEqual($0 as? VaultFrontmatterEditError, .parseFailed(line: 3))
        }
    }

    // MARK: 11. Даты

    func testDates() throws {
        XCTAssertEqual(VaultFrontmatterEditor.dateComponents(from: "2026-08-08"), DateComponents(year: 2026, month: 8, day: 8))
        XCTAssertNil(VaultFrontmatterEditor.dateComponents(from: "2026-13-40"))
        XCTAssertNil(VaultFrontmatterEditor.dateComponents(from: "2026-02-30"))
        XCTAssertNil(VaultFrontmatterEditor.dateComponents(from: "2026-08-08T10:00"))
        XCTAssertNil(VaultFrontmatterEditor.dateComponents(from: "вчера"))
        XCTAssertEqual(VaultFrontmatterEditor.dateString(from: DateComponents(year: 2026, month: 8, day: 8)), "2026-08-08")
        XCTAssertEqual(try apply(set("created", "2026-09-01"), to: "---\ncreated: \"2026-08-08\"\n---\n"), "---\ncreated: \"2026-09-01\"\n---\n")
        XCTAssertEqual(try apply(set("created", "2026-09-01"), to: "---\ncreated: 2026-08-08\n---\n"), "---\ncreated: 2026-09-01\n---\n")
    }

    // MARK: 12. Системные поля и образцы сервера

    func testServerHeaderSample() throws {
        let text = """
        ---
        type: thought-card
        description: Идея про синхронизацию
        last_accessed: 2026-11-03
        relevance: 0.82
        tier: warm
        access_count: 4
        industry: [FMCG|Electronics|…]
        tags: [samoregulyatsiya, stress]
        ---
        Тело
        """
        let result = fields(text)
        XCTAssertEqual(result.map(\.key), ["type", "description", "last_accessed", "relevance", "tier", "access_count", "industry", "tags"])
        XCTAssertEqual(result.filter(\.isSystem).map(\.key), ["last_accessed", "relevance", "tier", "access_count"])
        XCTAssertEqual(result.last?.value, .list(["samoregulyatsiya", "stress"]))
        guard case .readOnly = result[6].value else { return XCTFail("industry") }
        XCTAssertEqual(result[0].line, 2)
    }

    // MARK: 13. Идемпотентность

    func testSameValueGivesNoPatchAndPatchRoundTrips() throws {
        let text = "---\ntype: a\n---\n"
        XCTAssertNil(try VaultFrontmatterEditor.patch(for: set("type", "a"), in: text))
        XCTAssertNil(try VaultFrontmatterEditor.patch(for: set("type", "  a "), in: text))
        let changed = try apply(set("type", "b"), to: text)
        XCTAssertEqual(fields(changed).first?.value, .scalar("b"))
    }

    func testPatchRangeIsMinimal() throws {
        let text = "---\ntype: note\nstatus: b\n---\n"
        let patch = try XCTUnwrap(VaultFrontmatterEditor.patch(for: set("type", "idea"), in: text))
        XCTAssertEqual((text as NSString).substring(with: patch.range), "note")
        XCTAssertEqual(patch.replacement, "idea")
    }

    func testControlCharactersAreRejected() {
        XCTAssertThrowsError(try VaultFrontmatterEditor.patch(for: set("type", "a\nb"), in: "---\ntype: a\n---\n")) {
            XCTAssertEqual($0 as? VaultFrontmatterEditError, .invalidValue)
        }
    }

    // MARK: 14. Юникод

    func testUnicodeRanges() throws {
        let text = "---\ntype: 😀 привет\nstatus: ёж\n---\n日本語\n"
        XCTAssertEqual(try apply(set("status", "😀"), to: text), "---\ntype: 😀 привет\nstatus: 😀\n---\n日本語\n")
        XCTAssertEqual(try apply(set("type", "😀 мир"), to: text), "---\ntype: 😀 мир\nstatus: ёж\n---\n日本語\n")
        XCTAssertEqual(try apply(set("описание", "текст"), to: text), "---\ntype: 😀 привет\nstatus: ёж\nописание: текст\n---\n日本語\n")
    }
}

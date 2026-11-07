import XCTest
@testable import LacEditor

/// Эталоны этапа 0 (U0.1): точный HTML `renderPage` для семи наборов настроек на корпусе spec и документов.
/// Запись: `LAC_RECORD_BASELINE=1`; без переменной файлы сравниваются побайтно. Файлы: `Fixtures/RenderBaseline`.
final class MarkdownRenderBaselineTests: XCTestCase {
    private var suite: String?

    override func setUp() {
        super.setUp()
        useEnglish()
    }

    override func tearDown() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        L10n.configure()
        super.tearDown()
    }

    /// Текст интерфейса попадает в HTML (aria-label таблиц, выноски), поэтому язык фиксируется.
    private func useEnglish() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let name = "MarkdownRenderBaselineTests-\(UUID().uuidString)"
        suite = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.set("en", forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
    }

    private func records(_ set: BaselineSet, _ items: [BaselineItem]) -> String {
        useEnglish()
        return items.map { set.record($0) }.joined(separator: "")
    }

    private func documentRecords(_ set: BaselineSet) throws -> String {
        let documents = try BaselineCorpus.documents()
        var content = records(set, documents)
        if set.hasDarkEmbeds, let embeds = documents.first(where: { $0.id == "doc/Corpus/embeds" }) {
            content += set.record(embeds, dark: true)
        }
        if set == .preview { content += records(set, try BaselineCorpus.crlfDocuments()) }
        return content
    }

    private func check(_ set: BaselineSet) throws {
        if set.includesSpec {
            BaselineStore.check(records(set, try BaselineCorpus.spec()), directory: "RenderBaseline", file: "\(set.name).spec.txt")
            BaselineStore.check(records(set, try BaselineCorpus.extensions()), directory: "RenderBaseline", file: "\(set.name).ext.txt")
        }
        let documents = try documentRecords(set)
        BaselineStore.check(documents, directory: "RenderBaseline", file: "\(set.name).docs.txt")
        // В эталон не должны попасть пути машины и случайные части маркеров.
        XCTAssertFalse(documents.contains(BaselinePaths.projectRoot.path), "путь проекта в эталоне \(set.name)")
        XCTAssertNil(documents.range(of: "LAC[A-Z]+[0-9A-F]{32}", options: .regularExpression), "необработанный маркер в эталоне \(set.name)")
    }

    func testPreviewBaseline() throws { try check(.preview) }
    func testPreviewVaultBaseline() throws { try check(.previewVault) }
    func testPreviewNoBreaksBaseline() throws { try check(.previewNoBreaks) }
    func testExportPDFBaseline() throws { try check(.exportPDF) }
    func testExportHTMLBaseline() throws { try check(.exportHTML) }
    func testExportNoBreaksBaseline() throws { try check(.exportNoBreaks) }
    func testWriterBaseline() throws { try check(.writer) }

    /// Два построения одного набора совпадают: UUID и порядок словарей не просачиваются в запись.
    func testRecordsAreDeterministic() throws {
        for set in [BaselineSet.preview, .previewVault, .exportHTML, .writer] {
            let first = try documentRecords(set)
            let second = try documentRecords(set)
            XCTAssertTrue(first.utf8.elementsEqual(second.utf8), "набор \(set.name) недетерминирован: \(BaselineStore.difference(first, second))")
        }
    }

    /// Корпус даёт непустой вклад: в эталонах видны теги и поля нужных возможностей.
    func testCorpusExercisesFeatures() throws {
        let expectations: [(set: BaselineSet, id: String, needle: String)] = [
            (.previewVault, "doc/Corpus/critic", "<ins"),
            (.previewVault, "doc/Corpus/callouts", "callout"),
            (.previewVault, "doc/Corpus/embeds", "[dark]"),
            (.preview, "doc/Corpus/math", "[formula]"),
            (.preview, "doc/Corpus/diagrams", "language-mermaid"),
            (.preview, "doc/Corpus/diagrams", "[diagram] kind=flow"),
            (.preview, "doc/Corpus/diagrams", "[diagram] kind=sequence"),
            (.preview, "doc/Corpus/images-local-remote", "[remote]"),
            (.exportHTML, "doc/Corpus/media-av", "<video"),
            (.exportHTML, "doc/Corpus/media-html", "[raw]"),
            (.preview, "doc/Corpus/media-html", "image/svg+xml"),
            (.preview, "doc/Corpus/headings", "[headingIDs]"),
        ]
        let documents = try BaselineCorpus.documents()
        for expectation in expectations {
            let item = try XCTUnwrap(documents.first { $0.id == expectation.id }, expectation.id)
            let record = expectation.set.record(item, dark: expectation.needle == "[dark]")
            XCTAssertTrue(record.contains(expectation.needle), "\(expectation.id) в наборе \(expectation.set.name) не содержит \(expectation.needle)")
        }
    }
}

/// Эталоны этапа 0 (U0.2): все хранимые поля `MarkdownPresentation` для четырёх наборов разбора.
final class MarkdownPresentationBaselineTests: XCTestCase {
    private func content(_ set: PresentationBaselineSet, _ items: [BaselineItem], file: String) -> String {
        let dump = BaselineDump()
        let result = items.map { set.record($0, dump: dump) }.joined()
        XCTAssertTrue(dump.problems.isEmpty, "\(file): " + Set(dump.problems).sorted().joined(separator: "; "))
        return result
    }

    private func check(_ set: PresentationBaselineSet) throws {
        let directory = "PresentationBaseline"
        if set.includesSpec {
            BaselineStore.check(content(set, try BaselineCorpus.spec(), file: "\(set.name).spec"), directory: directory, file: "\(set.name).spec.txt")
            BaselineStore.check(content(set, try BaselineCorpus.extensions(), file: "\(set.name).ext"), directory: directory, file: "\(set.name).ext.txt")
        }
        var documents = try BaselineCorpus.documents()
        if set == .editor { documents += try BaselineCorpus.crlfDocuments() }
        let text = content(set, documents, file: "\(set.name).docs")
        BaselineStore.check(text, directory: directory, file: "\(set.name).docs.txt")
        for forbidden in ["baseShift", "changedIndex", "followingShift", BaselinePaths.projectRoot.path] {
            XCTAssertFalse(text.contains(forbidden), "в эталоне \(set.name) лишнее: \(forbidden)")
        }
    }

    func testEditorBaseline() throws { try check(.editor) }
    func testEditorLooseBaseline() throws { try check(.editorLoose) }
    func testEditorNumberedBaseline() throws { try check(.editorNumbered) }
    func testEditorMinimalBaseline() throws { try check(.editorMinimal) }

    /// Новое поле `MarkdownPresentation` нужно осознанно отнести к «пишем» или «исключаем»; удалять поля из списков можно только в U5.2.
    func testPresentationFieldListIsComplete() {
        let labels = Mirror(reflecting: MarkdownPresentation(spans: [])).children.compactMap(\.label)
        let known = Set(PresentationBaselineSet.writtenFields + PresentationBaselineSet.excludedFields)
        XCTAssertEqual(Set(labels).subtracting(known).sorted(), [], "поле MarkdownPresentation не отнесено ни к «пишем», ни к «исключаем»")
        XCTAssertEqual(known.subtracting(labels).sorted(), [], "в списке есть поле, которого нет в MarkdownPresentation")
    }

    func testPresentationRecordsAreDeterministic() throws {
        let documents = try BaselineCorpus.documents()
        let first = content(.editor, documents, file: "a"), second = content(.editor, documents, file: "b")
        XCTAssertTrue(first.utf8.elementsEqual(second.utf8), BaselineStore.difference(first, second))
    }
}

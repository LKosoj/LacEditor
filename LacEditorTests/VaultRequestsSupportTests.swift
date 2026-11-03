import Foundation
import XCTest
@testable import LacEditor

final class VaultRequestsSupportTests: XCTestCase {
    // MARK: Текст запроса

    func testTextLimitsCountScalars() throws {
        XCTAssertEqual(try VaultRequestText.validated(String(repeating: "я", count: 100_000)).unicodeScalars.count, 100_000)
        XCTAssertThrowsError(try VaultRequestText.validated(String(repeating: "я", count: 100_001))) {
            XCTAssertEqual($0 as? VaultRequestError, .tooLong)
        }
        // составной знак: один Character, два скаляра
        let composed = String(repeating: "e\u{301}", count: 50_001)
        XCTAssertThrowsError(try VaultRequestText.validated(composed)) { XCTAssertEqual($0 as? VaultRequestError, .tooLong) }
        XCTAssertThrowsError(try VaultRequestText.validated(" \n")) { XCTAssertEqual($0 as? VaultRequestError, .empty) }
    }

    // MARK: Признак записи

    func testCaptureAcknowledgement() {
        XCTAssertTrue(VaultReply.isCaptureAcknowledgement("✓ Сохранено в daily/2026-11-03.md"))
        XCTAssertTrue(VaultReply.isCaptureAcknowledgement("  \n✓ Saved"))
        XCTAssertFalse(VaultReply.isCaptureAcknowledgement("Сохранено"))
        XCTAssertFalse(VaultReply.isCaptureAcknowledgement(""))
        XCTAssertFalse(VaultReply.isCaptureAcknowledgement("Вот ответ на вопрос ✓ в конце"))
    }

    // MARK: Ссылки

    private func paths(_ text: String, known: (String) -> Bool = { _ in true }) -> [String] {
        VaultAskLinks.matches(in: text, isKnownPath: known).map(\.path)
    }

    func testPlainBacktickAndWikiPaths() {
        XCTAssertEqual(paths("см. daily/2026-11-03.md и `projects/x/status.md`."), ["daily/2026-11-03.md", "projects/x/status.md"])
        XCTAssertEqual(paths("[[projects/x]] и [[notes/a.md|псевдоним]] и [[notes/b#раздел]]"),
                       ["projects/x.md", "notes/a.md", "notes/b.md"])
        XCTAssertEqual(paths("[[Проекты/Мой план]]"), ["Проекты/Мой план.md"])
    }

    func testTrailingPunctuationAndMarkup() {
        XCTAssertEqual(paths("(смотри daily/a.md), потом daily/b.md; daily/c.md."), ["daily/a.md", "daily/b.md", "daily/c.md"])
        XCTAssertEqual(paths("**daily/a.md**"), ["daily/a.md"])
        XCTAssertEqual(paths("_a/b_c.md"), ["_a/b_c.md"])
    }

    func testUnsafeAndSlashlessPathsAreIgnored() {
        XCTAssertEqual(paths("../secret.md /abs/path.md a.md .hidden/x.md a//b.md"), [])
        XCTAssertEqual(paths("[[a]] [[../x/y]]"), [])
    }

    func testKnownPathFilter() {
        XCTAssertEqual(paths("daily/a.md daily/b.md", known: { $0 == "daily/b.md" }), ["daily/b.md"])
        XCTAssertEqual(paths("[[daily/a]]", known: { _ in false }), [])
    }

    func testWikiTargetIsNotMatchedTwice() {
        XCTAssertEqual(paths("[[daily/a.md]]"), ["daily/a.md"])
    }

    func testAttributedLinksRoundTrip() throws {
        for path in ["daily/a.md", "Заметки/мой план 100%.md", "a b/c+d&e.md"] {
            let url = try XCTUnwrap(VaultAskLinks.link(forPath: path))
            XCTAssertEqual(url.scheme, "laceditor-vault")
            XCTAssertEqual(VaultAskLinks.path(fromLink: url), path)
        }
        XCTAssertNil(VaultAskLinks.path(fromLink: URL(string: "https://example.com/?path=daily/a.md")!))
        XCTAssertNil(VaultAskLinks.path(fromLink: URL(string: "laceditor-vault://note?path=../x/y.md")!))

        let text = VaultAskLinks.attributed("Нашёл заметку daily/2026-11-03.md и [[projects/x]].", isKnownPath: { _ in true })
        let links = text.runs.compactMap { $0.link }.compactMap(VaultAskLinks.path(fromLink:))
        XCTAssertEqual(links, ["daily/2026-11-03.md", "projects/x.md"])
    }

    /// Разбор Markdown есть только на macOS: на Linux (стенд) тест не проходит, проверяется на Mac.
    func testAttributedParsesMarkdownBeforeFindingPaths() {
        let text = VaultAskLinks.attributed("Нашёл **заметку** daily/2026-11-03.md.", isKnownPath: { _ in true })
        XCTAssertEqual(String(text.characters), "Нашёл заметку daily/2026-11-03.md.")
        XCTAssertEqual(text.runs.compactMap { $0.link }.compactMap(VaultAskLinks.path(fromLink:)), ["daily/2026-11-03.md"])
    }

    func testAttributedPlainWhenNoPaths() {
        let text = VaultAskLinks.attributed("Просто ответ.\nВторая строка.", isKnownPath: { _ in true })
        XCTAssertEqual(String(text.characters), "Просто ответ.\nВторая строка.")
        XCTAssertTrue(text.runs.allSatisfy { $0.link == nil })
    }

    // MARK: Сообщения

    func testFailureMessagesAreNotEmpty() {
        let failures: [VaultRequestFailure] = [.interrupted, .jobLost, .serverError(nil, canRetry: true), .serverError("boom", canRetry: false),
                                               .rejected(.tooLarge), .needsConnectionFix(.unauthorized)]
        for failure in failures { XCTAssertFalse(failure.userMessage.isEmpty) }
        XCTAssertTrue(VaultRequestFailure.serverError("boom", canRetry: false).userMessage.contains("boom"))
        XCTAssertTrue(VaultRequestFailure.serverError(nil, canRetry: true).canRetry)
        XCTAssertFalse(VaultRequestFailure.jobLost.canRetry)
    }

    // MARK: Файлы результата

    func testArtifactTextDecision() {
        XCTAssertTrue(VaultArtifactText.isOpenableAsText(name: "report.MD", mimeType: nil))
        XCTAssertTrue(VaultArtifactText.isOpenableAsText(name: "data", mimeType: "text/plain"))
        XCTAssertTrue(VaultArtifactText.isOpenableAsText(name: "data", mimeType: "application/json"))
        XCTAssertFalse(VaultArtifactText.isOpenableAsText(name: "photo.png", mimeType: "image/png"))
        XCTAssertEqual(VaultArtifactText.decode(Data("текст".utf8), name: "a.txt", mimeType: nil), "текст")
        XCTAssertNil(VaultArtifactText.decode(Data([0xFF, 0xFE, 0x41]), name: "a.txt", mimeType: nil))
        XCTAssertNil(VaultArtifactText.decode(Data(count: VaultArtifactText.maxBytes + 1), name: "a.txt", mimeType: nil))
    }

    func testContentDispositionFileName() {
        XCTAssertEqual(VaultClient.fileName(fromContentDisposition: "attachment; filename=\"report.md\""), "report.md")
        XCTAssertEqual(VaultClient.fileName(fromContentDisposition: "attachment; filename=\"../../etc/passwd\""), ".._.._etc_passwd")
        XCTAssertEqual(VaultClient.fileName(fromContentDisposition: "attachment; filename=plain.txt; size=3"), "plain.txt")
        XCTAssertNil(VaultClient.fileName(fromContentDisposition: "attachment"))
        XCTAssertNil(VaultClient.fileName(fromContentDisposition: nil))
        XCTAssertNil(VaultClient.fileName(fromContentDisposition: "attachment; filename=\"..\""))
        XCTAssertNil(VaultClient.fileName(fromContentDisposition: "attachment; filename=\".\""))
    }

    func testFinalPhaseExcludesStoppedForConnectionFix() {
        XCTAssertFalse(VaultRequestPhase.failed(.needsConnectionFix(.unauthorized)).isFinal)
        XCTAssertTrue(VaultRequestPhase.failed(.needsConnectionFix(.unauthorized)).isTerminal)
        XCTAssertTrue(VaultRequestPhase.failed(.jobLost).isFinal)
        XCTAssertTrue(VaultRequestPhase.completed(VaultRequestResult(report: "", artifacts: [])).isFinal)
        XCTAssertFalse(VaultRequestPhase.running.isFinal)
    }
}

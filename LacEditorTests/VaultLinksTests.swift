import XCTest
@testable import LacEditor

final class VaultLinksTests: XCTestCase {
    private let paths = ["projects/идея про синхронизацию.md", "thoughts/синхронизация.md", "MEMORY.md", "a/Заметка.md", "b/заметка.md",
                         "Йога/старт.md"]

    private func resolver() -> MarkdownWikiLinkResolver { VaultLinks.resolver(paths: paths, token: 1) }

    private func links(_ text: String, complete: Bool = true) -> [VaultOutgoingLink] {
        VaultLinks.outgoing(in: text, resolver: resolver(), isCatalogComplete: complete)
    }

    func testOrderAndCounts() {
        let text = "[[MEMORY]] и [[идея про синхронизацию]], снова [[memory]] и [[MEMORY|псевдоним]]"
        let result = links(text)
        XCTAssertEqual(result.map(\.title), ["MEMORY", "идея про синхронизацию"])
        XCTAssertEqual(result[0].count, 3)
        XCTAssertEqual(result[1].count, 1)
        XCTAssertEqual((text as NSString).substring(with: result[0].firstRange), "[[MEMORY]]")
    }

    func testStatuses() {
        let result = links("[[MEMORY]] [[projects/идея про синхронизацию]] [[Заметка]] [[нет такой]] [[йога/старт]]")
        XCTAssertEqual(result[0].status, .resolved(path: "MEMORY.md"))
        XCTAssertEqual(result[1].status, .resolved(path: "projects/идея про синхронизацию.md"))
        guard case let .ambiguous(found) = result[2].status else { return XCTFail() }
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(result[3].status, .missing(suggestedPath: "нет такой.md"))
        XCTAssertEqual(result[4].status, .resolved(path: "Йога/старт.md"))
    }

    func testCodeAndSelfLinksAreSkipped() {
        let text = "`[[в коде]]`\n\n```\n[[в блоке]]\n```\n[[#Раздел]] [[заметка#раздел|текст]]"
        let result = links(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "заметка")
        XCTAssertEqual(result[0].heading, "раздел")
    }

    func testSameTargetDifferentHeadingsAreSeparate() {
        XCTAssertEqual(links("[[MEMORY#а]] [[MEMORY#б]] [[MEMORY#А]]").map(\.count), [2, 1])
    }

    func testIncompleteCatalogTurnsMissingIntoChecking() {
        let result = links("[[MEMORY]] [[нет такой]]", complete: false)
        XCTAssertEqual(result[0].status, .resolved(path: "MEMORY.md"))
        XCTAssertEqual(result[1].status, .checking)
    }

    func testSimilarFindsMissingLettersAndTruncatedNames() {
        XCTAssertEqual(VaultLinks.similar(to: "идея про синхрнизацию", in: paths).first, "projects/идея про синхронизацию.md")
        XCTAssertTrue(VaultLinks.similar(to: "синхрон", in: paths).contains("thoughts/синхронизация.md"))
        XCTAssertEqual(VaultLinks.similar(to: "memory", in: paths).first, "MEMORY.md")
        XCTAssertEqual(VaultLinks.similar(to: "СИНХРОНИЗАЦИЯ", in: paths).first, "thoughts/синхронизация.md")
    }

    func testSimilarLimitAndEmptyResult() {
        let many = (0..<20).map { "n/заметка\($0).md" }
        XCTAssertEqual(VaultLinks.similar(to: "заметка", in: many).count, 5)
        XCTAssertEqual(VaultLinks.similar(to: "заметка", in: many, limit: 2).count, 2)
        XCTAssertTrue(VaultLinks.similar(to: "zzzzqqq", in: paths).isEmpty)
        XCTAssertEqual(VaultLinks.similar(to: "заметка", in: many), VaultLinks.similar(to: "заметка", in: many))
    }

    func testSimilarPutsExactNameFirst() {
        let list = ["x/идея длинное имя.md", "y/идея.md", "z/идея 2.md"]
        XCTAssertEqual(VaultLinks.similar(to: "идея", in: list).first, "y/идея.md")
    }

    func testCancellationStopsParsing() {
        let text = "[[MEMORY]] [[нет]]"
        XCTAssertEqual(VaultLinks.outgoing(in: text, resolver: resolver(), isCatalogComplete: true, isCancelled: { true }), [])
        XCTAssertEqual(VaultLinks.similar(to: "memory", in: paths, isCancelled: { true }), [])
    }

    func testVaultResolverHasBaseButRejectsParentPaths() {
        let value = resolver()
        XCTAssertNotEqual(value.resolve(target: "MEMORY"), .invalid)
        XCTAssertEqual(value.resolve(target: "../MEMORY"), .invalid)
        XCTAssertEqual(links("[[../MEMORY]]").first?.status, .missing(suggestedPath: "../MEMORY"))
    }
}

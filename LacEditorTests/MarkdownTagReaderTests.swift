import XCTest
@testable import LacEditor

final class MarkdownTagReaderTests: XCTestCase {
    func testYAMLTagsPreserveLiteralValuesAndSeparateErrors() throws {
        let sources = [
            "---\ntags: [editor, '中文', 'a,b', editor, '_private_*']\n---\n",
            "---\ntags: 'один тег'\n---\n",
            "---\ntags: |\n  first\n  second\n---\n",
            "---\ntags: []\n---\n",
            "---\ntags: [\n---\n",
            "---\ntags: {nested: value}\n---\n",
            "---\ntags: true\n---\n",
            "---\ntitle: no tags\n---\n",
            "---\nshared: &labels ['one', 'two']\ntags: *labels\n---\n",
            "---\nbase: &base {tags: ['merged']}\n<<: *base\n---\n"
        ]
        let inputs = sources.map { MarkdownTagReader.Input(id: UUID(), frontMatter: $0) }
        let result = try MarkdownTagReader.read(inputs)
        XCTAssertEqual(result[inputs[0].id], .tags(["editor", "中文", "a,b", "editor", "_private_*"]))
        XCTAssertEqual(result[inputs[1].id], .tags(["один тег"]))
        XCTAssertEqual(result[inputs[2].id], .tags(["first\nsecond\n"]))
        XCTAssertEqual(result[inputs[3].id], .tags([]))
        XCTAssertEqual(result[inputs[7].id], .tags([]))
        XCTAssertEqual(result[inputs[8].id], .tags(["one", "two"]))
        XCTAssertEqual(result[inputs[9].id], .tags(["merged"]))
        for index in 4...6 {
            guard let outcome = result[inputs[index].id], case .invalid(let message) = outcome else {
                return XCTFail("Expected a document-specific tag error")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testEmptyDuplicateAndCancellation() throws {
        XCTAssertTrue(try MarkdownTagReader.read([]).isEmpty)
        let input = MarkdownTagReader.Input(id: UUID(), frontMatter: "---\ntags: x\n---\n")
        XCTAssertThrowsError(try MarkdownTagReader.read([input, input]))
        XCTAssertThrowsError(try MarkdownTagReader.read([input], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let inputs = (0..<10).map { _ in MarkdownTagReader.Input(id: UUID(), frontMatter: input.frontMatter) }
        var checks = 0
        XCTAssertThrowsError(try MarkdownTagReader.read(inputs, isCancelled: {
            checks += 1
            return checks > 4
        })) { XCTAssertTrue($0 is CancellationError) }
        let list = MarkdownTagReader.Input(id: UUID(), frontMatter: "---\ntags: [one, two, three, four]\n---\n")
        checks = 0
        XCTAssertThrowsError(try MarkdownTagReader.read([list], isCancelled: {
            checks += 1
            return checks > 3
        })) { XCTAssertTrue($0 is CancellationError) }
    }
}

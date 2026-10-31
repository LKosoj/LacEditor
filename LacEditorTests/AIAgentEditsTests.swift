import XCTest
@testable import LacEditor

/// Сценарий ответов модели без сети: очередь ответов и запись всех запросов.
private final class EditScript: @unchecked Sendable {
    enum Reply { case text(String), calls([(name: String, arguments: String)]) }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [(items: [[String: Any]], tools: [String])] = []
    var onStep: ((Int) async -> Void)?

    init(_ replies: [Reply]) { self.replies = replies }

    func step(_ items: [[String: Any]], _ tools: [AIToolDefinition]) async throws -> AIAgentStep {
        let index = lock.withLock { () -> Int in
            requests.append((items, tools.map(\.name)))
            return requests.count - 1
        }
        await onStep?(index)
        let reply: Reply = lock.withLock { replies.isEmpty ? .text("end") : replies.removeFirst() }
        switch reply {
        case .text(let text): return AIAgentStep(calls: [], echoed: [], text: text, usage: AIUsage())
        case .calls(let calls):
            let list = calls.enumerated().map { AIToolCall(id: "c\(index)-\($0.offset)", name: $0.element.name, arguments: $0.element.arguments) }
            return AIAgentStep(calls: list, echoed: [["role": "assistant", "content": "calls \(index)"]], text: nil, usage: AIUsage())
        }
    }

    func serialized(_ index: Int) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: requests[index].items)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Имитация редактора: отвечает на запросы выделения и замены, как EditorCoordinator.
@MainActor
private final class FakeEditor {
    let document: EditorDocument
    var revision: UInt = 7
    var respondsToExtraction = true
    var failure: String?
    private(set) var replacements: [EditorRangeReplacementRequest] = []
    private var tokens: [NSObjectProtocol] = []

    init(document: EditorDocument) {
        self.document = document
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let request = note.object as? EditorTextExtractionRequest, request.documentID == self.document.id,
                      self.respondsToExtraction else { return }
                request.result = EditorTextSelectionSnapshot(documentID: request.documentID, range: NSRange(location: 0, length: 0), text: "",
                                                             editorRevision: self.revision, wasExplicitSelection: false)
            }
        })
        tokens.append(center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let request = note.object as? EditorRangeReplacementRequest, request.documentID == self.document.id else { return }
                self.replacements.append(request)
                if let failure = self.failure { request.failureMessage = failure; return }
                let text = self.document.text as NSString
                guard request.expectedEditorRevision == self.revision, NSMaxRange(request.range) <= text.length,
                      text.substring(with: request.range) == request.originalText else { return }
                self.document.text = text.replacingCharacters(in: request.range, with: request.replacementText)
                self.revision += 1
                request.wasHandled = true
            }
        })
    }

    func remove() { for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = [] }
}

@MainActor
final class AIAgentEditsTests: XCTestCase {
    private var root: URL!
    private var editors: [FakeEditor] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        editors.forEach { $0.remove() }
        editors = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Помощники движка и инструментов

    private func openDocument(_ text: String, name: String = "note.md", path: String? = "note.md") -> AIAgentOpenDocument {
        AIAgentOpenDocument(id: UUID(), name: name, relativePath: path, text: text, revision: 1)
    }

    private func edit(_ old: String, _ new: String, number: Int = 1) -> AIAgentEdit {
        AIAgentEdit(id: UUID(), number: number, documentID: UUID(), documentName: "n", path: "n", oldText: old, newText: new,
                    explanation: "", externalReferences: [], problem: nil)
    }

    private func propose(_ draft: AIAgentEditDraft, _ document: AIAgentOpenDocument, _ old: String, _ new: String, key: String? = nil) -> AIAgentEditDraft.Proposal {
        draft.propose(callKey: key ?? UUID().uuidString, document: document, path: document.relativePath ?? "open:\(document.id.uuidString)",
                      oldText: old, newText: new, explanation: "why")
    }

    private func added(_ proposal: AIAgentEditDraft.Proposal, file: StaticString = #filePath, line: UInt = #line) throws -> AIAgentEdit {
        guard case let .added(edit, _) = proposal else { XCTFail("expected added", file: file, line: line); throw CancellationError() }
        return edit
    }

    private func tools(open: [AIAgentOpenDocument], draft: AIAgentEditDraft = AIAgentEditDraft()) -> AIAgentTools {
        AIAgentTools(scope: AIAgentScope(root: root, openDocuments: open), draft: draft)
    }

    private func call(_ tools: AIAgentTools, _ name: String, _ arguments: [String: Any], id: String = "1") async throws -> AIAgentToolOutcome {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await tools.run(AIToolCall(id: id, name: name, arguments: String(decoding: data, as: UTF8.self)))
    }

    private func proposeCall(_ tools: AIAgentTools, _ path: String, _ old: String, _ new: String, id: String = "1") async throws -> AIAgentToolOutcome {
        try await call(tools, "propose_edit", ["path": path, "old_text": old, "new_text": new, "explanation": "why"], id: id)
    }

    private func json(_ outcome: AIAgentToolOutcome) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(outcome.output.utf8)) as? [String: Any])
    }

    private func lines(_ outcome: AIAgentToolOutcome) throws -> [String] {
        try XCTUnwrap(json(outcome)["lines"] as? [String])
    }

    // MARK: - Движок и черновик

    func testUniqueMatchProposes() async throws {
        let document = openDocument("alpha beta gamma")
        let draft = AIAgentEditDraft()
        let tools = tools(open: [document], draft: draft)
        let outcome = try await proposeCall(tools, "note.md", "beta", "BETA")
        XCTAssertEqual(try json(outcome)["status"] as? String, "proposed")
        XCTAssertEqual(document.text, "alpha beta gamma")
        let read = try await call(tools, "read_document", ["path": "note.md", "from_line": NSNull(), "to_line": NSNull()])
        XCTAssertEqual(try lines(read), ["1\talpha BETA gamma"])
    }

    func testNotFoundAndAmbiguousErrors() throws {
        let draft = AIAgentEditDraft()
        let document = openDocument("one two aaa")
        guard case let .failed(code, message) = propose(draft, document, "missing", "x") else { return XCTFail() }
        XCTAssertEqual(code, .noMatch)
        XCTAssertTrue(message.contains("not found"))
        guard case let .failed(ambiguous, text) = propose(draft, document, "aa", "x") else { return XCTFail() }
        XCTAssertEqual(ambiguous, .ambiguousMatch)
        XCTAssertTrue(text.contains("matches 2 places"), text)
        XCTAssertTrue(draft.edits.isEmpty)
    }

    func testEmptyOldTextAndNoChange() async throws {
        let tools = tools(open: [openDocument("text")])
        let empty = try await proposeCall(tools, "note.md", "", "x")
        XCTAssertEqual(empty.journal.errorCode, .badArguments)
        let same = try await proposeCall(tools, "note.md", "text", "text")
        XCTAssertEqual(same.journal.errorCode, .badArguments)
        XCTAssertNotNil(AIAgentEditEngine.argumentError(oldText: "a\r\nb", newText: "a\nb"))
    }

    func testTextLimitsAndPendingCap() throws {
        XCTAssertNotNil(AIAgentEditEngine.argumentError(oldText: String(repeating: "a", count: 20_001), newText: "b"))
        XCTAssertNotNil(AIAgentEditEngine.argumentError(oldText: "a", newText: String(repeating: "b", count: 20_001)))
        XCTAssertNil(AIAgentEditEngine.argumentError(oldText: String(repeating: "a", count: 20_000), newText: "b"))
        let text = (0..<60).map { String(format: "<k%02d>", $0) }.joined(separator: " ")
        let document = openDocument(text)
        let draft = AIAgentEditDraft()
        for index in 0..<50 { _ = try added(propose(draft, document, String(format: "<k%02d>", index), "x\(index)")) }
        guard case let .failed(code, _) = propose(draft, document, "<k50>", "x") else { return XCTFail() }
        XCTAssertEqual(code, .limitReached)
        XCTAssertEqual(draft.edits.count, 50)
    }

    func testUTF16Indices() {
        let emoji = "😀a😀b"
        XCTAssertEqual(AIAgentEditEngine.matches(of: "a😀", in: emoji, limit: 5), [NSRange(location: 2, length: 3)])
        XCTAssertEqual(AIAgentEditEngine.matches(of: "世界", in: "你好世界", limit: 5), [NSRange(location: 2, length: 2)])
        XCTAssertEqual(AIAgentEditEngine.matches(of: "aa", in: "aaaa", limit: 20).map(\.location), [0, 1, 2])
        // Составная и разложенная формы не равны при точном сравнении
        XCTAssertTrue(AIAgentEditEngine.matches(of: "\u{00E9}", in: "e\u{0301}", limit: 5).isEmpty)
        XCTAssertTrue(AIAgentEditEngine.matches(of: "e\u{0301}", in: "\u{00E9}", limit: 5).isEmpty)
    }

    func testCRLFDocument() throws {
        let crlf = "a\r\nb\r\nc"
        let found = AIAgentEditEngine.matches(of: "a\nb", in: crlf, limit: 5)
        XCTAssertEqual(found, [NSRange(location: 0, length: 4)])
        guard case let .success(change) = AIAgentEditEngine.apply(edit("a\nb", "x\ny"), to: crlf) else { return XCTFail() }
        XCTAssertEqual(change, "x\r\ny\r\nc")
        // Смешанные окончания: берётся окончание найденного фрагмента
        guard case let .success(mixed) = AIAgentEditEngine.apply(edit("b\nc", "B\nC"), to: "a\nb\r\nc\rd") else { return XCTFail() }
        XCTAssertEqual(mixed, "a\nB\r\nC\rd")
        // Нет перевода строки во фрагменте - первое окончание документа
        guard case let .success(inserted) = AIAgentEditEngine.apply(edit("c", "c\nd"), to: "a\r\nc") else { return XCTFail() }
        XCTAssertEqual(inserted, "a\r\nc\r\nd")
        // Совпадение не начинается внутри CRLF, и один CRLF не считается двумя переносами
        XCTAssertEqual(AIAgentEditEngine.matches(of: "\nb", in: "a\r\nb", limit: 5), [NSRange(location: 1, length: 3)])
        XCTAssertEqual(AIAgentEditEngine.matches(of: "a\n\nb", in: "a\r\nb", limit: 5), [])
        // Без CR обычный путь
        guard case let .success(plain) = AIAgentEditEngine.apply(edit("a\nb", "x\ny"), to: "a\nb\nc") else { return XCTFail() }
        XCTAssertEqual(plain, "x\ny\nc")
    }

    func testEnclosingChangeIsMinimalAndSurrogateSafe() throws {
        let simple = try XCTUnwrap(AIAgentEditEngine.enclosingChange(from: "hello world", to: "hello brave world"))
        XCTAssertEqual(simple.range, NSRange(location: 6, length: 0))
        XCTAssertEqual(simple.replacement, "brave ")
        let prefix = try XCTUnwrap(AIAgentEditEngine.enclosingChange(from: "a\u{1F600}b", to: "a\u{1F601}b"))
        XCTAssertEqual(prefix.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(prefix.replacement, "\u{1F601}")
        let suffix = try XCTUnwrap(AIAgentEditEngine.enclosingChange(from: "\u{1F600}", to: "\u{1F200}"))
        XCTAssertEqual(suffix.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(suffix.replacement, "\u{1F200}")
        XCTAssertNil(AIAgentEditEngine.enclosingChange(from: "same", to: "same"))
        let overlapping = try XCTUnwrap(AIAgentEditEngine.enclosingChange(from: "aa", to: "aaa"))
        XCTAssertEqual(overlapping.range.length, 0)
        XCTAssertEqual(overlapping.replacement, "a")
    }

    func testPlanAppliesInOrderAndMarksFailures() {
        let first = edit("A1", "a1", number: 1), missing = edit("ZZ", "z", number: 2), third = edit("C3", "c3", number: 3)
        let plan = AIAgentEditEngine.plan(edits: [first, missing, third], on: "A1 B2 C3", earlierPending: [])
        XCTAssertEqual(plan.text, "a1 B2 c3")
        XCTAssertEqual(plan.applied, [first.id, third.id])
        XCTAssertEqual(plan.failed.map { $0.id }, [missing.id])
        XCTAssertEqual(plan.failed.map { $0.problem }, [.notFound])
        let dependent = edit("a1 B2", "q", number: 4)
        let blocked = AIAgentEditEngine.plan(edits: [dependent], on: "A1 B2", earlierPending: [first.id])
        XCTAssertEqual(blocked.failed.map { $0.problem }, [.needsEarlier])
        XCTAssertTrue(blocked.applied.isEmpty)
    }

    func testRejectMakesDependentUnavailable() throws {
        let draft = AIAgentEditDraft()
        let document = openDocument("one two three")
        let first = try added(propose(draft, document, "one", "uno ONE"))
        let dependent = try added(propose(draft, document, "ONE", "1"))
        let independent = try added(propose(draft, document, "three", "3"))
        XCTAssertEqual(draft.pending(documentID: document.id).map(\.problem), [nil, nil, nil])
        draft.reject([first.id])
        let rest = draft.pending(documentID: document.id)
        XCTAssertEqual(rest.map(\.id), [dependent.id, independent.id])
        XCTAssertEqual(rest.map(\.problem), [.dependsOnRejected, nil])
        let overlay = draft.overlay(on: AIAgentScope(root: nil, openDocuments: [document]))
        XCTAssertEqual(overlay.openDocuments.first?.text, "one two 3")
    }

    func testAcceptEarlierKeepsLaterApplicable() throws {
        let draft = AIAgentEditDraft()
        let document = openDocument("alpha beta")
        let first = try added(propose(draft, document, "alpha", "ALPHA"))
        let later = try added(propose(draft, document, "ALPHA beta", "X"))
        draft.settle(documentID: document.id, applied: [first.id], newBase: "ALPHA beta")
        let rest = draft.pending(documentID: document.id)
        XCTAssertEqual(rest.map(\.id), [later.id])
        XCTAssertNil(rest[0].problem)
        let overlay = draft.overlay(on: AIAgentScope(root: nil, openDocuments: [document]))
        XCTAssertEqual(overlay.openDocuments.first?.text, "X")
    }

    func testDuplicateCallKeyAddsNoSecondEdit() throws {
        let draft = AIAgentEditDraft()
        let document = openDocument("one two")
        let first = try added(propose(draft, document, "one", "1", key: "id\u{1}args"))
        guard case let .duplicate(number, _) = propose(draft, document, "one", "1", key: "id\u{1}args") else { return XCTFail() }
        XCTAssertEqual(number, first.number)
        XCTAssertEqual(draft.edits.count, 1)
        let other = try added(propose(draft, document, "two", "2", key: "id\u{1}other"))
        XCTAssertNotEqual(other.number, first.number)
        XCTAssertEqual(draft.edits.count, 2)
    }

    func testEditBetweenPendingAndSettleSurvives() throws {
        let document = openDocument("alpha one beta two")
        let draft = AIAgentEditDraft()
        let first = try added(propose(draft, document, "one", "1"))
        XCTAssertEqual(draft.pending(documentID: document.id).map(\.id), [first.id])
        let second = try added(propose(draft, document, "two", "2"))
        draft.settle(documentID: document.id, applied: [first.id], newBase: "alpha 1 beta two")
        XCTAssertEqual(draft.pending(documentID: document.id).map(\.id), [second.id])
        XCTAssertNil(draft.pending(documentID: document.id).first?.problem)
    }

    func testRetiredRunCannotAddEdit() {
        let document = openDocument("alpha")
        let draft = AIAgentEditDraft()
        let epoch = draft.epoch
        draft.retire()
        guard case .failed = draft.propose(callKey: "late", document: document, path: "note.md", oldText: "alpha", newText: "beta",
                                           explanation: "why", epoch: epoch) else { return XCTFail() }
        XCTAssertTrue(draft.edits.isEmpty)
    }

    func testConcurrentProposeAndSettle() async throws {
        let text = (0..<30).map { String(format: "<k%02d>", $0) }.joined(separator: " ")
        let document = openDocument(text)
        let draft = AIAgentEditDraft()
        _ = try added(propose(draft, document, "<k29>", "[29]", key: "seed"))
        let scope = AIAgentScope(root: nil, openDocuments: [document])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = draft.propose(callKey: "c\(index)", document: document, path: "note.md",
                                      oldText: String(format: "<k%02d>", index), newText: "[\(index)]", explanation: "")
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    _ = draft.overlay(on: scope)
                    draft.settle(documentID: document.id, applied: [], newBase: text)
                }
            }
        }
        var expected = text
        for index in 0..<20 { expected = expected.replacingOccurrences(of: String(format: "<k%02d>", index), with: "[\(index)]") }
        expected = expected.replacingOccurrences(of: "<k29>", with: "[29]")
        XCTAssertEqual(draft.edits.count, 21)
        XCTAssertTrue(draft.edits.allSatisfy { $0.problem == nil })
        XCTAssertEqual(draft.overlay(on: scope).openDocuments.first?.text, expected)
    }

    func testRebaseUsesFreshSnapshot() throws {
        let draft = AIAgentEditDraft()
        let document = openDocument("foo bar baz")
        _ = try added(propose(draft, document, "foo", "F"))
        _ = try added(propose(draft, document, "baz", "Z"))
        let fresh = AIAgentOpenDocument(id: document.id, name: "note.md", relativePath: "note.md", text: "foo bar BAZ", revision: 2)
        XCTAssertEqual(draft.rebase(onto: AIAgentScope(root: nil, openDocuments: [fresh])), 0)
        XCTAssertEqual(draft.pending(documentID: document.id).map(\.problem), [nil, .notFound])
        XCTAssertEqual(draft.rebase(onto: AIAgentScope(root: nil, openDocuments: [])), 2)
        XCTAssertTrue(draft.edits.isEmpty)
    }

    func testExternalReferences() {
        XCTAssertEqual(AIAgentEditEngine.externalReferences(old: "x", new: "see https://evil.example/a now"), ["https://evil.example/a"])
        XCTAssertFalse(AIAgentEditEngine.externalReferences(old: "<img src=\"a.png\">", new: "<IMG SRC=\"b.png\">").isEmpty)
        XCTAssertFalse(AIAgentEditEngine.externalReferences(old: "x", new: "<iframe src=a>").isEmpty)
        XCTAssertTrue(AIAgentEditEngine.externalReferences(old: "link https://a.example/x", new: "LINK HTTPS://A.EXAMPLE/X").isEmpty)
        XCTAssertTrue(AIAgentEditEngine.externalReferences(old: "a", new: "plain text").isEmpty)
    }

    // MARK: - Инструменты

    func testProposeEditToolOutputAndJournal() async throws {
        let tools = tools(open: [openDocument("alpha beta")])
        let outcome = try await proposeCall(tools, "note.md", "beta", "BETA")
        let object = try json(outcome)
        XCTAssertEqual(object["status"] as? String, "proposed")
        XCTAssertEqual(object["edit_id"] as? String, "e1")
        XCTAssertEqual(object["pending_edits_in_document"] as? Int, 1)
        XCTAssertEqual(outcome.journal.kind, .proposeEdit)
        XCTAssertEqual(outcome.journal.files, [AIAgentJournalFile(path: "note.md", name: "note.md", bytes: 8, source: .draft)])
        XCTAssertEqual(outcome.journal.sentBytes, outcome.output.utf8.count)
        let failed = try await proposeCall(tools, "note.md", "missing", "x", id: "2")
        XCTAssertEqual(failed.journal.errorCode, .noMatch)
        XCTAssertEqual(failed.journal.kind, .proposeEdit)
        XCTAssertEqual(try json(failed)["error"] as? String, "noMatch")
        let again = try await proposeCall(tools, "note.md", "beta", "BETA")
        XCTAssertEqual(try json(again)["edit_id"] as? String, "e1")
    }

    func testClosedFileIsNotOpenError() async throws {
        try Data([0x61, 0xE9, 0x20, 0x62]).write(to: root.appendingPathComponent("latin.md"))
        try Data([0xEF, 0xBB, 0xBF] + Array("alpha".utf8)).write(to: root.appendingPathComponent("bom.md"))
        for name in ["latin.md", "bom.md"] {
            let outcome = try await proposeCall(tools(open: []), name, "a", "b")
            XCTAssertEqual(outcome.journal.errorCode, .notOpen, name)
            let message = try XCTUnwrap(json(outcome)["message"] as? String)
            XCTAssertFalse(message.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        }
        let outside = try await proposeCall(tools(open: []), "../x.md", "a", "b")
        XCTAssertEqual(outside.journal.errorCode, .pathNotAllowed)
        let noFolder = try await proposeCall(AIAgentTools(scope: AIAgentScope(root: nil, openDocuments: [])), "x.md", "a", "b")
        XCTAssertEqual(noFolder.journal.errorCode, .noFolder)
    }

    func testDraftVisibleToSearchOutlineAndRead() async throws {
        try "disk".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let tools = tools(open: [openDocument("# Title\nold body")])
        let before = try await call(tools, "read_document", ["path": "note.md", "from_line": NSNull(), "to_line": NSNull()])
        XCTAssertEqual(before.journal.files.first?.source, .unsaved)
        _ = try await proposeCall(tools, "note.md", "old body", "# Added\nnew body")
        let read = try await call(tools, "read_document", ["path": "note.md", "from_line": NSNull(), "to_line": NSNull()])
        XCTAssertEqual(try lines(read), ["1\t# Title", "2\t# Added", "3\tnew body"])
        XCTAssertEqual(read.journal.files.first?.source, .draft)
        let outline = try await call(tools, "document_outline", ["path": "note.md"])
        XCTAssertEqual((try json(outline)["headings"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(outline.journal.files.first?.source, .draft)
        let search = try await call(tools, "search_text", ["query": "new body", "prefix": NSNull()])
        let matches = try XCTUnwrap(json(search)["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.first?["line"] as? Int, 3)
        XCTAssertEqual(search.journal.files.first?.source, .draft)
    }

    func testHiddenDocumentCannotBeEdited() async throws {
        let hidden = openDocument("KEY=1", name: ".env", path: ".env")
        let outcome = try await proposeCall(tools(open: [hidden]), "open:\(hidden.id.uuidString)", "KEY=1", "KEY=2")
        XCTAssertEqual(outcome.journal.errorCode, .notFound)
    }

    func testDefinitionsIncludeProposeEdit() throws {
        let definition = try XCTUnwrap(AIAgentTools.definitions.first { $0.name == "propose_edit" })
        XCTAssertEqual(definition.name, "propose_edit")
        let properties = try XCTUnwrap(definition.parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["path", "old_text", "new_text", "explanation"])
        XCTAssertEqual(Set(try XCTUnwrap(definition.parameters["required"] as? [String])), Set(properties.keys))
        XCTAssertEqual(definition.parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual((properties["old_text"] as? [String: Any])?["minLength"] as? Int, 1)
    }

    // MARK: - Контроллер

    private struct Setup {
        let controller: AIAgentController
        let state: AppState
        let script: EditScript
        let documents: [EditorDocument]
        let editors: [FakeEditor]
    }

    private func make(_ replies: [EditScript.Reply], documents: [EditorDocument],
                      confirm: @escaping @MainActor (AIAgentFileApplySummary) -> Bool = { _ in false },
                      writer: (@Sendable (AIAgentClosedPlan, URL, [URL]) throws -> AIAgentFileApplyOutcome)? = nil) throws -> Setup {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIAgentEdits-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.agent]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = "test-model"
        preferences.aiConfiguration = configuration
        var jina = JinaConfiguration()
        jina.searchEnabled = false
        jina.readerEnabled = false
        preferences.jinaConfiguration = jina
        let state = AppState(initialDocuments: documents, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        state.selectedDocumentID = documents[0].id
        let script = EditScript(replies)
        let step: @Sendable ([[String: Any]], String, [AIToolDefinition], AIModelProfile, String?) async throws -> AIAgentStep = { items, _, tools, _, _ in
            try await script.step(items, tools)
        }
        let controller = writer.map {
            AIAgentController(appState: state, step: step, loadKey: { _, _ in nil }, loadJinaKey: { _, _ in nil }, confirmFileWrite: confirm, fileWriter: $0)
        } ?? AIAgentController(appState: state, step: step, loadKey: { _, _ in nil }, loadJinaKey: { _, _ in nil }, confirmFileWrite: confirm)
        let fakes = documents.map { FakeEditor(document: $0) }
        editors.append(contentsOf: fakes)
        return Setup(controller: controller, state: state, script: script, documents: documents, editors: fakes)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func send(_ controller: AIAgentController, _ text: String) async {
        controller.draft = text
        controller.send()
        for _ in 0..<1000 {
            _ = await waitFor { !controller.isWorking || controller.approval != nil }
            guard controller.isWorking, controller.approval != nil else { return }
            controller.resolve(.allowOnce)
        }
    }

    private func reply(_ calls: [(String, String)]) -> EditScript.Reply { .calls(calls.map { (name: "propose_edit", arguments: $0.1) }) }

    private func args(_ document: EditorDocument, _ old: String, _ new: String) -> (String, String) {
        let object: [String: Any] = ["path": "open:\(document.id.uuidString)", "old_text": old, "new_text": new, "explanation": "why"]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return ("propose_edit", String(decoding: data, as: UTF8.self))
    }

    private func hold(_ script: EditScript, at index: Int) -> AsyncStream<Void>.Continuation {
        let gate = AsyncStream<Void>.makeStream()
        script.onStep = { current in
            guard current == index else { return }
            for await _ in gate.stream { break }
        }
        return gate.continuation
    }

    func testEditIsOnlyProposedUntilAccepted() async throws {
        let document = EditorDocument(text: "Hello world")
        let setup = try make([reply([args(document, "world", "there")]), .text("done")], documents: [document])
        await send(setup.controller, "Edit")
        XCTAssertEqual(document.text, "Hello world")
        XCTAssertEqual(setup.controller.editGroups.count, 1)
        XCTAssertEqual(setup.controller.editGroups.first?.edits.first?.newText, "there")
        XCTAssertTrue(setup.editors[0].replacements.isEmpty)
    }

    func testReadAfterProposeCountsDraftBytes() async throws {
        let document = EditorDocument(text: "Hello world")
        let read: EditScript.Reply = .calls([(name: "read_document", arguments: #"{"path":"open:\#(document.id.uuidString)"}"#)])
        let setup = try make([reply([args(document, "world", "there")]), read, .text("done")], documents: [document])
        await send(setup.controller, "Edit")
        XCTAssertTrue(setup.script.serialized(2).contains("Hello there"))
        let journal = try XCTUnwrap(setup.controller.turns.last?.journal)
        XCTAssertEqual(journal.map(\.kind), [.proposeEdit, .readDocument])
        XCTAssertEqual(journal[1].files.first?.source, .draft)
        XCTAssertGreaterThanOrEqual(setup.controller.counters.contextBytes, journal[1].sentBytes)
        XCTAssertGreaterThan(setup.controller.counters.sentBytes, 0)
    }

    func testAcceptSendsOneGroupedReplacement() async throws {
        let document = EditorDocument(text: "alpha one beta two gamma")
        let setup = try make([reply([args(document, "one", "1"), args(document, "two", "2"), args(document, "gamma", "G")]), .text("done")],
                             documents: [document])
        await send(setup.controller, "Edit")
        XCTAssertEqual(setup.controller.editGroups.first?.edits.count, 3)
        setup.controller.acceptAllEdits(in: document.id)
        let requests = setup.editors[0].replacements
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].groupsUndo)
        XCTAssertEqual(requests[0].expectedEditorRevision, 7)
        XCTAssertEqual(requests[0].range, NSRange(location: 6, length: 18))
        XCTAssertEqual(requests[0].replacementText, "1 beta 2 G")
        XCTAssertEqual(document.text, "alpha 1 beta 2 G")
        XCTAssertTrue(setup.controller.editGroups.isEmpty)
        XCTAssertEqual(setup.controller.message, L10n.tr("已接受 %lld 处修改", 3))
    }

    func testAcceptReadsFreshTextAndSkipsStaleEdit() async throws {
        let document = EditorDocument(text: "alpha one beta two gamma")
        let setup = try make([reply([args(document, "one", "1"), args(document, "two", "2")]), .text("done")], documents: [document])
        let gate = hold(setup.script, at: 1)
        setup.controller.draft = "Edit"
        setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.resolve(.allowOnce)
        _ = await waitFor { setup.controller.editGroups.first?.edits.count == 2 }
        document.text = "alpha one beta TWO gamma"
        setup.controller.acceptAllEdits(in: document.id)
        XCTAssertEqual(document.text, "alpha 1 beta TWO gamma")
        XCTAssertEqual(setup.controller.editGroups.first?.edits.map(\.problem), [.notFound])
        XCTAssertEqual(setup.controller.message, L10n.tr("已接受 %lld 处修改，%lld 处无法应用", 1, 1))
        XCTAssertTrue(setup.controller.isWorking)
        gate.yield()
        _ = await waitFor { !setup.controller.isWorking }
        XCTAssertEqual(setup.controller.turns.last?.status, .answered)
    }

    func testAcceptFailureKeepsEdits() async throws {
        let document = EditorDocument(text: "alpha one")
        let setup = try make([reply([args(document, "one", "1")]), .text("done")], documents: [document])
        await send(setup.controller, "Edit")
        setup.editors[0].failure = "boom"
        setup.controller.acceptAllEdits(in: document.id)
        XCTAssertEqual(setup.controller.message, "boom")
        XCTAssertEqual(setup.controller.editGroups.first?.edits.count, 1)
        XCTAssertEqual(document.text, "alpha one")
        setup.editors[0].failure = nil
        setup.editors[0].respondsToExtraction = false
        setup.controller.acceptAllEdits(in: document.id)
        XCTAssertEqual(setup.controller.message, L10n.tr("当前文本无法修改"))
        XCTAssertEqual(setup.controller.editGroups.first?.edits.count, 1)
        setup.editors[0].respondsToExtraction = true
        document.setReadingMode(true)
        setup.controller.acceptAllEdits(in: document.id)
        XCTAssertEqual(setup.controller.message, L10n.tr("阅读模式下无法修改"))
        XCTAssertEqual(setup.controller.editGroups.first?.edits.count, 1)
        XCTAssertEqual(document.text, "alpha one")
    }

    func testAcceptIsBlockedForNonSelectedDocument() async throws {
        let first = EditorDocument(text: "first"), second = EditorDocument(text: "second text")
        let setup = try make([reply([args(second, "second", "2nd")]), .text("done")], documents: [first, second])
        await send(setup.controller, "Edit")
        XCTAssertFalse(setup.controller.canAccept(in: second.id))
        setup.controller.acceptAllEdits(in: second.id)
        XCTAssertEqual(setup.controller.message, L10n.tr("切换到此文档后才能接受修改"))
        XCTAssertTrue(setup.editors[1].replacements.isEmpty)
        setup.controller.showDocument(second.id)
        XCTAssertEqual(setup.state.selectedDocumentID, second.id)
        XCTAssertTrue(setup.controller.canAccept(in: second.id))
    }

    func testClosedDocumentDropsItsEdits() async throws {
        let first = EditorDocument(text: "first"), second = EditorDocument(text: "second text")
        let setup = try make([reply([args(second, "second", "2nd")]), .text("done")], documents: [first, second])
        await send(setup.controller, "Edit")
        setup.state.documents.removeAll { $0.id == second.id }
        setup.controller.acceptAllEdits(in: second.id)
        XCTAssertTrue(setup.controller.editGroups.isEmpty)
        XCTAssertEqual(setup.controller.message, L10n.tr("文档已关闭，其修改建议已丢弃"))
        XCTAssertEqual(setup.controller.messageKind, .info)
    }

    func testEditsSurviveStopAndNewQuestionButNotNewConversation() async throws {
        let document = EditorDocument(text: "alpha one")
        let setup = try make([reply([args(document, "one", "1")]), .text("done"), .text("second")], documents: [document])
        await send(setup.controller, "Edit")
        setup.controller.stop()
        XCTAssertEqual(setup.controller.editGroups.count, 1)
        document.text = "changed"
        await send(setup.controller, "Again")
        XCTAssertEqual(setup.controller.editGroups.first?.edits.map(\.problem), [.notFound])
        setup.controller.newConversation()
        XCTAssertTrue(setup.controller.editGroups.isEmpty)
    }

    func testEditAfterAcceptSeesAcceptedText() async throws {
        let document = EditorDocument(text: "alpha one beta two gamma")
        let setup = try make([reply([args(document, "one", "1")]),
                              reply([args(document, "1 beta", "1 BETA"), args(document, "one", "x")]), .text("done")], documents: [document])
        let gate = hold(setup.script, at: 1)
        setup.controller.draft = "Edit"
        setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.resolve(.allowOnce)
        _ = await waitFor { setup.controller.editGroups.first?.edits.count == 1 }
        setup.controller.acceptAllEdits(in: document.id)
        XCTAssertEqual(document.text, "alpha 1 beta two gamma")
        gate.yield()
        _ = await waitFor { !setup.controller.isWorking }
        XCTAssertEqual(setup.controller.editGroups.first?.edits.map(\.oldText), ["1 beta"])
        XCTAssertNil(setup.controller.editGroups.first?.edits.first?.problem)
        XCTAssertEqual(setup.controller.turns.last?.journal.last?.errorCode, .noMatch)
    }

    func testRejectAllAndRejectOne() async throws {
        let document = EditorDocument(text: "alpha one beta two")
        let setup = try make([reply([args(document, "one", "1"), args(document, "two", "2")]), .text("done")], documents: [document])
        await send(setup.controller, "Edit")
        let first = try XCTUnwrap(setup.controller.editGroups.first?.edits.first)
        setup.controller.rejectEdit(first.id)
        XCTAssertEqual(setup.controller.editGroups.first?.edits.map(\.oldText), ["two"])
        setup.controller.rejectAllEdits(in: nil)
        XCTAssertTrue(setup.controller.editGroups.isEmpty)
        XCTAssertTrue(setup.editors[0].replacements.isEmpty)
        XCTAssertEqual(document.text, "alpha one beta two")
    }

    func testInstructionsAllowProposeEditOnly() {
        XCTAssertTrue(AIAgentController.instructions.contains("propose_edit"))
        XCTAssertFalse(AIAgentController.instructions.contains("Documents cannot be changed"))
        XCTAssertFalse(AIAgentController.instructions.contains("only the provided read tools"))
    }

    func testInstructionsMentionClosedFiles() {
        XCTAssertTrue(AIAgentController.instructions.contains("not open"))
        XCTAssertTrue(AIAgentController.instructions.contains("propose_edit"))
        XCTAssertFalse(AIAgentController.instructions.contains("Closed files cannot be edited"))
    }

    func testToolListIncludesProposeEdit() async throws {
        let document = EditorDocument(text: "text")
        let setup = try make([.text("a")], documents: [document])
        await send(setup.controller, "q")
        XCTAssertTrue(setup.script.requests[0].tools.contains("propose_edit"))
    }
}

// MARK: - Правки в закрытых файлах

private final class TaskBox: @unchecked Sendable { var task: Task<Void, Never>? }

private final class WriterLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var failOn: String?
    var onCall: (@Sendable (String) -> Void)?
    var called: [String] { lock.withLock { names } }
    func add(_ name: String) { lock.withLock { names.append(name) }; onCall?(name) }
}

extension AIAgentEditsTests {
    private func write(_ text: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent(name)), as: UTF8.self)
    }

    private func closedPlan(_ url: URL, _ edits: [(String, String)]) throws -> AIAgentClosedPlan {
        let snapshot = try FileRevisionSnapshot.capture(url)
        let name = url.lastPathComponent
        return AIAgentClosedPlan(
            key: UUID(), file: AIAgentClosedFile(url: url, relativePath: name, snapshot: snapshot), name: name,
            edits: edits.enumerated().map { index, pair in
                AIAgentEdit(id: UUID(), number: index + 1, documentID: UUID(), documentName: name, path: name, oldText: pair.0, newText: pair.1,
                            explanation: "", externalReferences: [], problem: nil, isClosedFile: true)
            })
    }

    private func closedTools(_ draft: AIAgentEditDraft = AIAgentEditDraft()) -> AIAgentTools {
        AIAgentTools(scope: AIAgentScope(root: root, openDocuments: []), draft: draft)
    }

    // MARK: Инструменты

    func testProposeOnClosedFileCreatesClosedEntry() async throws {
        let url = try write("alpha beta", to: "closed.md")
        let draft = AIAgentEditDraft()
        let outcome = try await proposeCall(closedTools(draft), "closed.md", "alpha", "ALPHA")
        let object = try json(outcome)
        XCTAssertEqual(object["status"] as? String, "proposed")
        XCTAssertEqual(object["closed_file"] as? Bool, true)
        XCTAssertEqual(draft.edits.first?.isClosedFile, true)
        XCTAssertEqual(try read("closed.md"), "alpha beta")
        XCTAssertEqual(draft.closedPlans().first?.file.snapshot, try FileRevisionSnapshot.capture(url))
    }

    func testReadAndSearchSeeClosedDraft() async throws {
        _ = try write("# Title\nold body", to: "closed.md")
        let tools = closedTools()
        _ = try await proposeCall(tools, "closed.md", "old body", "new body")
        let read = try await call(tools, "read_document", ["path": "closed.md", "from_line": NSNull(), "to_line": NSNull()])
        XCTAssertEqual(try lines(read), ["1\t# Title", "2\tnew body"])
        XCTAssertEqual(read.journal.files.first?.source, .draft)
        let outline = try await call(tools, "document_outline", ["path": "closed.md"])
        XCTAssertEqual(outline.journal.files.first?.source, .draft)
        let search = try await call(tools, "search_text", ["query": "new body", "prefix": NSNull()])
        XCTAssertEqual((try json(search)["matches"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try self.read("closed.md"), "# Title\nold body")
        let list = try json(try await call(tools, "list_documents", ["prefix": NSNull()]))
        XCTAssertEqual((list["open_documents"] as? [Any])?.count, 0)
        XCTAssertTrue((list["files"] as? [[String: Any]])?.contains { $0["path"] as? String == "closed.md" } == true)
    }

    func testClosedFileLimits() async throws {
        let draft = AIAgentEditDraft()
        let tools = closedTools(draft)
        for index in 0..<AIAgentEditLimits.maxClosedFiles {
            _ = try write("alpha beta", to: "f\(index).md")
            let outcome = try await proposeCall(tools, "f\(index).md", "alpha", "ALPHA", id: "p\(index)")
            XCTAssertEqual(try json(outcome)["status"] as? String, "proposed")
        }
        _ = try write("alpha", to: "extra.md")
        let refused = try await proposeCall(tools, "extra.md", "alpha", "x", id: "extra")
        XCTAssertEqual(refused.journal.errorCode, .limitReached)
        let more = try await proposeCall(tools, "f0.md", "beta", "BETA", id: "more")
        XCTAssertEqual(try json(more)["status"] as? String, "proposed")
        XCTAssertEqual(draft.edits.count, AIAgentEditLimits.maxClosedFiles + 1)
    }

    func testPendingCapCountsClosedFiles() async throws {
        let words = (0..<(AIAgentEditLimits.maxPendingEdits + 1)).map { String(format: "w%02d", $0) }
        _ = try write(words.joined(separator: " "), to: "many.md")
        let tools = closedTools()
        for (index, word) in words.prefix(AIAgentEditLimits.maxPendingEdits).enumerated() {
            let outcome = try await proposeCall(tools, "many.md", word, "x" + word, id: "c\(index)")
            XCTAssertEqual(try json(outcome)["status"] as? String, "proposed")
        }
        let over = try await proposeCall(tools, "many.md", words[AIAgentEditLimits.maxPendingEdits], "y", id: "over")
        XCTAssertEqual(over.journal.errorCode, .limitReached)
    }

    func testChangedFileInvalidatesEntry() async throws {
        let url = try write("alpha beta gamma", to: "closed.md")
        let draft = AIAgentEditDraft()
        let tools = closedTools(draft)
        let first = try await proposeCall(tools, "closed.md", "alpha", "ALPHA", id: "1")
        _ = try await proposeCall(tools, "closed.md", "beta", "BETA", id: "2")
        XCTAssertEqual(try json(first)["status"] as? String, "proposed")
        try Data("changed outside and longer than before".utf8).write(to: url)
        let read = try await call(tools, "read_document", ["path": "closed.md", "from_line": NSNull(), "to_line": NSNull()])
        XCTAssertEqual(try lines(read), ["1\tchanged outside and longer than before"])
        XCTAssertEqual(draft.edits.map(\.problem), [.fileChanged, .fileChanged])
        let again = try await proposeCall(tools, "closed.md", "outside", "x", id: "3")
        XCTAssertEqual(again.journal.errorCode, .changedDuringRead)
        // Перестройка не стирает причину
        draft.reject([try XCTUnwrap(draft.edits.first?.id)])
        XCTAssertEqual(draft.edits.map(\.problem), [.fileChanged])
        XCTAssertTrue(draft.closedPlans().isEmpty)
    }

    func testLargeEditSkipsWordDiff() throws {
        let setup = try make([], documents: [EditorDocument(text: "x")])
        let old = String(repeating: "a ", count: AIAgentEditLimits.maxDiffUnits)
        let diff = setup.controller.diff(for: edit(old, "b"))
        XCTAssertEqual(String(diff.original.characters), old)
        XCTAssertEqual(String(diff.replacement.characters), "b")
    }

    func testRebaseDropsClosedEditsOfOtherFolder() async throws {
        _ = try write("alpha beta", to: "closed.md")
        let draft = AIAgentEditDraft()
        _ = try await proposeCall(closedTools(draft), "closed.md", "alpha", "ALPHA")
        XCTAssertEqual(draft.rebase(onto: AIAgentScope(root: root, openDocuments: [])), 0)
        let other = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(draft.rebase(onto: AIAgentScope(root: other, openDocuments: [])), 1)
        XCTAssertTrue(draft.edits.isEmpty)
        XCTAssertTrue(draft.closedPlans().isEmpty)
    }

    func testRebaseDropsClosedEditsWhenParentBecomesRoot() async throws {
        _ = try write("alpha beta", to: "closed.md")
        let draft = AIAgentEditDraft()
        _ = try await proposeCall(closedTools(draft), "closed.md", "alpha", "ALPHA")
        XCTAssertEqual(draft.rebase(onto: AIAgentScope(root: root.deletingLastPathComponent(), openDocuments: [])), 1)
        XCTAssertTrue(draft.edits.isEmpty)
    }

    func testRejectedClosedFilesDoNotCountTowardsLimit() async throws {
        let draft = AIAgentEditDraft()
        let tools = closedTools(draft)
        for index in 0..<AIAgentEditLimits.maxClosedFiles {
            _ = try write("alpha", to: "f\(index).md")
            _ = try await proposeCall(tools, "f\(index).md", "alpha", "ALPHA")
        }
        draft.reject([try XCTUnwrap(draft.edits.first { $0.path == "f0.md" }?.id)])
        _ = try write("alpha", to: "next.md")
        let outcome = try await proposeCall(tools, "next.md", "alpha", "ALPHA")
        XCTAssertNil(outcome.journal.errorCode)
        // Вернуться к отклонённому файлу сверх лимита нельзя
        let again = try await proposeCall(tools, "f0.md", "alpha", "ALPHA2")
        XCTAssertEqual(again.journal.errorCode, .limitReached)
    }

    func testRebaseMovesClosedEditsToOpenDocument() async throws {
        _ = try write("alpha beta", to: "closed.md")
        let draft = AIAgentEditDraft()
        _ = try await proposeCall(closedTools(draft), "closed.md", "alpha", "ALPHA")
        let other = openDocument("zzz", name: "other.md", path: "other.md")
        _ = draft.rebase(onto: AIAgentScope(root: root, openDocuments: [other]))
        XCTAssertEqual(draft.edits.first?.isClosedFile, true)
        let twin = openDocument("alpha beta", name: "closed.md", path: "closed.md")
        _ = draft.rebase(onto: AIAgentScope(root: root, openDocuments: [twin]))
        XCTAssertEqual(draft.edits.first?.isClosedFile, false)
        XCTAssertEqual(draft.edits.first?.documentID, twin.id)
        XCTAssertNil(draft.edits.first?.problem)
        XCTAssertTrue(draft.closedPlans().isEmpty)
        let changed = AIAgentOpenDocument(id: twin.id, name: "closed.md", relativePath: "closed.md", text: "different", revision: 2)
        _ = draft.rebase(onto: AIAgentScope(root: root, openDocuments: [changed]))
        XCTAssertEqual(draft.edits.first?.problem, .notFound)
    }

    func testSymlinkIsRejectedForClosedFile() async throws {
        _ = try write("alpha", to: "real.md")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("real.md"))
        let outcome = try await proposeCall(closedTools(), "link.md", "alpha", "x")
        XCTAssertEqual(outcome.journal.errorCode, .pathNotAllowed)
    }

    // MARK: Запись на диск

    func testWritesAppliedEditsAndKeepsCRLF() throws {
        let original = "Line one\r\nü line\r\nlast"
        let url = try write(original, to: "crlf.md")
        let plan = try closedPlan(url, [("ü line", "ü line\nextra")])
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in nil })
        XCTAssertEqual(outcome.status, .written(applied: 1, notApplied: 0))
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes, Data("Line one\r\nü line\r\nextra\r\nlast".utf8))
        XCTAssertFalse(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
    }

    func testVersionBeforeAndAfterWrite() throws {
        let url = try write("alpha", to: "v.md")
        let plan = try closedPlan(url, [("alpha", "beta")])
        var log: [String] = []
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in log.append("version"); return nil },
                                                  write: { text, target in log.append("write"); try Data(text.utf8).write(to: target) })
        XCTAssertEqual(log, ["version", "write", "version"])
        XCTAssertFalse(outcome.versionWarning)
        XCTAssertEqual(try read("v.md"), "beta")

        let second = try write("alpha", to: "w.md")
        let secondPlan = try closedPlan(second, [("alpha", "beta")])
        var calls = 0
        let warned = try AIAgentFileWriter.apply(secondPlan, root: root, openFileURLs: [], recordVersion: { _ in
            calls += 1
            return calls == 1 ? CocoaError(.fileWriteUnknown) : nil
        })
        XCTAssertTrue(warned.versionWarning)
        XCTAssertEqual(warned.status, .written(applied: 1, notApplied: 0))

        let third = try write("alpha", to: "x.md")
        let thirdPlan = try closedPlan(third, [("alpha", "beta")])
        var thirdLog: [String] = []
        let failed = try AIAgentFileWriter.apply(thirdPlan, root: root, openFileURLs: [], recordVersion: { _ in thirdLog.append("version"); return nil },
                                                 write: { _, _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertEqual(failed.status, .skipped(.writeFailed))
        XCTAssertEqual(thirdLog, ["version"])
        XCTAssertEqual(try read("x.md"), "alpha")
    }

    func testChangedOutsideIsSkipped() throws {
        let url = try write("alpha", to: "c.md")
        let plan = try closedPlan(url, [("alpha", "beta")])
        try Data("alpha with other length".utf8).write(to: url)
        var written = false
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in nil }, write: { _, _ in written = true })
        XCTAssertEqual(outcome.status, .skipped(.changed))
        XCTAssertFalse(written)
        XCTAssertEqual(try read("c.md"), "alpha with other length")
    }

    func testSymlinkSwappedBeforeWrite() throws {
        let directory = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("file.md")
        try Data("alpha".utf8).write(to: url)
        let plan = try closedPlan(url, [("alpha", "beta")])
        let real = root.appendingPathComponent("sub_real")
        try FileManager.default.moveItem(at: directory, to: real)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: real)
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in nil })
        XCTAssertEqual(outcome.status, .skipped(.symbolicLink))
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("file.md"), encoding: .utf8), "alpha")
    }

    func testDeletedFile() throws {
        let url = try write("alpha", to: "gone.md")
        let plan = try closedPlan(url, [("alpha", "beta")])
        try FileManager.default.removeItem(at: url)
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in nil })
        XCTAssertEqual(outcome.status, .skipped(.changed))
    }

    func testNonUTF8AndBOMSkipped() throws {
        let latin = root.appendingPathComponent("latin.md"), bom = root.appendingPathComponent("bom.md")
        try Data([0x61, 0xE9, 0x20, 0x62]).write(to: latin)
        try Data([0xEF, 0xBB, 0xBF] + Array("alpha".utf8)).write(to: bom)
        var written = false
        for (url, old) in [(latin, "a"), (bom, "alpha")] {
            let plan = try closedPlan(url, [(old, "x")])
            let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in nil }, write: { _, _ in written = true })
            XCTAssertEqual(outcome.status, .skipped(.notExactUTF8), url.lastPathComponent)
        }
        XCTAssertFalse(written)
    }

    func testOpenFileIsNotWritten() throws {
        let url = try write("alpha", to: "open.md")
        let plan = try closedPlan(url, [("alpha", "beta")])
        var written = false
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [url], recordVersion: { _ in nil }, write: { _, _ in written = true })
        XCTAssertEqual(outcome.status, .skipped(.openNow))
        XCTAssertFalse(written)
    }

    func testCancelledBeforeWriteThrows() throws {
        let url = try write("alpha", to: "cancel.md")
        let plan = try closedPlan(url, [("alpha", "beta")])
        var versions = 0
        XCTAssertThrowsError(try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], isCancelled: { true },
                                                         recordVersion: { _ in versions += 1; return nil })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(versions, 0)
        XCTAssertEqual(try read("cancel.md"), "alpha")
    }

    func testNothingApplicable() throws {
        let url = try write("alpha", to: "none.md")
        let plan = try closedPlan(url, [("missing", "x")])
        var written = false
        let outcome = try AIAgentFileWriter.apply(plan, root: root, openFileURLs: [], recordVersion: { _ in nil }, write: { _, _ in written = true })
        XCTAssertEqual(outcome.status, .skipped(.nothingApplicable))
        XCTAssertFalse(written)
    }

    // MARK: Контроллер

    private func closedArgs(_ path: String, _ old: String, _ new: String) -> (String, String) {
        let object: [String: Any] = ["path": path, "old_text": old, "new_text": new, "explanation": "why"]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return ("propose_edit", String(decoding: data, as: UTF8.self))
    }

    private func fakeWriter(_ log: WriterLog) -> @Sendable (AIAgentClosedPlan, URL, [URL]) throws -> AIAgentFileApplyOutcome {
        { plan, root, openURLs in
            log.add(plan.name)
            return try AIAgentFileWriter.apply(plan, root: root, openFileURLs: openURLs, isCancelled: { Task.isCancelled }, recordVersion: { _ in nil },
                                               write: { text, url in
                                                   if log.failOn == plan.name { throw CocoaError(.fileWriteUnknown) }
                                                   try Data(text.utf8).write(to: url)
                                               })
        }
    }

    private func proposeClosed(_ names: [String], writer: WriterLog = WriterLog(), confirm: @escaping @MainActor (AIAgentFileApplySummary) -> Bool = { _ in true }) async throws -> Setup {
        for name in names { _ = try write("alpha \(name)", to: name) }
        let document = EditorDocument(text: "open doc")
        let setup = try make([reply(names.map { closedArgs($0, "alpha", "ALPHA") }), .text("done")], documents: [document], confirm: confirm, writer: fakeWriter(writer))
        _ = setup.state.folderWorkspace.setRoot(root)
        await send(setup.controller, "Edit")
        return setup
    }

    func testApplyToFilesRequiresConfirmation() async throws {
        let log = WriterLog()
        let setup = try await proposeClosed(["a.md"], writer: log, confirm: { _ in false })
        XCTAssertEqual(setup.controller.editGroups.first?.isClosedFile, true)
        XCTAssertEqual(setup.controller.closedFileCount, 1)
        XCTAssertEqual(try read("a.md"), "alpha a.md")
        XCTAssertTrue(log.called.isEmpty)
        setup.controller.applyToFiles()
        XCTAssertTrue(log.called.isEmpty)
        XCTAssertEqual(try read("a.md"), "alpha a.md")
        XCTAssertEqual(setup.controller.editGroups.count, 1)
    }

    func testPartialFailureOnSecondFile() async throws {
        let log = WriterLog()
        log.failOn = "b.md"
        let setup = try await proposeClosed(["a.md", "b.md", "c.md"], writer: log)
        let task = try XCTUnwrap(setup.controller.applyToFiles())
        await task.value
        let report = try XCTUnwrap(setup.controller.fileReport)
        XCTAssertEqual(report.lines.map(\.status), [.written(applied: 1, notApplied: 0), .skipped(.writeFailed), .written(applied: 1, notApplied: 0)])
        XCTAssertEqual(try read("a.md"), "ALPHA a.md")
        XCTAssertEqual(try read("b.md"), "alpha b.md")
        XCTAssertEqual(try read("c.md"), "ALPHA c.md")
        XCTAssertEqual(setup.controller.editGroups.map(\.name), ["b.md"])
        XCTAssertEqual(setup.controller.closedFileCount, 1)
        XCTAssertFalse(setup.controller.isApplyingFiles)
    }

    func testChangedFileKeepsEditsWithReason() async throws {
        let log = WriterLog()
        let setup = try await proposeClosed(["a.md"], writer: log)
        try Data("changed outside and longer".utf8).write(to: root.appendingPathComponent("a.md"))
        let task = try XCTUnwrap(setup.controller.applyToFiles())
        await task.value
        XCTAssertEqual(setup.controller.fileReport?.lines.first?.status, .skipped(.changed))
        let problem = try XCTUnwrap(setup.controller.editGroups.first?.edits.first?.problem)
        XCTAssertEqual(problem, .fileChanged)
        XCTAssertEqual(AIAgentController.reason(for: problem), L10n.tr("文件在磁盘上已被修改，建议已失效"))
        XCTAssertEqual(setup.controller.closedFileCount, 0)
        XCTAssertEqual(try read("a.md"), "changed outside and longer")
    }

    func testApplyDisabledWhileRunning() async throws {
        _ = try write("alpha a.md", to: "a.md")
        let document = EditorDocument(text: "open doc")
        let setup = try make([reply([closedArgs("a.md", "alpha", "ALPHA")]), .text("done")], documents: [document], confirm: { _ in true })
        _ = setup.state.folderWorkspace.setRoot(root)
        let gate = hold(setup.script, at: 1)
        setup.controller.draft = "Edit"
        setup.controller.send()
        _ = await waitFor { setup.controller.editGroups.first?.isClosedFile == true }
        XCTAssertTrue(setup.controller.isWorking)
        XCTAssertNil(setup.controller.applyToFiles())
        gate.yield()
        _ = await waitFor { !setup.controller.isWorking }
    }

    func testCancelBetweenFiles() async throws {
        let log = WriterLog()
        let box = TaskBox()
        // Вторая запись ждёт отмены, как долгая операция
        log.onCall = { name in
            if name == "b.md" { while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) } }
        }
        let setup = try await proposeClosed(["a.md", "b.md", "c.md"], writer: log)
        box.task = setup.controller.applyToFiles()
        _ = await waitFor { log.called.contains("b.md") }
        setup.controller.cancelFileApply()
        await box.task?.value
        XCTAssertEqual(log.called, ["a.md", "b.md"])
        XCTAssertEqual(try read("a.md"), "ALPHA a.md")
        XCTAssertEqual(try read("b.md"), "alpha b.md")
        XCTAssertEqual(try read("c.md"), "alpha c.md")
        XCTAssertEqual(setup.controller.fileReport?.isCancelled, true)
        XCTAssertEqual(setup.controller.editGroups.map(\.name), ["b.md", "c.md"])
        XCTAssertFalse(setup.controller.isApplyingFiles)
    }

    func testFileOpenedBeforeApplyMovesEdits() async throws {
        let log = WriterLog()
        let setup = try await proposeClosed(["a.md"], writer: log)
        let opened = EditorDocument(text: "alpha a.md")
        opened.url = root.appendingPathComponent("a.md")
        setup.state.documents.append(opened)
        XCTAssertNil(setup.controller.applyToFiles())
        XCTAssertTrue(log.called.isEmpty)
        XCTAssertEqual(try read("a.md"), "alpha a.md")
        XCTAssertEqual(setup.controller.editGroups.first?.isClosedFile, false)
        XCTAssertEqual(setup.controller.editGroups.first?.id, opened.id)
    }

    func testClosedAcceptCannotBeCalled() async throws {
        let setup = try await proposeClosed(["a.md"])
        let edit = try XCTUnwrap(setup.controller.editGroups.first?.edits.first)
        setup.controller.acceptEdit(edit.id)
        setup.controller.acceptAllEdits(in: edit.documentID)
        XCTAssertTrue(setup.editors[0].replacements.isEmpty)
        XCTAssertEqual(setup.controller.editGroups.first?.edits.count, 1)
        XCTAssertEqual(try read("a.md"), "alpha a.md")
    }
}

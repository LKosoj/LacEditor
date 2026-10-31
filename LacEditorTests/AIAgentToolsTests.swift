import XCTest
@testable import LacEditor

final class AIAgentToolsTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeData(_ data: Data, _ path: String) throws {
        try data.write(to: root.appendingPathComponent(path))
    }

    private func tools(open: [AIAgentOpenDocument] = [], folder: Bool = true) -> AIAgentTools {
        AIAgentTools(scope: AIAgentScope(root: folder ? root : nil, openDocuments: open))
    }

    private func call(_ tools: AIAgentTools, _ name: String, _ arguments: [String: Any]) async throws -> AIAgentToolOutcome {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try await tools.run(AIToolCall(id: "1", name: name, arguments: String(decoding: data, as: UTF8.self)))
    }

    private func json(_ outcome: AIAgentToolOutcome) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(outcome.output.utf8)) as? [String: Any])
    }

    private func assertError(_ outcome: AIAgentToolOutcome, _ code: AIAgentToolError, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try json(outcome)["error"] as? String, code.rawValue, file: file, line: line)
        XCTAssertEqual(outcome.journal.errorCode, code, file: file, line: line)
    }

    private func read(_ tools: AIAgentTools, _ path: String) async throws -> AIAgentToolOutcome {
        try await call(tools, "read_document", ["path": path, "from_line": NSNull(), "to_line": NSNull()])
    }

    // MARK: - Пути

    func testContentToolsRequireConsentOnlyForOpenDocumentsOutsideWorkspace() {
        let outside = AIAgentOpenDocument(id: UUID(), name: "outside.md", relativePath: nil, text: "secret", revision: 1)
        let inside = AIAgentOpenDocument(id: UUID(), name: "inside.md", relativePath: "inside.md", text: "workspace", revision: 1)
        let tools = tools(open: [outside, inside])
        for name in ["read_document", "document_outline", "document_links", "propose_edit"] {
            let externalCall = AIToolCall(id: "c", name: name, arguments: #"{"path":"open:\#(outside.id.uuidString)"}"#)
            XCTAssertEqual(tools.documentRequiringConsent(for: externalCall)?.id, outside.id, name)
            let workspaceCall = AIToolCall(id: "c", name: name, arguments: #"{"path":"open:\#(inside.id.uuidString)"}"#)
            XCTAssertNil(tools.documentRequiringConsent(for: workspaceCall), name)
        }
        let list = AIToolCall(id: "c", name: "list_documents", arguments: "{}")
        XCTAssertNil(tools.documentRequiringConsent(for: list))
    }

    func testEscapesAndAbsolutePathsAreRejected() async throws {
        try write("secret", "x.md")
        let tools = tools()
        for path in ["../x", "a/../../x", "a/../x.md", "/etc/hosts", "~/x", "a\\b", ""] {
            try await assertError(read(tools, path), .pathNotAllowed)
        }
    }

    func testHiddenComponentsAreRejected() async throws {
        try write("KEY=1", ".env")
        try write("[core]", ".git/config")
        try write("hidden", "a/.hidden/b.md")
        let tools = tools()
        for path in [".env", ".git/config", "a/.hidden/b.md"] { try await assertError(read(tools, path), .pathNotAllowed) }
    }

    func testSymbolicLinksAreRejectedAndNotSearched() async throws {
        try write("inside needle", "real.md")
        try write("dir needle", "dir/f.md")
        try "outside needle".write(to: outside.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("real.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: root.appendingPathComponent("dir"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ext.md"), withDestinationURL: outside.appendingPathComponent("o.md"))
        let tools = tools()
        for path in ["link.md", "linkdir/f.md", "ext.md"] { try await assertError(read(tools, path), .pathNotAllowed) }
        let found = try json(await call(tools, "search_text", ["query": "needle", "prefix": NSNull()]))
        let paths = (found["matches"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.sorted()
        XCTAssertEqual(paths, ["dir/f.md", "real.md"])
    }

    func testMissingFileDirectoryAndFIFO() async throws {
        try write("x", "dir/f.md")
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        let tools = tools()
        try await assertError(read(tools, "nope.md"), .notFound)
        try await assertError(read(tools, "dir"), .notRegularFile)
        try await assertError(read(tools, "pipe"), .notRegularFile)
    }

    func testNoFolderAndUnknownOpenAddress() async throws {
        let tools = tools(folder: false)
        try await assertError(read(tools, "a.md"), .noFolder)
        try await assertError(read(tools, "open:\(UUID().uuidString)"), .notFound)
        try await assertError(call(tools, "search_text", ["query": "x", "prefix": NSNull()]), .noFolder)
    }

    // MARK: - Чтение файлов

    func testBinaryAndEncodingFiles() async throws {
        try writeData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]), "a.png")
        try writeData(Data([0x61, 0x00, 0x62, 0x00]), "nul.txt")
        try writeData("привет".data(using: .windowsCP1251)!, "cp1251.txt")
        try writeData("привет".data(using: .utf16)!, "utf16.txt")
        let tools = tools()
        try await assertError(read(tools, "a.png"), .binary)
        try await assertError(read(tools, "nul.txt"), .binary)
        try await assertError(read(tools, "cp1251.txt"), .encodingRequired)
        try await assertError(read(tools, "utf16.txt"), .encodingRequired)
    }

    func testUTF8WithBOMIsRead() async throws {
        try writeData(Data([0xEF, 0xBB, 0xBF]) + Data("hello".utf8), "bom.md")
        let result = try json(await read(tools(), "bom.md"))
        XCTAssertEqual(result["lines"] as? [String], ["1\thello"])
    }

    func testLargeFileIsTooLargeAndSkippedInSearch() async throws {
        try writeData(Data(repeating: 0x61, count: 3 * 1_024 * 1_024), "big.txt")
        try write("small", "small.txt")
        let tools = tools()
        let failure = try await read(tools, "big.txt")
        try assertError(failure, .tooLarge)
        XCTAssertEqual(failure.journal.fileBytes, 3 * 1_024 * 1_024)
        let found = try json(await call(tools, "search_text", ["query": "mall", "prefix": NSNull()]))
        XCTAssertEqual((found["matches"] as? [[String: Any]])?.map { $0["path"] as? String }, ["small.txt"])
        XCTAssertEqual(found["skipped_files"] as? Int, 1)
    }

    func testReadLimitsAndRanges() async throws {
        try write((1...1000).map { "line \($0)" }.joined(separator: "\n"), "long.txt")
        let tools = tools()
        let first = try json(await read(tools, "long.txt"))
        XCTAssertEqual((first["lines"] as? [String])?.count, 400)
        XCTAssertEqual(first["total_lines"] as? Int, 1000)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        let range = try json(await call(tools, "read_document", ["path": "long.txt", "from_line": 10, "to_line": 12]))
        XCTAssertEqual(range["lines"] as? [String], ["10\tline 10", "11\tline 11", "12\tline 12"])
        XCTAssertEqual(range["has_more"] as? Bool, true)
        let tail = try json(await call(tools, "read_document", ["path": "long.txt", "from_line": 999, "to_line": NSNull()]))
        XCTAssertEqual(tail["has_more"] as? Bool, false)
        let omitted = try json(await call(tools, "read_document", ["path": "long.txt"]))
        XCTAssertEqual(omitted["from_line"] as? Int, 1)
    }

    func testOutputStaysUnderLimit() async throws {
        try write((1...400).map { _ in String(repeating: "я", count: 100) }.joined(separator: "\n"), "wide.txt")
        let outcome = try await read(tools(), "wide.txt")
        XCTAssertLessThanOrEqual(outcome.output.utf8.count, AIAgentToolLimits.outputBytes)
        XCTAssertTrue(outcome.journal.truncated)
    }

    func testJournalOfRead() async throws {
        try write("abc\ndef", "j.md")
        let outcome = try await read(tools(), "j.md")
        XCTAssertEqual(outcome.journal.kind, .readDocument)
        XCTAssertEqual(outcome.journal.files, [AIAgentJournalFile(path: "j.md", name: "j.md", bytes: 6, source: .disk)])
        XCTAssertEqual(outcome.journal.fileBytes, 7)
        XCTAssertEqual(outcome.journal.sentBytes, outcome.output.utf8.count)
    }

    // MARK: - Несохранённый текст

    func testUnsavedTextWinsInReadSearchAndLinks() async throws {
        try write("disk text\n", "note.md")
        try write("[[note]]", "other.md")
        let document = AIAgentOpenDocument(id: UUID(), name: "note.md", relativePath: "note.md", text: "unsaved text\n#tagx [[other]]", revision: 3)
        let tools = tools(open: [document])
        let result = try json(await read(tools, "note.md"))
        XCTAssertEqual((result["lines"] as? [String])?.first, "1\tunsaved text")
        let found = try json(await call(tools, "search_text", ["query": "unsaved", "prefix": NSNull()]))
        XCTAssertEqual((found["matches"] as? [[String: Any]])?.first?["path"] as? String, "note.md")
        XCTAssertEqual((found["matches"] as? [[String: Any]])?.first?["line"] as? Int, 1)
        let none = try json(await call(tools, "search_text", ["query": "disk text", "prefix": NSNull()]))
        XCTAssertEqual((none["matches"] as? [Any])?.count, 0)
        let links = try json(await call(tools, "document_links", ["path": "note.md"]))
        XCTAssertEqual((links["outgoing"] as? [[String: Any]])?.first?["resolved_path"] as? String, "other.md")
        XCTAssertEqual(links["tags"] as? [String], ["tagx"])
        XCTAssertEqual((links["backlinks"] as? [[String: Any]])?.first?["path"] as? String, "other.md")
        let outcome = try await call(tools, "read_document", ["path": "note.md", "from_line": NSNull(), "to_line": NSNull()])
        XCTAssertEqual(outcome.journal.files.first?.source, .unsaved)
    }

    func testDocumentOutsideRootIsAvailableOnlyByOpenAddress() async throws {
        let document = AIAgentOpenDocument(id: UUID(), name: "Draft", relativePath: nil, text: "# Title\nbody", revision: 1)
        let tools = tools(open: [document])
        let address = "open:\(document.id.uuidString)"
        let result = try json(await read(tools, address))
        XCTAssertEqual((result["lines"] as? [String])?.first, "1\t# Title")
        let links = try json(await call(tools, "document_links", ["path": address]))
        XCTAssertTrue(links["backlinks"] is NSNull)
        let listing = try json(await call(tools, "list_documents", ["prefix": NSNull()]))
        XCTAssertEqual((listing["open_documents"] as? [[String: Any]])?.first?["id"] as? String, address)
        let found = try json(await call(tools, "search_text", ["query": "body", "prefix": NSNull()]))
        XCTAssertEqual((found["matches"] as? [Any])?.count, 0)
    }

    func testHiddenOpenDocumentIsInvisible() async throws {
        let document = AIAgentOpenDocument(id: UUID(), name: ".env", relativePath: ".env", text: "KEY=1", revision: 1)
        let tools = tools(open: [document])
        try await assertError(read(tools, "open:\(document.id.uuidString)"), .notFound)
        let listing = try json(await call(tools, "list_documents", ["prefix": NSNull()]))
        XCTAssertEqual((listing["open_documents"] as? [Any])?.count, 0)
    }

    // MARK: - list_documents, search_text, outline

    func testListAndSearchWithPrefixAndJournal() async throws {
        try write("alpha", "a/one.md")
        try write("alpha", "b/two.md")
        try write("alpha", ".hidden/three.md")
        let tools = tools()
        let listing = try await call(tools, "list_documents", ["prefix": "a"])
        XCTAssertEqual((try json(listing)["files"] as? [[String: Any]])?.map { $0["path"] as? String }, ["a/one.md"])
        XCTAssertEqual(listing.journal.files.map(\.name), ["one.md"])
        let found = try await call(tools, "search_text", ["query": "ALPHA", "prefix": NSNull()])
        XCTAssertEqual(found.journal.files.map(\.path).sorted(), ["a/one.md", "b/two.md"])
        XCTAssertTrue(found.journal.files.allSatisfy { $0.bytes > 0 })
        XCTAssertEqual(found.journal.subject, "ALPHA")
        try await assertError(call(tools, "list_documents", ["prefix": ".hidden"]), .pathNotAllowed)
    }

    func testOutline() async throws {
        try write("# One\ntext\n## Two\n", "o.md")
        let result = try json(await call(tools(), "document_outline", ["path": "o.md"]))
        let headings = try XCTUnwrap(result["headings"] as? [[String: Any]])
        XCTAssertEqual(headings.map { $0["title"] as? String }, ["One", "Two"])
        XCTAssertEqual(headings.map { $0["line"] as? Int }, [1, 3])
        XCTAssertEqual(headings.map { $0["level"] as? Int }, [1, 2])
    }

    // MARK: - Аргументы

    func testBadArgumentsAndUnknownToolAreOutcomes() async throws {
        let tools = tools()
        try await assertError(call(tools, "nope", [:]), .unknownTool)
        try await assertError(call(tools, "search_text", ["query": "", "prefix": NSNull()]), .badArguments)
        try await assertError(call(tools, "search_text", ["query": 5]), .badArguments)
        try await assertError(call(tools, "read_document", ["path": "a", "extra": 1]), .badArguments)
        try await assertError(call(tools, "read_document", ["path": "a", "from_line": 5, "to_line": 2]), .badArguments)
        try await assertError(call(tools, "read_document", ["path": "a", "from_line": 0]), .badArguments)
        try await assertError(call(tools, "read_document", ["path": "a", "from_line": 1.5]), .badArguments)
        try await assertError(call(tools, "read_document", ["path": "a", "from_line": true]), .badArguments)
        let rejected = try await call(tools, "document_outline", [:])
        XCTAssertEqual(rejected.journal.kind, .rejected)
        let broken = try await tools.run(AIToolCall(id: "1", name: "list_documents", arguments: "{"))
        try assertError(broken, .badArguments)
    }

    func testSchemasAreStrict() throws {
        XCTAssertEqual(AIAgentTools.definitions.map(\.name), ["list_documents", "search_text", "read_document", "document_outline", "document_links", "propose_edit", "update_plan"])
        for definition in AIAgentTools.definitions {
            let properties = try XCTUnwrap(definition.parameters["properties"] as? [String: Any])
            XCTAssertEqual(Set(try XCTUnwrap(definition.parameters["required"] as? [String])), Set(properties.keys), definition.name)
            XCTAssertEqual(definition.parameters["additionalProperties"] as? Bool, false, definition.name)
        }
        let plan = try XCTUnwrap(AIAgentTools.definitions.last)
        let items = try XCTUnwrap((plan.parameters["properties"] as? [String: Any])?["items"] as? [String: Any])
        let element = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(element["required"] as? [String])), ["title", "status"])
        XCTAssertEqual(element["additionalProperties"] as? Bool, false)
    }

    // MARK: - update_plan

    private func planTools(_ store: AIAgentPlanStore) -> AIAgentTools {
        AIAgentTools(scope: AIAgentScope(root: root, openDocuments: []), plan: store)
    }

    private func items(_ count: Int, status: String = "pending") -> [[String: Any]] {
        (0..<count).map { ["title": "step \($0)", "status": status] }
    }

    func testUpdatePlanStoresReplacesAndRepeats() async throws {
        let store = AIAgentPlanStore()
        let tools = planTools(store)
        let args: [String: Any] = ["items": [["title": "a", "status": "done"], ["title": "b", "status": "in_progress"], ["title": "c", "status": "pending"]],
                                   "notes": "glossary"]
        let first = try await call(tools, "update_plan", args)
        XCTAssertEqual(first.journal.kind, .updatePlan)
        XCTAssertEqual(first.journal.subject, "1/3")
        XCTAssertNil(first.journal.errorCode)
        let result = try json(first)
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["items"] as? Int, 3)
        XCTAssertEqual(result["done"] as? Int, 1)
        XCTAssertEqual(result["in_progress"] as? Int, 1)
        XCTAssertEqual(result["notes_bytes"] as? Int, 8)
        let saved = store.current
        _ = try await call(tools, "update_plan", args)
        XCTAssertEqual(store.current, saved)
        _ = try await call(tools, "update_plan", ["items": [["title": "only", "status": "pending"]], "notes": NSNull()])
        XCTAssertEqual(store.current.items.map(\.title), ["only"])
        XCTAssertEqual(store.current.notes, "glossary")
    }

    func testUpdatePlanNotesRules() async throws {
        let store = AIAgentPlanStore()
        let tools = planTools(store)
        _ = try await call(tools, "update_plan", ["items": items(1), "notes": "one  \n"])
        XCTAssertEqual(store.current.notes, "one")
        _ = try await call(tools, "update_plan", ["items": items(1)])
        XCTAssertEqual(store.current.notes, "one")
        _ = try await call(tools, "update_plan", ["items": items(1), "notes": "two"])
        XCTAssertEqual(store.current.notes, "two")
        _ = try await call(tools, "update_plan", ["items": [] as [[String: Any]], "notes": ""])
        XCTAssertTrue(store.current.isEmpty)
    }

    func testUpdatePlanErrorsDoNotChangeStore() async throws {
        let store = AIAgentPlanStore()
        let tools = planTools(store)
        _ = try await call(tools, "update_plan", ["items": items(2), "notes": "keep"])
        let before = store.current
        let bad: [(String, [String: Any], AIAgentToolError)] = [
            ("no items", ["notes": "x"], .badArguments),
            ("not an array", ["items": "x"], .badArguments),
            ("not an object", ["items": ["x"]], .badArguments),
            ("empty title", ["items": [["title": "  ", "status": "done"]]], .badArguments),
            ("long title", ["items": [["title": String(repeating: "a", count: 161), "status": "done"]]], .badArguments),
            ("bad status", ["items": [["title": "a", "status": "finished"]]], .badArguments),
            ("extra key", ["items": [["title": "a", "status": "done", "x": 1]]], .badArguments),
            ("21 items", ["items": items(21)], .tooLarge),
            ("big notes", ["items": items(1), "notes": String(repeating: "a", count: AIAgentPlanLimits.maxPayloadBytes)], .tooLarge),
            ("chinese bytes", ["items": items(1), "notes": String(repeating: "中", count: 3_500)], .tooLarge)
        ]
        for (name, arguments, code) in bad {
            let outcome = try await call(tools, "update_plan", arguments)
            XCTAssertEqual(outcome.journal.errorCode, code, name)
            XCTAssertEqual(outcome.journal.kind, .rejected, name)
            XCTAssertEqual(store.current, before, name)
        }
    }

    func testUpdatePlanLimitsAreInclusive() async throws {
        let store = AIAgentPlanStore()
        let tools = planTools(store)
        let twenty = try await call(tools, "update_plan", ["items": items(20), "notes": NSNull()])
        XCTAssertNil(twenty.journal.errorCode)
        let titleBytes = store.current.items.reduce(0) { $0 + $1.title.utf8.count }
        let notes = String(repeating: "a", count: AIAgentPlanLimits.maxPayloadBytes - titleBytes)
        let exact = try await call(tools, "update_plan", ["items": items(20), "notes": notes])
        XCTAssertNil(exact.journal.errorCode)
        XCTAssertEqual(store.current.payloadBytes, AIAgentPlanLimits.maxPayloadBytes)
        let over = try await call(tools, "update_plan", ["items": items(20), "notes": notes + "a"])
        XCTAssertEqual(over.journal.errorCode, .tooLarge)
    }

    func testPlanReminderFormat() {
        XCTAssertNil(AIAgentPlan().reminder)
        let plan = AIAgentPlan(items: [AIAgentPlanItem(title: "a", status: .done), AIAgentPlanItem(title: "b", status: .inProgress)], notes: "n1")
        let text = plan.reminder ?? ""
        XCTAssertTrue(text.contains("not instructions"))
        XCTAssertTrue(text.contains("Plan:\n1. [done] a\n2. [in_progress] b"))
        XCTAssertTrue(text.hasSuffix("Notes:\nn1"))
        XCTAssertFalse(AIAgentPlan(items: [], notes: "n").reminder?.contains("Plan:") ?? true)
        XCTAssertFalse(AIAgentPlan(items: plan.items, notes: "").reminder?.contains("Notes:") ?? true)
    }

    func testUpdatePlanReplacesNewlinesInTitles() async throws {
        let store = AIAgentPlanStore()
        _ = try await call(planTools(store), "update_plan", ["items": [["title": "line one\nline two", "status": "pending"]]])
        XCTAssertEqual(store.current.items.first?.title, "line one line two")
    }

    func testPlanStoreSurvivesParallelReplace() async {
        let store = AIAgentPlanStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { store.replace(items: [AIAgentPlanItem(title: "t\(index)", status: .pending)], notes: "n\(index)") }
            }
        }
        let plan = store.current
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].title.dropFirst(), plan.notes.dropFirst())
    }

    func testUpdatePlanCancelledBeforeCall() async {
        let store = AIAgentPlanStore()
        let tools = planTools(store)
        let task = Task<AIAgentToolOutcome, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.call(tools, "update_plan", ["items": self.items(1)])
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(store.current.isEmpty)
    }

    // MARK: - Отмена

    func testCancellationBeforeAndDuringWork() async throws {
        for index in 0..<200 { try write("needle \(index)", "d\(index % 10)/f\(index).md") }
        let tools = tools()
        let before = Task<AIAgentToolOutcome, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.call(tools, "search_text", ["query": "needle", "prefix": NSNull()])
        }
        do { _ = try await before.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let during = Task<AIAgentToolOutcome, Error> { try await self.call(tools, "search_text", ["query": "needle", "prefix": NSNull()]) }
        during.cancel()
        do { _ = try await during.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }
}

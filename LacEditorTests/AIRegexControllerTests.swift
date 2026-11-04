import XCTest
@preconcurrency @testable import LacEditor

@MainActor
final class AIRegexControllerTests: XCTestCase {
    nonisolated private static let goodResponse = #"{"pattern":"\\d+","caseSensitive":true,"explanation":"Числа"}"#
    private static let goodResult = AIRegexBuilder.Result(pattern: #"\d+"#, caseSensitive: true, explanation: "Числа")

    private final class Box: @unchecked Sendable {
        var calls = 0
        var inputs: [String] = []
        var profiles: [AIModelProfile] = []
        var pending: [CheckedContinuation<String, Error>] = []
        var response: String? = AIRegexControllerTests.goodResponse
        var failure: Error?
        var keyRoles: [AIRole] = []
        var keyURLs: [String] = []
        var key: () throws -> String? = { "key" }
        var applied: [AIRegexBuilder.Result] = []
    }

    private struct Environment {
        let state: AppState
        let preferences: AppPreferences
        let controller: AIRegexController
        let box: Box
        let cleanup: () -> Void
    }

    /// response == nil: ответ зависает, пока тест не вызовет resume.
    private func makeEnvironment(hold: Bool = false) throws -> Environment {
        let suite = "LacEditor-AIRegex-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.api = .chatCompletions
        configuration.text.modelID = "text-model"
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "SECRET DOCUMENT TEXT")
        let state = AppState(initialDocuments: [document], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        state.selectedDocumentID = document.id
        let box = Box()
        if hold { box.response = nil }
        let controller = makeController(state: state, box: box)
        return Environment(state: state, preferences: preferences, controller: controller, box: box,
                           cleanup: { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeController(state: AppState, box: Box) -> AIRegexController {
        AIRegexController(
            appState: state,
            generate: { input, profile, _ in
                box.calls += 1
                box.inputs.append(input)
                box.profiles.append(profile)
                if let failure = box.failure { throw failure }
                if let response = box.response { return response }
                return try await withCheckedThrowingContinuation { box.pending.append($0) }
            },
            loadKey: { role, url in
                box.keyRoles.append(role)
                box.keyURLs.append(url)
                return try box.key()
            })
    }

    private func settle(_ controller: AIRegexController) async {
        for _ in 0..<400 {
            if !controller.isWorking { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("запрос не завершился")
    }

    private func waitForPending(_ box: Box, _ count: Int) async {
        for _ in 0..<400 {
            if box.pending.count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("запрос не дошёл до модели")
    }

    private func drain() async { try? await Task.sleep(nanoseconds: 50_000_000) }

    private func start(_ environment: Environment, phrase: String = "числа", target: AIRegexController.Target = .findBar) {
        let box = environment.box
        environment.controller.start(phrase: phrase, target: target) { box.applied.append($0) }
    }

    // MARK: Доступность и профиль

    func testIsAvailableTable() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let preferences = environment.preferences
        let original = preferences.aiConfiguration
        XCTAssertTrue(AIRegexController.isAvailable(preferences: preferences))
        var configuration = original
        configuration.text.isEnabled = false
        preferences.aiConfiguration = configuration
        XCTAssertFalse(AIRegexController.isAvailable(preferences: preferences))
        for model in ["", "   "] {
            configuration = original
            configuration.text.modelID = model
            preferences.aiConfiguration = configuration
            XCTAssertFalse(AIRegexController.isAvailable(preferences: preferences), "модель «\(model)»")
        }
        configuration = original
        configuration.text.modelID = ""
        preferences.aiConfiguration = configuration
        preferences.aiFeatureModelIDs[AppPreferences.regexBuilderModelKey] = "regex-model"
        XCTAssertTrue(AIRegexController.isAvailable(preferences: preferences))
        preferences.aiFeatureModelIDs.removeValue(forKey: AppPreferences.regexBuilderModelKey)
        for api in [AIAPIProtocol.images, .transcriptions] {
            configuration = original
            configuration.text.api = api
            preferences.aiConfiguration = configuration
            XCTAssertFalse(AIRegexController.isAvailable(preferences: preferences), api.rawValue)
        }
        configuration = original
        configuration.text.api = .responses
        preferences.aiConfiguration = configuration
        XCTAssertTrue(AIRegexController.isAvailable(preferences: preferences))
    }

    func testRegexBuilderProfileUsesTextProfileAndOwnModel() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let preferences = environment.preferences
        XCTAssertEqual(preferences.regexBuilderProfile().modelID, "text-model")
        let clarityBefore = preferences.aiProfile(for: .clarity)
        preferences.aiFeatureModelIDs[AppPreferences.regexBuilderModelKey] = "  regex-model "
        let profile = preferences.regexBuilderProfile()
        XCTAssertEqual(profile.modelID, "regex-model")
        XCTAssertEqual(profile.baseURL, preferences.aiConfiguration.text.baseURL)
        XCTAssertEqual(profile.api, preferences.aiConfiguration.text.api)
        XCTAssertEqual(preferences.aiProfile(for: .clarity), clarityBefore)
        preferences.aiFeatureModelIDs[AppPreferences.voiceCleanupModelKey] = "cleanup-model"
        XCTAssertEqual(preferences.regexBuilderProfile().modelID, "regex-model")
        XCTAssertEqual(preferences.voiceCleanupProfile().modelID, "cleanup-model")
    }

    // MARK: Успех и запрос

    func testSuccessAppliesOnceAndShowsExplanation() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        start(environment)
        XCTAssertTrue(environment.controller.isWorking)
        await settle(environment.controller)
        XCTAssertEqual(environment.box.applied, [Self.goodResult])
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .success, text: "Числа"))
        XCTAssertEqual(environment.controller.target, .findBar)
    }

    func testEmptyExplanationUsesDefaultText() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.response = #"{"pattern":"abc"}"#
        start(environment)
        await settle(environment.controller)
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .success, text: L10n.tr("已生成正则表达式")))
    }

    func testRequestContainsOnlyPhraseAndUsesRegexModel() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.preferences.aiFeatureModelIDs[AppPreferences.regexBuilderModelKey] = "regex-model"
        start(environment, phrase: "  числа  ")
        await settle(environment.controller)
        XCTAssertEqual(environment.box.calls, 1)
        XCTAssertEqual(environment.box.inputs, ["числа"])
        XCTAssertFalse(environment.box.inputs.joined().contains("SECRET"))
        XCTAssertEqual(environment.box.profiles.first?.modelID, "regex-model")
        XCTAssertEqual(environment.box.keyRoles.first, .text)
        XCTAssertEqual(environment.box.keyURLs.first, environment.preferences.aiConfiguration.text.baseURL)
    }

    func testNilKeyIsAllowed() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.key = { nil }
        start(environment)
        await settle(environment.controller)
        XCTAssertEqual(environment.box.calls, 1)
        XCTAssertEqual(environment.box.applied, [Self.goodResult])
    }

    func testKeychainErrorShowsMessageAndSendsNothing() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.key = { throw AIError.keychain }
        start(environment)
        await settle(environment.controller)
        XCTAssertEqual(environment.box.calls, 0)
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .error, text: AIError.keychain.errorDescription ?? ""))
        XCTAssertTrue(environment.box.applied.isEmpty)
    }

    // MARK: Ошибки

    func testInvalidPatternKeepsQueryAndShowsError() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.response = #"{"pattern":"(abc"}"#
        start(environment)
        await settle(environment.controller)
        XCTAssertTrue(environment.box.applied.isEmpty)
        XCTAssertEqual(environment.controller.message,
                       StatusMessage(kind: .error, text: L10n.tr("AI 生成的正则表达式无效，请换一种说法再试")))
    }

    func testDeclinedShowsModelExplanation() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.response = #"{"pattern":"","explanation":"Так нельзя"}"#
        start(environment)
        await settle(environment.controller)
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .error, text: "Так нельзя"))
        environment.box.response = #"{"pattern":""}"#
        start(environment)
        await settle(environment.controller)
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .error, text: AIError.invalidResponse.errorDescription ?? ""))
        XCTAssertTrue(environment.box.applied.isEmpty)
    }

    func testInvalidJSONShowsInvalidResponse() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.response = "not JSON"
        start(environment)
        await settle(environment.controller)
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .error, text: AIError.invalidResponse.errorDescription ?? ""))
        XCTAssertTrue(environment.box.applied.isEmpty)
    }

    func testHTTPErrorShowsLocalizedDescriptionWithoutRetry() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let error = AIError.http(500, "x")
        environment.box.failure = error
        start(environment)
        await settle(environment.controller)
        await drain()
        XCTAssertEqual(environment.box.calls, 1)
        XCTAssertEqual(environment.controller.message, StatusMessage(kind: .error, text: error.errorDescription ?? ""))
    }

    func testCancellationErrorIsSilent() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.failure = CancellationError()
        start(environment)
        await settle(environment.controller)
        XCTAssertNil(environment.controller.message)
        XCTAssertFalse(environment.controller.isWorking)
    }

    func testEmptyOrWhitespacePhraseDoesNotStart() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        for phrase in ["", "  \n "] { start(environment, phrase: phrase) }
        XCTAssertFalse(environment.controller.isWorking)
        await drain()
        XCTAssertEqual(environment.box.calls, 0)
    }

    // MARK: Отмена и актуальность

    func testCancelDropsLateResult() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment)
        await waitForPending(environment.box, 1)
        environment.controller.cancel()
        XCTAssertFalse(environment.controller.isWorking)
        environment.box.pending[0].resume(returning: Self.goodResponse)
        await drain()
        XCTAssertTrue(environment.box.applied.isEmpty)
        XCTAssertNil(environment.controller.message)
        XCTAssertFalse(environment.controller.isWorking)
    }

    func testCancelResetsMessage() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.failure = AIError.network
        start(environment)
        await settle(environment.controller)
        XCTAssertNotNil(environment.controller.message)
        environment.controller.cancel()
        XCTAssertNil(environment.controller.message)
    }

    func testNewStartSupersedesOldRequest() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment, phrase: "первое")
        await waitForPending(environment.box, 1)
        start(environment, phrase: "второе")
        await waitForPending(environment.box, 2)
        environment.box.pending[1].resume(returning: #"{"pattern":"second"}"#)
        await settle(environment.controller)
        environment.box.pending[0].resume(returning: #"{"pattern":"first"}"#)
        await drain()
        XCTAssertEqual(environment.box.applied.map(\.pattern), ["second"])
    }

    func testStartForOtherTargetCancelsFirst() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment, target: .findBar)
        await waitForPending(environment.box, 1)
        start(environment, target: .folderSearch)
        await waitForPending(environment.box, 2)
        XCTAssertEqual(environment.controller.target, .folderSearch)
        environment.box.pending[0].resume(returning: #"{"pattern":"first"}"#)
        environment.box.pending[1].resume(returning: #"{"pattern":"second"}"#)
        await settle(environment.controller)
        await drain()
        XCTAssertEqual(environment.box.applied.map(\.pattern), ["second"])
        XCTAssertEqual(environment.controller.target, .folderSearch)
    }

    func testQueryEditCancelsRequest() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment)
        await waitForPending(environment.box, 1)
        environment.controller.queryEdited("другое", target: .findBar)
        XCTAssertFalse(environment.controller.isWorking)
        environment.box.pending[0].resume(returning: Self.goodResponse)
        await drain()
        XCTAssertTrue(environment.box.applied.isEmpty)
        XCTAssertNil(environment.controller.message)
    }

    func testQueryEqualToAppliedPatternKeepsMessage() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        start(environment)
        await settle(environment.controller)
        environment.controller.queryEdited(Self.goodResult.pattern, target: .findBar)
        XCTAssertNotNil(environment.controller.message)
        environment.controller.queryEdited("другое", target: .findBar)
        XCTAssertNil(environment.controller.message)
    }

    func testQueryEditForOtherTargetIsIgnored() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment, target: .folderSearch)
        await waitForPending(environment.box, 1)
        environment.controller.queryEdited("другое", target: .findBar)
        XCTAssertTrue(environment.controller.isWorking)
        environment.box.pending[0].resume(returning: Self.goodResponse)
        await settle(environment.controller)
        XCTAssertEqual(environment.box.applied, [Self.goodResult])
    }

    func testProfileChangeDuringRequestDropsResult() async throws {
        for change in [{ (c: inout AIConfiguration) in c.text.modelID = "other" },
                       { (c: inout AIConfiguration) in c.text.baseURL = "https://example.com/v1" }] {
            let environment = try makeEnvironment(hold: true)
            defer { environment.cleanup() }
            start(environment)
            await waitForPending(environment.box, 1)
            var configuration = environment.preferences.aiConfiguration
            change(&configuration)
            environment.preferences.aiConfiguration = configuration
            environment.box.pending[0].resume(returning: Self.goodResponse)
            await settle(environment.controller)
            XCTAssertTrue(environment.box.applied.isEmpty)
            XCTAssertNil(environment.controller.message)
        }
    }

    func testRegexModelChangeDuringRequestDropsResult() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment)
        await waitForPending(environment.box, 1)
        environment.preferences.aiFeatureModelIDs[AppPreferences.regexBuilderModelKey] = "regex-model"
        environment.box.pending[0].resume(returning: Self.goodResponse)
        await settle(environment.controller)
        XCTAssertTrue(environment.box.applied.isEmpty)
        XCTAssertNil(environment.controller.message)
    }

    func testKeyChangeDuringRequestDropsResult() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        // loadKey записывает адрес до вызова key, поэтому число записей равно номеру чтения.
        environment.box.key = { [box = environment.box] in box.keyURLs.count == 1 ? "first" : "second" }
        start(environment)
        await waitForPending(environment.box, 1)
        environment.box.pending[0].resume(returning: Self.goodResponse)
        await settle(environment.controller)
        XCTAssertTrue(environment.box.applied.isEmpty)
        XCTAssertNil(environment.controller.message)
    }

    func testWindowClosedCancels() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        start(environment)
        await waitForPending(environment.box, 1)
        environment.controller.windowClosed()
        XCTAssertFalse(environment.controller.isWorking)
        environment.box.pending[0].resume(returning: Self.goodResponse)
        await drain()
        XCTAssertTrue(environment.box.applied.isEmpty)
    }

    func testDismissFindReplaceCancels() async throws {
        let environment = try makeEnvironment(hold: true)
        defer { environment.cleanup() }
        environment.state.aiRegex = makeController(state: environment.state, box: environment.box)
        let box = environment.box
        environment.state.aiRegex.start(phrase: "числа", target: .findBar) { box.applied.append($0) }
        await waitForPending(box, 1)
        environment.state.dismissFindReplace()
        XCTAssertFalse(environment.state.aiRegex.isWorking)
        box.pending[0].resume(returning: Self.goodResponse)
        await drain()
        XCTAssertTrue(box.applied.isEmpty)
    }
}

import Combine
import XCTest
@testable import LacEditor

@MainActor
final class DocumentMetricsTaskTests: XCTestCase {
    func testCancellationBeforeTaskAttachmentCancelsLateTask() {
        let coordinator = DocumentTaskCoordinator()
        let generation = coordinator.begin(.metrics)
        coordinator.cancel(.metrics)
        let task = Task<Void, Never> {}
        coordinator.attachTask(task, kind: .metrics, generation: generation)
        XCTAssertTrue(task.isCancelled)
    }

    func testLateTaskDoesNotReplaceCurrentCancellation() {
        let coordinator = DocumentTaskCoordinator()
        let oldGeneration = coordinator.begin(.metrics)
        let generation = coordinator.begin(.metrics)
        let current = Task<Void, Never> {}
        coordinator.attachTask(current, kind: .metrics, generation: generation)
        let old = Task<Void, Never> {}
        coordinator.attachTask(old, kind: .metrics, generation: oldGeneration)
        XCTAssertTrue(old.isCancelled)
        XCTAssertFalse(current.isCancelled)
        coordinator.cancel(.metrics)
        XCTAssertTrue(current.isCancelled)
    }

    func testOnlyLatestTextIsCounted() async {
        let document = EditorDocument()
        let updated = expectation(description: "latest count")
        let subscription = document.$wordCount.dropFirst().sink { count in
            if count == 100_001 { updated.fulfill() }
            else { XCTFail("Unexpected count: \(count)") }
        }
        document.text = String(repeating: "a", count: 100_000)
        document.text = String(repeating: "中", count: 100_000) + "😀"
        await fulfillment(of: [updated], timeout: 5)
        withExtendedLifetime(subscription) {}
    }

    func testCancelBeforeDelayAndResumeRetainedDocument() async {
        let document = EditorDocument()
        let unexpected = expectation(description: "cancelled count")
        unexpected.isInverted = true
        let subscription = document.$wordCount.dropFirst().sink { _ in unexpected.fulfill() }
        document.text = String(repeating: "a", count: 100_000)
        document.cancelMetricsRefresh()
        await fulfillment(of: [unexpected], timeout: 0.8)
        XCTAssertEqual(document.wordCount, 0)
        subscription.cancel()

        let resumed = expectation(description: "resumed count")
        let resumedSubscription = document.$wordCount.dropFirst().sink { count in
            if count == 100_000 { resumed.fulfill() }
        }
        document.resumeMetricsRefresh()
        await fulfillment(of: [resumed], timeout: 5)
        withExtendedLifetime(resumedSubscription) {}
    }

    func testLargeProfileAndManualOverride() async {
        let document = EditorDocument(text: String(repeating: "a", count: 100_000), performanceProfile: .large)
        XCTAssertEqual(document.wordCount, 0)
        let updated = expectation(description: "manual count")
        let subscription = document.$wordCount.dropFirst().sink { count in
            if count == 100_000 { updated.fulfill() }
        }
        document.setOverride(true, for: .wordCount)
        await fulfillment(of: [updated], timeout: 5)
        document.setOverride(false, for: .wordCount)
        XCTAssertEqual(document.wordCount, 0)
        withExtendedLifetime(subscription) {}
    }
}

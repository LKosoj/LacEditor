import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class StatusBarStatisticsTests: XCTestCase {
    private struct SelectedStatus: View {
        @EnvironmentObject var state: AppState
        var body: some View {
            if let document = state.selectedDocument { StatusBarView(document: document) }
        }
    }

    func testUnchangedReadingSpeedAppliesWhenHostedDocumentChanges() async throws {
        _ = NSApplication.shared
        let suite = "LacEditorTests.StatusBarStatistics.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.readingWordsPerMinute = 100
        let text = Array(repeating: "word", count: 201).joined(separator: " ")
        let first = EditorDocument(text: text), second = EditorDocument(text: text)
        let state = AppState(initialDocuments: [first, second], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { first.cancelMetricsRefresh(); second.cancelMetricsRefresh(); window.close() }
        let firstReady = expectation(description: "first document uses configured speed")
        let firstSubscription = first.$statistics.dropFirst().sink { value in
            if value?.readingMinutes == 3 { firstReady.fulfill() }
        }
        window.contentViewController = NSHostingController(rootView: SelectedStatus().environmentObject(state))
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [firstReady], timeout: 5)
        firstSubscription.cancel()
        let secondReady = expectation(description: "new document inherits unchanged speed")
        let secondSubscription = second.$statistics.dropFirst().sink { value in
            if value?.readingMinutes == 3 { secondReady.fulfill() }
        }
        state.selectedDocumentID = second.id
        await fulfillment(of: [secondReady], timeout: 5)
        XCTAssertEqual(preferences.readingWordsPerMinute, 100)
        XCTAssertEqual(second.statistics?.readingMinutes, 3)
        withExtendedLifetime(secondSubscription) {}
    }
}

import AppKit
import Foundation

/// Optional smoke check for the actual packaged application, not the XCTest
/// host. Refuses to touch an experiment instance the user already has open.
@main
struct UIExperimentLaunchVerification {
    enum Failure: Error {
        case invalidBundle, alreadyRunning, terminatedEarly, missingDataDirectory, quitFailed
    }

    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.invalidBundle }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let identifier = "com.laceditor.ui-experiment"
        guard Bundle(url: url)?.bundleIdentifier == identifier else { throw Failure.invalidBundle }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            throw Failure.alreadyRunning
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try await Task.sleep(for: .seconds(2))
        guard !app.isTerminated else { throw Failure.terminatedEarly }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: false)
        let isolated = support.appendingPathComponent("LacEditor-UI-Experiment")
        let hasIsolatedData = FileManager.default.fileExists(atPath: isolated.path)
        guard app.terminate() else { throw Failure.quitFailed }
        for _ in 0..<100 {
            if app.isTerminated { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard app.isTerminated else { throw Failure.quitFailed }
        guard hasIsolatedData else { throw Failure.missingDataDirectory }
        print("UI experiment launch and graceful quit passed; isolated Application Support exists.")
    }
}

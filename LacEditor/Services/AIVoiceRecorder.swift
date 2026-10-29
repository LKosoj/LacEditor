import AVFoundation
import Combine
import Foundation

@MainActor
final class AIVoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    private var recorder: AVAudioRecorder?
    private(set) var recordingURL: URL?
    private let requestPermission: () async -> Bool

    init(requestPermission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.requestPermission = requestPermission
    }

    func start() async throws {
        let allowed = await requestPermission()
        try Task.checkCancellation()
        guard allowed else { throw NSError(domain: "AIVoiceRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("无法访问麦克风。")]) }
        discard()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
        guard recorder.record() else { try? FileManager.default.removeItem(at: url); throw AIError.invalidResponse }
        self.recorder = recorder
        recordingURL = url
        isRecording = true
        startedAt = Date()
    }

    func stop() -> URL? {
        guard isRecording else { return recordingURL }
        recorder?.stop()
        recorder = nil
        isRecording = false
        startedAt = nil
        return recordingURL
    }

    func discard() {
        recorder?.stop(); recorder = nil; isRecording = false; startedAt = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    deinit {
        recorder?.stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
    }
}

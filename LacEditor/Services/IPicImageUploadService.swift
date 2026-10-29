import Foundation

/// iPicUploader uses one named pasteboard; keep its requests sequential.
@MainActor
enum IPicImageUploadService {
    typealias Start = (MarkdownImageUploadService.Payload, @escaping (String?, NSError?) -> Void) -> Void
    private static var busy = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    private static func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private static func release() {
        if waiting.isEmpty { busy = false }
        else { waiting.removeFirst().resume() }
    }

    static func upload(_ payload: MarkdownImageUploadService.Payload, start: Start? = nil,
                       isCancelled: () -> Bool = { false }) async throws -> URL {
        await acquire()
        defer { release() }
        if Task.isCancelled || isCancelled() { throw CancellationError() }
        let result: (String?, NSError?) = await withCheckedContinuation { continuation in
            let completion: (String?, NSError?) -> Void = { link, error in continuation.resume(returning: (link, error)) }
            if let start { start(payload, completion) }
            else { iPic.uploadImage(imageData: payload.data, handler: completion) }
        }
        guard let link = result.0 else {
            if let error = result.1 {
                if error.domain == iPicUploadError.TimeOut.domain && error.code == iPicUploadError.TimeOut.code {
                    throw MarkdownImageUploadService.UploadError.iPicTimedOut
                }
                throw error
            }
            throw MarkdownImageUploadService.UploadError.serverFailed
        }
        return try MarkdownImageUploadService.validURLs([link], count: 1)[0]
    }
}

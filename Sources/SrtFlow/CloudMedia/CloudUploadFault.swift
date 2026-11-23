#if DEBUG
import Foundation

// MARK: - SRTFLOW_TEST_UPLOAD_DROPS: lose the connection of an upload on purpose (debug builds only)
//
// What it covers: `SRTFLOW_TEST_UPLOAD_DROPS=N` makes the first N PUT tries of SkyStudioAPI.upload in this process lose their
// connection after part of the body went out, so a smoke test against the real Sky Studio can see the retry ("1 drop: the next try
// works") and the final error ("3 drops: the localized line, nothing charged") without touching any network setting. The cut try ends
// as URLError -1005 and goes through the same classification as a real lost connection (SkyStudioAPI.transfer).
// What it does not cover: the retry itself (SkyStudioAPI.upload, SkyStudioUploadRetry). **Release builds have none of this**: the whole
// file is inside `#if DEBUG`, scripts/check-sky-studio.sh looks for its traces in a build without DEBUG, and scripts/build-app.sh refuses
// a release binary that names it. Rules: docs/architecture/sky-studio-jobs.md, "Uploads that the network interrupts".

enum CloudUploadFault {
    static let environmentKey = "SRTFLOW_TEST_UPLOAD_DROPS"

    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var remaining: Int?
    }

    private static let counter = Counter()

    /// Whether this PUT try is one of the first N to lose its connection (N read from the environment once per process).
    static func claimDrop() -> Bool {
        counter.lock.lock()
        defer { counter.lock.unlock() }
        if counter.remaining == nil {
            counter.remaining = max(0, Int(ProcessInfo.processInfo.environment[environmentKey] ?? "") ?? 0)
        }
        guard let left = counter.remaining, left > 0 else { return false }
        counter.remaining = left - 1
        return true
    }

    /// Checks only: read the environment again at the next try.
    static func reset() {
        counter.lock.lock()
        counter.remaining = nil
        counter.lock.unlock()
    }

    /// Runs the PUT, cuts it as soon as part of the body went out, and ends it as a lost connection (-1005) whatever the wire did
    /// meanwhile (on a fast link the whole body may be out by then; the next try overwrites the same object). A real cancel stays one.
    static func perform(_ task: URLSessionTask, delegate: CloudTransferDelegate) async throws {
        let cut = task.observe(\.countOfBytesSent, options: [.new]) { task, _ in
            if task.countOfBytesSent > 0 { task.cancel() }
        }
        defer { cut.invalidate() }
        do {
            try await CloudTransfer.perform(task, delegate: delegate)
        } catch {
            if Task.isCancelled { throw error }
        }
        throw URLError(.networkConnectionLost)
    }
}
#endif

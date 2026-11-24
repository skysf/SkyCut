#if DEBUG
import Foundation

// MARK: - SRTFLOW_TEST_DOWNLOAD_DROPS: cut a paid result's download mid-body on purpose (debug builds only)
//
// What it covers: `SRTFLOW_TEST_DOWNLOAD_DROPS=N` cuts the first N download tries (GETs) of SkyStudioAPI.download in this process
// once part of the body arrived, so a smoke test against the real Sky Studio can see the resume / retry ("1 drop: the job completes and
// the file is whole") and the final error ("3 drops: the localized line, nothing more charged, Download again gets the same result")
// without touching any network setting.
// A cut try is the real GET, cancelled with the system's resume data once a quarter of the body (at most 256 KB, at least one byte)
// arrived, or after 5 s. It ends as URLError -1005 carrying that resume data, through the same classification as a real lost
// connection (SkyStudioAPI.fetch). A body that arrived whole before the cut (a small file on a fast link) is still dropped, at its end
// and without resume data, so the next try starts from nothing; an answer that is not 2xx stands, and so does a try that ended on its
// own before the cut (a real failure).
// What it does not cover: the retry itself (SkyStudioAPI.download, SkyStudioDownloadRetry). **Release builds have none of this**: the
// whole file is inside `#if DEBUG`, scripts/debug-hook-probe.sh refuses a binary that names it (a build without DEBUG in
// scripts/check-sky-studio.sh, the release binary in scripts/build-app.sh). Rules: docs/architecture/sky-studio-jobs.md, "Downloads
// that the network interrupts".

enum CloudDownloadFault {
    static let environmentKey = "SRTFLOW_TEST_DOWNLOAD_DROPS"
    /// The most of the body a cut try receives before it is cut.
    static let largestPart: Int64 = 256 * 1024

    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var remaining: Int?
    }

    private static let counter = Counter()

    /// Whether this GET is one of the first N to be cut (N read from the environment once per process).
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

    /// The bytes after which a cut try is cancelled: a quarter of the body, at most `largestPart`, at least one byte (one byte when
    /// the server did not say how long).
    static func cutAfter(expected: Int64) -> Int64 { expected > 0 ? max(1, min(expected / 4, largestPart)) : 1 }

    /// Whether the cutter cut this try, and the resume data the system gave for it.
    private final class Cut: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var resumeData: Data?
        func record(_ data: Data?) { lock.withLock { done = true; resumeData = data } }
        var outcome: (done: Bool, resumeData: Data?) { lock.withLock { (done, resumeData) } }
    }

    /// A cut try: the GET runs until its part arrived (or 5 s), is cancelled with the system's resume data, and ends as a lost
    /// connection (-1005) carrying it. A real cancel stays one.
    static func drop(_ task: URLSessionDownloadTask, delegate: CloudTransferDelegate) async throws {
        let cut = Cut()
        // Waits (sleeping, never spinning) until the part arrived, then cuts. It ends at once when the try already ended or the try is
        // over (cancelled by the defer below). A task not started yet (suspended) is waited for: this may look before
        // CloudTransfer.perform resumes it.
        let cutter = Task {
            let deadline = Date().addingTimeInterval(5)
            while task.state != .completed, task.state != .canceling,
                  task.countOfBytesReceived < cutAfter(expected: task.countOfBytesExpectedToReceive), Date() < deadline {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            guard task.state == .running else { return }
            let data: Data? = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
            }
            cut.record(data)
        }
        defer { cutter.cancel() }
        do {
            try await CloudTransfer.perform(task, delegate: delegate)
        } catch {
            if Task.isCancelled { throw error }
            await cutter.value
            let (done, resumeData) = cut.outcome
            guard done else { throw error }
            throw URLError(.networkConnectionLost, userInfo: resumeData.map { [NSURLSessionDownloadTaskResumeData: $0] } ?? [:])
        }
        // Whole before the cut could happen: a 2xx is still dropped (at its end, so the next try starts from nothing); any other
        // answer stands.
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { throw URLError(.networkConnectionLost) }
    }
}
#endif

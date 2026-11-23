#if DEBUG
import Foundation

// MARK: - SRTFLOW_TEST_UPLOAD_DROPS: lose the connection of an upload on purpose (debug builds only)
//
// What it covers: `SRTFLOW_TEST_UPLOAD_DROPS=N` makes the first N PUT tries of SkyStudioAPI.upload in this process lose their
// connection after part of the body went out, so a smoke test against the real Sky Studio can see the retry ("1 drop: the next try
// works") and the final error ("3 drops: the localized line, nothing charged") without touching any network setting.
// A dropped try is the same PUT (same signed address, same headers) sent as a stream that holds only the first quarter of the file
// (at most 256 KB) while its Content-Length is the whole file's, so the storage can never take it as complete, on any link. Once that
// part is out (or after 5 s) it is cancelled, and it ends as URLError -1005 through the same classification as a real lost connection
// (SkyStudioAPI.put).
// What it does not cover: the retry itself (SkyStudioAPI.upload, SkyStudioUploadRetry). **Release builds have none of this**: the whole
// file is inside `#if DEBUG`, scripts/debug-hook-probe.sh refuses a binary that names it (a build without DEBUG in
// scripts/check-sky-studio.sh, the release binary in scripts/build-app.sh). Rules: docs/architecture/sky-studio-jobs.md, "Uploads that
// the network interrupts".

enum CloudUploadFault {
    static let environmentKey = "SRTFLOW_TEST_UPLOAD_DROPS"
    /// The most of the body a dropped try sends.
    static let largestPart = 256 * 1024

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

    /// The bytes a dropped try sends: the first quarter of the file, at most `largestPart`, at least one byte.
    static func partSize(of size: Int) -> Int { max(1, min(size / 4, largestPart)) }

    /// A dropped try: the PUT streams only `partSize` bytes of a body whose declared length is the whole file, is cancelled once they
    /// are out (or after 5 s), and ends as a lost connection (-1005). A real cancel stays one.
    static func drop(_ request: URLRequest, file: URL, session: URLSession, delegate: CloudTransferDelegate) async throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        let head = try handle.read(upToCount: partSize(of: size)) ?? Data()
        try? handle.close()
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: max(1, head.count), inputStream: &input, outputStream: &output)
        guard let input, let output else { throw URLError(.networkConnectionLost) }
        output.open()
        defer { output.close() }
        if !head.isEmpty {
            _ = head.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: head.count) }
        }
        var streamed = request
        streamed.setValue(String(size), forHTTPHeaderField: "Content-Length")
        streamed.httpBodyStream = input
        // A data task sends `httpBodyStream` as the body (a streamed upload task would ask the delegate for it instead).
        let task = session.dataTask(with: streamed)
        let sent = Int64(head.count)
        // Waits (sleeping, never spinning) until the part is out, then cuts. It ends at once when the try already ended (a connection that
        // failed before the body) or the try is over (cancelled by the defer below).
        let cutter = Task {
            let deadline = Date().addingTimeInterval(5)
            while task.state != .completed, task.state != .canceling, task.countOfBytesSent < sent, Date() < deadline {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            task.cancel()
        }
        defer { cutter.cancel() }
        do {
            try await CloudTransfer.perform(task, delegate: delegate)
        } catch {
            if Task.isCancelled { throw error }
        }
        throw URLError(.networkConnectionLost)
    }
}
#endif

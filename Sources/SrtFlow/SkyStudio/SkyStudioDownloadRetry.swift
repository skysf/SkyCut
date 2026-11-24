import Foundation

// MARK: - A paid result's download: when SkyStudioAPI.download tries again
//
// What it covers (2026-11-24, backlog B40: the uplink here is slow and unstable, uploads got retries in #549, and every paid output
// still failed on its first dropped connection after Sky Studio had made and charged it):
// - how many GETs a download may send and the pauses between them; a try the network broke counts as broken by the upload's own rule
//   (SkyStudioUploadRetry.isTransient), so the two never disagree on what a dropped connection is;
// - which HTTP answers mean the result's address may have expired or been withdrawn, so Sky Studio is asked once for a fresh one
//   (the original job's `GET /jobs/{id}`; nothing is ever submitted again);
// - what one try ended as (`Try`), for SkyStudioAPI.download only.
// What it does not cover: sending anything (SkyStudioAPI.download owns the loop), the error when it gives up
// (SkyStudioDownloadFailure), the words the user reads (SkyStudioDownloadWords).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

struct SkyStudioDownloadRetry: Sendable {
    /// GETs in all, the first one included (a try at a fresh address counts as one).
    var attempts = 3
    /// Seconds to wait before the second, third… try after the network broke one (the last one repeats).
    var pauses: [TimeInterval] = [1, 2]
    /// How long a GET may go without a byte moving before it times out (the system's idle timeout; checks shorten it).
    var getTimeout: TimeInterval = 600
    /// Waits between tries; a cancelled task ends the wait at once (checks record the pauses instead of waiting).
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    static let standard = SkyStudioDownloadRetry()

    /// The pause before try `attempt` (2, 3…).
    func pause(before attempt: Int) async throws {
        guard let last = pauses.last else { return }
        let index = attempt - 2
        try await sleep(pauses.indices.contains(index) ? pauses[index] : last)
    }

    /// The answers that say the address no longer serves the result (expired, withdrawn): Sky Studio is asked for a fresh one once.
    /// Any other answer stands as it is: an HTTP answer is never tried again blindly.
    static let renewableStatuses: Set<Int> = [403, 404, 410]

    /// What one GET ended as.
    enum Try {
        /// The whole result is in the partial file beside the destination.
        case done
        /// The network broke it (SkyStudioUploadRetry.isTransient); `resumeData` when the system kept what had arrived.
        case broken(detail: String, resumeData: Data?)
        /// The server answered with this status (not 2xx), even when its body then broke.
        case answered(status: Int)
        /// The connection does not work at all (address, certificate, TLS): another try would only repeat it.
        case unreachable(detail: String)
    }
}

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
        /// The network broke it (SkyStudioUploadRetry.isTransient), or what arrived is not the whole result; `resumeData` when the
        /// system kept what had arrived (never for a result that did not add up: it starts again from nothing).
        case broken(detail: String, resumeData: Data?)
        /// An answer began but the network broke it before its status came through: the system holds a download's answer back until
        /// its body flows (a probe: even a 1 KB body is held, and the task's metrics carry no status either). It may be an expired
        /// address whose error body stalled, so the job is asked for its current address first.
        case heldBack(detail: String, resumeData: Data?)
        /// The server answered with this status (not 2xx, not a redirect), even when its body then broke.
        case answered(status: Int)
        /// A redirect (3xx with a Location): followed by the next GET, which counts as one (the system never follows one by itself
        /// here, so three tries are three GETs).
        case redirected(status: Int, to: URL)
        /// The connection does not work at all (address, certificate, TLS): another try would only repeat it.
        case unreachable(detail: String)
    }

    /// Why a finished GET is not the whole result, or nil. A resumed answer (206) must reach the result's last byte
    /// (`bytes a-b/total` with b = total - 1) and the file must then hold `total` bytes; a whole answer with a length must hold that
    /// length. A resumed 206 `bytes 100000-249999/1000000` once became a 250,000-byte "result" at 100% (the review of PR #554).
    /// `encoded`: the answer named a Content-Encoding, so the bytes on disk (decoded) are not the bytes counted: sizes are not compared.
    static func incompleteness(status: Int, contentRange: String?, expectedLength: Int64, size: Int, encoded: Bool = false) -> String? {
        if status == 206 {
            guard let range = contentRange, let parsed = parseContentRange(range) else {
                return "a resumed answer without a usable Content-Range (\(contentRange ?? "none"))"
            }
            guard let total = parsed.total, parsed.last == total - 1, encoded || size == total else {
                return "a resumed answer that does not finish the result (\(range); \(size) bytes here)"
            }
            return nil
        }
        guard !encoded, expectedLength > 0, Int64(size) != expectedLength else { return nil }
        return "\(size) of \(expectedLength) bytes arrived"
    }

    /// `bytes 100-199/1000` → (100, 199, 1000); the total is nil when it is `*`. Anything else is nil.
    static func parseContentRange(_ text: String) -> (first: Int, last: Int, total: Int?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        let bounds = rangeAndTotal.first?.split(separator: "-", maxSplits: 1) ?? []
        guard rangeAndTotal.count == 2, bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]), first <= last else { return nil }
        let total = rangeAndTotal[1] == "*" ? nil : Int(rangeAndTotal[1])
        guard rangeAndTotal[1] == "*" || total != nil else { return nil }
        return (first, last, total)
    }

    /// Where a redirect points (its Location, resolved against the address it came from), when it is http(s).
    static func redirectTarget(status: Int, location: String?, from address: URL) -> URL? {
        guard (300..<400).contains(status), let location, let target = URL(string: location, relativeTo: address)?.absoluteURL,
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return target
    }
}

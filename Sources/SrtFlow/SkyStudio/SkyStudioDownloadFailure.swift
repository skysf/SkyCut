import Foundation
import SrtFlowMCPKit

// MARK: - A paid result whose download did not happen: what the AI is told (pure)
//
// What it covers: SkyStudioAPI.download gave up on a finished result: the network broke every try, the connection did not work at
// all, or the storage refused it (after asking Sky Studio once for a fresh address when the answer was 403 / 404 / 410). Sky Studio
// made the result and charged for it; nothing more was charged, nothing was submitted again, and downloading it again is free. The
// English message, the stable code (`download_network`, `download_refused`), the GET count and the next step. It is an error of its
// own (not a SkyStudioFailure case): it only comes after a job is done, outside SkyStudioJobRun, and every flow that downloads keeps
// the result to download it again (SkyStudioMediaStatus.retryDownload, UpscaleJob.retryDownload).
// What it does not cover: when to try again (SkyStudioDownloadRetry), the user's localized line (SkyStudioDownloadWords).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

struct SkyStudioDownloadFailure: Error, LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The network broke every try (connection lost, timed out, offline).
        case interrupted
        /// The connection did not work at all (address, certificate, TLS), so it was not tried again.
        case unreachable
        /// The storage answered with an error, so it was not tried again (403 / 404 / 410 only after a fresh address).
        case refused(status: Int)
    }

    let kind: Kind
    /// GETs sent to the result's address, the first one included; asking Sky Studio for a fresh address is not one.
    let attempts: Int
    /// The last error the system gave ("NSURLErrorDomain -1005") or the storage's status ("HTTP 403").
    let lastError: String
    /// Sky Studio was asked for a fresh address (after a 403 / 404 / 410).
    var renewed = false

    var code: String {
        if case .refused = kind { return "download_refused" }
        return "download_network"
    }

    /// What the AI is told (English; the user reads SkyStudioDownloadWords).
    var message: String {
        let made = "Sky Studio finished this result and charged for it, but "
        switch kind {
        case .interrupted:
            let when = attempts > 1 ? "after \(attempts) tries" : "on its only try"
            return made + "its download to this Mac was interrupted by the network \(when); nothing more was charged and the result is "
                + "still on Sky Studio."
        case .unreachable:
            return made + "its download could not connect (\(lastError)); nothing more was charged and the result is still on Sky Studio."
        case .refused(let status):
            return made + "its storage refused the download (HTTP \(status))" + (renewed ? ", also at a fresh address from Sky Studio" : "")
                + "; nothing more was charged."
        }
    }

    var errorDescription: String? { message }

    /// The fields a tool result or get_job carries: the code, the GET count, the last error and, given `retry` (how the same result
    /// is downloaded again in this flow), the next step.
    func fields(retry: String? = nil) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["code": .string(code), "download_attempts": .number(Double(attempts)),
                                           "download_error": .string(lastError)]
        guard let retry else { return fields }
        let what: String
        switch kind {
        case .interrupted: what = "the network interrupted the download"
        case .unreachable: what = "the download could not connect, and ask them to check their network connection"
        case .refused(let status): what = "Sky Studio's storage refused the download (HTTP \(status))"
        }
        fields["next_step"] = .string("Sky Studio made this result and charged for it; only its download to this Mac failed, and nothing "
            + "more was charged. Tell the user, in their language, that " + what + ". To download the same result again at no charge, "
            + retry)
        return fields
    }

    /// How the user downloads it again in every flow that keeps the result: the task list's button.
    static let taskListRetry = "the user can press Download again on this task in SkyCut's cloud task list (the toolbar's task button)."

    /// The download failure inside an error, if that is what it is.
    static func from(_ error: Error) -> SkyStudioDownloadFailure? { error as? SkyStudioDownloadFailure }
}

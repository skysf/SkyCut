import Foundation
import SrtFlowMCPKit

// MARK: - A paid result whose download did not happen: what the AI is told (pure)
//
// What it covers: SkyStudioAPI.download gave up on a finished result: the network broke every try, what arrived was never the whole
// result, the connection did not work at all, or the storage refused it (after asking the original job once for its current address
// when the answer was 403 / 404 / 410); or the download was stopped (`stopped`, with the GETs it had sent). Sky Studio made the
// result; nothing more was charged and nothing was submitted again. This Mac could not keep it (`notSaved`: the disk, a file where the
// output folder should be) is one too: the paid result stays reachable the same way (the review of PR #554). The English message, the
// stable code (`download_network`, `download_incomplete`, `download_refused`, `download_stopped`, `download_not_saved`), the GET count
// and the next step, which each flow gives: the exact
// way back to this job's result (its task row's Download again, generate_media's own idempotency_key). Billing is not asserted here:
// it stays in each job's own fields.
// It is an error of its own (not a SkyStudioFailure case): it only comes after a job is done, outside SkyStudioJobRun, and every flow
// that downloads keeps the result to download it again (SkyStudioMediaStatus.retryDownload, UpscaleJob.retryDownload).
// What it does not cover: when to try again (SkyStudioDownloadRetry), the user's localized line (SkyStudioDownloadWords).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

struct SkyStudioDownloadFailure: Error, LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The network broke the last try (connection lost, timed out, offline, or an answer whose status never came through).
        case interrupted
        /// The last try finished but what arrived was not the whole result (empty, short, a size that does not add up).
        case incomplete
        /// The connection did not work at all (address, certificate, TLS), so it was not tried again.
        case unreachable
        /// The storage answered with an error, so it was not tried again (403 / 404 / 410 only after asking for the current address).
        case refused(status: Int)
        /// The user (or the AI) stopped the download; the result is kept for Download again.
        case stopped
        /// This Mac could not keep it (the disk, a file where the output folder should be): not the network's doing, so not tried again.
        case notSaved
    }

    let kind: Kind
    /// GETs sent, the first one included (a redirect followed is one more); asking the job for its current address is not one.
    let attempts: Int
    /// The last error the system gave ("NSURLErrorDomain -1005"), what was wrong with what arrived, or the storage's status ("HTTP 403").
    let lastError: String
    /// A GET went to a fresh address the job gave (one that differed from the address that failed).
    var triedFreshAddress = false

    /// A download that was stopped after sending `attempts` GETs (0 when it was stopped before its first one).
    static func stopped(attempts: Int) -> SkyStudioDownloadFailure {
        SkyStudioDownloadFailure(kind: .stopped, attempts: attempts, lastError: "stopped")
    }

    /// This Mac could not keep the result (`error`: making its folder, moving it into place) after `attempts` GETs (0: before any).
    static func notSaved(_ error: Error, attempts: Int = 0) -> SkyStudioDownloadFailure {
        SkyStudioDownloadFailure(kind: .notSaved, attempts: attempts, lastError: error.localizedDescription)
    }

    /// The same failure counting `earlier` GETs a flow sent before it (a voice change's background after its voice: the stop once said
    /// 1 GET of the 2 the server counted, CXD3 on PR #554).
    func after(_ earlier: Int) -> SkyStudioDownloadFailure {
        SkyStudioDownloadFailure(kind: kind, attempts: attempts + earlier, lastError: lastError, triedFreshAddress: triedFreshAddress)
    }

    var code: String {
        switch kind {
        case .refused: return "download_refused"
        case .stopped: return "download_stopped"
        case .incomplete: return "download_incomplete"
        case .notSaved: return "download_not_saved"
        case .interrupted, .unreachable: return "download_network"
        }
    }

    /// What the AI is told (English; the user reads SkyStudioDownloadWords).
    var message: String {
        let made = "Sky Studio finished this result, but "
        let when = attempts > 1 ? "after \(attempts) tries" : "on its only try"
        switch kind {
        case .interrupted:
            return made + "its download to this Mac was interrupted by the network \(when); nothing more was charged and the result is "
                + "still on Sky Studio."
        case .incomplete:
            return made + "what came down to this Mac was not the whole file (\(lastError)) \(when); nothing more was charged and the "
                + "result is still on Sky Studio."
        case .unreachable:
            return made + "its download could not connect (\(lastError)); nothing more was charged and the result is still on Sky Studio."
        case .refused(let status):
            return made + "its storage refused the download (HTTP \(status))"
                + (triedFreshAddress ? ", also at the fresh address Sky Studio gave" : "") + "; nothing more was charged."
        case .stopped:
            return made + "its download to this Mac was stopped; nothing more was charged and the result is still on Sky Studio."
        case .notSaved:
            return made + "SkyCut could not save it on this Mac (\(lastError)); nothing more was charged and the result is still on Sky Studio."
        }
    }

    var errorDescription: String? { message }

    /// The fields a tool result or get_job carries: the code, the GET count, the last error and, given `retry` (the exact way back to
    /// this job's result in this flow, and what a new call would do instead), the next step.
    func fields(retry: String? = nil) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["code": .string(code), "download_attempts": .number(Double(attempts)),
                                           "download_error": .string(lastError)]
        guard let retry else { return fields }
        let what: String
        switch kind {
        case .interrupted: what = "the network interrupted the download"
        case .incomplete: what = "what came down was not the whole file"
        case .unreachable: what = "the download could not connect, and ask them to check their network connection"
        case .refused(let status): what = "Sky Studio's storage refused the download (HTTP \(status))"
        case .stopped: what = "the download was stopped"
        case .notSaved: what = "SkyCut could not save the file on this Mac (\(lastError)), and ask them to free disk space or fix the output folder first"
        }
        fields["next_step"] = .string("Sky Studio made this result; only its download to this Mac did not finish, and nothing more was "
            + "charged for it. Tell the user, in their language, that " + what + ". To download this same result again at no charge, "
            + retry)
        return fields
    }

    /// How the user downloads it again in every flow that keeps the result: the button on this job's own task row.
    static let taskListRetry = "the user can press Download again on this task in SkyCut's cloud task list (the toolbar's task button)."

    /// The download failure inside an error, if that is what it is.
    static func from(_ error: Error) -> SkyStudioDownloadFailure? { error as? SkyStudioDownloadFailure }
}

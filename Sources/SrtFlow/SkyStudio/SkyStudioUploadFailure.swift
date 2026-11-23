import Foundation
import SrtFlowMCPKit

// MARK: - An upload to Sky Studio's storage that did not happen: what the AI is told (pure)
//
// What it covers: SkyStudioAPI.upload gave up on a file (SkyStudioFailure.uploadFailed): the network interrupted every try, the
// connection did not work at all, or the storage refused it. Nothing was submitted, so nothing was charged, and there is no original
// job to query. The English message, the stable code (`upload_network`, `upload_refused`), the PUT count and the next step.
// What it does not cover: when to try again (SkyStudioUploadRetry), the user's localized line (SkyStudioUploadWords). Sky Studio's own
// refusals of `/uploads` (`.server`, e.g. a file too large) keep their own code and words.
// Rules: docs/architecture/sky-studio-jobs.md, "Uploads that the network interrupts".

struct SkyStudioUploadFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The network broke every try (connection lost, timed out, offline).
        case interrupted
        /// The connection did not work at all (address, certificate, TLS), so it was not tried again.
        case unreachable
        /// The storage answered with an error, so it was not tried again.
        case refused(status: Int)
    }

    /// The file as the user knows it (a clip's or recording's own name when SkyCut uploaded a cut of it).
    let fileName: String
    let kind: Kind
    /// PUT tries sent, the first one included; renewing the signed address is not a try (0: the address was never had).
    let attempts: Int
    /// The last error the system gave ("NSURLErrorDomain -1005"), or the storage's status ("HTTP 403").
    let lastError: String

    var code: String {
        if case .refused = kind { return "upload_refused" }
        return "upload_network"
    }

    /// What the AI is told (English; the user reads SkyStudioUploadWords).
    var message: String {
        switch kind {
        case .interrupted:
            let when = attempts > 1 ? "after \(attempts) tries" : attempts == 1 ? "on its only try" : "before the file could be sent"
            return "The upload of \(fileName) to Sky Studio was interrupted by the network \(when); nothing was submitted and nothing was "
                + "charged."
        case .unreachable:
            return "The upload of \(fileName) to Sky Studio could not connect (\(lastError)), so it was not tried again; nothing was "
                + "submitted and nothing was charged."
        case .refused(let status):
            return "Sky Studio's storage refused the upload of \(fileName) (HTTP \(status)), so it was not tried again; nothing was "
                + "submitted and nothing was charged."
        }
    }

    /// The fields a tool result or get_job carries: the code, the PUT count, nothing charged and what to do next.
    /// `retry`: how this tool is called again.
    func fields(retry: String) -> [String: JSONValue] {
        let what: String
        switch kind {
        case .interrupted: what = "the network interrupted the upload of \(fileName), and ask them to check their network connection"
        case .unreachable: what = "the upload of \(fileName) could not connect, and ask them to check their network connection"
        case .refused(let status): what = "Sky Studio's storage refused the upload of \(fileName) (HTTP \(status))"
        }
        return ["code": .string(code), "upload_attempts": .number(Double(attempts)), "upload_error": .string(lastError), "charged": false,
                "next_step": .string("Nothing was submitted to Sky Studio and nothing was charged. Tell the user, in their language, that "
                    + what + ". When they want to try again, " + retry)]
    }

    /// The upload failure inside an error, if that is what it is.
    static func from(_ error: Error) -> SkyStudioUploadFailure? {
        if case .uploadFailed(let failure)? = error as? SkyStudioFailure { return failure }
        return nil
    }
}

import Foundation
import SrtFlowMCPKit

// MARK: - An upload to Sky Studio's storage that did not happen: what the AI is told (pure)
//
// What it covers: SkyStudioAPI.upload gave up on a file (SkyStudioFailure.uploadFailed): the network interrupted every try, the
// connection did not work at all, the storage refused it, or Sky Studio did not hand out an address (`/uploads` refused or answered
// without one; its own refusal is kept in `server`, so the voice library still names it). Nothing was submitted, so nothing was
// charged, and there is no original job to query. The English message, the stable code (`upload_network`, `upload_refused`,
// `upload_declined`), the PUT count and the next step.
// What it does not cover: when to try again (SkyStudioUploadRetry), the user's localized line (SkyStudioUploadWords).
// Rules: docs/architecture/sky-studio-jobs.md, "Uploads that the network interrupts".

struct SkyStudioUploadFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The network broke every try (connection lost, timed out, offline).
        case interrupted
        /// The connection did not work at all (address, certificate, TLS), so it was not tried again.
        case unreachable
        /// The storage answered with an error, so it was not tried again (0: only its head came, and the system held it back).
        case refused(status: Int)
        /// Sky Studio did not hand out an address (`/uploads` refused, or answered without one).
        case declined(status: Int)
    }

    /// The file as the user knows it (a clip's or recording's own name when SkyCut uploaded a cut of it).
    let fileName: String
    let kind: Kind
    /// PUT tries sent, the first one included; renewing the signed address is not a try (0: the address was never had).
    let attempts: Int
    /// The last error the system gave ("NSURLErrorDomain -1005"), the storage's status ("HTTP 403"), or Sky Studio's refusal.
    let lastError: String
    /// Sky Studio's own refusal of `/uploads`, when it gave one (its code and fields, as `.server` would carry them).
    var server: SkyStudioServerError? = nil

    var code: String {
        switch kind {
        case .interrupted, .unreachable: return "upload_network"
        case .refused: return "upload_refused"
        case .declined: return "upload_declined"
        }
    }

    /// The file is bigger than Sky Studio takes (a 413, or its refusal's reason `upload_too_large`): only a smaller file helps, so
    /// the words never say "try again later".
    var isTooLarge: Bool {
        if server?.fields["reason"]?.stringValue == SkyStudioVoiceCodes.Reason.uploadTooLarge { return true }
        switch kind {
        case .refused(413), .declined(413): return true
        default: return false
        }
    }

    /// What the AI is told (English; the user reads SkyStudioUploadWords).
    var message: String {
        if isTooLarge {
            return "Sky Studio did not accept the upload of \(fileName) because the file is too large (\(lastError)); nothing was submitted "
                + "and nothing was charged."
        }
        switch kind {
        case .interrupted:
            let when = attempts > 1 ? "after \(attempts) tries" : attempts == 1 ? "on its only try" : "before the file could be sent"
            return "The upload of \(fileName) to Sky Studio was interrupted by the network \(when); nothing was submitted and nothing was "
                + "charged."
        case .unreachable:
            return "The upload of \(fileName) to Sky Studio could not connect (\(lastError)), so it was not tried again; nothing was "
                + "submitted and nothing was charged."
        case .refused(0):
            return "Sky Studio's storage answered the upload of \(fileName), but its answer did not come through, so it was not tried "
                + "again; nothing was submitted and nothing was charged."
        case .refused(let status):
            return "Sky Studio's storage refused the upload of \(fileName) (HTTP \(status)), so it was not tried again; nothing was "
                + "submitted and nothing was charged."
        case .declined:
            return "Sky Studio did not accept the upload of \(fileName) (\(lastError)); nothing was submitted and nothing was charged."
        }
    }

    /// The fields a tool result or get_job carries: the code, the PUT count, nothing charged and what to do next.
    /// `retry`: how this tool is called again.
    func fields(retry: String) -> [String: JSONValue] {
        let what: String
        switch kind {
        case _ where isTooLarge: what = "\(fileName) is too large for Sky Studio (\(lastError)), so they need a smaller file"
        case .interrupted: what = "the network interrupted the upload of \(fileName), and ask them to check their network connection"
        case .unreachable: what = "the upload of \(fileName) could not connect, and ask them to check their network connection"
        case .refused(0): what = "Sky Studio's storage answered the upload of \(fileName), but its answer did not come through"
        case .refused(let status): what = "Sky Studio's storage refused the upload of \(fileName) (HTTP \(status))"
        case .declined: what = "Sky Studio did not accept the upload of \(fileName) (\(lastError))"
        }
        var fields: [String: JSONValue] = ["code": .string(code), "upload_attempts": .number(Double(attempts)), "upload_error": .string(lastError),
            "charged": false, "next_step": .string("Nothing was submitted to Sky Studio and nothing was charged. Tell the user, in their "
                + "language, that " + what + ". When they want to try again, " + retry)]
        if let server { fields["server_code"] = .string(server.code) }
        return fields
    }

    /// The upload failure inside an error, if that is what it is.
    static func from(_ error: Error) -> SkyStudioUploadFailure? {
        if case .uploadFailed(let failure)? = error as? SkyStudioFailure { return failure }
        return nil
    }
}

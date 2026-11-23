import Foundation

// MARK: - What the user reads when an upload to Sky Studio did not happen (localized)
//
// What it covers: the one line the cloud task row, the upscale and voice change panels, the voice library and a project's notice
// show after SkyStudioAPI.upload gave up (SkyStudioUploadFailure): which file, what happened (interrupted by the network, after how
// many tries; could not connect; refused by the storage), that nothing was charged and what to do. It names the network, never a
// proxy: on 2026-11-23 the uplink was just as unstable without one.
// What it does not cover: the AI's English (SkyStudioUploadFailure.message and fields), when to try again (SkyStudioUploadRetry).

enum SkyStudioUploadWords {
    static func shown(_ failure: SkyStudioUploadFailure) -> String {
        switch failure.kind {
        case .interrupted where failure.attempts > 1:
            return String(format: L10n("The upload of “%1$@” was interrupted by the network after %2$d tries. Nothing was charged. Check your network connection and try again."),
                          failure.fileName, failure.attempts)
        case .interrupted:
            return String(format: L10n("The upload of “%@” was interrupted by the network. Nothing was charged. Check your network connection and try again."),
                          failure.fileName)
        case .unreachable:
            return String(format: L10n("The upload of “%@” could not connect. Nothing was charged. Check your network connection and try again."),
                          failure.fileName)
        case .refused(let status):
            return String(format: L10n("Sky Studio's storage refused the upload of “%1$@” (HTTP %2$d). Nothing was charged. Try again later."),
                          failure.fileName, status)
        }
    }
}

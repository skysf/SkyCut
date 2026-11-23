import Foundation

// MARK: - What the user reads when the network interrupted an upload to Sky Studio (localized)
//
// What it covers: the one line the cloud task row, the upscale and voice change panels, the voice library and a project's notice
// show after SkyStudioAPI.upload gave up (SkyStudioUploadInterruption): which file, after how many tries, that nothing was charged
// and to check the network. It names the network, never a proxy: on 2026-11-23 the uplink was just as unstable without one.
// What it does not cover: the AI's English (SkyStudioUploadInterruption.message and fields), when to try again (SkyStudioUploadRetry).

enum SkyStudioUploadWords {
    static func interrupted(_ interruption: SkyStudioUploadInterruption) -> String {
        String(format: L10n("The upload of “%1$@” was interrupted by the network after %2$d tries. Nothing was charged. Check your network connection and try again."),
               interruption.fileName, interruption.attempts)
    }
}

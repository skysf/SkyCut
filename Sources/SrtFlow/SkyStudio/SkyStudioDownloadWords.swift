import Foundation

// MARK: - What the user reads when a paid result's download did not happen (localized)
//
// What it covers: the one line the cloud task row and a project's notice show after SkyStudioAPI.download gave up
// (SkyStudioDownloadFailure): the result is ready on Sky Studio, what broke the download (the network, after how many tries; could
// not connect; refused by the storage), that nothing more was charged, and that trying again downloads the same result (the row's
// Download again button). It names the network, never a proxy (the uplink was just as unstable without one, 2026-11-23).
// What it does not cover: the AI's English (SkyStudioDownloadFailure.message and fields), when to try again (SkyStudioDownloadRetry).

enum SkyStudioDownloadWords {
    static func shown(_ failure: SkyStudioDownloadFailure) -> String {
        switch failure.kind {
        case .interrupted where failure.attempts > 1:
            return String(format: L10n("The result is ready on Sky Studio, but its download was interrupted by the network after %d tries. Nothing more was charged; trying again downloads the same result."),
                          failure.attempts)
        case .interrupted:
            return L10n("The result is ready on Sky Studio, but its download was interrupted by the network. Nothing more was charged; trying again downloads the same result.")
        case .unreachable:
            return L10n("The result is ready on Sky Studio, but its download could not connect. Nothing more was charged; check your network connection and try again.")
        case .refused(let status):
            return String(format: L10n("The result is ready on Sky Studio, but its storage refused the download (HTTP %d). Nothing more was charged."),
                          status)
        case .stopped:
            return L10n("The result is ready on Sky Studio, but its download was stopped. Nothing more was charged; trying again downloads the same result.")
        }
    }
}

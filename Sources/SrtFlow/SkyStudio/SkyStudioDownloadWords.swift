import Foundation

// MARK: - What the user reads when a paid result's download did not happen (localized)
//
// What it covers: the one line the cloud task row, the upscale inspector and a project's notice show after SkyStudioAPI.download gave
// up (SkyStudioDownloadFailure): the result is ready on Sky Studio, what kept it from this Mac (the network, after how many tries; not
// the whole file; could not connect; refused by the storage; stopped), that nothing more was charged, and the exact way back: Download
// again on this task in the generation task list. It never suggests asking for the same thing again (that is a new, charged job), and
// it names the network, never a proxy (the uplink was just as unstable without one, 2026-11-23).
// What it does not cover: the AI's English (SkyStudioDownloadFailure.message and fields), when to try again (SkyStudioDownloadRetry).

enum SkyStudioDownloadWords {
    static func shown(_ failure: SkyStudioDownloadFailure) -> String {
        switch failure.kind {
        case .interrupted where failure.attempts > 1:
            return String(format: L10n("The result is ready on Sky Studio, but its download was interrupted by the network after %d tries. Nothing more was charged. To get the same result, use Download again on this task in the generation task list."),
                          failure.attempts)
        case .interrupted:
            return L10n("The result is ready on Sky Studio, but its download was interrupted by the network. Nothing more was charged. To get the same result, use Download again on this task in the generation task list.")
        case .incomplete:
            return L10n("The result is ready on Sky Studio, but what came down was not the whole file. Nothing more was charged. To get the same result, use Download again on this task in the generation task list.")
        case .unreachable:
            return L10n("The result is ready on Sky Studio, but its download could not connect. Nothing more was charged. Check your network connection, then use Download again on this task in the generation task list.")
        case .refused(let status):
            return String(format: L10n("The result is ready on Sky Studio, but its storage refused the download (HTTP %d). Nothing more was charged. To try the same result again, use Download again on this task in the generation task list."),
                          status)
        case .stopped:
            return L10n("The result is ready on Sky Studio, but its download was stopped. Nothing more was charged. To get the same result, use Download again on this task in the generation task list.")
        }
    }
}

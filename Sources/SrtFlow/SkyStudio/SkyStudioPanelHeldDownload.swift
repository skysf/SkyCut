import Foundation

// MARK: - The paid result a panel's own clip is holding (backlog B47's UI half; user, 2026-11-25 / 26)
//
// What it covers: the upscale and change-voice panels open for one clip. When that clip's own last paid job (started for this clip in
// this opening of the project, from the panel or by the AI) was made by Sky Studio but did not come down, the panel makes Download
// again its main button (free: that job's own Download again, only GETs) and labels the paid button "Make a new version (N credits)",
// with one line saying which is which. The job is found by its own identity: the project's opening and the clip it was started for,
// never by matching a new request's parameters (that once handed project B's upscale to project A's clip, PR #554). A held upscale
// older than a later upscale of the clip that landed is not offered: it is no longer the clip's last. Read once when the panel opens,
// as the panel's other state of the clip's last job (VoiceChangeActivity.separationFailed).
// Panels are never counted as identical requests (a person's click is deliberate; SkyStudioRepeatGuard).
// What it does not cover: drawing (UpscalePanel, VoiceChangePanel), the download itself (UpscaleJob, VoiceChangeJob).

@MainActor
struct SkyStudioPanelHeldDownload {
    /// Download again of that job's own paid result.
    let downloadAgain: () -> Void

    /// The upscale held for this clip in this opening of the project (its row's Download again), unless a later upscale of the clip
    /// has landed since: the held one is then no longer the clip's last upscale, and only its own row offers it (FBR1 on PR #557).
    static func upscale(project: VideoEditProject, clipID: UUID) -> SkyStudioPanelHeldDownload? {
        guard let job = UpscaleActivity.shared.jobs.last(where: {
            $0.projectGeneration == project.documentGeneration && $0.clipIDs.contains(clipID) && $0.canRetryDownload
        }), !UpscaleActivity.shared.landedAfter(job, clipID: clipID) else { return nil }
        return SkyStudioPanelHeldDownload { UpscaleActivity.shared.downloadAgain(job) }
    }

    /// The voice change last started for this clip in this opening of the project, when its result is held for Download again.
    static func voiceChange(project: VideoEditProject, clipID: UUID) -> SkyStudioPanelHeldDownload? {
        guard let id = VoiceChangeActivity.shared.lastJob(for: clipID, generation: project.documentGeneration) else { return nil }
        if SkyStudioHeldDownloads.isHeld(id) { return SkyStudioPanelHeldDownload { _ = SkyStudioHeldDownloads.retry(id) } }
        // Held because a file could not be saved: only its row has the button (nothing registers it by job id).
        guard let retry = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id })?.retryDownload else { return nil }
        return SkyStudioPanelHeldDownload(downloadAgain: retry)
    }
}

/// The panels' words for a held result, in the app's language at the moment they are read.
enum SkyStudioPanelHeldText {
    static var upscaleLine: String {
        L10n("Sky Studio made this clip's last upscale, but it did not reach this Mac. Download again gets it at no charge; a new version is a new paid upscale.")
    }

    static var voiceChangeLine: String {
        L10n("Sky Studio made this clip's last voice change, but it did not reach this Mac. Download again gets it at no charge; a new version is a new paid voice change.")
    }

    /// The upscale panel's paid button next to Download again.
    static func upscaleNewVersion(_ credits: Double?) -> String {
        guard let credits else { return L10n("Make a new version") }
        return String(format: L10n("Make a new version (%@ credits)"), SkyStudioCredits.text(credits))
    }

    /// The change-voice panel's paid button next to Download again (its quote is the most it can cost).
    static func voiceChangeNewVersion(_ credits: Double?) -> String {
        guard let credits else { return L10n("Make a new version") }
        return String(format: L10n("Make a new version (up to %@ credits)"), SkyStudioCredits.text(credits))
    }
}

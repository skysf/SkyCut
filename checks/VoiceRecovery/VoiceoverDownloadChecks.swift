import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// A voiceover batch Sky Studio made whose download gave up (2026-11-24, the review of PR #554; docs/bugfixes/2026-11-24-download-lost-
// connection-no-retry.md), with the real voiceover run and the voice fixture (VoiceRecoveryHTTP): the batch's file loses its connection
// three times, so the job fails with download_network and its row offers Download again; pressing it runs the same local recovery as
// add_voiceover resume=recovery_file (only GETs the original job), which lands the voiceover, and nothing is generated again.

@MainActor
func runVoiceoverDownloadChecks(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("voiceover-download"))
    SkyStudioSpendStore.shared.setDailyLimit(100_000)   // the checks before this one spent part of the fixture's 1,000
    VoiceRecoveryHTTP.fileDrops = 3
    let started = try fixture.started(await fixture.narrate(["Hello world."]))
    let id = started.payload["job_id"]?.stringValue ?? ""
    let failed = try await fixture.wait(started)
    require(failed["status"] == "failed" && failed["code"] == "download_network" && failed["download_attempts"] == 3,
            "a voiceover batch whose download gave up fails with download_network after three GETs: \(failed)")
    let posts = VoiceRecoveryHTTP.posts
    let activity = SkyStudioGenerationActivity.shared
    guard let row = activity.runs.first(where: { $0.aiJobID == id }), let retry = row.retryDownload else {
        return require(false, "the failed voiceover row offers Download again")
    }
    require(row.issue == SkyStudioDownloadWords.shown(SkyStudioDownloadFailure(kind: .interrupted, attempts: 3, lastError: "")),
            "the row reads the localized line")
    let before = Set(activity.runs.map(ObjectIdentifier.init))
    retry()
    require(!activity.runs.contains { $0 === row }, "the row gives way to its recovery")
    guard let recovery = activity.runs.first(where: { !before.contains(ObjectIdentifier($0)) }), let recoveryID = recovery.aiJobID,
          let job = AIJobs.shared.job(recoveryID) else {
        return require(false, "Download again starts the voiceover's recovery as a job")
    }
    await AIJobs.shared.wait(for: job, seconds: 30)
    let done = AIJobs.shared.json(job)
    require(done["status"] == "done", "the recovery downloads the batch and lands the voiceover: \(done)")
    require(VoiceRecoveryHTTP.posts == posts && VoiceRecoveryHTTP.log.filter { $0.0 == "GET" && $0.1.hasPrefix("/files/") }.count == 4,
            "nothing is generated again: the same batch downloaded once more")
    require(fixture.project.state.audioTracks.contains { !$0.clips.isEmpty }, "the voiceover is on the timeline")
}

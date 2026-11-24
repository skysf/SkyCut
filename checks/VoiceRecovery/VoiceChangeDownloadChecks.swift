import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A paid voice change whose download gave up (2026-11-24, backlog B40; docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md),
// with real App objects and the fake Sky Studio (VoiceChangeHTTP):
// - three lost connections: the job fails with download_network after three GETs, charged once, the timeline untouched; the task row
//   reads the localized line and offers Download again; pressing it runs the same job id again, downloads the byte-identical files and
//   lands them as one undo step, with no new upload and no new /jobs (Main checks every keep-awake lease came back);
// - an expired address (403): one GET of the original job for a fresh address, and the change lands with no new job.

@MainActor
func runVoiceChangeDownloadChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-download"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    let args: JSONValue = ["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.fileDrops = 3 }
    let started = try await fixture.change(args)
    let failed = try await fixture.wait(started)
    let next = failed["next_step"]?.stringValue ?? ""
    require(failed["status"] == "failed" && failed["code"] == "download_network" && failed["download_attempts"] == 3
            && failed["skystudio_job_id"] == "convert-1" && failed["credits_charged"] == 7.5
            && next.contains("Download again") && next.contains("Never call change_voice again"),
            "three lost connections: failed with download_network after three GETs, charged once, Download again next: \(failed)")
    require(VoiceChangeHTTP.log.filter { $0.path.contains("/files/") }.count == 3, "three GETs of the voice file, never a fourth")
    require(fixture.project.state == before, "nothing lands while the files are not here")
    guard let id = started.payload["job_id"]?.stringValue,
          let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id }), let retry = row.retryDownload else {
        return require(false, "the failed row stays in the cloud task list with Download again")
    }
    require(row.issue == SkyStudioDownloadWords.shown(SkyStudioDownloadFailure(kind: .interrupted, attempts: 3, lastError: "")),
            "the row reads the localized line: \(row.issue ?? "nil")")

    retry()
    require(row.retryDownload == nil && row.issue == nil, "Download again starts once: its button and the line go")
    require(AIJobs.shared.job(id)?.status == .running, "the same job id runs again")
    let done = try await fixture.wait(started)
    require(done["status"] == "done" && done["voice_clip_id"] != nil && done["skystudio_job_id"] == "convert-1" && done["code"] == nil,
            "Download again lands the change under the same job id: \(done)")
    require(VoiceChangeHTTP.calls("POST", "/jobs").count == 1 && VoiceChangeHTTP.calls("POST", "/uploads").count == 1,
            "no new upload and no new job: the result made once")
    let state = fixture.project.state
    if state.audioTracks.count == 3, let voice = state.audioTracks[1].clips.first, let background = state.audioTracks[2].clips.first {
        require((try? Data(contentsOf: voice.sourceURL)) == VoiceChangeHTTP.wave(seconds: 4.02)
                && (try? Data(contentsOf: background.sourceURL)) == VoiceChangeHTTP.wave(seconds: 4),
                "the files are the byte-identical results")
    } else {
        require(false, "two new audio tracks after Download again: \(state.audioTracks.map(\.clips.count))")
    }
    require(state.clip(with: clipID)?.isMuted == true && !VoiceChangeActivity.shared.isChanging(clipID), "the original is muted and free again")
    fixture.project.effectiveUndoManager?.undo()
    require(fixture.project.state == before, "one undo step puts it all back")
    require(!SkyStudioGenerationActivity.shared.runs.contains { $0 === row }, "a delivered change leaves the cloud task list")

    // An expired address: one GET of the original job gives a fresh one, and the change lands with no new job.
    let expired = try VoiceChangeFixture(folder: root.appendingPathComponent("change-expired"))
    let other = expired.placeClip(try expired.stereoSource())
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.expireVoiceFile = true }
    let renewed = try await expired.wait(try await expired.change(["clip_id": .string(expired.short(other)), "voice": .string(VoiceChangeHTTP.voiceID),
                                                                   "language": "en"]))
    require(renewed["status"] == "done", "an expired address is renewed and the change lands: \(renewed)")
    require(VoiceChangeHTTP.calls("GET", "/jobs/convert-1").count == 1 && VoiceChangeHTTP.calls("POST", "/jobs").count == 1
            && VoiceChangeHTTP.log.contains { $0.path.hasSuffix("/files/voice-fresh.wav") },
            "one GET of the original job for a fresh address, the fresh address downloaded, no new job")
}

import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A paid voice change whose download did not finish (2026-11-24, backlog B40 and the review of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), with real App objects and the fake Sky Studio (VoiceChangeHTTP):
// - three lost connections: failed with download_network after three GETs, charged once, the timeline untouched, the row's localized
//   line and Download again;
// - change_voice asked for the same change downloads it again under the same job id: no new quote, upload or /jobs; the job's current
//   files are read first; the byte-identical files land as one undo step;
// - a stop during Download again keeps the button (download_stopped), and the next press lands it;
// - the panel opened for the same change offers Download again instead of a new paid change (B47);
// - an expired address (403): one GET of the original job for a fresh address; the change lands with no new job.
// Main checks that every keep-awake lease came back.

@MainActor
func runVoiceChangeDownloadChecks(_ root: URL) async throws {
    try await askedAgainChecks(root)
    try await stopChecks(root)
    try await panelChecks(root)
    try await expiredChecks(root)
}

@MainActor
private func args(_ fixture: VoiceChangeFixture, _ clipID: UUID) -> JSONValue {
    ["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]
}

/// Three lost connections: the change is held. Returns the AI job id and the row.
@MainActor
private func held(_ fixture: VoiceChangeFixture, _ clipID: UUID) async throws -> (String, SkyStudioMediaStatus)? {
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.fileDrops = 3 }
    let started = try await fixture.change(args(fixture, clipID))
    let failed = try await fixture.wait(started)
    guard let id = started.payload["job_id"]?.stringValue,
          let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id }), row.retryDownload != nil else {
        require(false, "the failed row stays in the cloud task list with Download again: \(failed)")
        return nil
    }
    let next = failed["next_step"]?.stringValue ?? ""
    require(failed["status"] == "failed" && failed["code"] == "download_network" && failed["download_attempts"] == 3
            && failed["skystudio_job_id"] == "convert-1" && failed["credits_charged"] == 7.5
            && next.contains("Download again") && next.contains("call change_voice again for the same clip"),
            "three lost connections: failed with download_network after three GETs, charged once, both ways back named: \(failed)")
    require(row.issue == SkyStudioDownloadWords.shown(SkyStudioDownloadFailure(kind: .interrupted, attempts: 3, lastError: "")),
            "the row reads the localized line: \(row.issue ?? "nil")")
    return (id, row)
}

@MainActor
private func landedCorrectly(_ fixture: VoiceChangeFixture, _ clipID: UUID, before: TimelineState, _ what: String) {
    let state = fixture.project.state
    if state.audioTracks.count == 3, let voice = state.audioTracks[1].clips.first, let background = state.audioTracks[2].clips.first {
        require((try? Data(contentsOf: voice.sourceURL)) == VoiceChangeHTTP.wave(seconds: 4.02)
                && (try? Data(contentsOf: background.sourceURL)) == VoiceChangeHTTP.wave(seconds: 4), "\(what): the byte-identical files land")
    } else {
        require(false, "\(what): two new audio tracks: \(state.audioTracks.map(\.clips.count))")
    }
    require(state.clip(with: clipID)?.isMuted == true && !VoiceChangeActivity.shared.isChanging(clipID), "\(what): the original is muted, free again")
    require(VoiceChangeHTTP.calls("POST", "/jobs").count == 1 && VoiceChangeHTTP.calls("POST", "/uploads").count == 1,
            "\(what): no new upload and no new job")
    fixture.project.effectiveUndoManager?.undo()
    require(fixture.project.state == before, "\(what): one undo step puts it all back")
}

@MainActor
private func askedAgainChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-download"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    guard let (id, row) = try await held(fixture, clipID) else { return }
    require(fixture.project.state == before, "nothing lands while the files are not here")
    let quotes = VoiceChangeHTTP.calls("POST", "/quote").count

    // change_voice for the same change: Download again under the same job id, never a second charge.
    let again = try await fixture.change(args(fixture, clipID))
    require(again.payload["status"] == "downloading_again" && again.payload["job_id"]?.stringValue == id && again.payload["submitted_again"] == false,
            "asked for the same change again: Download again under the same job id: \(again.payload)")
    require(VoiceChangeHTTP.calls("POST", "/quote").count == quotes, "nothing is quoted again")
    require(row.retryDownload == nil && row.issue == nil && AIJobs.shared.job(id)?.status == .running, "the button goes and the same job runs again")
    let done = try await fixture.wait(again)
    require(done["status"] == "done" && done["voice_clip_id"] != nil && done["code"] == nil, "Download again lands the change: \(done)")
    require(VoiceChangeHTTP.calls("GET", "/jobs/convert-1").count == 1, "Download again read the job's current files first")
    landedCorrectly(fixture, clipID, before: before, "asked again")
    require(!SkyStudioGenerationActivity.shared.runs.contains { $0 === row }, "a delivered change leaves the cloud task list")
}

@MainActor
private func stopChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-download-stop"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    guard let (id, row) = try await held(fixture, clipID), let retry = row.retryDownload, let job = AIJobs.shared.job(id) else { return }

    // Stopped while downloading again: the result stays held, with its own line and the button.
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdFiles = true }
    let gets = VoiceChangeHTTP.log.filter { $0.path.contains("/files/") }.count
    retry()
    await eventually("the held GET") { VoiceChangeHTTP.log.filter { $0.path.contains("/files/") }.count > gets }
    AIJobs.shared.cancel(job)
    await eventually("the stop") { job.status != .running }
    let stopped = AIJobs.shared.json(job)
    require(stopped["status"] == "cancelled" && stopped["code"] == "download_stopped" && row.retryDownload != nil
            && row.issue == SkyStudioDownloadWords.shown(.stopped),
            "a stop while downloading keeps the paid result with Download again: \(stopped), \(row.issue ?? "nil")")
    require(fixture.project.state == before && VoiceChangeHTTP.calls("POST", "/jobs").count == 1, "and lands nothing, starts nothing")

    // The next press lands it.
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdFiles = false }
    row.retryDownload?()
    await eventually("the change to land after the stop") { job.status != .running }
    require(AIJobs.shared.json(job)["status"] == "done", "Download again after a stop lands the change")
    landedCorrectly(fixture, clipID, before: before, "after a stop")
}

@MainActor
private func panelChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-download-panel"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    guard let (id, _) = try await held(fixture, clipID) else { return }

    // The panel opened for the same clip and voice offers Download again instead of a new paid change (B47).
    let store = VoiceLibraryStore()
    store.readKey = { .success("local-voice-change-fixture") }
    store.api = fixture.api
    fixture.detected = "en"
    guard let model = VoiceChangePanelModel(project: fixture.project, clipID: clipID, store: store) else { return require(false, "the panel opens") }
    model.services = fixture.services
    await model.open()
    await eventually("the panel's voice") { model.target != nil }
    require(model.heldDownload?.jobID == id, "the panel sees the held change of this clip and voice")
    model.skipSeparation = true
    require(model.heldDownload == nil, "another option is another change (it is quoted as usual)")
    model.skipSeparation = false
    require(model.downloadAgain() && AIJobs.shared.job(id)?.status == .running, "Download again from the panel runs the same job again")
    model.close()
    await eventually("the change to land from the panel") { AIJobs.shared.job(id)?.status != .running }
    landedCorrectly(fixture, clipID, before: before, "from the panel")
}

@MainActor
private func expiredChecks(_ root: URL) async throws {
    let expired = try VoiceChangeFixture(folder: root.appendingPathComponent("change-expired"))
    let other = expired.placeClip(try expired.stereoSource())
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.expireVoiceFile = true }
    let renewed = try await expired.wait(try await expired.change(args(expired, other)))
    require(renewed["status"] == "done", "an expired address is renewed and the change lands: \(renewed)")
    require(VoiceChangeHTTP.calls("GET", "/jobs/convert-1").count == 1 && VoiceChangeHTTP.calls("POST", "/jobs").count == 1
            && VoiceChangeHTTP.log.contains { $0.path.hasSuffix("/files/voice-fresh.wav") },
            "one GET of the original job for a fresh address, the fresh address downloaded, no new job")
}

@MainActor
private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<1500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

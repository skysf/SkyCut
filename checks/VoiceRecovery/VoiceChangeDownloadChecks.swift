import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A paid voice change whose download did not finish (2026-11-24 / 25, backlog B40 and the reviews of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), with real App objects and the fake Sky Studio (VoiceChangeHTTP):
// - three lost connections: failed with download_network after three GETs, charged once, the timeline untouched, the row's localized
//   line and Download again; the next step names only that row and says change_voice again is charged again;
// - change_voice asked again for the same change, and for Chinese after English, through the tool: each a new paid job (a new quote,
//   upload and POST /jobs; the Chinese one asks for zh), never the held result (user, 2026-11-25: an identical paid request sent again
//   is a deliberate new version); the held change keeps its own row's Download again;
// - that row's Download again lands the byte-identical files under the same job id (the job read first), as one undo step;
// - a stop during Download again keeps the button (download_stopped, with the GET it sent), and the next press lands it;
// - an expired address (403): one GET of the original job for a fresh address; the change lands with no new job;
// - a bill under review when it lands: the reservation stays and the receipt says the bill is pending (not its amount as the charge);
//   get_job reads the original job again, and once the bill is final the books and the receipt take it (the reviews of PR #554);
// - held with a bill under review, settled by get_job, then its row's Download again: the receipt keeps the settled bill (it once went
//   back to pending with 9 reserved, CXD5).
// Main checks that every keep-awake lease came back.

@MainActor
func runVoiceChangeDownloadChecks(_ root: URL) async throws {
    try await repeatChecks(root)
    try await stopChecks(root)
    try await expiredChecks(root)
    try await billChecks(root)
}

@MainActor
private func billChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-bill"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.billUnderReview = true }
    let spent = SkyStudioSpendStore.shared.spentToday()
    @MainActor func books() -> Double { SkyStudioSpendStore.shared.spentToday() - spent }
    let started = try await fixture.change(args(fixture, clipID))
    let landed = try await fixture.wait(started)
    require(landed["status"] == "done" && landed["billing_pending"] == true && landed["credits_charged"] == nil && landed["credits_reserved"] == 9
            && abs(books() - 9) < 0.001,
            "landed while the bill is under review: the 9 reserved stay, the bill said pending: \(landed), \(books())")
    guard let id = started.payload["job_id"]?.stringValue else { return require(false, "the change's job id") }
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.billUnderReview = false }
    let final = try await AIExportTools.job(AIToolArguments(["job_id": .string(id)])).payload
    require(final["billing_pending"] == false && final["credits_charged"] == 7.5 && abs(books() - 7.5) < 0.001,
            "once the bill is final, get_job settles it: the books and the receipt say 7.5: \(final), \(books())")

    // Held with a bill under review, settled by get_job, then Download again: the receipt keeps the settled bill.
    fixture.project.effectiveUndoManager?.undo()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.billUnderReview = true; VoiceChangeHTTP.fileDrops = 3 }
    let heldStart = try await fixture.change(args(fixture, clipID))
    _ = try await fixture.wait(heldStart)
    guard let heldID = heldStart.payload["job_id"]?.stringValue, let heldJob = AIJobs.shared.job(heldID),
          let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == heldID }) else {
        return require(false, "the held change keeps its row")
    }
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.billUnderReview = false }
    let settled = try await AIExportTools.job(AIToolArguments(["job_id": .string(heldID)])).payload
    require(settled["billing_pending"] == false && settled["credits_charged"] == 7.5, "get_job settles the held change's bill: \(settled)")
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.billUnderReview = true }   // Download again's re-read still shows the review
    row.retryDownload?()
    await AIJobs.shared.wait(for: heldJob, seconds: 30)
    let landed2 = AIJobs.shared.json(heldJob)
    require(landed2["status"] == "done" && landed2["billing_pending"] == false && landed2["credits_charged"] == 7.5
            && landed2["credits_reserved"] == nil,
            "Download again keeps the settled bill in the receipt, never pending again: \(landed2)")
}

@MainActor
private func args(_ fixture: VoiceChangeFixture, _ clipID: UUID, language: String = "en") -> JSONValue {
    ["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": .string(language)]
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
            && next.contains("Download again") && next.contains("Calling change_voice again starts a new voice change and is charged again"),
            "three lost connections: download_network after three GETs, charged once, its own row named, a repeat said to be charged: \(failed)")
    require(row.issue == SkyStudioDownloadWords.shown(SkyStudioDownloadFailure(kind: .interrupted, attempts: 3, lastError: "")),
            "the row reads the localized line: \(row.issue ?? "nil")")
    return (id, row)
}

@MainActor
private func landedCorrectly(_ fixture: VoiceChangeFixture, _ clipID: UUID, before: TimelineState, jobs: Int, _ what: String) {
    let state = fixture.project.state
    if state.audioTracks.count == 3, let voice = state.audioTracks[1].clips.first, let background = state.audioTracks[2].clips.first {
        require((try? Data(contentsOf: voice.sourceURL)) == VoiceChangeHTTP.wave(seconds: 4.02)
                && (try? Data(contentsOf: background.sourceURL)) == VoiceChangeHTTP.wave(seconds: 4), "\(what): the byte-identical files land")
    } else {
        require(false, "\(what): two new audio tracks: \(state.audioTracks.map(\.clips.count))")
    }
    require(state.clip(with: clipID)?.isMuted == true && !VoiceChangeActivity.shared.isChanging(clipID), "\(what): the original is muted, free again")
    require(VoiceChangeHTTP.calls("POST", "/jobs").count == jobs && VoiceChangeHTTP.calls("POST", "/uploads").count == jobs,
            "\(what): \(jobs) upload(s) and job(s) in all, nothing more for the download")
    fixture.project.effectiveUndoManager?.undo()
    require(fixture.project.state == before, "\(what): one undo step puts it all back")
}

@MainActor
private func repeatChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-download"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    guard let (id, row) = try await held(fixture, clipID) else { return }
    require(fixture.project.state == before, "nothing lands while the files are not here")
    let quotes = VoiceChangeHTTP.calls("POST", "/quote").count

    // The same change asked again: a new paid job, never the held result (its upload and POST /jobs come from the started job).
    let same = try await fixture.change(args(fixture, clipID))
    let sameID = same.payload["job_id"]?.stringValue
    require(same.payload["status"] == "started" && sameID != nil && sameID != id,
            "the same change asked again is a new job, not the held one: \(same.payload)")
    let sameDone = try await fixture.wait(same)
    require(sameDone["status"] == "done", "the new change lands: \(sameDone)")
    require(VoiceChangeHTTP.calls("POST", "/quote").count == quotes + 1 && VoiceChangeHTTP.calls("POST", "/uploads").count == 2
            && VoiceChangeHTTP.calls("POST", "/jobs").count == 2,
            "a new quote, upload and POST /jobs for it: \(VoiceChangeHTTP.log.filter { $0.method == "POST" }.map(\.path))")
    fixture.project.effectiveUndoManager?.undo()
    require(fixture.project.state == before && row.retryDownload != nil && AIJobs.shared.job(id)?.status == .failed,
            "the held change keeps its own row's Download again")

    // Chinese after English: a new job asking for Chinese.
    let chinese = try await fixture.change(args(fixture, clipID, language: "zh"))
    let chineseID = chinese.payload["job_id"]?.stringValue
    _ = try await fixture.wait(chinese)
    require(chinese.payload["status"] == "started" && chineseID != nil && chineseID != id && chineseID != sameID
            && VoiceChangeHTTP.calls("POST", "/jobs").count == 3
            && VoiceChangeHTTP.calls("POST", "/jobs").last?["params"]?["target_language"] == "zh",
            "Chinese after English is a new job asking for zh, never the English result: \(chinese.payload), "
                + "\(VoiceChangeHTTP.calls("POST", "/jobs").map { $0["params"] ?? .null })")
    fixture.project.effectiveUndoManager?.undo()
    require(fixture.project.state == before && row.retryDownload != nil, "the held English change is still held on its row")

    // The held change's own Download again: its files, under its job id.
    let reads = VoiceChangeHTTP.calls("GET", "/jobs/convert-1").count
    row.retryDownload?()
    require(row.retryDownload == nil && row.issue == nil && AIJobs.shared.job(id)?.status == .running,
            "the button goes and the same job runs again")
    guard let job = AIJobs.shared.job(id) else { return require(false, "the held job is still there") }
    await AIJobs.shared.wait(for: job, seconds: 30)
    let done = AIJobs.shared.json(job)
    require(done["status"] == "done" && done["voice_clip_id"] != nil && done["code"] == nil, "Download again lands the change: \(done)")
    require(VoiceChangeHTTP.calls("GET", "/jobs/convert-1").count > reads, "Download again read the job's current files first")
    landedCorrectly(fixture, clipID, before: before, jobs: 3, "Download again")
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
    require(stopped["status"] == "cancelled" && stopped["code"] == "download_stopped" && stopped["download_attempts"] == 1
            && row.retryDownload != nil && row.issue == SkyStudioDownloadWords.shown(.stopped(attempts: 1)),
            "a stop while downloading keeps the paid result with Download again, and says the GET it sent: \(stopped), \(row.issue ?? "nil")")
    require(fixture.project.state == before && VoiceChangeHTTP.calls("POST", "/jobs").count == 1, "and lands nothing, starts nothing")

    // The next press lands it.
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdFiles = false }
    row.retryDownload?()
    await eventually("the change to land after the stop") { job.status != .running }
    require(AIJobs.shared.json(job)["status"] == "done", "Download again after a stop lands the change")
    landedCorrectly(fixture, clipID, before: before, jobs: 1, "after a stop")
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

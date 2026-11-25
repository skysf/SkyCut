import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// A voiceover batch Sky Studio made whose download did not finish (2026-11-24 / 25, the reviews of PR #554; docs/bugfixes/2026-11-24-
// download-lost-connection-no-retry.md), with the real voiceover run and the voice fixture (VoiceRecoveryHTTP):
// - the batch's file loses its connection three times: the job fails with download_network, its next step names the row's Download
//   again and the recovery file, and the row's Download again runs the same local recovery as add_voiceover resume=recovery_file (only
//   GETs the original job), which lands the voiceover; nothing is generated again;
// - recovered first with add_voiceover resume, then the old row's Download again: the voiceover is not landed a second time (one
//   segment; the row once landed it again from its stale copy of the recovery record);
// - the user stops the job while the batch downloads: stopped with download_stopped, and the row keeps its Download again, which then
//   lands the voiceover;
// - a batch file that does not decode (4 bytes) fails local_split, and resume downloads that batch again from its original job instead
//   of failing on the same file (CXD5: the paid batch was unreachable);
// - a batch recovered while its bill is under review keeps its unknown amount, never the top-level figure as the charge (CXD5).

@MainActor
func runVoiceoverDownloadChecks(_ root: URL) async throws {
    try await rowRecovers(root)
    try await resumedThenRow(root)
    try await stoppedWhileDownloading(root)
    try await brokenBatchFile(root)
    try await recoveredBillUnderReview(root)
}

@MainActor
private func fileGets() -> Int { VoiceRecoveryHTTP.log.filter { $0.0 == "GET" && $0.1.hasPrefix("/files/") }.count }

/// A batch file that does not decode is not trusted: resume downloads it again from its original job.
@MainActor
private func brokenBatchFile(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("voiceover-broken-file"))
    fixture.failSplitOnce = false
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    VoiceRecoveryHTTP.brokenFiles = 1
    let failed = try await fixture.wait(fixture.started(await fixture.narrate(["Hello world."])))
    guard failed["failure_stage"] == "local_split", let file = failed["recovery_file"]?.stringValue else {
        return require(false, "a batch file that does not decode fails local_split with its recovery file: \(failed)")
    }
    let gets = fileGets(), posts = VoiceRecoveryHTTP.posts
    let resumed = try await fixture.resume(file)
    require(resumed["status"] == "done" && fileGets() == gets + 1 && VoiceRecoveryHTTP.posts == posts,
            "resume downloads the batch again from its original job (one more file GET, nothing generated again): \(resumed)")
}

/// A batch that already started when the job was stopped, recovered while its bill is under review: its unknown amount stays (the
/// reservation), and the top-level figure is never booked as the charge.
@MainActor
private func recoveredBillUnderReview(_ root: URL) async throws {
    let lines = ["Hello world."]
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("voiceover-bill-review"))
    fixture.failSplitOnce = false
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    VoiceRecoveryHTTP.deferred = true
    VoiceRecoveryHTTP.promptIndex = [lines[0]: 0]
    VoiceRecoveryHTTP.holdUntil = [0: 99]
    VoiceRecoveryHTTP.override = { method, path in   // already started on Sky Studio: a stop cannot cancel it
        method == "POST" && path.hasSuffix("/cancel")
            ? (409, ["error": ["code": "not_cancellable", "message": "Sky Studio already started this job.", "status": "running"]]) : nil
    }
    let result = try fixture.started(await fixture.narrate(lines))
    guard let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { return require(false, "the voiceover starts") }
    for _ in 0..<1_000 where AIJobs.shared.json(job)["batches_running"] != 1 { try await Task.sleep(nanoseconds: 10_000_000) }
    AIJobs.shared.cancel(job)
    let stopped = try await fixture.wait(result)
    guard stopped["unknown_batch_indices"] == [0], let file = stopped["recovery_file"]?.stringValue else {
        return require(false, "the stopped batch's outcome is unknown: \(stopped)")
    }
    VoiceRecoveryHTTP.lock.withLock { VoiceRecoveryHTTP.billUnderReview = 0.1; VoiceRecoveryHTTP.override = nil }
    VoiceRecoveryHTTP.release()
    let recovered = try await fixture.resume(file)
    require(recovered["status"] == "done" && recovered["credits_charged"] == 0 && recovered["credits_unknown"] == 2.5,
            "recovered while its bill is under review: the 2.5 unknown stays, 0.1 is never booked as the charge: \(recovered)")
}

/// A one-line voiceover whose batch download gives up; returns the failed job's answer and its row.
@MainActor
private func heldVoiceover(_ fixture: VoiceRecoveryFixture) async throws -> (JSONValue, SkyStudioMediaStatus)? {
    SkyStudioSpendStore.shared.setDailyLimit(100_000)   // the checks before these spent part of the fixture's 1,000
    VoiceRecoveryHTTP.fileDrops = 3
    let started = try fixture.started(await fixture.narrate(["Hello world."]))
    let id = started.payload["job_id"]?.stringValue ?? ""
    let failed = try await fixture.wait(started)
    guard let job = AIJobs.shared.job(id), let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id }),
          row.retryDownload != nil else {
        require(false, "the failed voiceover row offers Download again: \(failed)")
        return nil
    }
    let detail = AIJobs.shared.json(job)
    let next = detail["next_step"]?.stringValue ?? ""
    require(failed["status"] == "failed" && detail["code"] == "download_network" && detail["download_attempts"] == 3
            && next.contains("Download again") && next.contains("resume=") && next.contains("is a new voiceover and is charged again"),
            "a voiceover batch whose download gave up: download_network after three GETs; the row and the recovery file named: \(detail)")
    return (detail, row)
}

/// Presses the row's Download again and waits until the row gives way to its recovery (it reads the record first): the recovery job
/// for `file`, or nil when it already ended (an inserted voiceover ends at once).
@MainActor
private func pressDownloadAgain(_ row: SkyStudioMediaStatus, recovering file: String) async -> AIJobs.Job? {
    row.retryDownload?()
    await voiceoverEventually("the row to give way to its recovery") { !SkyStudioGenerationActivity.shared.runs.contains { $0 === row } }
    return SkyStudioVoiceRecovery.active[file].flatMap { AIJobs.shared.job($0) }
}

@MainActor
private func voiceoverEventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<1500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

@MainActor
private func rowRecovers(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("voiceover-download"))
    guard let (failed, row) = try await heldVoiceover(fixture), let file = failed["recovery_file"]?.stringValue else { return }
    require(row.issue == SkyStudioDownloadWords.shown(SkyStudioDownloadFailure(kind: .interrupted, attempts: 3, lastError: "")),
            "the row reads the localized line")
    let posts = VoiceRecoveryHTTP.posts
    guard let job = await pressDownloadAgain(row, recovering: file) else {
        return require(false, "Download again starts the voiceover's recovery as a job")
    }
    await AIJobs.shared.wait(for: job, seconds: 30)
    let done = AIJobs.shared.json(job)
    require(done["status"] == "done", "the recovery downloads the batch and lands the voiceover: \(done)")
    require(VoiceRecoveryHTTP.posts == posts && VoiceRecoveryHTTP.log.filter { $0.0 == "GET" && $0.1.hasPrefix("/files/") }.count == 4,
            "nothing is generated again: the same batch downloaded once more")
    require(fixture.project.state.audioTracks.flatMap(\.clips).count == 1, "the voiceover is on the timeline, once")
}

@MainActor
private func resumedThenRow(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("voiceover-resumed"))
    guard let (failed, row) = try await heldVoiceover(fixture), let file = failed["recovery_file"]?.stringValue else {
        return require(false, "the failed voiceover names its recovery file")
    }
    // The AI recovers it first (add_voiceover resume=recovery_file): one segment on the timeline.
    let resumed = try await fixture.resume(file)
    require(resumed["status"] == "done" && fixture.project.state.audioTracks.flatMap(\.clips).count == 1, "resume lands the voiceover once")
    let posts = VoiceRecoveryHTTP.posts
    let state = fixture.project.state

    // Then the old row's Download again: it reads the record as it is now, finds it inserted, and adds nothing.
    if let job = await pressDownloadAgain(row, recovering: file) { await AIJobs.shared.wait(for: job, seconds: 30) }
    await voiceoverEventually("the old row's recovery to end") { SkyStudioVoiceRecovery.active[file] == nil }
    require(fixture.project.state == state && fixture.project.state.audioTracks.flatMap(\.clips).count == 1 && VoiceRecoveryHTTP.posts == posts,
            "one segment still: the old row never lands the voiceover a second time, and nothing is generated")
}

@MainActor
private func stoppedWhileDownloading(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("voiceover-stopped"))
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    VoiceRecoveryHTTP.lock.withLock { VoiceRecoveryHTTP.holdFiles = true }
    let started = try fixture.started(await fixture.narrate(["Hello world."]))
    guard let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { return require(false, "the voiceover starts") }
    for _ in 0..<1500 {
        if VoiceRecoveryHTTP.log.contains(where: { $0.0 == "GET" && $0.1.hasPrefix("/files/") }) { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    AIJobs.shared.cancel(job)
    await AIJobs.shared.wait(for: job, seconds: 30)
    let stopped = AIJobs.shared.json(job)
    let row = SkyStudioGenerationActivity.shared.runs.first { $0.aiJobID == id }
    require(stopped["status"] == "cancelled" && stopped["code"] == "download_stopped" && row?.retryDownload != nil,
            "the user's stop while the batch downloads keeps the row's Download again (download_stopped): \(stopped)")
    VoiceRecoveryHTTP.lock.withLock { VoiceRecoveryHTTP.holdFiles = false }
    guard let row, let file = stopped["recovery_file"]?.stringValue, let recovery = await pressDownloadAgain(row, recovering: file) else {
        return require(false, "Download again after the stop starts the recovery")
    }
    await AIJobs.shared.wait(for: recovery, seconds: 30)
    require(AIJobs.shared.json(recovery)["status"] == "done" && fixture.project.state.audioTracks.flatMap(\.clips).count == 1,
            "Download again after the stop lands the voiceover")
}

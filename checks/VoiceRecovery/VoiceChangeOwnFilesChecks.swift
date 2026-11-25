import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A voice change's files belong to its own cloud job (2026-11-26, CXD3 on PR #554; docs/bugfixes/2026-11-24-download-lost-connection-
// no-retry.md), with real App objects and the fake Sky Studio (VoiceChangeHTTP):
// - two running changes of the same clip and voice never choose the same names (VoiceChangeOutputName.claim), and a name is free again
//   once its change is done with it;
// - a new Chinese change downloading while the held English one's Download again lands: cancelling the Chinese one leaves the English
//   files, on the timeline, as they were (both once chose the same two paths, and the cancel deleted them);
// - a stop during the background's download says both GETs (it once said 1 of the 2 the server saw), keeps the voice it wrote while a
//   timeline uses it and a file someone else put at its background's name, and deletes the voice it wrote when nothing uses it.

@MainActor
func runVoiceChangeOwnFilesChecks(_ root: URL) async throws {
    try claimChecks(root)
    try await cancelKeepsOtherJobsFiles(root)
    try await stopDuringBackground(root)
}

@MainActor
private func changeArgs(_ fixture: VoiceChangeFixture, _ clipID: UUID, language: String) -> JSONValue {
    ["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": .string(language)]
}

@MainActor
private func claimChecks(_ root: URL) throws {
    let folder = root.appendingPathComponent("change-claims", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let original = folder.appendingPathComponent("talk.wav")
    func claim() -> (voice: URL, background: URL) {
        VoiceChangeOutputName.claim(original: original, voiceName: "Sky", backgroundLabel: "background", voiceExtension: "wav",
                                    backgroundExtension: "wav", fallbacks: [])
    }
    let first = claim(), second = claim()
    require(Set([first.voice, first.background, second.voice, second.background]).count == 4,
            "two running changes of the same clip and voice choose four different paths: \(first), \(second)")
    VoiceChangeOutputName.release(first)
    VoiceChangeOutputName.release(second)
    let again = claim()
    require(again.voice == first.voice && again.background == first.background, "a released name is free again: \(again)")
    VoiceChangeOutputName.release(again)
}

/// The held English change's Download again lands while a new Chinese change of the same clip and voice is downloading; cancelling
/// the Chinese one leaves the English files on the timeline.
@MainActor
private func cancelKeepsOtherJobsFiles(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-own-files"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.fileDrops = 3 }
    let english = try await fixture.change(changeArgs(fixture, clipID, language: "en"))
    _ = try await fixture.wait(english)
    guard let englishID = english.payload["job_id"]?.stringValue, let englishJob = AIJobs.shared.job(englishID),
          let englishRow = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == englishID }), englishRow.retryDownload != nil else {
        return require(false, "the English change is held with Download again: \(english.payload)")
    }

    // The Chinese change, its voice's GET unanswered: downloading, nothing written yet.
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdNext["voice.wav"] = 1 }
    let chinese = try await fixture.change(changeArgs(fixture, clipID, language: "zh"))
    guard let chineseID = chinese.payload["job_id"]?.stringValue, let chineseJob = AIJobs.shared.job(chineseID) else {
        return require(false, "the Chinese change starts: \(chinese.payload)")
    }
    await ownFilesEventually("the Chinese change's voice GET") { VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdNext["voice.wav"] } == 0 }

    // The English change's own row: its files land.
    englishRow.retryDownload?()
    await AIJobs.shared.wait(for: englishJob, seconds: 30)
    let landed = AIJobs.shared.json(englishJob)
    let englishFiles = ["voice_file", "background_file"].compactMap { landed[$0]?.stringValue.map { AIWorkspace.shared.resolve($0) } }
    require(landed["status"] == "done" && englishFiles.count == 2, "the English change lands its two files: \(landed)")
    let onTimeline = fixture.project.state

    // Cancel the Chinese change: the English files stay, as they were, on the timeline.
    AIJobs.shared.cancel(chineseJob)
    await ownFilesEventually("the Chinese change to stop") { chineseJob.status != .running }
    let stopped = AIJobs.shared.json(chineseJob)
    require(stopped["code"] == "download_stopped" && stopped["download_attempts"] == 1, "the Chinese change stopped after its one GET: \(stopped)")
    require(englishFiles.count == 2 && (try? Data(contentsOf: englishFiles[0])) == VoiceChangeHTTP.wave(seconds: 4.02)
            && (try? Data(contentsOf: englishFiles[1])) == VoiceChangeHTTP.wave(seconds: 4) && fixture.project.state == onTimeline,
            "cancelling the Chinese change leaves the English files whole and on the timeline: \(englishFiles.map(\.lastPathComponent))")
}

/// Stopped while its background downloads: both GETs said; the voice it wrote stays while a timeline uses it, and a file someone else
/// put at its background's name stays; with nothing using its voice, the voice goes.
@MainActor
private func stopDuringBackground(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-stop-background"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let media = fixture.folder.appendingPathComponent("media")
    let voice = media.appendingPathComponent("talk - Sky.wav")
    let background = media.appendingPathComponent("talk - \(L10n("background (file name)")).wav")
    let someoneElses = Data("someone else's file".utf8)

    /// A change whose background GET gets no answer; `meanwhile` runs once its voice is here; then it is cancelled.
    func stopped(_ meanwhile: () -> Void) async throws -> JSONValue {
        VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdNext["background.wav"] = 1 }
        let started = try await fixture.change(changeArgs(fixture, clipID, language: "en"))
        guard let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("no job: \(started.payload)") }
        await ownFilesEventually("the background's GET") { VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdNext["background.wav"] } == 0 }
        meanwhile()
        AIJobs.shared.cancel(job)
        await ownFilesEventually("the change to stop") { job.status != .running }
        return AIJobs.shared.json(job)
    }

    // Its voice on a timeline and someone else's file at its background's name: both stay.
    let first = try await stopped {
        require(FileManager.default.fileExists(atPath: voice.path) && !FileManager.default.fileExists(atPath: background.path),
                "the voice is here, the background not yet")
        try? someoneElses.write(to: background)
        let clip = EditClip(sourceURL: voice, isAudioOnly: true, sourceStart: 0, sourceDuration: 1, timelineStart: 0, audioAssetDuration: 4.02)
        fixture.project.perform { $0.audioTracks.append(EditLane(clips: [clip])) }
    }
    require(first["status"] == "cancelled" && first["code"] == "download_stopped" && first["download_attempts"] == 2,
            "a stop during the background's download says both GETs (the voice's and the background's): \(first)")
    require(FileManager.default.fileExists(atPath: voice.path), "the voice it wrote stays while a timeline uses it")
    require((try? Data(contentsOf: background)) == someoneElses, "a file someone else put at its background's name stays as it was")

    // Nothing uses the next one's voice: it goes, and nothing of it is left.
    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? [])
    var second: URL?
    let next = try await stopped {
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? [])
        second = now.subtracting(before).first.map { media.appendingPathComponent($0) }
    }
    require(next["code"] == "download_stopped" && second != nil && !FileManager.default.fileExists(atPath: second?.path ?? "/"),
            "a voice nothing uses is deleted at the stop: \(second?.lastPathComponent ?? "none")")
    require(Set((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []) == before, "nothing of it is left in the folder")
}

@MainActor
private func ownFilesEventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<1500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

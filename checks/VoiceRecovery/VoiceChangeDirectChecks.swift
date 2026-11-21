import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Direct voice change and the separation failure (2026-11-21; contract in Sky Studio's docs/agents/skycut-api.md "voice_convert",
// rules in docs/architecture/voice-library.md section 11, item 12). Real App objects against the fake Sky Studio (VoiceChangeHTTP):
// - landing (pure): a voice-only result lands on one new track at the clip's time window, the original muted and linked;
// - change_voice skip_separation=true: the quote and the job both carry skip_separation true, only the voice is downloaded,
//   it lands on one new track, and one undo removes it and unmutes the source;
// - a direct quote Sky Studio does not confirm starts and charges nothing; a default result without its background lands nothing;
// - separation_failed: the job fails, nothing lands, the source stays unmuted, the books keep only the separation's part, the AI
//   is told to retry with skip_separation; from the panel the notice bar says so and the panel opened again starts direct;
// - the panel's checkbox re-quotes with the new value and Start sends exactly the quoted value.

@MainActor
func runVoiceChangeDirectChecks(_ root: URL) async throws {
    directLandingChecks()
    try await directToolChecks(root)
    try await refusedDirectChecks(root)
    try await separationFailureChecks(root)
    try await directPanelChecks(root)
}

// MARK: Landing (pure)

@MainActor
private func directLandingChecks() {
    let source = URL(fileURLWithPath: "/media/omni intro.mp4")
    let clip = EditClip(sourceURL: source, isAudioOnly: true, sourceStart: 1, sourceDuration: 4, timelineStart: 2, volume: 0.7, audioAssetDuration: 15)
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [clip])]
    let before = state
    let origin = VoiceChangeLanding.Origin(clipID: clip.id, sourceURL: source, sourceStart: 1, sourceDuration: 4)
    let files = VoiceChangeLanding.Files(voice: URL(fileURLWithPath: "/media/omni intro - Sky.wav"), voiceSeconds: 4.02)
    guard case .success(let landed) = VoiceChangeLanding.land(files, origin: origin, in: &state), let voice = state.clip(with: landed.voiceID) else {
        return require(false, "a voice-only result lands")
    }
    require(landed.backgroundID == nil && landed.backgroundTrack == nil && landed.voiceTrack == 1 && state.audioTracks.count == 2
            && state.audioTracks[1].clips.map(\.id) == [voice.id], "a direct change adds exactly one new track, holding the voice")
    require(state.clip(with: clip.id)?.isMuted == true && state.linkedClipIDs(of: clip.id) == [clip.id, voice.id],
            "the original is muted, not deleted, and linked to the new voice")
    require(voice.timelineStart == 2 && voice.sourceStart == 0 && voice.sourceDuration == 4 && voice.audioAssetDuration == 4.02 && voice.volume == 0.7,
            "the voice sits at the source's time window with its volume, trimmed to it")
    var widened = before
    widened.update(clip.id) { $0.sourceStart = 0; $0.sourceDuration = 6 }
    let widenedBefore = widened
    require(VoiceChangeLanding.land(files, origin: origin, in: &widened) == .failure(.notCovered) && widened == widenedBefore,
            "a voice-only result still lands nothing on a clip trimmed outwards")
}

// MARK: change_voice skip_separation=true

@MainActor
private func directToolChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("direct-tool"))
    let source = try fixture.stereoSource()
    let clipID = fixture.placeClip(source)
    let before = fixture.project.state
    let spent = SkyStudioSpendStore.shared.spentToday()
    let started = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID),
                                            "language": "en", "skip_separation": true])
    require(started.payload["status"] == "started" && started.payload["skip_separation"] == true && started.payload["credits"] == 5
            && started.payload["next_step"]?.stringValue?.contains("one new linked audio track") == true,
            "a direct change returns the direct price and says it lands on one track: \(started.payload)")
    let done = try await fixture.wait(started)
    let quotes = VoiceChangeHTTP.calls("POST", "/quote"), jobs = VoiceChangeHTTP.calls("POST", "/jobs")
    require(quotes.count == 1 && jobs.count == 1 && quotes[0]["params"]?["skip_separation"] == true && jobs[0]["params"]?["skip_separation"] == true
            && jobs[0]["max_credits"] == 5, "the quote and the job both carry skip_separation true, the direct quote is max_credits: \(quotes) \(jobs)")
    require(done["status"] == "done" && done["skip_separation"] == true && done["voice_clip_id"] != nil && done["voice_track"] == "A2"
            && done["background_clip_id"] == nil && done["background_file"] == nil && done["background_track"] == nil && done["credits_charged"] == 5,
            "get_job reports one voice clip and no background: \(done)")
    require(!VoiceChangeHTTP.log.contains { $0.path.hasSuffix("/files/background.wav") }, "nothing but the voice is downloaded")
    let state = fixture.project.state
    guard state.audioTracks.count == 2, let voice = state.audioTracks[1].clips.first, state.audioTracks[1].clips.count == 1 else {
        return require(false, "the voice lands on one new track: \(state.audioTracks.map(\.clips.count))")
    }
    require(state.clip(with: clipID)?.isMuted == true && voice.timelineStart == 2 && voice.sourceDuration == 4 && voice.linkGroup != nil
            && voice.linkGroup == state.clip(with: clipID)?.linkGroup, "the original clip is muted; the voice is linked to it at its time window")
    let saved = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).filter { $0.hasPrefix("talk - ") }
    require(saved == ["talk - Sky.wav"], "only the voice file is saved next to the source: \(saved)")
    require(abs(SkyStudioSpendStore.shared.spentToday() - spent - 5) < 0.0001, "the books hold the direct charge")
    guard let manager = fixture.project.effectiveUndoManager else { return require(false, "the project has an undo manager") }
    manager.undo()
    require(fixture.project.state == before && !manager.canUndo, "one undo removes the new track and the source plays again")
    manager.redo()
    require(fixture.project.state == state, "one redo lands it again")
}

// MARK: Refused or not landed

@MainActor
private func refusedDirectChecks(_ root: URL) async throws {
    // A server that ignores skip_separation would separate and charge for it: the quote does not confirm it, nothing starts.
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("direct-unconfirmed"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let spent = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.quoteIgnoresSkip = true }
    do {
        let result = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID),
                                               "language": "en", "skip_separation": true])
        require(false, "a direct quote Sky Studio does not confirm is refused, not \(result.payload)")
    } catch let error as AIToolError {
        require(error.message.contains("skip_separation") && error.message.contains("Nothing was started or charged"), "the refusal says why: \(error.message)")
    }
    require(VoiceChangeHTTP.calls("POST", "/uploads").isEmpty && VoiceChangeHTTP.calls("POST", "/jobs").isEmpty
            && SkyStudioSpendStore.shared.spentToday() == spent && fixture.project.state.audioTracks.count == 1,
            "nothing is uploaded, started, charged or changed")
    require(((try? FileManager.default.contentsOfDirectory(atPath: fixture.services.workFolder.path)) ?? []).isEmpty,
            "the prepared sound is deleted when nothing starts")

    // A default change whose result has no background lands nothing (the background would be lost from the mix).
    let missing = try VoiceChangeFixture(folder: root.appendingPathComponent("default-no-background"))
    let other = missing.placeClip(try missing.stereoSource())
    let untouched = missing.project.state
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.omitBackground = true }
    let failed = try await missing.wait(try await missing.change(["clip_id": .string(missing.short(other)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    require(failed["status"] == "failed" && failed["message"]?.stringValue?.contains("background") == true,
            "a default result without its background fails and says so: \(failed)")
    require(missing.project.state == untouched, "nothing lands and the source is not muted")
    for row in SkyStudioGenerationActivity.shared.runs where row.issue != nil { SkyStudioGenerationActivity.shared.dismiss(row) }
}

// MARK: separation_failed

@MainActor
private func separationFailureChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("separation-failed"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    let spent = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.separationFails = true }
    let failed = try await fixture.wait(try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    require(failed["status"] == "failed" && failed["code"] == "separation_failed" && failed["credits_charged"] == 6.5
            && failed["failure"]?["code"] == "separation_failed" && failed["next_step"]?.stringValue?.contains("skip_separation=true") == true,
            "a failed separation is a failed job with its code, the separation's charge and when to retry directly: \(failed)")
    require(fixture.project.state == before && fixture.project.state.clip(with: clipID)?.isMuted == false, "nothing lands; the source keeps playing")
    require(abs(SkyStudioSpendStore.shared.spentToday() - spent - 6.5) < 0.0001,
            "the books keep only the separation's part, 6.5 of the 9 reserved (\(SkyStudioSpendStore.shared.spentToday() - spent))")
    require(VoiceChangeActivity.shared.separationFailed(clipID) && VoiceChangeHTTP.calls("POST", "/jobs").count == 1,
            "the clip is remembered for a direct retry; the job is not sent again")
    let row = SkyStudioGenerationActivity.shared.runs.first { $0.issue != nil }
    require(row?.issue == L10n("Voice separation failed; you can change the voice directly instead."),
            "the cloud task row shows the localized separation line: \(row?.issue ?? "none")")
    if let row { SkyStudioGenerationActivity.shared.dismiss(row) }
    require(fixture.project.notice == nil, "a change the AI started says nothing in the notice bar")

    // The AI retries the same clip directly: it lands and the clip is no longer marked.
    let retry = try await fixture.wait(try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID),
                                                                 "language": "en", "skip_separation": true]))
    require(retry["status"] == "done" && retry["background_clip_id"] == nil && VoiceChangeHTTP.calls("POST", "/jobs").last?["params"]?["skip_separation"] == true
            && !VoiceChangeActivity.shared.separationFailed(clipID), "a direct retry lands one track and forgets the failed separation: \(retry)")
}

// MARK: The panel

@MainActor
private func directPanelChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("direct-panel"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let store = VoiceLibraryStore()
    store.readKey = { .success("local-voice-change-fixture") }
    store.api = fixture.api
    fixture.detected = "en"
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.separationFails = true }
    guard let model = VoiceChangePanelModel(project: fixture.project, clipID: clipID, store: store) else { return require(false, "the panel opens") }
    model.services = fixture.services
    require(!model.skipSeparation && !model.separationFailedBefore, "a clip without a failed separation opens with the separation")
    await model.open()
    await panelEventually("the default quote") { model.quote != nil }
    require(VoiceChangeHTTP.calls("POST", "/quote").last?["params"]?["skip_separation"] == false && model.quote?.credits == 9, "the default is quoted with skip_separation false")
    let before = fixture.project.state
    require(model.start(), "Start sends the default change")
    model.close()
    await panelEventually("the notice") { fixture.project.notice != nil }
    require(fixture.project.notice?.contains(L10n("Voice separation failed; you can change the voice directly instead.")) == true,
            "the notice bar says the separation failed and the direct change is there: \(fixture.project.notice ?? "")")
    require(fixture.project.state == before, "nothing landed from the panel either")
    for row in SkyStudioGenerationActivity.shared.runs where row.issue != nil { SkyStudioGenerationActivity.shared.dismiss(row) }

    // Opened again on that clip: the line is there and the direct option is already on; switching it re-quotes.
    guard let again = VoiceChangePanelModel(project: fixture.project, clipID: clipID, store: store) else { return require(false, "the panel opens again") }
    again.services = fixture.services
    require(again.separationFailedBefore && again.skipSeparation, "the panel opened again on that clip starts with the direct option on")
    await again.open()
    await panelEventually("the direct quote") { again.quote != nil }
    require(VoiceChangeHTTP.calls("POST", "/quote").last?["params"]?["skip_separation"] == true && again.quote?.credits == 5, "the direct option is quoted as direct")
    let asked = VoiceChangeHTTP.calls("POST", "/quote").count
    again.skipSeparation = false
    require(again.quote == nil, "switching the option drops the price in hand")
    await panelEventually("the default quote again") { again.quote != nil }
    require(VoiceChangeHTTP.calls("POST", "/quote").count == asked + 1 && VoiceChangeHTTP.calls("POST", "/quote").last?["params"]?["skip_separation"] == false
            && again.quote?.credits == 9, "and asks again for the default")
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.quoteIgnoresSkip = true }
    again.skipSeparation = true
    await panelEventually("the unconfirmed direct quote") { if case .failed = again.offer { return true }; return false }
    require(again.quote == nil && !again.start(), "a direct quote Sky Studio does not confirm offers no price and starts nothing")
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.quoteIgnoresSkip = false }
    again.skipSeparation = false
    again.skipSeparation = true
    await panelEventually("the direct quote once more") { again.quote != nil }
    require(again.start(), "Start sends the direct change")
    again.close()
    await panelEventually("the direct change to land") { fixture.project.state.audioTracks.count == 2 }
    let job = VoiceChangeHTTP.calls("POST", "/jobs").last
    require(job?["params"]?["skip_separation"] == true && job?["max_credits"] == 5, "the job carries the value the quote had: \(String(describing: job))")
    require(fixture.project.state.clip(with: clipID)?.isMuted == true && fixture.project.state.audioTracks[1].clips.count == 1
            && !VoiceChangeActivity.shared.separationFailed(clipID), "one track lands, the source is muted, the failed separation is forgotten")
    let manager = fixture.project.effectiveUndoManager
    manager?.undo()
    require(fixture.project.state == before && manager?.canUndo == false, "a direct change from the panel is one undo step")
}

@MainActor
private func panelEventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<1500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

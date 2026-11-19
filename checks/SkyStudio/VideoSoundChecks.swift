import Foundation
import SrtFlowMCPKit

// A generated video's own sound (2026-11-19, MCP-42), against Sky Studio's own catalog records (models-music-video-2026-11-19.json):
// `audio_mode` none only where the model lists it (refused before the quote elsewhere, in plain words), ambient and full where
// listed, nothing sent when not asked (a default request stays what it was), generate_audio sent agreeing with the mode; the
// finished job's `audio` block reaches the AI with a note to listen before laying narration over a clip that may carry a bed.
// Request bodies go through the fake Sky Studio (SkyStudioStub). No network, no credits.
@MainActor
func runVideoSoundChecks() async {
    guard let catalog = musicVideoCatalog() else { check(false, "the 2026-11-19 music / video catalog loads"); return }
    func model(_ id: String, _ kind: String = "text_to_video") -> SkyStudioModel? { catalog.model(id, kind: kind) }
    guard let h3 = model("minimax-h3"), let seedance = model("seedance-2-pro"), let wan = model("wan-3.0-text-to-video"),
          let veo = model("veo-fast") else { check(false, "the video records are in the catalog"); return }

    // 1. Which modes each model takes comes from its record.
    checkEqual(SkyStudioVideoSound.modes(of: h3), ["full", "ambient"], "MiniMax H3 always makes sound")
    checkEqual(SkyStudioVideoSound.modes(of: veo), ["full", "ambient"], "Veo is not offered none (the user chose not to test it)")
    checkEqual(SkyStudioVideoSound.modes(of: seedance), ["full", "ambient", "none"], "Seedance can turn sound off")
    checkEqual(SkyStudioVideoSound.modes(of: wan), ["full", "ambient", "none"], "Wan can turn sound off")
    for record in catalog.models where SkyStudioVideoSound.applies(record.kind) {
        check(SkyStudioVideoSound.modes(of: record).allSatisfy(MCPVocabulary.videoAudioModes.contains),
              "\(record.id) lists only modes the AI can name")
    }

    // 2. Which model: none moves to the first default video model that can turn sound off; a named one is never swapped.
    func ask(_ mode: String?, generateAudio: Bool? = nil) -> SkyStudioGeneration.Ask {
        var value = SkyStudioGeneration.Ask(generateAudio: generateAudio)
        value.audioMode = mode
        return value
    }
    func pick(_ value: SkyStudioGeneration.Ask, requested: String? = nil) -> String? {
        generationPick(catalog, kind: "text_to_video", ask: value, prompt: "waves at dusk", requested: requested)?.id
    }
    checkEqual(pick(ask(nil)), "minimax-h3", "no mode: the usual default model")
    checkEqual(pick(ask("ambient")), "minimax-h3", "ambient: the usual default model")
    checkEqual(pick(ask("none")), "seedance-2-pro", "none: the first default video model that lists it")
    checkEqual(pick(ask("none"), requested: "minimax-h3"), nil, "none on a named H3 is not swapped for another model")
    let refusal = SkyStudioVideoSound.problem(model: h3, ask: ask("none")) ?? ""
    check(refusal.contains("always makes its own sound") && refusal.contains("lists none in params.audio_mode") && refusal.contains("edit_clip"),
          "none on H3: plain words and what to do instead (\(refusal))")
    check(SkyStudioVideoSound.problem(model: seedance, ask: ask("none", generateAudio: true))?.contains("disagree") == true,
          "audio_mode none with generate_audio true is refused (Sky Studio would refuse it too)")
    checkEqual(SkyStudioVideoSound.problem(model: seedance, ask: ask("none", generateAudio: false)), nil, "the two agreeing is fine")

    // 3. The request: the mode only when asked, generate_audio agreeing where the model has that switch.
    func params(_ value: SkyStudioGeneration.Ask, _ record: SkyStudioModel) -> [String: JSONValue] {
        SkyStudioGeneration.make(.textToVideo, prompt: "waves", ask: value, canvas: 16.0 / 9, model: record).params
    }
    checkEqual(params(ask(nil), seedance)["audio_mode"], nil, "not asked: no audio_mode, so a default request stays what it was")
    checkEqual(params(ask(nil), seedance)["generate_audio"], true, "not asked: Seedance's default sound as before")
    checkEqual(params(ask(nil), h3)["generate_audio"], nil, "H3 has no switch and is sent none")
    checkEqual(params(ask("none"), seedance)["audio_mode"], "none", "none is sent")
    checkEqual(params(ask("none"), seedance)["generate_audio"], false, "generate_audio agrees with none")
    checkEqual(params(ask("full"), wan)["generate_audio"], true, "generate_audio agrees with full")
    checkEqual(params(ask("ambient"), h3)["audio_mode"], "ambient", "ambient on H3 is sent")
    checkEqual(params(ask("ambient"), h3)["generate_audio"], nil, "and H3 still gets no generate_audio")
    let silent = SkyStudioGeneration.make(.textToVideo, prompt: "waves", ask: ask("none"), canvas: 16.0 / 9, model: seedance)
    checkEqual(silent.summary(modelTitle: seedance.title), "Seedance 2.0 Pro · 5 s · 720p · no sound", "the summary says no sound")
    check(SkyStudioGeneration.make(.music, prompt: "x", ask: ask("none"), canvas: 1).notes.contains { $0.hasPrefix("audio_mode was ignored") },
          "audio_mode on music is said to be ignored")
    let lipsync = SkyStudioModel(id: "lip", kind: "lipsync", title: "Lip")
    check(SkyStudioGenerationControls.problem(model: lipsync, ask: ask("none"), prompt: "", references: .init(mode: "lipsync", files: []))?
            .contains("audio_mode") == true, "lip-sync carries the caller's audio and refuses audio_mode")
    var older = seedance
    older.params["audio_mode"] = nil
    checkEqual(SkyStudioVideoSound.problem(model: older, ask: ask("full")), nil, "an older catalog: full is what it makes anyway")
    checkEqual(params(ask("full"), older)["audio_mode"], nil, "and nothing new is sent to it")
    check(SkyStudioVideoSound.problem(model: older, ask: ask("ambient"))?.contains("does not offer audio_mode") == true,
          "an older catalog: ambient is refused rather than silently dropped")
    let parsed = try? SkyStudioGenerationControls.ask(AIToolArguments(["audio_mode": "ambient"]))
    checkEqual(parsed?.audioMode, "ambient", "audio_mode is read from the tool's arguments")
    check((try? SkyStudioGenerationControls.ask(AIToolArguments(["audio_mode": "quiet"]))) == nil, "an unknown mode is refused")

    // 4. Through the fake Sky Studio: /jobs carries the mode and the switch agreeing.
    SkyStudioStub.reset { _ in .http(202, #"{"job_id": "video-1", "status": "queued", "poll_after_seconds": 5}"#) }
    _ = try? await jobAPI().submit(silent.job(model: seedance.id, maxCredits: 60, idempotencyKey: "sound-1"), key: jobKey)
    let body = SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(body?["params"]?["audio_mode"], "none", "/jobs carries audio_mode none")
    checkEqual(body?["params"]?["generate_audio"], false, "/jobs carries generate_audio false with it")

    // 5. The finished job: Sky Studio's audio block reaches the AI with what to do.
    func done(_ audio: JSONValue?, duration: JSONValue = 5, extra: [String: JSONValue] = [:]) -> SkyStudioJobResult? {
        var result: [String: JSONValue] = ["url": "https://example.invalid/clip.mp4", "content_type": "video/mp4", "duration": duration]
        if let audio { result["audio"] = audio }
        result.merge(extra) { _, new in new }
        return SkyStudioJobStatus(json: ["job_id": "video-1", "status": "done", "result": .object(result)])?.result
    }
    let bedNote = "The model was asked for on-screen sound only (a direction in the prompt, not a switch), so it can still have added a music, drone or low-rumble bed. Listen to it before laying narration over it."
    let ambient = done(["mode": "ambient", "has_track": true, "can_turn_off": false, "may_carry_bed": true, "note": .string(bedNote)])
    let ambientDetail = ambient.map(SkyStudioVideoSound.resultDetail) ?? [:]
    checkEqual(ambientDetail["audio"]?["may_carry_bed"], true, "the audio block reaches get_job as Sky Studio sent it")
    let ambientNote = ambientDetail["note"]?.stringValue ?? ""
    check(ambientNote.hasPrefix(bedNote) && ambientNote.contains("listen describe=true") && ambientNote.contains("edit_clip volume_db"),
          "a clip that may carry a bed: Sky Studio's note, then listen first and how to lower it (\(ambientNote))")
    let none = done(["mode": "none", "has_track": false, "can_turn_off": true, "may_carry_bed": false, "note": "No sound was generated."])
    checkEqual(none.map(SkyStudioVideoSound.resultDetail)?["note"], "No sound was generated.", "no sound: no listening asked for")
    let stray = done(["mode": "none", "has_track": true, "can_turn_off": true, "may_carry_bed": false,
                      "note": "The model was asked for no sound, but the file has a sound track. Listen to it before using it."])
    check(stray.map(SkyStudioVideoSound.resultDetail)?["note"]?.stringValue?.contains("Listen to it before using it") == true,
          "asked for none yet the file has sound: Sky Studio's warning stands")
    let bare = done(["mode": "full", "has_track": .null, "can_turn_off": false, "may_carry_bed": true])
    checkEqual(bare.map(SkyStudioVideoSound.resultDetail)?["note"], .string(SkyStudioVideoSound.listenFirst), "no note from Sky Studio: listen first")
    checkEqual(done(nil).map(SkyStudioVideoSound.resultDetail), ["note": .string(SkyStudioVideoSound.generalNote)],
               "a server from before 2026-11-19: the general note, as before")

    // 6. The delivered length of a video (MCP-9): Sky Studio's own asked and delivered lengths and where it measured.
    let measured = done(["mode": "full", "may_carry_bed": true], duration: 5.17,
                        extra: ["requested_duration": 5, "duration_source": "file"])
    let fields = SkyStudioGenerationDuration.fields(for: SkyStudioGeneration.make(.textToVideo, prompt: "waves", ask: .init(), canvas: 1, model: h3),
                                                    result: measured)
    checkEqual(fields["requested_duration"], 5, "the asked length")
    checkEqual(fields["duration"], 5.17, "H3 makes a few frames more")
    checkEqual(fields["duration_source"], "file", "measured from the file")
    checkEqual(fields["duration_warning"], .null, "a few frames is not a difference worth a warning")
}

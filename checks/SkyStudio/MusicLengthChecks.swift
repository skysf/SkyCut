import Foundation
import SrtFlowMCPKit

// Music length (2026-11-19, MCP-18), against Sky Studio's own catalog records (checks/SkyStudio/Fixtures/
// models-music-video-2026-11-19.json, written by PR #256's buildSkycutModelCatalog): each model's `length` is read, never written
// here; the first music model in the server's order that takes the ask is chosen (a short or exact cue: the exact-length model; a
// song or an automatic length: Lyria); the length goes out in the model's steps, or its default; a request no model can make is
// refused in plain words before any quote; a flat-priced longer piece is not beyond the draft; Sky Studio's own refusals get a plain
// next step. The request bodies go through the fake Sky Studio (SkyStudioStub). No network, no credits.

/// The music and video records of Sky Studio's catalog on 2026-11-19 (Lyria first).
func musicVideoCatalog() -> SkyStudioCatalog? {
    let url = URL(fileURLWithPath: "checks/SkyStudio/Fixtures/models-music-video-2026-11-19.json")
    guard let data = try? Data(contentsOf: url), let json = try? JSONValue.decode(data) else { return nil }
    return SkyStudioCatalog(json: json)
}

/// What the tool's `accepts` closure asks of each candidate (SkyStudioGenerateTool): the model policy, then the controls.
func generationPick(_ catalog: SkyStudioCatalog, kind: String, ask: SkyStudioGeneration.Ask, prompt: String = "a calm piano cue",
                    requested: String? = nil) -> SkyStudioModel? {
    let none = SkyStudioReferencePlan(mode: "frames", files: [])
    return SkyStudioModelPolicy.select(catalog: catalog, kind: kind, requested: requested, accepts: { model in
        SkyStudioModelPolicy.problem(model: model, ask: ask, references: none) == nil
            && SkyStudioGenerationControls.problem(model: model, ask: ask, prompt: prompt, references: none) == nil
    })
}

@MainActor
func runMusicLengthChecks() async {
    guard let catalog = musicVideoCatalog() else { check(false, "the 2026-11-19 music / video catalog loads"); return }
    let music = catalog.models(kind: "music")
    checkEqual(music.map(\.id), ["lyria-3-pro", "stable-audio-3-medium"], "Lyria stays the first music record")
    guard music.count == 2, let lyria = SkyStudioMusicLength(model: music[0]), let exact = SkyStudioMusicLength(model: music[1]) else {
        check(false, "both music records carry a length"); return
    }

    // 1. Each model's length comes from its record.
    checkEqual(lyria, SkyStudioMusicLength(exact: false, auto: true, defaultSeconds: nil, minSeconds: 60, maxSeconds: 180, stepSeconds: 1,
                                           typicalErrorSeconds: 3), "Lyria: approximate, automatic, 60-180 s in whole seconds")
    checkEqual(exact, SkyStudioMusicLength(exact: true, auto: false, defaultSeconds: 30, minSeconds: 1, maxSeconds: 380, stepSeconds: 0.1,
                                           typicalErrorSeconds: 0.05), "the exact-length model: exact, 1-380 s in 0.1 s, 30 s by default")
    var older = music[0]
    older.metadata["length"] = nil
    older.defaults = [:]
    checkEqual(SkyStudioMusicLength(model: older), SkyStudioMusicLength(exact: false, auto: true, defaultSeconds: nil, minSeconds: 60,
               maxSeconds: 180), "a catalog from before the length block: params.duration stands in")
    older.params["duration"] = nil
    check(SkyStudioMusicLength(model: older) == nil, "a record with no length at all: nothing to check, Sky Studio judges")
    check(SkyStudioMusicLength(model: catalog.models(kind: "text_to_video")[0]) == nil, "video records have no music length")

    // 2. Rounding to the model's steps (Sky Studio rounds the same way) and the text in the summary.
    for (asked, sent) in [(12.34, 12.3), (12.36, 12.4), (0.96, 1.0), (379.98, 380.0), (20.0, 20.0)] {
        checkEqual(exact.rounded(asked), sent, "the exact-length model takes 0.1 s steps: \(asked)")
    }
    checkEqual(lyria.rounded(90.4), 90, "Lyria takes whole seconds")
    checkEqual(lyria.rounded(90.5), 91, "Lyria takes whole seconds, half up")
    checkEqual(SkyStudioMusicLength.text(12.3), "12.3", "seconds text without trailing zeros")
    checkEqual(SkyStudioMusicLength.text(30), "30", "whole seconds text")

    // 3. Which model: the first in the server's order whose length (and vocals) take the ask.
    func pick(_ ask: SkyStudioGeneration.Ask, requested: String? = nil) -> String? {
        generationPick(catalog, kind: "music", ask: ask, requested: requested)?.id
    }
    var auto = SkyStudioGeneration.Ask()
    auto.smartDuration = true
    var exact90 = SkyStudioGeneration.Ask(duration: 90)
    exact90.exactLength = true
    checkEqual(pick(.init()), "lyria-3-pro", "no length: the song model chooses its own")
    checkEqual(pick(auto), "lyria-3-pro", "auto: the song model")
    checkEqual(pick(.init(duration: 90)), "lyria-3-pro", "90 s, not exact: the song model")
    checkEqual(pick(exact90), "stable-audio-3-medium", "90 s exact: the exact-length model")
    checkEqual(pick(.init(duration: 20)), "stable-audio-3-medium", "a 20 s cue: the exact-length model (under the song model's minute)")
    checkEqual(pick(.init(duration: 240)), "stable-audio-3-medium", "240 s instrumental: past the song model's range")
    checkEqual(pick(.init(duration: 120, instrumental: false, lyrics: "la la")), "lyria-3-pro", "a song with words: the song model")
    checkEqual(pick(.init(duration: 20), requested: "lyria-3-pro"), nil, "a named model that cannot make 20 s is not swapped")
    var serverFirst = catalog
    serverFirst.models = catalog.models.filter { $0.id != "lyria-3-pro" } + catalog.models.filter { $0.id == "lyria-3-pro" }
    checkEqual(generationPick(serverFirst, kind: "music", ask: .init())?.id, "stable-audio-3-medium",
               "the order is the server's: with the exact-length model first, it takes an ask with no length")

    // 4. The request: the asked seconds in the model's steps; none asked: its default, or nothing for an automatic length.
    func made(_ ask: SkyStudioGeneration.Ask, _ model: SkyStudioModel) -> SkyStudioGeneration {
        SkyStudioGeneration.make(.music, prompt: "x", ask: ask, canvas: 16.0 / 9, model: model)
    }
    checkEqual(made(.init(duration: 12.34), music[1]).params, ["duration": 12.3, "instrumental": true], "an exact cue: 0.1 s steps")
    checkEqual(made(.init(), music[1]).params["duration"], 30, "no length on the exact-length model: its default 30 s is sent")
    checkEqual(made(.init(), music[0]).params, ["instrumental": true], "no length on Lyria: none sent, it chooses (as before)")
    checkEqual(made(auto, music[0]).params["duration"], nil, "auto on Lyria: none sent")
    checkEqual(made(.init(duration: 90.4, instrumental: false, lyrics: "la"), music[0]).params,
               ["duration": 90, "instrumental": false, "lyrics": "la"], "a song: whole seconds, words sent")
    checkEqual(made(.init(duration: 12.34), music[1]).summary(modelTitle: music[1].title), "Stable Audio 3 Medium · 12.3 s",
               "the summary shows tenths")
    checkEqual(made(.init(), music[1]).summary(modelTitle: music[1].title), "Stable Audio 3 Medium · 30 s", "the default in the summary")
    var noteAsk = SkyStudioGeneration.Ask(duration: 5)
    noteAsk.exactLength = true
    check(SkyStudioGeneration.make(.soundEffect, prompt: "x", ask: noteAsk, canvas: 1).notes.contains { $0.hasPrefix("exact_length was ignored") },
          "exact_length on another kind is said to be ignored")

    // 5. Refusals in plain words, before any quote.
    func refusal(_ ask: SkyStudioGeneration.Ask) -> String { SkyStudioMusicLength.refusal(music, ask: ask) ?? "" }
    let tooLong = refusal(.init(duration: 400))
    check(tooLong.contains("60–180 s") && tooLong.contains("1–380 s") && tooLong.hasPrefix("No music model takes this request."),
          "a length outside every range names each model's range: \(tooLong)")
    let sungCue = refusal(.init(duration: 20, instrumental: false))
    check(sungCue.contains("instrumental music only") && sungCue.contains("60–180 s"), "a 20 s song: why each model cannot: \(sungCue)")
    var exactSong = SkyStudioGeneration.Ask(duration: 90, instrumental: false)
    exactSong.exactLength = true
    let exactSung = refusal(exactSong)
    check(exactSung.contains("only aims at a length (it lands within about 3 s)") && exactSung.contains("instrumental music only"),
          "an exact length with vocals: both reasons: \(exactSung)")
    var noLength = SkyStudioGeneration.Ask()
    noLength.exactLength = true
    checkEqual(refusal(noLength), "No music model takes this request. exact_length=true needs duration: the length in seconds. "
               + "get_status models=true lists each music model's length.", "exact_length without a length, said once")
    check(SkyStudioMusicLength.refusal(music, ask: .init(duration: 20)) == nil, "no refusal when a model takes it")
    let noAuto = SkyStudioMusicLength.problem(model: music[1], ask: auto) ?? ""
    check(noAuto.contains("has no automatic length") && noAuto.contains("1–380 s"), "auto on the exact-length model: plain words: \(noAuto)")
    checkEqual(SkyStudioGenerationControls.problem(model: music[0], ask: auto, prompt: "x", references: .init(mode: "frames", files: [])), nil,
               "auto on Lyria is not refused as a missing smart duration")

    // 6. The draft: a piece priced per clip or song costs the same at any length.
    checkEqual(AIDraftPolicy.deviations(made(.init(duration: 120), music[1]), model: music[1]), [],
               "120 s on the per-clip model is not beyond the draft (same price as its 30 s default)")
    var perSecond = music[1]
    perSecond.price = ["per": "second", "credits": 1]
    checkEqual(AIDraftPolicy.deviations(made(.init(duration: 120), perSecond), model: perSecond).count, 1,
               "a music model priced by the second still needs approval past its default")

    // 7. The AI's words: exact_length and auto read from the tool's arguments.
    let parsed = try? SkyStudioGenerationControls.ask(AIToolArguments(["duration": 20, "exact_length": true]))
    checkEqual(parsed?.exactLength, true, "exact_length is read")
    checkEqual(parsed?.duration, 20, "with its length")
    checkEqual((try? SkyStudioGenerationControls.ask(AIToolArguments(["duration": "auto"])))?.smartDuration, true, "auto is read")

    await musicRequestChecks(music)
    skyStudioRefusalChecks()
}

/// The bodies that reach the fake Sky Studio, and Sky Studio's own refusal coming back.
@MainActor
private func musicRequestChecks(_ music: [SkyStudioModel]) async {
    let api = jobAPI()
    let cue = SkyStudioGeneration.make(.music, prompt: "a rising cue", ask: .init(duration: 12.34), canvas: 16.0 / 9, model: music[1])
    SkyStudioStub.reset { _ in .http(200, #"{"credits": 10, "typical_seconds": 20}"#) }
    let quote = try? await api.quote(cue.job(model: music[1].id), key: jobKey)
    checkEqual(quote?.credits, 10, "the quote is the server's")
    let body = SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(body?["model"], "stable-audio-3-medium", "the exact-length model is named")
    checkEqual(body?["params"], ["duration": 12.3, "instrumental": true], "/quote carries 12.3 s, nothing else")
    checkEqual(body?["params"]?["duration"]?.encodedString(), "12.3", "the length is written as 12.3, not a long binary fraction")
    SkyStudioStub.reset { _ in .http(400, #"{"error": {"code": "invalid_request", "message": "Stable Audio 3 Medium makes the length it is asked for and has no auto length.", "field": "params.duration", "limit": [1, 380], "reason": "auto_not_supported"}}"#) }
    let refused = await expectFailure("auto refused by Sky Studio") { _ = try await api.quote(cue.job(model: music[1].id), key: jobKey) }
    let tool = refused.map(SkyStudioCharacterError.tool)
    check(tool?.message.hasPrefix("Stable Audio 3 Medium makes the length") == true, "Sky Studio's own words go to the AI as they are")
    check(tool?.details["next_step"]?.stringValue?.contains("leave model out so SkyCut picks a music model that chooses its own length") == true,
          "and the next step says what to change, not 'inspect the billing'")
}

/// Sky Studio's refusals of a length, vocals or sound (a catalog SkyCut holds that is older than Sky Studio's).
private func skyStudioRefusalChecks() {
    func error(_ fields: [String: JSONValue], code: String = "invalid_request") -> SkyStudioServerError {
        SkyStudioServerError(status: 400, code: code, message: "refused", fields: fields)
    }
    let steps: [(String, [String: JSONValue], String)] = [
        ("auto", ["field": "params.duration", "limit": [1, 380], "reason": "auto_not_supported"], "chooses its own length"),
        ("range", ["field": "params.duration", "limit": [1, 380]], "whose length takes it"),
        ("vocals", ["field": "params.instrumental", "allowed": [true]], "picks one that sings"),
        ("lyrics", ["field": "params.lyrics", "allowed": [true]], "picks one that sings"),
        ("sound", ["field": "params.audio_mode", "allowed": ["full", "ambient"], "reason": "audio_always_on"], "lists none in params.audio_mode")
    ]
    for (name, fields, words) in steps {
        let step = SkyStudioGenerationRefusal.nextStep(error(fields)) ?? ""
        check(step.contains(words) && step.hasSuffix("Nothing was charged."), "\(name): a plain next step (\(step))")
    }
    check(SkyStudioGenerationRefusal.nextStep(error(["field": "params.duration"])) == nil, "a duration refusal without a limit is not guessed at")
    check(SkyStudioGenerationRefusal.nextStep(error(["field": "params.audio_mode"])) == nil, "an unknown mode is left to the server's words")
    check(SkyStudioGenerationRefusal.nextStep(error(["field": "params.duration", "limit": [1, 380]], code: "price_changed")) == nil,
          "only invalid_request")
    checkEqual(SkyStudioCharacterError.tool(SkyStudioFailure.server(error(["code": "x"], code: "price_changed"))).details["next_step"]?.stringValue,
               SkyStudioCharacterError.nextStep("price_changed"), "other refusals keep their own next step")
}

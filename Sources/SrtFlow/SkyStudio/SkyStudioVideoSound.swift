import Foundation
import SrtFlowMCPKit

// MARK: - A generated video's own sound: the mode SkyCut asks for and what the result says (Sky Studio "Video sound", 2026-11-19; MCP-42)
//
// What it covers:
// - `audio_mode` for text_to_video / image_to_video: `full` (the model's own sound, the default), `ambient` (Sky Studio adds a
//   direction to the prompt: on-screen sound only, no music or bed; not a switch) and `none` (the provider's own switch). Which ones
//   a model takes is its `/models` record (`params.audio_mode`): `none` only where it is listed (Seedance 2.0 Pro / 2.5, Wan 3.0 on
//   2026-11-19; MiniMax H3, Gemini Omni and Veo 3.1 Fast always make sound). A mode the model does not take is refused before quoting.
//   The mode never moves the choice to another model: the generate tools check it on the model already chosen, because a model
//   that can turn sound off costs several times the default one (Seedance 2.0 Pro 720p 76 credits/s against MiniMax H3 768p 16
//   on 2026-11-19) while muting the clip gives the same silence for nothing.
// - The request: `audio_mode` is sent only when the AI asks for one, so a default request stays exactly what it was (an official
//   shot's pinned request digest too); where the model also has `generate_audio`, it is sent agreeing with the mode (Sky Studio
//   refuses the two disagreeing).
// - The finished job: Sky Studio's `audio` block (mode, has_track, can_turn_off, may_carry_bed, note) goes to the AI with what to
//   do next: when the clip may carry the model's own bed, listen to it (listen describe=true) before laying narration over it.
// Not: measuring or changing the sound (the AI listens; edit_clip lowers or mutes), the price (the mode never changes it).
enum SkyStudioVideoSound {
    /// A video kind that takes `audio_mode` (lip-sync carries the caller's audio and takes none).
    static func applies(_ kind: String) -> Bool { kind == "text_to_video" || kind == "image_to_video" }

    /// The modes this model takes; empty for a catalog from before 2026-11-19.
    static func modes(of model: SkyStudioModel) -> [String] { model.choices("audio_mode") }

    /// Why `model` cannot take the asked mode; nil when it can (or nothing was asked).
    static func problem(model: SkyStudioModel, ask: SkyStudioGeneration.Ask) -> String? {
        guard let mode = ask.audioMode, applies(model.kind) else { return nil }
        if let generate = ask.generateAudio, generate == (mode == "none") {
            return "audio_mode=\(mode) and generate_audio=\(generate) disagree; send audio_mode alone."
        }
        let offered = modes(of: model)
        if offered.contains(mode) || (offered.isEmpty && mode == "full") { return nil }
        if offered.isEmpty { return "Sky Studio does not offer audio_mode for \(model.title) yet; leave audio_mode out." }
        if mode == "none" {
            return "\(model.title) always makes its own sound, so audio_mode=none is not available. For silence, mute the clip after it "
                + "arrives (edit_clip muted=true; nothing extra to pay); ambient asks for on-screen sound only (a direction in the prompt); "
                + "or name a model whose get_status models=true lists none in params.audio_mode (its quote shows the price)."
        }
        return "\(model.title) takes audio_mode \(offered.joined(separator: ", "))."
    }

    /// Adds the asked mode to the request (only when asked and the model lists it), with generate_audio agreeing where it is sent.
    static func apply(_ ask: SkyStudioGeneration.Ask, model: SkyStudioModel?, to params: inout [String: JSONValue]) {
        guard let mode = ask.audioMode else { return }
        if let model, !modes(of: model).contains(mode) { return }
        params["audio_mode"] = .string(mode)
        if params["generate_audio"] != nil { params["generate_audio"] = .bool(mode != "none") }
    }

    /// What get_job says about a finished video's sound: Sky Studio's `audio` block and a note on what to do before laying narration
    /// or music over it. A server from before 2026-11-19 sends no block: the general note stands.
    static func resultDetail(_ result: SkyStudioJobResult) -> [String: JSONValue] {
        guard let audio = result.metadata["audio"], audio.objectValue != nil else { return ["note": .string(generalNote)] }
        let said = audio["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note: String
        if audio["may_carry_bed"]?.boolValue == true {
            note = said.isEmpty ? listenFirst : said + " " + listenFirst
        } else if audio["has_track"]?.boolValue == true {
            // Asked for none, yet the file has sound: Sky Studio's note says to listen first.
            note = said.isEmpty ? "The file has a sound track: listen to it (listen describe=true with this file) before using it." : said
        } else {
            note = said.isEmpty ? "The clip has no generated sound." : said
        }
        return ["audio": audio, "note": .string(note)]
    }

    /// The note for a clip whose sound may carry the model's own bed (MCP-42: one buried the narration laid over it).
    static let listenFirst = "Before laying narration or music over it, run listen describe=true with this file (or its clip_id once "
        + "placed): if it names a drone, music or rumble bed, lower the clip (edit_clip volume_db) or mute it (edit_clip muted=true)."

    /// Before 2026-11-19 Sky Studio said nothing about a video's sound.
    static let generalNote = "Generated clips may carry their own sound; it plays with the clip. "
        + "Lower or mute the clip's volume (edit_clip) when you add your own music or narration."
}

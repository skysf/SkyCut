import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio's own refusals of a music length, vocals or video sound, as a plain next step (2026-11-19; MCP-18, MCP-42)
//
// What it covers: the `next_step` given to the AI when `/quote` answers `invalid_request` for a music length (`auto_not_supported`,
// a length outside the model's `limit`), vocals or lyrics asked of an instrumental-only model, or `audio_mode` none on a model that
// always makes sound (`audio_always_on`). SkyCut checks the same things from `/models` before it quotes (`SkyStudioMusicLength`,
// `SkyStudioVideoSound`), so these answers only come back when the catalog SkyCut holds is older than Sky Studio's. Nothing is
// charged for an `invalid_request`; the server's own message still goes to the AI as it is.
// Not: other refusals (their next step stays `SkyStudioCharacterError.nextStep`), the message itself (the server's words).
enum SkyStudioGenerationRefusal {
    /// A next step for one of the refusals above; nil for any other answer.
    static func nextStep(_ error: SkyStudioServerError) -> String? {
        guard error.code == "invalid_request" else { return nil }
        let reason = error.fields["reason"]?.stringValue
        switch error.fields["field"]?.stringValue {
        case "params.duration"? where reason == "auto_not_supported":
            return "This music model makes the length it is given: give duration in seconds within limit, or leave model out so SkyCut "
                + "picks a music model that chooses its own length. Nothing was charged."
        case "params.duration"? where error.fields["limit"] != nil:
            return "duration is outside this model's limit: give one inside it, or leave model out so SkyCut picks a music model whose "
                + "length takes it (get_status models=true lists each one's length). Nothing was charged."
        case "params.instrumental"?, "params.lyrics"?:
            return "This model makes instrumental music only: leave model out so SkyCut picks one that sings, or drop instrumental=false "
                + "and lyrics. Nothing was charged."
        case "params.audio_mode"? where reason == "audio_always_on":
            return "This video model always makes its own sound: use audio_mode full or ambient and lower or mute the clip after it "
                + "arrives (edit_clip), or choose a model whose get_status models=true lists none in params.audio_mode. Nothing was charged."
        default:
            return nil
        }
    }
}

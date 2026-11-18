import Foundation
import SrtFlowMCPKit

// edit_clip voice_band_db (MCP-30, 2026-11-18; docs/architecture/sound-scenes.md section 5): read and range-checked (out of
// range is refused with the allowed range, nothing applied), applied to the clip, written back for get_timeline only when set,
// refused on a clip with no sound, and the schema's range is the model's (VoiceBand.range).

func runVoiceBandToolChecks() {
    guard let details = try? AIClipDetails(args(["voice_band_db": -10])) else { return check(false, "voice_band_db -10 is read") }
    checkEqual(details.voiceBand, -10, "voice_band_db is read")
    check(details.touchesSound, "voice_band_db is a sound setting")
    do {
        _ = try AIClipDetails(args(["voice_band_db": -40]))
        check(false, "voice_band_db -40 is refused")
    } catch let error as AIToolError {
        checkEqual(error.details["status"], "invalid_parameter", "out of range is an invalid_parameter")
        checkEqual(error.details["suggested"], -30, "and suggests the nearest allowed depth")
    } catch {
        check(false, "voice_band_db -40 fails as an AIToolError")
    }
    var state = TimelineState()
    let sound = audioClip(0, 4)
    var silent = videoClip(4, 4)
    silent.info?.hasAudio = false
    state.audioTracks = [EditLane(clips: [sound])]
    state.mainClips = [silent]
    do {
        try details.apply(to: sound.id, in: &state, frameRate: .fps24)
        checkEqual(state.clip(with: sound.id)?.voiceBandDB, -10, "the cut lands on the clip")
        if let clip = state.clip(with: sound.id) {
            checkEqual(AIClipDetails.summary(clip)["voice_band_db"], -10, "the clip's summary (get_timeline) shows the cut")
        }
        let off = try AIClipDetails(args(["voice_band_db": 0]))
        try off.apply(to: sound.id, in: &state, frameRate: .fps24)
        check(state.clip(with: sound.id).map { AIClipDetails.summary($0)["voice_band_db"] == nil } ?? false,
              "0 takes the cut off and the summary leaves it out")
    } catch {
        check(false, "voice_band_db applies to a clip with sound: \(error)")
    }
    checkThrows("a clip with no sound refuses voice_band_db") { try details.apply(to: silent.id, in: &state, frameRate: .fps24) }
    let schema = MCPToolName.editClip.definition.inputSchema["properties"]?["voice_band_db"]
    checkEqual(schema?["minimum"], .number(VoiceBand.range.lowerBound), "voice_band_db's minimum is the model's")
    checkEqual(schema?["maximum"], .number(VoiceBand.range.upperBound), "voice_band_db's maximum is the model's")
}

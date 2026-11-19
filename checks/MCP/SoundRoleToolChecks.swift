import Foundation
import SrtFlowMCPKit

// edit_clip sound_role (MCP-40, 2026-11-19; docs/architecture/finished-video-inspection.md, "Saved sound roles"): read (any case,
// written back as listed), saved on the clip, auto clearing it, written back for get_timeline only when saved, refused on a clip
// with no sound and for a name that is no role, and the advertised names are the model's (ClipSoundRole) plus auto.

func runSoundRoleToolChecks() {
    checkEqual(MCPVocabulary.soundRoles, ClipSoundRole.allCases.map(\.rawValue) + ["auto"],
               "edit_clip's sound_role names are ClipSoundRole's plus auto")
    let schema = MCPToolName.editClip.definition.inputSchema["properties"]?["sound_role"]
    checkEqual(schema?["enum"], .array(MCPVocabulary.soundRoles.map(JSONValue.string)), "the schema advertises those names")

    guard let object = try? AIClipDetails(args(["sound_role": "Object"])) else { return check(false, "sound_role Object is read") }
    checkEqual(object.soundRole, .save(.object), "sound_role is read whatever its case")
    check(object.touchesSound && !object.touchesPicture, "sound_role is a sound setting")
    checkEqual((try? AIClipDetails(args(["sound_role": "auto"])))?.soundRole, .clear, "auto clears a saved role")
    check((try? AIClipDetails(args([:])))?.soundRole == nil, "without sound_role nothing about the role changes")
    checkThrows("a name that is no role is refused") { _ = try AIClipDetails(args(["sound_role": "drums"])) }

    var state = TimelineState()
    let sound = audioClip(0, 4)
    var silent = videoClip(4, 4)
    silent.info?.hasAudio = false
    state.audioTracks = [EditLane(clips: [sound])]
    state.mainClips = [silent]
    do {
        try object.apply(to: sound.id, in: &state, frameRate: .fps24)
        checkEqual(state.clip(with: sound.id)?.soundRole, .object, "the role is saved on the clip")
        if let clip = state.clip(with: sound.id) {
            checkEqual(AIClipDetails.summary(clip)["sound_role"], "object", "the clip's summary (get_timeline, edit_clip's reply) shows it")
        }
        let volume = try AIClipDetails(args(["voice_band_db": -6]))
        try volume.apply(to: sound.id, in: &state, frameRate: .fps24)
        checkEqual(state.clip(with: sound.id)?.soundRole, .object, "another sound setting leaves the saved role alone")
        try AIClipDetails(args(["sound_role": "auto"])).apply(to: sound.id, in: &state, frameRate: .fps24)
        check(state.clip(with: sound.id).map { $0.soundRole == nil && AIClipDetails.summary($0)["sound_role"] == nil } ?? false,
              "auto clears it and the summary leaves it out")
    } catch {
        check(false, "sound_role applies to a clip with sound: \(error)")
    }
    checkThrows("a clip with no sound refuses sound_role") { try object.apply(to: silent.id, in: &state, frameRate: .fps24) }
}

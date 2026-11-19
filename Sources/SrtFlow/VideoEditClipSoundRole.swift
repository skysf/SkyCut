import Foundation

// MARK: - A clip's saved sound role (`EditClip.soundRole`, project format v39; 2026-11-19, production feedback MCP-40)
//
// Owns: what a clip's sound can be saved as — voice, music, effects (hits, risers, whooshes), ambience (the sound of a place)
// and object (a thing in the picture) — and the value written to the project file. nil = nothing saved: the delivery checks
// then infer the role from where the clip came from (AIDeliverySoundRoles: our voice-overs and effects by folder, library
// music and effects by manifest id, generated audio as music, a picture's own sound as camera). Saving one is how a role
// SkyCut can't infer (an imported music file, a wind bed, a clang) stops having to be named on every inspect_video call.
// A saved role describes the sound; it never changes it: nothing that renders, mixes or previews reads it.
// Decoding: a value this build doesn't know reads as nil (inferred), like an unknown sound scene.
// Not here: which role wins (AIDeliverySoundRoles: inspect_video `sounds`, then this, then provenance), the checks reading
// roles (finished-video-inspection.md, "Second-tier sound checks"), the edit_clip parameter that sets it.

enum ClipSoundRole: String, CaseIterable, Codable, Hashable, Sendable {
    case voice, music, effects, ambience, object
}

import Foundation

// MARK: - 说明书：set_transition 的 sound（声音怎么过一刀，2026-11-16 MCP-32）
//
// 管什么：set_transition 主题里讲 sound 的三节（几种过法、规矩、结果）。名片和参数说明写短（清单只剩约 1.5k 字），长话在这里。
// 出处：docs/architecture/cut-sound.md（每种过法改哪一边、默认几帧、垫底的 6 dB、余料不够整个不做、分离时另一头照它实际响的样子、
// 2026-11-16 decisions: equal-power crossfades, the bed is raised to carry the cut, gain brings the louder side down;
// 转场上、all=true 跳过没声音的刀、量电平的窗）；默认帧数和 6 dB 来自真人南极正片 45 刀的实测（joins-human.md，研究资料不进仓库）。
// 只写英文。不管什么：画面转场那几节（MCPGuideTimelineEditTopics.setTransition 本身）。

enum MCPGuideCutSound {
    static let sections: [MCPGuideSection] = [
        MCPGuideSection(name: "sound", about: "the sound values: what each changes at a cut and its default frames", text: """
        Sound joins. sound (instead of type) changes only how the sound crosses the cut; the picture never moves. frames are \
        frames at the project frame rate.
        - crossfade: both sounds overlap frames on each side of the cut and fade across with equal power, so two different \
        sounds keep their loudness through the middle (default about 0.25 s each side). Two pieces of one continuous take fade \
        linearly instead, which sums exactly.
        - lead: the next shot's sound starts frames early and fades in under the previous one, a J cut (default about 0.67 s).
        - lag: the previous shot's sound runs frames past the cut and fades out, an L cut (default about 0.875 s).
        - bed: a continuous sound on an audio track (layer_id, or the longest sound across the cut: music, ambience, a long tone) \
        is made to reach frames on each side (default 2 s). A bed hides a jump only within 6 dB of the louder side, so a \
        quieter bed is raised around the cut (a swell in its volume curve) until it is; only what the volume limit leaves \
        uncovered is taken off the loud side.
        - on_beat: a hard switch, moved to the nearest beat of the music (layer_id, or the longest sound across the cut) within \
        frames of the cut (default about 1/3 s). Music with no clear beat is refused.
        - gain: the next shot's sound moves by gain_db; without gain_db the louder side comes down to the quieter side's \
        level at the cut (headroom kept, noise never lifted).
        - cut: back to a hard switch exactly at the picture cut, no fades.
        gain_db also adds to crossfade, lead, on_beat and cut (the next shot's sound) and lag (the previous shot's). For a dialogue \
        J cut that starts at full level, use lead and then edit_clip fade_in 0 on the separated sound.
        """),
        MCPGuideSection(name: "sound_rules", about: "separating a shot's sound, not enough footage, tracks, transitions, all=true", text: """
        Rules. A shot's own sound that has to move is separated first, as add_clips sound=separate does: the picture is muted, \
        the sound goes to an audio track linked to it, and its other end keeps sounding as before (a V1 transition there keeps \
        its crossfade). Two sounds that now overlap go on different audio tracks. Nothing is shortened silently: when a file has \
        too little sound beyond the cut, or the sound would run past the next shot, the call changes nothing and returns the \
        maximum frames and why. On a cut with a picture transition, the sounds are separated so your join replaces the \
        transition's crossfade; the picture transition stays. The cut can be on any video track (V1, V2...); after_clip_id may \
        also be a separated sound. all=true joins every touching V1 cut in one undo step and lists cuts without the sound it \
        needs in skipped_no_sound. gain and bed measure 0.3 s on each side of the cut; if SkyCut is still reading the sound, \
        call again in a moment. V1 never moves, so the magnet does nothing; linkage keeps a separated sound with its picture.
        """),
        MCPGuideSection(name: "sound_results", about: "what the result reports for each sound join", text: """
        Sound results. For each cut, out and in give the clip that holds that sound (id, track), where it ends or starts, \
        offset_frames from the picture cut (negative is earlier), fade_frames, separated_from when it was just separated, \
        gain_db as applied and requested_gain_db when the volume limit clamped it. room_frames is how many frames of sound each \
        file still has beyond the cut. crossfade adds shape (equal_power, or linear for one continuous take); on_beat adds \
        beat (at, moved_frames, music); bed adds bed (id, track, from, to, extended_frames, raised_db) and levels_db; gain \
        adds levels_db. picture is always unchanged.
        """)
    ]

    static let examples: [JSONValue] = [
        ["after_clip_id": "c2", "sound": "lead", "frames": 12, "gain_db": -6],
        ["after_clip_id": "c3", "sound": "crossfade", "frames": 6],
        ["all": true, "sound": "bed", "layer_id": "a1"]
    ]

    static let readingTip = "For a sound join (sound=...), read only section=sound."
}

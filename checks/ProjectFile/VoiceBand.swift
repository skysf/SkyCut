import Foundation
import SrtFlowCore

// 51: a clip's voice-band cut (EditClip.voiceBandDB, MCP-30, 2026-11-18; docs/architecture/sound-scenes.md section 5) —
// the range and cleaning, the v38 gate and the key written only when set, a round trip, an old project without the key,
// split halves and separated sound carrying it, and changing it being an audio-only change (no picture rebuild).

func checkVoiceBand(root: URL) throws {
    let dir = root.appendingPathComponent("voice-band")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    checkEqual(VoiceBand.sanitized(-10), -10, "a depth in range stays")
    checkEqual(VoiceBand.sanitized(-80), -30, "deeper than -30 dB is clamped to -30")
    checkEqual(VoiceBand.sanitized(4), 0, "above 0 dB is clamped to 0 (it only lowers)")
    checkEqual(VoiceBand.sanitized(.nan), 0, "not a number is no cut")
    check(VoiceBand.bandGain(0) == 1, "0 dB is gain 1 (the engine leaves the filter off)")
    check(abs(VoiceBand.bandGain(-20) - 0.1) < 1e-6, "-20 dB is a tenth")

    let media = dir.appendingPathComponent("shot.m4a")
    try Data("a".utf8).write(to: media)
    var state = TimelineState()
    let plain = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 4, audioAssetDuration: 4)
    var shot = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 4, timelineStart: 4, audioAssetDuration: 4)
    shot.voiceBandDB = -10
    state.audioTracks = [EditLane(clips: [plain, shot])]
    check(state.requiresFormatVersion38, "a clip with a voice-band cut needs v38")
    var none = state
    none.audioTracks[0].clips[1].voiceBandDB = 0
    check(!none.requiresFormatVersion38, "no cut, no v38 data")
    check(state.differsOnlyInAudioMix(from: none), "changing the cut is an audio-only change (no picture rebuild)")

    let file = dir.appendingPathComponent("voice-band.skycut")
    try VideoEditProjectIO.save(state, to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    checkEqual(text.components(separatedBy: "\"voiceBandDB\"").count - 1, 1, "only the clip with a cut writes the key")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 38, "a project with a voice-band cut writes v38")
    let loaded = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(loaded.clip(with: shot.id)?.voiceBandDB, -10, "the cut survives a round trip")
    checkEqual(loaded.clip(with: plain.id)?.voiceBandDB, 0, "a clip without the key reads as no cut")

    let tampered = dir.appendingPathComponent("tampered.skycut")
    let edited = text.replacingOccurrences(of: #""voiceBandDB"\s*:\s*-10"#, with: "\"voiceBandDB\" : -80", options: .regularExpression)
    check(edited != text, "the saved project has the key to tamper with")
    try edited.write(to: tampered, atomically: true, encoding: .utf8)
    checkEqual(try VideoEditProjectIO.load(from: tampered).timeline.clip(with: shot.id)?.voiceBandDB, -30,
               "a stored depth beyond -30 dB reads back clamped")

    var split = state
    split.split(clipID: shot.id, at: 6)
    checkEqual(split.audioTracks[0].clips.map(\.voiceBandDB), [0, -10, -10], "both halves of a split clip keep the cut")
    var video = EditClip(sourceURL: media, sourceDuration: 4, info: MediaInfo(
        duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    ))
    video.voiceBandDB = -12
    checkEqual(video.detachedAudio(linkGroup: UUID()).voiceBandDB, -12, "separated sound takes the cut with it")
}

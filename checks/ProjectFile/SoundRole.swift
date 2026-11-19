import Foundation
import SrtFlowCore

// 52: a clip's saved sound role (EditClip.soundRole, MCP-40, 2026-11-19; VideoEditClipSoundRole.swift,
// docs/architecture/video-edit-project-file.md v39) — the v39 gate and the key written only when saved, a round trip, an old
// project without the key and a role this build doesn't know (both: nothing saved), split halves and separated sound carrying
// it, and the reader refusing the next version.

func checkSoundRole(root: URL) throws {
    let dir = root.appendingPathComponent("sound-role")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    checkEqual(ClipSoundRole.allCases.map(\.rawValue), ["voice", "music", "effects", "ambience", "object"],
               "the roles a clip can be saved as (what inspect_video's sounds takes)")

    let media = dir.appendingPathComponent("clang.m4a")
    try Data("a".utf8).write(to: media)
    var state = TimelineState()
    let plain = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 4, audioAssetDuration: 4)
    var clang = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 4, timelineStart: 4, audioAssetDuration: 4)
    clang.soundRole = .object
    state.audioTracks = [EditLane(clips: [plain, clang])]
    check(state.requiresFormatVersion39, "a clip with a saved sound role needs v39")
    var none = state
    none.audioTracks[0].clips[1].soundRole = nil
    check(!none.requiresFormatVersion39, "no saved role, no v39 data")

    let file = dir.appendingPathComponent("sound-role.skycut")
    try VideoEditProjectIO.save(state, to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    checkEqual(text.components(separatedBy: "\"soundRole\"").count - 1, 1, "only the clip with a saved role writes the key")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 39, "a project with a saved sound role writes v39")
    let loaded = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(loaded.clip(with: clang.id)?.soundRole, .object, "the saved role survives a round trip")
    check(loaded.clip(with: plain.id)?.soundRole == nil, "a clip without the key has nothing saved (inferred)")

    let unknown = dir.appendingPathComponent("unknown-role.skycut")
    let edited = text.replacingOccurrences(of: #""soundRole"\s*:\s*"object""#, with: "\"soundRole\" : \"drums\"", options: .regularExpression)
    check(edited != text, "the saved project has the key to change")
    try edited.write(to: unknown, atomically: true, encoding: .utf8)
    let reread = try VideoEditProjectIO.load(from: unknown).timeline
    check(reread.clip(with: clang.id) != nil && reread.clip(with: clang.id)?.soundRole == nil,
          "a role this build doesn't know reads as nothing saved, and the clip still opens")

    var split = state
    split.split(clipID: clang.id, at: 6)
    checkEqual(split.audioTracks[0].clips.map(\.soundRole), [nil, .object, .object], "both halves of a split clip keep the role")
    var video = EditClip(sourceURL: media, sourceDuration: 4, info: MediaInfo(
        duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    ))
    video.soundRole = .ambience
    checkEqual(video.detachedAudio(linkGroup: UUID()).soundRole, .ambience, "separated sound takes the role with it")
}

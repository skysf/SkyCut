import Foundation
import SrtFlowCore

// 53: the editing style a film was cut with (TimelineState.editingStyle, v40, SS5 plan 5.5; docs/architecture/video-edit-project-file.md):
// the v40 gate and the key written only with a record, round trips of a pinned Sky Studio style and of a preset (recorded, not pinned),
// an older project without the key, and a record that does not read is dropped while the project still opens.

func checkEditingStyle(root: URL) throws {
    let dir = root.appendingPathComponent("editing-style")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pinned = EditingStyleRecord(id: "film-trailer", source: "sky_studio", version: "1.0", sha256: String(repeating: "a", count: 64))
    let preset = EditingStyleRecord(id: "documentary", source: "built_in", sha256: String(repeating: "b", count: 64), skycutVersion: "0.18.70")
    check(pinned.isPinned, "a Sky Studio style with a version is pinned")
    check(!preset.isPinned, "a preset is recorded, never pinned")

    var state = TimelineState()
    check(!state.requiresFormatVersion40, "no record, no v40 data")
    let plainFile = dir.appendingPathComponent("plain.skycut")
    try VideoEditProjectIO.save(state, to: plainFile)
    check(!(try String(contentsOf: plainFile, encoding: .utf8)).contains("editingStyle"), "no record, no key")
    check(try VideoEditProjectIO.load(from: plainFile).timeline.editingStyle == nil, "a project without the key has no record")

    state.editingStyle = pinned
    check(state.requiresFormatVersion40, "a film with an editing style needs v40")
    let file = dir.appendingPathComponent("styled.skycut")
    try VideoEditProjectIO.save(state, to: file)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 40, "a film with an editing style writes v40")
    checkEqual(try VideoEditProjectIO.load(from: file).timeline.editingStyle, pinned, "a pinned Sky Studio style survives a round trip")

    state.editingStyle = preset
    try VideoEditProjectIO.save(state, to: file)
    checkEqual(try VideoEditProjectIO.load(from: file).timeline.editingStyle, preset, "a preset's record keeps SkyCut's version")

    // A record without a checksum is not a record: dropped, and the project still opens with everything else.
    state.editingStyle = pinned
    state.minimumDuration = 12
    try VideoEditProjectIO.save(state, to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    let broken = text.replacingOccurrences(of: #""sha256"\s*:\s*"a{64}""#, with: "\"sha256\" : \"  \"", options: .regularExpression)
    check(broken != text, "the saved project has the checksum to break")
    let brokenFile = dir.appendingPathComponent("broken.skycut")
    try broken.write(to: brokenFile, atomically: true, encoding: .utf8)
    let loaded = try VideoEditProjectIO.load(from: brokenFile).timeline
    check(loaded.editingStyle == nil, "a record without a checksum is dropped")
    checkEqual(loaded.minimumDuration, 12, "and the rest of the project reads")
}

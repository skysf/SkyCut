import Foundation

// Group 50: a motion movie is a recoverable project cache. These I/O checks use synthetic bytes, not video rendering;
// actual page checks and ProRes output are exercised by check-web-motion and the App-side motion checks.
func checkWebMotionProjectFiles(_ root: URL) throws {
    let folder = root.appendingPathComponent("web-motion")
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("initial-render.mov")
    let movieBytes = Data("synthetic carried movie".utf8)
    try movieBytes.write(to: source)
    let fingerprint = String(repeating: "a", count: 64)
    let record = WebMotionClipRecord(
        page: "<script>window.motion={frame(t){}}</script>", parametersJSON: #"{"text":"From ice","font":"Avenir Next"}"#,
        name: "Project title", parameterFields: [WebMotionParameterField(key: "text", label: "Text"),
                                                WebMotionParameterField(key: "font", label: "Font", kind: .font)],
        fonts: ["Hardcoded Page Font"], duration: 4, hitTime: 0.75, width: 320, height: 180, fps: 24,
        provenance: WebMotionClipProvenance(fingerprint: fingerprint, renderer: 1, macOS: "old macOS",
                                           macOSBuild: "old build", webKit: "old WebKit", fonts: ["Avenir Next"],
                                           renderedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    var clip = EditClip(sourceURL: source, sourceDuration: 4, timelineStart: 7)
    clip.webMotion = record
    var state = TimelineState()
    state.overlayTracks = [EditLane(clips: [clip])]
    checkEqual(clip.name, "Project title", "50 clip label uses the stored motion name, not the cache fingerprint")
    check(state.requiresFormatVersion36, "50 stored web source requires v36")
    check(!state.requiresFormatVersion35, "50 a web page alone does not claim the v35 delivery-review contract")
    var withCapture = state
    withCapture.update(clip.id) { $0.isScreenRecording = true }
    check(withCapture.requiresFormatVersion35 && withCapture.requiresFormatVersion36,
          "50 screen provenance and web source keep their distinct persistent version contracts")
    check(state.mediaURLs.isEmpty, "50 rendered motion movie is not imported media")
    try sourceRoundTrip(clip, record: record)
    try splitKeepsSource(clip, record: record)

    let file = folder.appendingPathComponent("title.skycut")
    let records = try VideoEditProjectIO.save(state, to: file)
    check(records.isEmpty, "50 saving a motion makes no media bookmark")
    let expected = folder.appendingPathComponent("SkyCut/Motion/motion-\(fingerprint).mov")
    checkEqual(try Data(contentsOf: expected), movieBytes, "50 first save carries the already rendered movie beside the project")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    checkEqual(raw["formatVersion"] as? Int, 38, "50 writer records latest v38 (includes the v36 gate) as an external fixed contract")
    check((raw["media"] as? [Any])?.isEmpty == true, "50 movie does not enter the project media table")
    let firstLoad = try VideoEditProjectIO.load(from: file)
    checkEqual(firstLoad.timeline.clip(with: clip.id)?.webMotion, record, "50 page, parameters and source provenance survive ProjectIO")
    checkEqual(firstLoad.timeline.clip(with: clip.id)?.sourceURL, expected, "50 saved clip points at project-relative cache")
    check(firstLoad.motionsToRegenerate.isEmpty && firstLoad.missingMedia.isEmpty, "50 existing render needs neither regeneration nor relinking")

    let movedFolder = root.appendingPathComponent("motion-on-another-mac")
    try manager.copyItem(at: folder, to: movedFolder)
    let moved = movedFolder.appendingPathComponent("title.skycut")
    let movedMovie = movedFolder.appendingPathComponent("SkyCut/Motion/motion-\(fingerprint).mov")
    let carried = try VideoEditProjectIO.load(from: moved)
    checkEqual(carried.timeline.clip(with: clip.id)?.sourceURL, movedMovie, "50 carried movie wins over original Mac absolute path, even while old file exists")
    checkEqual(carried.timeline.clip(with: clip.id)?.webMotion?.provenance, record.provenance, "50 OS/font change does not rewrite render provenance or fingerprint")
    check(carried.motionsToRegenerate.isEmpty, "50 carried render is used without re-rendering on a new Mac")

    try manager.removeItem(at: movedMovie)
    try manager.removeItem(at: expected)
    let missing = try VideoEditProjectIO.load(from: moved)
    checkEqual(missing.motionsToRegenerate, [clip.id], "50 missing project cache queues the source clip for regeneration")
    check(missing.missingMedia.isEmpty && missing.records.isEmpty, "50 lost movie is not a missing-media warning")
    checkEqual(missing.timeline.clip(with: clip.id)?.webMotion?.page, record.page, "50 deleting cache leaves its stored page intact")
    checkEqual(missing.timeline.clip(with: clip.id)?.sourceURL, movedMovie, "50 missing movie keeps a stable cache destination")
    try VideoEditProjectIO.save(missing.timeline, to: moved)
    let missingAgain = try VideoEditProjectIO.load(from: moved)
    checkEqual(missingAgain.motionsToRegenerate, [clip.id], "50 saving with a missing movie retains recovery source and request")

    var runtime = firstLoad.timeline
    checkEqual(WebMotionProjectFiles.refreshWebMotionCaches(in: &runtime, projectURL: file), [clip.id],
               "50 runtime revalidation detects a deleted cache too")
    var mixed = state
    let ordinary = folder.appendingPathComponent("normal.mp4")
    mixed.mainClips = [EditClip(sourceURL: ordinary, sourceDuration: 2)]
    checkEqual(mixed.mediaURLs, [ordinary], "50 ordinary imported media still takes the normal media path")
    try invalidFingerprintAndSaveFailure(record, clip: clip, root: root)
}

private func sourceRoundTrip(_ clip: EditClip, record: WebMotionClipRecord) throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    checkEqual(try decoder.decode(EditClip.self, from: encoder.encode(clip)).webMotion, record,
               "50 Codable keeps the complete source and parameter form")
    var captured = clip
    captured.isScreenRecording = true
    let captureRoundTrip = try decoder.decode(EditClip.self, from: encoder.encode(captured))
    check(captureRoundTrip.isScreenRecording && captureRoundTrip.webMotion == record,
          "50 the shared clip coder retains screen-capture provenance alongside the new web source")
    var plain = clip
    plain.webMotion = nil
    let raw = try JSONSerialization.jsonObject(with: encoder.encode(plain)) as! [String: Any]
    check(raw["webMotion"] == nil, "50 ordinary clips omit the new field")
    check(raw["isScreenRecording"] == nil, "50 ordinary clips still omit false screen-capture provenance")
    check(try decoder.decode(EditClip.self, from: encoder.encode(plain)).webMotion == nil, "50 old absent field reads as nil")
    let field = try decoder.decode(WebMotionParameterField.self, from: Data(#"{"key":"future","kind":"new_control"}"#.utf8))
    checkEqual(field.kind, .text, "50 future parameter control falls back to editable text")
    checkEqual(field.label, "future", "50 missing parameter label defaults to its key")
    let minimal = try decoder.decode(WebMotionClipRecord.self, from: Data(#"{"page":"<p>saved source</p>"}"#.utf8))
    checkEqual(minimal.parametersJSON, "{}", "50 absent optional record fields retain safe defaults")
    check(minimal.provenance == nil && minimal.parameterFields.isEmpty && minimal.fonts.isEmpty,
          "50 source-only record has no invented render or declared font dependencies")
}

private func splitKeepsSource(_ clip: EditClip, record: WebMotionClipRecord) throws {
    guard let halves = TimelineClipSplit.make(clip, at: 9) else {
        check(false, "50 motion clip splits"); return
    }
    checkEqual(halves.left.webMotion, record, "50 split left keeps source page and full render timing")
    checkEqual(halves.right.webMotion, record, "50 split right keeps source page and full render timing")
    checkEqual(halves.right.sourceStart, 2, "50 split right selects the later part of the same rendered source")
    check(halves.right.id != clip.id, "50 split still creates a new clip identity")
}

private func invalidFingerprintAndSaveFailure(_ record: WebMotionClipRecord, clip: EditClip, root: URL) throws {
    var invalid = record
    invalid.provenance?.fingerprint = "../../outside"
    check(WebMotionProjectFiles.filename(for: invalid) == nil, "50 stored fingerprint cannot escape cache directory")
    let manager = FileManager.default
    let blocked = root.appendingPathComponent("motion-save-blocked")
    try manager.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: blocked.appendingPathComponent("SkyCut"))
    let project = blocked.appendingPathComponent("existing.skycut")
    let before = Data("existing project is never truncated".utf8)
    try before.write(to: project)
    var state = TimelineState()
    state.overlayTracks = [EditLane(clips: [clip])]
    check((try? VideoEditProjectIO.save(state, to: project)) == nil, "50 failed carry fails save explicitly")
    checkEqual(try Data(contentsOf: project), before, "50 cache-copy failure preserves the previous project file")
}

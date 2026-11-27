import Foundation
import SrtFlowCore

// 54: what an empty project is (`TimelineState.isEmpty`, docs/architecture/video-edit-project-file.md §5 "What an empty
// project is"): the one answer to "would its file hold anything the person made?". Closing an untitled project asks only
// when it would (docs/bugfixes/2026-11-27-untitled-project-with-only-markers-closes-unasked.md: markers on the ruler and
// their notes were not counted, so they were thrown away unasked). Each kind of content alone counts, markers on the ruler
// with or without a note too; settings, switches, review marks of findings and the style record alone do not; a file that
// holds only ruler markers reads back with them and is not empty either.

func checkEmptyProject(root: URL) throws {
    check(TimelineState().isEmpty, "a new timeline is empty")
    let media = root.appendingPathComponent("empty-project-media.mov")
    let clip = EditClip(sourceURL: media, sourceDuration: 4)
    var filter = FilterClip(preset: .tealOrange, timelineStart: 0, duration: 3)
    filter.markers = [ClipMarker(sourceTime: 1, text: "Grade ends here")]
    let lines = SubtitleDocumentModel(cues: [SubtitleCue(index: 1, start: 0, end: 1, text: "Hello")])

    // Content: anything the person made, each kind alone.
    let content: [(String, (inout TimelineState) -> Void)] = [
        ("a marker on the ruler", { $0.rulerMarkers = [ClipMarker(sourceTime: 2)] }),
        ("a marker on the ruler with a note", { $0.rulerMarkers = [ClipMarker(sourceTime: 2, color: .blue, text: "Cut the intro here")] }),
        ("a clip on V1", { $0.mainClips = [clip] }),
        ("a clip on an upper video track", { $0.overlayTracks = [EditLane(clips: [clip])] }),
        ("a clip on an audio track", { $0.audioTracks = [EditLane(clips: [clip])] }),
        ("the original subtitle track", { $0.subtitle = lines }),
        ("a translation track", { $0.subtitleCompanion = SubtitleCompanion(translation: lines, targetLanguage: "zh-Hans") }),
        ("a shape", { $0.shapes = [ShapeAnnotation(kind: .rectangle, timelineStart: 0, duration: 2)] }),
        ("a text", { $0.textOverlays = [TextOverlay(text: "Title", timelineStart: 0, duration: 2, row: 0)] }),
        ("a grade carrying a marker", { $0.filters = [filter] }),
        ("a storyboard", { $0.production = FilmProductionState(revision: 1, story: "A short film", shots: [], soundCues: []) }),
        ("an explicit ending", { $0.minimumDuration = 12 }),
    ]
    for (name, make) in content {
        var state = TimelineState()
        make(&state)
        check(!state.isEmpty, "a project whose only content is \(name) is not empty: closing it untitled must ask")
    }

    // Not content: how an empty project is set up, and records about content that is no longer there.
    let anchor = DeliveryFindingAnchor(kind: "picture_jump", items: [UUID()], reference: nil, from: 1, to: 1.1,
                                       tolerance: 0.05, context: "")
    let settings: [(String, (inout TimelineState) -> Void)] = [
        ("the canvas shape", { $0.canvasRatio = .tall9x16 }),
        ("the frame rate", { $0.frameRate = .fps30 }),
        ("the faders", { $0.mainVolume = 0.5; $0.masterVolume = 0.8 }),
        ("the eyes and the magnet", { $0.mainHidden = true; $0.subtitleHidden = true; $0.translationHidden = true; $0.mainMagnet = true }),
        ("tracks without clips", { $0.overlayTracks = [EditLane(isHidden: true, colorIndex: 2)]; $0.audioTracks = [EditLane(volume: 0.5)] }),
        ("the subtitle style, place, highlight and line count", {
            $0.projectSubtitleStyle = .default
            $0.subtitleLayout = SubtitleLayout(marginLeft: 10, marginRight: 10, marginBottom: 40)
            $0.subtitleHighlight = SubtitleWordHighlight()
            $0.subtitleMaxLines = 2
        }),
        ("review marks of findings on clips that are gone", {
            $0.deliveryIntentions = [DeliveryIntentionalMark(anchor: anchor, reason: "An intended jump cut")]
        }),
        ("the editing-style record", {
            $0.editingStyle = EditingStyleRecord(id: "documentary", source: "built_in", sha256: String(repeating: "c", count: 64))
        }),
    ]
    for (name, make) in settings {
        var state = TimelineState()
        make(&state)
        check(state.isEmpty, "\(name) alone is no content: the project stays empty")
    }

    // A file that holds only ruler markers: they are in it, and what reads back is not empty.
    var marked = TimelineState()
    marked.rulerMarkers = [ClipMarker(sourceTime: 2, color: .green, text: "Music comes in")]
    let file = root.appendingPathComponent("only-ruler-markers.skycut")
    try VideoEditProjectIO.save(marked, to: file)
    let loaded = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(loaded.rulerMarkers, marked.rulerMarkers, "a project file keeps ruler markers that are its only content")
    check(!loaded.isEmpty, "a project read back with only ruler markers is not empty")
}

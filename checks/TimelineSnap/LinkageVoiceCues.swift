import Foundation
import SrtFlowCore

// Group 1k: a subtitle made from a sound off V1 (narration, an interview on an audio track) follows that sound and never
// the V1 picture (`CaptionSourceFollow.voices`, UI-3, 2026-11-18).
//
// Before: the V1 picture rule (rule 12) ran first on every subtitle above V1, so changing which part of a screen recording
// plays (edit_clip source_in / source_out) moved its narration subtitles off their words, shortened them or deleted them —
// judged by a picture that never held those words (docs/bugfixes/2026-11-18-narration-subtitles-follow-screen-recording-trim.md).
// A translation goes with the sound of the original it was translated from. Subtitles without a source (typed, imported)
// and subtitles generated from V1's own sound still follow the picture.

private let recordingFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/screen-recording.mov")
private let nextFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/next-shot.mp4")
private let narrationFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/narration.m4a")

/// V1: a 30 s screen recording playing 0–10 s at [0,10), another shot at [10,20). A1: narration [6,14) (file 0–8 s) across
/// the cut, with three subtitles: n1 [6.2,7.8) and n2 [8.3,9.9) over the recording, n3 [10.5,12.5) over the next shot.
/// A typed subtitle [2,4) over the recording; the translation track has t1 (from n1) and t2 (from the typed one).
private struct VoiceFixture {
    var state = TimelineState()
    let recording = EditClip(sourceURL: recordingFile, sourceDuration: 10, timelineStart: 0)
    let next = EditClip(sourceURL: nextFile, sourceDuration: 10, timelineStart: 10)
    let voice = EditClip(sourceURL: narrationFile, isAudioOnly: true, sourceDuration: 8, timelineStart: 6)
    let n1 = SubtitleCue(start: 6.2, end: 7.8, text: "first line")
    let n2 = SubtitleCue(start: 8.3, end: 9.9, text: "second line")
    let n3 = SubtitleCue(start: 10.5, end: 12.5, text: "third line")
    let typed = SubtitleCue(start: 2, end: 4, text: "typed by hand")
    let t1 = SubtitleCue(start: 6.2, end: 7.8, text: "première ligne")
    let t2 = SubtitleCue(start: 2, end: 4, text: "tapé à la main")

    init() {
        state.mainClips = [recording, next]
        state.audioTracks = [EditLane(clips: [voice])]
        var original = SubtitleDocumentModel(format: .srt)
        original.cues = [typed, n1, n2, n3]
        state.subtitle = original
        var companion = SubtitleCompanion(origin: .generated)
        for cue in [n1, n2, n3] { companion.cueMeta[cue.id] = CueMeta(provenance: CueProvenance(clipID: voice.id)) }
        var translation = SubtitleDocumentModel(format: .srt)
        translation.cues = [t2, t1]
        companion.translation = translation
        companion.translationLinks[t1.id] = TranslationLink(sourceIDs: [n1.id], sourceText: n1.text)
        companion.translationLinks[t2.id] = TranslationLink(sourceIDs: [typed.id], sourceText: typed.text)
        state.subtitleCompanion = companion
    }
}

private func span(_ state: TimelineState, _ id: UUID) -> [Double]? {
    state.subtitleCue(id).map { [($0.start * 1000).rounded() / 1000, ($0.end * 1000).rounded() / 1000] }
}

func checkLinkageVoiceCues() {
    let base = VoiceFixture()
    let voiced = CaptionSourceFollow.voices(in: base.state)
    checkEqual(Set(voiced.keys), [base.n1.id, base.n2.id, base.n3.id, base.t1.id], "1k: the narration's subtitles and t1 (from n1) show the narration")
    check(voiced.values.allSatisfy { $0 == .init(clip: base.voice.id, sitsOnIt: true) }, "1k: …the narration clip, which they sit on")

    // Show a later part of the recording in the same slot (edit_clip source_in=4 source_out=14): the narration spans the cut
    // and stays, so its subtitles stay. The UI-3 report: they moved 4 s earlier with the picture.
    var slipped = base.state
    slipped.update(base.recording.id) { $0.sourceStart = 4 }
    let slipReport = TimelineLinkage.follow(from: base.state, to: &slipped, deletesContent: false)
    checkEqual(slipped.clip(with: base.voice.id)?.timelineStart, 6, "1k: the narration across the cut stays where it was")
    checkEqual(span(slipped, base.n1.id), [6.2, 7.8], "1k: a new recording window leaves the narration's first subtitle on its words")
    checkEqual(span(slipped, base.n2.id), [8.3, 9.9], "1k: …and its second")
    checkEqual(span(slipped, base.t1.id), [6.2, 7.8], "1k: …and the translation of the first")
    check(span(slipped, base.typed.id) == nil && span(slipped, base.t2.id) == nil,
          "1k: a typed subtitle (and its translation) still follow the picture: theirs left the window, so they go (rule 12)")
    check(slipReport.shortenedCues.isEmpty && slipReport.deletedCues == 2, "1k: the report counts only the two picture-led subtitles")

    // End the recording 3 s earlier (source_out=7): n2's stretch of picture is gone, its words are not.
    var shortened = base.state
    shortened.update(base.recording.id) { $0.sourceDuration = 7 }
    TimelineLinkage.follow(from: base.state, to: &shortened, deletesContent: false)
    checkEqual(span(shortened, base.n2.id), [8.3, 9.9], "1k: trimming the recording's tail keeps the narration subtitle above the trimmed part")
    checkEqual(span(shortened, base.n1.id), [6.2, 7.8], "1k: …and the one before it")

    // Trim 2 s off the recording's head with a ripple: the narration rides on both shots, both move 2 s, so it moves 2 s
    // and its subtitles move with it (the same place the picture rule put them before).
    var rippled = base.state
    rippled.update(base.recording.id) { $0.sourceStart = 2; $0.sourceDuration = 8 }
    rippled.update(base.next.id) { $0.timelineStart = 8 }
    TimelineLinkage.follow(from: base.state, to: &rippled, deletesContent: false)
    checkEqual(rippled.clip(with: base.voice.id)?.timelineStart, 4, "1k: a ripple moves the narration with its pictures")
    checkEqual(span(rippled, base.n1.id), [4.2, 5.8], "1k: …its subtitles go with it")
    checkEqual(span(rippled, base.n3.id), [8.5, 10.5], "1k: …over either shot")
    checkEqual(span(rippled, base.t1.id), [4.2, 5.8], "1k: …and so does the translation")

    // Moving the narration itself: the translation of its subtitle goes with it too (the words are the narration's).
    var dragged = base.state
    dragged.update(base.voice.id) { $0.timelineStart = 8 }
    let dragReport = TimelineLinkage.follow(from: base.state, to: &dragged, deletesContent: false)
    checkEqual(span(dragged, base.n1.id), [8.2, 9.8], "1k: the narration moved +2 s: its subtitle follows")
    checkEqual(span(dragged, base.t1.id), [8.2, 9.8], "1k: …and the translation of it")
    checkEqual(span(dragged, base.t2.id), [2, 4], "1k: a translation of a typed subtitle stays")
    checkEqual(dragReport.moved, 4, "1k: the report counts the three subtitles and the translation")
    var removed = base.state
    removed.remove(base.voice.id)
    TimelineLinkage.follow(from: base.state, to: &removed, deletesContent: true)
    check(span(removed, base.t1.id) == nil && span(removed, base.n1.id) == nil, "1k: deleting the narration deletes the translation of its subtitle too")

    // Dragging the recording alone: the narration spans the cut and stays, so its subtitles are not carried along;
    // dragging both shots carries the narration and its subtitles with it.
    let alone = TimelineLinkage.attachments(of: [base.recording.id], in: base.state)
    checkEqual(Set(alone.cues.map(\.id)), [base.typed.id, base.t2.id], "1k: a V1 drag carries only the picture-led subtitles above it")
    let both = TimelineLinkage.attachments(of: [base.recording.id, base.next.id], in: base.state)
    checkEqual(Set(both.clips.map(\.id)), [base.voice.id], "1k: dragging both shots carries the narration")
    checkEqual(Set(both.cues.map(\.id)), [base.typed.id, base.t2.id, base.n1.id, base.n2.id, base.n3.id, base.t1.id],
               "1k: …and every subtitle of it")
    check(both.cues.filter { voiced[$0.id] != nil }.allSatisfy { $0.host == both.clips[0].host },
          "1k: the narration's subtitles land where the narration lands (same host)")
    checkSplitNarration()
}

/// A narration split in two keeps its right half's subtitles naming the left half (rule 11's known limit). Those do not sit
/// on the clip they name, so they stay with the picture rule: deleting the left half for real must not take them along.
private func checkSplitNarration() {
    var state = TimelineState()
    let first = EditClip(sourceURL: recordingFile, sourceDuration: 10, timelineStart: 0)
    let second = EditClip(sourceURL: nextFile, sourceDuration: 10, timelineStart: 10)
    let left = EditClip(sourceURL: narrationFile, isAudioOnly: true, sourceDuration: 6, timelineStart: 2)
    var right = EditClip(sourceURL: narrationFile, isAudioOnly: true, sourceDuration: 4, timelineStart: 12)
    right.sourceStart = 6
    let onLeft = SubtitleCue(start: 3, end: 5, text: "said in the left half")
    let onRight = SubtitleCue(start: 12.5, end: 14.5, text: "said in the right half")
    state.mainClips = [first, second]
    state.audioTracks = [EditLane(clips: [left, right])]
    var original = SubtitleDocumentModel(format: .srt)
    original.cues = [onLeft, onRight]
    state.subtitle = original
    var companion = SubtitleCompanion(origin: .generated)
    for cue in [onLeft, onRight] { companion.cueMeta[cue.id] = CueMeta(provenance: CueProvenance(clipID: left.id)) }
    state.subtitleCompanion = companion
    checkEqual(CaptionSourceFollow.voices(in: state)[onRight.id], .init(clip: left.id, sitsOnIt: false),
               "1k: a subtitle away from the clip its source names does not sit on it")

    // Delete the first shot for real; the magnet closes the gap. The left half sits inside it and goes, with its subtitle;
    // the right half rides on the second shot, and so does the subtitle said in it.
    var after = state
    after.remove(first.id)
    after.update(second.id) { $0.timelineStart = 0 }
    TimelineLinkage.follow(from: state, to: &after, deletesContent: true)
    check(after.clip(with: left.id) == nil && span(after, onLeft.id) == nil, "1k: the left half and its subtitle go with the shot")
    checkEqual(span(after, onRight.id), [2.5, 4.5], "1k: a subtitle of the right half moves with its shot, not deleted with the left half")
}

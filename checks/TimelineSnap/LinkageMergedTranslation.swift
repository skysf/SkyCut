import Foundation
import SrtFlowCore

// Group 1l: a merged translation follows by the speech of all the originals it was translated from (review CXR2 R11,
// 2026-11-19; docs/architecture/timeline-linkage.md rule 12).
//
// Merging translations (`SubtitleTrackEditing.mergeCues`) gives one translation several source lines. Linkage keeps a subtitle
// when half or more of its speech is left; a translation has no word timing of its own and goes by its originals' words. It
// used to read only the first original: a merged translation whose first, shorter line was trimmed away was deleted although
// most of its speech was kept, and one whose later line was trimmed away stayed although most of it was gone. Now its speech is
// all its originals' lines together, so trimming the head or the tail of the same speech gives the same answer, both for a
// narration off V1 (rule 11, `CaptionSourceFollow`) and for V1's own picture (rule 12). Single-source translations keep their
// checks in LinkageCues.swift (group 1h). Built with scripts/check-timeline-snap.sh.

private let narrationFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/merged-narration.m4a")
private let talkFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/merged-talk.mp4")

/// An 8 s clip (narration on A1, or V1's own picture), two originals with word timing over `first` and `second` (timeline
/// seconds of their speech), and their translations merged into one by the production merge.
private struct MergedFixture {
    var state = TimelineState()
    let clip: EditClip
    let first: SubtitleCue
    let second: SubtitleCue
    let merged: UUID

    init(onMain: Bool, first firstSpeech: (Double, Double), second secondSpeech: (Double, Double)) {
        clip = onMain ? EditClip(sourceURL: talkFile, sourceDuration: 8, timelineStart: 0)
            : EditClip(sourceURL: narrationFile, isAudioOnly: true, sourceDuration: 8, timelineStart: 0)
        first = Self.line(firstSpeech, "first line")
        second = Self.line(secondSpeech, "second line")
        if onMain { state.mainClips = [clip] } else { state.audioTracks = [EditLane(clips: [clip])] }
        var original = SubtitleDocumentModel(format: .srt)
        original.cues = [first, second]
        var companion = SubtitleCompanion(origin: .generated)
        // The narration's lines name it (rule 11); V1's are left to the picture (rule 12).
        if !onMain { for cue in [first, second] { companion.cueMeta[cue.id] = CueMeta(provenance: CueProvenance(clipID: clip.id)) } }
        let translations = [first, second].map { SubtitleCue(start: $0.start, end: $0.end, text: "translated \($0.text)") }
        var translation = SubtitleDocumentModel(format: .srt)
        translation.cues = translations
        companion.translation = translation
        for (cue, source) in zip(translations, [first, second]) {
            companion.translationLinks[cue.id] = TranslationLink(sourceIDs: [source.id], sourceText: source.text)
        }
        check(SubtitleTrackEditing.mergeCues(ids: Set(translations.map(\.id)), original: &original, companion: &companion),
              "1l: the production merge joins the two translations")
        merged = translations[0].id
        state.subtitle = original
        state.subtitleCompanion = companion
    }

    /// A line whose one word runs over `speech`; it shows 0.3 s longer (the pause after it, as generated subtitles do).
    static func line(_ speech: (Double, Double), _ text: String) -> SubtitleCue {
        let words = [SubtitleCueWord(location: 0, length: (text as NSString).length, start: 0, end: speech.1 - speech.0)]
        return SubtitleCue(start: speech.0, end: speech.1 + 0.3, text: text, words: words)
    }

    /// Trims `seconds` off the clip's head, leaving what remains where it was (the words do not move).
    func trimmingHead(_ seconds: Double) -> TimelineState {
        var after = state
        after.update(clip.id) { $0.sourceStart = seconds; $0.sourceDuration = 8 - seconds; $0.timelineStart = seconds }
        TimelineLinkage.follow(from: state, to: &after, deletesContent: false)
        return after
    }

    /// Ends the clip at `time`.
    func trimmingTail(at time: Double) -> TimelineState {
        var after = state
        after.update(clip.id) { $0.sourceDuration = time }
        TimelineLinkage.follow(from: state, to: &after, deletesContent: false)
        return after
    }
}

private func span(_ state: TimelineState, _ id: UUID) -> [Double]? {
    state.subtitleCue(id).map { [($0.start * 1000).rounded() / 1000, ($0.end * 1000).rounded() / 1000] }
}

func checkLinkageMergedTranslations() {
    // The review's case: lines spoken over [1,2] and [3,7] on a narration, translations merged. Trimming the narration's
    // first 2.5 s keeps 4 of the 5 s spoken: the merged translation stays, from where the sound now starts. Before: judged by
    // the first line alone (none of it left), it was deleted while the second original stayed.
    let review = MergedFixture(onMain: false, first: (1, 2), second: (3, 7))
    checkEqual(review.state.subtitleCompanion?.translationLinks[review.merged]?.sourceIDs, [review.first.id, review.second.id],
               "1l: the merged translation names both originals")
    let trimmed = review.trimmingHead(2.5)
    checkEqual(span(trimmed, review.merged), [2.5, 7.3],
               "1l: 2.5 s trimmed off the narration keep 4 of the 5 s spoken: the merged translation stays (was deleted)")
    check(span(trimmed, review.first.id) == nil, "1l: …the first original, all of whose words were trimmed, is deleted")
    checkEqual(span(trimmed, review.second.id), [3, 7.3], "1l: …the second stays on its words")

    // Head or tail, the same answer: two lines of 2 s each at [1,3] and [3.5,5.5]. Keeping 2.2 of the 4 s keeps it, keeping
    // 1.6 deletes it, whichever line was cut. Before: the head trims were judged by the first line alone (0.2 of 2 s left:
    // deleted) and so were the tail trims (1.6 of 2 s left: kept).
    for (onMain, path) in [(false, "a narration"), (true, "V1")] {
        let even = MergedFixture(onMain: onMain, first: (1, 3), second: (3.5, 5.5))
        checkEqual(span(even.trimmingHead(2.8), even.merged), [2.8, 5.8],
                   "1l (\(path)): head trimmed to 2.8 s, 2.2 of 4 s spoken left: the merged translation stays")
        checkEqual(span(even.trimmingTail(at: 3.7), even.merged), [1, 3.7],
                   "1l (\(path)): tail trimmed at 3.7 s, 2.2 of 4 s spoken left: the merged translation stays")
        check(span(even.trimmingHead(3.9), even.merged) == nil,
              "1l (\(path)): head trimmed to 3.9 s, 1.6 of 4 s spoken left: the merged translation is deleted")
        check(span(even.trimmingTail(at: 2.6), even.merged) == nil,
              "1l (\(path)): tail trimmed at 2.6 s, 1.6 of 4 s spoken left: the merged translation is deleted (was kept)")
    }
}

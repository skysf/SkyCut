import Foundation
import SrtFlowMCPKit

// MARK: - Where the music is missing: late, gone for a long stretch, dropping out under a line (MCP-40 tier 2; report only)
//
// Owns three rows of production feedback MCP-40's second tier, from the production research's check_project.py (rules 5 and 11,
// the preview board's music_late / no_score / music_drops), read on the music role group (AIDeliverySoundLevels: everything
// AIDeliverySoundRoles takes as music) in the research's 0.1 s cells (DeliveryCells):
// - `audio_music_drops` (rule 11): music was heard (above −45 dBFS) within the last 3 s, a voice speaks (voice group above
//   −35 dBFS) and the music sits more than 22 dB under it, for 2 s or more: under the line it is all but gone, and the shots it
//   carried come apart (the user on the fourth draft's 0:57: "like the music suddenly died"; the shared rules dip about 10 dB).
// - `audio_music_late` (rule 5): the video has music, but it is first heard more than 3 s after the first picture. As the shared
//   rules allow (Voice and music 4), an opening line (a transcript or narration sentence, or a line of the voice check) that
//   starts inside those 3 s moves the deadline to 3 s after that line ends. Judged only when the measured frames reach the
//   deadline (a narrow from/to that misses the opening says nothing).
// - `audio_no_score` (rule 5, a reminder): 15 s or more with neither music nor a long tone or riser (an effect lasting 3 s or
//   more, heard above −50 dBFS within 0.5 s; SkyCut can't name an effect's kind, so length stands in for it). Only when the
//   video has music somewhere; a video with none gets one grey hint instead (`audio_no_music`, listed in `hints`): fine for a
//   talk, an interview or a tutorial, the shared rules make music optional. Since 2026-11-20 (the user: by style) it is the
//   suspect `audio_music_missing` when the editing style the film was cut with expects music (AIDeliveryStyleMusic).
// Thresholds are the research's (one human film and two AI drafts; delivery-checks.md in the research folder), not validated
// across genres: report only, and intentional marks apply. Hard music starts and stops are AIDeliveryMusicEdges.
// Not here: measuring (AIDeliverySoundLevels), roles (AIDeliverySoundRoles), music under a line rising (AIDeliveryMusicSwell).

enum AIDeliveryMusic {
    /// Music counts as heard above this (dBFS, a 0.1 s cell of the music group).
    static let heardDB = -45.0
    /// A voice counts as speaking above this (dBFS, the voice group).
    static let voiceDB = -35.0
    /// Music more than this under a speaking voice is as good as gone (dB).
    static let dropDB = 22.0
    static let dropSeconds = 2.0
    /// Music heard this recently (seconds) is music that dropped out, not music that never came.
    static let recentSeconds = 3.0
    static let lateSeconds = 3.0
    static let noScoreSeconds = 15.0
    /// An effect this long (seconds) stands in for a long tone or a riser.
    static let longEffectSeconds = 3.0
    /// A long effect counts where it is heard above this (dBFS) within `smoothSeconds` either side (the research's layers).
    static let effectHeardDB = -50.0
    static let smoothSeconds = 0.5
    /// A video with no music at all gets the grey hint only when at least this long (seconds).
    static let noMusicSeconds = 15.0

    // MARK: Music dropping out under a line (rule 11)

    static func drops(_ levels: AIDeliverySoundLevels, sounds: [AIDeliveryCutJumps.Sound],
                      scope: AIInspection.Scope) -> [AIInspection.Finding] {
        guard levels.frames[.music] != nil, levels.frames[.voice] != nil else { return [] }
        let cells = DeliveryCells(levels), recent = DeliveryCells.count(recentSeconds)
        var lastHeard: Int?
        var flags: [Bool] = []
        var levelPairs: [(voice: Double, music: Double)] = []
        for cell in cells.range {
            let music = cells.db(levels, .music, cell), voice = cells.db(levels, .voice, cell)
            if music > heardDB { lastHeard = cell }
            let musicWasThere = lastHeard.map { cell - $0 <= recent } ?? false
            flags.append(musicWasThere && voice > voiceDB && voice - music > dropDB)
            levelPairs.append((voice, music))
        }
        return DeliveryCells.runs(flags, minimum: DeliveryCells.count(dropSeconds)).compactMap { run in
            let from = DeliveryCells.from(cells.range.lowerBound + run.lowerBound)
            let to = DeliveryCells.from(cells.range.lowerBound + run.upperBound)
            guard scope.intersects(from, to) else { return nil }
            let voice = median(levelPairs[run].map(\.voice)), music = max(-60, median(levelPairs[run].map(\.music)))
            let items = sounds.filter {
                ($0.role == .voice && $0.start < to && $0.end > from)
                    || ($0.role == .music && $0.start < to && $0.end > from - recentSeconds)
            }.map(\.id)
            return AIInspection.Finding(
                kind: "audio_music_drops", from: from, to: to,
                reason: String(format: "For %.1f s under this line the music sits more than %.0f dB under the voice (voice %.0f dBFS, music "
                    + "%.0f dBFS) after it was heard in the 3 s before: it all but vanishes, and the shots it carried come apart. Keep it "
                    + "about 10 dB under the words instead (set_track duck_others_db), or mark it intentional.", to - from, dropDB, voice, music),
                items: items, details: ["voice_db": tenths(voice), "music_db": tenths(music)])
        }
    }

    // MARK: Music late, a long stretch without any, none at all (rule 5)

    /// `firstPicture`: where the first visible picture starts (nil: no picture). `lines`: spoken lines (timeline seconds).
    static func late(_ levels: AIDeliverySoundLevels, sounds: [AIDeliveryCutJumps.Sound], firstPicture: Double?,
                     lines: [ClosedRange<Double>], duration: Double, scope: AIInspection.Scope) -> [AIInspection.Finding] {
        guard let start = firstPicture, sounds.contains(where: { $0.role == .music }) else { return [] }
        let cells = DeliveryCells(levels)
        guard let firstCell = cells.range.first, DeliveryCells.from(firstCell) <= start + 1e-6 else { return [] }
        var deadline = start + lateSeconds
        if let opening = lines.filter({ $0.lowerBound < deadline && $0.upperBound > start }).min(by: { $0.lowerBound < $1.lowerBound }) {
            deadline = max(deadline, opening.upperBound + lateSeconds)
        }
        let measuredEnd = DeliveryCells.from(cells.range.upperBound)
        let heard = cells.range.first { cells.db(levels, .music, $0) > heardDB }.map(DeliveryCells.from)
        if let heard, heard <= deadline + 1e-6 { return [] }
        // Without music heard by the deadline, say so only when the deadline itself was measured.
        guard heard != nil || measuredEnd >= min(deadline, duration) - DeliveryCells.seconds else { return [] }
        let to = heard ?? measuredEnd
        guard to > start, scope.intersects(start, to) else { return [] }
        let music = sounds.filter { $0.role == .music }
        let first = heard.flatMap { at in music.first { $0.start <= at + 1e-6 && $0.end > at } } ?? music.min { $0.start < $1.start }
        let when = heard.map { String(format: "music is first heard at %.2f s", $0) }
            ?? String(format: "no music is heard by %.2f s (the end of what was checked)", to)
        return [AIInspection.Finding(
            kind: "audio_music_late", from: start, to: to,
            reason: String(format: "The picture starts at %.2f s but %@: an opening without music is flat. Bring it in within %.0f s of the "
                + "first picture (quiet, with some melody), or within %.0f s of an opening line's end, or mark it intentional.",
                start, when, lateSeconds, lateSeconds),
            items: first.map { [$0.id] } ?? [],
            details: ["music_at": heard.map { AIFormat.seconds($0) } ?? .null, "deadline": AIFormat.seconds(deadline)])]
    }

    static func noScore(_ levels: AIDeliverySoundLevels, sounds: [AIDeliveryCutJumps.Sound],
                        scope: AIInspection.Scope) -> [AIInspection.Finding] {
        guard sounds.contains(where: { $0.role == .music }) else { return [] }
        let cells = DeliveryCells(levels), smooth = DeliveryCells.count(smoothSeconds)
        let long = sounds.filter { $0.role == .effects && $0.end - $0.start >= longEffectSeconds - 1e-6 }
        let effects = cells.range.map { cells.db(levels, .effects, $0) }
        let flags = cells.range.enumerated().map { offset, cell -> Bool in
            if cells.db(levels, .music, cell) > heardDB { return false }
            let middle = DeliveryCells.from(cell) + DeliveryCells.seconds / 2
            guard long.contains(where: { $0.start <= middle && $0.end > middle }) else { return true }
            let around = effects[max(0, offset - smooth) ..< min(effects.count, offset + smooth + 1)]
            return (around.max() ?? -120) <= effectHeardDB
        }
        return DeliveryCells.runs(flags, minimum: DeliveryCells.count(noScoreSeconds)).compactMap { run in
            let from = DeliveryCells.from(cells.range.lowerBound + run.lowerBound)
            let to = DeliveryCells.from(cells.range.lowerBound + run.upperBound)
            guard scope.intersects(from, to) else { return nil }
            return AIInspection.Finding(
                kind: "audio_no_score", from: from, to: to,
                reason: String(format: "A reminder: for %.0f s there is neither music nor a long tone or riser, so nothing carries these "
                    + "shots. Fine for a dialogue scene; otherwise bring music or a bed under it, or mark it intentional.", to - from))
        }
    }

    /// Nothing anywhere is music: the suspect `audio_music_missing` when `style` (the film's editing style, AIDeliveryStyleMusic)
    /// expects music, else a grey hint (listed in `hints`, not counted with the suspects). Both are about the whole film.
    static func noMusic(sounds: [AIDeliveryCutJumps.Sound], duration: Double, scope: AIInspection.Scope,
                        style: AIDeliveryStyleMusic.Style? = nil) -> [AIInspection.Finding] {
        guard !sounds.isEmpty, !sounds.contains(where: { $0.role == .music }), duration >= noMusicSeconds,
              let from = scope.ranges.map(\.lowerBound).min(), let to = scope.ranges.map(\.upperBound).max() else { return [] }
        if let style {
            let name = style.title == style.id ? style.id : "\(style.title) (\(style.id))"
            return [AIInspection.Finding(
                kind: "audio_music_missing", from: from, to: to,
                reason: "Nothing here is music, and the editing style this film was cut with, \(name), expects music from the first "
                    + "3 s. Bring music in (find_audio, or a track of the user's), or mark it intentional. An imported music file "
                    + "counts once it is named music (edit_clip sound_role music, or sounds).",
                details: ["style": .string(style.id)])]
        }
        return [AIInspection.Finding(
            kind: "audio_no_music", from: from, to: to,
            reason: "Grey hint, not a suspect: nothing here is music (library or generated music, or what sounds names music). Fine "
                + "for a talk, an interview or a tutorial; a trailer, a promo or a montage usually carries music from its first 3 s.")]
    }

    // MARK: Helpers

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return -120 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func tenths(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
}

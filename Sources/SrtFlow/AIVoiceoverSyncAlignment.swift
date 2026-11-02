import Foundation
import SrtFlowCore

// MARK: - 新音频的词映回原稿（纯值）
// 管什么：复用 SubtitleCueWords 字符对齐，按新词时间重写现有 cue；保留 id、原稿、繁简体与两轨独立性。
// 不管什么：ASR、时间线比例缩放和提交；对不准就整次失败，不猜旧字幕的新时间。

enum AIVoiceoverSyncAlignment {
    static func timings(
        cues: [SubtitleCue], words: [TimedWord], start: Double, duration: Double
    ) throws -> [UUID: SubtitleTrackEditing.Timing] {
        guard !cues.isEmpty else { return [:] }
        let cues = cues.sorted { $0.start < $1.start }
        let script = cues.map(\.text).joined(separator: "\n")
        let recognized = words.map(\.text).joined()
        guard script.count <= 2_000, recognized.count <= 4_000 else {
            throw AIToolError("A subtitle alignment paragraph exceeds 2,000 script or 4,000 recognized characters; split the mapping.")
        }
        var offset = 0
        var timed: [SubtitleCueWord] = []
        var previous = 0.0
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= previous,
                  word.end > word.start, word.start >= 0, word.end <= duration + 0.001 else { throw problem() }
            timed.append(.init(location: offset, length: word.text.utf16.count, start: word.start, end: word.end))
            offset += word.text.utf16.count
            previous = word.start
        }
        guard let aligned = SubtitleCueWords.realigned(timed, from: recognized, to: script, foldsChineseScript: true) else {
            throw problem()
        }
        offset = 0
        var result: [UUID: SubtitleTrackEditing.Timing] = [:]
        var lastEnd = 0.0
        for cue in cues {
            let end = offset + cue.text.utf16.count
            let own = aligned.filter { $0.location >= offset && $0.location + $0.length <= end }
            let ownText = own.compactMap { word -> String? in
                guard let source = timed.first(where: { $0.start == word.start && $0.end == word.end }) else { return nil }
                return (recognized as NSString).substring(with: NSRange(location: source.location, length: source.length))
            }.joined()
            let count = cue.text.filter { $0.isLetter || $0.isNumber }.count
            let matched = SubtitleCueWords.matchingCharacterCount(ownText, to: cue.text, foldsChineseScript: true)
            guard count > 0, Double(matched) >= Double(count) * 0.9, let first = own.first, let last = own.last,
                  first.start >= lastEnd - 0.000001, last.end > first.start else { throw problem() }
            let relative = own.map { word in
                SubtitleCueWord(location: word.location - offset, length: word.length,
                                start: word.start - first.start, end: word.end - first.start)
            }
            result[cue.id] = .init(start: start + first.start, end: start + last.end, words: relative)
            lastEnd = last.end
            offset = end + 1
        }
        return result
    }

    private static func problem() -> AIToolError {
        AIToolError("Subtitle alignment failed: the new audio's words do not reliably match each original cue. Nothing was applied. Keep the audio, check the script/language or split cues at spoken word boundaries, then retry sync_voiceover; do not generate the voice again.")
    }
}

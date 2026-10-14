import Foundation
import SrtFlowCore

// MARK: - 联动：一句字幕跟着画面走时，两头各自换算（纯值）
//
// 管什么：一次改动之后，压在画面上的一句字幕（原文、译文两条轨；配音那条规矩 11 也用它）怎么跟（联动规矩 12）：
// 1. 底下的画面只是被剪掉 / 裁掉了一部分、或者变了速（剩下的几截前后顺序不变、中间没插进别的东西）：**两头各自跟着画面换算**
//    —— 中间剪掉一截就缩短，开头 / 结尾被剪掉就收到剩下的那截，变速跟着伸缩；逐词高亮的词时间一起换算。
// 2. 这句说话的那几秒剩下**不到一半**：真删（⌫、delete_items、cut_speech）就删；不是真删（裁切、变速）就留在原地
//    （同联动规矩 4），报出来让人 / AI 收拾。「说话的那几秒」有逐词时间就按词，译文按它翻自的那句原文，都没有才按整句的显示时间
//    —— 显示时间里有说完之后多停的半秒（`SubtitleCueTiming`），删停顿时剪掉的正是它，按显示时间算会把「OK.」这种短句误删。
// 3. 别的情况（换了位置、中间插进了别的东西、底下没有画面）照老规矩：整句跟着挪，或者不动（调用方给的 `fallback`）。
// 为什么（2026-10-15，docs/bugfixes/2026-10-15-linkage-moves-subtitles-as-a-block.md）：以前整句平移、时长不变 ——
// 剪掉的那句只要尾巴蹭进保留段几帧就整句留下、挂到前一段上；保留的那句开头被剪掉几帧，整句就往前挪到片段开始之前；
// 删停顿时一句的尾巴被剪掉、它却不缩，和往前挪的下一句叠在画面上。
// 不管什么：哪些东西算压在画面上、别的种类怎么跟（TimelineLinkage）、写进字幕轨（SubtitleTrackEditing.setTimings）。

enum LinkageCueFollow {
    typealias Piece = TimelineLinkage.Piece

    /// 一句字幕底下还在的一截画面：改之前在时间线的哪一段、改之后在哪一段。
    struct Segment: Equatable {
        var oldStart: Double
        var oldEnd: Double
        var newStart: Double
        var newEnd: Double

        var delta: Double { newStart - oldStart }
        var oldLength: Double { oldEnd - oldStart }
    }

    enum Outcome: Equatable {
        case stay
        case delete
        /// 说话的那几秒大半没了、又不是真删：留在原地（报出来）。
        case leftBehind
        /// 换成这个时间；`shortened` = 它底下有画面被剪掉了（字里可能还留着剪掉的词）。
        case retime(SubtitleTrackEditing.Timing, shortened: Bool)
    }

    /// 说话的那几秒剩下不到这么多就算没了。
    static let keepFraction = 0.5
    static let epsilon = TimelineLinkage.epsilon

    /// 这句字幕怎么跟。`speech`：说话的那几秒（`speech(of:originals:links:)`）；`hosts`：改之前它可能压着的画面；
    /// `survivors`：一段画面改之后还在哪几段里（同 id 的在前）；`fallback`：照老规矩（整句挪多少 / 不动 / 删）。
    static func outcome(
        _ cue: SubtitleCue, speech: TimelineSpan, hosts: [Piece], survivors: (Piece) -> [Piece],
        deletesContent: Bool, fallback: () -> TimelineLinkage.Outcome
    ) -> Outcome {
        let span = cue.span
        let under = hosts.filter { $0.overlaps(span) }
        guard !under.isEmpty else { return whole(cue, fallback()) }
        let parts = segments(of: span, hosts: under, survivors: survivors)
        guard !parts.isEmpty else { return deletesContent ? .delete : .leftBehind }
        let kept = survived(speech, hosts: hosts, survivors: survivors) ?? survived(span, hosts: hosts, survivors: survivors) ?? 1
        if kept < keepFraction - 1e-9 { return deletesContent ? .delete : .leftBehind }
        guard inOrder(parts) else { return whole(cue, fallback()) }

        let first = parts[0]
        let last = parts[parts.count - 1]
        let leadCut = hosted(span.start, first.oldStart, by: under) > epsilon
        let trailCut = hosted(last.oldEnd, span.end, by: under) > epsilon
        let cutInside = hosted(span.start, span.end, by: under) - parts.reduce(0) { $0 + $1.oldLength } > epsilon
        let shortened = leadCut || trailCut || cutInside
        // 底下的画面整体挪了同一个量、什么都没剪：整句平移（词记的是相对开头的秒，不用动）。
        if !shortened, parts.allSatisfy({ abs($0.delta - first.delta) <= epsilon && abs(($0.newEnd - $0.newStart) - $0.oldLength) <= epsilon }) {
            guard abs(first.delta) > epsilon else { return .stay }
            return whole(cue, .move(by: first.delta))
        }
        let map = { (time: Double) in mapped(time, parts, leadCut: leadCut, trailCut: trailCut) }
        let start = max(0, map(span.start))
        let end = max(start, map(span.end))
        guard abs(start - cue.start) > epsilon || abs(end - cue.end) > epsilon || shortened else { return .stay }
        let words = cue.words.map { words in
            words.map { word -> SubtitleCueWord in
                var moved = word
                moved.start = min(max(map(span.start + word.start) - start, 0), end - start)
                moved.end = min(max(map(span.start + word.end) - start, moved.start), end - start)
                return moved
            }
        }
        return .retime(.init(start: start, end: end, words: words), shortened: shortened)
    }

    // MARK: 说话的那几秒

    /// 这句说话的那几秒（时间线，改之前）：有逐词时间就是第一个词的开头到最后一个词的结尾；译文没有词就看它翻自的那句原文；
    /// 都没有就是整句的显示时间。
    static func speech(of cue: SubtitleCue, originals: [UUID: SubtitleCue], links: [UUID: TranslationLink]) -> TimelineSpan {
        if let span = wordSpan(of: cue) { return span }
        if let source = links[cue.id]?.sourceIDs.first, let original = originals[source], let span = wordSpan(of: original) {
            return span
        }
        return cue.span
    }

    private static func wordSpan(of cue: SubtitleCue) -> TimelineSpan? {
        guard let words = cue.words, let first = words.map(\.start).min(), let last = words.map(\.end).max(),
              last - first > epsilon else { return nil }
        return TimelineSpan(start: cue.start + first, end: cue.start + last)
    }

    // MARK: 底下还剩哪几截画面

    /// 这一段（时间线）底下每一截还在的画面，按改之前的先后排。同 id 的那段盖住的部分只认它（粘贴出来的同素材新段不算画面
    /// 挪过去了，联动规矩 1）；它没盖住的部分（切开之后右边的新 id、剪掉中间之后后面那块）再找这次新出来的同素材段。
    static func segments(of span: TimelineSpan, hosts: [Piece], survivors: (Piece) -> [Piece]) -> [Segment] {
        var result: [Segment] = []
        for host in hosts where host.overlaps(span) {
            var rest = [host.source(at: max(span.start, host.start))...host.source(at: min(span.end, host.end))]
            for piece in survivors(host) {
                var left: [ClosedRange<Double>] = []
                for range in rest {
                    let from = max(range.lowerBound, piece.sourceStart)
                    let to = min(range.upperBound, piece.sourceEnd)
                    guard to - from > epsilon else {
                        left.append(range)
                        continue
                    }
                    result.append(Segment(
                        oldStart: host.time(atSource: from), oldEnd: host.time(atSource: to),
                        newStart: piece.time(atSource: from), newEnd: piece.time(atSource: to)
                    ))
                    if from - range.lowerBound > epsilon { left.append(range.lowerBound...from) }
                    if range.upperBound - to > epsilon { left.append(to...range.upperBound) }
                }
                rest = left
            }
        }
        return result.sorted { $0.oldStart < $1.oldStart }
    }

    /// 这一段底下的画面还剩几成；底下本来就没画面是 nil。
    private static func survived(_ span: TimelineSpan, hosts: [Piece], survivors: (Piece) -> [Piece]) -> Double? {
        let under = hosts.filter { $0.overlaps(span) }
        let total = hosted(span.start, span.end, by: under)
        guard total > epsilon else { return nil }
        return segments(of: span, hosts: under, survivors: survivors).reduce(0) { $0 + $1.oldLength } / total
    }

    /// [from, to) 里改之前有画面的长度。
    private static func hosted(_ from: Double, _ to: Double, by hosts: [Piece]) -> Double {
        hosts.reduce(0) { $0 + max(0, min(to, $1.end) - max(from, $1.start)) }
    }

    /// 剩下的几截前后顺序没变、中间没插进别的：后一截的新开头不早于前一截的新结尾，两截之间的距离也没变大。
    private static func inOrder(_ parts: [Segment]) -> Bool {
        zip(parts, parts.dropFirst()).allSatisfy { previous, next in
            next.newStart >= previous.newEnd - epsilon
                && next.newStart - previous.newEnd <= next.oldStart - previous.oldEnd + epsilon
        }
    }

    // MARK: 一刻换到改之后

    /// 落在还在的画面上：按那截换算；落在剪掉的画面上：收到下一截还在的开头（开头之前收到第一截的开头、结尾之后收到最后一截的结尾）；
    /// 落在本来就没画面的地方（主轨的缝、配音段外面）：跟着挨着的那截平移。
    private static func mapped(_ time: Double, _ parts: [Segment], leadCut: Bool, trailCut: Bool) -> Double {
        if let part = parts.first(where: { time >= $0.oldStart - epsilon && time <= $0.oldEnd + epsilon }) {
            let ratio = part.oldLength > epsilon ? min(max((time - part.oldStart) / part.oldLength, 0), 1) : 0
            return part.newStart + ratio * (part.newEnd - part.newStart)
        }
        let first = parts[0]
        let last = parts[parts.count - 1]
        if time < first.oldStart { return leadCut ? first.newStart : first.newStart - (first.oldStart - time) }
        if time > last.oldEnd { return trailCut ? last.newEnd : last.newEnd + (time - last.oldEnd) }
        return parts.first { $0.oldStart > time }?.newStart ?? last.newEnd
    }

    /// 老规矩的结果换成字幕的：整句挪 `delta`（开头不早于 0，时长不变，同 `SubtitleTrackEditing.setStarts`）。
    private static func whole(_ cue: SubtitleCue, _ outcome: TimelineLinkage.Outcome) -> Outcome {
        switch outcome {
        case .stay: return .stay
        case .delete: return .delete
        case .move(let delta):
            let start = max(0, cue.start + delta)
            return .retime(.init(start: start, end: start + cue.end - cue.start, words: cue.words), shortened: false)
        }
    }
}

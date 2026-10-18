import Foundation
import SrtFlowCore

// MARK: - cut_speech 的切口最后落在哪：先听量出来的停顿，转写只用来认词（纯值）
//
// 管什么：一处切口（AI 给的一刻，或口头禅、说重了的词的边）最后切在哪、为什么挪：
// 1. `snaps` 为 false（AI 传了 snap=false）：照给的时间切，一刀不挪（合并时照旧对齐到帧）。
// 2. 这一刻落在量出来的停顿里（贴着停顿的边、差不到一个电平窗也算）：原样用 —— AI 拿 listen 量好的静音来剪，就照它切。
// 3. 否则先按转写挪（`AISpeechCuts.startPoint` / `endPoint`：词间空隙的中点，离词最多 0.3 秒），挪到的那一刻在停顿里就用它。
// 4. 还不在：在这两个词之间（转写里前一个词的中点到后一个词的中点；没有转写就是前后 0.3 秒）找量出来的停顿，
//    取离第 3 步那一刻最近的一段 —— 段的开头切在停顿中间、但离后面的声音最多 0.3 秒，结尾反过来；没有够长的停顿，
//    就找最近的一个安静的窗（一口气说下去时词和词之间那几十毫秒），切在它中间。
// 5. 都没有（一口气说下去、背景太吵）：用第 3 步那一刻，并标出这一刀可能切到字。
// 读不到声音时只剩第 1、3 步（2026-10-14 之前就是这样）。
//
// 为什么先听（docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md）：转写的词时间是给字幕估的 —— 停顿后面第一个词的开口
// 故意往前估（`SubtitleSpeechOnset`：字幕宁早勿晚），句末的词常把后面的停顿并进自己的结尾，前后差 0.1–0.3 秒；只信它，
// AI 拿 listen 量好的静音切口会被挪进词里（「When」的开头被切掉、带进上一句的尾音）。
// 数据（停顿、安静窗、词）永远是声音的源秒；cut_speech 问的、拿回去的是时间线秒（`clip`），进出各换一次 —— listen cuts=true
// 直接问源秒。两边的数据都从 `AISpeechHearing` 来（整个素材文件一份），同一个源时刻判得一样
// （docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md）。
// 不管什么：哪几段要剪（AISpeechCuts）、读波形和结果怎么写（AISpeechCutTool）、输入从哪来（AISpeechHearing）。

struct AISpeechCutPoints {
    /// 这一刀是一段的开头（后面接着说话）还是结尾（前面刚说完）。
    enum Side { case start, end }

    /// 一处切口最后落在哪。`why` 为 nil = 没挪；`onSpeech` = 附近找不到停顿，这一刀可能切到字。
    struct Point: Equatable {
        var time: Double
        var why: String?
        var onSpeech = false
    }

    /// AI 给的一刻最后切在哪（挪了超过 `reportThreshold` 才报）。
    struct Move: Equatable {
        var asked: Double
        var cutAt: Double
        var why: String
    }

    /// 转写的词（源秒，按时间排）；没转写过是空的。
    let words: [SpeechTranscript.Word]
    /// 量出来的停顿（源秒，至少 `minPause` 长）；读不到声音是 nil。
    let pauses: [ClosedRange<Double>]?
    /// 每一个比门限轻的窗（源秒）：找不到够长的停顿时的退路。
    let quiet: [ClosedRange<Double>]
    /// false = 照给的时间切（AI 传了 snap=false）。只管 AI 给的时间；口头禅、重复词的边永远要挪（`snapping`）。
    var snaps: Bool
    /// 问的时刻是这段声音在时间线上的秒（cut_speech）；nil = 直接问源秒（listen cuts=true）。0.1 秒算不算停顿、最多挪 0.3 秒
    /// 都按声音自己的秒算，变速的片段上两个工具也判得一样。
    var clip: EditClip?

    /// 挪进停顿最多离声音多远（秒）：同转写那一套（`AISpeechCuts.maxShift`）。
    static let reach = AISpeechCuts.maxShift
    /// 多长的安静才算停顿（秒）：比塞音闭口那几十毫秒长，比句子之间的停顿短。
    static let minPause = 0.1
    /// 贴着停顿的边也算在停顿里（秒，约一个电平窗）：listen 报的静音边就是窗的边。
    static let edgeTolerance = 0.05
    /// 挪了超过这么多才报给 AI（秒）。
    static let reportThreshold = 0.05

    /// - Parameters:
    ///   - words: 转写的词（源秒，按时间排）。
    ///   - levels: 这段声音按窗的电平（源秒，`AIAudioLevels.windows`）；读不到声音传 nil。
    ///   - silenceDB: 比它轻的窗算安静。
    ///   - clip: 问的时刻是它在时间线上的秒（cut_speech）；nil = 问源秒。
    init(words: [SpeechTranscript.Word], levels: [AIAudioLevels.Window]?, silenceDB: Double, snaps: Bool = true, clip: EditClip? = nil) {
        self.words = words
        self.snaps = snaps
        self.clip = clip
        guard let levels else {
            pauses = nil
            quiet = []
            return
        }
        pauses = AIAudioLevels.report(levels, silenceDB: silenceDB, minSilence: Self.minPause).silences
        quiet = levels.filter { $0.decibels < silenceDB }.map { $0.start...$0.end }
    }

    /// 同一份数据、永远要挪（口头禅、重复词：它们的边就是转写的词边，照着切一定切到字）。
    var snapping: AISpeechCutPoints {
        var copy = self
        copy.snaps = true
        return copy
    }

    // MARK: 一处切口

    /// `time` 是问的那条轴上的秒（`clip` 给了就是时间线秒），回来的也是。
    func point(_ time: Double, _ side: Side) -> Point {
        guard snaps else { return Point(time: time) }
        let at = source(time)
        if let pauses, pauses.contains(where: { Self.holds($0, at, tolerance: Self.edgeTolerance) }) { return Point(time: time) }
        let proposed = side == .start
            ? AISpeechCuts.startPoint(at, words: words) : AISpeechCuts.endPoint(at, words: words)
        guard let pauses else {
            return proposed == at
                ? Point(time: time) : Point(time: asked(proposed), why: "on a word in the transcript: moved to the gap between words")
        }
        if pauses.contains(where: { Self.holds($0, proposed, tolerance: 0) }) {
            return Point(time: asked(proposed), why: "on speech: moved into the pause between the words")
        }
        let area = searchArea(around: at, proposed: proposed)
        if let pause = Self.nearest(pauses, to: proposed, within: area) {
            return Point(time: asked(place(in: pause, side)), why: "on speech: moved into the pause \(text(pause))")
        }
        if let spot = Self.nearest(quiet, to: proposed, within: area) {
            return Point(time: asked((spot.lowerBound + spot.upperBound) / 2), why: "on speech: moved to the quiet spot between the words")
        }
        return Point(
            time: proposed == at ? time : asked(proposed),
            why: words.isEmpty ? "on speech, no pause within 0.3 s" : "on speech, no pause near it: cut between the words as transcribed",
            onSpeech: true
        )
    }

    /// 问的那条轴上的秒 → 声音的源秒，和反过来（`clip` 是 nil 时两边一样）。
    private func source(_ time: Double) -> Double { clip?.sourceTime(atTimeline: time) ?? time }
    private func asked(_ source: Double) -> Double { clip?.timelineTime(atSource: source) ?? source }

    /// AI 给的一段（要剪掉的或要留下的），两头各切在哪。挪完两头碰到了一起（整段在一个词里，两头挪进了同一个停顿）
    /// 就照给的时间切 —— 不然要留的一段会整个没了、要剪的一段什么都不剪。
    func span(_ range: ClosedRange<Double>) -> (start: Point, end: Point) {
        let start = point(range.lowerBound, .start)
        let end = point(range.upperBound, .end)
        guard end.time <= start.time else { return (start, end) }
        let why = "inside one word: cut at the given times"
        return (Point(time: range.lowerBound, why: why), Point(time: range.upperBound, why: why))
    }

    /// AI 给的这几段的两头，挪了超过 `reportThreshold` 的（按合并时同样对齐到帧之后比），和附近没有停顿、可能切到字的。
    /// 落在片段头尾以外的不报（那里本来就不下刀）。
    func report(_ ranges: [ClosedRange<Double>], clip: ClosedRange<Double>, frame: Double) -> (moved: [Move], onSpeech: [Double]) {
        var moved: [Move] = []
        var onSpeech: [Double] = []
        for range in ranges {
            let (start, end) = span(range)
            for (time, point) in [(range.lowerBound, start), (range.upperBound, end)] {
                guard time > clip.lowerBound + 1e-6, time < clip.upperBound - 1e-6 else { continue }
                let at = AISpeechCuts.onFrame(point.time, frame: frame)
                if abs(at - time) > Self.reportThreshold { moved.append(Move(asked: time, cutAt: at, why: point.why ?? "rounded to a frame")) }
                if point.onSpeech { onSpeech.append(at) }
            }
        }
        return (moved, onSpeech)
    }

    // MARK: 在哪儿找、切在哪

    /// 在哪儿找停顿：转写里这一刀两边的词之间（前一个词的中点到后一个词的中点，不跨过整个词）；没有转写就是前后 `reach`。
    private func searchArea(around time: Double, proposed: Double) -> ClosedRange<Double> {
        guard !words.isEmpty else { return (time - Self.reach)...(time + Self.reach) }
        let middle = { (word: SpeechTranscript.Word) in (word.start + word.end) / 2 }
        let next = words.firstIndex { middle($0) > proposed }
        let lower = next.map { $0 > 0 ? middle(words[$0 - 1]) : proposed - Self.reach } ?? middle(words[words.count - 1])
        let upper = next.map { middle(words[$0]) } ?? proposed + Self.reach
        return min(lower, proposed)...max(upper, proposed)
    }

    /// 停顿里切在哪：段的开头切在停顿中间、但离后面的声音最多 `reach`；段的结尾切在中间、但离前面的声音最多 `reach`。
    private func place(in pause: ClosedRange<Double>, _ side: Side) -> Double {
        let middle = (pause.lowerBound + pause.upperBound) / 2
        switch side {
        case .start: return max(middle, pause.upperBound - Self.reach)
        case .end: return min(middle, pause.lowerBound + Self.reach)
        }
    }

    private static func holds(_ span: ClosedRange<Double>, _ time: Double, tolerance: Double) -> Bool {
        time >= span.lowerBound - tolerance && time <= span.upperBound + tolerance
    }

    /// `spans` 里和 `area` 有交集的、离 `time` 最近的一段（在它里面算 0）。
    private static func nearest(_ spans: [ClosedRange<Double>], to time: Double, within area: ClosedRange<Double>) -> ClosedRange<Double>? {
        let distance = { (span: ClosedRange<Double>) in
            holds(span, time, tolerance: 0) ? 0 : min(abs(span.lowerBound - time), abs(span.upperBound - time))
        }
        return spans.filter { $0.overlaps(area) }.min { distance($0) < distance($1) }
    }

    /// 一段停顿写给 AI 看：换回问的那条轴（cut_speech 的 `moved` 里是时间线秒）。
    private func text(_ span: ClosedRange<Double>) -> String {
        String(format: "%.2f–%.2f s", asked(span.lowerBound), asked(span.upperBound))
    }
}

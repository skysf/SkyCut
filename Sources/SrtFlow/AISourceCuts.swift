import Foundation
import SrtFlowMCPKit

// MARK: - 一段用到的源范围跨没跨过素材自己的刀（纯值）
//
// 管什么：素材文件自己在中间切了一刀（生成的素材常带好几刀，刀前后有时只差几帧），一段片段的入点出点把这一刀包在里面，
// 成片里就夹着另一个镜头的几帧（MCP-36：南极预告片第二稿入点 1.95、出点按整数秒算到 5.45，过了素材第 129 帧那一刀，
// 夹了 2 帧黑轿车）。这里只算、只报，不改入点出点（用户定：只提醒，不自动收）。
// 这段用到的源范围被范围里的刀分成几截（一帧的大半在范围里才算露出来 —— 出点贴着刀差几微秒不算跨），每一截露几帧：
// - `head` / `tail`：头一截 / 末一截不到 `AIFrameScan.shortShot` 帧 —— 夹进来的一小段，建议把入点 / 出点收到刀上；
// - `inside`：两刀之间不到这么多帧的一截 —— 素材自己闪了一下（收入点出点去不掉，换一段范围）；
// - `twoShots`：刀两边都够长 —— 一段里有两个镜头（可能就是想要的）；范围里只有这一刀时建议留长的那一边。
// 刀从哪来：`AIShotDetector.hardCuts`（和成片逐帧扫同一套）；素材怎么扫、缓存（AIShotScan、AISourceCutCheck）。

enum AISourceCuts {
    enum Kind: Equatable { case head, tail, inside, twoShots }

    struct Crossing: Equatable {
        var kind: Kind
        /// 刀后第一帧是素材的第几帧（从 0 数）、在素材的第几秒；`inside` 是那一小截的第一帧。
        var frame: Int
        var time: Double
        /// 刀前那一截、刀后那一截在这段里各露几帧。
        var before: Int
        var after: Int
        /// 范围里只有这一刀。
        var sole: Bool

        /// 夹进来的那一小截露几帧（`head` 是刀前，`tail`、`inside` 是刀后）。
        var shortFrames: Int { kind == .head ? before : after }

        /// 建议改哪一头、改成多少；`inside` 和不止一刀的 `twoShots` 没有。
        var suggestion: (key: String, value: Double)? {
            switch kind {
            case .head: return ("suggested_source_in", time)
            case .tail: return ("suggested_source_out", time)
            case .inside: return nil
            case .twoShots:
                guard sole else { return nil }
                return before >= after ? ("suggested_source_out", time) : ("suggested_source_in", time)
            }
        }
    }

    /// `times`：素材每一帧的时间（源秒）；`cuts`：刀后第一帧的下标（`AIShotDetector.hardCuts`）；`window`：这段用到的源秒。
    static func crossings(window: ClosedRange<Double>, times: [Double], cuts: [Int]) -> [Crossing] {
        guard times.count > 1 else { return [] }
        let frame = medianStep(times)
        // 露出来的帧：这一帧的大半落在范围里。
        let shown = times.indices.filter { index in
            let end = index + 1 < times.count ? times[index + 1] : times[index] + frame
            return min(end, window.upperBound) - max(times[index], window.lowerBound) > frame / 2
        }
        guard let first = shown.first, let last = shown.last else { return [] }
        let inside = cuts.filter { $0 > first && $0 <= last }.sorted()
        guard !inside.isEmpty else { return [] }
        // 几截各露几帧：头一截从 first 起，末一截到 last 止。
        // The shown frames are one contiguous run (the window is a single interval), so a piece's count is the gap between its edges.
        let edges = [first] + inside + [last + 1]
        let pieces = zip(edges, edges.dropFirst()).map { $1 - $0 }
        let short = AIFrameScan.shortShot
        let sole = inside.count == 1
        func crossing(_ kind: Kind, cut index: Int) -> Crossing {
            Crossing(kind: kind, frame: inside[index], time: times[inside[index]], before: pieces[index], after: pieces[index + 1], sole: sole)
        }
        if sole, pieces[0] < short, pieces[1] < short {
            // 一刀、两边都短：收掉更短的那一边。
            return [crossing(pieces[0] <= pieces[1] ? .head : .tail, cut: 0)]
        }
        var result: [Crossing] = []
        for index in inside.indices {
            let isLast = index == inside.count - 1
            if index == 0, pieces[0] < short { result.append(crossing(.head, cut: index)) }
            if pieces[index + 1] < short { result.append(crossing(isLast ? .tail : .inside, cut: index)) }
            if pieces[index] >= short, pieces[index + 1] >= short { result.append(crossing(.twoShots, cut: index)) }
        }
        return result
    }

    /// 写给 AI 的一条（放素材、改入点出点的结果里；成片检查另有说法）。
    static func json(_ crossing: Crossing, clip: EditClip, ids: AIShortIDs) -> JSONValue {
        let frames = crossing.shortFrames
        let why: String
        switch crossing.kind {
        case .head:
            why = "The file itself cuts to this clip's shot at frame \(crossing.frame); the first \(frames) frame(s) of the clip still show the "
                + "shot before it. Nothing was changed."
        case .tail:
            why = "The file itself cuts to another shot at frame \(crossing.frame); the last \(frames) frame(s) of this clip show it. "
                + "Nothing was changed."
        case .inside:
            why = "Inside this clip the file shows a different picture for only \(frames) frame(s) from frame \(crossing.frame) "
                + "(a flash or a glitch in the file). Pick another range if it is not wanted. Nothing was changed."
        case .twoShots:
            why = "The file itself cuts to another shot at frame \(crossing.frame), inside this clip (\(crossing.before) frames before, "
                + "\(crossing.after) after): the clip shows two shots. Keep it if that is wanted. Nothing was changed."
        }
        var object: [String: JSONValue] = [
            "clip": .string(ids.short(clip.id)), "source_cut": AIFormat.seconds(crossing.time),
            "source_frame": .number(Double(crossing.frame)), "at": AIFormat.seconds(clip.timelineTime(atSource: crossing.time)),
            "frames_before_cut": .number(Double(crossing.before)), "frames_after_cut": .number(Double(crossing.after)),
            "why": .string(why)
        ]
        if let suggestion = crossing.suggestion { object[suggestion.key] = AIFormat.seconds(suggestion.value) }
        return .object(object)
    }

    /// 相邻两帧时间差的中位数（不到两帧按 24 帧每秒）。
    static func medianStep(_ times: [Double]) -> Double {
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        return steps.isEmpty ? 1.0 / 24 : steps[steps.count / 2]
    }
}

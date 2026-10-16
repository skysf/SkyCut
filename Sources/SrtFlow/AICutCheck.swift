import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen cuts=true：V1 上每个剪辑点落在不落在停顿里（纯值）
//
// 管什么：测试员（2026-10-16）原来是逐段用 listen 看每个剪辑点前后是不是静音；这里一次把 V1 上每一段的头和尾都看一遍
// （docs/plans/2026-10-16-ai-feedback-line-spacing-and-cut-check.md）：
// - 剪辑点 = V1 每一段的头和尾（`boundaries`）：挨着的两段（不到 `mainGapTolerance` 的缝不算缝，同成片 / 预览）的尾和头合成
//   一个剪辑点报，跨着转场的也合成一个并带上叠了多久，开着缝的各报各的；第一段的头、最后一段的尾也报（成片从哪儿开口、到哪儿收）。
// - 每一头（`side`）在**那段声音自己的源时间轴**上判：声音从哪一段来由调用方定（同 cut_speech：自己有声就是自己，静音了 /
//   声音分离出去了就是链接的那段）；在不在停顿里、挪到哪，判法只有 `AISpeechCutPoints` 一份 —— 先听量出来的停顿，转写只用来
//   认词（docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md）。**在声音上才报切到的词**：转写把停顿后面第一个词的开口
//   故意估早了，在停顿里按词判会冤枉它。
// - 建议的入出点换回这一段 V1 片段自己的源时间（声音从链接的那段来时两条源时间轴可能不一样），AI 直接拿去 edit_clip；
//   落到素材外面的不给。
// 不管什么：波形和转写缓存怎么读、参数（AIListenCuts）；判法本身（AISpeechCutPoints）。

struct AICutCheck {
    /// 一个剪辑点：前一段的尾、后一段的头（至少有一个）。
    struct Boundary: Equatable {
        /// 时间线秒：挨着的两段是接缝；跨着转场的是后一段开始、画面开始叠的那一刻。
        var at: Double
        var outgoing: EditClip? = nil
        var incoming: EditClip? = nil
        /// 跨着的 V1 转场在时间线上叠了多久（秒）；硬切是 nil。
        var transition: Double? = nil
    }

    /// V1 这几段（任意顺序）的剪辑点，按时间排；`from` / `to`（时间线秒）给了只留落在里面的。
    static func boundaries(
        of clips: [EditClip], from: Double? = nil, to: Double? = nil, tolerance: Double = TimelineState.mainGapTolerance
    ) -> [Boundary] {
        let sorted = clips.sorted { $0.timelineStart < $1.timelineStart }
        var result: [Boundary] = []
        for (index, clip) in sorted.enumerated() {
            if index == 0 {
                result.append(Boundary(at: clip.timelineStart, incoming: clip))
            } else {
                let previous = sorted[index - 1]
                if clip.timelineStart <= previous.timelineEnd + tolerance {
                    let overlap = previous.timelineEnd - clip.timelineStart
                    let crossing = previous.transitionAfter != .none && overlap > tolerance
                    result.append(Boundary(at: clip.timelineStart, outgoing: previous, incoming: clip, transition: crossing ? overlap : nil))
                } else {
                    result.append(Boundary(at: previous.timelineEnd, outgoing: previous))
                    result.append(Boundary(at: clip.timelineStart, incoming: clip))
                }
            }
            if index == sorted.count - 1 { result.append(Boundary(at: clip.timelineEnd, outgoing: clip)) }
        }
        return result.filter { boundary in
            (from.map { boundary.at >= $0 - tolerance } ?? true) && (to.map { boundary.at <= $0 + tolerance } ?? true)
        }
    }

    // MARK: 一头

    enum Verdict: Equatable {
        /// 落在量出来的停顿里。
        case inPause
        /// 落在声音上：切到的词（转写缓存里有才有）、为什么这么判（`AISpeechCutPoints.Point.why`）。
        case onSpeech(word: String?, why: String)
        /// 这一头量不了：没声音 / 静音 / 藏起来了 / 波形还没读完。
        case unheard(String)
    }

    /// 一个剪辑点的一头：这一段的头（`.start`）或尾（`.end`）。
    struct Side: Equatable {
        var clipID: UUID
        var end: AISpeechCutPoints.Side
        /// 这一头在时间线上的位置（跨着转场时头和尾不是同一刻）。
        var at: Double
        var verdict: Verdict
        /// 建议切到哪：这一段自己的源时间（入点或出点，edit_clip 直接收）和时间线上的位置；在停顿里、量不了、附近没有停顿时是 nil。
        var suggestedSource: Double? = nil
        var suggestedAt: Double? = nil
    }

    struct Edge: Equatable {
        var at: Double
        var outgoing: Side? = nil
        var incoming: Side? = nil
        var transition: Double? = nil
    }

    /// `clip` 这一头在时间线 `at` 上；声音从 `sound` 来（自己或链接的那段），`points` 是在 `sound` 的源时间轴上建的（要带着量出来的停顿）。
    static func side(of clip: EditClip, end: AISpeechCutPoints.Side, at: Double, sound: EditClip, points: AISpeechCutPoints) -> Side {
        let sourceAt = sound.sourceTime(atTimeline: at)
        let point = points.point(sourceAt, end)
        guard let why = point.why else { return Side(clipID: clip.id, end: end, at: at, verdict: .inPause) }
        var side = Side(clipID: clip.id, end: end, at: at, verdict: .onSpeech(word: word(at: sourceAt, in: points.words), why: why))
        if abs(point.time - sourceAt) > 1e-6 {
            let suggestedAt = sound.timelineTime(atSource: point.time)
            let source = clip.sourceTime(atTimeline: suggestedAt)
            if source >= -1e-6, source <= clip.assetDuration + 1e-6 {
                side.suggestedSource = max(0, source)
                side.suggestedAt = suggestedAt
            }
        }
        return side
    }

    static func unheard(_ clip: EditClip, end: AISpeechCutPoints.Side, at: Double, _ reason: String) -> Side {
        Side(clipID: clip.id, end: end, at: at, verdict: .unheard(reason))
    }

    /// 这一刻切到的词：盖着它的那个；没有就是离它不到 `AISpeechCuts.maxShift` 的最近一个（识别器给的词边和声音差零点几秒，
    /// 「When I」连着说时 42.1 落在转写的两个词之间、声音上却正在说话）。
    static func word(at time: Double, in words: [SpeechTranscript.Word]) -> String? {
        if let covering = words.first(where: { $0.start - 1e-3 <= time && time <= $0.end + 1e-3 }) { return covering.text }
        let distance = { (word: SpeechTranscript.Word) in min(abs(word.start - time), abs(word.end - time)) }
        guard let nearest = words.min(by: { distance($0) < distance($1) }), distance(nearest) <= AISpeechCuts.maxShift else { return nil }
        return nearest.text
    }

    // MARK: 写给 AI 看

    static func json(_ edges: [Edge], ids: AIShortIDs) -> [JSONValue] {
        edges.map { edge in
            var object: [String: JSONValue] = ["at": AIFormat.seconds(edge.at)]
            if let transition = edge.transition { object["transition"] = AIFormat.seconds(transition) }
            if let outgoing = edge.outgoing { object["out"] = .object(json(outgoing, ids: ids)) }
            if let incoming = edge.incoming { object["in"] = .object(json(incoming, ids: ids)) }
            return .object(object)
        }
    }

    static func json(_ side: Side, ids: AIShortIDs) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["clip": .string(ids.short(side.clipID))]
        switch side.verdict {
        case .inPause:
            object["status"] = "in_pause"
        case .onSpeech(let word, let why):
            object["status"] = "on_speech"
            if let word { object["word"] = .string(word) }
            object["why"] = .string(why)
        case .unheard(let reason):
            object["status"] = "unheard"
            object["note"] = .string(reason)
        }
        if let source = side.suggestedSource, let at = side.suggestedAt {
            object[side.end == .start ? "suggested_source_in" : "suggested_source_out"] = AIFormat.seconds(source)
            object["suggested_at"] = AIFormat.seconds(at)
        }
        return object
    }

    /// 有几头切在声音上。
    static func onSpeechCount(_ edges: [Edge]) -> Int {
        edges.flatMap { [$0.outgoing, $0.incoming] }.filter { side in
            if case .onSpeech? = side?.verdict { return true }
            return false
        }.count
    }
}

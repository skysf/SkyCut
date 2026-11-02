import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 成片检查的范围、疑点和纯值规则。只报告，不产生任何编辑计划；媒体读取在 AIInspectionTool/Audio。
enum AIInspection {
    struct Finding {
        var kind: String
        var from: Double
        var to: Double
        var reason: String
        var items: [UUID] = []

        var time: Double { (from + to) / 2 }
        func json(ids: AIShortIDs) -> JSONValue {
            ["kind": .string(kind), "from": AIFormat.seconds(from), "to": AIFormat.seconds(to),
             "at": AIFormat.seconds(time), "reason": .string(reason), "suspected": true,
             "items": .array(items.map { .string(ids.short($0)) })]
        }
    }

    struct Scope {
        var ranges: [ClosedRange<Double>]
        var duration: Double
        func contains(_ time: Double) -> Bool { ranges.contains { $0.contains(time) } }
        func intersects(_ from: Double, _ to: Double) -> Bool {
            ranges.contains { from < $0.upperBound && to > $0.lowerBound }
        }
        var json: JSONValue { .array(ranges.map { [AIFormat.seconds($0.lowerBound), AIFormat.seconds($0.upperBound)] }) }
    }

    static func scope(state: TimelineState, from: Double?, to: Double?) throws -> Scope {
        let duration = state.duration
        guard duration > 0 else { throw AIToolError("The timeline is empty.") }
        if from != nil || to != nil {
            let a = from ?? 0, b = to ?? duration
            guard a >= 0, b > a, b <= duration + 0.001 else {
                throw AIToolError("Use 0 <= from < to <= timeline duration (\(duration) s).")
            }
            return Scope(ranges: [a...min(b, duration)], duration: duration)
        }
        let config = AudioEngineConfig.make(from: state)
        let edges = config.tracks.flatMap(\.segments).flatMap { [$0.start, $0.end] }
        let ranges = edges.map { min(duration, max(0, $0 - 0.75))...min(duration, max(0, $0 + 0.75)) }
            + [max(0, duration - 3)...duration]
        return Scope(ranges: merged(ranges), duration: duration)
    }

    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    /// 结尾和每条范围的两头优先；再每 0.5 秒取一帧。有上限时显式报未取的帧数。
    static func sampleTimes(_ scope: Scope, frame: Double, limit: Int = 120) -> (times: [Double], omitted: Int) {
        var candidates = [scope.duration - frame].filter { scope.contains($0) }
        for range in scope.ranges {
            candidates += [range.lowerBound, min(range.upperBound, scope.duration - frame), (range.lowerBound + range.upperBound) / 2]
        }
        for range in scope.ranges {
            candidates += stride(from: range.lowerBound, through: range.upperBound, by: 0.5)
        }
        var seen: Set<Int> = []
        let unique = candidates.map { min(max(0, $0), max(0, scope.duration - frame)) }.filter {
            seen.insert(Int(($0 / frame).rounded())).inserted
        }
        return (Array(unique.prefix(limit)).sorted(), max(0, unique.count - limit))
    }

    static func silence(_ windows: [AIAudioLevels.Window], scope: Scope, db: Double, minimum: Double) -> [Finding] {
        scope.ranges.flatMap { range in
            let part = windows.compactMap { w -> AIAudioLevels.Window? in
                let a = max(w.start, range.lowerBound), b = min(w.end, range.upperBound)
                return b > a ? .init(start: a, end: b, meanSquare: w.meanSquare, peak: w.peak) : nil
            }
            return AIAudioLevels.report(part, silenceDB: db, minSilence: minimum).silences.map {
                Finding(kind: "audio_silence", from: $0.lowerBound, to: $0.upperBound,
                        reason: "Mixed output stays below \(db) dBFS for at least \(minimum) s; review whether this pause is intentional.")
            }
        }
    }

    static func overlaps(_ config: AudioEngineConfig, scope: Scope) -> [Finding] {
        let segments = config.tracks.flatMap { track in track.segments.map { (track.name, track.fader, $0) } }
        var result: [Finding] = []
        guard config.master > 0 else { return [] }
        for i in segments.indices {
            for j in segments.indices where j > i {
                let a = segments[i], b = segments[j]
                guard a.1 > 0, b.1 > 0, a.0 == b.0 || a.2.url == b.2.url else { continue }
                let start = max(a.2.start, b.2.start), end = min(a.2.end, b.2.end)
                guard end - start > 0.1, scope.intersects(start, end) else { continue }
                let mid = (start + end) / 2
                // 原生主轨交叉淡变是明确安排过的，互补斜坡不作为重叠疑点。
                let ga = a.2.gain.gain(at: mid), gb = b.2.gain.gain(at: mid)
                guard ga > 0.05, gb > 0.05, a.0 != "main" || ga + gb > 1.05 else { continue }
                result.append(Finding(kind: "audio_overlap", from: start, to: end,
                                      reason: "Concurrent audio on \(a.0)/\(b.0) (same lane or repeated source); may be an intended mix.",
                                      items: [a.2.clipID, b.2.clipID]))
            }
        }
        return result
    }

    static func subtitles(_ state: TimelineState, style: BurnInStyle, scope: Scope) -> [Finding] {
        let blocks = state.subtitleScreenBlocks()
        let canvas = VideoEditCompositionBuilder.renderSize(for: state)
        let boxes = AISubtitleBoxes.boxes(in: blocks, style: style, canvas: canvas)
        let cues = blocks.flatMap { $0.layers.flatMap { $0 } }
        var result: [Finding] = []
        for cue in cues {
            // 查到片尾时也要查完全落在片尾之后的句子；这种句子不会与任何有效画面范围相交。
            let beyondEnding = scope.contains(scope.duration) && cue.end > scope.duration
            let beforeOpening = scope.contains(0) && cue.start < 0
            guard scope.intersects(cue.start, cue.end) || scope.contains(cue.start) || beyondEnding || beforeOpening else { continue }
            if cue.start < 0 || cue.end > scope.duration + 0.001 || cue.end <= cue.start {
                result.append(Finding(kind: "subtitle_time_bounds", from: cue.start, to: cue.end,
                                      reason: "Visible subtitle timing lies outside the video or has no positive duration.", items: [cue.id]))
            }
            if let rect = boxes[cue.id]?.rect,
               rect.minX < -0.002 || rect.minY < -0.002 || rect.maxX > 1.002 || rect.maxY > 1.002 {
                result.append(Finding(kind: "subtitle_bounds", from: cue.start, to: cue.end,
                                      reason: "Subtitle ink extends outside the canvas with this project's font, size, wrapping and layout.", items: [cue.id]))
            }
        }
        for i in cues.indices {
            for j in cues.indices where j > i {
                let a = cues[i], b = cues[j]
                let from = max(a.start, b.start), to = min(a.end, b.end)
                guard to - from > 0.001, scope.intersects(from, to) else { continue }
                let sameTrack = state.subtitleTrack(of: a.id) == state.subtitleTrack(of: b.id)
                // 原生双语叠排会自动让开，不能把它当作两个独立拖框的碰撞。
                if !sameTrack, blocks.contains(where: { block in
                    block.isStacked && block.layers.flatMap { $0 }.contains(where: { $0.id == a.id })
                        && block.layers.flatMap { $0 }.contains(where: { $0.id == b.id })
                }) { continue }
                let collision = boxes[a.id].flatMap { ar in boxes[b.id].map { ar.rect.intersection($0.rect) } }
                if sameTrack || collision.map({ !$0.isNull && $0.width > 0.002 && $0.height > 0.002 }) == true {
                    result.append(Finding(kind: "subtitle_overlap", from: from, to: to,
                                          reason: sameTrack ? "Two visible lines on one subtitle track overlap in time."
                                            : "Separately placed subtitle tracks intersect with the current style; review the composed frame.",
                                          items: [a.id, b.id]))
                }
            }
        }
        return result
    }

    static func isBlack(_ luma: AIBlackBars.Luma) -> Bool {
        guard !luma.pixels.isEmpty else { return false }
        return Double(luma.pixels.filter { $0 <= 16 }.count) / Double(luma.pixels.count) > 0.995
    }

    /// 证据先给结尾，再按疑点出现顺序；避免开头几个切口用光名额，结尾反而没法复核。
    static func evidence(_ findings: [Finding], duration: Double) -> [Finding] {
        findings.enumerated().sorted {
            let a = $0.element.time >= duration - 3, b = $1.element.time >= duration - 3
            return a == b ? $0.offset < $1.offset : a
        }.map(\.element)
    }
}

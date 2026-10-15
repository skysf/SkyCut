import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 字幕撞没撞上画面里固定的字、烧进去的旧字幕（纯值）
//
// 管什么：look text_scan 看时间线上的一段时，这一段期间显示的工程字幕（看得见的两条轨，每句的框按 `AISubtitleBoxes`）
// 和画面里固定的字 / 字幕带换到画布上的框（`AICoverBox.canvasRect`）求交，相交的报出来：哪一句、和什么撞上、这句的框。
// 2026-10-15 用户转来的反馈：三行字幕碰到左下角的台标，AI 只能一帧一帧 look 才发现。
// 不管什么：固定的字怎么认（AITextRegions）、框怎么换到画布（AICoverBox）、每句的框怎么算（AISubtitleBoxes）。

enum AISubtitleOverlaps {
    /// 画面里的一样东西（水印、台标、旧字幕带）在画布上占的几处。
    struct Mark: Equatable {
        var name: String
        var rects: [CGRect]
    }

    struct Overlap: Equatable {
        var cueID: UUID
        var track: SubtitleTrack
        var text: String
        var box: CGRect
        var marks: [String]
    }

    /// 最多报这么多句（都撞上了再多也没用，先改样式）。
    static let maxReported = 40

    /// 每句和哪几样撞上了；一样都没撞的不出现。
    static func find(marks: [Mark], boxes: [UUID: SubtitleLineBox], cues: [(cue: SubtitleCue, track: SubtitleTrack)]) -> [Overlap] {
        var result: [Overlap] = []
        for (cue, track) in cues {
            guard let box = boxes[cue.id] else { continue }
            let hit = marks.filter { mark in mark.rects.contains { meets($0, box.rect) } }.map(\.name)
            if !hit.isEmpty { result.append(Overlap(cueID: cue.id, track: track, text: cue.text, box: box.rect, marks: hit)) }
        }
        return result
    }

    /// 相交到看得出来才算：交集的宽和高都超过画面的 0.5%（描边那一圈擦过去不算撞）。
    static func meets(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 0.005 && shared.height > 0.005
    }

    /// 给 text_scan 的结果（`AITextRegions.json` 出的那份，`AICoverBox.annotate` 之后）补上：这一段期间显示的工程字幕里，
    /// 哪几句撞上了固定的字 / 旧字幕带。画面里什么都没认出来、或者这段时间里没有字幕，就什么都不加。
    static func annotate(
        _ payload: inout [String: JSONValue], report: AITextRegions.Report, clip: EditClip, state: TimelineState,
        style: BurnInStyle, canvas: CGSize, ids: AIShortIDs
    ) {
        var marks: [Mark] = report.fixed.map { mark in
            Mark(name: mark.text, rects: ([mark.box] + mark.places).compactMap { AICoverBox.canvasRect(of: $0, on: clip, canvas: canvas) })
        }
        if let band = report.band, let rect = AICoverBox.canvasRect(of: AICoverBox.bandSource(band.box), on: clip, canvas: canvas) {
            marks.append(Mark(name: "burned-in subtitles", rects: [rect]))
        }
        marks.removeAll { $0.rects.isEmpty }
        guard !marks.isEmpty else { return }
        let range = clip.timelineStart...clip.timelineEnd
        let blocks = state.subtitleScreenBlocks()
        let cues = blocks.flatMap { block in
            zip(block.tracks, block.layers).flatMap { track, layer in
                layer.filter { $0.end > range.lowerBound && $0.start < range.upperBound }.map { (cue: $0, track: track) }
            }
        }
        guard !cues.isEmpty else { return }
        let boxes = AISubtitleBoxes.boxes(in: blocks, style: style, canvas: canvas, within: range)
        let overlaps = find(marks: marks, boxes: boxes, cues: cues)
        payload["subtitles_checked"] = .number(Double(cues.count))
        payload["subtitle_overlaps"] = .array(overlaps.prefix(maxReported).map { overlap in
            .object([
                "id": .string(ids.short(overlap.cueID)),
                "track": .string(overlap.track.rawValue),
                "text": .string(String(overlap.text.prefix(80))),
                "box": AIFrameDescription.box(overlap.box),
                "overlaps": .array(overlap.marks.map { .string($0) })
            ])
        })
        if overlaps.count > maxReported { payload["subtitle_overlaps_truncated"] = .number(Double(overlaps.count - maxReported)) }
        payload["subtitle_overlaps_hint"] = .string(
            overlaps.isEmpty
                ? "The project's subtitle lines shown during this clip stay clear of the text found in the picture (boxes assume the current subtitle style)."
                : "These project subtitle lines are drawn over text in the picture (box = the line as drawn with the current style, fractions of the canvas). "
                    + "Shorten or re-split them (edit_subtitles), narrow style.max_width or move the subtitles (style.position / margin), "
                    + "or cover the mark (set_shape kind=blur with the cover values). Then look at the timeline to check."
        )
    }
}

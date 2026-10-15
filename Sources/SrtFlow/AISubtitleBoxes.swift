import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 每一句看得见的字幕在画布上占的框（纯值）
//
// 管什么：从画面上排好的几块（`SubtitleScreenBlock`，预览和烧录同一份）算出每一句的框（`SubtitleLineBoxes`）：
// 按这句显示时整块的样子算（这句的中点那一刻）；叠在一起的两条轨 —— 原文在上、译文在下 —— 整块的上下沿按两句合起来的字算，
// 每句的框是整块里属于它的那一截（左右按它自己那几行的宽）。藏起来的句子、关着眼睛的轨不在块里，就没有框。
// get_subtitles 每句报它、look text_scan 拿它和画面里的字求交（`AISubtitleOverlaps`）。
// 不管什么：一句字怎么量（SubtitleLineBoxes）、块怎么排（TimelineState.subtitleScreenBlocks）。

enum AISubtitleBoxes {
    /// 每一句的框；`within` 给了就只算和这段时间有交集的句子。
    static func boxes(
        in blocks: [SubtitleScreenBlock], style: BurnInStyle, canvas: CGSize, within range: ClosedRange<Double>? = nil
    ) -> [UUID: SubtitleLineBox] {
        var result: [UUID: SubtitleLineBox] = [:]
        for block in blocks {
            for (index, track) in block.tracks.enumerated() {
                for cue in block.layers[index] where range.map({ cue.end > $0.lowerBound && cue.start < $0.upperBound }) ?? true {
                    if let box = box(of: cue, track: track, in: block, style: style, canvas: canvas) { result[cue.id] = box }
                }
            }
        }
        return result
    }

    /// 这一句（在这一块的 `track` 上）的框；不在这一块里（藏着、轨关着）就是 nil。
    static func box(
        of cue: SubtitleCue, track: SubtitleTrack, in block: SubtitleScreenBlock, style: BurnInStyle, canvas: CGSize
    ) -> SubtitleLineBox? {
        guard let index = block.tracks.firstIndex(of: track), block.layers[index].contains(where: { $0.id == cue.id }) else { return nil }
        let time = (cue.start + cue.end) / 2
        guard let whole = block.text(at: time), let own = block.text(of: track, at: time),
              let wholeBox = SubtitleLineBoxes.box(for: whole, style: style, layout: block.layout, canvas: canvas),
              let ownBox = SubtitleLineBoxes.box(for: own, style: style, layout: block.layout, canvas: canvas)
        else { return nil }
        // 这一刻只有这条轨有字（或者本来就不叠）：整块就是它。
        guard block.isStacked, whole != own else { return ownBox }
        var rect = ownBox.rect
        rect.size.height = min(ownBox.rect.height, wholeBox.rect.height)
        rect.origin.y = track == .original ? wholeBox.rect.minY : wholeBox.rect.maxY - rect.height
        return SubtitleLineBox(rect: rect, lineCount: ownBox.lineCount)
    }
}

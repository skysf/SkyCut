import Foundation
import SrtFlowMCPKit

// MARK: - 片段输入的共同校验（纯值）
// 单项 / 批量 / 同步旁白共用 AIClipEdit；这里只判请求能不能做，不提交、不自动放宽生产限制。
enum AIClipParameters {
    static func validate(_ change: AIClipChange) throws {
        try AIEditLimits.nonnegative("start", change.start)
        try AIEditLimits.require("speed", change.speed, in: TimelineTrim.clipSpeedRange)
        for (field, number) in [("volume_db", change.volumeDB), ("source_in", change.sourceIn), ("source_out", change.sourceOut),
                                ("fade_in", change.fadeIn), ("fade_out", change.fadeOut)] {
            if let number, !number.isFinite { throw AIEditLimits.invalid(field, number) }
        }
    }
}

/// 视频 / 声音 / 图片的同一份源窗口规则，add_clips 和 edit_clip 不再各算一份限幅与最短长度。
struct AIClipSourceWindow {
    let start: Double
    let duration: Double

    static func resolve(
        sourceIn: Double?, sourceOut: Double?, oldIn: Double, oldOut: Double,
        assetDuration: Double, isImage: Bool, stillDuration: Double
    ) throws -> Self {
        let rawIn = sourceIn ?? oldIn
        let rawOut = sourceOut ?? oldOut
        guard rawIn.isFinite else { throw AIEditLimits.invalid("source_in", rawIn, minimum: 0) }
        guard rawOut.isFinite else { throw AIEditLimits.invalid("source_out", rawOut, minimum: 0) }
        let minimum = TimelineTrim.clipMinimumDuration
        if isImage {
            try AIEditLimits.nonnegative("source_in", rawIn)
            let length = rawOut - rawIn
            guard length >= minimum - 1e-9, length <= stillDuration + 1e-9 else {
                throw AIEditLimits.invalid("source_out", rawOut, minimum: rawIn + minimum, maximum: rawIn + stillDuration)
            }
            return Self(start: 0, duration: min(max(length, minimum), stillDuration))
        }
        var start = rawIn
        var end = rawOut
        guard assetDuration >= minimum else {
            throw AIEditLimits.invalid("source_out", rawOut, minimum: minimum, maximum: assetDuration)
        }
        if start < 0, start > -AIClipEdit.tolerance { start = 0 }
        if end > assetDuration, end - assetDuration < AIClipEdit.tolerance { end = assetDuration }
        let lastIn = assetDuration - minimum
        if start > lastIn, start - lastIn < 1e-9 { start = lastIn }
        guard start >= 0, start <= lastIn else {
            throw AIEditLimits.invalid("source_in", rawIn, minimum: 0, maximum: min(assetDuration, end) - minimum)
        }
        guard end >= start + minimum - 1e-9, end <= assetDuration else {
            throw AIEditLimits.invalid("source_out", rawOut, minimum: start + minimum, maximum: assetDuration)
        }
        return Self(start: start, duration: max(minimum, end - start))
    }
}

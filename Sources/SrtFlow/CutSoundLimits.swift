import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 声音怎么过一刀：最多几帧、在哪量（纯值）
//
// 管什么：一种过法要的帧数做不做得到 —— 声音的余料（文件里切点那一边还剩多少）、不伸过隔壁那个镜头 —— 做不到就整个不做，
// 照实回「最多 N 帧」和为什么（同 docs/architecture/mcp-edit-parameters.md 的 invalid_parameter：requested / allowed / suggested），
// 绝不悄悄改小；on_beat 附近没有能落的拍子怎么说；调增益 / 垫底在哪几毫秒量电平。
// 不管什么：怎么改（CutSoundPlanner）、真去读声音（CutSoundMeasure）。

/// 一条上限：最多几帧、为什么。
struct CutSoundLimit: Equatable {
    var frames: Int
    var reason: String
}

enum CutSoundLimits {
    /// 上一个镜头的声音能拖过切点几帧：文件在切点之后还剩多少。
    static func after(_ sound: EditClip, _ picture: EditClip, at time: Double, _ rate: ProjectFrameRate) -> CutSoundLimit {
        let room = CutSoundFrames.whole(CutSoundEdges.roomAfter(sound, at: time), rate)
        return CutSoundLimit(frames: room, reason: "the sound of \(picture.name) ends \(room) frames after the cut (its file has no more)")
    }

    /// 下一个镜头的声音能提前几帧：文件在切点之前还有多少。
    static func before(_ sound: EditClip, _ picture: EditClip, at time: Double, _ rate: ProjectFrameRate) -> CutSoundLimit {
        let room = CutSoundFrames.whole(CutSoundEdges.roomBefore(sound, at: time), rate)
        return CutSoundLimit(frames: room, reason: "the sound of \(picture.name) has only \(room) frames before the cut in its file")
    }

    /// 声音不伸过隔壁那个镜头：下一个镜头（拖后、叠）/ 上一个镜头（先进、叠）有多长。
    static func shot(_ side: CutSoundPlanner.Side, _ cut: CutSoundCut, _ rate: ProjectFrameRate) -> CutSoundLimit {
        let picture = side == .incoming ? cut.incoming : cut.outgoing
        let length = CutSoundFrames.whole(side == .incoming ? picture.timelineEnd - cut.time : cut.time - picture.timelineStart, rate)
        return CutSoundLimit(frames: length, reason: "\(picture.name) is only \(length) frames long \(side == .incoming ? "after" : "before") the cut")
    }

    /// 一段声音能伸到 [earliest, latest] 里（文件的头尾）：从切点往前 / 往后各最多几帧，外加不早于时间线的开头。
    static func reach(_ clip: EditClip, around time: Double, _ rate: ProjectFrameRate) -> [CutSoundLimit] {
        let before = CutSoundFrames.whole(time - (clip.timelineStart - CutSoundEdges.roomBefore(clip, at: clip.timelineStart)), rate)
        let after = CutSoundFrames.whole(clip.timelineEnd + CutSoundEdges.roomAfter(clip, at: clip.timelineEnd) - time, rate)
        let start = CutSoundFrames.whole(time, rate)
        return [
            CutSoundLimit(frames: before, reason: "\(clip.name)'s file reaches only \(before) frames before the cut"),
            CutSoundLimit(frames: after, reason: "\(clip.name)'s file reaches only \(after) frames after the cut"),
            CutSoundLimit(frames: start, reason: "the cut is only \(start) frames from the start of the timeline")
        ]
    }

    /// 要的帧数比最紧的那条上限多就不做：结构化的 invalid_parameter（parameter = frames），建议用那条上限。
    static func check(_ frames: Int, _ mode: CutSoundMode, _ limits: [CutSoundLimit]) throws {
        guard let tightest = limits.min(by: { $0.frames < $1.frames }), frames > tightest.frames else { return }
        var details: [String: JSONValue] = [
            "status": "invalid_parameter", "parameter": "frames", "requested": .number(Double(frames)),
            "allowed": ["minimum": .number(Double(mode.minimumFrames)), "maximum": .number(Double(tightest.frames))],
            "retryable": false, "reason": .string(tightest.reason)
        ]
        let advice: String
        if tightest.frames >= mode.minimumFrames {
            details["suggested"] = .number(Double(tightest.frames))
            advice = "Use frames \(tightest.frames) or fewer."
        } else {
            advice = "There is nothing to work with on that side: try the other side (lead / lag), a bed, or a gain change."
            details["suggestion"] = .string(advice)
        }
        throw AIToolError(
            "Not enough for \(mode.rawValue) \(frames) frames: \(tightest.reason). \(advice) Nothing was changed.", details: details
        )
    }

    /// on_beat 在 ±window 帧里没有能落的拍子。`nearest`：最近的一拍离切点几帧（没有拍子是 nil）；`blocked`：窗里有拍子，
    /// 只是挪过去余料不够或者会把一边裁没。
    static func noBeat(window: Int, nearest: Int?, blocked: Bool) -> AIToolError {
        if blocked {
            return AIToolError(
                "The beats within \(window) frames of the cut cannot take the sound switch: one side's sound has no footage there "
                    + "or would be cut away. Nothing was changed; try lead, lag or crossfade."
            )
        }
        guard let nearest else {
            return AIToolError("No beat was found in the music near this cut. Nothing was changed; pass layer_id for another music clip.")
        }
        var details: [String: JSONValue] = [
            "status": "invalid_parameter", "parameter": "frames", "requested": .number(Double(window)),
            "allowed": ["minimum": 0, "maximum": .number(Double(CutSoundRequest.maximumFrames))], "retryable": false
        ]
        if abs(nearest) <= CutSoundRequest.maximumFrames { details["suggested"] = .number(Double(abs(nearest))) }
        return AIToolError(
            "No beat within \(window) frames of the cut; the nearest is \(nearest) frames away. Pass frames \(abs(nearest)) to "
                + "reach it, or use another join. Nothing was changed.", details: details
        )
    }

}

/// 在哪几毫秒量电平（同真人南极正片和预览板的量法，joins-human.md）：切点前后各 0.3 秒、躲开切点上那一帧左右的 0.02 秒；
/// 底在切点两边各 0.3 秒一起量。
enum CutSoundWindows {
    static let span = 0.3
    static let gap = 0.02
    /// 窗的中点离切点多远（量增益、读段的音量线都在这一刻）。
    static var middle: Double { gap + span / 2 }

    static func outgoing(_ time: Double) -> (from: Double, to: Double) { (time - gap - span, time - gap) }
    static func incoming(_ time: Double) -> (from: Double, to: Double) { (time + gap, time + gap + span) }
    static func layer(_ time: Double) -> (from: Double, to: Double) { (time - span, time + span) }
}

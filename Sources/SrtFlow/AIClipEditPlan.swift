import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 准备好的一次片段编辑（纯值）
//
// 管什么：单项 / 批量共用的候选时间线计算、重叠错误和结果反馈（含取景发现、关键帧与换源提示）。
// 不管什么：异步探测（AIClipTools.plan）、真正提交、撤销和选择。

struct AIClipEditPlan {
    let id: UUID
    var change: AIClipChange
    /// 算取景时的画布；提交前变了就不套用旧几何。
    let canvas: CGSize
    var findings: [String: JSONValue] = [:]
    var requestedRegion: CGRect?
    var requestedParameters: JSONValue = [:]
    var expectedClip: EditClip?

    func applying(
        to state: TimelineState, linkage: Bool, stillDuration: Double, canvas: CGSize, checksOverlap: Bool = true
    ) throws -> TimelineState {
        let ids = AIShortIDs(state: state)
        if let expectedClip, state.clip(with: id) != expectedClip {
            throw AIToolError("The clip changed while SkyCut was loading its metadata. Nothing was applied; get_timeline and retry.",
                              details: ["status": "stale_edit", "retryable": true])
        }
        if change.framing != nil, canvas != self.canvas {
            throw AIToolError("The frame shape changed while SkyCut was looking at the clip. Call edit_clip again.")
        }
        let next: TimelineState
        do {
            next = try AIClipEdit.apply(
                change, to: id, linkage: linkage,
                stillDuration: stillDuration, in: state, checksOverlap: checksOverlap
            )
        } catch let conflict as AIClipEdit.Conflict {
            let other = conflict.other
            throw AIToolError("""
                That would overlap "\(other.name)" (\(ids.short(other.id)), \(String(format: "%.2f", other.timelineStart))–\
                \(String(format: "%.2f", other.timelineEnd)) s) on \(AITrackName.name(of: conflict.track)). \
                Move or trim that clip first, choose another start or track, or use ripple on V1.
                """)
        }
        return next
    }

    func summary(old: EditClip?, in fresh: TimelineState, context: AITimelineSummary.Context) -> [String: JSONValue] {
        guard let clip = fresh.clip(with: id), let location = fresh.location(of: id) else {
            return ["changed": .string(context.ids.short(id))]
        }
        var summary = AITimelineSummary.clip(clip, next: nil, context, frameRate: fresh.frameRate).objectValue ?? [:]
        summary["track"] = .string(AITrackName.name(of: location.track))
        if !clip.isAudioOnly, change.framing != nil {
            summary["picture"] = AITimelineSummary.picture(clip, canvas: context.renderSize, always: true)
        }
        for (key, value) in findings { summary[key] = value }
        if let requestedRegion {
            summary["framing"] = AIRegionFraming.summary(clip, canvas: context.renderSize, requested: requestedRegion)
        }
        for (key, value) in AIParameterReport.clip(requested: requestedParameters, old: old, clip: clip, state: fresh, canvas: context.renderSize) {
            summary[key] = value
        }
        if let old,
           let note = AIKeyframes.editNote(policy: change.keyframes ?? .keepFrames, old: old, new: clip, frameRate: fresh.frameRate) {
            summary["keyframes_note"] = .string(note)
        }
        if change.replacement != nil, let old,
           let note = ClipFileReplacement.aspectNote(old: old, new: clip) {
            summary["picture_note"] = .string(note)
        }
        return summary
    }
}

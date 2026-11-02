import Foundation
import SrtFlowMCPKit

// MARK: - 工具：edit_clips / set_texts / set_shapes
//
// 管什么：整批准备并校验 → 同步提交一次 → 选中整批一次 → 按输入顺序回最终状态。
// 片段的 await 全在 planClips 里；期间用户改了时间线、换了工程或联动开关就拒绝旧计划。
// 不管什么：编辑规则和反馈（复用 AIClipTools / AIOverlayTools），事务与撤销分组（AIBatchEdit）。

@MainActor
enum AIBatchEditTools {
    struct ClipsPlan {
        var batch: AIClipBatch
        let generation: Int
        let linkage: Bool
    }

    static func planClips(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> ClipsPlan {
        let items = try AIBatchItems.read(args, key: "clips", tool: .editClips)
        var plan = ClipsPlan(batch: AIClipBatch(project.state), generation: project.documentGeneration, linkage: project.linkageEnabled)
        for (index, item) in items.enumerated() {
            do {
                try Task.checkCancellation()
                let edit = try await AIClipTools.plan(item, project, state: plan.batch.edit.next)
                try plan.batch.append(
                    edit, linkage: plan.linkage, stillDuration: StillImageClipFactory.stillDuration,
                    canvas: VideoEditCompositionBuilder.renderSize(for: plan.batch.edit.next)
                )
            } catch { throw AIBatchItems.failure(error, key: "clips", index: index) }
        }
        try Task.checkCancellation()
        return plan
    }

    static func applyClips(_ plan: ClipsPlan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation), project.linkageEnabled == plan.linkage else {
            throw AIToolError("The project or Linkage changed while SkyCut was preparing this batch. Nothing was applied; get_timeline and retry.")
        }
        let report = try commit(plan.batch.edit, project, rebuildsPreview: true)
        let ids = Set(plan.batch.entries.map { $0.plan.id })
        let time = project.state.allClips.filter { ids.contains($0.id) }.map(\.timelineStart).min()
        AIEditorPresenter.reveal(.init(clips: ids, time: time), project: project)
        let results = plan.batch.entries.map { JSONValue.object(AIClipTools.summary($0.plan, old: $0.old, project)) }
        return result("clips", results, edit: plan.batch.edit, report: report, project)
    }

    static func setTexts(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let plan = try AITextBatch(args, state: project.state, playhead: project.clock.time)
        let report = try commit(plan.edit, project, rebuildsPreview: false)
        let ids = Set(plan.entries.map(\.id))
        let time = project.state.textOverlays.filter { ids.contains($0.id) }
            .map { $0.timelineStart + min(0.5, $0.duration / 2) }.min()
        AIEditorPresenter.reveal(.init(texts: ids, time: time), project: project)
        return result("texts", plan.entries.map { AIOverlayTools.textSummary($0, project) }, edit: plan.edit, report: report, project)
    }

    static func setShapes(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let plan = try AIShapeBatch(args, state: project.state, playhead: project.clock.time)
        let report = try commit(plan.edit, project, rebuildsPreview: false)
        let ids = Set(plan.ids)
        let time = project.state.shapes.filter { ids.contains($0.id) }
            .map { $0.timelineStart + min(0.5, $0.duration / 2) }.min()
        AIEditorPresenter.reveal(.init(shapes: ids, time: time), project: project)
        let results = plan.ids.enumerated().compactMap { index, id in
            project.state.shapes.first { $0.id == id }.map { AIOverlayTools.shapeSummary($0, parameters: plan.parameters[index], project) }
        }
        return result("shapes", results, edit: plan.edit, report: report, project)
    }

    /// 唯一提交点：普通批量交给 perform 收尾；完整显式映射已结算落点，原样采用，不二次联动。
    static func commit(
        _ edit: AIBatchEdit, _ project: VideoEditProject, rebuildsPreview: Bool, alreadySettled: Bool = false
    ) throws -> TimelineLinkage.Report {
        try edit.commit(current: project.state, undo: project.effectiveUndoManager) { next in
            // 显式段落映射已经算完所有落点；和撤销快照共用原样采用的路径，不再磁吸 / 联动一次。
            if alreadySettled {
                project.restoreTimeline(next)
                return TimelineLinkage.Report()
            }
            return project.perform(rebuildsPreview: rebuildsPreview) { $0 = next }
        }
    }

    private static func result(
        _ key: String, _ entries: [JSONValue], edit: AIBatchEdit, report: TimelineLinkage.Report, _ project: VideoEditProject
    ) -> AIToolResult {
        var payload: [String: JSONValue] = [key: .array(entries), "count": .number(Double(entries.count))]
        if !edit.changed { payload["unchanged"] = true }
        if let followed = AILinkageReport.json(report, ids: AIShortIDs(state: project.state)) { payload["linkage"] = followed }
        if let packed = AILinkageReport.magnet(report) { payload["magnet"] = packed }
        return .ok(.object(payload), changed: edit.changed)
    }
}

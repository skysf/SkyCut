import Foundation
import SrtFlowMCPKit

// MARK: - 工具：set_transition 的 sound（声音怎么过一刀，2026-11-16 MCP-32）
//
// 管什么：参数 → 哪种过法、几帧、增益、哪一层；哪一刀（after_clip_id，或 all=true 的 V1 每一刀）；`plan` 可以 await（量电平、找拍子，
// CutSoundMeasure），`apply` 同步落到时间线上（路由包 `AIUndoGrouping.step`，同 cut_to_beat：一个工具 = 一步撤销）。
// 中途时间线变了就不落，请 AI 重来。几刀一次做：有一刀做不到整个不做（CutSoundPlanner.run）；all=true 时没有声音的那几刀跳过、报出来。
// 不管什么：画面的转场（type，AITimelineTools.transition，不和 sound 同一次）、怎么改（CutSoundPlanner 等纯值）、说明文字
// （SrtFlowMCPKit/MCPTimelineTools.swift、说明书 MCPGuideCutSound）。规矩见 docs/architecture/cut-sound.md。

@MainActor
enum AICutSoundTool {
    struct Plan {
        var request: CutSoundRequest
        var cuts: [CutSoundCut]
        var inputs: [CutSoundPlanner.Inputs]
        var all: Bool
        var state: TimelineState
        var generation: Int
    }

    static func plan(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> Plan {
        let state = project.state
        let request = try CutSoundRequest.read(args, state)
        let all = try args.bool("all") ?? false
        let cuts = try targets(args, all: all, state)
        var inputs: [CutSoundPlanner.Inputs] = []
        for cut in cuts {
            var input = CutSoundPlanner.Inputs()
            input.layer = try CutSoundCut.layer(for: request, at: cut, in: state)
            if request.mode == .bed || (request.mode == .gain && request.gainDB == nil) {
                input.material = try await CutSoundMeasure.material(cut, layer: input.layer, in: state)
            }
            if request.mode == .onBeat, let music = input.layer {
                input.beats = try await CutSoundMeasure.beats(of: music)
            }
            inputs.append(input)
        }
        return Plan(request: request, cuts: cuts, inputs: inputs, all: all, state: state, generation: project.documentGeneration)
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation), project.state == plan.state else {
            throw AIToolError("The timeline changed while SkyCut was listening to the cut. Call set_transition again.")
        }
        var next = plan.state
        let done = try CutSoundPlanner.run(plan.request, cuts: plan.cuts, inputs: plan.inputs, skipsSilent: plan.all, in: &next)
        let linkage = project.perform { $0 = next }
        let ids = AIShortIDs(state: project.state)
        guard case .object(var result) = CutSoundReport.json(done.outcomes, in: project.state, ids: ids) else {
            return .ok(.object([:]), changed: true)
        }
        if !done.skipped.isEmpty { result["skipped_no_sound"] = .array(done.skipped.map { .string(ids.short($0)) }) }
        if let followed = AILinkageReport.json(linkage, ids: ids) { result["linkage"] = followed }
        if let packed = AILinkageReport.magnet(linkage) { result["magnet"] = packed }
        let sounds = Set(done.outcomes.flatMap { [$0.outgoing, $0.incoming, $0.bed?.clip].compactMap { $0 } })
        AIEditorPresenter.reveal(.init(clips: sounds, time: done.outcomes.first.map { max(0, $0.cut.time - 1) }), project: project)
        return .ok(.object(result), changed: true)
    }

    private static func targets(_ args: AIToolArguments, all: Bool, _ state: TimelineState) throws -> [CutSoundCut] {
        if all {
            let cuts = CutSoundCut.everyMainCut(in: state)
            guard !cuts.isEmpty else { throw AIToolError("No two V1 clips touch, so there is no cut to join the sound across.") }
            return cuts
        }
        guard let text = try args.string("after_clip_id") else { throw AIToolError("Pass after_clip_id, or all=true.") }
        return [try CutSoundCut.after(try AIShortIDs(state: state).resolve(text), in: state)]
    }
}

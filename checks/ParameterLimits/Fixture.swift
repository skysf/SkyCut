import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 独立真实工程，复用生产计划 / 提交 / 素材探测，不注入假元数据状态。
@MainActor final class ParameterFixture {
    let project: VideoEditProject
    let before: TimelineState
    let id: UUID

    init(folder: URL, source: URL, info: MediaInfo) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project = OpenProjects.shared.primary
        project.newProject()
        project.documentURL = folder.appendingPathComponent("parameters.skycut")
        var state = TimelineState()
        state.mainMagnet = false
        state.mainClips = [EditClip(sourceURL: source, sourceDuration: 1, timelineStart: 0, info: info)]
        id = state.mainClips[0].id
        before = state
        reset()
        AIReadGrants.shared.remember([folder, source.deletingLastPathComponent()])
    }

    func reset(_ state: TimelineState? = nil) {
        project.restoreTimeline(state ?? before)
        project.effectiveUndoManager!.removeAllActions()
    }

    func arguments(_ fields: [String: JSONValue]) -> AIToolArguments {
        var fields = fields
        fields["clip_id"] = .string(AIShortIDs(state: project.state).short(id))
        return AIToolArguments(.object(fields))
    }

    func edit(_ fields: [String: JSONValue]) async throws -> AIToolResult {
        let plan = try await AIClipTools.plan(arguments(fields), project)
        return try AIClipTools.apply(plan, project)
    }

    var rebuild: Int {
        guard let count = Mirror(reflecting: project).children.first(where: { $0.label == "rebuildGeneration" })?.value as? Int else {
            fatalError("Cannot inspect production rebuild counter")
        }
        return count
    }
}

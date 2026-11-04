import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 既有 save_project/get_timeline 的制作状态适配；所有实际媒体操作继续走既有 MCP 工具。
// 作者输入在副本/读取队列上全验，提交是工程自己的一个 undo，不开窗口、不建预览。
@MainActor
enum AIFilmProductionTool {
    static func save(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        guard let input = try AIFilmProductionReader.input(args) else { return try AIProjectTools.saveProject(args, project) }
        _ = try args.string("path") // 参数类型错不能等改了制作状态才发现。
        guard let expected = try args.int("expected_revision"), expected >= 0 else {
            throw AIToolError("production needs expected_revision from get_timeline (0 for an absent plan).")
        }
        let capture = AIFilmProductionCapture(project), state = capture.original
        let urls = AIFilmProductionJSON.anchorImageURLs(input)
        let allowed = Set(urls.filter { AIAccessStore.shared.mode == .full || AIWorkspace.shared.allowsReading($0, project: project) })
        let catalog = SkyStudioCatalogCache.shared.cachedCatalog()
        let result: Result<FilmProductionState?, Error> = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result {
                guard expected == (state.production?.revision ?? 0) else {
                    throw AIToolError("Production changed; read get_timeline again before authoring.")
                }
                if input == .null { return nil } // 明确清空可撤销；仅版本仍可合法比较的损坏内容能经此清掉。
                return try AIFilmProductionReader.read(input, expectedRevision: expected, previous: state.production,
                    state: capture.evaluation, allowedImages: allowed, catalog: catalog)
            }
        }
        let proposal = try result.get()
        guard !Task.isCancelled, capture.matches(project) else {
            throw AIToolError("The project changed while validating production; nothing was authored. Read get_timeline again.")
        }
        let changed = proposal != state.production
        if changed {
            AISession.shared.round(for: project).beginIfNeeded(project: project)
            _ = AIUndoGrouping.step(project.effectiveUndoManager) {
                project.perform(rebuildsPreview: false) { $0.production = proposal }
            }
        }
        do {
            var saved = try AIProjectTools.saveProject(args, project)
            if case .object(var payload) = saved.payload {
                payload["production_revision"] = proposal.map { .number(Double($0.revision)) } ?? .null
                payload["production_authored"] = .bool(changed)
                saved.payload = .object(payload)
            }
            saved.changedProject = changed
            return saved
        } catch {
            // 内存 authoring 已提交仍可撤销；不假称回滚，也不把请求路径保存失败说成写盘成功。
            return AIToolResult(payload: ["status": "production_authored_save_failed", "production_authored": .bool(changed),
                "requested_save_succeeded": false, "message": .string(error.localizedDescription)], isError: true, changedProject: changed)
        }
    }

    static func timeline(_ project: VideoEditProject) async throws -> AIToolResult {
        var result = AITimelineTools.timeline(project)
        let capture = AIFilmProductionCapture(project), state = capture.original
        guard state.production != nil else { return result }
        let allowed = AIFilmProduction.allowedImages(state, project: project)
        let production = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            AIFilmProductionSummary.make(capture.evaluation, allowedImages: allowed)
        }
        guard !Task.isCancelled, capture.matches(project) else {
            throw AIToolError("The timeline changed while reading production evidence; read it again.")
        }
        if case .object(var payload) = result.payload {
            payload["production"] = production
            result.payload = .object(payload)
        }
        return result
    }
}

import Foundation

// 每一次官方 POST 前的最后一道本机核对；包括 too_many_jobs 等待后的再次尝试。
// 不报价、不上传、不预留；一旦失败只可记“未受理”，不能把本机拒绝变成丢失云端应答。
@MainActor
enum SkyStudioOfficialSubmission {
    static func validate(_ operation: SkyStudioOfficialOperation, references: SkyStudioReferencePlan,
                         project: VideoEditProject?) async throws {
        do {
            guard let project, OpenProjects.shared.all.contains(where: { $0 === project }) else {
                throw AIToolError("The official project was closed before submission; no new POST was sent.")
            }
            try await SkyStudioOfficialGenerateTool.validateScope(operation.scope, project: project, key: operation.key)
            // 最后一次 await 之后同步核对；不只看 weak 引用，因为别的任务可能仍持有已关闭的工程。
            guard OpenProjects.shared.all.contains(where: { $0 === project }) else {
                throw AIToolError("The official project was closed while checking its account; no new POST was sent.")
            }
            guard try SkyStudioOfficialPreparation.sources(references) == operation.sources else {
                throw AIToolError("Original reference files changed before the official POST. Prepare and review a new quote; no new POST was sent.")
            }
            guard operation.expiresAt > Date() else {
                throw AIToolError("The official quote expired before submission. Obtain and review a fresh quote using a new operation key; no new POST was sent.")
            }
            try Task.checkCancellation()
        } catch {
            let reason = error is CancellationError ? "Cancelled before the official POST; no new request was sent."
                : (error as? AIToolError)?.message ?? error.localizedDescription
            throw SkyStudioJobError.notSubmitted(reason)
        }
    }
}

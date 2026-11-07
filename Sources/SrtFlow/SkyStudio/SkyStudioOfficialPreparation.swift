import Foundation
import SrtFlowMCPKit

// 显式准备原创图片引用：复用原有授权/测量/上传，只回准备令牌与真实资产，不报价、不预留、不生成。
// 长上传是既有 AIJobs 的任务；工程、账户、原文件变化后不能把旧资产装成新的准备结果。
@MainActor
enum SkyStudioOfficialPreparation {
    static func sources(_ plan: SkyStudioReferencePlan) throws -> JSONValue {
        var sources = try plan.files.map { file -> JSONValue in
            ["role": .string(file.role), "type": .string(file.type), "file": try SkyStudioApproval.file(file.file)]
        }
        if let assets = plan.characterAssets { sources.append(["character": assets.json]) }
        return .array(sources)
    }

    static func start(generation: SkyStudioGeneration, plan: SkyStudioReferencePlan, model: SkyStudioModel, scope: SkyStudioOfficialPrepared.Scope,
                      key: String, operationKey: String, project: VideoEditProject) throws -> AIToolResult {
        let originalSources = try sources(plan)
        let status = SkyStudioMediaStatus(kindLabel: L10n("Image"), modelTitle: model.title, credits: 0,
            uploads: plan.uploads, title: "Official references", owner: CloudTasksActivity.owner(of: project), mediaKind: .image)
        var task: Task<Void, Never>?
        let job = AIJobs.shared.start(.generate, progress: { nil }, liveDetail: { status.progress?.json() ?? [:] }, cancel: { task?.cancel() })
        status.aiJobID = job.id
        status.onCancel = { task?.cancel() }
        SkyStudioGenerationActivity.shared.add(status)
        task = Task { @MainActor in
            defer { SkyStudioGenerationActivity.shared.remove(status) }
            do {
                try Task.checkCancellation()
                try await SkyStudioOfficialGenerateTool.validateScope(scope, project: project, key: key)
                let cache = SkyStudioOfficialPrepared.shared
                let token: String
                let uploaded: SkyStudioOfficialPrepared.Assets
                if let reusable = cache.reusableAssets(scope: scope, sources: originalSources) {
                    (token, uploaded) = reusable
                } else {
                    status.advance(to: .uploading(fraction: nil), typicalSeconds: 0)
                    let result = try await SkyStudioReferenceFiles.upload(plan, model: model, api: SkyStudioAPI(), key: key) { fraction in
                        Task { @MainActor in status.advance(to: .uploading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: 0) }
                    }
                    try Task.checkCancellation()
                    guard project.documentGeneration == scope.projectGeneration,
                          project.documentURL?.standardizedFileURL.path == scope.projectPath,
                          SkyStudioAccount.shared.stored?.me.account.id == scope.accountID,
                          try sources(plan) == originalSources else {
                        throw AIToolError("The project, account or original files changed during reference upload. Uploaded assets were not approved for this request; no generation or credits were reserved.")
                    }
                    token = cache.rememberAssets(scope: scope, sources: originalSources, inputs: result.inputs, references: result.references)
                    uploaded = try cache.assets(token, scope: scope, sources: originalSources)
                }
                try await SkyStudioOfficialGenerateTool.validateScope(scope, project: project, key: key)
                guard try sources(plan) == originalSources else { throw AIToolError("The original files changed before preparation completed; no generation or credits were reserved.") }
                var request = generation.job(model: model.id, uploaded: uploaded.inputs, references: uploaded.references)
                request.characterAssets = plan.characterAssets
                let render: JSONValue = ["kind": .string(generation.kind.rawValue), "model": .string(model.id),
                    "prompt": .string(generation.prompt), "params": .object(request.renderParams), "inputs": .object(request.renderInputs)]
                var detail: [String: JSONValue] = [
                    "prepared_render": render, "inputs": uploaded.allInputs, "model_id": .string(model.id),
                    "input_mode": .string(plan.mode), "reference_files": .number(Double(plan.files.count)), "charged": false,
                    "next_step": "Add explicit public context to prepared_render for the story plan and neighbor declarations. Request generate_media with film, prepared_references when present and quote_only=true; quote_only never uploads. Preparation is local to this App run and project."
                ]
                if let usage = plan.characterAssets?.usage { detail["character_usage"] = usage.json }
                if !plan.files.isEmpty { detail["prepared_references"] = .string(token) }
                AIJobs.shared.finish(job, .done, message: "Effective render and original image references prepared; no generation or credit reservation.", detail: .object(detail))
            } catch {
                let cancelled = error is CancellationError
                let message = (error as? AIToolError)?.message ?? (error as? SkyStudioFilmError)?.localizedDescription
                    ?? (error as? SkyStudioFailure).map { SkyStudioJobError.request($0).message } ?? error.localizedDescription
                AIJobs.shared.finish(job, cancelled ? .cancelled : .failed, message: message,
                    detail: ["charged": false, "generation_started": false, "idempotency_key": .string(operationKey)])
            }
        }
        return .ok(["status": "preparing_references", "job_id": .string(job.id), "idempotency_key": .string(operationKey), "charged": false,
                    "next_step": "Wait with get_job for prepared_references and actual inputs. This explicit phase uploads only original images; it does not quote, reserve credits or generate."])
    }
}

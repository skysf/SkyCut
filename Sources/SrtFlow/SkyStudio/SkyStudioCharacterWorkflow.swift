import Foundation
import SrtFlowMCPKit

// 原生角色生产路径：测图 → 只读报价 → 获准后上传 → 既有 JobRun；也供假服务器直接执行，不复制另一套测试实现。
struct SkyStudioCharacterWorkflow: Sendable {
    var api: SkyStudioAPI
    var key: String
    var sleep: @Sendable (Double) async throws -> Void = { seconds in try await Task.sleep(for: .seconds(seconds)) }

    static func measure(_ paths: [(role: String, url: URL)], creatingPhoto: Bool) async throws -> [SkyStudioReference] {
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result {
                try paths.map { role, url in
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let bytes = (attributes[.size] as? NSNumber)?.doubleValue ?? 0
                    guard attributes[.type] as? FileAttributeType == .typeRegular, bytes > 0, bytes <= Double(SkyStudioGenerationFrame.maxBytes),
                          let image = SkyStudioReferenceImage.measure(url, role: role, bytes: bytes), image.imageCount == 1,
                          ["image/jpeg", "image/png", "image/webp"].contains(image.contentType ?? "") else {
                        throw AIToolError("Character input must be one still JPEG/PNG/WebP image per view, at most 30 MiB; BMP and animated images are unsupported.")
                    }
                    if creatingPhoto, (image.width ?? 0) * (image.height ?? 0) > 64_000_000 { throw AIToolError("Character creation photo exceeds 64,000,000 pixels.") }
                    return image
                }
            }
        }.get()
    }

    func quote(_ plan: SkyStudioCharacterPlan) async throws -> SkyStudioCharacterPlan {
        guard let job = plan.job else { return plan }
        var result = plan
        try result.accept(await api.quote(job, key: key))
        return result
    }

    /// 每张上传完成立即交给持久回执；源文件变化在 POST /uploads 之前拒绝，不用旧确认读新内容。
    func upload(_ plan: SkyStudioCharacterPlan, approvedFiles: [JSONValue],
                checkpoint: @escaping @Sendable (SkyStudioCharacterPlan) async throws -> Void = { _ in },
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SkyStudioCharacterPlan {
        guard approvedFiles.count == plan.files.count else { throw SkyStudioCharacterReceiptError.conflict }
        var result = plan
        for (index, file) in plan.files.enumerated() {
            try Task.checkCancellation()
            guard try SkyStudioApproval.file(file.file) == approvedFiles[index], let mime = file.contentType else { throw AIToolError("Character input changed after approval. Quote and approve the current file; nothing new was submitted.") }
            let purpose = plan.action == .create ? "image" : "character_role"
            let url = try await api.upload(fileURL: file.file, contentType: mime, purpose: purpose, key: key) { fraction in
                progress((Double(index) + fraction) / Double(plan.files.count))
            }
            guard try SkyStudioApproval.file(file.file) == approvedFiles[index] else { throw AIToolError("Character input changed during upload; no generation or library write was submitted.") }
            if plan.action == .create { result.job?.inputs["image_url"] = url.absoluteString }
            else {
                let asset: JSONValue = ["assetKey": .string(String(url.path.dropFirst())), "publicUrl": .string(url.absoluteString),
                    "mimeType": .string(mime), "sizeBytes": .number(file.bytes)]
                if plan.action == .importViews {
                    var roles = result.job?.nativeCharacter?.fields["roles"]?.objectValue ?? [:]
                    roles[file.role] = asset
                    result.job?.nativeCharacter?.fields["roles"] = .object(roles)
                } else { result.mutation?.body["asset"] = asset }
            }
            try await checkpoint(result)
        }
        return result
    }

    func run(_ request: SkyStudioJobRequest, resuming jobID: String? = nil,
             checkpoint: @escaping @Sendable (SkyStudioJobStatus) async throws -> Void,
             beforeSubmit: @escaping @Sendable () async throws -> Void = {},
             onUnstoppable: (@Sendable (String) -> Void)? = nil) async throws -> SkyStudioJobStatus {
        var runner = SkyStudioJobRun(api: api, key: key)
        runner.cancellable = false
        runner.sleep = sleep
        runner.checkpoint = checkpoint
        runner.beforeSubmit = beforeSubmit
        runner.onUnstoppable = onUnstoppable
        let done: SkyStudioJobStatus
        if let jobID { done = try await runner.resume(jobID) }
        else { done = try await runner.run(request) }
        guard done.characterID != nil, done.characterStatus == "ready" else { throw SkyStudioJobError.badAnswer("a completed Character job without a ready reusable character_id") }
        return done
    }
}

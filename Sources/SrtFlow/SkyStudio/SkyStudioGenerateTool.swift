import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：生成素材（generate_media），送 Sky Studio、花积分
//
// 管什么：AI 的参数读成一次生成（`SkyStudioGeneration`：图 / 视频 / 音乐 / 音效），按 kind 挑 `/models` 里的模型，问 `/quote` 多少积分，
// 在起任务之前过 `SkyStudioJobGate`（额度内直接记账；超了当场回确认码），然后**回任务号**：一次生成要几秒到几分钟，客户端对一次调用
// 大多只等一分钟。真正的活在 `SkyStudioGenerationRun` 里跑。成品放在用户的「生成」文件夹（点名的文件夹 → 工程的家 → 下载，撞名加编号），
// 也长期留在用户的 Sky Studio 作品库里。2026-10-28 起（收费方案第 6 刀 6b）；之前送 fal、花美元。
// 不管什么：参数怎么换成 Sky Studio 的写法（SkyStudioGeneration）；跑、等、下载（SkyStudioGenerationRun）；配旁白（add_voiceover）。
//
// 不改工程：放上时间线是 add_clips 的事（一个工具一件事，撤销也各是各的）。所以这里不进撤销分组、不算这一轮的改动。

@MainActor
enum SkyStudioGenerateTool {
    static func generate(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        // 工具始终可发现；Key、授权和积分必须在调用时核对，不能把列清单当成已经获准消费。
        guard SkyStudioAccount.shared.hasKey else { throw AIToolError(SkyStudioJobKey.Problem.noKey.message) }
        guard let kindName = try args.choice("kind", from: MCPVocabulary.generationKinds), let kind = SkyStudioGeneration.Kind(rawValue: kindName) else {
            throw AIToolError("kind is required: \(MCPVocabulary.generationKinds.joined(separator: ", ")).")
        }
        var ask = try SkyStudioGenerationControls.ask(args)
        let prompt = try args.string("prompt") ?? ""
        if try args.string("model") == "ideogram-remove-background", !args.has("operation") { ask.operation = "remove_background" }
        if kind != .image, ask.operation != "generate" { throw AIToolError("operation=remove_background requires kind=image.") }
        let idempotencyKey = try args.string("idempotency_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? UUID().uuidString.lowercased()
        var arguments = args.raw.objectValue ?? [:]
        arguments["confirm_token"] = nil
        let requestIdentity: JSONValue = ["arguments": .object(arguments), "project": .string(String(describing: ObjectIdentifier(project))),
            "generation": .number(Double(project.documentGeneration)), "account": .string(SkyStudioAccount.shared.stored?.me.account.id ?? "")]
        if let cached = try SkyStudioGenerationRequests.begin(idempotencyKey, identity: requestIdentity) { return cached }
        defer { SkyStudioGenerationRequests.abandonPreparation(idempotencyKey) }
        let picked = try SkyStudioReferenceFiles.picks(args, kind: kind)
        if let approval = try AIWorkspace.shared.confirmReading(picked.files.map(\.file), verb: "send to Sky Studio", args: args, project: project) { return approval }
        if kind.isVideo || kind == .image { _ = try await SkyStudioGeneratedVideo.engine() }
        let references = try await SkyStudioReferenceFiles.measure(picked, project: project)
        let frame = references.firstFrame
        let canvas = project.renderSize
        let canvasRatio = canvas.width / max(canvas.height, 1)
        let frameRatio = frame.flatMap(SkyStudioGenerationFrame.aspect(of:))
        let requested = try args.string("model")
        let imageContext = try args.choice("image_context", from: ["asian", "other"]) ?? "other"
        let quality = try args.choice("quality", from: ["standard", "highest"]) ?? "standard"

        // Sky Studio：Key（不弹框）、这一种用哪个模型、多少积分。
        let key: String
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let found): key = found
        case .failure(let problem): throw AIToolError(problem.message)
        }
        let api = SkyStudioAPI()
        let model: SkyStudioModel
        let catalog: SkyStudioCatalog
        let generation: SkyStudioGeneration
        let quote: SkyStudioQuote
        do {
            catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: api)
            guard let offered = SkyStudioModelPolicy.select(catalog: catalog, kind: kind.rawValue, requested: requested, imageContext: imageContext, quality: quality,
                accepts: { SkyStudioModelPolicy.problem(model: $0, ask: ask, references: references) == nil && SkyStudioGenerationControls.problem(model: $0, ask: ask, prompt: prompt, references: references) == nil }) else {
                if let requested, let model = catalog.model(requested, kind: kind.rawValue) {
                    throw AIToolError(SkyStudioModelPolicy.problem(model: model, ask: ask, references: references) ?? SkyStudioGenerationControls.problem(model: model, ask: ask, prompt: prompt, references: references) ?? "This model cannot accept the request.")
                }
                throw AIToolError("No offered model accepts the complete request. Read get_status models=true for model ids, modes and reference limits. Available: "
                    + catalog.models(kind: kind.rawValue).map(\.id).joined(separator: ", "))
            }
            model = offered
            generation = SkyStudioGeneration.make(kind, prompt: prompt, ask: ask, canvas: canvasRatio, frame: frameRatio,
                                                  model: model, inputMode: references.mode, references: references)
            quote = try await api.quote(generation.job(model: model.id), key: key)
        } catch let error as AIToolError {
            throw error
        } catch {
            throw AIToolError(message(error))
        }

        // 花积分的把关在起任务之前（AI 多开方案板 9）：超了每日上限当场回确认码，AI 在聊天里问用户、带码再调。
        let folder = AIWorkspace.shared.outputFolder(.generated, project: project)
        let identity = SkyStudioApproval.identity(job: generation.job(model: model.id), credits: quote.credits, context: [
            "frame": try frame.map(SkyStudioApproval.file) ?? .null,
            "references": .array(try references.files.map { try SkyStudioApproval.file($0.file) }),
            "auto_fallback": false,
            "folder": .string(folder.standardizedFileURL.path), "name": .string(try args.string("name") ?? "")
        ])
        let reservation: SkyStudioJobGate.Reservation
        switch try SkyStudioJobGate.decide(credits: quote.credits, summary: generation.summary(modelTitle: model.title), identity: identity, args: args) {
        case .needsConfirmation(let ask): return ask
        case .reserved(let reserved): reservation = reserved
        }

        let stem = ExportFileName.stem(
            from: try args.string("name").map { AIVoiceoverPlacement.fileStem($0) } ?? AIVoiceoverPlacement.fileStem(prompt),
            droppingExtension: "", fallback: fallbackStem(kind)
        )
        let run = SkyStudioGenerationRun(
            generation: generation, model: model, quote: quote, references: references, folder: folder, stem: stem, project: project, reservation: reservation, idempotencyKey: idempotencyKey
        )
        let job = run.start()
        let store = SkyStudioSpendStore.shared
        let minutes = CloudJobProgress.minutes(quote.typicalSeconds ?? generation.typicalSeconds)
        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(job.id), "kind": .string(kind.rawValue), "model": .string(model.title), "model_id": .string(model.id),
            "params": .object(generation.params), "idempotency_key": .string(idempotencyKey),
            "billing_policy": catalog.billingPolicy ?? model.metadata["billing_policy"] ?? .null,
            "billing_note": .string(SkyStudioBilling.policyMessage), "reference_files": .number(Double(references.files.count)),
            "credits": .number(SkyStudioCredits.number(quote.credits)),
            "typical_minutes": .number(Double(minutes)),
            "daily_limit_credits": .number(store.dailyLimit),
            "spent_today_credits": .number(SkyStudioCredits.number(store.spentToday())),
            "next_step": .string(
                "Tell the user the reservation is \(SkyStudioCredits.text(quote.credits)) Sky Studio credits. Explain billing_note before waiting. Wait with get_job (usually about "
                    + "\(minutes) min); when it is done, put the file on the timeline with add_clips"
                    + (kind.isSound ? " (track new_audio)." : ".")
            )
        ]
        if !generation.notes.isEmpty { result["notes"] = .array(generation.notes.map { .string($0) }) }
        let response = AIToolResult.ok(.object(result))
        SkyStudioGenerationRequests.complete(idempotencyKey, result: response)
        return response
    }

    /// 给 get_status 的一段：存了 Sky Studio 的 Key 才有。AI 看了就知道生成和 upscale 花的是积分、今天还剩多少。
    static func statusJSON() -> JSONValue? {
        guard SkyStudioAccount.shared.hasKey else { return nil }
        let store = SkyStudioSpendStore.shared
        return .object([
            "provider": "Sky Studio", "daily_limit_credits": .number(store.dailyLimit),
            "spent_today_credits": .number(SkyStudioCredits.number(store.spentToday())),
            "models_hint": "Call get_status models=true (optionally model=<id>) for current models, defaults and reference input limits."
        ])
    }

    // MARK: 参数

    private static func fallbackStem(_ kind: SkyStudioGeneration.Kind) -> String {
        switch kind {
        case .image: return "Image"
        case .imageToVideo, .textToVideo, .lipsync: return "Video"
        case .music: return "Music"
        case .soundEffect: return "Sound effect"
        }
    }

    private static func message(_ error: Error) -> String {
        if let failure = error as? SkyStudioFailure { return SkyStudioJobError.request(failure).message }
        return error.localizedDescription
    }
}

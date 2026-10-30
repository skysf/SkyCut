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
        let prompt = try args.requiredString("prompt")
        let ask = SkyStudioGeneration.Ask(
            duration: try args.double("duration"),
            resolution: try args.choice("resolution", from: MCPVocabulary.videoResolutions),
            aspectRatio: try args.choice("aspect_ratio", from: MCPVocabulary.generationAspects),
            instrumental: try args.bool("instrumental"),
            lyrics: try args.string("lyrics")
        )
        var frame: URL?
        if kind == .imageToVideo {
            let picture = try firstFrameFile(args)
            // 首帧会传给 Sky Studio：点名的文件夹以外的先问一次用户（同读别处的文件）。
            if let ask = try AIWorkspace.shared.confirmReading([picture], verb: "send to Sky Studio", args: args, project: project) { return ask }
            frame = picture
        } else if args.has("image") {
            throw AIToolError("image is only used by image_to_video.")
        }
        let canvas = project.renderSize
        let generation = SkyStudioGeneration.make(
            kind, prompt: prompt, ask: ask, canvas: canvas.width / max(canvas.height, 1), frame: frame.flatMap(SkyStudioGenerationFrame.aspect(of:))
        )

        // Sky Studio：Key（不弹框）、这一种用哪个模型、多少积分。
        let key: String
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let found): key = found
        case .failure(let problem): throw AIToolError(problem.message)
        }
        let api = SkyStudioAPI()
        let model: SkyStudioModel
        let quote: SkyStudioQuote
        do {
            let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: api)
            guard let offered = catalog.models(kind: kind.rawValue).first else {
                throw AIToolError("Sky Studio offers no \(kind.rawValue) model right now.")
            }
            model = offered
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
            generation: generation, model: model, quote: quote, frame: frame, folder: folder, stem: stem, project: project, reservation: reservation
        )
        let job = run.start()
        let store = SkyStudioSpendStore.shared
        let minutes = CloudJobProgress.minutes(quote.typicalSeconds ?? generation.typicalSeconds)
        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(job.id), "kind": .string(kind.rawValue), "model": .string(model.title),
            "credits": .number(SkyStudioCredits.number(quote.credits)),
            "typical_minutes": .number(Double(minutes)),
            "daily_limit_credits": .number(store.dailyLimit),
            "spent_today_credits": .number(SkyStudioCredits.number(store.spentToday())),
            "next_step": .string(
                "Tell the user it costs \(SkyStudioCredits.text(quote.credits)) Sky Studio credits. Wait with get_job (usually about "
                    + "\(minutes) min); when it is done, put the file on the timeline with add_clips"
                    + (kind.isSound ? " (track new_audio)." : ".")
            )
        ]
        if !generation.notes.isEmpty { result["notes"] = .array(generation.notes.map { .string($0) }) }
        return .ok(.object(result))
    }

    /// 给 get_status 的一段：存了 Sky Studio 的 Key 才有。AI 看了就知道生成和 upscale 花的是积分、今天还剩多少。
    static func statusJSON() -> JSONValue? {
        guard SkyStudioAccount.shared.hasKey else { return nil }
        let store = SkyStudioSpendStore.shared
        return .object([
            "provider": "Sky Studio", "daily_limit_credits": .number(store.dailyLimit),
            "spent_today_credits": .number(SkyStudioCredits.number(store.spentToday()))
        ])
    }

    // MARK: 参数

    private static func firstFrameFile(_ args: AIToolArguments) throws -> URL {
        guard let path = try args.string("image"), !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIToolError("image is required for image_to_video: the picture file to start from.")
        }
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no picture at \(path).") }
        return url
    }

    private static func fallbackStem(_ kind: SkyStudioGeneration.Kind) -> String {
        switch kind {
        case .image: return "Image"
        case .imageToVideo, .textToVideo: return "Video"
        case .music: return "Music"
        case .soundEffect: return "Sound effect"
        }
    }

    private static func message(_ error: Error) -> String {
        if let failure = error as? SkyStudioFailure { return SkyStudioJobError.request(failure).message }
        return error.localizedDescription
    }
}

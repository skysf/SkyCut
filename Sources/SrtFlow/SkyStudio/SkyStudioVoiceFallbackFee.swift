import Foundation
import SrtFlowMCPKit

// MARK: - 旁白中途：备用要先花一次性费用（任务结束码 fallback_needs_one_time）
//
// 管什么（SkyCut 声音方案 4.5；声音 PR 4 让那一批停下、别的批收好、任务以可恢复的 failed 结束，问用户是这里）：
// - **任务结束那一刻**（`ask`）：结束码带的 `one_time`（建哪种语言的 MiniMax 版；可能不带价）补上价（没带就 `/quote` 一次 voice_enroll，
//   免费）和声音（照恢复记录），记进恢复记录（`fallbackFee`），经 SkyStudioJobGate.voiceOneTime 发问句和 confirm_token，并进 get_job：
//   AI 问用户 —— **resume + confirm_token** = 建（起 voice_enroll 任务），做完 **resume + generate_missing=true** 接着做没做成的几批
//   （MiniMax 版有了，默认再出错时服务器能自动换上备用）；**resume + skip_one_time=true** = 不建，用原来的模型重试那几批（同 generate_missing）。
// - **resume 带着这两样**（`resume`）：skip → 清掉、交给 generate_missing；令牌 → 过闸（每日硬预算、令牌绑这一笔的完整身份）、记账、起建的任务、
//   清掉；令牌过期 / 用过了 → 再问一次。不带的普通 resume 照旧只恢复已有结果，这一笔留着等答复。
// 和配旁白开头那一问（SkyStudioVoiceOneTimeStep）一样分两步：建要几十秒、建完的价要再报，不在旁白任务里串着做。
// 这一刀两种模式都问（全部权限下直接建要等长期授权和打开时的价目说明，声音 PR 7）。
// 不管什么：几批怎么交、中途换备用（SkyStudioVoiceBatchQueue / SkyStudioVoiceCloudBatches，声音 PR 4）。

@MainActor
enum SkyStudioVoiceFallbackFee {
    enum Decision {
        /// 没答这一问（普通 resume）：照旧恢复，这一笔留着。
        case notAsked
        /// 用户不建：用原来的模型重试没做成的几批。
        case retryWithSameModel
        /// 要再问一次，或者点过头起了建的任务：原样回给 AI。
        case result(AIToolResult)
    }

    /// 任务以 fallback_needs_one_time 结束：补价、记下、发问句，回要并进 get_job 的字段。问不了（读不到 Key、报不出价、不是建 MiniMax 版）回 nil。
    static func ask(_ failure: SkyStudioJobFailure, recovery: SkyStudioVoiceRecovery, services: SkyStudioVoiceServices) async -> [String: JSONValue]? {
        guard let raw = failure.oneTime.first, raw.kind == SkyStudioVoiceKind.enroll, let key = try? await services.key(),
              let fee = await priced(raw, voice: recovery.value.input.voice, key: key, api: services.api), let credits = fee.credits else { return nil }
        recovery.value.fallbackFee = fee
        do { try await recovery.save() } catch { return nil }
        let decision = try? SkyStudioJobGate.voiceOneTime(credits: credits, action: action(fee, key: key),
                                                          question: SkyStudioVoiceApproval.fallbackQuestion(fee, credits: credits), token: nil)
        guard case .needsConfirmation(let result)? = decision, case .object(var value) = result.payload else { return nil }
        value["one_time"] = .array([fee.json])
        value["next_step"] = .string(nextStep(asking: value["status"] == "needs_confirmation", file: recovery.file.path))
        return value
    }

    /// resume 带着 confirm_token / skip_one_time，答这一笔。`token` 只在这一次没有拿它去答「读别处的文件」时才传进来。
    static func resume(fee: SkyStudioVoiceOneTime, skip: Bool, token: String?, recovery: SkyStudioVoiceRecovery, project: VideoEditProject,
                       services: SkyStudioVoiceServices) async throws -> Decision {
        if skip {
            recovery.value.fallbackFee = nil
            try await recovery.save()
            return .retryWithSameModel
        }
        guard let token, let credits = fee.credits, let voice = fee.voice, let language = fee.language else { return .notAsked }
        let key = try await services.key()
        let catalog = try? await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api)
        guard let model = fee.model ?? catalog?.models(kind: SkyStudioVoiceKind.enroll).first?.id else {
            throw AIToolError("Sky Studio's catalog has no model to build the voice's MiniMax version. Nothing was charged.")
        }
        // 请求先拼好（拼不出来在记账之前就停），再过闸。
        let request: SkyStudioJobRequest
        do { request = try SkyStudioVoiceRequests.enroll(voice: voice, language: language, model: model, maxCredits: credits) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message + " Nothing was charged.") }
        switch try SkyStudioJobGate.voiceOneTime(credits: credits, action: action(fee, key: key),
                                                 question: SkyStudioVoiceApproval.fallbackQuestion(fee, credits: credits), token: token) {
        case .needsConfirmation(let result):
            guard case .object(var value) = result.payload else { return .result(result) }
            value["one_time"] = .array([fee.json])
            value["next_step"] = .string(nextStep(asking: value["status"] == "needs_confirmation", file: recovery.file.path))
            var asked = result
            asked.payload = .object(value)
            return .result(asked)
        case .reserved(let reservation):
            recovery.value.fallbackFee = nil
            try? await recovery.save()
            let file = recovery.file.path
            let job = SkyStudioVoiceLibraryJob(
                kind: .voiceEnroll, request: request, key: key, reservation: reservation, title: SkyStudioVoicePick.languageName(language),
                modelTitle: catalog?.models.first { $0.id == model }?.title ?? "MiniMax", project: project,
                nextStep: "The voice's MiniMax version is ready. Call add_voiceover resume=\(file) generate_missing=true to read the missing "
                    + "parts; the fallback can be used now. Never send the original lines again.",
                api: services.api
            ).start()
            return .result(.ok([
                "status": "started", "job_id": .string(job.id), "kind": .string(AIJobs.Kind.voiceEnroll.rawValue), "provider": "Sky Studio",
                "credits": .number(credits), "one_time": .array([fee.json]), "recovery_file": .string(file),
                "next_step": .string("Building the voice's MiniMax version, a one-time fee. Wait with get_job; when it is done, call "
                    + "add_voiceover resume=\(file) generate_missing=true. Never send the original lines again.")
            ]))
        }
    }

    /// 结束码带的那一笔没有价就报一次（`/quote` voice_enroll，免费）；声音没写就照恢复记录。
    private static func priced(_ raw: SkyStudioVoiceOneTime, voice: String, key: String, api: SkyStudioAPI) async -> SkyStudioVoiceOneTime? {
        var fee = raw
        if fee.voice == nil { fee.voice = voice }
        guard let voice = fee.voice, SkyStudioVoice.isVoiceID(voice), let language = fee.language else { return nil }
        if fee.credits != nil { return fee }
        guard let catalog = try? await SkyStudioCatalogCache.shared.catalog(key: key, api: api),
              let model = fee.model ?? catalog.models(kind: SkyStudioVoiceKind.enroll).first?.id,
              let request = try? SkyStudioVoiceRequests.enroll(voice: voice, language: language, model: model),
              let quote = try? await api.quote(request, key: key) else { return nil }
        fee.model = model
        fee.credits = quote.voice?.oneTime.first?.credits ?? quote.credits
        return fee
    }

    private static func action(_ fee: SkyStudioVoiceOneTime, key: String) -> String {
        SkyStudioVoiceApproval.oneTimeAction(fee, account: SkyStudioCharacterAccess.stamp(key))
    }

    private static func nextStep(asking: Bool, file: String) -> String {
        let retry = "or retry the missing parts with the same model (add_voiceover resume=\(file) skip_one_time=true, the same as generate_missing=true)"
        guard asking else {
            return "One part failed and its fallback needs a one-time fee that is over today's credit limit. Tell the user; " + retry + ". "
                + "Never send the original lines again."
        }
        return "One part failed on Sky Studio and its fallback first needs a one-time fee (one_time); nothing was charged for it and the "
            + "other parts are kept. Ask the user in their language: build the voice's MiniMax version (add_voiceover resume=\(file) with "
            + "this confirm_token; when that job is done, resume=\(file) generate_missing=true reads the missing parts), " + retry + ". "
            + "Never send the original lines again."
    }
}

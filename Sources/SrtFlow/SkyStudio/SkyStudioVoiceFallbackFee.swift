import Foundation
import SrtFlowMCPKit

// MARK: - 旁白中途：备用要先花一次性费用（任务结束码 fallback_needs_one_time）
//
// 管什么（SkyCut 声音方案 4.5；声音 PR 4 让那一批停下、别的批收好、任务以可恢复的 failed 结束，这里定怎么办）：
// - **任务结束那一刻**（`ask`）：结束码带的 `one_time`（建哪种语言的 MiniMax 版；可能不带价）补上价（没带就 `/quote` 一次 voice_enroll，
//   免费）和声音（照恢复记录），记进恢复记录（`fallbackFee`），再照此刻的权限定（`settle`，SkyStudioVoiceStanding.voiceAsk）：
//   - 请求批准模式：经 SkyStudioJobGate.voiceOneTime 发问句和 confirm_token，并进 get_job。AI 问用户：**resume + confirm_token** = 建
//     （起 voice_enroll 任务），做完 **resume + generate_missing=true** 接着做没做成的几批（MiniMax 版有了，默认再出错时服务器能自动换上备用）；
//     **resume + skip_one_time=true** = 不建，用原来的模型重试那几批（同 generate_missing）；
//   - 全部权限、有长期授权（声音 PR 7）：不问，直接建（每日硬预算照拦），get_job（`enroll_job_id`）和提示条说建了、最多花多少；
//   - 全部权限、还没有长期授权：照请求批准模式问一次，问句带打开全部权限时那段说明，点过头补记。
// - **resume**：带 skip_one_time → 清掉、交给 generate_missing；带 confirm_token → 照此刻的权限过闸（令牌绑这一笔的完整身份）、起建的任务；
//   不带的普通 resume 照旧只恢复已有结果，这一笔留着，收尾时（`waiting`）同一个问题、同一张令牌再给一遍（全部权限 + 长期授权就直接建）。
// 和配旁白开头那一问（SkyStudioVoiceOneTimeStep）一样分两步：建要几十秒、建完的价要再报，不在旁白任务里串着做。
// 不管什么：几批怎么交、中途换备用（SkyStudioVoiceBatchQueue / SkyStudioVoiceCloudBatches，声音 PR 4）。

@MainActor
enum SkyStudioVoiceFallbackFee {
    enum Decision {
        /// 没答这一问（普通 resume）：照旧恢复，这一笔留着。
        case notAsked
        /// 用户不建：用原来的模型重试没做成的几批。
        case retryWithSameModel
        /// 要再问一次，或者起了建的任务：原样回给 AI。
        case result(AIToolResult)
    }

    /// 定下来的样子：问 / 额度不够（原样的结果），或者起了建的任务（`following`：早先点过头的那一单还在建，这一次没有新记账）。
    private enum Settled {
        case asked(AIToolResult)
        case building(job: AIJobs.Job, credits: Double, standing: Bool, following: Bool)
    }

    /// 任务以 fallback_needs_one_time 结束：补价、记下，照此刻的权限问 / 建，回要并进 get_job 的字段。问不了（读不到 Key、报不出价、
    /// 不是建 MiniMax 版）回 nil。
    static func ask(_ failure: SkyStudioJobFailure, recovery: SkyStudioVoiceRecovery, project: VideoEditProject?,
                    services: SkyStudioVoiceServices) async -> [String: JSONValue]? {
        guard let raw = failure.oneTime.first, raw.kind == SkyStudioVoiceKind.enroll, let key = try? await services.key(),
              let fee = await priced(raw, voice: recovery.value.input.voice, key: key, api: services.api), fee.credits != nil else { return nil }
        recovery.value.fallbackFee = fee
        do { try await recovery.save() } catch { return nil }
        return await jobFields(fee, key: key, recovery: recovery, project: project, services: services)
    }

    /// 普通 resume 收好了已有的、这一笔还在等答复：get_job 把同一个问题（同一张令牌）再给一遍，免得 AI 只看到 generate_missing 那一句；
    /// 全部权限 + 长期授权就直接建。
    static func waiting(_ recovery: SkyStudioVoiceRecovery, project: VideoEditProject?, services: SkyStudioVoiceServices) async -> [String: JSONValue]? {
        guard let fee = recovery.value.fallbackFee, fee.credits != nil, let key = try? await services.key() else { return nil }
        return await jobFields(fee, key: key, recovery: recovery, project: project, services: services)
    }

    /// resume 带着 confirm_token / skip_one_time，答这一笔。`token` 只在这一次没有拿它去答「读别处的文件」时才传进来。
    static func resume(fee: SkyStudioVoiceOneTime, skip: Bool, token: String?, recovery: SkyStudioVoiceRecovery, project: VideoEditProject,
                       services: SkyStudioVoiceServices) async throws -> Decision {
        if skip {
            recovery.value.fallbackFee = nil
            try await recovery.save()
            return .retryWithSameModel
        }
        guard let token, fee.credits != nil else { return .notAsked }
        let key = try await services.key()
        switch try await settle(fee, token: token, key: key, recovery: recovery, project: project, services: services) {
        case .asked(let result): return .result(result)
        case .building(let job, let credits, let standing, let following):
            var value: [String: JSONValue] = [
                "status": "started", "job_id": .string(job.id), "kind": .string(AIJobs.Kind.voiceEnroll.rawValue), "provider": "Sky Studio",
                "one_time": .array([fee.json]), "recovery_file": .string(recovery.file.path),
                "next_step": .string((following ? "The voice's MiniMax version is already being built (job \(job.id), approved earlier): "
                        + "nothing new was charged. " : "Building the voice's MiniMax version, a one-time fee. ")
                    + "Wait with get_job; when it is done, call add_voiceover resume=\(recovery.file.path) generate_missing=true. "
                    + "Never send the original lines again.")
            ]
            if following { value["already_building"] = true } else { value["credits"] = .number(credits) }
            if standing { value["full_access"] = .string(fullAccessNote(credits)) }
            return .result(.ok(.object(value)))
        }
    }

    /// 并进旁白那一单 get_job 的字段（job_id / kind / status 是旁白那一单自己的，建的任务号单独写在 enroll_job_id）。
    private static func jobFields(_ fee: SkyStudioVoiceOneTime, key: String, recovery: SkyStudioVoiceRecovery, project: VideoEditProject?,
                                  services: SkyStudioVoiceServices) async -> [String: JSONValue]? {
        switch try? await settle(fee, token: nil, key: key, recovery: recovery, project: project, services: services) {
        case .asked(let result)?:
            return result.payload.objectValue
        case .building(let job, let credits, let standing, let following)?:
            var value: [String: JSONValue] = [
                "enroll_job_id": .string(job.id), "one_time": .array([fee.json]),
                "next_step": .string("SkyCut is building the voice's MiniMax version (job \(job.id)), a one-time fee, because one part's "
                    + "fallback needs it. Wait for that job with get_job; then call add_voiceover resume=\(recovery.file.path) "
                    + "generate_missing=true to read the missing parts. Never send the original lines again.")
            ]
            if following { value["already_building"] = true } else { value["credits"] = .number(credits) }
            if standing { value["full_access"] = .string(fullAccessNote(credits)) }
            return value
        case nil:
            return nil
        }
    }

    /// 照此刻的权限定这一笔：要问就回问句（同一件事回同一张令牌）、额度不够原样回；不用问 / 点过头就记账、清掉这一笔、起建的任务。
    private static func settle(_ fee: SkyStudioVoiceOneTime, token: String?, key: String, recovery: SkyStudioVoiceRecovery,
                               project: VideoEditProject?, services: SkyStudioVoiceServices) async throws -> Settled {
        guard let credits = fee.credits, let voice = fee.voice, let language = fee.language else {
            throw AIToolError("This one-time fee has no price, voice or language. Nothing was charged.")
        }
        let catalog = try? await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api)
        guard let model = fee.model ?? catalog?.models(kind: SkyStudioVoiceKind.enroll).first?.id else {
            throw AIToolError("Sky Studio's catalog has no model to build the voice's MiniMax version. Nothing was charged.")
        }
        // 请求先拼好（拼不出来在记账之前就停），再过闸。
        let request: SkyStudioJobRequest
        do { request = try SkyStudioVoiceRequests.enroll(voice: voice, language: language, model: model, maxCredits: credits) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message + " Nothing was charged.") }
        let account = SkyStudioCharacterAccess.stamp(key)
        let identity = SkyStudioVoiceLibraryJob.enrollIdentity(voice: voice, language: language, account: account)
        // 这个声音这种语言的 MiniMax 版已经在建（早先点过头的那一单还没做完）：跟着它，不再问、不再预留（审查 #362 第 2 条）。
        if let open = SkyStudioVoiceLibraryJob.running(identity) { return .building(job: open, credits: credits, standing: false, following: true) }
        let standing = SkyStudioVoiceStanding.shared
        // 工程关了：起不了挂在它名下的任务，只问不建（点过头也要等工程开着再来）。
        let ask: SkyStudioJobGate.VoiceAsk = project == nil ? .ask : await standing.voiceAsk(key: key, api: services.api)
        // 上面等了一下：再看一眼有没有别的调用刚起了这一单。从这里到起任务之间没有 await。
        if let open = SkyStudioVoiceLibraryJob.running(identity) { return .building(job: open, credits: credits, standing: false, following: true) }
        switch try SkyStudioJobGate.voiceOneTime(credits: credits, action: action(fee, key: key),
                                                 question: SkyStudioVoiceApproval.fallbackQuestion(fee, credits: credits),
                                                 token: project == nil ? nil : token, ask: ask) {
        case .needsConfirmation(let result):
            guard case .object(var value) = result.payload else { return .asked(result) }
            value["one_time"] = .array([fee.json])
            value["next_step"] = .string(nextStep(asking: value["status"] == "needs_confirmation", file: recovery.file.path))
            var asked = result
            asked.payload = .object(value)
            return .asked(asked)
        case .reserved(let reservation):
            let file = recovery.file
            let enrolment = SkyStudioVoiceLibraryJob(
                kind: .voiceEnroll, identity: identity, request: request, key: key, reservation: reservation,
                title: SkyStudioVoicePick.languageName(language),
                modelTitle: catalog?.models.first { $0.id == model }?.title ?? "MiniMax", project: project,
                nextStep: "The voice's MiniMax version is ready. Call add_voiceover resume=\(file.path) generate_missing=true to read "
                    + "the missing parts; the fallback can be used now. Never send the original lines again.",
                api: services.api
            )
            // 这一笔的问题留到 Sky Studio 受理了建的那一单才清：受理之前就没做成（改了价、断网、等不到槽）预留退了，问题还在，
            // 普通 resume / get_job 照样再问（审查 #362 第 3 条：以前记上账就清，之后只剩 generate_missing、又回到同一个失败）。
            enrolment.onAccepted = { [recovery] in
                recovery.value.fallbackFee = nil
                await SkyStudioVoiceRecovery.updateFee(in: file) { _ in nil }
            }
            enrolment.onFailure = { [recovery] code, changed in
                await unanswered(fee, code: code, changed: changed, recovery: recovery)
            }
            let job = enrolment.start()
            await standing.recordAfterApproval(ask, key: key, api: services.api)
            if ask == .standing {
                standing.notify(String(format: L10n("Full access: SkyCut is building a voice's MiniMax version (at most %@ credits)."),
                                       SkyStudioCredits.text(credits)), project: project)
            }
            return .building(job: job, credits: credits, standing: ask == .standing, following: false)
        }
    }

    /// 建的那一单没做成：这一笔怎么办，回并进它 get_job 的字段。
    /// - 这种语言的 MiniMax 版其实已经有了（`minimax_voice_exists`）：问题答完了，直接去读没做成的几批；
    /// - 别的：问题还开着（受理之后才失败的把它放回恢复记录）；Sky Studio 改了价（`price_changed`）就把新价记下，下一次按新价问。
    private static func unanswered(_ fee: SkyStudioVoiceOneTime, code: String?, changed: Double?,
                                   recovery: SkyStudioVoiceRecovery) async -> [String: JSONValue] {
        let file = recovery.file
        if code == SkyStudioVoiceCodes.minimaxVoiceExists {
            recovery.value.fallbackFee = nil
            await SkyStudioVoiceRecovery.updateFee(in: file) { _ in nil }
            return ["recovery_file": .string(file.path),
                    "next_step": .string("The voice already has its MiniMax version for this language; nothing was charged. Call add_voiceover "
                        + "resume=\(file.path) generate_missing=true to read the missing parts. Never send the original lines again.")]
        }
        var repriced = fee
        if let changed { repriced.credits = changed }
        let open = repriced
        recovery.value.fallbackFee = open
        await SkyStudioVoiceRecovery.updateFee(in: file) { _ in open }
        return ["recovery_file": .string(file.path), "one_time": .array([open.json]),
                "next_step": .string((changed.map { "Sky Studio's price changed to \(SkyStudioCredits.text($0)) credits and nothing was charged. " } ?? "")
                    + "The MiniMax version was not built, so the one-time fee question is still open: call add_voiceover resume=\(file.path) "
                    + "to be asked again with the current price, or resume=\(file.path) skip_one_time=true to retry the missing parts with "
                    + "the same model. Never reuse the old confirm_token or send the original lines again.")]
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

    private static func fullAccessNote(_ credits: Double) -> String {
        "Full access: SkyCut started this without asking. Tell the user it builds the voice's MiniMax version for at most "
            + "\(SkyStudioCredits.text(credits)) credits."
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

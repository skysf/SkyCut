import Foundation
import SrtFlowMCPKit

// MARK: - 配旁白碰上一次性费用：用户声音库里的声音要先建 MiniMax 版
//
// 管什么（SkyCut 声音方案 4.2 第 3 步、4.5）：整段报价回来 `one_time` 不为空时（`voice_plan.rule: default_needs_one_time`：默认要的
// MiniMax 版还没建，selection 先给了不花一次性费用的那个；或者点名的模型就要 MiniMax 版），回任务号之前在这里定：
// - `skip_one_time=true`：照报价里不花钱的那个读（英文 IndexTTS2、其他语言 HeyGen Turbo），只对 `default_needs_one_time` 有用；
//   点名的模型要 MiniMax 版时没有不花钱的那个，报错叫 AI 改用 auto / 别的模型 / 点头；
// - 没带：经 SkyStudioJobGate.voiceOneTime（先判每日硬预算），照 SkyStudioVoiceStanding.voiceAsk：请求批准模式问，问句里写价、建了以后用什么、
//   不建这一单用什么；全部权限下有长期授权不问、直接建、做完说（声音 PR 7），没有就问一次并带打开全部权限时那段说明、点过头补记；
// - 点过头 / 不用问（记上账）：起一单 `voice_enroll`（SkyStudioVoiceLibraryJob，回它的任务号），做完叫 AI 再调一次
//   add_voiceover —— 那时 MiniMax 版有了，报价不再要一次性费用，照默认读。不在一单里串着读：建的这一步要几十秒、价也要等建完再报一次，
//   回任务号之前的整段报价和整体预留这条规矩（声音 PR 3）不能在任务里绕过去。
// **这个声音这种语言的 MiniMax 版已经在建就跟着那一单**（SkyStudioVoiceLibraryJob.running，问之前先看）：不再问、不再预留、不再起任务。
// 不管什么：报价、分批、起旁白任务（SkyStudioVoiceoverStart）；任务里某一批的备用要先建 MiniMax 版（`fallback_needs_one_time`，
// 问用户在 SkyStudioVoiceFallbackFee）。

@MainActor
enum SkyStudioVoiceOneTimeStep {
    enum Decision {
        /// 用户不建：照报价里不花钱的那个读。
        case readWithoutFee
        /// 要问、额度不够、或者点过头起了建 MiniMax 版的任务：原样回给 AI，这一次不起旁白。
        case result(AIToolResult)
    }

    static func decide(_ input: AIVoiceoverInput, quote: SkyStudioVoiceQuote, key: String, catalog: SkyStudioCatalog,
                       project: VideoEditProject, api: SkyStudioAPI) async throws -> Decision {
        let plan = quote.plan
        let noFee = plan?.needsOneTime == true ? plan?.model : nil
        if input.skipOneTime {
            guard noFee != nil else {
                throw AIToolError("\(plan?.model ?? "This model") needs this voice's MiniMax version first, a one-time fee, so there is "
                    + "nothing to skip to. Use model=auto (or another model), or ask the user to approve the fee. Nothing was charged.")
            }
            return .readWithoutFee
        }
        guard quote.oneTime.count == 1, let item = quote.oneTime.first, item.kind == SkyStudioVoiceKind.enroll,
              let credits = item.credits, let voice = item.voice ?? input.requestedVoice, let language = item.language else {
            throw AIToolError("Sky Studio asks for a one-time fee SkyCut cannot pay here (\(quote.oneTime.map(\.kind).joined(separator: ", "))). "
                + "Nothing was charged.")
        }
        guard let model = item.model ?? catalog.models(kind: SkyStudioVoiceKind.enroll).first?.id else {
            throw AIToolError("Sky Studio's catalog has no model to build the voice's MiniMax version. Nothing was charged.")
        }
        // 请求先拼好（拼不出来在记账之前就停），再问 / 记账。
        let request: SkyStudioJobRequest
        do { request = try SkyStudioVoiceRequests.enroll(voice: voice, language: language, model: model, maxCredits: credits) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message + " Nothing was charged.") }
        let account = SkyStudioCharacterAccess.stamp(key)
        let identity = SkyStudioVoiceLibraryJob.enrollIdentity(voice: voice, language: language, account: account)
        // 这个声音这种语言的 MiniMax 版已经在建（上一次点过头的那一单还没做完）：跟着它，不再问、不再预留。服务器对开着的建单本来就只回
        // 原来那一单、只扣一次；本机再预留一笔、再起一个任务跟它，同一笔钱就记成两笔（审查 #362 第 2 条）。
        if let open = SkyStudioVoiceLibraryJob.running(identity) { return .result(following(open, item: item, language: language)) }
        let action = SkyStudioVoiceApproval.oneTimeAction(item, account: account)
        let question = SkyStudioVoiceApproval.oneTimeQuestion(item, credits: credits, noFeeModel: noFee)
        let standing = SkyStudioVoiceStanding.shared
        let ask = await standing.voiceAsk(key: key, api: api)
        // 上面等了一下（读长期授权）：再看一眼有没有别的调用刚起了这一单。从这里到起任务之间没有 await。
        if let open = SkyStudioVoiceLibraryJob.running(identity) { return .result(following(open, item: item, language: language)) }
        switch try SkyStudioJobGate.voiceOneTime(credits: credits, action: action, question: question, token: input.confirmToken, ask: ask) {
        case .needsConfirmation(let result):
            return .result(asked(result, item: item, plan: plan, noFee: noFee))
        case .reserved(let reservation):
            let title = catalog.models.first { $0.id == model }?.title ?? "MiniMax"
            let enrolment = SkyStudioVoiceLibraryJob(
                kind: .voiceEnroll, identity: identity, request: request, key: key, reservation: reservation,
                title: SkyStudioVoicePick.languageName(language), modelTitle: title, project: project,
                nextStep: "The voice's MiniMax version is ready. Call add_voiceover again with the same lines and voice, without "
                    + "confirm_token: nothing was narrated yet, and Sky Studio now reads it with that version.",
                api: api
            )
            enrolment.onFailure = { _, credits in
                ["next_step": .string((credits.map { "Sky Studio's price changed to \(SkyStudioCredits.text($0)) credits and nothing was charged. " } ?? "")
                    + "The MiniMax version was not built and nothing was narrated. Call add_voiceover again with the same lines and voice: "
                    + "it quotes the current price and asks the user again (or pass skip_one_time=true). Never reuse the old confirm_token.")]
            }
            let job = enrolment.start()
            await standing.recordAfterApproval(ask, key: key, api: api)
            var result: [String: JSONValue] = [
                "status": "started", "job_id": .string(job.id), "kind": .string(AIJobs.Kind.voiceEnroll.rawValue), "provider": "Sky Studio",
                "credits": .number(credits), "one_time": .array([item.json]),
                "next_step": .string("Building the voice's MiniMax version for \(SkyStudioVoicePick.languageName(language)), a one-time fee. "
                    + "Wait with get_job; when it is done, call add_voiceover again with the same lines and voice (no confirm_token). "
                    + "Nothing was narrated yet, so this is not a resend.")
            ]
            if ask == .standing {
                result["full_access"] = .string("Full access: SkyCut built this without asking. Tell the user it builds the voice's MiniMax "
                    + "version for \(SkyStudioVoicePick.languageName(language)) for at most \(SkyStudioCredits.text(credits)) credits.")
                standing.notify(String(format: L10n("Full access: SkyCut is building a voice's MiniMax version (at most %@ credits)."),
                                       SkyStudioCredits.text(credits)), project: project)
            }
            return .result(.ok(.object(result)))
        }
    }

    /// 已经在建的那一单：回它的任务号，说清楚这一次没有新花钱、没有新问题。
    private static func following(_ job: AIJobs.Job, item: SkyStudioVoiceOneTime, language: String) -> AIToolResult {
        .ok([
            "status": "started", "job_id": .string(job.id), "kind": .string(AIJobs.Kind.voiceEnroll.rawValue), "provider": "Sky Studio",
            "already_building": true, "one_time": .array([item.json]),
            "next_step": .string("This voice's MiniMax version for \(SkyStudioVoicePick.languageName(language)) is already being built "
                + "(job \(job.id), approved earlier): nothing new was charged and there is nothing to ask. Wait for it with get_job; when "
                + "it is done, call add_voiceover again with the same lines and voice (no confirm_token). Nothing was narrated yet.")
        ])
    }

    /// 问句的结果里带上一次性费用和不建时用的那个，next_step 写清两条路。额度不够（daily_budget_exceeded）的原样回。
    private static func asked(_ result: AIToolResult, item: SkyStudioVoiceOneTime, plan: SkyStudioVoiceModelPlan?, noFee: String?) -> AIToolResult {
        guard case .object(var value) = result.payload, value["status"] == "needs_confirmation" else { return result }
        value["one_time"] = .array([item.json])
        if let plan { value["voice_plan"] = plan.json }
        var next = "Ask the user in their language, with the price: build the MiniMax version (repeat the same call with this "
            + "confirm_token)"
        next += noFee.map { ", or read now with \($0) without the fee (repeat the same call with skip_one_time=true)" } ?? ""
        value["next_step"] = .string(next + ". Never decide for the user.")
        var copy = result
        copy.payload = .object(value)
        return copy
    }
}

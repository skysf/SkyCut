import Foundation
import SrtFlowMCPKit

// MARK: - manage_voices design：按描述设计一个新声音（一次性费用）
//
// 管什么（SkyCut 声音方案 4.5、4.7）：核对描述（≤ 2,000 字）、名字（1–80）、可选的试读句（≤ 500）→ `POST /quote`（kind `voice_design`、
// `model: auto`：中文描述服务器用 MiniMax、别的用 Qwen3，SkyCut 不挑）→ 经 SkyStudioJobGate.voiceOneTime 把关（先判每日硬预算；
// 这一刀两种模式都问，问句写「约多少（最多多少）」，令牌绑描述、名字、试读句、精确积分）→ 点过头、记上账 → 起任务
// （SkyStudioVoiceLibraryJob，回任务号；做完 get_job 报新声音和 1 小时的样音链接）。设计失败服务器退款、不换模型（另一个也是一次性费用）。
// 声音满了（50 个）在报价时就回 409 `voice_limit`。
// 不管什么：用录音建声音（SkyStudioVoiceRecordingTool）、列出 / 改名 / 删除（SkyStudioVoiceLibraryTool）。

@MainActor
enum SkyStudioVoiceDesignTool {
    static let maxDescription = 2_000
    static let maxSampleText = 500

    static func run(_ args: AIToolArguments, _ project: VideoEditProject, services: SkyStudioVoiceServices) async throws -> AIToolResult {
        let description = try args.requiredString("description").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.unicodeScalars.count <= maxDescription else {
            throw AIToolError("description: describe the voice in 1 to \(maxDescription) characters.")
        }
        let sampleText = try args.string("sample_text").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let sampleText, sampleText.unicodeScalars.count > maxSampleText {
            throw AIToolError("sample_text is at most \(maxSampleText) characters.")
        }
        let draft: SkyStudioJobRequest
        do { draft = try SkyStudioVoiceRequests.design(description: description, name: try args.requiredString("name"), sampleText: sampleText) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message) }
        let name = draft.params["name"]?.stringValue ?? ""
        let key = try await services.key()
        let quote: SkyStudioQuote
        do { quote = try await services.api.quote(draft, key: key) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }
        let credits = quote.credits
        let action = SkyStudioVoiceApproval.designAction(description: description, name: name, sampleText: sampleText, credits: credits,
                                                         account: SkyStudioCharacterAccess.stamp(key))
        let question = SkyStudioVoiceApproval.designQuestion(name: name, credits: credits, expected: quote.creditsExpected)
        switch try SkyStudioJobGate.voiceOneTime(credits: credits, action: action, question: question, token: try args.string("confirm_token")) {
        case .needsConfirmation(let result):
            return priced(result, quote: quote)
        case .reserved(let reservation):
            var request = draft
            request.maxCredits = credits
            let job = SkyStudioVoiceLibraryJob(
                kind: .voiceDesign, request: request, key: key, reservation: reservation, title: name,
                modelTitle: quote.model ?? "Sky Studio", project: project,
                nextStep: "Tell the user the voice is ready and give them sample_url to listen to (valid one hour). Use voice=<voice.id> "
                    + "with add_voiceover.",
                api: services.api
            ).start()
            return .ok([
                "status": "started", "job_id": .string(job.id), "kind": .string(AIJobs.Kind.voiceDesign.rawValue), "provider": "Sky Studio",
                "credits": .number(credits),
                "next_step": "Designing the voice, a one-time fee. Wait with get_job; it reports the new voice and a sample_url to listen to."
            ])
        }
    }

    /// 问句的结果里带上报价（最多多少、大概多少）；额度不够的原样回。
    private static func priced(_ result: AIToolResult, quote: SkyStudioQuote) -> AIToolResult {
        guard case .object(var value) = result.payload, value["status"] == "needs_confirmation" else { return result }
        value["credits"] = .number(quote.credits)
        if let expected = quote.creditsExpected { value["credits_expected"] = .number(expected) }
        if let model = quote.model { value["model"] = .string(model) }
        var copy = result
        copy.payload = .object(value)
        return copy
    }
}

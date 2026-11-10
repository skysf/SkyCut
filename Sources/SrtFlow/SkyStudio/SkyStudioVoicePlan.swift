import Foundation
import SrtFlowMCPKit

// MARK: - 一段旁白怎么交给 Sky Studio：先分批、整段报一次价，再每批照报价交（纯值）
// 管什么（SkyCut 声音方案 4.2 第 2、5 步、8.1、8.4）：
// - `draft`：报价之前按 `/models` 的字数上限分批（这个 kind 下各模型里最小的那个：`model: auto` 时还不知道选哪个），拼整段报价的请求
//   （`params.batches`、语言提示，SkyStudioVoiceRequests.segmentQuote）。合不合批、交哪个 model 照 SkyStudioVoiceReading（声音 PR 5）：
//   这台 Mac 切得开、或者读的模型报字的时间就合批（普通旁白和克隆一样），切不开就一句一单；定下的那一份记进计划（恢复时照它）。
// - `quoted`：整段报价回来之后，每批的 `/jobs` 请求定下来、记进恢复记录：这一批的字、这一批报价的 credits 当 `max_credits`、
//   `model: auto` 时带回同一个 `params.plan`（`voice_plan.selection`：整段一个模型）、每批一个幂等 key。服务器的选择原样留着（`voicePlan`）报给 AI。
//   报价要一次性费用（建 MiniMax 版）的现在不交：那是声音 PR 6（按两种权限模式问 / 直接建）。
// 不管什么：Key、HTTP、预算、执行、切句、入轨；模型、价、上限一律不在本机抄。

struct SkyStudioVoicePlan: Sendable, Codable {
    struct Batch: Sendable, Codable {
        let speech: SkyStudioVoiceBatch
        /// 这一批交给 `/jobs` 的那一份（字、params、max_credits、幂等 key），报价之后就定了。
        var request: SkyStudioJobRequest
    }

    /// 报价之前：怎么分批、整段报价的请求。
    struct Draft: Sendable {
        let kind: String
        let voice: String
        let reading: SkyStudioVoiceReading
        let language: String
        let speech: [SkyStudioVoiceBatch]
        let segment: SkyStudioJobRequest
        var model: String { reading.model }
    }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `voice`（预设）或 `voice_clone`（声音库的声音）。
    let kind: String
    /// `params.voice`：`gemini:Charon` 这种预设 id，或 `voice_…`。
    let voice: String
    /// `auto` 或点名的模型。
    let model: String
    /// 稿子的主要语言（ISO 639-1）：分批的上限、本机转写都按它。
    let language: String
    /// 整段报价的请求原样（恢复补没生成的批次时照它再报一次价）。
    let segment: SkyStudioJobRequest
    /// 服务器为这一段选的模型，原样（`selection` 是每批 `params.plan` 带回的那一份）。
    let voicePlan: SkyStudioVoiceModelPlan
    var batches: [Batch]
    /// 报价之前定的怎么读、字幕时间从哪来（声音 PR 5 起记；之前的记录没有，恢复时照旧当转写得了）。
    var reading: SkyStudioVoiceReading?

    var clones: Bool { kind == SkyStudioVoiceKind.clone }

    /// 要不要在本机转写：服务器选的模型不报每个字的时间（`/models` 的 `output.words`），又有一批里几句要切开、或者要字幕而字幕的时间
    /// 定的是本机对齐（定的是估就不转写）。要的话在付费请求之前先确认这台 Mac 转写得了、模型没装先装（SkyStudioVoiceoverStart / Run）。
    func needsTranscription(subtitles: Bool, catalog: SkyStudioCatalog) -> Bool {
        let timed = voicePlan.model.flatMap { model in catalog.models.first { $0.id == model } }?.givesWordTimes == true
        guard !timed else { return false }
        return batches.contains { $0.speech.parts.count > 1 } || (subtitles && reading?.transcribes != false)
    }
    /// 每批最多多少积分（预算按它们的和整体预留）。
    var batchCredits: [Double] { batches.map { $0.request.maxCredits ?? 0 } }

    static func draft(lines: [String], kind: String, voice: String, reading: SkyStudioVoiceReading, language: String,
                      catalog: SkyStudioCatalog) throws -> Draft {
        guard !lines.isEmpty, lines.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Problem(message: "Give at least one non-empty voiceover line.")
        }
        guard SkyStudioVoiceKind.reading.contains(kind) else { throw Problem(message: "Sky Studio reads lines only with narration or cloned voices.") }
        guard let cap = catalog.voiceCharacterLimit(kind: kind, language: language), cap >= 1 else {
            throw Problem(message: "Sky Studio did not give a character limit for \(language) voices.")
        }
        let speech = try SkyStudioVoiceBatch.make(lines: lines, limit: cap, pack: reading.packs)
        let model = reading.model
        let segment = try SkyStudioVoiceRequests.segmentQuote(kind: kind, model: model, voice: voice, batches: speech.map(\.prompt), lines: lines)
        return Draft(kind: kind, voice: voice, reading: reading, language: language, speech: speech, segment: segment)
    }

    /// 整段报价回来：核对（有 voice_plan、批数对得上），每批的请求照报价定下来。报价里的一次性费用先由 SkyStudioVoiceOneTimeStep 问过：
    /// `skippingOneTime` = 用户不建 MiniMax 版、照报价里不花钱的那个读（`default_needs_one_time` 时 selection 就是它）；别的一律不交。
    static func quoted(_ draft: Draft, quote: SkyStudioQuote, skippingOneTime: Bool = false) throws -> SkyStudioVoicePlan {
        guard let voice = quote.voice, let plan = voice.plan, voice.batches.count == draft.speech.count else {
            throw Problem(message: "Sky Studio's quote did not cover this script's batches; nothing was charged. Try again.")
        }
        guard voice.oneTime.isEmpty || (skippingOneTime && plan.needsOneTime) else {
            let kinds = voice.oneTime.map(\.kind).joined(separator: ", ")
            throw Problem(message: "Sky Studio asked for a one-time fee (\(kinds)) before this voice can read with this model; "
                + "nothing was charged. Use model=auto, or approve the fee first.")
        }
        let batches = try draft.speech.indices.map { index in
            Batch(speech: draft.speech[index], request: try SkyStudioVoiceRequests.batch(index, of: draft.segment, quote: quote))
        }
        return SkyStudioVoicePlan(kind: draft.kind, voice: draft.voice, model: draft.model, language: draft.language,
                                  segment: draft.segment, voicePlan: plan, batches: batches, reading: draft.reading)
    }
}

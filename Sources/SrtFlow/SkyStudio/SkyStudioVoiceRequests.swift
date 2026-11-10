import Foundation
import SrtFlowMCPKit

// MARK: - 声音的几种活怎么交给 Sky Studio（纯值）
//
// 管什么：拼 `/quote`、`/jobs` 的请求（SkyStudioJobRequest），名字照 Sky Studio 声音方案文末的「名字对照」：
// - **读稿（`voice` 预设 / `voice_clone` 声音库）整段报一次价**：`params.batches` 代替 prompt（一批一个字符串），服务器按整段算
//   语言占比、选一个模型，回 voice_plan（约定第 1 条）。**每一批 `/jobs`**：prompt 是这一批的字、`max_credits` 用这一批报价的 `credits`、
//   `params.plan` 原样带回 `voice_plan.selection`（中途换了备用就带 `voice_plan.fallback.selection`）。
//   **点名的模型每批照样点名、也带 plan**，`plan.model` 必须就是点名的那个：克隆靠它整段用同一段参考（不然服务器按每批自己的字挑参考），
//   读稿靠它定住声音；点名的出错不自动换（Sky Studio `shared/voiceSelection.ts` 的 planVoiceNarration / planVoiceClone）。
// - 语言提示 `params.language`（SkyStudioVoiceLanguageHint）：只在拉丁字母的那些句子判得出、而且不是英文时才带；
//   中文、日文、韩文服务器自己分得清，英文是服务器的默认，都不带（SkyCut 声音方案 4.2 第 2 步、13.2 第 4 条）。
// - 建 MiniMax 版（`voice_enroll`）、设计声音（`voice_design`）、视频变声（`voice_convert`）：同一个请求先 `/quote`、再 `/jobs`。
// - 两个新上传用途：参考录音 `voice_reference`（VoiceReferenceSample.uploadPurpose）、变声素材 `voice_convert_source`（SkyStudioVoiceUpload），
//   各 ≤ 35 MB（十进制，上限在 SkyStudioVoiceUpload）。
// 拼错了（没有字、声音的 id 不像样、批数和报价对不上）在发出去之前就拦下：一分不花、不碰服务器。
// 不管什么：分批（SkyStudioVoicePlan）、问不问用户（SkyStudioJobGate）、交和等（SkyStudioJobRun）、模型从哪个记录里挑（调用方读 `/models`）。

/// 声音的几种活（`kind`）。
enum SkyStudioVoiceKind {
    /// 普通旁白：预设声音（`gemini:<名字>` / `eleven:<名字>`）。
    static let narration = "voice"
    /// 克隆读稿：声音库里的声音（`voice_…`）。
    static let clone = "voice_clone"
    /// 给某种语言建 MiniMax 版（一次性费用）。
    static let enroll = "voice_enroll"
    /// 设计一个新声音（一次性费用）。
    static let design = "voice_design"
    /// 视频变声：分离出人声换成另一个声音，人声和背景分两个文件回来。
    static let convert = "voice_convert"
    /// 读稿的两种：整段报价、按批交。
    static let reading: Set<String> = [narration, clone]
}

/// 声音的两种上传（`POST /uploads` 的 `purpose`）：参考录音的 `voice_reference` 只写在 `VoiceReferenceSample.uploadPurpose`
/// （参考录音那一摊，docs/architecture/voice-library.md），这里是变声素材的用途和两种共用的上限。服务器按十进制 35,000,000 字节卡；
/// SkyCut 按单声道传，3 分钟参考约 16 MB、5 分钟变声素材约 27 MB。立体声在上限以内服务器也收（转单声道）。
enum SkyStudioVoiceUpload {
    /// 变声的源音频：WAV / MP3 / FLAC（分离模型只认这三种），≤ 5 分钟。
    static let conversionSourcePurpose = "voice_convert_source"
    /// 两种声音上传共用的上限（十进制 35 MB）。
    static let maxBytes = 35_000_000

    /// 传之前先看大小：超了就不传（服务器同样会拒，`upload_too_large`）。
    static func fits(bytes: Int) -> Bool { bytes > 0 && bytes <= maxBytes }
}

/// 读稿时要不要带 `params.language`。
enum SkyStudioVoiceLanguageHint {
    /// 拉丁字母的那些句子一起判主要语言；判得出、不是英文才给（ISO 639-1 两个字母，`es`、`de`、`fr`…），别的都是 nil。
    static func hint(for lines: [String]) -> String? {
        let latin = lines.filter(isLatin)
        guard !latin.isEmpty, let tag = AITextLanguage.dominant(in: latin) else { return nil }
        let code = String(tag.lowercased().prefix { $0 != "-" && $0 != "_" })
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }), code != "en" else { return nil }
        return code
    }

    /// 一句话里有字母、而且字母全是拉丁字母（带重音的、越南文的都算）。有一个汉字 / 假名 / 谚文 / 别的文字就交给服务器自己判。
    static func isLatin(_ line: String) -> Bool {
        var sawLetter = false
        for scalar in line.unicodeScalars where scalar.properties.isAlphabetic {
            guard latinLetters.contains(where: { $0.contains(scalar.value) }) else { return false }
            sawLetter = true
        }
        return sawLetter
    }

    /// 基本拉丁、西文序数（ª º）、Latin-1 补充、扩展 A / B、越南文用的扩展附加。
    private static let latinLetters: [ClosedRange<UInt32>] = [0x41...0x5A, 0x61...0x7A, 0xAA...0xAA, 0xBA...0xBA, 0xC0...0x24F, 0x1E00...0x1EFF]
}

enum SkyStudioVoiceRequests {
    /// 交给服务器选模型。
    static let autoModel = "auto"

    /// 读稿整段报一次价：`params.batches` 代替 prompt；语言提示照 `lines`（原来那几句）判。
    /// `plan`：恢复时补没生成的批次，照整段当初的选择（`voice_plan.selection`）再报价，服务器不重新选模型（SkyCut 声音方案 8.4）。
    static func segmentQuote(kind: String, model: String = autoModel, voice: String, batches: [String], lines: [String],
                             plan: [String: JSONValue]? = nil) throws -> SkyStudioJobRequest {
        guard SkyStudioVoiceKind.reading.contains(kind) else { throw problem("Only narration and cloned reading are quoted as a whole segment.") }
        try checkReadingVoice(voice, kind: kind)
        let model = try checkedModel(model)
        guard !batches.isEmpty, batches.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw problem("Give at least one non-empty batch of words.")
        }
        var params: [String: JSONValue] = ["voice": .string(voice), "batches": .array(batches.map(JSONValue.string))]
        if let language = SkyStudioVoiceLanguageHint.hint(for: lines) { params["language"] = .string(language) }
        if let plan {
            guard plan["model"]?.stringValue?.isEmpty == false else { throw problem("A plan to quote again needs the model it was quoted with.") }
            params["plan"] = .object(plan)
        }
        return SkyStudioJobRequest(kind: kind, model: model, params: params)
    }

    /// 整段报价之后交第 `index` 批（从 0 起）：这一批的字、`params.plan` 原样（不给就用报价的 `voice_plan.selection`）、这一批报价的
    /// `credits` 当 `max_credits`；`kind`、`model`、`voice`、语言提示照整段报价的。点名的模型也带 plan（克隆靠它整段用同一段参考、
    /// 读稿靠它定住声音），但 `plan.model` 必须就是点名的那个（服务器同样卡），换模型就是另一次决定：重新报价。
    static func batch(
        _ index: Int, of segment: SkyStudioJobRequest, quote: SkyStudioQuote, plan: [String: JSONValue]? = nil,
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) throws -> SkyStudioJobRequest {
        guard SkyStudioVoiceKind.reading.contains(segment.kind), let texts = segment.params["batches"]?.arrayValue?.compactMap(\.stringValue),
              texts.indices.contains(index) else { throw problem("That batch is not part of the quoted segment.") }
        guard let voice = quote.voice, voice.batches.count == texts.count else {
            throw problem("Sky Studio's quote does not list the same batches; quote the segment again.")
        }
        guard let selection = plan ?? voice.plan?.selection, let planModel = selection["model"]?.stringValue, !planModel.isEmpty else {
            throw problem("Sky Studio's quote has no voice plan to reuse.")
        }
        guard segment.model == autoModel || planModel == segment.model else {
            throw problem("A named model reads every batch itself; to use another model, quote the segment again.")
        }
        var params = segment.params
        params["batches"] = nil
        params["plan"] = .object(selection)
        return SkyStudioJobRequest(kind: segment.kind, model: segment.model, prompt: texts[index], params: params,
                                   maxCredits: voice.batches[index].credits, idempotencyKey: idempotencyKey)
    }

    /// 给 `voice` 的 `language` 建 MiniMax 版（模型从 `/models` 的 `voice_enroll` 记录挑；那条记录 `accepts_auto: false`，要点名）。
    static func enroll(
        voice: String, language: String, model: String, maxCredits: Double? = nil, idempotencyKey: String = UUID().uuidString.lowercased()
    ) throws -> SkyStudioJobRequest {
        guard SkyStudioVoice.isVoiceID(voice) else { throw problem("Use a voice id from the user's voice library (voice_…).") }
        guard model != autoModel else { throw problem("Name the enrolment model from Sky Studio's catalog; it does not take auto.") }
        let language = try SkyStudioVoiceNaming.checkedLanguage(language)
        return SkyStudioJobRequest(kind: SkyStudioVoiceKind.enroll, model: try checkedModel(model),
                                   params: ["voice": .string(voice), "language": .string(language)],
                                   maxCredits: maxCredits, idempotencyKey: idempotencyKey)
    }

    /// 按描述设计一个新声音：描述的语言决定用哪个模型（服务器选，`auto`）；可选的试读句。
    static func design(
        description: String, name: String, sampleText: String? = nil, language: String? = nil, model: String = autoModel,
        maxCredits: Double? = nil, idempotencyKey: String = UUID().uuidString.lowercased()
    ) throws -> SkyStudioJobRequest {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw problem("Describe the voice to design.") }
        var params: [String: JSONValue] = ["name": .string(try SkyStudioVoiceNaming.checked(name))]
        if let sample = sampleText?.trimmingCharacters(in: .whitespacesAndNewlines), !sample.isEmpty { params["sample_text"] = .string(sample) }
        if let language { params["language"] = .string(try SkyStudioVoiceNaming.checkedLanguage(language)) }
        return SkyStudioJobRequest(kind: SkyStudioVoiceKind.design, model: try checkedModel(model), prompt: description, params: params,
                                   maxCredits: maxCredits, idempotencyKey: idempotencyKey)
    }

    /// 把一段的人声换成 `targetVoice`（声音库的 `voice_…` 或预设 `gemini:<名字>`）。`sourceSeconds` 只用来报价（服务器自己再量一遍
    /// 上传的文件）；报价时还没传，`sourceAudioURL` 给 nil，传完再交 `/jobs`。`targetLanguage`：知道这段说什么语言、目标声音又有
    /// 这种语言的参考时才给（SkyCut 声音方案 4.8）。
    static func convert(
        targetVoice: String, sourceSeconds: Double, sourceAudioURL: URL? = nil, targetLanguage: String? = nil, model: String = autoModel,
        maxCredits: Double? = nil, idempotencyKey: String = UUID().uuidString.lowercased()
    ) throws -> SkyStudioJobRequest {
        guard SkyStudioVoice.isVoiceID(targetVoice) || isPreset(targetVoice, prefix: "gemini:") else {
            throw problem("Change the voice to a library voice (voice_…) or a preset (gemini:Name).")
        }
        guard sourceSeconds.isFinite, sourceSeconds > 0 else { throw problem("The clip has no sound to re-voice.") }
        var params: [String: JSONValue] = [
            "target_voice": .string(targetVoice), "source": ["seconds": .number((sourceSeconds * 1000).rounded() / 1000)]
        ]
        if let targetLanguage { params["target_language"] = .string(try SkyStudioVoiceNaming.checkedLanguage(targetLanguage)) }
        var inputs: [String: String] = [:]
        if let sourceAudioURL { inputs["source_audio_url"] = sourceAudioURL.absoluteString }
        return SkyStudioJobRequest(kind: SkyStudioVoiceKind.convert, model: try checkedModel(model), inputs: inputs, params: params,
                                   maxCredits: maxCredits, idempotencyKey: idempotencyKey)
    }

    // MARK: 核对

    /// 读稿的声音：普通旁白只认预设 id（`gemini:*`、`eleven:*`），克隆只认声音库的 `voice_…`。
    private static func checkReadingVoice(_ voice: String, kind: String) throws {
        if kind == SkyStudioVoiceKind.clone {
            guard SkyStudioVoice.isVoiceID(voice) else { throw problem("Cloned reading needs a library voice id (voice_…).") }
        } else {
            guard isPreset(voice, prefix: "gemini:") || isPreset(voice, prefix: "eleven:") else {
                throw problem("Narration needs a preset voice id such as gemini:Charon or eleven:Daniel.")
            }
        }
    }

    private static func isPreset(_ voice: String, prefix: String) -> Bool {
        voice.hasPrefix(prefix) && voice.count > prefix.count && !voice.contains(where: \.isWhitespace)
    }

    private static func checkedModel(_ model: String) throws -> String {
        guard !model.isEmpty, !model.contains(where: \.isWhitespace) else { throw problem("Name a model id from Sky Studio's catalog, or auto.") }
        return model
    }

    private static func problem(_ message: String) -> SkyStudioVoiceRequestProblem { SkyStudioVoiceRequestProblem(message: message) }
}

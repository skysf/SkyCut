import Foundation
import SrtFlowMCPKit

// MARK: - 声音任务做完回来的东西，和声音这几样的错误码（纯值）
//
// 管什么（Sky Studio 声音方案 5.3、5.6）：
// - 读稿 / 克隆的结果照旧有 `url`（SkyStudioJobResult），另带「实际怎么做的」（SkyStudioVoiceOutcome）：实际跑的 `model`、
//   有没有自动换备用（`fallback_used`）、整段的 `voice_plan`。结果要说清楚用了哪个模型（决定第三节第 1 条）。
// - 三种没有 `url` 的结果（SkyStudioVoiceJobResult）：变声回两个文件（变声后的人声 `voice_url`、分离出来的背景 `background_url`，
//   混音在 SkyCut 里做，约定第 4 条）；建 MiniMax 版回更新后的声音；设计回新声音 + 一段样音的临时链接。
// - 错误码（SkyStudioVoiceCodes）：界面和 AI 按它说人话（声音 PR 6）；这里只认得、读得出附加字段。
// 读得严：少了必须的（变声少一个文件、声音的 id 不像 Sky Studio 的）就不算结果（SkyStudioJobRun 当「做完了却没有成品」）。
// 不管什么：下载、入轨、撤销（声音 PR 9）；怎么跟用户说（声音 PR 6）。

/// 读稿 / 克隆 / 变声做完时服务器报的「实际怎么做的」。
struct SkyStudioVoiceOutcome: Equatable, Sendable {
    /// 实际跑的模型（报价时写 `auto` 的话，这里是服务器选的那个）。
    var model: String?
    /// 默认出错、服务器在这一单里自动换了备用（只换一次）。
    var fallbackUsed: Bool
    var plan: SkyStudioVoiceModelPlan?

    /// 没有 `fallback_used`、也没有 `voice_plan` 就是 nil（不是声音任务）：只带一个 `model` 的结果别的活也可能有，不算。
    init?(json: JSONValue) {
        let plan = SkyStudioVoiceModelPlan(json: json["voice_plan"])
        let fallback = json["fallback_used"]?.boolValue
        guard plan != nil || fallback != nil else { return nil }
        model = json["model"]?.stringValue
        fallbackUsed = fallback ?? false
        self.plan = plan
    }
}

/// 变声的两个文件（人声已在结尾补静音补到源音频那么长；长了不裁）。成品地址 60 天，不带 Key。
struct SkyStudioVoiceConversion: Equatable, Sendable {
    var voiceURL: URL
    var backgroundURL: URL
    var contentType: String?
    var sampleRate: Double?
    var channels: Int?
    var duration: Double?
    var sourceDuration: Double?
    var paddedSeconds: Double?
    var expiresAt: Date?

    init?(json: JSONValue) {
        guard let voice = Self.link(json["voice_url"]), let background = Self.link(json["background_url"]) else { return nil }
        voiceURL = voice
        backgroundURL = background
        contentType = json["content_type"]?.stringValue
        sampleRate = json["sample_rate"]?.doubleValue
        channels = json["channels"]?.intValue
        duration = json["duration"]?.doubleValue
        sourceDuration = json["source_duration"]?.doubleValue
        paddedSeconds = json["padded_seconds"]?.doubleValue
        expiresAt = json["expires_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate)
    }

    private static func link(_ value: JSONValue?) -> URL? {
        guard let text = value?.stringValue, let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }
}

/// 没有 `url` 的三种结果。
enum SkyStudioVoiceJobResult: Equatable, Sendable {
    /// `voice_convert`。
    case conversion(SkyStudioVoiceConversion)
    /// `voice_enroll`（这种语言 `minimax: true` 了）、`voice_design`（新声音，带一段样音的 1 小时临时链接）。
    case voice(SkyStudioVoice, sampleURL: URL?)

    /// 认不出来（或者少了必须的）就是 nil。
    init?(json: JSONValue) {
        if json["voice_url"] != nil || json["background_url"] != nil {
            guard let conversion = SkyStudioVoiceConversion(json: json) else { return nil }
            self = .conversion(conversion)
        } else if let voice = json["voice"], voice.objectValue != nil {
            guard let parsed = try? SkyStudioVoice(json: voice) else { return nil }
            self = .voice(parsed, sampleURL: SkyStudioLinks.webURL(json["sample_url"]?.stringValue))
        } else {
            return nil
        }
    }
}

/// 声音这几样新的错误码（Sky Studio 声音方案 5.6）。服务器的 `message` 照旧原样给人看；这里只是认得出是哪一种。
enum SkyStudioVoiceCodes {
    /// 409：点名的模型（或带回的 plan）要的 MiniMax 版还没建；附 `one_time`。不扣钱。
    static let oneTimeRequired = "one_time_required"
    /// 409：声音数到上限（50）；附 `limit`。
    static let voiceLimit = "voice_limit"
    /// 409：这种语言已经有录音（v1 想换只能删了重建）；附 `language`。
    static let referenceExists = "reference_exists"
    /// 409：这种语言已经有 MiniMax 版；附 `language`。不扣钱。
    static let minimaxVoiceExists = "minimax_voice_exists"
    /// 503：Sky Studio 的私有声音桶没配（声音库暂时用不了，预设旁白照常）。
    static let libraryUnavailable = "voice_library_unavailable"
    /// 任务结束码：默认失败、备用要先花一次性费用；附 `one_time`、`refunded`。
    static let fallbackNeedsOneTime = "fallback_needs_one_time"

    /// `invalid_request` 的 `reason`（附 `limit`、`field`；`unsupported_language` 另附 `language`）。
    enum Reason {
        static let tooLong = "too_long"
        static let tooLittleSpeech = "too_little_speech"
        static let unsupportedLanguage = "unsupported_language"
        static let consentRequired = "consent_required"
        static let noStandingGrant = "no_standing_grant"
        static let consentOutdated = "consent_outdated"
        static let uploadTooLarge = "upload_too_large"
    }
}

extension SkyStudioServerError {
    /// 409 `one_time_required` 等附带的一次性费用；没有、读不出来都是空的。
    var voiceOneTime: [SkyStudioVoiceOneTime] { SkyStudioVoiceOneTime.list(fields["one_time"]) ?? [] }
}

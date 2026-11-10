import Foundation
import SrtFlowMCPKit

// MARK: - 声音任务的报价：服务器选了哪个模型（voice_plan）、每批多少、一次性费用（纯值）
//
// 管什么：`POST /quote` 回答里声音那几样（Sky Studio 声音方案 5.4），`/jobs` 的 202、`GET /jobs/{id}` 和任务结果里也带 voice_plan：
// - `voice_plan`（SkyStudioVoiceModelPlan）：**选模型在服务器**（约定第 1 条）。`selection` 是选定的那一个（读稿：`model` + `voice`；
//   克隆：`model` + `reference_language`），一段旁白分几批时每批 `/jobs` 的 `params.plan` **原样带回它**（整段一个模型，中途不换）；
//   `rule` / `reason` / 各语言占比 / `cross_language` / `warnings` / `fallback` 原样报给 AI（`reason` 是英文，界面按 `rule` 本地化）。
// - `batches`：带 `params.batches` 报价时每批的 `credits`（作这一批的 `max_credits`）、`credits_expected`、字数。
// - `one_time`（SkyStudioVoiceOneTime）：一次性费用（建 MiniMax 版、设计声音），**单独列出来、先问再花**（约定第 2 条）。
//   同样的条目也出现在 409 `one_time_required` 和任务结束码 `fallback_needs_one_time` 的附加字段里。
// 读得严：和钱有关的（顶层 `one_time` 的每一笔和它的价、每批的积分）少一样、不像样，整份报价就不算回答 —— 不能悄悄丢掉一笔一次性费用。
// 别的读得宽：认不出的 `rule`、`warnings` 原样留着；备用要的那一笔（`fallback.one_time`，服务器给一项或 null、可能不带价）只是说明，读不出来当没有。
// 不管什么：问不问用户（SkyStudioJobGate，声音 PR 6 / 7）、怎么分批（声音 PR 3）、`/quote` 整份的 credits（SkyStudioQuote）。

/// 一次性费用：建 MiniMax 版（`voice_enroll`）或设计声音（`voice_design`）。
struct SkyStudioVoiceOneTime: Equatable, Sendable, Codable {
    var kind: String
    var model: String?
    var voice: String?
    var language: String?
    /// 这一笔的积分（交的时候当 `max_credits`）。`/quote` 顶层的 `one_time` 必须有（SkyStudioVoiceQuote 核对）；
    /// 备用要的那一笔（`voice_plan.fallback.one_time`）、409 / 任务结束码带的那一笔可能只说要建哪种语言的 MiniMax 版、不带价。
    var credits: Double?
    /// 为什么要花（一句英文）。
    var why: String?
    /// 建了以后会改用什么、大概多少钱（原样）。
    var then: JSONValue?

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue, !kind.isEmpty else { return nil }
        if let value = json["credits"], !value.isNull {
            guard let credits = value.doubleValue, credits.isFinite, credits >= 0 else { return nil }
            self.credits = credits
        }
        self.kind = kind
        model = json["model"]?.stringValue
        voice = json["voice"]?.stringValue
        language = json["language"]?.stringValue
        why = json["why"]?.stringValue
        if let then = json["then"], !then.isNull { self.then = then }
    }

    /// 没有 / null 是空的；一项（对象）或一串（数组）都认 —— 服务器的备用和 409 只带一项；有一项读不出来是 nil。
    static func list(_ value: JSONValue?) -> [SkyStudioVoiceOneTime]? {
        guard let value, !value.isNull else { return [] }
        if value.objectValue != nil { return SkyStudioVoiceOneTime(json: value).map { [$0] } }
        guard let items = value.arrayValue else { return nil }
        let parsed = items.compactMap(SkyStudioVoiceOneTime.init(json:))
        return parsed.count == items.count ? parsed : nil
    }

    var json: JSONValue {
        var value: [String: JSONValue] = ["kind": .string(kind)]
        if let credits { value["credits"] = .number(credits) }
        if let model { value["model"] = .string(model) }
        if let voice { value["voice"] = .string(voice) }
        if let language { value["language"] = .string(language) }
        if let why { value["why"] = .string(why) }
        if let then { value["then"] = then }
        return .object(value)
    }
}

/// 服务器为这一段选的模型（`voice_plan`）。
struct SkyStudioVoiceModelPlan: Equatable, Sendable, Codable {
    /// 默认要的 MiniMax 版还没建：`selection` 先给不花一次性费用的那个，`one_time` 里列建它要多少（Sky Studio 方案 5.2 ④）。
    static let defaultNeedsOneTime = "default_needs_one_time"
    /// `warnings` 里的几种（SkyCut 照 4.3、4.4 转告）。
    static let notListedForLanguage = "not_listed_for_language"
    static let modelNotTestedForLanguage = "model_not_tested_for_language"
    static let targetLanguageUnavailable = "target_language_unavailable"

    /// 一种语言占多少（按估的读出来的秒数算）。
    struct Share: Equatable, Sendable, Codable {
        var language: String
        var share: Double
        var seconds: Double?
    }

    /// 出错时换哪个：`selection` 原样（中途换了备用后，后面的批 `params.plan` 带它）、能不能用、会不会自动换、要不要先花一次性费用。
    struct Fallback: Equatable, Sendable, Codable {
        var selection: [String: JSONValue]?
        var available: Bool
        var auto: Bool
        var oneTime: [SkyStudioVoiceOneTime]
    }

    /// 选定的那一个，原样（`params.plan` 原样带回它）。
    var selection: [String: JSONValue]
    var requestedModel: String?
    var rule: String?
    var languages: [Share]
    var reason: String?
    var crossLanguage: Bool
    var warnings: [String]
    var fallback: Fallback?
    /// 整个 voice_plan 原样：报给 AI 用（服务器保证里面没有任何服务商 id）。
    var json: JSONValue

    var model: String? { selection["model"]?.stringValue }
    var voice: String? { selection["voice"]?.stringValue }
    var referenceLanguage: String? { selection["reference_language"]?.stringValue }
    var needsOneTime: Bool { rule == Self.defaultNeedsOneTime }

    /// 不是对象、或者没有一个像样的 `selection`（至少要有 `model`）就是 nil。
    init?(json: JSONValue?) {
        guard let json, let root = json.objectValue, let selection = root["selection"]?.objectValue,
              let model = selection["model"]?.stringValue, !model.isEmpty else { return nil }
        self.selection = selection
        self.json = json
        requestedModel = root["requested_model"]?.stringValue
        rule = root["rule"]?.stringValue
        reason = root["reason"]?.stringValue
        crossLanguage = root["cross_language"]?.boolValue ?? false
        warnings = root["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        languages = (root["languages"]?.arrayValue ?? []).compactMap { entry in
            guard let language = entry["language"]?.stringValue, let share = entry["share"]?.doubleValue else { return nil }
            return Share(language: language, share: share, seconds: entry["seconds"]?.doubleValue)
        }
        // 备用要的一次性费用只是告诉人「换过去之前得先建」：读不出来就当没有，不拖累整份报价（真要建的时候另有报价）。
        if let fallback = root["fallback"]?.objectValue {
            self.fallback = Fallback(
                selection: fallback["selection"]?.objectValue, available: fallback["available"]?.boolValue ?? false,
                auto: fallback["auto"]?.boolValue ?? false, oneTime: SkyStudioVoiceOneTime.list(fallback["one_time"]) ?? []
            )
        }
    }
}

/// 带 `params.batches` 报价时的一批。
struct SkyStudioVoiceBatchQuote: Equatable, Sendable, Codable {
    /// 这一批最多多少积分：交这一批时当 `max_credits`。
    var credits: Double
    var creditsExpected: Double?
    /// 字数（Unicode code point）。
    var characters: Int?
}

/// `/quote` 回答里声音的那几样（读稿、克隆、建 MiniMax 版、设计、变声都可能有）。
struct SkyStudioVoiceQuote: Equatable, Sendable, Codable {
    var plan: SkyStudioVoiceModelPlan?
    var batches: [SkyStudioVoiceBatchQuote]
    var oneTime: [SkyStudioVoiceOneTime]

    /// 回答里有没有声音的这几样（没有就不是声音的报价，SkyStudioQuote 不读它）。
    static func isPresent(in json: JSONValue) -> Bool {
        ["voice_plan", "batches", "one_time"].contains { json[$0].map { !$0.isNull } ?? false }
    }

    /// 有声音的这几样、但和钱有关的读不出来：nil（整份报价不算回答）。
    init?(json: JSONValue) {
        if let plan = json["voice_plan"], !plan.isNull {
            guard let parsed = SkyStudioVoiceModelPlan(json: plan) else { return nil }
            self.plan = parsed
        }
        // 要先问用户、要当 max_credits 交的那几笔：每一笔都得有价。
        guard let oneTime = SkyStudioVoiceOneTime.list(json["one_time"]), oneTime.allSatisfy({ $0.credits != nil }) else { return nil }
        self.oneTime = oneTime
        batches = []
        if let value = json["batches"], !value.isNull {
            guard let items = value.arrayValue else { return nil }
            for item in items {
                guard let credits = item["credits"]?.doubleValue, credits.isFinite, credits >= 0 else { return nil }
                batches.append(SkyStudioVoiceBatchQuote(
                    credits: credits, creditsExpected: item["credits_expected"]?.doubleValue, characters: item["characters"]?.intValue
                ))
            }
        }
    }
}

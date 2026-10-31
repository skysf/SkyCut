import Foundation
import SrtFlowMCPKit

// MARK: - 交给 Sky Studio 的一件活：请求体、报价、任务此刻怎样、成品（纯值）
//
// 管什么：`/quote`、`/jobs` 要发的那一份（kind、model、prompt、inputs、params；`/jobs` 另带 max_credits 和 idempotency_key），
// 回来的报价（credits、typical_seconds、upscale 的 plan），任务此刻怎样（status、phase、排队位置、隔多久再问、扣了多少、成品），
// 取消的结果。读得宽：认不出的字段不管、少了可选的不算错；少了必须的（报价没有 credits、任务没有 job_id、做完没有成品地址）就不算回答。
// 合同：Sky Studio 仓库 docs/agents/skycut-api.md「POST /quote」「POST /jobs」「GET /jobs/{id}」「POST /jobs/{id}/cancel」「Per kind」
// （2026-10-28 上线，从 Sky Studio main 的 5c8d6a0d 起冻结）。
// 不管什么：发请求（SkyStudioAPI）、等它做完（SkyStudioJobRun）、每种活怎么拼参数（upscale、生成、配旁白各自的调用方）。

struct SkyStudioJobRequest: Equatable, Sendable {
    /// `upscale`、`image`、`text_to_video`、`image_to_video`、`lipsync`、`music`、`voice`、`sound_effect`、`voice_clone`。
    var kind: String
    /// Sky Studio 自己的模型名（`/models` 的 id），不是 fal 的端点号。
    var model: String
    var prompt: String?
    /// `video_url`、`image_url`、`reference_audio_url`：自己 `/uploads` 上去的文件，或 Sky Studio 的素材。
    var inputs: [String: String]
    var references: [JSONValue]
    var params: [String: JSONValue]
    /// 用户同意过的上限（`/quote` 报的那个数）：服务器算出来更贵就回 `price_changed`、一分不扣。
    var maxCredits: Double?
    /// 每个账号唯一：服务器按同一个 key 去重。客户端只在明确 too_many_jobs 时等着再交，未知提交保留 key、不自动重放。
    var idempotencyKey: String

    init(
        kind: String, model: String, prompt: String? = nil, inputs: [String: String] = [:], params: [String: JSONValue] = [:],
        maxCredits: Double? = nil, idempotencyKey: String = UUID().uuidString.lowercased(), references: [JSONValue] = []
    ) {
        self.kind = kind
        self.model = model
        self.prompt = prompt
        self.inputs = inputs
        self.references = references
        self.params = params
        self.maxCredits = maxCredits
        self.idempotencyKey = idempotencyKey
    }

    /// `/quote` 的请求体：`/jobs` 的那一份去掉 inputs、max_credits、idempotency_key。
    var quoteBody: JSONValue {
        var body: [String: JSONValue] = ["kind": .string(kind), "model": .string(model), "params": .object(params)]
        if let prompt { body["prompt"] = .string(prompt) }
        return .object(body)
    }

    /// `/jobs` 的请求体。
    var jobBody: JSONValue {
        guard case .object(var body) = quoteBody else { return quoteBody }
        var allInputs = inputs.mapValues { JSONValue.string($0) }
        if !references.isEmpty { allInputs["references"] = .array(references) }
        body["inputs"] = .object(allInputs)
        body["idempotency_key"] = .string(idempotencyKey)
        if let maxCredits { body["max_credits"] = .number(maxCredits) }
        return .object(body)
    }
}

/// `/quote` 的回答：要扣多少（和 `/jobs` 扣钱用同一个计价函数）、通常多久做完；upscale 另有 `plan`（倍数、输出尺寸、按哪一档收）。
struct SkyStudioQuote: Equatable, Sendable {
    var credits: Double
    var typicalSeconds: Double?
    var plan: [String: JSONValue]

    init(credits: Double, typicalSeconds: Double? = nil, plan: [String: JSONValue] = [:]) {
        self.credits = credits
        self.typicalSeconds = typicalSeconds
        self.plan = plan
    }

    init?(json: JSONValue) {
        guard let credits = json["credits"]?.doubleValue else { return nil }
        self.init(credits: credits, typicalSeconds: json["typical_seconds"]?.doubleValue, plan: json["plan"]?.objectValue ?? [:])
    }
}

/// 一个任务此刻怎样（`POST /jobs` 的 202 和 `GET /jobs/{id}` 都读成它）。
struct SkyStudioJobStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case queued, running, done, failed, cancelled
    }

    var jobID: String
    /// nil = 这个 SkyCut 不认识的词（当成回的不像话）。
    var state: State?
    /// `queued` / `processing` / `saving`（存进 Sky Studio 的作品库）。下载是 SkyCut 自己的阶段。
    var phase: String?
    var queuePosition: Int?
    var phaseSeconds: Double?
    var typicalSeconds: Double?
    /// 隔多久再问（没有长轮询）。
    var pollAfterSeconds: Double?
    var creditsReserved: Double?
    var creditsCharged: Double?
    var result: SkyStudioJobResult?
    /// 没做成时服务器说的话。
    var error: String?
    var failure: SkyStudioJobFailure?
    var billing: SkyStudioBilling?
    var generationStatus: String?
    var deliveryStatus: String?

    var isFinished: Bool { state == .done || state == .failed || state == .cancelled }

    init(jobID: String, state: State?) {
        self.jobID = jobID
        self.state = state
    }

    init?(json: JSONValue) {
        guard let id = json["job_id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(jobID: id, state: json["status"]?.stringValue.flatMap(State.init(rawValue:)))
        phase = json["phase"]?.stringValue
        queuePosition = json["queue_position"]?.intValue
        phaseSeconds = json["phase_seconds"]?.doubleValue
        typicalSeconds = json["typical_seconds"]?.doubleValue
        pollAfterSeconds = json["poll_after_seconds"]?.doubleValue
        creditsReserved = json["credits_reserved"]?.doubleValue
        creditsCharged = json["credits_charged"]?.doubleValue
        billing = SkyStudioBilling(json["billing"])
        generationStatus = json["generation_status"]?.stringValue
        deliveryStatus = json["delivery_status"]?.stringValue
        if let result = json["result"], !result.isNull { self.result = SkyStudioJobResult(json: result) }
        error = Self.errorText(json["error"])
        if let error { failure = SkyStudioJobFailure(message: error, fields: json["error"]?.objectValue ?? [:], jobID: id) }
        if state == .failed || state == .cancelled, failure == nil { failure = SkyStudioJobFailure(message: "Sky Studio job \(state?.rawValue ?? "failed").", jobID: id) }
        failure?.billing = billing
    }

    /// `error` 可能是一句话，也可能是 `{"code", "message"}`。
    private static func errorText(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        return value["message"]?.stringValue ?? value["code"]?.stringValue ?? value.encodedString()
    }
}

/// 做完的成品。作品库里的那几种（upscale、图片、视频、音乐、旁白、音效）地址永久有效、只有用户自己删；克隆的声音不进作品库，带 `expires_at`（60 天）。
/// 宽高、时长、帧率服务器没记的是 nil（MiniMax H3 的视频不记像素和帧率）：用的时候从文件里读。
struct SkyStudioJobResult: Equatable, Sendable {
    var url: URL
    var generationID: String?
    var contentType: String?
    var width: Double?
    var height: Double?
    var duration: Double?
    var fps: Double?
    var expiresAt: Date?
    /// 旁白：Eleven v4 的 timestamps 原样（按字符给的开始 / 结束时间，不是按词）。
    var words: JSONValue?
    var captionFile: URL?
    var captionStatus: String?
    var captionRetryAfterSeconds: Double?
    var metadata: [String: JSONValue]

    init?(json: JSONValue) {
        guard let text = json["url"]?.stringValue, let url = URL(string: text), url.scheme != nil else { return nil }
        self.url = url
        metadata = json.objectValue ?? [:]
        generationID = json["generation_id"]?.stringValue
        contentType = json["content_type"]?.stringValue
        width = json["width"]?.doubleValue
        height = json["height"]?.doubleValue
        duration = json["duration"]?.doubleValue
        fps = json["fps"]?.doubleValue
        expiresAt = json["expires_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate)
        if let words = json["words"], !words.isNull { self.words = words }
        captionFile = (json["caption_file"]?.stringValue ?? json["caption_file"]?["url"]?.stringValue).flatMap(URL.init(string:))
        captionStatus = json["caption_status"]?.stringValue
        captionRetryAfterSeconds = json["caption_retry_after_seconds"]?.doubleValue
    }
}

/// `POST /jobs/{id}/cancel` 的结果。只有排着队的能取消。
enum SkyStudioCancel: Equatable, Sendable {
    /// 取消了，积分退回（`credits_refunded`）。
    case cancelled(refunded: Double?)
    /// 已经开始（或已经结束）：取消不了，`status` 是它此刻的状态。
    case notCancellable(status: String?)
}

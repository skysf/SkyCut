import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio 声音库：用户自己的声音、授权（纯值）
//
// 管什么：`/voices` 回来的声音长什么样（SkyStudioVoice）、一页声音、长期授权的状态（SkyStudioVoiceConsentState），
// 以及发出去的两种请求体：用一段录音新建声音（SkyStudioVoiceCreation）、给已有的声音加一种语言的录音（SkyStudioVoiceReference）。
// 规矩（约定第 2、3 条，Sky Studio 声音方案 3.3–3.5）：
// - **SkyCut 只认 Sky Studio 自己发的 id**：`voice_` + 32 位十六进制。服务商那边的 id（MiniMax 的 voice_id）永远不出服务器：
//   DTO 里没有这种字段，`languages[].minimax` 只是「这种语言有没有 MiniMax 版」的布尔值；回答里就算多了别的字段也不留着（不存原始 JSON）。
// - 用录音建声音、加录音都要授权：这一次的确认（`consent: true` + 可选的文案版本）或打开全部权限时记的长期授权
//   （`consent: "standing_grant"`）。服务器自己卡、自己记回执，SkyCut 只负责问到了再发。
// - 试听链接是 1 小时的临时链接（`preview_expires_at`），过期就重取，不存。
// 读得宽：认不出的字段不管；少了 id / 名字、id 不像 Sky Studio 的就不算回答（`SkyStudioFailure.badAnswer`）。
// 不管什么：发请求（SkyStudioVoiceAPI）、问不问用户（声音 PR 6 / 7）、录音怎么截（VoiceReferenceSample）。

/// 声音库里的一个声音（`GET /voices/{id}` 的 `voice`）。
struct SkyStudioVoice: Equatable, Sendable {
    /// 这个声音在一种语言里的那段参考（录音或设计样音）。
    struct Language: Equatable, Sendable {
        /// ISO 639-1（`zh`、`en`、`ja`…）。每种语言最多一段。
        var language: String
        /// `recording` / `design_sample` / `import`。
        var kind: String
        var seconds: Double?
        /// 这种语言有没有 MiniMax 版（第一次用到时才建，一次性费用）。**是布尔，不是 id。**
        var minimax: Bool
        /// 试听用的临时链接（1 小时）。
        var previewURL: URL?
        var previewExpiresAt: Date?
    }

    /// 设计出来的声音：描述、用的模型、描述的语言。
    struct Design: Equatable, Sendable {
        var prompt: String?
        var model: String?
        var language: String?
    }

    var id: String
    var name: String
    /// `recording` / `design` / `import`。
    var source: String
    /// `personal`（v1 只有个人的）。
    var scope: String?
    /// 预留给团队，v1 永远是 nil。
    var teamID: String?
    var languages: [Language]
    var design: Design?
    var createdAt: Date?
    var updatedAt: Date?

    /// `voice_` + 32 位十六进制（uuid 去掉横线）。只当一节路径用，别的样子一律不认。
    static func isVoiceID(_ text: String) -> Bool {
        guard text.hasPrefix("voice_") else { return false }
        let hex = text.unicodeScalars.dropFirst(6)
        return hex.count == 32 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    init(json: JSONValue) throws {
        guard let id = json["id"]?.stringValue, Self.isVoiceID(id), let name = json["name"]?.stringValue, !name.isEmpty else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        self.id = id
        self.name = name
        source = json["source"]?.stringValue ?? "recording"
        scope = json["scope"]?.stringValue
        teamID = json["team_id"]?.stringValue
        languages = (json["languages"]?.arrayValue ?? []).compactMap { entry in
            guard let language = entry["language"]?.stringValue, !language.isEmpty else { return nil }
            return Language(
                language: language, kind: entry["kind"]?.stringValue ?? "recording", seconds: entry["seconds"]?.doubleValue,
                minimax: entry["minimax"]?.boolValue ?? false, previewURL: SkyStudioLinks.webURL(entry["preview_url"]?.stringValue),
                previewExpiresAt: entry["preview_expires_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate)
            )
        }
        if let design = json["design"], design.objectValue != nil {
            self.design = Design(prompt: design["prompt"]?.stringValue, model: design["model"]?.stringValue, language: design["language"]?.stringValue)
        }
        createdAt = json["created_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate)
        updatedAt = json["updated_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate)
    }

    /// 这种语言的那一段；没有就是 nil。
    func language(_ code: String) -> Language? { languages.first { $0.language == code } }

    /// 报给 AI / 界面的样子：只有上面这些字段（没有任何服务商 id）；试听链接是临时的，不报。
    var json: JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "source": .string(source),
            "languages": .array(languages.map { entry in
                var item: [String: JSONValue] = ["language": .string(entry.language), "kind": .string(entry.kind), "minimax": .bool(entry.minimax)]
                if let seconds = entry.seconds { item["seconds"] = .number(seconds) }
                return .object(item)
            })
        ]
        if let design {
            var item: [String: JSONValue] = [:]
            if let prompt = design.prompt { item["prompt"] = .string(prompt) }
            if let model = design.model { item["model"] = .string(model) }
            if let language = design.language { item["language"] = .string(language) }
            value["design"] = .object(item)
        }
        return .object(value)
    }
}

/// `GET /voices` 的一页（每个账号最多 50 个声音，一页回完）。
struct SkyStudioVoicePage: Equatable, Sendable {
    var voices: [SkyStudioVoice]
    var nextCursor: String?
}

/// 这个账号的长期授权（`GET /voices/consent-grant`）。`active` 已经把「文案版本过期」算进去了。
struct SkyStudioVoiceConsentGrant: Equatable, Sendable {
    var statementVersion: String
    var grantedAt: Date?
    var active: Bool
    /// 不有效的原因：`outdated`（文案升了版本）……
    var inactiveReason: String?
}

struct SkyStudioVoiceConsentState: Equatable, Sendable {
    /// nil = 没记过或已撤销。
    var grant: SkyStudioVoiceConsentGrant?
    var currentStatementVersion: String?

    /// 全部权限下能不能带 `consent: "standing_grant"`：只在有一条有效的长期授权时。
    var hasActiveGrant: Bool { grant?.active == true }

    init(grant: SkyStudioVoiceConsentGrant?, currentStatementVersion: String?) {
        self.grant = grant
        self.currentStatementVersion = currentStatementVersion
    }

    init(json: JSONValue) throws {
        guard let root = json.objectValue else { throw SkyStudioFailure.badAnswer(status: 200) }
        currentStatementVersion = root["current_statement_version"]?.stringValue
        guard let grant = root["grant"], !grant.isNull else { return }
        guard let version = grant["statement_version"]?.stringValue, !version.isEmpty, let active = grant["active"]?.boolValue else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        self.grant = SkyStudioVoiceConsentGrant(
            statementVersion: version, grantedAt: grant["granted_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate),
            active: active, inactiveReason: grant["inactive_reason"]?.stringValue
        )
    }
}

// MARK: - 发出去的请求体

/// 用录音建声音 / 加一种语言的录音时的授权。
enum SkyStudioVoiceConsent: Equatable, Sendable {
    /// 这一次的确认（请求批准模式的对话框 / 确认码）：`consent: true`，带上问的那句的版本号（不带 = 当前版本）。
    case thisRecording(statementVersion: String?)
    /// 引用打开全部权限时记的长期授权：`consent: "standing_grant"`（只在这个账号有有效的长期授权时用）。
    case standingGrant

    var fields: [String: JSONValue] {
        switch self {
        case .thisRecording(let version):
            var fields: [String: JSONValue] = ["consent": true]
            if let version, !version.isEmpty { fields["consent_statement_version"] = .string(version) }
            return fields
        case .standingGrant:
            return ["consent": "standing_grant"]
        }
    }
}

/// SkyCut 从源文件里用了哪一段（服务器存进参考的 `source_range`，回执里不存）。
struct SkyStudioVoiceReferenceSource: Equatable, Sendable {
    var filename: String
    var start: Double?
    var end: Double?
    /// 是 SkyCut 自动挑的那 3 分钟（源文件超过 3 分钟时）。
    var autoSelected: Bool

    var json: JSONValue {
        var value: [String: JSONValue] = ["filename": .string(filename), "auto_selected": .bool(autoSelected)]
        if let start { value["start"] = .number(start) }
        if let end { value["end"] = .number(end) }
        return .object(value)
    }
}

/// 请求体里的毛病：在发出去之前就拦下（一分不花、不碰服务器）。
struct SkyStudioVoiceRequestProblem: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum SkyStudioVoiceNaming {
    /// 声音名 1–80 个字（按 UTF-16 数，和服务器的 JS 同一个数法；角色名也是这么数的）。
    static let maximumUTF16 = 80

    static func checked(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkyStudioVoiceRequestProblem(message: "Give the voice a name.") }
        guard trimmed.utf16.count <= maximumUTF16 else {
            throw SkyStudioVoiceRequestProblem(message: "A voice name is at most \(maximumUTF16) characters.")
        }
        return trimmed
    }

    /// ISO 639-1（两个小写字母），没有 639-1 的用 639-3（三个）。
    static func checkedLanguage(_ language: String) throws -> String {
        let code = language.trimmingCharacters(in: .whitespaces)
        guard (2...3).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isLowercase }) else {
            throw SkyStudioVoiceRequestProblem(message: "Give the recording's language as an ISO 639-1 code, like zh or en.")
        }
        return code
    }
}

/// `POST /voices`：用一段录音新建声音（免费；MiniMax 版第一次用到时再建）。
struct SkyStudioVoiceCreation: Equatable, Sendable {
    var name: String
    var language: String
    /// `/uploads` purpose `voice_reference` 回的 `file_url`。
    var referenceURL: URL
    var source: SkyStudioVoiceReferenceSource?
    var consent: SkyStudioVoiceConsent
    /// 同一个 key 重发回同一个声音，不重复建。
    var idempotencyKey: String

    init(name: String, language: String, referenceURL: URL, source: SkyStudioVoiceReferenceSource? = nil,
         consent: SkyStudioVoiceConsent, idempotencyKey: String = UUID().uuidString.lowercased()) throws {
        self.name = try SkyStudioVoiceNaming.checked(name)
        self.language = try SkyStudioVoiceNaming.checkedLanguage(language)
        self.referenceURL = referenceURL
        self.source = source
        self.consent = consent
        self.idempotencyKey = idempotencyKey
    }

    var body: JSONValue {
        var fields = consent.fields
        fields["name"] = .string(name)
        fields["language"] = .string(language)
        fields["reference_url"] = .string(referenceURL.absoluteString)
        fields["idempotency_key"] = .string(idempotencyKey)
        if let source { fields["source"] = source.json }
        return .object(fields)
    }
}

/// `POST /voices/{id}/references`：给已有的声音加一种语言的录音（这种语言已经有了回 409 `reference_exists`）。
struct SkyStudioVoiceReference: Equatable, Sendable {
    var language: String
    var referenceURL: URL
    var source: SkyStudioVoiceReferenceSource?
    var consent: SkyStudioVoiceConsent

    init(language: String, referenceURL: URL, source: SkyStudioVoiceReferenceSource? = nil, consent: SkyStudioVoiceConsent) throws {
        self.language = try SkyStudioVoiceNaming.checkedLanguage(language)
        self.referenceURL = referenceURL
        self.source = source
        self.consent = consent
    }

    var body: JSONValue {
        var fields = consent.fields
        fields["language"] = .string(language)
        fields["reference_url"] = .string(referenceURL.absoluteString)
        if let source { fields["source"] = source.json }
        return .object(fields)
    }
}

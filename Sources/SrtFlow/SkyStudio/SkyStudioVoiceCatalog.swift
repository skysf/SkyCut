import Foundation
import SrtFlowMCPKit

// MARK: - `GET /models` 里声音的那一部分（纯值）
//
// 管什么：Sky Studio 在 `/models` 顶层多给的四样（Sky Studio 声音方案 4.1），和声音模型记录上 SkyCut 要读的几个数：
// - `voice_presets`：预设声音（现在是 Gemini 的 30 个，`gemini:<名字>`）。**属性按语言分开**：同一个声音中英文可能是两个人
//   （Gacrux 中文男声、英文女声），所以性别、说明、打分、在不在名单里、样音都挂在 `languages[<语言>]` 下；别的语言照
//   `other_languages`（现在是 `en`）用那种语言的那一套。藏起来的（两种语言都 `listed: false`）点名照样能用，只是不推荐。
// - `voice_roles`：SkyCut 的 8 个 AI 角色 → 预设 id，平的 `{角色: 预设 id}`。角色表只在服务器放一份，SkyCut 不再写死。
// - `voice_rules`：只给人看的选模型说明，**SkyCut 不照着算**（用哪个模型只认 `/quote` 回的 voice_plan），原样留着。
// - `voice_consent`：两句授权文案（这一次的 `per_recording` / 长期的 `standing`）的当前版本和英文原文；界面显示本地化文字，
//   交的时候带版本号（SkyStudioVoiceConsent）。
// - 模型记录上：一次性费用的记录（`one_time: true`）和它的价目（`price.typical_credits`，打开全部权限时列给用户看）、
//   支持哪些语言（`languages`：`eleven-v4` 的 94 种、Qwen3 设计的 10 种）、报价前分批用的字数上限
//   （`limits.max_characters_by_language`，其余语言是 `other`；同一个 kind 取最小的那个）。
// 从哪读：SkyStudioCatalog 把这四样原样留在 `voiceSection`，`catalog.voices` 现读成这里的类型（只用模型目录的地方不用编这个文件）。
// 读得宽：认不出的字段不管；少了 id 的预设跳过；整块没有就是 nil（服务器还没上声音的那一版）。
// 不管什么：认 AI 给的声音名、本机退档（声音 PR 3）；选模型（服务器）；价（`/quote`）；用户自己的声音（SkyStudioVoice）。
// 合同：SkyCut 声音方案第三节「SkyCut 需要 Sky Studio 接口提供的东西」、Sky Studio 声音方案 4.1、5.3、5.4；测试数据
// `checks/SkyStudio/Fixtures/models-voice-*.json`（从 Sky Studio 的 buildSkycutModelCatalog() 导出）。

/// 一个预设声音。
struct SkyStudioVoicePreset: Equatable, Sendable {
    /// 这个声音在某一种语言里的样子。
    struct Entry: Equatable, Sendable {
        /// 这种语言的名单里显示不显示。藏起来的点名照样能用。
        var listed: Bool
        /// `male` / `female` / `unknown`（听不出来，比如 Despina）。**按这次读的语言报**，同一个声音两种语言可能不一样。
        var gender: String?
        /// 用户打的分（1–5）；没打分是 nil。
        var rating: Int?
        /// 说明：`zh` 给中文界面，`en` 给 AI、英文和西语界面。
        var description: [String: String]
        /// 这种语言的样音（公开地址，永久不变）。
        var sampleURL: URL?

        init(listed: Bool, gender: String? = nil, rating: Int? = nil, description: [String: String] = [:], sampleURL: URL? = nil) {
            self.listed = listed
            self.gender = gender
            self.rating = rating
            self.description = description
            self.sampleURL = sampleURL
        }

        init?(json: JSONValue) {
            guard let listed = json["listed"]?.boolValue else { return nil }
            var description: [String: String] = [:]
            for (language, text) in json["description"]?.objectValue ?? [:] {
                if let text = text.stringValue, !text.isEmpty { description[language] = text }
            }
            self.init(listed: listed, gender: json["gender"]?.stringValue, rating: json["rating"]?.intValue, description: description,
                      sampleURL: SkyStudioLinks.webURL(json["sample_url"]?.stringValue))
        }
    }

    /// 服务器自己的备用：Gemini 出错时换 Eleven v4 的哪个声音（SkyCut 只报给人看，换不换是服务器的事）。
    struct Fallback: Equatable, Sendable {
        var model: String
        var voice: String
    }

    /// `gemini:Charon` 这样的 id：交给 `/quote`、`/jobs` 的 `params.voice` 就是它。
    var id: String
    var name: String
    var model: String?
    var isDefault: Bool
    var officialStyle: String?
    /// 语言（ISO 639-1）→ 那种语言的样子。
    var languages: [String: Entry]
    /// 别的语言用哪种语言的那一套（现在是 `en`）。
    var otherLanguages: String?
    var fallback: Fallback?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? Self.bareName(id)
        model = json["model"]?.stringValue
        isDefault = json["default"]?.boolValue ?? false
        officialStyle = json["official_style"]?.stringValue
        var languages: [String: Entry] = [:]
        for (language, value) in json["languages"]?.objectValue ?? [:] {
            if let entry = Entry(json: value) { languages[language] = entry }
        }
        self.languages = languages
        otherLanguages = json["other_languages"]?.stringValue
        if let model = json["fallback"]?["model"]?.stringValue, let voice = json["fallback"]?["voice"]?.stringValue {
            fallback = Fallback(model: model, voice: voice)
        }
    }

    /// 这种语言用哪一套：自己有就用自己的，没有就照 `other_languages`（「其他语言先沿用英文名单」，决定第四节）。
    func entry(for language: String) -> Entry? {
        if let own = languages[language] { return own }
        return otherLanguages.flatMap { languages[$0] }
    }

    /// `gemini:Charon` → `Charon`。
    static func bareName(_ id: String) -> String {
        id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
    }
}

/// 一句授权文案：版本号 + 英文原文（服务器存原文，SkyCut 显示本地化文字、交的时候带版本号）。
struct SkyStudioVoiceConsentStatement: Equatable, Sendable {
    var version: String
    var statement: String

    init?(json: JSONValue?) {
        guard let version = json?["version"]?.stringValue, !version.isEmpty,
              let statement = json?["statement"]?.stringValue, !statement.isEmpty else { return nil }
        self.version = version
        self.statement = statement
    }
}

/// `/models` 顶层声音的那四样。
struct SkyStudioVoiceCatalog: Equatable, Sendable {
    var presets: [SkyStudioVoicePreset]
    /// 角色名 → 预设 id。
    var roles: [String: String]
    /// 只给人看，SkyCut 不照着算。
    var rules: JSONValue?
    /// 用录音建声音时「这一次」的那句（`consent: true` 时带它的版本）。
    var perRecordingConsent: SkyStudioVoiceConsentStatement?
    /// 打开全部权限时记的长期授权那句（`POST /voices/consent-grant` 带它的版本）。
    var standingConsent: SkyStudioVoiceConsentStatement?

    /// 根对象；没有 `voice_presets` 数组 = 这个服务器还没上声音（nil）。
    init?(json: JSONValue) {
        guard let entries = json["voice_presets"]?.arrayValue else { return nil }
        presets = entries.compactMap(SkyStudioVoicePreset.init(json:))
        var roles: [String: String] = [:]
        for (role, preset) in json["voice_roles"]?.objectValue ?? [:] {
            if let preset = preset.stringValue, !preset.isEmpty { roles[role] = preset }
        }
        self.roles = roles
        rules = json["voice_rules"]
        perRecordingConsent = SkyStudioVoiceConsentStatement(json: json["voice_consent"]?["per_recording"])
        standingConsent = SkyStudioVoiceConsentStatement(json: json["voice_consent"]?["standing"])
    }

    /// 按 id 找（`gemini:Charon`，大小写照服务器写的）。
    func preset(_ id: String) -> SkyStudioVoicePreset? { presets.first { $0.id == id } }

    /// 默认声音（现在是 Charon）。**每次请求都明确写它**，不靠服务商的默认。
    var defaultPreset: SkyStudioVoicePreset? { presets.first(where: \.isDefault) }

    /// 这种语言的名单：`listed` 的，按打分高到低、同分按名字（没打分的排在有分的后面）。
    func listed(language: String) -> [SkyStudioVoicePreset] {
        presets.filter { $0.entry(for: language)?.listed == true }.sorted { left, right in
            let a = left.entry(for: language)?.rating ?? 0
            let b = right.entry(for: language)?.rating ?? 0
            return a != b ? a > b : left.name < right.name
        }
    }

    /// 角色对应的预设；角色不在表里、或指向一个不存在的预设都是 nil。
    func rolePreset(_ role: String) -> SkyStudioVoicePreset? { roles[role].flatMap(preset) }
}

// MARK: - 声音模型记录上的几个数

extension SkyStudioModel {
    /// 一次性费用这类记录的「大概多少」（`price.typical_credits`）：打开全部权限时的价目从这里读，SkyCut 不写死。
    var typicalCredits: Double? { price["typical_credits"]?.doubleValue }

    /// 这个模型支持哪些语言（`eleven-v4` 的 94 种；ISO 639-1，没有 639-1 的用 639-3）；没列就是 nil（不知道，不是「都不支持」）。
    var supportedLanguages: [String]? { metadata["languages"]?.arrayValue?.compactMap(\.stringValue) }

    /// 一次请求最多多少字（Unicode code point）：先找这种语言，没有就用 `other`（其余语言）那一项；都没写是 nil。
    func characterLimit(language: String) -> Int? {
        let table = limits["max_characters_by_language"]
        return (table?[language] ?? table?["other"])?.intValue
    }

    /// 一次性费用的那几条记录（建 MiniMax 版、设计声音：`one_time: true`）：打开全部权限时的价目照它挑，不写死 id。
    var isOneTime: Bool { metadata["one_time"]?.boolValue == true }

    /// 读稿的模型报不报每个字什么时候说（`output.words`：Eleven v4 报、Gemini / 克隆的几个不报）；没写是 nil（不知道，当不报）。
    /// 不报的要字幕、要把一批切成几句就得在本机转写（SkyStudioVoiceoverStart、SkyCut 声音方案第七节）。
    var givesWordTimes: Bool? { metadata["output"]?["words"]?.boolValue }
}

extension SkyStudioCatalog {
    /// 顶层的预设声音、角色、授权文案；服务器还没上声音时是 nil。每次现读（30 个预设，很便宜），要多次用就留一份。
    var voices: SkyStudioVoiceCatalog? { SkyStudioVoiceCatalog(json: .object(voiceSection)) }

    /// 报价之前分批用的字数上限：这个 kind 下各模型里最小的那个（`model: auto` 时还不知道选哪个；Sky Studio 保证同一个 kind
    /// 新加的模型不低于现在这一组，SkyCut 声音方案 8.1、13.3 第 7 条）。这个 kind 没有一个模型写了上限就是 nil。
    func voiceCharacterLimit(kind: String, language: String) -> Int? {
        models(kind: kind).compactMap { $0.characterLimit(language: language) }.min()
    }
}

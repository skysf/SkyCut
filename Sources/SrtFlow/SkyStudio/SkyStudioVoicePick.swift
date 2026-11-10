import Foundation

// MARK: - add_voiceover 的 voice 在 Sky Studio 上是谁（纯值）
//
// 管什么：SkyCut 声音方案 4.3 认声音的那张表。分两步：
// 1. `ask`：读 `/models` 之前，光看 AI 写的字就分得出来的 —— 没给（默认预设）、8 个角色之一、`gemini:<名字>`、`eleven:<名字>`、
//    不带前缀的名字（可能是预设的名字，不是的话再当这台 Mac 的声音找）；Kokoro 的音色名（`af_heart` 这种）是 nil：本机的声音，不走云端。
// 2. `resolve`：读到 `/models` 的预设和角色之后，换成交给 `params.voice` 的预设 id，外加要告诉 AI 的话（英式男声读非英文）。
//    角色 → 预设只认服务器给的 `voice_roles`，默认声音只认 `default: true` 的那个预设（SkyCut 不写死）。
// 本机退档（没 Key、报价时服务不可用）用哪个角色也在这里（`localRole`）：没给 = 旁白角色（中文 zh_male、英文 en_male）、角色照旧、
// 预设按它在这种语言里的性别挑角色、Eleven 的照旧退到旁白。
// 声音库的 `voice_…`（声音 PR 6）光看字就认得出（`voice_` + 32 位十六进制）：原样交给 `params.voice`，读稿的 kind 是 `voice_clone`；
// 它没有本机退档（4.3：声音库的声音报错、不退本机）。
// 不管什么：本机怎么挑 Kokoro / Mac 的声音（AIVoiceChoice）、读 Key 和目录（SkyStudioVoiceoverStart）。

/// AI 要 Sky Studio 的哪个声音（读目录之前）。
enum SkyStudioVoiceAsk: Equatable, Sendable {
    /// 没给：目录里的默认预设（现在是 gemini:Charon）。
    case standard
    case role(AIVoiceRole)
    /// `gemini:<名字>`。
    case preset(String)
    /// `eleven:<名字>`（Eleven v4 的声音，原样交给服务器）。
    case eleven(String)
    /// 不带前缀的名字：先当预设的名字找，不是的话当这台 Mac 的声音（4.3 的顺序：预设在本机声音之前）。
    case name(String)
    /// 用户声音库里的声音（`voice_…`，list_voices 的 mine）：克隆读稿，不退本机。
    case library(String)

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }

    /// 读稿交给 Sky Studio 的 kind：声音库的是克隆读稿，别的都是普通旁白（预设）。
    var kind: String { isLibrary ? SkyStudioVoiceKind.clone : SkyStudioVoiceKind.narration }
}

/// 认出来的 Sky Studio 声音。
struct SkyStudioVoicePick: Equatable, Sendable {
    /// 交给 `params.voice` 的 id。
    var voice: String
    /// 要随 voice.note 告诉 AI 的话（没有就是空的）。
    var notes: [String] = []

    enum Resolution: Equatable, Sendable {
        case cloud(SkyStudioVoicePick)
        /// 目录里没有这个预设：不带前缀的名字交给本机按名字找（Mac 的声音），`gemini:` / 写坏的 `eleven:` 直接报错。
        case notPreset(String)
        /// 目录里少了这一项（没有默认预设、角色不在 voice_roles 里）：当成 Sky Studio 这次用不了，退本机。
        case incomplete(String)
    }

    /// 读目录之前先分类；nil = Kokoro 的音色名（本机的声音）。
    static func ask(_ requested: String?) -> SkyStudioVoiceAsk? {
        guard let text = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .standard }
        if let role = AIVoiceRole.named(text) { return .role(role) }
        let lower = text.lowercased()
        if lower.hasPrefix("gemini:") { return .preset(text) }
        if lower.hasPrefix("eleven:") { return .eleven(text) }
        if AIVoiceRole.isKokoroName(text) { return nil }
        if SkyStudioVoice.isVoiceID(text) { return .library(text) }
        return .name(text)
    }

    /// 换成预设 id。`language` 是稿子的主要语言（ISO 639-1）。
    static func resolve(_ ask: SkyStudioVoiceAsk, in catalog: SkyStudioVoiceCatalog, language: String) -> Resolution {
        switch ask {
        case .standard:
            guard let preset = catalog.defaultPreset else { return .incomplete("Sky Studio's catalog names no default voice.") }
            return .cloud(SkyStudioVoicePick(voice: preset.id))
        case .role(let role):
            return pick(role: role, in: catalog, language: language)
        case .preset(let id), .name(let id):
            guard let preset = preset(named: id, in: catalog) else { return .notPreset(id) }
            return .cloud(SkyStudioVoicePick(voice: preset.id))
        case .eleven(let id):
            let name = String(id.dropFirst("eleven:".count))
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return .notPreset(id) }
            return .cloud(SkyStudioVoicePick(voice: "eleven:" + name))
        case .library(let id):
            return .cloud(SkyStudioVoicePick(voice: id))
        }
    }

    /// 角色 → 预设（只认 voice_roles）。英式男声只读英文：别的语言改用那种语言的旁白角色（没有就用默认预设），并说一声（4.3）。
    private static func pick(role: AIVoiceRole, in catalog: SkyStudioVoiceCatalog, language: String) -> Resolution {
        if role.style == .british, role.gender == .male, language != "en" {
            let stand = AIVoiceRole.narrator(forLanguage: language).flatMap { catalog.rolePreset($0.name) } ?? catalog.defaultPreset
            guard let stand else { return .incomplete("Sky Studio's catalog names no default voice.") }
            let note = "\(role.name) only reads English, so \(stand.id) read this \(languageName(language)) text instead."
            return .cloud(SkyStudioVoicePick(voice: stand.id, notes: [note]))
        }
        guard let preset = catalog.rolePreset(role.name) else {
            return .incomplete("Sky Studio's catalog has no voice for the role \(role.name).")
        }
        return .cloud(SkyStudioVoicePick(voice: preset.id))
    }

    /// 按 id 或不带前缀的名字找预设，大小写不计较（`gemini:charon`、`Charon` 都是 gemini:Charon）。
    static func preset(named raw: String, in catalog: SkyStudioVoiceCatalog) -> SkyStudioVoicePreset? {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.presets.first { $0.id.lowercased() == wanted }
            ?? catalog.presets.first { SkyStudioVoicePreset.bareName($0.id).lowercased() == wanted }
    }

    /// 本机退档用哪个角色（nil = 按语言用默认的那个本机声音）。`catalog` 读不到时预设的性别不知道，按旁白算。
    static func localRole(for ask: SkyStudioVoiceAsk, catalog: SkyStudioVoiceCatalog?, language: String) -> AIVoiceRole? {
        switch ask {
        case .role(let role):
            return role
        case .preset(let id), .name(let id):
            let gender = catalog.flatMap { preset(named: id, in: $0) }?.entry(for: language)?.gender
            return gender.flatMap { AIVoiceRole.role(gender: $0, language: language) } ?? AIVoiceRole.narrator(forLanguage: language)
        case .standard, .eleven:
            return AIVoiceRole.narrator(forLanguage: language)
        case .library:
            // 声音库的声音不退本机（调用方在退之前就报错）；真走到这里也只给旁白角色。
            return AIVoiceRole.narrator(forLanguage: language)
        }
    }

    /// 报错时列给 AI 的预设名（这种语言名单里的，按打分高到低）。
    static func listedNames(in catalog: SkyStudioVoiceCatalog, language: String) -> String {
        catalog.listed(language: language).map(\.id).joined(separator: ", ")
    }

    /// 语言代码在给 AI 的话里写成英文名（zh → Chinese）。
    static func languageName(_ language: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
    }
}

import Foundation
import SrtFlowMCPKit

// MARK: - list_voices 回什么（纯值）
//
// 管什么（SkyCut 声音方案 4.6）：预设名单（一种语言 `listed` 的、按打分高到低：id、gender、英文的 description、默认的那个标出来）和
// 「我的声音」（`GET /voices` 的每一个，原样只有 SkyStudioVoice.json 那几样，没有任何服务商 id）。
// 一种语言没有自己的名单时照 `other_languages`（现在是英文那份，决定第四节），并在回答里说清 `list_language`。
// 同一个预设中英文的性别、说明可能不一样（Gacrux 中文是男声、英文是女声），所以只报这种语言的那一套。
// 不管什么：读 Key / 目录 / 声音库（SkyStudioVoiceLibraryTool）、声音库用不了时怎么说（SkyStudioVoiceLibraryErrors）。

enum SkyStudioVoiceListing {
    /// 一种语言的预设名单。
    static func presets(_ catalog: SkyStudioVoiceCatalog, language: String) -> JSONValue {
        let ownList = catalog.presets.contains { $0.languages[language] != nil }
        let listLanguage = ownList ? language : (catalog.presets.compactMap(\.otherLanguages).first ?? "en")
        let voices = catalog.listed(language: language).map { preset -> JSONValue in
            let entry = preset.entry(for: language)
            var item: [String: JSONValue] = ["id": .string(preset.id)]
            if let gender = entry?.gender { item["gender"] = .string(gender) }
            if let text = entry?.description["en"] { item["description"] = .string(text) }
            if preset.isDefault { item["default"] = true }
            return .object(item)
        }
        var value: [String: JSONValue] = ["language": .string(language), "voices": .array(voices)]
        if listLanguage != language {
            value["list_language"] = .string(listLanguage)
            value["note"] = .string("Sky Studio has no \(SkyStudioVoicePick.languageName(language)) list yet, so these are its "
                + "\(SkyStudioVoicePick.languageName(listLanguage)) descriptions; any of them can read \(SkyStudioVoicePick.languageName(language)).")
        }
        return .object(value)
    }

    /// 我的声音（每个账号最多 50 个，一页回完）。
    static func mine(_ page: SkyStudioVoicePage) -> JSONValue {
        .array(page.voices.map(\.json))
    }
}

import Foundation

// MARK: - 声音选择器里列什么（纯值）
//
// 管什么（SkyCut 声音方案 5.2）：一排语言（中文 / English / 其他语言）下的三组——我的声音（用录音建的）、设计的声音、预设声音。
// 预设只列这种语言里 `listed` 的、按打分高到低同分按名字（SkyStudioVoiceCatalog.listed，和 list_voices 同一份名单）；
// 性别、说明、样音都取**这种语言**的那一套（同一个预设中英文可能是两个人）；「其他语言」照 `other_languages`（现在是英文那份）。
// 说明按界面语言挑：中文界面用 `zh`，英文、西语界面用 `en`。默认的那个（Charon）标出来。默认选哪一排：中文界面中文，其余 English。
// 我的声音试听哪种语言的录音：这一排的语言有就用它，没有用第一段。
// 不管什么：怎么画（VoicePickerView）、试听（VoiceAudition）、声音库怎么取（VoiceLibraryStore）。

/// 选择器上面那一排语言。
enum VoicePickerTab: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh"
    case english = "en"
    case other

    var id: String { rawValue }

    /// 问预设名单用的语言：「其他语言」给一个哪个预设都没有自己名单的码，名单就照 `other_languages` 走。
    var catalogLanguage: String { self == .other ? "und" : rawValue }

    /// 界面是中文就先看中文那一排，英文、西语界面先看 English。
    static func initial(uiLanguage: String) -> VoicePickerTab {
        uiLanguage.lowercased().hasPrefix("zh") ? .chinese : .english
    }
}

/// 选择器的一行。
struct VoicePickerRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case mine, designed, preset }

    /// 交给配旁白 / 变声的那个名字：`voice_…` 或 `gemini:<名字>`。
    let id: String
    let kind: Kind
    let name: String
    /// `male` / `female`；我的声音没有。
    let gender: String?
    /// 预设在这种语言里的说明（已经按界面语言挑好）；我的声音没有（界面写它有哪几种语言）。
    let detail: String?
    /// 我的声音有哪几种语言的录音（ISO 639-1）。
    let languages: [String]
    /// 预设的样音（公开地址）。我的声音的试听是临时链接，要用的时候现取（VoiceLibraryStore.previewURL）。
    let sampleURL: URL?
    /// 我的声音试听哪种语言的那一段；没有录音就是 nil。
    let previewLanguage: String?
    let isDefault: Bool
}

struct VoicePickerSection: Identifiable, Equatable, Sendable {
    let kind: VoicePickerRow.Kind
    let rows: [VoicePickerRow]
    var id: VoicePickerRow.Kind { kind }
}

extension VoicePickerRow.Kind: Hashable {}

enum VoicePickerRows {
    /// 三组，顺序固定：我的声音、设计的声音、预设（变声面板也照这个顺序：预设排最后）。没有内容的组照样在（界面写一句空着的话）。
    static func sections(catalog: SkyStudioVoiceCatalog?, voices: [SkyStudioVoice], tab: VoicePickerTab, uiLanguage: String) -> [VoicePickerSection] {
        let mine = voices.filter { $0.source != "design" }.map { row($0, kind: .mine, tab: tab) }
        let designed = voices.filter { $0.source == "design" }.map { row($0, kind: .designed, tab: tab) }
        return [
            VoicePickerSection(kind: .mine, rows: mine),
            VoicePickerSection(kind: .designed, rows: designed),
            VoicePickerSection(kind: .preset, rows: presets(catalog, tab: tab, uiLanguage: uiLanguage))
        ]
    }

    static func presets(_ catalog: SkyStudioVoiceCatalog?, tab: VoicePickerTab, uiLanguage: String) -> [VoicePickerRow] {
        guard let catalog else { return [] }
        let language = tab.catalogLanguage
        let wanted = uiLanguage.lowercased().hasPrefix("zh") ? "zh" : "en"
        return catalog.listed(language: language).map { preset in
            let entry = preset.entry(for: language)
            return VoicePickerRow(
                id: preset.id, kind: .preset, name: preset.name, gender: entry?.gender,
                detail: entry?.description[wanted] ?? entry?.description["en"], languages: [],
                sampleURL: entry?.sampleURL, previewLanguage: nil, isDefault: preset.isDefault)
        }
    }

    /// 我的声音试听哪种语言的录音：这一排的语言有就用它，没有用第一段。
    static func previewLanguage(of voice: SkyStudioVoice, tab: VoicePickerTab) -> String? {
        voice.language(tab.rawValue)?.language ?? voice.languages.first?.language
    }

    private static func row(_ voice: SkyStudioVoice, kind: VoicePickerRow.Kind, tab: VoicePickerTab) -> VoicePickerRow {
        VoicePickerRow(id: voice.id, kind: kind, name: voice.name, gender: nil, detail: nil, languages: voice.languages.map(\.language),
                       sampleURL: nil, previewLanguage: previewLanguage(of: voice, tab: tab), isDefault: false)
    }
}

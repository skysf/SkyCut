import Foundation

// MARK: - 一段旁白在 Sky Studio 上怎么读、字幕的时间从哪来（纯值）
//
// 管什么（SkyCut 声音方案第七节、8.1；约定第 5 条：字幕时间由 SkyCut 决定，服务器只照点名的模型读）：报价之前定下三件事 ——
// - 交哪个 model：auto / 点名的；**预设声音要字幕、这台 Mac 又转写不了这种语言**时，整段点名这个预设的备用模型
//   （`voice_presets[].fallback.model`，现在是 eleven-v4：它报每个字的时间，服务器换成这个预设的 Eleven 声音，一段里不出现两种声音）；
//   备用模型也不读这种语言（`/models` 的 `languages`）就不换、按字数估；点名了模型的照点名的读、不换；
// - 几句合一批（这台 Mac 切得开、或者读的模型报字的时间：按 Eleven 的字符时间切），还是一句一单（切不开：一批里几句只能靠转写切）；
// - 要字幕时字幕的时间从哪来（AIVoiceoverTiming）：provider / aligned / estimated。声音库的声音（voice_…）转写不了就估、不换 Eleven
//   （换了就不是那个人的声音，决定第七节第 5 条）。
// 「这台 Mac 转写得了」（`transcribes`）由调用方量（SkyStudioVoiceTranscription）：macOS 26、SpeechTranscriber 支持这种语言，模型没装也算 ——
// 任务里花钱之前明着装，装不上再按「转写不了」定一次（SkyStudioVoiceoverStart.withoutTranscription）。
// 读的模型报不报字的时间（报价之前，`model: auto` 时服务器还没选）：点名的看它自己；预设看它自己的 `model`；Eleven 的声音看预设的备用里
// 读 Eleven 声音的那个模型；声音库的声音看这个 kind 的全部模型（服务器在几个里挑，都报才算报）。
// 不管什么：分批本身（SkyStudioVoiceBatch）、报价（SkyStudioVoicePlan）、切句和字幕（SkyStudioVoiceRender）。

struct SkyStudioVoiceReading: Equatable, Sendable, Codable {
    /// 交给 /quote、/jobs 的 model。
    var model: String
    /// 几句合一批（按 `/models` 的字数上限装）；false = 一句一单。
    var packs: Bool
    /// 要字幕时字幕的时间从哪来；不要字幕是 nil。
    var timing: AIVoiceoverTiming?
    /// 定的时候这台 Mac 转写得了这种语言（恢复时照它：转写不了就不去试）。
    var transcribes: Bool
    /// 为了字幕的时间整段换了模型（voice.note 说一声）。
    var switchedForTiming: Bool

    /// `named`：add_voiceover 点名的模型（nil = auto）；`voice`：认出来的 `params.voice`。
    static func decide(kind: String, voice: String, model named: String?, subtitles: Bool, language: String,
                       transcribes: Bool, catalog: SkyStudioCatalog) -> SkyStudioVoiceReading {
        let model = named ?? SkyStudioVoiceRequests.autoModel
        if reportsWordTimes(kind: kind, voice: voice, model: named, catalog: catalog) {
            return .init(model: model, packs: true, timing: subtitles ? .provider : nil, transcribes: transcribes, switchedForTiming: false)
        }
        if transcribes {
            return .init(model: model, packs: true, timing: subtitles ? .aligned : nil, transcribes: true, switchedForTiming: false)
        }
        if subtitles, named == nil, let timed = timedFallback(kind: kind, voice: voice, language: language, catalog: catalog) {
            return .init(model: timed, packs: true, timing: .provider, transcribes: false, switchedForTiming: true)
        }
        return .init(model: model, packs: false, timing: subtitles ? .estimated : nil, transcribes: false, switchedForTiming: false)
    }

    /// 读这段的模型报不报每个字什么时候说（报价之前能知道的）。
    static func reportsWordTimes(kind: String, voice: String, model named: String?, catalog: SkyStudioCatalog) -> Bool {
        let voices = catalog.voices
        let candidates: [SkyStudioModel]
        if let named {
            candidates = catalog.model(named, kind: kind).map { [$0] } ?? []
        } else if let own = voices?.preset(voice)?.model {
            candidates = catalog.model(own, kind: kind).map { [$0] } ?? []
        } else if voice.lowercased().hasPrefix("eleven:"), let eleven = voices.flatMap(elevenModel) {
            candidates = catalog.model(eleven, kind: kind).map { [$0] } ?? []
        } else {
            candidates = catalog.models(kind: kind)
        }
        return !candidates.isEmpty && candidates.allSatisfy { $0.givesWordTimes == true }
    }

    /// 预设声音的备用模型：报字的时间、读这种语言才用（没列语言当读）。
    static func timedFallback(kind: String, voice: String, language: String, catalog: SkyStudioCatalog) -> String? {
        guard kind == SkyStudioVoiceKind.narration, let fallback = catalog.voices?.preset(voice)?.fallback,
              let model = catalog.model(fallback.model, kind: kind), model.givesWordTimes == true,
              model.supportedLanguages.map({ $0.contains(language) }) ?? true else { return nil }
        return model.id
    }

    /// 读 Eleven 声音（`eleven:<名字>`）的模型：预设的备用声音是 Eleven 的，备用的那个模型就是它（现在是 eleven-v4）。
    private static func elevenModel(_ voices: SkyStudioVoiceCatalog) -> String? {
        voices.presets.compactMap(\.fallback).first { $0.voice.lowercased().hasPrefix("eleven:") }?.model
    }
}

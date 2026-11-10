import Foundation

// MARK: - 声音库界面上的话（照界面语言）
//
// 管什么（SkyCut 声音方案 5.1–5.4）：把错误、语言、性别、来源、授权那一句、用了哪一段、设计的报价换成界面上给人看的那一句。
// - 错误：是哪一种只问 SkyStudioVoiceLibraryErrors.kind（和给 AI 的英文同一份分法），这里只管照界面语言怎么说；认不出来的照旧用
//   服务器 / SkyCut 的原话（英文）。读不到 Key 的两种（没存、要授权）各一句。
// - 授权那一句：`/models` 的 `voice_consent.per_recording`。认得的版本显示本地化的译文；服务器换了新版本而这里还没有译文时，
//   **显示服务器的英文原文**——用户同意的必须是交上去的那个版本说的话。
// - 语言的名字照界面语言写（`zh` → 中文 / Chinese / Chino）。
// 不管什么：什么时候显示（各视图）、AI 那一路的英文（SkyStudioVoiceLibraryErrors.message）。

enum VoiceLibraryText {
    /// 认得的那一版授权文案（有三种语言的译文）。
    static let knownConsentVersion = "voice-consent-v1"

    /// 界面上勾的那一句。
    static func consent(_ statement: SkyStudioVoiceConsentStatement) -> String {
        statement.version == knownConsentVersion
            ? L10n("I have the right to use this voice: it is my own voice, or the speaker gave me permission to create and use an AI copy of it.")
            : statement.statement
    }

    /// 语言的名字，照界面语言写、首字母大写。
    static func languageName(_ code: String, uiLanguage: String) -> String {
        let locale = Locale(identifier: uiLanguage)
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    @MainActor
    static func languageName(_ code: String) -> String {
        languageName(code, uiLanguage: AppLanguageStore.shared.language.resolvedCode)
    }

    @MainActor
    static func languageNames(_ codes: [String]) -> String {
        codes.map { languageName($0) }.joined(separator: " · ")
    }

    static func gender(_ gender: String?) -> String? {
        switch gender {
        case "male"?: return L10n("Male")
        case "female"?: return L10n("Female")
        default: return nil
        }
    }

    /// 「0:00–0:42 · 38 s of clear speech」；自动挑的一段前面加一句。
    static func sampleSummary(_ sample: VoiceReferenceSample.Sample) -> String {
        let range = VoiceReferenceSample.clock(sample.sourceStart) + "–" + VoiceReferenceSample.clock(sample.sourceEnd)
        let speech = String(format: L10n("%@ of clear speech"), VoiceReferenceSample.spoken(sample.voicedSeconds))
        let line = range + " · " + speech
        return sample.autoSelected ? String(format: L10n("Picked automatically (a sample is at most 3 minutes): %@"), line) : line
    }

    /// 设计用的是哪家的模型（给人看的名字）。
    static func designModel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "Sky Studio" }
        if model.lowercased().contains("minimax") { return "MiniMax" }
        if model.lowercased().contains("qwen") { return "Qwen3" }
        return model
    }

    /// 「将用 MiniMax 设计 · 约 752 积分（最多 760）」；大概和最多一样时只写一个数。
    static func designOffer(_ quote: SkyStudioQuote) -> String {
        let model = designModel(quote.model)
        let most = SkyStudioCredits.text(quote.credits)
        if let expected = quote.creditsExpected, abs(expected - quote.credits) > 0.05 {
            return String(format: L10n("Designed with %@ · about %@ credits (at most %@)"), model, SkyStudioCredits.text(expected), most)
        }
        return String(format: L10n("Designed with %@ · %@ credits"), model, most)
    }

    static func designButton(_ quote: SkyStudioQuote?) -> String {
        guard let quote else { return L10n("Design") }
        return String(format: L10n("Design (up to %@ credits)"), SkyStudioCredits.text(quote.credits))
    }

    /// 读不到 Key 时的那一句。
    static func keyProblem(_ problem: SkyStudioJobKey.Problem) -> String {
        switch problem {
        case .noKey: return L10n("Connect your Sky Studio account to use the voice library.")
        case .needsPermission: return L10n("macOS needs your permission before SkyCut can read the key.")
        case .keychain: return problem.message
        }
    }

    /// 做参考录音 / 问 Sky Studio 出的错，照界面语言说。
    @MainActor
    static func message(_ error: Error) -> String {
        if let tool = error as? AIToolError, tool.details["reason"]?.stringValue == "too_little_speech",
           let have = tool.details["voiced_seconds"]?.doubleValue {
            return String(format: L10n("Only %@ s of clear speech so far. A voice needs at least 10 s of one person talking."), String(format: "%.1f", have))
        }
        guard let kind = SkyStudioVoiceLibraryErrors.kind(error) else { return SkyStudioVoiceLibraryErrors.message(error) }
        func name(_ language: String?) -> String { language.map { languageName($0) } ?? L10n("that language") }
        switch kind {
        case .unavailable:
            return L10n("The voice library is not available right now. Try again later.")
        case .storageUnavailable:
            return L10n("The voice is gone from your library, but Sky Studio could not finish removing its files. Delete it again later.")
        case .voiceLimit(let limit):
            return String(format: L10n("Your voice library is full (at most %@ voices). Delete one you no longer use first."), limit ?? String(NewVoiceGate.voiceLimit))
        case .referenceExists(let language):
            return String(format: L10n("This voice already has a recording in %@. To replace it, delete the voice and create it again."), name(language))
        case .minimaxVoiceExists(let language):
            return String(format: L10n("This voice already has its MiniMax version for %@."), name(language))
        case .notFound:
            return L10n("This voice is no longer in your library.")
        case .tooLittleSpeech(let limit):
            return String(format: L10n("Sky Studio found less than %@ seconds of clear speech in the recording. Use a part where one person talks clearly, without music."), limit ?? "10")
        case .tooLong(let limit):
            return String(format: L10n("The recording is longer than Sky Studio accepts (%@ seconds)."), limit ?? "180")
        case .uploadTooLarge:
            return L10n("The recording is too large to upload (at most 35 MB).")
        case .unsupportedLanguage(let language):
            return String(format: L10n("Sky Studio does not support %@ for this."), name(language))
        case .consent:
            return L10n("Sky Studio needs your consent for this recording again. Check the box and try once more.")
        case .refused(let message):
            return message
        }
    }

    /// 「新建」还灰着时下面那一句；能按了是 nil。
    @MainActor
    static func blocker(_ blocker: NewVoiceGate.Blocker?, voiceName: String?) -> String? {
        switch blocker {
        case nil, .busy?: return nil
        case .unavailable?: return L10n("The voice library is not available right now. Try again later.")
        case .tooManyVoices(let limit)?:
            return String(format: L10n("Your voice library is full (at most %@ voices). Delete one you no longer use first."), String(limit))
        case .name?: return L10n("Give the voice a name (up to 80 characters).")
        case .recording?: return L10n("Record or choose at least 10 seconds of one person talking.")
        case .language?: return L10n("Choose the language spoken in the recording.")
        case .languageTaken(let language)?:
            return String(format: L10n("“%@” already has a recording in %@."), voiceName ?? "", languageName(language))
        case .consent?: return L10n("Check the box to confirm you may use this voice.")
        }
    }
}

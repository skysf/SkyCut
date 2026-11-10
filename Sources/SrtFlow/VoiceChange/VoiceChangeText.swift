import Foundation

// MARK: - 变声面板上的话（照界面语言）
//
// 管什么（SkyCut 声音方案 5.5）：这一段为什么变不了（没有声音、静音了、超过一次的上限、几乎没声音）、报价那一行「约 X 积分（最多 Y）」、
// 按钮上的字、用哪种语言的录音那一句。是哪一种问题只问 VoiceChangeProblem（和给 AI 的英文同一份分法）；Sky Studio 的错误照
// VoiceLibraryText（声音库那一摊同一份）。界面上的话不叫人去调 AI 的工具。
// 不管什么：什么时候显示（VoiceChangePanel）、AI 那一路的英文（VoiceChangeProblem.message）。

enum VoiceChangeText {
    @MainActor
    static func message(_ error: Error) -> String {
        guard let problem = error as? VoiceChangeProblem else { return VoiceLibraryText.message(error) }
        return message(problem)
    }

    static func message(_ problem: VoiceChangeProblem) -> String {
        switch problem {
        case .noSound: return L10n("This clip has no sound to change.")
        case .muted: return L10n("This clip is muted. Unmute it first, then change its voice.")
        case .tooLong(let seconds, let limit):
            return String(format: L10n("This clip uses %1$@ of its source; a voice change takes at most %2$@ at a time. Split the clip first, then change each part."),
                          VoiceReferenceSample.clock(seconds), VoiceReferenceSample.clock(limit))
        case .almostSilent: return L10n("This clip is almost silent: there is no voice to change.")
        case .tooLarge: return L10n("This clip's sound is too large to upload (at most 35 MB). Split the clip first.")
        }
    }

    /// 「约 9.5 积分（最多 15.5）」；大概和最多一样时只写一个数。
    static func offer(_ quote: SkyStudioQuote) -> String {
        let most = SkyStudioCredits.text(quote.credits)
        if let expected = quote.creditsExpected, abs(expected - quote.credits) > 0.05 {
            return String(format: L10n("About %@ credits (at most %@)"), SkyStudioCredits.text(expected), most)
        }
        return String(format: L10n("%@ credits"), most)
    }

    static func button(_ quote: SkyStudioQuote?) -> String {
        guard let quote else { return L10n("Change Voice") }
        return String(format: L10n("Change Voice (up to %@ credits)"), SkyStudioCredits.text(quote.credits))
    }

    /// 用哪种语言的录音：知道这段的语言、目标又有这种录音就说用它；知道语言但目标没有这种录音，说会用别的录音、可能不那么像；不知道语言不说。
    @MainActor
    static func languageNote(spoken: String?, target: VoiceChangeTarget?) -> String? {
        guard let spoken, let target else { return nil }
        let language = VoiceLibraryText.languageName(spoken)
        if target.languages.contains(spoken) {
            return String(format: L10n("This clip is in %1$@; “%2$@” has a recording in %1$@ and that one is used."), language, target.name)
        }
        return String(format: L10n("This clip is in %1$@; “%2$@” has no recording in %1$@, so another of its recordings is used and the result may sound less like it."),
                      language, target.name)
    }
}

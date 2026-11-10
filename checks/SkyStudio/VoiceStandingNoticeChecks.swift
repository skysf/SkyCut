import Foundation
import SrtFlowMCPKit

// 打开全部权限时那段说明（SkyCut 声音方案 5.6，纯值 SkyStudioVoiceStandingNotice）：价目照 Sky Studio 的目录快照读（不写死）、
// 额度、授权那句（版本 + 英文原文：SkyCut 认识的那一版和 Sky Studio 导出的一字不差，设置里那张说明的译文译的就是它）；
// 读不到时的退路；给 AI 的两段英文（set_settings 打开全部权限、全部权限下第一次补问）。
// set_settings 的问句带它、令牌绑那一句的版本在 AccessChecks。

func runVoiceStandingNoticeChecks() {
    guard let loaded = loadVoiceFixture() else { return check(false, "the voice catalog fixture loads") }
    let notice = SkyStudioVoiceStandingNotice(catalog: loaded.catalog, dailyLimit: 1_000)
    checkEqual(notice.credits(.designChinese), 751.4, "designing from a Chinese description: MiniMax's typical credits from /models")
    checkEqual(notice.credits(.designEnglish), 22.5, "designing from an English description: Qwen3's, per 1,000 characters started")
    check(notice.fee(.designEnglish)?.perThousandCharacters == true && notice.fee(.designChinese)?.perThousandCharacters == false
            && notice.fee(.minimaxVersion)?.perThousandCharacters == false, "only Qwen3 design is priced by characters (Sky Studio #247)")
    checkEqual(notice.credits(.minimaxVersion), 377.6, "a voice's MiniMax version: minimax-voice-clone's")
    checkEqual(notice.statement, loaded.catalog.voices?.standingConsent, "the statement is Sky Studio's standing one")
    checkEqual(SkyStudioVoiceStandingNotice.knownStatement, loaded.catalog.voices?.standingConsent,
               "SkyCut's known statement is word for word Sky Studio's v1 (the Settings sheet translates this text)")
    for phrase in ["about 751.4 credits", "22.5 credits for every 1,000 characters started of description and sample text", "about 377.6 credits",
                   "1000 credits a day", "voice-standing-consent-v1", "For every recording I later use",
                   "Full access lets AI do these without asking first", "move files to the Trash", "design and delete voices",
                   "hard cap", "Show this to the user"] {
        check(notice.turnOnText.contains(phrase), "turning Full access on explains \"\(phrase)\"")
    }
    for phrase in ["no standing voice consent on record", "asks this once", "stops asking", "voice-standing-consent-v1", "377.6", "hard cap"] {
        check(notice.missingText.contains(phrase), "the full-access question without a standing consent says \"\(phrase)\"")
    }

    // 读不到 /models：没有价（写「Sky Studio quotes each one」），授权那句用 SkyCut 认识的那一版，额度照本机。
    let offline = SkyStudioVoiceStandingNotice(catalog: nil, dailyLimit: 250)
    check(offline.fees.isEmpty && offline.turnOnText.contains("Sky Studio quotes each one") && offline.turnOnText.contains("250 credits a day"),
          "without /models: no prices, Sky Studio quotes each fee, the local daily limit")
    checkEqual(offline.statement, SkyStudioVoiceStandingNotice.knownStatement, "without /models: SkyCut's known statement")

    // 有价没有 typical：用 credits；少了的模型那一行不写；没有声音那一节：用认识的那一版。
    let bare = SkyStudioCatalog(json: ["models": [["id": "minimax-voice-clone", "kind": "voice_enroll", "title": "MiniMax", "price": ["credits": 375]]]])
    let fromCredits = SkyStudioVoiceStandingNotice(catalog: bare, dailyLimit: 1_000)
    checkEqual(fromCredits.credits(.minimaxVersion), 375, "without typical_credits the price's credits are used")
    check(fromCredits.fee(.minimaxVersion)?.perThousandCharacters == false && fromCredits.turnOnText.contains("about 375 credits"),
          "a price without per 1000_characters reads as about so much")
    check(fromCredits.credits(.designChinese) == nil && fromCredits.turnOnText.contains("375")
            && !fromCredits.turnOnText.contains("Chinese description"), "a model missing from /models leaves its line out")
    checkEqual(fromCredits.statement, SkyStudioVoiceStandingNotice.knownStatement, "a server without voice_consent: SkyCut's known statement")
}

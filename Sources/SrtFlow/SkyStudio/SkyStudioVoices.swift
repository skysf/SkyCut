import Foundation
import SrtFlowCore

// MARK: - 配旁白用 Sky Studio 的声音时，挑哪个音色（纯值）
//
// 管什么：方案第 42 条的最上面一档 —— 用户接了 Sky Studio 就用 Sky Studio 的声音（Eleven v4）配旁白。角色（`AIVoiceRole`）换成 ElevenLabs 的预制音色名；
// AI 直接点名 ElevenLabs 的音色（`Rachel`、`Brian`……）也认；都没点名按文字的语言取温和的那个角色。
// 音色名是 fal 在 Eleven v4 的 `voice` 字段例子里列的那一批（2026-09-29 读接口定义：Aria、Roger、Sarah、Laura、Charlie、George、Callum、
// River、Liam、Charlotte、Alice、Matilda、Will、Jessica、Eric、Chris、Brian、Daniel、Lily、Bill，默认 Rachel）。
// 不管什么：这一次用不用 fal（额度和 Key，AIVoiceoverTool）、怎么调（SkyStudioVoiceoverRun）。

enum SkyStudioVoices {
    /// Sky Studio 的 Eleven v4 认的预制音色（大小写照它写的）。
    static let premade = [
        "Rachel", "Aria", "Roger", "Sarah", "Laura", "Charlie", "George", "Callum", "River", "Liam", "Charlotte", "Alice",
        "Matilda", "Will", "Jessica", "Eric", "Chris", "Brian", "Daniel", "Lily", "Bill"
    ]

    /// 角色 → 音色。**名字和 `AIVoiceRole.all` 一一对上**（check-fal 对账）。
    /// 女声：活泼 = Jessica（明亮）、温和 = Sarah（柔和）、英式 = Alice；男声：Brian（低沉稳重）、Eric（顺滑可信）、英式 = George（温暖）。
    /// ElevenLabs 的多语言模型用同一个音色读中英文，所以中文角色也用这几个。
    static let byRole: [String: String] = [
        "zh_female_lively": "Jessica", "zh_female_warm": "Sarah", "zh_male": "Eric",
        "en_female_lively": "Jessica", "en_female_warm": "Rachel", "en_male": "Brian",
        "en_female_british": "Alice", "en_male_british": "George"
    ]

    /// 没点名时：按文字的语言取温和的那个角色的音色；认不出语言用默认的 Rachel。
    static func defaultVoice(forLanguage language: String) -> String {
        AIVoiceRole.fallback(forLanguage: language).flatMap { byRole[$0.name] } ?? "Rachel"
    }

    static func voice(for role: AIVoiceRole) -> String { byRole[role.name] ?? "Rachel" }

    /// AI 点名的是不是 ElevenLabs 的预制音色（大小写不敏感）；是就回规范写法。
    static func named(_ requested: String) -> String? {
        premade.first { $0.caseInsensitiveCompare(requested.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

}

import Foundation

// MARK: - user_requested_overrides 要用户自己的话点名规格（纯值）
//
// 管什么：AI 说「这是用户点名的规格，不用再问」（user_requested_overrides=true）时，要在 user_request 里带上用户原话里点名它的那一段；
// 每一项越档（分辨率、时长、最高画质、更贵的模型、付费 upscale、付费角色）都要在那段话里找得到它的名字，找不到就照常要确认
// （SkyStudioJobGate 回 needs_confirmation，不报错：叫 AI 去问用户，而不是逼它重编一段原话）。
// 「画质尽量好」「最好的」「best quality」这种形容不是任何一项的名字，所以过不了（2026-11-10 Codex 两次都把它当成点名、跳过了确认）。
// 不管什么：App 看不到对话，不判断那段话是不是用户真说的 —— 只要求模型明确地把规格归到用户的原话上；预算、全部权限照旧由闸管。
enum AIOverrideQuote {
    /// 一项越档：给人看的原因，和用户点名它时原话里会出现的写法（出现任一个就算点名）。names 为空 = 这一项没有能点名的写法，带了原话就算。
    struct Item: Equatable {
        let reason: String
        let names: [String]
    }

    /// 付费 upscale：用户要放大（「upscale」「放大」「超分」）。
    static let upscaleNames = ["upscale", "放大", "超分"]
    /// 付费的角色库操作：用户要建 / 改角色或头像。
    static let characterNames = ["character", "角色", "headshot", "头像"]
    /// 最高画质：只认点名这一档的说法，不认「最好」「尽量好」这种形容。
    static let highestQualityNames = ["highest", "最高"]

    /// 原话里没点名的那几项；原话是空的就是全部。比较时不分大小写、去掉空白 / 连字符 / 下划线 / 点（「GPT Image 2」=「gpt-image-2」）。
    static func unnamed(_ items: [Item], in quote: String?) -> [Item] {
        let said = normalized(quote ?? "")
        guard !said.isEmpty else { return items }
        return items.filter { item in
            !item.names.isEmpty && !item.names.contains { name in
                let wanted = normalized(name)
                return !wanted.isEmpty && said.contains(wanted)
            }
        }
    }

    /// 分辨率的几种写法：原样（4K）、按档位换算的像素行数（2160p / 2160）。
    static func resolutionNames(_ value: String) -> [String] {
        let rank = AIDraftPolicy.rank(value)
        guard rank.isFinite else { return [value] }
        let lines = String(Int(rank))
        return [value, lines + "p", lines].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// 时长的几种写法：10s、10 秒、10 sec、10 second(s)。
    static func durationNames(_ seconds: Double) -> [String] {
        let number = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        return [number + "s", number + "秒", number + "sec", number + "second"]
    }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace && !"-_.".contains($0) })
    }
}

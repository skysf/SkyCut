import Foundation
import SrtFlowMCPKit

// 剪辑风格卡里讲生成素材、花积分的话要和现行合同对得上（2026-11-13，docs/bugfixes/2026-11-13-recipe-rules-teach-budget-bypass.md）。
// 卡是 App 资源，AI 调 recipes 时原样读到。合同在别处改了 —— 2026-10-30 工具清单始终列出 generate_media、10-31 目录里有了 1080p 的
// 视频模型、11-01 每日预算改成硬上限 —— 共用规矩照旧教 AI「超了每日上限回 needs_confirmation、带 confirm_token 再调」「480p 出草稿、
// 768p 重做」；原来的检查还钉着 480p、needs_confirmation 这几个词，等于替过期的那句站岗。这里对着生产的行为和现行合同的说法查：
// 1. generate_media 只写成条件句（2026-09-29 用户拍板）；清单不按 Key 过滤（MCPToolName.listed）时，条件里不许说「存了 Key 才有」；
// 2. 共用规矩讲到报价（quote_only）、要点头（needs_confirmation + confirm_token）和每日硬上限（daily_budget_exceeded），而且没有
//    一句话把每日预算和 needs_confirmation / confirm_token 写在一起（SkyStudioJobGate.decide：先守硬上限，超了直接 blocked、不发码）；
// 3. 讲生成素材的句子不写死档位（480p、768p、1080p、2K……）：草稿由 SkyCut 按目录挑（AIDraftPolicy），更高档看 get_status models=true；
// 4. 不再提 fal（2026-10-28 起都走 Sky Studio、花积分）。
// 不管什么：卡的格式、名字存不存在、各节在不在（RecipeChecks）；字号（RecipeSizeChecks）；合同本身（SkyStudioJobGate、说明书的 paid 主题
// 各有各的检查）。长期约束见 docs/architecture/ai-control-mcp.md 第四节第 32 条。

func runRecipeContractChecks() {
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let cards = AIBuiltInRecipes.load(from: [resources])
    let shared = AIBuiltInRecipes.sharedRules(from: [resources])
    let texts = cards.map { ($0.id, $0.body) } + [("shared rules", shared)]
    conditionalChecks(cards: cards, shared: shared)
    paidFlowChecks(shared: shared, texts: texts)
    for (name, text) in texts {
        tierChecks(name, text)
        check(text.range(of: #"(?i)\bfal\b|fal\.ai|cost_usd"#, options: .regularExpression) == nil,
              "\(name): no mention of fal or dollars (Sky Studio credits since 2026-10-28)")
    }
}

/// generate_media 的条件句：卡一直读得到，生成要看清单里有没有它。
private func conditionalChecks(cards: [AIRecipe], shared: String) {
    let conditional = "If generate_media is among your tools"
    check(shared.contains(conditional), "the shared rules teach generate_media as a conditional")
    for card in cards where card.body.contains("generate_media") {
        check(card.body.contains("only if generate_media is among your tools"),
              "\(card.id) mentions generate_media only under the condition that it exists")
    }
    check(cards.allSatisfy { $0.body.contains("generate_media") }, "every card says what generate_media may add for its style")
    // 2026-10-30 起清单始终列出它，Key、套餐、积分在调用时核对：条件只说「清单里有它」，说成「存了 Key 才列出来」是一句过期的事实。
    guard MCPToolName.listed(providers: []).contains(.generateMedia), let start = shared.range(of: conditional) else { return }
    let condition = shared[start.upperBound...].prefix { $0 != ":" }
    check(!condition.localizedCaseInsensitiveContains("key"),
          "the shared rules' condition for generate_media does not tie it to a Sky Studio key (it is listed without one since 2026-10-30): \"\(condition)\"")
}

/// 花积分怎么问：报价、要点头、每日硬上限三样都讲到，而且每日预算和确认那一套不写在同一句里。
private func paidFlowChecks(shared: String, texts: [(String, String)]) {
    for name in ["quote_only", "needs_confirmation", "confirm_token", "daily_budget_exceeded"] {
        check(shared.contains(name), "the shared rules mention \(name) (the price, the approval beyond the low-cost draft, the daily hard limit)")
    }
    for (name, text) in texts {
        let mixed = recipeSentences(text).filter {
            $0.range(of: #"(?i)daily|budget|\blimit\b"#, options: .regularExpression) != nil
                && $0.range(of: "needs_confirmation|confirm_token", options: .regularExpression) != nil
        }
        check(mixed.isEmpty, "\(name): no sentence ties the daily budget to needs_confirmation / confirm_token (over the daily hard "
              + "limit the result is daily_budget_exceeded and nothing starts; the confirmation is only for an in-budget request beyond "
              + "the low-cost draft, SkyStudioJobGate.decide since 2026-11-01). Sentences: \(mixed)")
    }
}

/// 讲生成素材的句子不写死档位：草稿由 SkyCut 按目录挑（AIDraftPolicy：视频取 720p 同档），留下的再按那个模型在目录里有的更高档做；
/// 10-31 之后目录里有 1080p 的视频模型，768p 也不是每个模型都有。
private func tierChecks(_ name: String, _ text: String) {
    let tier = #"\b\d{3,4}[pP]\b|\b\d[kK]\b"#
    let generation = #"(?i)generat|draft|remake|sky studio|text_to_video|image_to_video"#
    let fixed = recipeSentences(text).filter {
        $0.range(of: tier, options: .regularExpression) != nil && $0.range(of: generation, options: .regularExpression) != nil
    }
    check(fixed.isEmpty, "\(name): no resolution tier in a sentence about generated media (the draft comes from the catalog "
          + "through AIDraftPolicy, higher tiers from get_status models=true). Sentences: \(fixed)")
}

/// 卡里的句子：先分段（标题、列表的每一项、空行隔开的段各算一段，缩进的续行接在上一行后面），段里再按句号 / 问号 / 叹号切。
/// 冒号、分号不切：「超了每日上限：回 needs_confirmation」这种写法要算在同一句里。
func recipeSentences(_ text: String) -> [String] {
    var blocks: [String] = []
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let startsBlock = trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("- ")
            || trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        if startsBlock || blocks.isEmpty { blocks.append(trimmed) } else { blocks[blocks.count - 1] += " " + trimmed }
    }
    return blocks
        .flatMap { $0.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression).components(separatedBy: "\n") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

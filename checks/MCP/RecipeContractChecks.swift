import Foundation
import SrtFlowMCPKit

// 剪辑风格卡里讲生成素材、花积分的话要和现行合同对得上（2026-11-13，docs/bugfixes/2026-11-13-recipe-rules-teach-budget-bypass.md）。
// 卡是 App 资源，AI 调 recipes 时原样读到。合同在别处改了 —— 2026-10-30 工具清单始终列出 generate_media、10-31 目录里有了 1080p 的
// 视频模型、11-01 每日预算改成硬上限 —— 共用规矩照旧教 AI「超了每日上限回 needs_confirmation、带 confirm_token 再调」「480p 出草稿、
// 768p 重做」；原来的检查还钉着 480p、needs_confirmation 这几个词，等于替过期的那句站岗。这里对着生产的行为和现行合同的说法查：
// 1. generate_media 只写成条件句（2026-09-29 用户拍板）；清单不按 Key 过滤（MCPToolName.listed）时，条件里不许说「存了 Key 才有」；
// 2. 共用规矩讲到报价（quote_only）、要点头（needs_confirmation + confirm_token）和每日硬上限（daily_budget_exceeded），而且没有
//    一句话把每日预算和 needs_confirmation / confirm_token 写在一起（SkyStudioJobGate.decide：先守硬上限，超了直接 blocked、不发码）；
//    怎么切段切句、哪些说法算预算在 RecipeTextScan.swift（自带坏话和合规的例子，审查 D6R-03）；
// 3. 讲生成素材的句子不写死档位（480p、768p、1080p、2K……）：草稿由 SkyCut 按目录挑（AIDraftPolicy），更高档看 get_status models=true；
// 4. 不再提 fal（2026-10-28 起都走 Sky Studio、花积分）；
// 5. 卡里叫 AI 用到的花钱工具，共用规矩里都有一条说它花积分（2026-11-13：五张卡都叫 AI 配旁白，存了 Key 就走 Sky Studio）。
//    花钱的工具钉在 recipePaidTools，说明书 paid 主题「Which tools.」那一句和地图「Paid」那一行认出来的都必须正好是它（审查 D6R-02：
//    原来只照那一句认、只防「一个都没认出」，说明书换个写法少认一个就悄悄少查）；
// 6. 讲 add_voiceover 花积分的那一条要讲到建声音那一步（kind voice_enroll、已经在建的 already_building、跟着 next_step）：那一单的
//    credits 是建版本的钱，旁白还没读、没预留（审查 D6R-01：原来一概说「回任务号之前整段报价、整体预留，结果里的 credits 就是价」）；
// 7. needs_confirmation 不等于某一个原因（读点名文件夹以外的参考文件也回它，连 quote_only 都先问）：不写成「needs_confirmation means …」，
//    共用规矩留着总的那句（照结果的 question 问、同意才带 confirm_token）；「SkyCut 会问」不说满 —— 全部权限、用户点名过这个规格、
//    这个工程批准过的都不问（审查 D6R-07）。
// 不管什么：卡的格式、名字存不存在、各节在不在（RecipeChecks）；字号（RecipeSizeChecks）；合同本身（SkyStudioJobGate、说明书的 paid 主题
// 各有各的检查）。长期约束见 docs/architecture/ai-control-mcp.md 第四节第 32 条。

/// 花积分的工具（2026-11-13，审查 D6R-02）。生产代码里没有一份结构化的清单：`MCPToolName.provider` 说的是去哪消费（免费的
/// list_characters / get_character / list_voices 也是 Sky Studio，配旁白却是 nil：本机的声音不花钱）；花钱的入口是各工具自己过
/// SkyStudioJobGate，那是 App 的代码、这个自检不编。所以钉在这里，每一个对着 App 里记账的那一处：
/// generate_media（SkyStudioGenerateTool、SkyStudioOfficialGenerateTool → decide）、upscale_clip（AIUpscaleTool → decide）、
/// change_voice（VoiceChangeTool → reserveWithoutAsking）、manage_characters（SkyStudioCharacterManageTool → decide）、
/// manage_voices（SkyStudioVoiceDesignTool → voiceOneTime）、add_voiceover（SkyStudioVoiceBudget → reserveWithoutAsking、
/// SkyStudioVoiceOneTimeStep → voiceOneTime）。加了花钱的工具、或者说明书改了写法，paidToolChecks 先红。
let recipePaidTools: Set<MCPToolName> = [.generateMedia, .upscaleClip, .changeVoice, .manageCharacters, .manageVoices, .addVoiceover]

func runRecipeContractChecks() {
    runRecipeTextScanSelfChecks()
    contractSelfChecks()
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let cards = AIBuiltInRecipes.load(from: [resources])
    let shared = AIBuiltInRecipes.sharedRules(from: [resources])
    let texts = cards.map { ($0.id, $0.body) } + [("shared rules", shared)]
    conditionalChecks(cards: cards, shared: shared)
    paidFlowChecks(shared: shared, texts: texts)
    paidToolChecks(texts: texts, shared: shared)
    voiceoverChecks(shared: shared)
    confirmationWordingChecks(shared: shared, texts: texts)
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
        let mixed = recipeBudgetConfirmationSentences(text)
        check(mixed.isEmpty, "\(name): no sentence ties the daily budget to needs_confirmation / confirm_token (over the daily hard "
              + "limit the result is daily_budget_exceeded and nothing starts; the confirmation is only for an in-budget request beyond "
              + "the low-cost draft, SkyStudioJobGate.decide since 2026-11-01). Sentences: \(mixed)")
    }
}

/// 花钱的工具：说明书的两处都正好认出 recipePaidTools；卡里提到哪一个，共用规矩就要有一条（列表的一项）同时讲到它和积分。
private func paidToolChecks(texts: [(String, String)], shared: String) {
    let overview = MCPGuideTopics.topic(named: "paid")?.sections.first?.text ?? ""
    let expected = recipeToolList(recipePaidTools)
    checkEqual(recipePaidToolsInGuide(overview).map(recipeToolList), expected,
               "the paid guide topic's \"Which tools.\" sentence names exactly the tools that spend credits (recipePaidTools)")
    checkEqual(recipePaidToolsOnMap(guideMapText()).map(recipeToolList), expected,
               "the guide map's Paid line names exactly the tools that spend credits (recipePaidTools)")
    let rules = recipeBlocks(shared)
    for tool in expected where texts.contains(where: { recipeNames(tool, in: $0.1) }) {
        check(rules.contains { recipeNames(tool, in: $0) && $0.localizedCaseInsensitiveContains("credits") },
              "the shared rules have a rule saying \(tool) spends Sky Studio credits (the recipes tell the AI to use it; skycut_guide topic=paid lists it)")
    }
}

/// 配旁白：说明书讲 add_voiceover 可能先回建声音那一步时，共用规矩里讲它花积分的那一条也讲到（审查 D6R-01）。
private func voiceoverChecks(shared: String) {
    let guide = MCPGuideTopics.topic(for: .addVoiceover).sections.map(\.text).joined(separator: "\n")
    guard guide.contains("voice_enroll") else { return }  // 哪天不再先建声音的版本，这条自己让开（说明书必含它，SkyStudioVoiceChecks）
    check(recipeVoiceoverCoversEnrolment(shared), "the shared rule on add_voiceover's credits says a voice_enroll or already_building "
          + "result is the voice-building step: follow next_step, its credits pay for building the voice, not for the narration")
}

/// needs_confirmation 怎么讲（审查 D6R-07）：不等于某一个原因、留着总的那句、「SkyCut 会问」不说满。
private func confirmationWordingChecks(shared: String, texts: [(String, String)]) {
    for (name, text) in texts {
        let sentences = recipeSentences(text)
        let defined = sentences.filter(recipeDefinesConfirmation)
        check(defined.isEmpty, "\(name): needs_confirmation is not defined as one cause (reading a file outside the opened folder "
              + "returns it too, even for quote_only=true). Sentences: \(defined)")
        let certain = sentences.filter(recipeClaimsSkyCutAsks)
        check(certain.isEmpty, "\(name): no sentence says SkyCut asks as a certainty (full_access, a setting the user named or one "
              + "approved for the project go ahead): follow what the call returns. Sentences: \(certain)")
    }
    check(recipeSentences(shared).contains { $0.contains("needs_confirmation") && $0.contains("question") && $0.contains("confirm_token") },
          "the shared rules keep the general rule: on needs_confirmation ask the user the result's question, call again with confirm_token only if they agree")
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

// MARK: - 认工具名、认说明书里的清单

/// 整词提到这个工具名。
func recipeNames(_ tool: String, in text: some StringProtocol) -> Bool {
    text.range(of: #"\b"# + tool + #"\b"#, options: .regularExpression) != nil
}

/// 工具名按字母排（报错时好读）。
func recipeToolList(_ tools: Set<MCPToolName>) -> [String] { tools.map(\.rawValue).sorted() }

/// 说明书 paid 主题「Which tools.」后面第一句点到的工具；没有那一句回 nil。
func recipePaidToolsInGuide(_ overview: String) -> Set<MCPToolName>? {
    guard let start = overview.range(of: "Which tools.") else { return nil }
    let sentence = overview[start.upperBound...].prefix { $0 != "." }
    return Set(MCPToolName.allCases.filter { recipeNames($0.rawValue, in: sentence) })
}

/// 地图「Paid」那一行在「free:」之前点到的工具；没有那一行回 nil。
func recipePaidToolsOnMap(_ map: String) -> Set<MCPToolName>? {
    guard let line = map.components(separatedBy: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Paid") }) else {
        return nil
    }
    let paid = line.components(separatedBy: "free:").first ?? line
    return Set(MCPToolName.allCases.filter { recipeNames($0.rawValue, in: paid) })
}

/// 讲 add_voiceover 花积分的那一条（段，子项带着父项的话）里，有一段讲到建声音那一步：kind voice_enroll、已经在建的 already_building、
/// 跟着 next_step。
func recipeVoiceoverCoversEnrolment(_ shared: String) -> Bool {
    recipeBlocks(shared)
        .filter { recipeNames("add_voiceover", in: $0) && $0.localizedCaseInsensitiveContains("credits") }
        .contains { $0.contains("voice_enroll") && $0.contains("already_building") && $0.contains("next_step") }
}

/// 上面几样自带的例子：把说明书的那一句拆开、把建声音那一步写进别的一条，都要认得出来（审查 D6R-01、02 的坏例子）。
private func contractSelfChecks() {
    let split = "Paid work uses the user's Sky Studio credits.\n\nWhich tools. generate_media spends credits. Other paid tools include "
        + "upscale_clip, change_voice, manage_characters, manage_voices and add_voiceover with Sky Studio voices. list_voices is free."
    check(recipePaidToolsInGuide(split) == Set([MCPToolName.generateMedia]), "a \"Which tools.\" sentence split in two names only its first part "
          + "(so the exact-list check goes red instead of quietly checking less)")
    check(recipePaidToolsInGuide("Paid work.") == nil, "a paid topic without \"Which tools.\" is noticed")
    check(recipePaidToolsOnMap("Clips: add_clips\nPaid, Sky Studio credits: upscale_clip (x; edits are free), add_voiceover; free: list_voices")
          == Set([MCPToolName.upscaleClip, .addVoiceover]), "the map's Paid line counts tools before \"free:\" and not the free ones")
    let oldRule = "13. Voiceover can spend credits too: with a Sky Studio key, add_voiceover reads with Sky Studio voices. Before job_id "
        + "comes back it quotes the whole script once and reserves that against the daily credit limit; tell the user the price (credits in the result)."
    check(!recipeVoiceoverCoversEnrolment(oldRule), "the voiceover rule that reports every result's credits as the narration's price is caught")
    check(!recipeVoiceoverCoversEnrolment("- add_voiceover spends credits.\n- A voice_enroll job (already_building: no charge): follow next_step."),
          "the enrolment step written in another rule than add_voiceover's credits is caught")
    check(recipeVoiceoverCoversEnrolment("13. add_voiceover spends credits:\n    - a job of kind voice_enroll (already_building: nothing new is "
          + "charged) pays for building the voice: follow next_step."), "a sub-item of the add_voiceover rule covers the enrolment step")
}

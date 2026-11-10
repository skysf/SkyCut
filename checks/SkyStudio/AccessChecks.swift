import Foundation
import SrtFlowMCPKit

// 真正经过权限 / 收费闸，使用隔离偏好与假请求，不接触账户或媒体服务。
@MainActor
func runAccessChecks() {
    let suite = "com.srtflow.ai-access-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let access = AIAccessStore(defaults: defaults)
    let spend = SkyStudioSpendStore(defaults: defaults)
    checkEqual(access.mode, .ask, "approval is the initial mode")
    checkEqual(AIAccessMode.full.names["zh"]?.stringValue, "全部权限", "Chinese full-access label")
    checkEqual(AIAccessMode.ask.names["zh"]?.stringValue, "请求批准", "Chinese approval label")
    do {
        _ = try AISettingsApproval.check(AIToolArguments(["confirm_token": []]), mode: nil, limit: nil, access: access, currentLimit: 1_000)
        check(false, "invalid confirmation fields must not be silently ignored")
    } catch { check(true, "invalid confirmation fields are rejected before any setting changes") }
    access.setMode(.full)
    checkEqual(AIAccessStore(defaults: defaults).mode, .full, "the GUI and MCP share a persisted mode")
    let settings = AIToolArguments(["ai_access_mode": "ask_for_approval", "language": "es"])
    let asked = try? AISettingsApproval.check(settings, mode: .ask, limit: nil, access: access, currentLimit: 1_000)
    let token = asked?.payload["confirm_token"]?.stringValue ?? ""
    check(!token.isEmpty, "even full access must ask before changing permissions")
    checkEqual(access.mode, .full, "requesting settings approval changes nothing")
    let changed = AIToolArguments(["ai_access_mode": "ask_for_approval", "language": "en", "confirm_token": .string(token)])
    let wrong = try? AISettingsApproval.check(changed, mode: .ask, limit: nil, access: access, currentLimit: 1_000)
    check(wrong?.payload["confirm_token_refused"] != nil, "changing another setting cannot reuse the approved request")
    let approved = AIToolArguments(["ai_access_mode": "ask_for_approval", "language": "es", "confirm_token": .string(token)])
    do {
        check(try AISettingsApproval.check(approved, mode: .ask, limit: nil, access: access, currentLimit: 1_000) == nil, "the original approval still works")
    } catch { check(false, "settings approval: \(error)") }
    check((try? AISettingsApproval.check(settings, mode: .ask, limit: 2_000, access: access, currentLimit: 1_000)) != nil,
          "raising a hard budget always asks")

    func decide(_ args: JSONValue = [:], reason: String? = "2K exceeds the draft", overrides: [AIOverrideQuote.Item]? = nil,
                profile: String = "h3-2k", project: String = "account/project") -> SkyStudioJobGate.Decision? {
        try? SkyStudioJobGate.decide(credits: 130, summary: "H3 2K", identity: "exact-request", args: AIToolArguments(args),
            store: spend, access: access, reason: reason, overrides: overrides, project: project, profile: profile)
    }
    access.setMode(.ask)
    if case .needsConfirmation(let result) = decide() { checkEqual(result.payload["status"]?.stringValue, "needs_confirmation", "premium draft asks") }
    else { check(false, "premium draft must ask") }
    checkEqual(spend.spentToday(), 0, "an approval question reserves no credits")
    if case .reserved = decide(reason: nil) { check(true, "ordinary drafts proceed") }
    else { check(false, "ordinary drafts proceed") }
    // 2026-11-10：user_requested_overrides 只在 user_request 里找得到每一项越档的名字时才免问（Codex 把「画质尽量好」当成点名）。
    let twoK = [AIOverrideQuote.Item(reason: "2K exceeds the draft", names: AIOverrideQuote.resolutionNames("2K"))]
    let beforeNamed = spend.spentToday()
    if case .reserved = decide(["user_requested_overrides": true, "user_request": "生成一张 2K 的封面"], overrides: twoK) {
        check(true, "a specification the user named is not asked twice")
    } else { check(false, "a specification the user named can proceed") }
    checkEqual(spend.spentToday(), beforeNamed + 130, "the named specification reserves its credits")
    for (words, why) in [(nil, "without user_request"), ("画质尽量好", "for a wish like 画质尽量好"), ("best quality please", "for \"best quality\"")] as [(JSONValue?, String)] {
        var args: [String: JSONValue] = ["user_requested_overrides": true]
        if let words { args["user_request"] = words }
        if case .needsConfirmation(let result) = decide(.object(args), overrides: twoK) {
            checkEqual(result.payload["status"]?.stringValue, "needs_confirmation", "user_requested_overrides still asks \(why)")
            check(result.payload["overrides_not_applied"]?.stringValue != nil, "the question says why the override was not applied (\(why))")
        } else { check(false, "user_requested_overrides must not skip the question \(why)") }
    }
    checkEqual(spend.spentToday(), beforeNamed + 130, "an override that did not apply reserves nothing")
    if case .needsConfirmation = decide(["user_requested_overrides": true, "user_request": "就要 2K"],
        overrides: twoK + [.init(reason: "Highest quality", names: AIOverrideQuote.highestQualityNames)]) {
        check(true, "every setting beyond the draft must be named, not just one")
    } else { check(false, "naming one of two settings must still ask") }

    if case .needsConfirmation(let result) = decide(["approval_scope": "project"]) {
        let projectToken = result.payload["confirm_token"]?.stringValue ?? ""
        if case .reserved = decide(["approval_scope": "project", "confirm_token": .string(projectToken)]) { check(true, "project scope accepts exact approval") }
        else { check(false, "project scope accepts exact approval") }
        if case .reserved = decide() { check(true, "same project specification proceeds later") }
        else { check(false, "same project specification proceeds later") }
        if case .needsConfirmation = decide(profile: "h3-4k") { check(true, "a higher specification still needs approval") }
        else { check(false, "a higher specification still needs approval") }
        if case .needsConfirmation = decide(project: "other-account/project") { check(true, "approval never crosses accounts/projects") }
        else { check(false, "approval never crosses accounts/projects") }
    } else { check(false, "project approval is offered") }
    access.approve(project: "account/project", profile: "draft-price-ceiling", credits: 100)
    if case .needsConfirmation = decide(reason: nil, profile: "draft-price-ceiling") {
        check(true, "a project price increase asks even if the model now calls this specification its default")
    } else { check(false, "a project price increase cannot silently exceed its approved ceiling") }
    access.setMode(.full)
    if case .reserved = decide(profile: "another-model") { check(true, "full access proceeds without a question") }
    else { check(false, "full access proceeds without a question") }
    spend.setDailyLimit(0)
    let before = spend.spentToday()
    if case .needsConfirmation(let result) = decide(["confirm_token": .string(token), "user_requested_overrides": true]) {
        checkEqual(result.payload["code"]?.stringValue, "daily_budget_exceeded", "hard budget blocks even full access and explicit requests")
        check(result.payload["confirm_token"] == nil, "a budget block never offers an approval bypass")
    } else { check(false, "hard budget cannot be bypassed") }
    checkEqual(spend.spentToday(), before, "budget rejection reserves nothing")
    check(access.allows(project: "account/project", profile: "h3-2k", credits: 130), "project grant has a per-task ceiling")
    check(!access.allows(project: "account/project", profile: "h3-2k", credits: 131), "a price rise needs new approval")
    let shortBalance = SkyStudioJobFailure(message: "Insufficient", fields: ["code": "insufficient_credits", "balance": 2, "needed": 20, "recharge_url": "https://skystudioai.com/app?credits=1"])
    checkEqual(shortBalance.json["balance"], 2, "actual balance is preserved")
    checkEqual(shortBalance.json["needed"], 20, "actual required credits are preserved")
    checkEqual(shortBalance.json["recharge_url"], "https://skystudioai.com/app?credits=1", "server recharge link survives the MCP error")
    runDraftResolutionChecks()
    runOverrideQuoteChecks()
}

/// user_request 里找不找得到每一项越档的名字（纯值，AIOverrideQuote）。
private func runOverrideQuoteChecks() {
    let fourK = AIOverrideQuote.Item(reason: "4K", names: AIOverrideQuote.resolutionNames("4K"))
    let model = AIOverrideQuote.Item(reason: "pricier model", names: ["gpt-image-2", "GPT Image 2"])
    let highest = AIOverrideQuote.Item(reason: "highest", names: AIOverrideQuote.highestQualityNames)
    let ten = AIOverrideQuote.Item(reason: "10 s", names: AIOverrideQuote.durationNames(10))
    checkEqual(AIOverrideQuote.resolutionNames("4K"), ["4K", "2160p", "2160"], "4K can be said as 4K, 2160p or 2160")
    check(AIOverrideQuote.unnamed([fourK], in: "给这个工程生成一张 4k 的封面").isEmpty, "4K named in Chinese, any case")
    check(AIOverrideQuote.unnamed([fourK], in: "export a 2160p cover").isEmpty, "4K named as 2160p")
    check(AIOverrideQuote.unnamed([model], in: "用 GPT Image 2 生成").isEmpty, "a model named with spaces matches its id")
    check(AIOverrideQuote.unnamed([highest], in: "用最高画质").isEmpty, "the highest tier named as 最高画质")
    check(AIOverrideQuote.unnamed([ten], in: "make it 10 seconds long").isEmpty, "a duration named in seconds")
    check(AIOverrideQuote.unnamed([ten], in: "要 10 秒").isEmpty, "a duration named in 秒")
    for wish in ["画质尽量好", "给这个工程生成一张封面图，画质尽量好。", "要最好的", "best quality", "as good as possible", "高清一点"] {
        checkEqual(AIOverrideQuote.unnamed([fourK, highest, model], in: wish).count, 3, "\"\(wish)\" names no setting")
    }
    checkEqual(AIOverrideQuote.unnamed([fourK, model], in: nil).count, 2, "no user_request names nothing")
    checkEqual(AIOverrideQuote.unnamed([fourK, model], in: "   ").count, 2, "blank user_request names nothing")
    checkEqual(AIOverrideQuote.unnamed([fourK, model], in: "4K please"), [model], "only the unnamed setting is reported")
    check(AIOverrideQuote.unnamed([.init(reason: "paid", names: [])], in: "yes do it").isEmpty, "an item with no name only needs the user's words")
    check(!AIOverrideQuote.unnamed([.init(reason: "paid", names: [])], in: "").isEmpty, "…and still needs them")
    check(AIOverrideQuote.unnamed([.init(reason: "upscale", names: AIOverrideQuote.upscaleNames)], in: "把这段放大到 4K").isEmpty, "upscale named as 放大")
    check(!AIOverrideQuote.unnamed([.init(reason: "upscale", names: AIOverrideQuote.upscaleNames)], in: "画质尽量好").isEmpty, "a quality wish is not an upscale request")
}

private func runDraftResolutionChecks() {
    let nano = SkyStudioModel(id: "nano2", kind: "image", title: "Nano", params: ["resolution": ["4K", "1K", "2K"]], defaults: ["resolution": "2K"])
    checkEqual(AIDraftPolicy.resolution(model: nano, mode: "images"), "1K", "old catalogs cannot make Nano drafts 2K")
    let seedream = SkyStudioModel(id: "seedream5-flash", kind: "image", title: "Seedream", params: ["resolution": ["2K"]])
    checkEqual(AIDraftPolicy.resolution(model: seedream, mode: "images"), "2K", "Seedream uses its genuine minimum")
    let h3 = SkyStudioModel(id: "minimax-h3", kind: "text_to_video", title: "H3", params: ["resolution": ["480p", "768p", "2K", "4K"]], defaults: ["duration": 5, "resolution": "2K"])
    let draft = SkyStudioGeneration.make(.textToVideo, prompt: "Paris", ask: .init(), canvas: 9.0 / 16, model: h3)
    checkEqual(draft.params["resolution"], "768p", "H3 drafts use 768p even with an expensive old catalog default")
    check(AIDraftPolicy.deviations(draft, model: h3).isEmpty, "draft is allowed")
    let premium = SkyStudioGeneration.make(.textToVideo, prompt: "Paris", ask: .init(duration: 10, resolution: "2K"), canvas: 9.0 / 16, model: h3)
    checkEqual(AIDraftPolicy.deviations(premium, model: h3).count, 2, "both longer and larger requests need approval")
    let omni = SkyStudioModel(id: "omni", kind: "text_to_video", title: "Omni", params: ["resolution": ["360p", "720p", "1080p"]])
    checkEqual(AIDraftPolicy.resolution(model: omni, mode: "frames"), "720p", "720p-class does not silently choose 360p")
    let veo = SkyStudioModel(id: "veo", kind: "text_to_video", title: "Veo", params: ["resolution": ["1080p", "4K"]])
    checkEqual(AIDraftPolicy.resolution(model: veo, mode: "frames"), "1080p", "use a model's actual minimum when no 720p-class tier exists")
}

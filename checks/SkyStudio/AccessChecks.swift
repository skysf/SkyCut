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

    func decide(_ args: JSONValue = [:], reason: String? = "2K exceeds the draft", profile: String = "h3-2k", project: String = "account/project") -> SkyStudioJobGate.Decision? {
        try? SkyStudioJobGate.decide(credits: 130, summary: "H3 2K", identity: "exact-request", args: AIToolArguments(args),
            store: spend, access: access, reason: reason, project: project, profile: profile)
    }
    access.setMode(.ask)
    if case .needsConfirmation(let result) = decide() { checkEqual(result.payload["status"]?.stringValue, "needs_confirmation", "premium draft asks") }
    else { check(false, "premium draft must ask") }
    checkEqual(spend.spentToday(), 0, "an approval question reserves no credits")
    if case .reserved = decide(reason: nil) { check(true, "ordinary drafts proceed") }
    else { check(false, "ordinary drafts proceed") }
    if case .reserved = decide(["user_requested_overrides": true]) { check(true, "explicit user-requested specification is not asked twice") }
    else { check(false, "explicit specification can proceed") }

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

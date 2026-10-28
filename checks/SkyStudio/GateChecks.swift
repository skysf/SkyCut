import Foundation
import SrtFlowMCPKit

// SkyCutGates：照授权拦（收费方案第 5 刀第二步）—— 先关着、测试开关只能打开；AI 的工具让不让用（get_status 永远让）；
// 导出带不带水印；被挡住时回给 AI 的话（没做、为什么、请用户做什么）；get_status 里的 skycut_plan；导出带了水印时那一句。

func runGateChecks() {
    // 1. 先关着：接口上线、用户给自己开了正式版之后单独一个 PR 打开（同时改这一条）。测试开关只能打开。
    checkEqual(SkyCutGates.enforcedByDefault, false, "the gates stay off until Sky Studio's API is live and the owner has Pro")
    checkEqual(SkyCutGates.testingKey, "skystudio.testGates", "the testing switch's key")
    let suite = "skycut-gate-checks"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check(false, "a scratch UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    check(!SkyCutGates.enforced(defaults), "off by default")
    defaults.set(true, forKey: SkyCutGates.testingKey)
    check(SkyCutGates.enforced(defaults), "the testing switch turns them on")

    let now = moment()
    let free = SkyCutLicense(plan: .free, mcp: false, watermark: true, basis: .server, validUntil: moment(3 * 86_400))
    let trial = SkyCutLicense(
        plan: .trial, mcp: true, watermark: true, basis: .server, trialEndsAt: moment(5 * 86_400 + 60), validUntil: moment(3 * 86_400)
    )
    let pro = SkyCutLicense(plan: .pro, mcp: true, watermark: false, basis: .server, paidUntil: moment(365 * 86_400), validUntil: moment(3 * 86_400))
    var proWithoutAI = pro
    proWithoutAI.mcp = false

    // 2. AI 的工具：关着时都让；开着时只听 mcp，get_status 永远让。
    for tool in MCPToolName.allCases {
        check(SkyCutGates.aiAllows(tool, license: .free(.noKey), enforced: false), "gates off: \(tool.rawValue) runs")
        checkEqual(
            SkyCutGates.aiAllows(tool, license: .free(.noKey), enforced: true), tool == .getStatus,
            "no key: only get_status runs (\(tool.rawValue))"
        )
        checkEqual(SkyCutGates.aiAllows(tool, license: free, enforced: true), tool == .getStatus, "free plan: only get_status (\(tool.rawValue))")
        check(SkyCutGates.aiAllows(tool, license: trial, enforced: true), "trial: \(tool.rawValue) runs")
        check(SkyCutGates.aiAllows(tool, license: pro, enforced: true), "pro: \(tool.rawValue) runs")
    }
    check(!SkyCutGates.aiAllows(.addClips, license: proWithoutAI, enforced: true), "a plan without mcp is refused, whatever its name")
    for basis in [SkyCutLicense.Basis.notChecked, .expired] {
        check(!SkyCutGates.aiAllows(.exportVideo, license: .free(basis), enforced: true), "\(basis): refused")
    }

    // 3. 导出的水印：关着时不因为授权加；开着时听服务器的。
    check(!SkyCutGates.watermark(license: free, enforced: false), "gates off: no licence watermark")
    check(SkyCutGates.watermark(license: free, enforced: true), "free: watermark")
    check(SkyCutGates.watermark(license: trial, enforced: true), "trial: watermark (the server says so)")
    check(!SkyCutGates.watermark(license: pro, enforced: true), "pro: no watermark")
    check(SkyCutGates.watermark(license: .free(.expired), enforced: true), "an expired check: watermark")

    runRefusalChecks(free: free, now: now)
    runStatusChecks(free: free, trial: trial, pro: pro, now: now)
}

/// 被挡住时回给 AI 的话：都以「Not done」开头、说为什么、请用户做什么，结尾指到 get_status。
private func runRefusalChecks(free: SkyCutLicense, now: Date) {
    let email = SkyStudioLinks.supportEmail
    func says(_ text: String, _ parts: [String], _ what: String) {
        check(text.hasPrefix("Not done: "), "\(what): starts with Not done")
        check(text.hasSuffix("get_status shows the plan."), "\(what): points at get_status")
        for part in parts { check(text.contains(part), "\(what) mentions \(part): \(text)") }
    }

    let noKey = SkyCutGates.aiRefusal(license: .free(.noKey), problem: nil, now: now)
    says(noKey, ["no Sky Studio API key", "skystudioai.com (Settings → SkyCut)", "SkyCut Settings → Sky Studio", email], "no key")

    says(SkyCutGates.aiRefusal(license: free, problem: nil, now: now), ["free plan", email], "free plan")
    check(!SkyCutGates.aiRefusal(license: free, problem: nil, now: now).contains("paste"), "free plan with a key: no paste-a-key advice")
    var machineUsed = free
    machineUsed.trialUnavailable = "machine_used"
    says(SkyCutGates.aiRefusal(license: machineUsed, problem: nil, now: now), ["already had a SkyCut trial", email], "machine_used")

    let offline = SkyCutGates.aiRefusal(license: .free(.expired), problem: .unreachable("Could not reach Sky Studio (offline)."), now: now)
    says(offline, ["has run out", "could not reach Sky Studio", "Check Again"], "expired and offline")
    check(!offline.contains("(offline)"), "the UI-language detail stays out of the AI's text")

    says(
        SkyCutGates.aiRefusal(license: .free(.notChecked), problem: .needsKeychainPermission, now: now),
        ["not been able to check", "keychain", "click Allow"], "keychain permission"
    )
    says(
        SkyCutGates.aiRefusal(license: .free(.noKey), problem: .keyRejected("This API key was revoked."), now: now),
        ["did not accept the API key: This API key was revoked.", "paste it", email], "key rejected"
    )
    says(
        SkyCutGates.aiRefusal(license: .free(.notChecked), problem: .updateRequired("Update SkyCut.", nil), now: now),
        ["needs a newer SkyCut", "update SkyCut"], "update required"
    )
    check(SkyCutGates.watermarkNote.contains("watermark") && SkyCutGates.watermarkNote.contains(email), "the export note says why and how")
}

/// get_status 里的 skycut_plan。
private func runStatusChecks(free: SkyCutLicense, trial: SkyCutLicense, pro: SkyCutLicense, now: Date) {
    let trialPlan = SkyCutGates.statusJSON(license: trial, problem: nil, now: now).objectValue ?? [:]
    checkEqual(trialPlan["plan"]?.stringValue, "trial", "trial: plan")
    checkEqual(trialPlan["source"]?.stringValue, "sky_studio", "trial: from Sky Studio")
    checkEqual(trialPlan["ai_tools"]?.boolValue, true, "trial: AI tools")
    checkEqual(trialPlan["export_watermark"]?.boolValue, true, "trial: watermark")
    checkEqual(trialPlan["trial_days_left"]?.intValue, 6, "trial: 5 days and a minute left shows as 6")
    check(trialPlan["next_step"]?.stringValue?.contains(SkyStudioLinks.supportEmail) == true, "trial: how to drop the watermark")

    let proPlan = SkyCutGates.statusJSON(license: pro, problem: nil, now: now).objectValue ?? [:]
    checkEqual(proPlan["plan"]?.stringValue, "pro", "pro: plan")
    checkEqual(proPlan["pro_until"]?.stringValue, "2027-10-27", "pro: until when (a date)")
    check(proPlan["next_step"] == nil && proPlan["trial_days_left"] == nil, "pro: nothing to do")

    let none = SkyCutGates.statusJSON(license: .free(.noKey), problem: nil, now: now).objectValue ?? [:]
    checkEqual(none["source"]?.stringValue, "no_key", "no key: source")
    checkEqual(none["ai_tools"]?.boolValue, false, "no key: no AI tools")
    check(none["next_step"]?.stringValue?.contains("paste it") == true, "no key: says to paste one")

    let stale = SkyCutGates.statusJSON(license: .free(.expired), problem: .unreachable("x"), now: now).objectValue ?? [:]
    checkEqual(stale["source"]?.stringValue, "check_expired", "expired: source")
    checkEqual(stale["problem"]?.stringValue, "SkyCut could not reach Sky Studio just now.", "expired: what went wrong")
    checkEqual(SkyCutGates.statusJSON(license: free, problem: nil, now: now).objectValue?["plan"]?.stringValue, "free", "free: plan")
}

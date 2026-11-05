import Foundation

// 自助购买合同 v1：新字段向后兼容、缓存不丢字段、购买地址进入此刻授权和 AI 的下一步。
// JSON 来自冻结合同的字段与第三台 Mac 样例，含 pro_source 补充；不连真服务器，不改变授权规则。

func runProPurchaseChecks() {
    for name in ["me-pro-v1", "me-free-purchase-v1", "me-machine-limit-v1", "me-machine-limit-purchase-v1", "me-grace-v1", "me-purchase-unavailable-v1"] {
        let url = URL(fileURLWithPath: "checks/SkyStudio/Fixtures/\(name).json")
        do {
            let data = try Data(contentsOf: url)
            let me = try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: data)
            let stored = SkyStudioStoredAnswer(me: me, receivedAt: me.serverTime.addingTimeInterval(-3 * 3600))
            let saved = try SkyStudioJSON.encoder().encode(stored)
            checkEqual(try SkyStudioJSON.decoder().decode(SkyStudioStoredAnswer.self, from: saved), stored, "\(name): all fields survive the answer cache")
            let license = SkyCutLicense.evaluate(stored, hasKey: true, now: stored.receivedAt)
            checkEqual(license.plan?.rawValue, me.skycut.plan, "\(name): current Mac plan comes from plan")
            checkEqual(license.mcp, me.skycut.features.mcp, "\(name): MCP only follows features")
            checkEqual(license.watermark, me.skycut.features.watermark, "\(name): watermark only follows features")
            checkEqual(me.skycut.machines?.limit, 2, "\(name): machines.limit")
            checkEqual(me.skycut.machines?.windowDays, 30, "\(name): machines.window_days")
            let limited = name.hasPrefix("me-machine-limit-")
            checkEqual(me.skycut.machines?.currentAllowed, !limited, "\(name): machines.current_allowed")
            checkEqual(me.skycut.proSource, me.skycut.plan == "pro" ? "subscription" : nil, "\(name): pro_source")
            checkEqual(me.skycut.manageMachinesURL?.absoluteString, "https://skystudioai.com/app/skycut/machines", "\(name): management URL is independent of purchasing")
            if limited {
                checkEqual(me.skycut.accountPlan, "pro", "a limited Mac still reports the account's Pro")
                checkEqual(me.skycut.planReason, "machine_limit_reached", "machine limit is a plan reason, not an HTTP error")
                checkEqual(me.skycut.planMessage, "This account is already using SkyCut on 2 Macs. This Mac is using the free plan. Remove a Mac in Sky Studio to use this account here.", "the frozen machine-limit message")
                checkEqual(me.skycut.autoRenews, false, "false is not nil")
                checkEqual(me.skycut.machines?.currentAllowed, false, "current Mac is not allowed")
                checkEqual(me.skycut.machines?.used, 2, "machines.used")
                check(license.plan == .free && !license.mcp && license.watermark, "account_plan and paid_until cannot upgrade this Mac")
                checkEqual(license.upgradeURL == nil, name == "me-machine-limit-v1", "both absent and enabled purchase configurations are covered")
                runMachineLimitChecks(me)
            } else if name == "me-grace-v1" {
                checkEqual(me.skycut.autoRenews, true, "a verified renewal is true")
                checkEqual(me.skycut.graceUntil, SkyStudioJSON.parseDate("2026-11-12T00:00:00.250Z"), "grace_until accepts milliseconds")
                checkEqual(me.skycut.graceUntil.map(stored.local), SkyStudioJSON.parseDate("2026-11-11T21:00:00.250Z"), "grace uses the existing server-to-local clock mapping")
                check(license.plan == .pro && license.mcp && !license.watermark, "a past paid_until cannot override the server's valid Pro")
            } else if name == "me-purchase-unavailable-v1" {
                check(me.skycut.autoRenews == nil && me.skycut.graceUntil == nil, "unknown renewal and absent grace remain nil")
                check(license.proActivationURL == nil, "no purchase URL: keep the email fallback")
            }
            try runOptionalProFieldChecks(data)
            runPurchaseDestinationChecks(me)
        } catch {
            check(false, "required v1 fixture \(name) loads and round-trips: \(error)")
        }
    }
}

private func runOptionalProFieldChecks(_ data: Data) throws {
    let fields = ["account_plan", "pro_source", "upgrade_url", "manage_machines_url", "plan_reason", "plan_message", "auto_renews", "grace_until", "machines"]
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let original = object["skycut"] as! [String: Any]
    for key in fields {
        for remove in [true, false] {
            var skycut = original
            if remove { skycut.removeValue(forKey: key) } else { skycut[key] = NSNull() }
            object["skycut"] = skycut
            let me = try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: JSONSerialization.data(withJSONObject: object))
            checkEqual(me.skycut.plan, original["plan"] as? String, "\(key) missing/null does not invalidate the old authorization")
        }
    }
    var legacy = original
    for key in fields { legacy.removeValue(forKey: key) }
    object["skycut"] = legacy
    let old = try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: JSONSerialization.data(withJSONObject: object)).skycut
    check(old.accountPlan == nil && old.proSource == nil && old.upgradeUrl == nil && old.manageMachinesUrl == nil && old.planReason == nil && old.planMessage == nil
          && old.autoRenews == nil && old.graceUntil == nil && old.machines == nil, "old servers leave every new field nil")
    legacy["machines"] = [:] as [String: Any]
    legacy["account_plan"] = "future_plan"
    legacy["plan_reason"] = "future_reason"
    legacy["plan_message"] = "A future server explanation."
    object["skycut"] = legacy
    let future = try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: JSONSerialization.data(withJSONObject: object)).skycut
    checkEqual(future.accountPlan, "future_plan", "an unknown account plan is kept without guessing its features")
    checkEqual(future.planReason, "future_reason", "unknown reasons remain readable")
    checkEqual(future.planMessage, "A future server explanation.", "unknown explanations are preserved")
    check(future.machines?.limit == nil && future.machines?.currentAllowed == nil, "partial optional machine data does not invalidate authorization")
    for source in ["subscription", "one_time", "manual", "future_source"] {
        legacy["pro_source"] = source
        object["skycut"] = legacy
        let me = try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: JSONSerialization.data(withJSONObject: object))
        checkEqual(me.skycut.proSource, source, "pro_source \(source) is read without guessing a plan")
        let encoded = try SkyStudioJSON.encoder().encode(me)
        checkEqual(try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: encoded), me, "pro_source \(source) survives persistence")
    }
}

private func runPurchaseDestinationChecks(_ fixture: SkyStudioMe) {
    let purchase = "https://skystudioai.com/app/skycut/pro"
    let email = SkyStudioLinks.supportEmail
    for plan in ["free", "trial"] {
        var me = fixture
        me.skycut.plan = plan
        // 这里验普通购买入口；台数原因的优先级单独由 runMachineLimitChecks 验证。
        me.skycut.planReason = nil
        me.skycut.planMessage = nil
        me.skycut.upgradeUrl = purchase
        // 体验也可由服务器关闭 MCP；功能只听它说的，不按 plan 猜。
        me.skycut.features = .init(mcp: false, watermark: true)
        let stored = SkyStudioStoredAnswer(me: me, receivedAt: me.serverTime.addingTimeInterval(-3 * 3600))
        let license = SkyCutLicense.evaluate(stored, hasKey: true, now: stored.receivedAt)
        checkEqual(license.proActivationURL?.absoluteString, purchase, "\(plan): the same purchase destination for Settings/export/AI")
        let refusal = SkyCutGates.aiRefusal(license: license, problem: nil, now: stored.receivedAt)
        check(refusal.contains(purchase) && !refusal.contains(email), "\(plan): AI refusal gives the purchase URL instead of email")
        let next = SkyCutGates.statusJSON(license: license, problem: nil, now: stored.receivedAt).objectValue?["next_step"]?.stringValue
        check(next?.contains(purchase) == true, "\(plan): get_status uses the same purchase advice")
        let note = SkyCutGates.watermarkNote(license: license)
        check(note.contains(purchase) && !note.contains(email), "\(plan): the watermark note uses this license's purchase link")
        for badURL in [nil, "", "   ", "javascript:alert(1)", "file:///tmp/pro", "http://skystudioai.com/app/skycut/pro"] as [String?] {
            me.skycut.upgradeUrl = badURL
            let fallback = SkyCutLicense.evaluate(.init(me: me, receivedAt: stored.receivedAt), hasKey: true, now: stored.receivedAt)
            check(fallback.proActivationURL == nil, "\(plan): absent/unsafe purchase URL gives no link")
            check(SkyCutGates.aiRefusal(license: fallback, problem: nil, now: stored.receivedAt).contains(email), "\(plan): absent/unsafe purchase URL keeps the email")
            check(SkyCutGates.watermarkNote(license: fallback).contains(email), "\(plan): watermark note falls back to email")
        }
        check(SkyCutLicense.evaluate(stored, hasKey: false, now: stored.receivedAt).upgradeURL == nil, "no key: no cached purchase link")
        check(SkyCutLicense.evaluate(stored, hasKey: true, now: stored.local(me.skycut.validUntil)).upgradeURL == nil, "expired answer: no stale purchase link")
        me.skycut.plan = "pro"
        me.skycut.upgradeUrl = purchase
        let pro = SkyCutLicense.evaluate(.init(me: me, receivedAt: stored.receivedAt), hasKey: true, now: stored.receivedAt)
        check(pro.upgradeURL != nil && pro.proActivationURL == nil, "a Pro feature override is not a request to buy Pro again")
    }
}

/// 台数说明只从有效回答来；台数满了即使购买已配置，也只能引导管理 Mac / 联系支持。
private func runMachineLimitChecks(_ fixture: SkyStudioMe) {
    let purchase = "https://skystudioai.com/app/skycut/pro"
    let manage = "https://skystudioai.com/app/skycut/machines"
    let email = SkyStudioLinks.supportEmail
    let received = fixture.serverTime.addingTimeInterval(-3 * 3600)
    func evaluate(_ me: SkyStudioMe) -> SkyCutLicense {
        SkyCutLicense.evaluate(.init(me: me, receivedAt: received), hasKey: true, now: received)
    }
    for limit in [1, 2, 5, 19, nil] as [Int?] {
        var me = fixture
        me.skycut.upgradeUrl = purchase
        me.skycut.machines?.limit = limit
        me.skycut.machines?.used = 93 // 不能拿 used 冒充 limit。
        me.skycut.planMessage = "Do not display this server message for a known reason."
        for destination in [manage, nil, "", "javascript:alert(1)", "http://skystudioai.com/machines"] as [String?] {
            me.skycut.manageMachinesUrl = destination
            let license = evaluate(me)
            check(license.isMachineLimited, "the valid plan reason reaches the UI / AI license")
            checkEqual(license.machineLimit, limit, "Mac count comes from limit, not used or a client constant")
            check(license.proActivationURL == nil, "a limited Mac must never be offered a purchase URL")
            check(license.unrecognizedPlanMessage == nil, "known reasons use the client's localized text")
            let next = SkyCutGates.statusJSON(license: license, problem: nil, now: received).objectValue?["next_step"]?.stringValue ?? ""
            let messages = [SkyCutGates.aiRefusal(license: license, problem: nil, now: received), next, SkyCutGates.watermarkNote(license: license)]
            for message in messages {
                check(message.contains("This Mac is using the free plan."), "every AI hint distinguishes the current Mac from the account")
                if let limit {
                    check(message.contains("on \(limit) \(limit == 1 ? "Mac" : "Macs")."), "every AI hint explains the server's Mac limit")
                } else {
                    check(message.contains("has reached its Mac limit"), "a missing optional limit does not invent a number")
                }
                check(!message.contains(purchase) && !message.contains("buy Pro") && !message.contains("activate SkyCut Pro"), "machine management takes priority over buying Pro")
                check(!message.contains(me.skycut.planMessage!), "known plan_message is replaced by the client's wording")
                if destination == manage {
                    check(message.contains(manage) && !message.contains(email), "manage Macs when the server gives a usable URL")
                } else {
                    check(message.contains(email) && !message.contains(manage), "missing/unsafe management URLs fall back to support, never purchase")
                }
            }
        }
    }
    var unknown = fixture
    unknown.skycut.planReason = "future_reason"
    unknown.skycut.planMessage = "A future server explanation."
    let future = evaluate(unknown)
    checkEqual(future.unrecognizedPlanMessage, unknown.skycut.planMessage, "unknown reasons display the server's message verbatim")
    check(SkyCutGates.aiRefusal(license: future, problem: nil, now: received).contains(unknown.skycut.planMessage!), "AI receives an unknown server explanation")
    unknown.skycut.plan = "pro"
    unknown.skycut.features = .init(mcp: true, watermark: false)
    let pro = SkyCutGates.statusJSON(license: evaluate(unknown), problem: nil, now: received).objectValue ?? [:]
    check(pro["next_step"] == nil, "an unknown reason does not create an activation request for valid Pro")
    checkEqual(pro["plan_message"]?.stringValue,
               unknown.skycut.planMessage, "get_status preserves an unknown explanation even without a next step")
    unknown.skycut.planMessage = " \n "
    check(evaluate(unknown).unrecognizedPlanMessage == nil, "blank explanations do not add empty rows")
    let stored = SkyStudioStoredAnswer(me: fixture, receivedAt: received)
    for problem in [SkyStudioProblem.needsKeychainPermission, .updateRequired("Update SkyCut.", nil)] {
        let next = SkyCutGates.statusJSON(license: evaluate(fixture), problem: problem, now: received).objectValue?["next_step"]?.stringValue ?? ""
        check(next.contains("on 2 Macs") && next.contains("This Mac is using the free plan.") && next.contains(manage),
              "a separate refresh problem cannot hide the cached Mac limit and its remedy")
    }
    let discarded = [SkyCutLicense.evaluate(stored, hasKey: false, now: received),
                     SkyCutLicense.evaluate(stored, hasKey: true, now: stored.local(fixture.skycut.validUntil)),
                     SkyCutLicense.evaluate(stored, hasKey: true, now: received.addingTimeInterval(-301))]
    for license in discarded {
        check(!license.isMachineLimited && license.machineLimit == nil && license.manageMachinesURL == nil && license.planMessage == nil,
              "missing key, expired answer or rewound clock clears stale machine instructions")
    }
    // 说明字段不能反过来改变功能，哪怕服务器将来返回了不同组合。
    var override = fixture
    override.skycut.features = .init(mcp: true, watermark: false)
    let license = evaluate(override)
    check(license.mcp && !license.watermark, "machine explanations cannot override the server's feature flags")
}

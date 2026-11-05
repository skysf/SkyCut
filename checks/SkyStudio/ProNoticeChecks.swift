import Foundation
import SrtFlowMCPKit

// Pro 续约提醒：真实合同 fixture、七天 / 到期边界、钟差、商务邮箱、宽限和台数优先级。
// 只检验生产的授权 / 提醒 / AI 状态，不碰网络、钥匙串或支付；界面接线另由 sky-studio-wiring 守着。

func runProNoticeChecks() {
    guard let expiring = proNoticeFixture("me-pro-expiring-v1"),
          let manual = proNoticeFixture("me-pro-manual-expiring-v1"),
          let grace = proNoticeFixture("me-grace-v1") else { return }
    for me in [expiring, manual, grace] {
        let stored = SkyStudioStoredAnswer(me: me, receivedAt: me.serverTime.addingTimeInterval(-3 * 3600))
        do {
            let data = try SkyStudioJSON.encoder().encode(stored)
            let cached = try SkyStudioJSON.decoder().decode(SkyStudioStoredAnswer.self, from: data)
            checkEqual(cached, stored, "renewal fixtures survive the answer cache")
            checkEqual(noticeLicense(cached.me).proNotice, noticeLicense(me).proNotice, "cached fields produce the same notice")
        } catch { check(false, "renewal fixture cache round-trip: \(error)") }
    }
    checkEqual(noticeLicense(expiring).proNotice?.kind, .expiring(days: 3), "one-time fixture has 3 days left")
    checkEqual(noticeLicense(manual).proNotice?.kind, .expiring(days: 3), "manual fixture also gets an expiry reminder")
    check(noticeLicense(manual).proNotice?.actionURL == nil, "manual fixture never links to self-service purchasing")
    checkEqual(noticeLicense(grace).proNotice?.kind, grace.skycut.graceUntil.map { .paymentGrace(until: $0) }, "grace fixture reaches the current license")
    runProExpiryBoundaries(expiring)
    runProRenewalDestinations(expiring)
    runProGraceChecks(grace)
    runProNoticePrecedence(expiring)
    runProNoticeAuthorizationChecks(expiring)
}

private func proNoticeFixture(_ name: String) -> SkyStudioMe? {
    do {
        return try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: Data(contentsOf:
            URL(fileURLWithPath: "checks/SkyStudio/Fixtures/\(name).json")))
    } catch {
        check(false, "required renewal fixture \(name) loads: \(error)")
        return nil
    }
}

private func noticeLicense(_ me: SkyStudioMe, skew: TimeInterval = -3 * 3600, elapsed: TimeInterval = 0) -> SkyCutLicense {
    let received = me.serverTime.addingTimeInterval(skew)
    return SkyCutLicense.evaluate(.init(me: me, receivedAt: received), hasKey: true, now: received.addingTimeInterval(elapsed))
}

private func noticeStatus(_ license: SkyCutLicense) -> [String: JSONValue] {
    SkyCutGates.statusJSON(license: license, problem: nil, now: moment()).objectValue ?? [:]
}

private func runProExpiryBoundaries(_ fixture: SkyStudioMe) {
    let cases: [(TimeInterval, Int?)] = [
        (7 * 86_400 + 0.001, nil), (7 * 86_400, 7), (7 * 86_400 - 0.001, 7),
        (6 * 86_400, 6), (86_400 + 0.001, 2), (86_400, 1), (0.001, 1), (0, nil), (-0.001, nil)
    ]
    for skew in [-11 * 3600, 0, 14 * 3600, 5.072] as [TimeInterval] {
        for (remaining, expected) in cases {
            var me = fixture
            me.skycut.paidUntil = me.serverTime.addingTimeInterval(remaining)
            let license = noticeLicense(me, skew: skew)
            checkEqual(license.proNotice?.kind, expected.map { .expiring(days: $0) }, "\(remaining)s left with \(skew)s clock offset")
            checkEqual(license.paidUntil, me.skycut.paidUntil, "displayed paid date stays the server's moment")
            check(license.mcp && !license.watermark && license.plan == .pro, "expiry metadata never overrides a valid server Pro")
        }
    }
    var me = fixture
    me.skycut.paidUntil = me.serverTime.addingTimeInterval(8 * 86_400)
    check(noticeLicense(me).proNotice == nil, "outside seven days: no reminder")
    checkEqual(noticeLicense(me, elapsed: 86_400).proNotice?.kind, .expiring(days: 7), "the same cached answer enters the window as time passes")
    for renewal in [true, nil] as [Bool?] {
        me = fixture
        me.skycut.autoRenews = renewal
        check(noticeLicense(me).proNotice == nil, "true or unknown renewal is never treated as false")
    }
    me = fixture
    me.skycut.paidUntil = nil
    check(noticeLicense(me).proNotice == nil, "no paid_until: no invented deadline")
}

private func runProRenewalDestinations(_ fixture: SkyStudioMe) {
    for source in ["manual", "one_time", "subscription", "future_source", nil] as [String?] {
        var me = fixture
        me.skycut.proSource = source
        let license = noticeLicense(me)
        let notice = license.proNotice
        checkEqual(notice?.actionURL, source == "manual" ? nil : me.skycut.upgradeURL, "\(source ?? "nil"): correct renewal destination")
        let status = noticeStatus(license)
        let info = status["pro_notice"]?.objectValue ?? [:]
        checkEqual(info["state"]?.stringValue, "expiring", "AI reports expiry state")
        checkEqual(info["days_left"]?.intValue, 3, "AI reports the shared day count")
        checkEqual(info["message"]?.stringValue, "SkyCut Pro expires in 3 days and will not renew automatically.", "AI expiry explanation stays English")
        let action = info["next_step"]?.stringValue ?? ""
        check(action.contains(source == "manual" ? SkyStudioLinks.supportEmail : me.skycut.upgradeUrl!), "AI uses the UI's renewal destination")
        if source == "manual" { check(!action.contains(me.skycut.upgradeUrl!), "manual renewal cannot send AI to purchasing") }
        checkEqual(status["next_step"], info["next_step"], "normal Pro gets an actionable next step without disabling AI")
    }
    for url in [nil, "", "   ", "javascript:alert(1)", "http://skystudioai.com/pro"] as [String?] {
        var me = fixture
        me.skycut.upgradeUrl = url
        let license = noticeLicense(me)
        check(license.proNotice != nil && license.proNotice?.actionURL == nil, "unavailable renewal URL keeps the reminder with email")
        check(noticeStatus(license)["pro_notice"]?.objectValue?["next_step"]?.stringValue?.contains(SkyStudioLinks.supportEmail) == true,
              "AI renewal falls back to support")
    }
    var single = fixture
    single.skycut.paidUntil = single.serverTime.addingTimeInterval(1)
    checkEqual(noticeStatus(noticeLicense(single))["pro_notice"]?.objectValue?["message"]?.stringValue,
               "SkyCut Pro expires in 1 day and will not renew automatically.", "AI has a singular day message")
}

private func runProGraceChecks(_ fixture: SkyStudioMe) {
    var me = fixture
    let end = SkyStudioJSON.parseDate("2026-12-31T15:59:59Z")!
    me.skycut.graceUntil = end
    // 故意同时满足到期提醒；宽限必须优先，且不看 auto_renews（null 也可能有宽限）。
    me.skycut.paidUntil = me.serverTime.addingTimeInterval(86_400)
    for renewal in [false, true, nil] as [Bool?] {
        me.skycut.autoRenews = renewal
        let license = noticeLicense(me, skew: 5.072)
        checkEqual(license.proNotice?.kind, .paymentGrace(until: end), "grace overrides expiry even with unknown renewal")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        if case .paymentGrace(let until)? = license.proNotice?.kind {
            checkEqual(calendar.component(.day, from: until), 31, "late response cannot move the displayed grace date past midnight")
        }
        let status = noticeStatus(license)
        let info = status["pro_notice"]?.objectValue ?? [:]
        checkEqual(info["state"]?.stringValue, "payment_grace", "AI reports payment grace")
        checkEqual(info["until"]?.stringValue, "2026-12-31", "AI uses the same date convention as pro_until")
        checkEqual(info["message"]?.stringValue,
                   "The renewal payment failed. SkyCut Pro is kept until 2026-12-31. Please update the payment method for the existing subscription.",
                   "AI explains the failure, retained Pro and existing subscription in English")
        check(info["days_left"] == nil, "grace does not masquerade as non-renewing expiry")
        checkEqual(status["next_step"], info["next_step"], "payment grace gives the AI an actionable next step")
    }
    for url in [fixture.skycut.upgradeUrl, nil, "", "javascript:alert(1)"] as [String?] {
        me.skycut.upgradeUrl = url
        let license = noticeLicense(me)
        let action = noticeStatus(license)["pro_notice"]?.objectValue?["next_step"]?.stringValue ?? ""
        checkEqual(license.proNotice?.actionURL, me.skycut.upgradeURL, "grace uses only a validated server URL")
        check(action.contains(me.skycut.upgradeURL?.absoluteString ?? SkyStudioLinks.supportEmail), "payment recovery shares the UI's link / email fallback")
        check(action.contains("update the payment method for the existing subscription") && !action.contains("buy"), "grace never suggests buying another subscription")
    }
    check(noticeLicense(fixture).mcp && !noticeLicense(fixture).watermark, "past paid_until during grace does not revoke Pro")
}

private func runProNoticePrecedence(_ fixture: SkyStudioMe) {
    for grace in [nil, fixture.serverTime.addingTimeInterval(5 * 86_400)] as [Date?] {
        for plan in ["free", "pro"] {
            var me = fixture
            me.skycut.plan = plan
            me.skycut.planReason = "machine_limit_reached"
            me.skycut.graceUntil = grace
            me.skycut.features = .init(mcp: false, watermark: true)
            let license = noticeLicense(me)
            check(license.proNotice == nil, "machine limit suppresses both renewal notices")
            let status = noticeStatus(license)
            check(status["pro_notice"] == nil, "AI does not stack a renewal notice on a machine limit")
            let next = status["next_step"]?.stringValue ?? ""
            check(next.contains(me.skycut.manageMachinesUrl!) && !next.contains(me.skycut.upgradeUrl!), "AI keeps machine-management precedence")
        }
    }
    let received = fixture.serverTime.addingTimeInterval(-3 * 3600)
    let stored = SkyStudioStoredAnswer(me: fixture, receivedAt: received)
    for license in [SkyCutLicense.evaluate(stored, hasKey: false, now: received),
                    SkyCutLicense.evaluate(nil, hasKey: true, now: received),
                    SkyCutLicense.evaluate(stored, hasKey: true, now: stored.local(fixture.skycut.validUntil)),
                    SkyCutLicense.evaluate(stored, hasKey: true, now: received.addingTimeInterval(-301))] {
        check(license.proNotice == nil && noticeStatus(license)["pro_notice"] == nil, "no key, no answer, expiry or clock rewind discards old renewal advice")
    }
    var legacy = fixture
    legacy.skycut.autoRenews = nil
    legacy.skycut.proSource = nil
    legacy.skycut.graceUntil = nil
    let license = noticeLicense(legacy)
    check(license.proNotice == nil && noticeStatus(license)["next_step"] == nil, "old servers keep ordinary Pro behavior without guessing renewal state")
}

private func runProNoticeAuthorizationChecks(_ fixture: SkyStudioMe) {
    for grace in [nil, fixture.serverTime.addingTimeInterval(5 * 86_400)] as [Date?] {
        for plan in ["pro", "trial", "free", "future_plan"] {
            for mcp in [false, true] {
                for watermark in [false, true] {
                    var me = fixture
                    me.skycut.plan = plan
                    me.skycut.graceUntil = grace
                    me.skycut.features = .init(mcp: mcp, watermark: watermark)
                    let license = noticeLicense(me)
                    checkEqual(license.mcp, mcp, "renewal metadata cannot change MCP")
                    checkEqual(license.watermark, watermark, "renewal metadata cannot change watermark")
                    checkEqual(license.plan?.rawValue, plan == "future_plan" ? nil : plan, "renewal metadata cannot change plan")
                    if plan != "pro" { check(license.proNotice == nil, "only the current Mac's Pro gets Pro renewal notices") }
                    for tool in MCPToolName.allCases {
                        checkEqual(SkyCutGates.aiAllows(tool, license: license, enforced: true), tool == .getStatus || mcp,
                                   "renewal notices cannot change AI access to \(tool.rawValue)")
                    }
                }
            }
        }
    }
}

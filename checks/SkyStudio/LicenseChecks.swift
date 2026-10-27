import Foundation

// SkyCutLicense：此刻作数的授权（没有 Key / 没问到过 / 过期都按免费版；服务器的钟换成本机的；钟往回拨不作数）；
// SkyStudioRefresh：什么时候再问。

func runLicenseChecks() {
    guard let me = try? SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: Data(sampleMe.utf8)) else {
        check(false, "the /me sample decodes")
        return
    }
    // 本机的钟比服务器慢 3 小时：拿到回答时服务器 15:04:05，本机 12:04:05。
    let receivedAt = moment(-3 * 3600)
    let stored = SkyStudioStoredAnswer(me: me, receivedAt: receivedAt)

    // 1. 没有授权 = 免费版那一组。
    let noKey = SkyCutLicense.evaluate(stored, hasKey: false, now: receivedAt)
    checkEqual(noKey, SkyCutLicense.free(.noKey), "no key: free, whatever was stored")
    check(!noKey.mcp && noKey.watermark && noKey.plan == .free, "free means no MCP and a watermark")
    checkEqual(SkyCutLicense.evaluate(nil, hasKey: true, now: receivedAt), .free(.notChecked), "a key never checked: free")

    // 2. 服务器的回答：照它的 plan 和开关；时间都换成本机的。
    let trial = SkyCutLicense.evaluate(stored, hasKey: true, now: receivedAt.addingTimeInterval(3600))
    checkEqual(trial.basis, .server, "a fresh answer counts")
    checkEqual(trial.plan, .trial, "trial")
    check(trial.mcp && trial.watermark, "trial: MCP on, watermark on (the server said so)")
    checkEqual(trial.trialEndsAt, receivedAt.addingTimeInterval(7 * 86_400), "trial end in local time")
    checkEqual(trial.validUntil, receivedAt.addingTimeInterval(3 * 86_400), "valid_until in local time")
    checkEqual(trial.trialDaysLeft(now: receivedAt.addingTimeInterval(3600)), 7, "6 days 23 hours left shows as 7")
    checkEqual(trial.trialDaysLeft(now: receivedAt.addingTimeInterval(6.5 * 86_400)), 1, "half a day left shows as 1")
    checkEqual(trial.trialDaysLeft(now: receivedAt.addingTimeInterval(7 * 86_400)), nil, "at the end: no days left")

    // 3. 过了 valid_until（本机时间）就不作数，按免费版；差一秒还作数。
    let lastSecond = SkyCutLicense.evaluate(stored, hasKey: true, now: receivedAt.addingTimeInterval(3 * 86_400 - 1))
    checkEqual(lastSecond.basis, .server, "one second before valid_until")
    let expired = SkyCutLicense.evaluate(stored, hasKey: true, now: receivedAt.addingTimeInterval(3 * 86_400))
    checkEqual(expired.basis, .expired, "at valid_until")
    check(!expired.mcp && expired.watermark, "expired: free switches")
    checkEqual(expired.validUntil, receivedAt.addingTimeInterval(3 * 86_400), "expired still says until when it counted")

    // 4. 钟往回拨了：5 分钟以内照用，再往前就不作数。
    checkEqual(SkyCutLicense.evaluate(stored, hasKey: true, now: receivedAt.addingTimeInterval(-240)).basis, .server, "a clock 4 minutes behind")
    checkEqual(SkyCutLicense.evaluate(stored, hasKey: true, now: receivedAt.addingTimeInterval(-600)).basis, .expired, "a clock set back 10 minutes")

    // 5. 正式版、认不出的 plan、没给体验的原因：开关只听服务器的。
    var pro = me
    pro.skycut.plan = "pro"
    pro.skycut.features = SkyStudioMe.Features(mcp: true, watermark: false)
    pro.skycut.paidUntil = moment(365 * 86_400)
    let proLicense = SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: pro, receivedAt: receivedAt), hasKey: true, now: receivedAt)
    check(proLicense.plan == .pro && proLicense.mcp && !proLicense.watermark, "pro: MCP on, no watermark")
    checkEqual(proLicense.paidUntil, receivedAt.addingTimeInterval(365 * 86_400), "paid_until in local time")
    checkEqual(proLicense.trialDaysLeft(now: receivedAt), nil, "pro has no trial days")

    var team = me
    team.skycut.plan = "team"
    team.skycut.features = SkyStudioMe.Features(mcp: false, watermark: false)
    let teamLicense = SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: team, receivedAt: receivedAt), hasKey: true, now: receivedAt)
    check(teamLicense.plan == nil && !teamLicense.mcp && !teamLicense.watermark, "an unknown plan: the server's switches still apply")

    var used = me
    used.skycut.plan = "free"
    used.skycut.features = SkyStudioMe.Features(mcp: false, watermark: true)
    used.skycut.trialUnavailable = "machine_used"
    let usedLicense = SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: used, receivedAt: receivedAt), hasKey: true, now: receivedAt)
    checkEqual(usedLicense.trialUnavailable, "machine_used", "why there is no trial")

    // 6. 什么时候再问。
    let fresh = SkyStudioStoredAnswer(me: me, receivedAt: receivedAt)
    let thirtyMinutes = SkyStudioRefresh.onActivation
    let sixHours = SkyStudioRefresh.inBackground
    check(SkyStudioRefresh.isDue(stored: nil, lastFailure: nil, now: receivedAt, after: thirtyMinutes), "never asked: ask")
    check(!SkyStudioRefresh.isDue(stored: fresh, lastFailure: nil, now: receivedAt.addingTimeInterval(600), after: thirtyMinutes), "asked 10 minutes ago")
    check(SkyStudioRefresh.isDue(stored: fresh, lastFailure: nil, now: receivedAt.addingTimeInterval(1860), after: thirtyMinutes), "asked 31 minutes ago")
    check(!SkyStudioRefresh.isDue(stored: fresh, lastFailure: nil, now: receivedAt.addingTimeInterval(5 * 3600), after: sixHours), "the hourly look: 5 hours")
    check(SkyStudioRefresh.isDue(stored: fresh, lastFailure: nil, now: receivedAt.addingTimeInterval(6 * 3600), after: sixHours), "the hourly look: 6 hours")
    check(SkyStudioRefresh.isDue(stored: fresh, lastFailure: nil, now: receivedAt.addingTimeInterval(-600), after: sixHours), "a clock set back: ask again")
    check(SkyStudioRefresh.isDue(stored: fresh, lastFailure: nil, now: receivedAt.addingTimeInterval(3 * 86_400), after: sixHours), "expired: ask")
    let failedAt = receivedAt.addingTimeInterval(7200)
    check(!SkyStudioRefresh.isDue(stored: nil, lastFailure: failedAt, now: failedAt.addingTimeInterval(120), after: thirtyMinutes), "failed 2 minutes ago: wait")
    check(SkyStudioRefresh.isDue(stored: nil, lastFailure: failedAt, now: failedAt.addingTimeInterval(360), after: thirtyMinutes), "failed 6 minutes ago: try again")
    check(SkyStudioRefresh.isDue(stored: nil, lastFailure: failedAt, now: failedAt.addingTimeInterval(-60), after: thirtyMinutes), "a failure in the future (clock set back): try again")
}

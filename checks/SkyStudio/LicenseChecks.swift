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
    checkEqual(proLicense.paidUntil, pro.skycut.paidUntil, "paid_until stays the server's moment: it is only shown as a date")
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

    runRequestTimeChecks(me)
}

/// 2026-10-28 真服务器上撞到的两处（docs/bugfixes/2026-10-28-trial-and-pro-dates-shown-a-day-late.md）：server_time 取在请求一进来那一刻，
/// 拿到回答比它晚 4–5 秒（请求在路上、写库的时间），SkyCut 把这几秒也当成了两边的钟差：
/// - 体验还剩几天：不满一天算一天，但不超过体验本身的天数（trial_ends_at − trial_started_at）。体验的起点是 3.2 秒后写库时的钟，
///   换算到本机后刚开始的 7 天体验剩「7 天零 3 秒」，设置页显示成 8 天；
/// - 正式版到哪天：只用来显示，照服务器给的那一刻、不换算。北京时间 12-31 23:59:59 挪 5 秒就成了第二年 1 月 1 日。
private func runRequestTimeChecks(_ me: SkyStudioMe) {
    var started = me
    started.serverTime = moment()
    started.skycut.trialStartedAt = moment(3.177)
    started.skycut.trialEndsAt = moment(3.177 + 7 * 86_400)
    started.skycut.validUntil = moment(72 * 3600)
    let receivedAt = moment(4.275)
    let fresh = SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: started, receivedAt: receivedAt), hasKey: true, now: receivedAt)
    checkEqual(fresh.trialDaysLeft(now: receivedAt), 7, "a 7-day trial that began 3.2 s after server_time: 7 days left, not 8")
    checkEqual(fresh.trialDaysLeft(now: receivedAt.addingTimeInterval(86_400 + 60)), 6, "a day and a minute later: 6")

    // 后台改过的体验（设结束日、延长）照它自己的长度封顶：10.5 天的体验刚开始是 11 天。
    var edited = me
    edited.serverTime = moment()
    edited.skycut.trialStartedAt = moment()
    edited.skycut.trialEndsAt = moment(10.5 * 86_400)
    let editedLicense = SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: edited, receivedAt: moment()), hasKey: true, now: moment())
    checkEqual(editedLicense.trialDaysLeft(now: moment()), 11, "a 10.5-day trial at its start: 11 days")

    // 后台「开通到 2099-12-31」= 北京时间那天结束（15:59:59Z）；回答晚到 5 秒，显示的那天还是 12 月 31 日。
    guard let endOfDay = ISO8601DateFormatter().date(from: "2099-12-31T15:59:59Z"), let beijing = TimeZone(identifier: "Asia/Shanghai") else {
        check(false, "the end-of-day sample")
        return
    }
    var pro = me
    pro.serverTime = moment()
    pro.skycut.plan = "pro"
    pro.skycut.features = SkyStudioMe.Features(mcp: true, watermark: false)
    pro.skycut.paidUntil = endOfDay
    let late = SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: pro, receivedAt: moment(5.072)), hasKey: true, now: moment(5.072))
    checkEqual(late.paidUntil, endOfDay, "paid_until is not moved by the 5 s the request took")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = beijing
    checkEqual(late.paidUntil.map { calendar.component(.day, from: $0) }, 31, "Pro until Dec 31 in Beijing, not Jan 1")
}

import Foundation

// /me 的回答怎么读、怎么存（SkyStudioMe / SkyStudioJSON / SkyStudioStoredAnswer / SkyStudioLinks）。

func runMeChecks() {
    let decoder = SkyStudioJSON.decoder()

    // 合同里的样例：每个字段都读得到。
    guard let me = try? decoder.decode(SkyStudioMe.self, from: Data(sampleMe.utf8)) else {
        check(false, "the contract's /me sample decodes")
        return
    }
    checkEqual(me.account.email, "someone@example.com", "email")
    checkEqual(me.credits.balance, 30, "balance")
    checkEqual(me.skycut.plan, "trial", "plan")
    checkEqual(me.skycut.features, SkyStudioMe.Features(mcp: true, watermark: true), "features")
    checkEqual(me.skycut.trialStartedAt, moment(), "trial_started_at")
    checkEqual(me.skycut.trialEndsAt, moment(7 * 86_400), "trial_ends_at")
    checkEqual(me.skycut.validUntil, moment(3 * 86_400), "valid_until")
    checkEqual(me.serverTime, moment(), "server_time")
    check(me.skycut.paidUntil == nil && me.skycut.trialUnavailable == nil, "nulls read as nil")
    checkEqual(me.skycut.minVersion, "0.18.47", "min_version")
    checkEqual(me.skycut.maxRunningJobs, 3, "max_running_jobs")
    checkEqual(me.skycut.rechargeURL?.absoluteString, "https://skystudioai.com/app?credits=1", "recharge_url")

    // 日期带毫秒（JS 的 toISOString()）也认；Foundation 自带的 .iso8601 不认，整份会读不出来。
    let fractional = sampleMe.replacingOccurrences(of: "\"server_time\": \"2026-10-27T15:04:05Z\"", with: "\"server_time\": \"2026-10-27T15:04:05.250Z\"")
    let withMillis = try? decoder.decode(SkyStudioMe.self, from: Data(fractional.utf8))
    check(withMillis.map { abs($0.serverTime.timeIntervalSince(moment(0.25))) < 0.001 } ?? false, "a date with milliseconds")
    checkEqual(SkyStudioJSON.parseDate("2026-10-27T23:04:05+08:00"), moment(), "a date with an offset")
    check(SkyStudioJSON.parseDate("2026-10-27") == nil, "a bare date is not a moment")

    // 读得宽：认不出的字段（下面的 future_field、upgrade_url、new_switch）不管；少了可选的（email、trial_*、paid_until、recharge_url…）不算错。
    let lean = """
    {"account": {"id": "u1"}, "credits": {"balance": 12.5}, "future_field": [1, 2],
     "skycut": {"plan": "pro", "features": {"mcp": true, "watermark": false, "new_switch": true},
                "valid_until": "2026-10-30T15:04:05Z", "upgrade_url": "https://skystudioai.com/skycut?from=app"},
     "server_time": "2026-10-27T15:04:05Z"}
    """
    let leanMe = try? decoder.decode(SkyStudioMe.self, from: Data(lean.utf8))
    check(leanMe != nil, "unknown fields and missing optional ones still decode")
    checkEqual(leanMe?.account.email, nil, "no email")
    checkEqual(leanMe?.credits.balance, 12.5, "a fractional balance")

    // 少了必须的（features、valid_until）读不出来：宁可当成没问到，也不猜。
    let broken = sampleMe.replacingOccurrences(of: "\"valid_until\": \"2026-10-30T15:04:05Z\",", with: "")
    check((try? decoder.decode(SkyStudioMe.self, from: Data(broken.utf8))) == nil, "no valid_until: not an answer")

    // 网址只认 https；本机的假服务器的 http://127.0.0.1 也认；别的（http 到外面、没主机、乱写）当没有。
    checkEqual(SkyStudioLinks.webURL("https://skystudioai.com/skycut")?.host, "skystudioai.com", "https")
    checkEqual(SkyStudioLinks.webURL("http://127.0.0.1:8123/skycut")?.port, 8123, "loopback http")
    check(SkyStudioLinks.webURL("http://skystudioai.com/skycut") == nil, "plain http to the internet is refused")
    check(SkyStudioLinks.webURL("javascript:alert(1)") == nil, "no host, no link")
    check(SkyStudioLinks.webURL("") == nil && SkyStudioLinks.webURL(nil) == nil, "empty is nothing")
    checkEqual(SkyStudioLinks.supportEmail, "support@skystudioai.com", "the address Settings tells people to email to activate Pro")

    // 存下来再读回来一模一样（UserDefaults 里存的就是这份）。
    // 整秒：存的时候只留到毫秒，Date() 那样的零头读回来会差一点（不影响用，但比不了相等）。
    let stored = SkyStudioStoredAnswer(me: me, receivedAt: moment(-3 * 3600))
    if let data = try? SkyStudioJSON.encoder().encode(stored) {
        checkEqual(try? decoder.decode(SkyStudioStoredAnswer.self, from: data), stored, "a stored answer round-trips")
    } else {
        check(false, "a stored answer encodes")
    }

    // 服务器的时间换成本机时间：本机的钟比服务器慢 3 小时，到期时刻也跟着早 3 小时。
    checkEqual(stored.local(moment(7 * 86_400)), moment(7 * 86_400 - 3 * 3600), "server time to local time")
}

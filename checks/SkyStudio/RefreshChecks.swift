import Foundation

// SkyStudioRefresh 的纯规则回归：前台按此刻授权选间隔，后台仍是 6 小时，失败退避优先。
// 不碰网络、钥匙串或 App 生命周期；由 scripts/check-sky-studio.sh 编译、LicenseChecks 调用。

func runRefreshChecks(_ me: SkyStudioMe) {
    let receivedAt = moment(-3 * 3600)
    for plan in ["free", "trial", "pro", "unknown"] {
        var answer = me
        answer.skycut.plan = plan
        let stored = SkyStudioStoredAnswer(me: answer, receivedAt: receivedAt)
        let activationCases: [(TimeInterval, Bool)] = plan == "pro"
            ? [(59, false), (60, false), (61, false), (1799, false), (1800, true), (1860, true)]
            : [(59, false), (60, true), (61, true)]
        for (age, expected) in activationCases {
            checkEqual(SkyStudioRefresh.isDue(stored: stored, lastFailure: nil, now: receivedAt.addingTimeInterval(age), trigger: .activation),
                       expected, "\(plan) activation after \(age) seconds")
        }
        for (age, expected) in [(61.0, false), (5 * 3600.0, false), (6 * 3600.0 - 1, false), (6 * 3600.0, true)] {
            checkEqual(SkyStudioRefresh.isDue(stored: stored, lastFailure: nil, now: receivedAt.addingTimeInterval(age), trigger: .background),
                       expected, "\(plan) background after \(age) seconds")
        }
        check(SkyStudioRefresh.isDue(stored: stored, lastFailure: nil, now: receivedAt, trigger: .beforeUse), "\(plan) before use: no age threshold")
        check(SkyStudioRefresh.isDue(stored: stored, lastFailure: nil, now: receivedAt.addingTimeInterval(-600), trigger: .background), "\(plan) clock set back: ask")
        check(SkyStudioRefresh.isDue(stored: stored, lastFailure: nil, now: receivedAt.addingTimeInterval(3 * 86_400), trigger: .background), "\(plan) expired: ask")
        runRefreshBackoffChecks(stored)
    }

    // 过期的正式版要用 evaluate 得到的免费版；即使上一次刚问过，不等 1 / 30 分钟。
    var expiringPro = me
    expiringPro.skycut.plan = "pro"
    expiringPro.skycut.validUntil = me.serverTime.addingTimeInterval(30)
    let expired = SkyStudioStoredAnswer(me: expiringPro, receivedAt: receivedAt)
    for trigger in [SkyStudioRefresh.Trigger.activation, .background, .beforeUse] {
        check(SkyStudioRefresh.isDue(stored: nil, lastFailure: nil, now: receivedAt, trigger: trigger), "\(trigger) never checked: ask immediately")
        check(SkyStudioRefresh.isDue(stored: expired, lastFailure: nil, now: receivedAt.addingTimeInterval(30), trigger: trigger), "\(trigger) expired Pro: ask immediately")
    }
    runRefreshBackoffChecks(expired)
    runRefreshBackoffChecks(nil)
}

private func runRefreshBackoffChecks(_ stored: SkyStudioStoredAnswer?) {
    let failedAt = (stored?.receivedAt ?? moment()).addingTimeInterval(7 * 3600)
    for trigger in [SkyStudioRefresh.Trigger.activation, .background, .beforeUse] {
        for (age, expected) in [(60.0, false), (120.0, false), (299.0, false), (300.0, true), (360.0, true)] {
            checkEqual(SkyStudioRefresh.isDue(stored: stored, lastFailure: failedAt, now: failedAt.addingTimeInterval(age), trigger: trigger),
                       expected, "\(stored?.me.skycut.plan ?? "not checked") \(trigger): failure \(age) seconds ago")
        }
        check(SkyStudioRefresh.isDue(stored: stored, lastFailure: failedAt, now: failedAt.addingTimeInterval(-60), trigger: trigger),
              "\(trigger) a failure in the future (clock set back): try again")
    }
}

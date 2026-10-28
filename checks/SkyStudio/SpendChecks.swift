import Foundation

// 积分的每日上限和按天的账（SkyStudioSpendStore，收费方案第 6 刀）：默认 1,000 积分、额度内不问 / 超了问、记账和退回按那一天、
// 上限夹在 0 到 100 万之间取整、存下来再读回来一样；积分怎么写（整数不带小数，不是整数留一位）。

@MainActor
func runSpendChecks() {
    let suite = "skycut-spend-checks"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check(false, "a scratch UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SkyStudioSpendStore(defaults: defaults)
    let day = moment()
    checkEqual(store.dailyLimit, 1_000, "the daily limit starts at 1,000 credits (about the old $10 fal default)")
    checkEqual(store.decide(credits: 455, now: day), .allow, "within the limit: no question")
    store.record(455, now: day)
    checkEqual(store.spentToday(now: day), 455, "recorded on that day")
    checkEqual(store.decide(credits: 545, now: day), .allow, "exactly up to the limit: still no question")
    checkEqual(store.decide(credits: 600, now: day), .ask(.overLimit(spent: 455, estimate: 600, limit: 1_000)), "over the limit: ask, saying how far")
    checkEqual(store.spentToday(now: day.addingTimeInterval(2 * 86_400)), 0, "another day starts at nothing")
    store.refund(455, on: day)
    checkEqual(store.spentToday(now: day), 0, "a refund goes back to the day it was recorded")
    store.refund(100, on: day)
    checkEqual(store.spentToday(now: day), 0, "never below nothing")

    store.setDailyLimit(-5)
    checkEqual(store.dailyLimit, 0, "a negative limit is 0 (ask every time)")
    store.setDailyLimit(2_000_000)
    checkEqual(store.dailyLimit, 1_000_000, "at most a million")
    store.setDailyLimit(1_234.4)
    checkEqual(store.dailyLimit, 1_234, "whole credits")
    store.setDailyLimit(.nan)
    checkEqual(store.dailyLimit, 1_000, "not a number: back to the default")
    store.setDailyLimit(1_500)
    store.record(12.5, now: day)
    let reloaded = SkyStudioSpendStore(defaults: defaults)
    checkEqual(reloaded.dailyLimit, 1_500, "the limit is kept")
    checkEqual(reloaded.spentToday(now: day), 12.5, "the ledger is kept")

    checkEqual(SkyStudioCredits.text(455), "455", "whole credits have no decimals")
    checkEqual(SkyStudioCredits.text(1.4), "1.4", "otherwise one decimal")
    checkEqual(SkyStudioCredits.number(2.04), 2.0, "the AI gets one decimal")
}

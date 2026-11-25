import Combine
import Foundation

// Settling and refunding a reservation (Codex CXM3, 2026-11-26; SkyStudioHeldCredits, SkyStudioSpendStore.settle,
// DailySpendLedger.provenDayKey). Each case is Shanghai a second before and after midnight, 60 and 80 booked, a limit of 100:
// - a settlement goes on the day key the reservation was booked on, also after the Mac moved to Tokyo;
// - a reservation saved without a day key refunds or settles only into a day the ledger proves holds it, never into a day worked
//   out in today's time zone (CXM3: the next day's 80 became 20 and 50 more were let through);
// - a settlement is one ledger write: no state written in between has the refund without the charge (CXM3: 60 held, 20 spent,
//   40 charged, killed between two writes: 20 on the books and 70 more let through).
// docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md

@MainActor
func runSettleChecks() {
    let original = NSTimeZone.default
    defer { NSTimeZone.default = original }
    settleDayChecks()
    keylessChecks()
    oneWriteChecks()
}

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// A second before and after the next Shanghai midnight after `moment()` (call with NSTimeZone.default set to Shanghai).
private func aroundMidnight() -> (late: Date, early: Date) {
    let calendar = Calendar.current
    let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: moment())!)
    return (midnight.addingTimeInterval(-1), midnight.addingTimeInterval(1))
}

@MainActor
private func settleDayChecks() {
    let scratch = ScratchDefaults("settle-day-checks")
    defer { scratch.remove() }
    NSTimeZone.default = shanghai
    let store = SkyStudioSpendStore(defaults: scratch.defaults)
    store.setDailyLimit(100)
    let (late, early) = aroundMidnight()
    guard let first = SkyStudioJobGate.reserveWithoutAsking(credits: 60, store: store, now: late),
          let second = SkyStudioJobGate.reserveWithoutAsking(credits: 80, store: store, now: early),
          let firstDay = first.dayKey, let secondDay = second.dayKey else { return check(false, "both reservations are booked with a day key") }
    NSTimeZone.default = tokyo
    var held = SkyStudioHeldCredits(first, store: store)
    held.settle(charged: 40)
    checkEqual(store.ledger.days[firstDay], 40, "a settlement in Tokyo goes on the day key the 60 was booked on")
    checkEqual(store.ledger.days[secondDay], 80, "and the next day's 80 is untouched")
    NSTimeZone.default = shanghai
    checkEqual(store.decide(credits: 50, now: early), .overLimit(spent: 80, estimate: 50, limit: 100), "so its limit still holds")
}

@MainActor
private func keylessChecks() {
    let scratch = ScratchDefaults("settle-keyless-checks")
    defer { scratch.remove() }
    NSTimeZone.default = shanghai
    let store = SkyStudioSpendStore(defaults: scratch.defaults)
    store.setDailyLimit(100)
    let (late, early) = aroundMidnight()
    let firstDay = store.record(60, now: late), secondDay = store.record(80, now: early)
    NSTimeZone.default = tokyo
    var refunded = SkyStudioHeldCredits(.init(credits: 60, day: late, dayKey: nil), store: store)
    refunded.refund()
    checkEqual(store.ledger.days[secondDay], 80, "a keyless refund in Tokyo does not cut the next day's 80 (both days could hold the 60)")
    checkEqual(store.ledger.days[firstDay], 60, "and nothing is refunded: the books count more, never less")
    var settled = SkyStudioHeldCredits(.init(credits: 60, day: late, dayKey: nil), store: store)
    settled.settle(charged: 40)
    check(store.ledger.days[firstDay] == 60 && store.ledger.days[secondDay] == 80, "nor is a keyless settlement guessed: \(store.ledger.days)")
    NSTimeZone.default = shanghai
    checkEqual(store.decide(credits: 50, now: early), .overLimit(spent: 80, estimate: 50, limit: 100), "the next day's limit still holds")

    // Proven: 60 booked at Shanghai noon. Of the two days that moment falls on around the world, only one holds 60, so a keyless
    // refund comes out of it and a keyless settlement goes into it, also in Tokyo.
    let noon = late.addingTimeInterval(-12 * 3_600 + 1)
    checkEqual(DailySpendLedger.possibleDayKeys(for: noon).count, 2, "noon in Shanghai falls on two days around the world")
    for settles in [false, true] {
        let other = ScratchDefaults("settle-proven-checks")
        defer { other.remove() }
        NSTimeZone.default = shanghai
        let alone = SkyStudioSpendStore(defaults: other.defaults)
        let noonDay = alone.record(60, now: noon)
        NSTimeZone.default = tokyo
        var held = SkyStudioHeldCredits(.init(credits: 60, day: noon, dayKey: nil), store: alone)
        if settles {
            held.settle(charged: 40)
            checkEqual(alone.ledger.days, [noonDay: 40], "a keyless settlement goes into the one day that holds the booking")
        } else {
            held.refund()
            checkEqual(alone.ledger.days, [:], "a keyless refund comes out of the one day that holds the booking")
        }
    }
}

@MainActor
private func oneWriteChecks() {
    let scratch = ScratchDefaults("settle-one-write-checks")
    defer { scratch.remove() }
    NSTimeZone.default = shanghai
    let store = SkyStudioSpendStore(defaults: scratch.defaults)
    store.setDailyLimit(100)
    guard let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: 60, store: store, now: moment()),
          let day = reservation.dayKey else { return check(false, "60 is reserved with a day key") }
    store.record(20, now: moment())
    // Every ledger the store writes is published once (save assigns it, then writes it to the defaults): these are the states a
    // kill could leave on disk.
    var written: [DailySpendLedger] = []
    let watch = store.$ledger.dropFirst().sink { written.append($0) }
    var held = SkyStudioHeldCredits(reservation, store: store)
    held.settle(charged: 40)
    watch.cancel()
    checkEqual(written.map { $0.days[day] ?? 0 }, [60], "settling 60 to 40 next to 20 spent writes the ledger once, at 60")
    checkEqual(SkyStudioSpendStore(defaults: scratch.defaults).ledger.days[day], 60, "and the stored ledger reads back 60")
    checkEqual(store.decide(credits: 50, now: moment()), .overLimit(spent: 60, estimate: 50, limit: 100), "so 50 more is still refused")
}

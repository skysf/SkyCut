import Foundation

// scripts/check-app-update.sh: the window of SkyCut › Check for Updates… (UPD1, 2026-11-28), pure parts.
// - It opens at once from the menu: the state machine's `.openCheckWindow`, only for the menu's check.
// - What shows when (AppUpdateCheckFlow): a quick answer straight on it, else checking after 0.5 s, kept at least 0.5 s;
//   Try Again; Cancel stops the check; closing only hides it and never stops a check or a download; the menu item brings
//   it back on a running download without a check.
// - What it draws (AppUpdateCheckDisplay): a found release followed from the updater's state alone, its progress included.
// - The menu item (AppUpdateMenuEntry): greyed while any check runs, the percent while a download runs.
// The window itself, the run-loop rule and the wiring: checks/app-update-wiring.sh section 10.

enum CheckWindowChecks {
    static func run(check: (Bool, String) -> Void) {
        print("==> the check window")
        guard let feed = FeedChecks.feed(FeedChecks.valid()), let newer = FeedChecks.feed(FeedChecks.valid(version: "0.19.1")) else {
            return check(false, "fixture feeds parse")
        }
        opensAtOnce(check)
        timing(check)
        closing(feed, check)
        cancel(feed, check)
        display(feed, newer, check)
        menu(feed, check)
        reopening(feed, check)
    }

    private static let auto = AppUpdateMode.install(automatic: true)
    private static let manualMode = AppUpdateMode.install(automatic: false)
    private static let tells = AppUpdateMode.notifyOnly(.folderNotWritable)
    private typealias Flow = AppUpdateCheckFlow

    private static func done(_ result: AppUpdateCheckResult) -> AppUpdateEvent { .checkFinished(result, at: StateChecks.t0) }

    /// A state holding `feed` as found by a check, in `mode`.
    private static func found(_ feed: AppUpdateFeed, _ mode: AppUpdateMode) -> AppUpdateState {
        var state = AppUpdateState()
        _ = state.apply(.checkStarted(.menu), mode: mode)
        _ = state.apply(done(.offer(feed)), mode: mode)
        return state
    }

    private static func opensAtOnce(_ check: (Bool, String) -> Void) {
        var menu = AppUpdateState()
        check(menu.apply(.checkStarted(.menu), mode: auto) == [.openCheckWindow] && menu.personChecking,
              "the menu's check opens its window as it starts")
        var schedule = AppUpdateState(), settings = AppUpdateState()
        check(schedule.apply(.checkStarted(.schedule), mode: auto).isEmpty && settings.apply(.checkStarted(.settings), mode: auto).isEmpty,
              "the schedule's and Settings' checks open nothing")
        check(schedule.apply(.checkStarted(.menu), mode: auto) == [.openCheckWindow],
              "the menu joining the schedule's check in flight opens the window too")
        var only = AppUpdateState()
        check(only.apply(.checkStarted(.menu), mode: tells) == [.openCheckWindow], "a copy that only tells gets the window too")
        check(Flow.grace == 0.5 && Flow.minimumChecking == 0.5, "the fast path is 0.5 s and the checking state stays 0.5 s")
        var flow = Flow()
        check(flow.chosen(at: 100) == Flow.Step(tickAt: 100.5) && flow.shows == nil, "chosen: a tick at the end of the grace period")
        check(flow.tick(at: 100.3) == Flow.Step(tickAt: 100.5) && flow.shows == nil, "an early tick shows nothing and asks again")
        check(flow.tick(at: 100.5) == Flow.Step(opens: true) && flow.shows == .checking, "no answer after 0.5 s: the window opens checking")
    }

    private static func timing(_ check: (Bool, String) -> Void) {
        var quick = Flow()
        _ = quick.chosen(at: 0)
        check(quick.answered(.upToDate, at: 0.49) == Flow.Step(opens: true) && quick.shows == .answer(.upToDate),
              "an answer within 0.5 s opens the window straight on it: the checking state never flashes")
        check(quick.tick(at: 0.5) == Flow.Step() && quick.shows == .answer(.upToDate), "the grace tick that comes after changes nothing")
        var slow = Flow()
        _ = slow.chosen(at: 0)
        _ = slow.tick(at: 0.5)
        check(slow.answered(.failed, at: 0.6) == Flow.Step(tickAt: 1.0) && slow.shows == .checking,
              "an answer 0.1 s after the checking state showed waits until it has shown 0.5 s")
        check(slow.tick(at: 0.8) == Flow.Step(tickAt: 1.0) && slow.shows == .checking, "an early tick keeps it waiting")
        check(slow.tick(at: 1.0) == Flow.Step() && slow.shows == .answer(.failed), "then the answer replaces it in place (no re-open)")
        var late = Flow()
        _ = late.chosen(at: 0)
        _ = late.tick(at: 0.5)
        check(late.answered(.upToDate, at: 1.2) == Flow.Step() && late.shows == .answer(.upToDate),
              "an answer after the minimum replaces checking at once, in place")
        check(late.answered(.failed, at: 1.3) == Flow.Step() && late.shows == .answer(.upToDate), "a second answer changes nothing")
        check(late.chosen(at: 5) == Flow.Step() && late.shows == .checking, "Try Again: checking at once, where the window is")
        check(late.answered(.upToDate, at: 5.1) == Flow.Step(tickAt: 5.5) && late.shows == .checking,
              "…and a quick answer to it waits for 0.5 s of checking")
        _ = late.tick(at: 5.5)
        check(late.shows == .answer(.upToDate), "…then shows")
    }

    private static func closing(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var flow = Flow()
        _ = flow.chosen(at: 0)
        _ = flow.tick(at: 0.5)
        let closed = flow.closed()
        check(closed == Flow.Step(closes: true) && !closed.stopsCheck && flow.shows == nil && flow.hidden,
              "the close button while checking hides the window; the check is not stopped")
        check(flow.answered(.downloading(feed), at: 9) == Flow.Step() && flow.shows == nil && !flow.hidden,
              "its answer never brings the window back")
        var held = Flow()
        _ = held.chosen(at: 0)
        _ = held.tick(at: 0.5)
        _ = held.answered(.upToDate, at: 0.6)
        check(held.closed() == Flow.Step(closes: true) && !held.hidden, "closed while an answer waits: the check is over, nothing waits")
        var answer = Flow()
        _ = answer.chosen(at: 0)
        _ = answer.answered(.downloading(feed), at: 0.2)
        check(answer.closed() == Flow.Step(closes: true) && answer.shows == nil && !answer.hidden,
              "closing a download's window (OK, Later, the close button) only closes it")
        var nothing = Flow()
        check(nothing.closed() == Flow.Step(), "closing nothing does nothing")
    }

    private static func cancel(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var flow = Flow()
        _ = flow.chosen(at: 0)
        _ = flow.tick(at: 0.5)
        check(flow.cancelled() == Flow.Step(closes: true, stopsCheck: true) && flow == Flow(), "Cancel stops the check and closes the window")
        check(flow.answered(.upToDate, at: 1) == Flow.Step() && flow.shows == nil, "a late answer after Cancel shows nothing")
        var state = AppUpdateState()
        _ = state.apply(.checkStarted(.menu), mode: auto)
        check(state.apply(.checkCancelled, mode: auto) == [.stopCheck] && !state.checking && !state.personChecking && !state.personStarted,
              "the cancelled check stops")
        check(!state.lastCheckFailed && state.phase == .idle, "a cancelled check is not a failed one")
        let staged = AppUpdateStagedRecord(feed: feed, appPath: "/x/staged.noindex/0.19.0/SkyCut.app", asked: false)
        let retry = AppUpdateRetryRecord.counting(nil, failureOf: feed, at: StateChecks.t0)
        var launch = AppUpdateState.atLaunch(staged: staged, updated: nil, retry: retry, mode: auto, running: AppUpdateVersion("0.18.73")!)
        _ = launch.apply(.checkStarted(.menu), mode: auto)
        _ = launch.apply(.checkCancelled, mode: auto)
        check(launch.unconfirmed == staged && launch.phase == .idle && launch.pill == nil && launch.retry == retry,
              "a cancelled check settles nothing: an earlier run's staged copy stays unconfirmed, the retry record as it was")
        var shared = AppUpdateState()
        _ = shared.apply(.checkStarted(.menu), mode: auto)
        _ = shared.apply(.checkStarted(.schedule), mode: auto)
        check(shared.apply(.checkCancelled, mode: auto).isEmpty && shared.checking && !shared.personChecking && !shared.personStarted,
              "the schedule's check sharing it: Cancel ends only the person's part, the check goes on")
        check(!shared.apply(done(.upToDate), mode: auto).contains { if case .answer = $0 { return true } else { return false } },
              "…and its answer is never shown")
        var first = AppUpdateState()
        _ = first.apply(.checkStarted(.schedule), mode: auto)
        _ = first.apply(.checkStarted(.menu), mode: auto)
        check(first.apply(.checkCancelled, mode: auto).isEmpty && first.checking, "the menu joining the schedule's check: the same")
        // Review CXU1 §1: Settings' check, then the window's Try Again joining it, then Cancel.
        var settings = AppUpdateState()
        _ = settings.apply(.checkStarted(.settings), mode: auto)
        _ = settings.apply(.checkStarted(.menu), mode: auto)
        let kept = settings.apply(.checkCancelled, mode: auto)
        check(kept.isEmpty && settings.checking && settings.personStarted && !settings.personChecking,
              "Settings' check shared by the window: Cancel stops nothing, the check stays Settings' (got \(kept))")
        let answered = settings.apply(done(.offer(feed)), mode: auto)
        check(answered == [.discardDownloads(keeping: feed), .download(feed)] && settings.phase == .downloading && !settings.lastCheckFailed,
              "…Settings gets its answer and the download starts, with no window answer (got \(answered))")
        var idle = AppUpdateState()
        check(idle.apply(.checkCancelled, mode: auto).isEmpty, "Cancel with no check running does nothing")
        var downloading = found(feed, auto)
        _ = downloading.apply(.downloadProgress(0.4), mode: auto)
        _ = downloading.apply(.checkStarted(.menu), mode: auto)
        let stopped = downloading.apply(.checkCancelled, mode: auto)
        check(stopped == [.stopCheck] && downloading.phase == .downloading && downloading.offer == feed && downloading.progress == 0.4,
              "Cancel during a download stops only the check: the download goes on (got \(stopped))")
    }

    private static func display(_ feed: AppUpdateFeed, _ newer: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        let make = AppUpdateCheckDisplay.make
        check(make(.checking, AppUpdateState(), auto) == .checking && make(.answer(.upToDate), AppUpdateState(), auto) == .upToDate
              && make(.answer(.failed), AppUpdateState(), auto) == .couldNotCheck, "checking, up to date and couldn't check as answered")
        let shows = Flow.Shows.answer(.downloading(feed))
        var state = found(feed, auto)
        check(make(shows, state, auto) == .downloading(feed, fraction: nil), "a found release downloads: the window shows the download")
        for fraction in [0.1, 0.2905, 1.0] {
            _ = state.apply(.downloadProgress(fraction), mode: auto)
            check(make(shows, state, auto) == .downloading(feed, fraction: fraction), "the updater's progress \(fraction) is the window's")
        }
        _ = state.apply(.staged(feed), mode: auto)
        check(make(shows, state, auto) == .ready(feed), "verified and staged: ready")
        _ = state.apply(.restartRequested, mode: auto)
        check(make(shows, state, auto) == .waitingToRestart(feed), "Restart and Update waiting for running work: the waiting list")
        _ = state.apply(.restartCancelled, mode: auto)
        check(make(shows, state, auto) == .ready(feed), "Cancel Restart: ready again")
        for (event, name) in [(AppUpdateEvent.downloadFailed, "didn't complete"), (.downloadRejected(feed, at: StateChecks.t0), "was rejected")] {
            var failed = found(feed, auto)
            _ = failed.apply(event, mode: auto)
            check(make(shows, failed, auto) == .downloadFailed(feed, asked: false),
                  "an automatic download that \(name): the download didn't finish, Try Again checks again")
        }
        let asked = Flow.Shows.answer(.askToDownload(feed))
        var manual = found(feed, manualMode)
        check(make(asked, manual, manualMode) == .askToDownload(feed), "auto install off: Download and Install")
        _ = manual.apply(.downloadAsked, mode: manualMode)
        _ = manual.apply(.downloadProgress(0.5), mode: manualMode)
        check(make(asked, manual, manualMode) == .downloading(feed, fraction: 0.5), "Download and Install: the same window shows the download")
        _ = manual.apply(.downloadFailed, mode: manualMode)
        check(make(asked, manual, manualMode) == .downloadFailed(feed, asked: true),
              "Download and Install's download didn't finish: Try Again downloads again")
        var switched = found(feed, auto)
        _ = switched.apply(.automaticChanged, mode: manualMode)
        check(make(shows, switched, manualMode) == .askToDownload(feed), "the switch turned off during the download: Download and Install")
        check(make(.answer(.cannotUpdate(feed)), found(feed, tells), tells) == .cannotUpdate(feed), "a copy that can't update itself")
        var replaced = found(feed, auto)
        _ = replaced.apply(.checkStarted(.schedule), mode: auto)
        _ = replaced.apply(done(.offer(newer)), mode: auto)
        check(make(shows, replaced, auto) == .downloading(newer, fraction: nil), "a later check finding a newer release: the window follows it")
        var withdrawn = found(feed, auto)
        _ = withdrawn.apply(.checkStarted(.schedule), mode: auto)
        _ = withdrawn.apply(done(.upToDate), mode: auto)
        check(make(shows, withdrawn, auto) == .upToDate, "a release withdrawn during its download: up to date")
        // Review CXU1 §4: auto install off, nothing downloaded, a later check finds nothing newer.
        var offered = found(feed, manualMode)
        _ = offered.apply(.checkStarted(.schedule), mode: manualMode)
        _ = offered.apply(done(.upToDate), mode: manualMode)
        check(make(asked, offered, manualMode) == .upToDate, "auto install off, a release withdrawn before any download: up to date")
        var told = found(feed, tells)
        _ = told.apply(.checkStarted(.schedule), mode: tells)
        _ = told.apply(done(.upToDate), mode: tells)
        check(make(.answer(.cannotUpdate(feed)), told, tells) == .upToDate, "a copy that can't update itself, the release withdrawn: up to date")
        let percent = AppUpdateCheckDisplay.percent
        check(percent(nil) == 0 && percent(0.2905) == 29 && percent(0.999) == 99 && percent(1) == 100 && percent(1.5) == 100
              && percent(-0.2) == 0, "whole percents, floored and clamped")
    }

    private static func menu(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        let make = AppUpdateMenuEntry.make
        check(make(AppUpdateState()) == .check, "nothing running: Check for Updates…")
        var checking = AppUpdateState()
        _ = checking.apply(.checkStarted(.schedule), mode: auto)
        check(make(checking) == .checking, "any check running (the schedule's too): greyed Checking for Updates…")
        var downloading = found(feed, auto)
        check(make(downloading) == .downloading(percent: 0), "a download that has no bytes yet: 0 %")
        _ = downloading.apply(.downloadProgress(0.2905), mode: auto)
        check(make(downloading) == .downloading(percent: 29), "downloading: its percent")
        _ = downloading.apply(.checkStarted(.schedule), mode: auto)
        check(make(downloading) == .downloading(percent: 29), "a check during a download: the download's item")
        _ = downloading.apply(done(.offer(feed)), mode: auto)
        _ = downloading.apply(.staged(feed), mode: auto)
        check(make(downloading) == .restart("0.19.0"), "ready: Restart and Update to 0.19.0…")
        _ = downloading.apply(.checkStarted(.schedule), mode: auto)
        check(make(downloading) == .restart("0.19.0"), "ready while a check runs: still Restart and Update")
        var available = found(feed, manualMode)
        check(make(available) == .check, "auto install off, not downloading: Check for Updates…")
        _ = available.apply(.checkStarted(.schedule), mode: manualMode)
        check(make(available) == .checking, "…greyed while a check runs")
    }

    private static func reopening(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var flow = Flow()
        _ = flow.chosen(at: 0)
        _ = flow.answered(.downloading(feed), at: 0.2)
        _ = flow.closed()
        let shown = flow.showing(.downloading(feed))
        check(shown == Flow.Step(opens: true) && !shown.stopsCheck && flow.shows == .answer(.downloading(feed)),
              "the menu item during the download: the window again, on the download")
        var hiddenCheck = Flow()
        _ = hiddenCheck.chosen(at: 0)
        _ = hiddenCheck.tick(at: 0.5)
        _ = hiddenCheck.closed()
        _ = hiddenCheck.showing(.downloading(feed))
        check(!hiddenCheck.hidden && hiddenCheck.shows == .answer(.downloading(feed)), "even after a check's window was hidden")
        check(hiddenCheck.answered(.upToDate, at: 3) == Flow.Step() && hiddenCheck.shows == .answer(.downloading(feed)),
              "…a late answer doesn't replace the download")
        var onScreen = Flow()
        _ = onScreen.chosen(at: 0)
        _ = onScreen.tick(at: 0.5)
        check(onScreen.showing(.downloading(feed)) == Flow.Step(opens: true) && onScreen.shows == .answer(.downloading(feed)),
              "on screen: it shows the download and comes forward (the person chose the item)")
    }
}

import Foundation

// scripts/check-app-update.sh: the updater's state machine (AppUpdateState.apply), the toolbar pill it shows, the popover's
// content, what a restart waits for (AppUpdateBusy) and the Settings status line. Nothing ever answers a check the person
// didn't start; checking and downloading show nothing; a withdrawn release never stays staged; a copy an earlier run staged
// waits for this launch's first check; a DMG that downloaded whole and failed is held back from automatic checks.

enum StateChecks {
    static func run(check: (Bool, String) -> Void) {
        print("==> the state machine")
        guard let feed = FeedChecks.feed(FeedChecks.valid()), let newer = FeedChecks.feed(FeedChecks.valid(version: "0.19.1")),
              let otherDMG = FeedChecks.feed(UpdateFixture.feedJSON(version: "0.19.1", url: FeedChecks.url, size: 42_431_367,
                                                                    sha: String(repeating: "cd", count: 32))) else {
            return check(false, "fixture feeds parse")
        }
        automatic(feed, newer, check)
        manual(feed, check)
        notifyOnly(feed, check)
        launch(feed, newer, check)
        retry(feed, otherDMG, check)
        busy(check)
        statusLine(feed, check)
    }

    private static let auto = AppUpdateMode.install(automatic: true)
    private static let manualMode = AppUpdateMode.install(automatic: false)
    /// The checks' clock (the retry record's).
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 3600

    private static func done(_ result: AppUpdateCheckResult, _ at: Date = t0) -> AppUpdateEvent { .checkFinished(result, at: at) }
    /// The effects of a new release on offer in install mode: other DMGs' downloads go, then `rest`.
    private static func named(_ feed: AppUpdateFeed, _ rest: AppUpdateEffect...) -> [AppUpdateEffect] {
        [.discardDownloads(keeping: feed)] + rest
    }

    private static func automatic(_ feed: AppUpdateFeed, _ newer: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var state = AppUpdateState()
        check(state.apply(.checkStarted(.schedule), mode: auto).isEmpty && state.pill == nil, "a background check shows nothing")
        let effects = state.apply(done(.offer(feed)), mode: auto)
        check(effects == named(feed, .download(feed)), "auto: an offer starts the download, no answer (got \(effects))")
        check(state.phase == .downloading && state.pill == nil, "auto: a background download shows nothing")
        _ = state.apply(.downloadProgress(0.5), mode: auto)
        check(state.progress == 0.5 && state.pill == nil, "auto: progress is kept, still nothing shown")
        _ = state.apply(.staged(newer), mode: auto)
        check(state.phase == .downloading, "auto: a staged copy of another release is ignored")
        _ = state.apply(.staged(feed), mode: auto)
        check(state.phase == .ready && state.pill == .ready, "auto: verified and staged shows Update")
        check(state.apply(done(.offer(feed)), mode: auto).isEmpty && state.phase == .ready, "auto: the same release again changes nothing")
        let replaced = state.apply(done(.offer(newer)), mode: auto)
        check(replaced == [.discardStaged] + named(newer, .download(newer)) && state.offer == newer, "auto: a newer release replaces the staged one (got \(replaced))")
        _ = state.apply(.staged(newer), mode: auto)
        _ = state.apply(.restartRequested, mode: auto)
        check(state.restartPending, "Restart and Update waits while work runs")
        _ = state.apply(.restartCancelled, mode: auto)
        check(!state.restartPending && state.phase == .ready, "Cancel Restart keeps the update")
        let withdrawn = state.apply(done(.upToDate), mode: auto)
        check(withdrawn == [.discardStaged, .discardDownloads(keeping: nil)] && state.phase == .idle && state.pill == nil,
              "a withdrawn release is removed, its download too (got \(withdrawn))")
        var failing = AppUpdateState()
        _ = failing.apply(done(.offer(feed)), mode: auto)
        _ = failing.apply(.downloadFailed, mode: auto)
        check(failing.phase == .idle && failing.pill == nil && failing.retry == nil,
              "auto: a download that didn't complete is silent and not counted; the next check tries again")
        var person = AppUpdateState()
        _ = person.apply(.checkStarted(.menu), mode: auto)
        check(person.apply(done(.upToDate), mode: auto) == [.discardDownloads(keeping: nil), .answer(.upToDate)], "a check the person started is answered: up to date")
        _ = person.apply(.checkStarted(.menu), mode: auto)
        check(person.apply(done(.failed), mode: auto) == [.answer(.failed)] && person.lastCheckFailed, "…and when it fails")
        _ = person.apply(.checkStarted(.menu), mode: auto)
        check(person.apply(done(.offer(feed)), mode: auto) == named(feed, .download(feed), .answer(.downloading(feed))), "…found: downloading")
        check(!person.lastCheckFailed, "a check that succeeds clears the failure line")
        var background = AppUpdateState()
        _ = background.apply(.checkStarted(.schedule), mode: auto)
        check(background.apply(done(.failed), mode: auto).isEmpty, "a background check is never answered")
        var settings = AppUpdateState()
        _ = settings.apply(.checkStarted(.settings), mode: auto)
        check(settings.apply(done(.failed), mode: auto).isEmpty && settings.lastCheckFailed,
              "Settings' check answers in its status line, never with a window")
    }

    private static func manual(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var state = AppUpdateState()
        check(state.apply(done(.offer(feed)), mode: manualMode) == named(feed), "auto off: an offer downloads nothing")
        check(state.phase == .available && state.pill == .newVersion, "auto off: New Version")
        check(state.apply(.downloadAsked, mode: manualMode) == [.download(feed)], "Download and Install starts the download")
        check(state.pill == .newVersion && state.downloadAsked, "…shown in the New Version popover while it runs")
        _ = state.apply(.downloadFailed, mode: manualMode)
        check(state.phase == .available && state.downloadFailed, "an asked download that fails says so and offers it again")
        _ = state.apply(.downloadAsked, mode: manualMode)
        _ = state.apply(.staged(feed), mode: manualMode)
        check(state.phase == .ready && state.pill == .ready, "the asked copy installs at quit like an automatic one")
        // The switch.
        var switching = AppUpdateState()
        _ = switching.apply(done(.offer(feed)), mode: auto)
        check(switching.apply(.automaticChanged, mode: manualMode) == [.cancelDownload] && switching.phase == .available,
              "turned off while downloading: the download stops, New Version shows")
        check(switching.apply(.automaticChanged, mode: auto) == [.download(feed)] && switching.phase == .downloading,
              "turned on again: it downloads (or takes the staged copy)")
        _ = switching.apply(.staged(feed), mode: auto)
        check(switching.apply(.automaticChanged, mode: manualMode).isEmpty && switching.phase == .available,
              "turned off with a copy staged: it no longer installs by itself")
        let otherDMG = FeedChecks.feed(UpdateFixture.feedJSON(version: "0.19.1", url: FeedChecks.url, size: 42_431_367,
                                                             sha: String(repeating: "cd", count: 32)))!
        let moved = switching.apply(done(.offer(otherDMG)), mode: manualMode)
        check(moved.contains(.discardDownloads(keeping: otherDMG)) && !moved.contains(.download(otherDMG)),
              "auto off: the feed naming another DMG removes the old download, and nothing downloads (got \(moved))")
    }

    private static func notifyOnly(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        let mode = AppUpdateMode.notifyOnly(.folderNotWritable)
        var state = AppUpdateState()
        _ = state.apply(.checkStarted(.menu), mode: mode)
        check(state.apply(done(.offer(feed)), mode: mode) == [.answer(.cannotUpdate(feed))], "can't update: the answer offers the download page")
        check(state.pill == .newVersion && AppUpdatePopoverContent.choose(state, mode: mode) == .cannotUpdate(feed), "can't update: New Version, the can't popover")
        check(state.apply(.downloadAsked, mode: mode).isEmpty, "can't update: nothing ever downloads")
        check(AppUpdatePopoverContent.choose(state, mode: manualMode) == .available(feed), "auto off: the Download and Install popover")
    }

    /// A copy an earlier run staged (U2): unseen and never installed until this launch's first check confirms it (the feed
    /// still names it) or can't reach the feed; the feed rolled back or moved on removes it.
    private static func launch(_ feed: AppUpdateFeed, _ newer: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        let running = AppUpdateVersion("0.18.69")!
        let staged = AppUpdateStagedRecord(feed: feed, appPath: "/x/staged.noindex/0.19.0/SkyCut.app", asked: false)
        let note = AppUpdateInstalledNote(from: AppUpdateVersion("0.18.68")!, to: running, notes: ["en": ["New"]])
        let atLaunch = { (staged: AppUpdateStagedRecord?, mode: AppUpdateMode) in
            AppUpdateState.atLaunch(staged: staged, updated: nil, retry: nil, mode: mode, running: running)
        }
        var confirmed = atLaunch(staged, auto)
        check(confirmed.phase == .idle && confirmed.pill == nil && confirmed.unconfirmed == staged,
              "a copy an earlier run staged is neither shown nor installed before this launch's first check")
        check(confirmed.apply(done(.offer(feed)), mode: auto).isEmpty && confirmed.phase == .ready && confirmed.pill == .ready,
              "the first check names it: Update, it installs at quit, nothing downloads")
        var offline = atLaunch(staged, auto)
        check(offline.apply(done(.failed), mode: auto).isEmpty && offline.phase == .ready && offline.unconfirmed == nil,
              "the first check can't reach the feed: Update, it installs at quit")
        var pulled = atLaunch(staged, auto)
        let pulledEffects = pulled.apply(done(.upToDate), mode: auto)
        check(pulledEffects == [.discardStaged, .discardDownloads(keeping: nil)] && pulled.phase == .idle && pulled.pill == nil,
              "the feed rolled back: the first check removes it, it never installs (got \(pulledEffects))")
        var replaced = atLaunch(staged, auto)
        let replacedEffects = replaced.apply(done(.offer(newer)), mode: auto)
        check(replacedEffects == [.discardStaged] + named(newer, .download(newer)) && replaced.offer == newer && replaced.pill == nil,
              "the feed names another release: the staged copy goes unseen, the new one downloads (got \(replacedEffects))")
        var person = atLaunch(staged, auto)
        _ = person.apply(.checkStarted(.menu), mode: auto)
        check(person.apply(done(.offer(feed)), mode: auto) == [.answer(.downloading(feed))] && person.phase == .ready,
              "the menu's check confirms it at once")
        var off = atLaunch(staged, manualMode)
        _ = off.apply(done(.offer(feed)), mode: manualMode)
        check(off.phase == .available, "…with auto off and never asked for: New Version once confirmed")
        var asked = staged
        asked.asked = true
        var askedState = atLaunch(asked, manualMode)
        _ = askedState.apply(done(.offer(feed)), mode: manualMode)
        check(askedState.phase == .ready, "…asked for: ready once confirmed")
        check(AppUpdateState.atLaunch(staged: staged, updated: nil, retry: nil, mode: auto, running: AppUpdateVersion("0.19.0")!).unconfirmed == nil,
              "a staged copy not newer than the running version is nothing")
        check(atLaunch(staged, .notifyOnly(.folderNotWritable)).unconfirmed == nil, "a copy that only tells holds no staged copy")
        var updated = AppUpdateState.atLaunch(staged: nil, updated: note, retry: nil, mode: auto, running: running)
        check(updated.pill == .updated && AppUpdatePopoverContent.choose(updated, mode: auto) == .updated(note), "after an update: Updated")
        _ = updated.apply(.notesViewed, mode: auto)
        check(updated.pill == nil, "Updated goes away once its notes were looked at")
        check(AppUpdateState.atLaunch(staged: nil, updated: note, retry: nil, mode: auto, running: AppUpdateVersion("0.18.70")!).pill == nil,
              "a marker for another version shows nothing")
        var both = AppUpdateState.atLaunch(staged: nil, updated: note, retry: nil, mode: auto, running: running)
        _ = both.apply(done(.offer(feed)), mode: auto)
        check(both.pill == .updated, "a background download keeps Updated")
        _ = both.apply(.staged(feed), mode: auto)
        check(both.pill == .ready, "a newer update ready replaces Updated")
        var waiting = atLaunch(staged, auto)
        _ = waiting.apply(done(.offer(feed)), mode: auto)
        _ = waiting.apply(.restartRequested, mode: auto)
        check(AppUpdatePopoverContent.choose(waiting, mode: auto) == .waiting(feed), "a waiting restart shows what it waits for")
    }

    /// A DMG that downloaded whole and then failed (U1): counted, held back from automatic checks for a day and for good
    /// after three, never from the person's; nothing shown.
    private static func retry(_ feed: AppUpdateFeed, _ otherDMG: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var state = AppUpdateState()
        _ = state.apply(done(.offer(feed)), mode: auto)
        let first = state.apply(.downloadRejected(feed, at: t0), mode: auto)
        check(first == [.saveRetry(AppUpdateRetryRecord(dmgSHA256: feed.dmgSHA256, failures: 1, lastFailure: t0))]
              && state.phase == .idle && state.pill == nil, "a DMG that fails its check or staging is counted and kept on disk, silently (got \(first))")
        check(!state.apply(done(.offer(feed), t0 + hour), mode: auto).contains(.download(feed)) && state.phase == .idle && state.pill == nil,
              "an automatic check an hour later leaves it alone and shows nothing")
        check(!state.apply(done(.offer(feed), t0 + 23 * hour), mode: auto).contains(.download(feed)), "…and 23 hours later")
        check(state.apply(done(.offer(feed), t0 + 25 * hour), mode: auto) == named(feed, .download(feed)), "a day later an automatic check fetches it again")
        _ = state.apply(.downloadRejected(feed, at: t0 + 25 * hour), mode: auto)
        check(state.retry?.failures == 2, "the second failure is counted")
        check(state.apply(done(.offer(feed), t0 + 50 * hour), mode: auto) == named(feed, .download(feed)), "a day after that, once more")
        _ = state.apply(.downloadRejected(feed, at: t0 + 50 * hour), mode: auto)
        check(!state.apply(done(.offer(feed), t0 + 2000 * hour), mode: auto).contains(.download(feed)) && state.phase == .idle,
              "after three failures an automatic check never fetches it again")
        _ = state.apply(.checkStarted(.settings), mode: auto)
        check(state.apply(done(.offer(feed), t0 + 2001 * hour), mode: auto) == named(feed, .download(feed)), "a check the person starts in Settings fetches it")
        _ = state.apply(.downloadRejected(feed, at: t0 + 2001 * hour), mode: auto)
        check(state.retry?.failures == 4 && state.phase == .idle && state.pill == nil, "…and its failure counts too, silently")
        _ = state.apply(.checkStarted(.menu), mode: auto)
        check(state.apply(done(.offer(feed), t0 + 2002 * hour), mode: auto) == named(feed, .download(feed), .answer(.downloading(feed))),
              "the menu's check fetches it")
        _ = state.apply(.downloadFailed, mode: auto)
        check(state.retry?.failures == 4, "a download that didn't complete isn't counted")
        check(state.apply(done(.offer(otherDMG), t0 + 2003 * hour), mode: auto) == named(otherDMG, .download(otherDMG)),
              "the feed names another DMG: an automatic check fetches it")
        check(state.apply(.staged(otherDMG), mode: auto) == [.saveRetry(nil)] && state.retry == nil && state.phase == .ready,
              "a staged copy removes the record")
        let held = AppUpdateRetryRecord(dmgSHA256: feed.dmgSHA256, failures: 3, lastFailure: t0)
        var launched = AppUpdateState.atLaunch(staged: nil, updated: nil, retry: held, mode: auto, running: AppUpdateVersion("0.18.69")!)
        check(!launched.apply(done(.offer(feed), t0 + 9999 * hour), mode: auto).contains(.download(feed)) && launched.phase == .idle,
              "the record read at launch still holds the DMG back")
        let future = AppUpdateRetryRecord(dmgSHA256: feed.dmgSHA256, failures: 1, lastFailure: t0 + 48 * hour)
        check(AppUpdateRetryRecord.allowsAutomaticDownload(future, of: feed, at: t0), "a clock set back by more than a day doesn't hold it for ever")
        check(AppUpdateRetryRecord.allowsAutomaticDownload(nil, of: feed, at: t0), "no record: an automatic check fetches it")
        check(AppUpdateFetchOutcome.rejected.event(for: feed, at: t0) == .downloadRejected(feed, at: t0)
              && AppUpdateFetchOutcome.notDownloaded.event(for: feed, at: t0) == .downloadFailed
              && AppUpdateFetchOutcome.staged.event(for: feed, at: t0) == .staged(feed), "the pipeline's outcomes map to their events")
    }

    private static func busy(_ check: (Bool, String) -> Void) {
        check(AppUpdateBusy().isIdle && AppUpdateBusy().rows.isEmpty, "nothing running: the restart goes now")
        var busy = AppUpdateBusy()
        busy.recording = true
        check(!busy.isIdle && busy.rows.isEmpty, "a screen recording holds the restart (the note, not a row)")
        busy = AppUpdateBusy(exports: [.init(title: "Trailer", progress: 0.62)],
                             aiEditing: [.init(projectName: "B", isThisProject: false), .init(projectName: "A", isThisProject: true)],
                             compressLeft: 2, burnInLeft: 1, generatingSubtitles: true, translatingSubtitles: true, cloudTasks: 3)
        check(busy.rows == [.export(title: "Trailer", progress: 0.62), .aiThisProject, .aiProject(name: "B"), .compress(left: 2),
                            .burnIn(left: 1), .generatingSubtitles, .translatingSubtitles, .cloudTasks(3)], "the rows, in order (got \(busy.rows))")
        check(AppUpdateBusy.cloudTaskBlocksRestart(kind: "generate") && AppUpdateBusy.cloudTaskBlocksRestart(kind: "upscale")
              && AppUpdateBusy.cloudTaskBlocksRestart(kind: "voiceover") && AppUpdateBusy.cloudTaskBlocksRestart(kind: nil),
              "cloud tasks that don't survive a restart hold it")
        check(!AppUpdateBusy.cloudTaskBlocksRestart(kind: "voice_design") && !AppUpdateBusy.cloudTaskBlocksRestart(kind: "voice_enroll"),
              "the voice library's orders survive a restart and don't hold it")
    }

    private static func statusLine(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 10, minute: 42))!
        let make = { (state: AppUpdateState, last: Date?) in AppUpdateStatusLine.make(state, lastUpToDate: last, now: now, calendar: calendar) }
        let idle = AppUpdateState()
        check(make(idle, nil) == .notChecked, "never checked")
        let morning = now.addingTimeInterval(-3600)
        check(make(idle, morning) == .checkedToday(morning), "checked today")
        let yesterday = now.addingTimeInterval(-20 * 3600)
        check(make(idle, yesterday) == .checkedYesterday(yesterday), "checked yesterday")
        let earlier = now.addingTimeInterval(-5 * 86400)
        check(make(idle, earlier) == .checkedOn(earlier), "checked on an earlier date")
        var checking = idle
        checking.checking = true
        check(make(checking, morning) == .checking, "checking")
        var failed = idle
        failed.lastCheckFailed = true
        check(make(failed, morning) == .checkFailed, "the last check failed")
        var downloading = AppUpdateState()
        _ = downloading.apply(done(.offer(feed)), mode: auto)
        _ = downloading.apply(.downloadProgress(0.423), mode: auto)
        check(make(downloading, morning) == .downloading(percent: 42), "downloading 42%")
        _ = downloading.apply(.staged(feed), mode: auto)
        check(make(downloading, morning) == .ready(feed.version), "ready")
    }
}

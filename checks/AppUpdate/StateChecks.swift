import Foundation

// scripts/check-app-update.sh: the updater's state machine (AppUpdateState.apply), the toolbar pill it shows, the popover's
// content, what a restart waits for (AppUpdateBusy) and the Settings status line. Nothing ever answers a check the person
// didn't start; checking and downloading show nothing; a withdrawn release never stays staged.

enum StateChecks {
    static func run(check: (Bool, String) -> Void) {
        print("==> the state machine")
        guard let feed = FeedChecks.feed(FeedChecks.valid()), let newer = FeedChecks.feed(FeedChecks.valid(version: "0.19.1")) else {
            return check(false, "fixture feeds parse")
        }
        automatic(feed, newer, check)
        manual(feed, check)
        notifyOnly(feed, check)
        launch(feed, check)
        busy(check)
        statusLine(feed, check)
    }

    private static let auto = AppUpdateMode.install(automatic: true)
    private static let manualMode = AppUpdateMode.install(automatic: false)

    private static func automatic(_ feed: AppUpdateFeed, _ newer: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var state = AppUpdateState()
        check(state.apply(.checkStarted(byPerson: false), mode: auto).isEmpty && state.pill == nil, "a background check shows nothing")
        let effects = state.apply(.checkFinished(.offer(feed)), mode: auto)
        check(effects == [.download(feed)], "auto: an offer starts the download, no answer (got \(effects))")
        check(state.phase == .downloading && state.pill == nil, "auto: a background download shows nothing")
        _ = state.apply(.downloadProgress(0.5), mode: auto)
        check(state.progress == 0.5 && state.pill == nil, "auto: progress is kept, still nothing shown")
        _ = state.apply(.staged(newer), mode: auto)
        check(state.phase == .downloading, "auto: a staged copy of another release is ignored")
        _ = state.apply(.staged(feed), mode: auto)
        check(state.phase == .ready && state.pill == .ready, "auto: verified and staged shows Update")
        check(state.apply(.checkFinished(.offer(feed)), mode: auto).isEmpty && state.phase == .ready, "auto: the same release again changes nothing")
        let replaced = state.apply(.checkFinished(.offer(newer)), mode: auto)
        check(replaced == [.discardStaged, .download(newer)] && state.offer == newer, "auto: a newer release replaces the staged one (got \(replaced))")
        _ = state.apply(.staged(newer), mode: auto)
        _ = state.apply(.restartRequested, mode: auto)
        check(state.restartPending, "Restart and Update waits while work runs")
        _ = state.apply(.restartCancelled, mode: auto)
        check(!state.restartPending && state.phase == .ready, "Cancel Restart keeps the update")
        let withdrawn = state.apply(.checkFinished(.upToDate), mode: auto)
        check(withdrawn == [.discardStaged] && state.phase == .idle && state.pill == nil, "a withdrawn release is removed (got \(withdrawn))")
        var failing = AppUpdateState()
        _ = failing.apply(.checkFinished(.offer(feed)), mode: auto)
        _ = failing.apply(.downloadFailed, mode: auto)
        check(failing.phase == .idle && failing.pill == nil, "auto: a failed download is silent; the next check tries again")
        var person = AppUpdateState()
        _ = person.apply(.checkStarted(byPerson: true), mode: auto)
        check(person.apply(.checkFinished(.upToDate), mode: auto) == [.answer(.upToDate)], "a check the person started is answered: up to date")
        _ = person.apply(.checkStarted(byPerson: true), mode: auto)
        check(person.apply(.checkFinished(.failed), mode: auto) == [.answer(.failed)] && person.lastCheckFailed, "…and when it fails")
        _ = person.apply(.checkStarted(byPerson: true), mode: auto)
        check(person.apply(.checkFinished(.offer(feed)), mode: auto) == [.download(feed), .answer(.downloading(feed))], "…found: downloading")
        check(!person.lastCheckFailed, "a check that succeeds clears the failure line")
        var background = AppUpdateState()
        _ = background.apply(.checkStarted(byPerson: false), mode: auto)
        check(background.apply(.checkFinished(.failed), mode: auto).isEmpty, "a background check is never answered")
    }

    private static func manual(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        var state = AppUpdateState()
        check(state.apply(.checkFinished(.offer(feed)), mode: manualMode).isEmpty, "auto off: an offer downloads nothing")
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
        _ = switching.apply(.checkFinished(.offer(feed)), mode: auto)
        check(switching.apply(.automaticChanged, mode: manualMode) == [.cancelDownload] && switching.phase == .available,
              "turned off while downloading: the download stops, New Version shows")
        check(switching.apply(.automaticChanged, mode: auto) == [.download(feed)] && switching.phase == .downloading,
              "turned on again: it downloads (or takes the staged copy)")
        _ = switching.apply(.staged(feed), mode: auto)
        check(switching.apply(.automaticChanged, mode: manualMode).isEmpty && switching.phase == .available,
              "turned off with a copy staged: it no longer installs by itself")
    }

    private static func notifyOnly(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        let mode = AppUpdateMode.notifyOnly(.folderNotWritable)
        var state = AppUpdateState()
        _ = state.apply(.checkStarted(byPerson: true), mode: mode)
        check(state.apply(.checkFinished(.offer(feed)), mode: mode) == [.answer(.cannotUpdate(feed))], "can't update: the answer offers the download page")
        check(state.pill == .newVersion && AppUpdatePopoverContent.choose(state, mode: mode) == .cannotUpdate(feed), "can't update: New Version, the can't popover")
        check(state.apply(.downloadAsked, mode: mode).isEmpty, "can't update: nothing ever downloads")
        check(AppUpdatePopoverContent.choose(state, mode: manualMode) == .available(feed), "auto off: the Download and Install popover")
    }

    private static func launch(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void) {
        let running = AppUpdateVersion("0.18.69")!
        let staged = AppUpdateStagedRecord(feed: feed, appPath: "/x/staged/0.19.0/SkyCut.app", asked: false)
        let note = AppUpdateInstalledNote(from: AppUpdateVersion("0.18.68")!, to: running, notes: ["en": ["New"]])
        let ready = AppUpdateState.atLaunch(staged: staged, updated: nil, mode: auto, running: running)
        check(ready.phase == .ready && ready.pill == .ready, "a copy staged by an earlier run is ready at launch")
        let off = AppUpdateState.atLaunch(staged: staged, updated: nil, mode: manualMode, running: running)
        check(off.phase == .available, "…with auto off and never asked for: New Version")
        var asked = staged
        asked.asked = true
        check(AppUpdateState.atLaunch(staged: asked, updated: nil, mode: manualMode, running: running).phase == .ready, "…asked for: ready")
        check(AppUpdateState.atLaunch(staged: staged, updated: nil, mode: auto, running: AppUpdateVersion("0.19.0")!).phase == .idle,
              "a staged copy not newer than the running version is nothing")
        var updated = AppUpdateState.atLaunch(staged: nil, updated: note, mode: auto, running: running)
        check(updated.pill == .updated && AppUpdatePopoverContent.choose(updated, mode: auto) == .updated(note), "after an update: Updated")
        _ = updated.apply(.notesViewed, mode: auto)
        check(updated.pill == nil, "Updated goes away once its notes were looked at")
        check(AppUpdateState.atLaunch(staged: nil, updated: note, mode: auto, running: AppUpdateVersion("0.18.70")!).pill == nil,
              "a marker for another version shows nothing")
        var both = AppUpdateState.atLaunch(staged: nil, updated: note, mode: auto, running: running)
        _ = both.apply(.checkFinished(.offer(feed)), mode: auto)
        check(both.pill == .updated, "a background download keeps Updated")
        _ = both.apply(.staged(feed), mode: auto)
        check(both.pill == .ready, "a newer update ready replaces Updated")
        var waiting = AppUpdateState.atLaunch(staged: staged, updated: nil, mode: auto, running: running)
        _ = waiting.apply(.restartRequested, mode: auto)
        check(AppUpdatePopoverContent.choose(waiting, mode: auto) == .waiting(feed), "a waiting restart shows what it waits for")
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
        _ = downloading.apply(.checkFinished(.offer(feed)), mode: auto)
        _ = downloading.apply(.downloadProgress(0.423), mode: auto)
        check(make(downloading, morning) == .downloading(percent: 42), "downloading 42%")
        _ = downloading.apply(.staged(feed), mode: auto)
        check(make(downloading, morning) == .ready(feed.version), "ready")
    }
}

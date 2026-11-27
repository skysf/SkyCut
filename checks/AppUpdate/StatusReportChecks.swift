import Foundation

// scripts/check-app-update.sh: get_status's `app_update` (AppUpdateStatusReport.make). Every state of the vocabulary, each
// against the JSON written out here by hand: who this copy is (not known yet, never updates, only tells, installs), the
// quiet states (not checked, checking, failed, up to date), a release in play (downloading, ready, a restart waiting,
// available and why), the first launch after an update, and which wins when two hold. Notes only for ready, available and
// just_updated, in the App's language; a hint only where the user can act; a copy an earlier run staged stays unseen until
// confirmed, as on the pill. Then the same through the real state machine's transitions.

enum StatusReportChecks {
    static func run(check: @escaping (Bool, String) -> Void) {
        print("==> get_status's app_update")
        guard let feed = FeedChecks.feed(UpdateFixture.feedJSON(version: "0.19.0", url: FeedChecks.url, size: 42_431_367,
                                                                 sha: FeedChecks.sha, notes: notes)) else {
            return check(false, "the status fixture feed parses")
        }
        var seen = Set<AppUpdateStatusReport.State>()
        let expect = { (report: AppUpdateStatusReport, json: String, what: String) in
            seen.insert(report.state)
            let got = canonical(report)
            check(got == canonical(json), "app_update \(what): \(got ?? "not JSON") (expected \(json))")
            check(keysDocumented(report), "app_update \(what): only the documented keys")
            let notesBelong: Set<AppUpdateStatusReport.State> = [.ready, .available, .justUpdated]
            check((report.notes != nil) == notesBelong.contains(report.state), "app_update \(what): notes only for ready, available, just_updated")
        }
        vocabulary(check)
        who(feed, expect)
        quiet(expect)
        release(feed, expect)
        justUpdated(feed, expect)
        transitions(feed, check, expect)
        let missing = Set(AppUpdateStatusReport.State.allCases).subtracting(seen)
        check(missing.isEmpty, "app_update: a case for every state (missing: \(missing.map(\.rawValue).sorted()))")
    }

    private typealias Expect = (AppUpdateStatusReport, String, String) -> Void
    private static let notes = ["en": ["Faster export", "Two fixes"], "zh-Hans": ["导出更快", "两处修复"], "es": ["Exportación más rápida", "Dos correcciones"]]
    private static let installs = AppUpdateEligibility.Decision.updates
    /// StateChecks.t0 is 2027-01-15 08:00:00 UTC.
    private static let lastUpToDate = StateChecks.t0
    private static let page = "https://skylu.ai/download/skycut"
    private static let readyHint = "It installs when SkyCut quits. To install it now, the user clicks Update in the toolbar, then Restart and Update."
    private static let restartHint = "The user chose Restart and Update: SkyCut restarts by itself once running work (exports, AI rounds, cloud tasks) has finished."
    private static let offHint = "Automatic updates are off: the user clicks New Version in the toolbar, then Download and Install."
    private static let failedHint = "The download didn't finish: New Version in the toolbar, then Download and Install, tries again."
    private static let retryHint = "The download didn't finish; SkyCut tries again by itself at its next check (within a day), or the user chooses Check for Updates… in the SkyCut menu."
    private static let heldHint = "The download failed its check; SkyCut tries again by itself a day after that failure, or the user chooses Check for Updates… in the SkyCut menu."
    private static let heldForGoodHint = "The download failed its check 3 times; SkyCut no longer fetches it by itself: the user chooses Check for Updates… in the SkyCut menu to try again."
    private static let cannotHint = "This copy can't update itself: the user clicks New Version in the toolbar, then Open Download Page (\(page))."
    private static let movingHint = cannotHint + " Moved into the Applications folder, SkyCut updates itself."

    private static func make(_ state: AppUpdateState, _ decision: AppUpdateEligibility.Decision? = installs, automatic: Bool = true,
                             last: Date? = nil, language: String = "en",
                             buttons: AppUpdateStatusReport.Buttons = .init()) -> AppUpdateStatusReport {
        AppUpdateStatusReport.make(state, decision: decision, automatic: automatic, lastUpToDate: last, language: language, buttons: buttons)
    }

    private static func vocabulary(_ check: (Bool, String) -> Void) {
        check(AppUpdateStatusReport.State.allCases.map(\.rawValue) == ["up_to_date", "not_checked", "checking", "check_failed",
                                                                         "downloading", "ready", "available", "just_updated", "off"],
              "app_update: the state vocabulary is the documented one (ai-control-mcp.md section 4 item 69)")
        check(AppUpdateStatusReport.Reason.allCases.map(\.rawValue) == [
            "automatic_off", "download_failed", "held_back", "installer_disk", "translocated", "protected_folder", "folder_not_writable",
            "bundle_not_writable", "volume_cannot_swap", "staging_on_other_volume", "other_build", "development_build",
            "updates_folder", "scripted_run"], "app_update: the reason vocabulary is the documented one")
        check(AppUpdateFeed.downloadPageURL.absoluteString == page, "app_update: the hint names AppUpdateFeed's download page")
    }

    /// Who this copy is: not known yet, never updates (whatever the state holds), only tells, installs.
    private static func who(_ feed: AppUpdateFeed, _ expect: Expect) {
        expect(make(AppUpdateState(), nil), #"{"state":"not_checked"}"#, "before the launch's reading")
        var ready = AppUpdateState()
        (ready.phase, ready.offer) = (.ready, feed)
        let off: [(AppUpdateEligibility.Never, String)] = [
            (.otherBundle, "other_build"), (.notAppBundle, "development_build"), (.notReleaseSignature, "development_build"),
            (.developmentVersion, "development_build"), (.developmentFolder, "development_build"), (.updatesFolder, "updates_folder"),
            (.scripted, "scripted_run")]
        for (never, reason) in off {
            expect(make(ready, .never(never)), #"{"reason":"\#(reason)","state":"off"}"#, "never updates (\(never))")
        }
        expect(make(AppUpdateState(), .notifyOnly(.folderNotWritable)), #"{"state":"not_checked"}"#,
               "a copy that only tells has no switch to report")
        expect(make(AppUpdateState(), automatic: false), #"{"automatic":false,"state":"not_checked"}"#, "the switch off")
    }

    private static func quiet(_ expect: Expect) {
        expect(make(AppUpdateState()), #"{"automatic":true,"state":"not_checked"}"#, "never checked")
        var checking = AppUpdateState()
        checking.checking = true
        expect(make(checking, last: lastUpToDate), #"{"automatic":true,"state":"checking"}"#, "a check in flight wins over the last result")
        var failed = AppUpdateState()
        failed.lastCheckFailed = true
        expect(make(failed, last: lastUpToDate), #"{"automatic":true,"state":"check_failed"}"#, "the last check failed")
        expect(make(AppUpdateState(), last: lastUpToDate),
               #"{"automatic":true,"last_checked":"2027-01-15T08:00:00Z","state":"up_to_date"}"#, "up to date, with when")
    }

    private static func release(_ feed: AppUpdateFeed, _ expect: Expect) {
        var downloading = AppUpdateState()
        (downloading.phase, downloading.offer, downloading.progress) = (.downloading, feed, 0.427)
        expect(make(downloading), #"{"automatic":true,"percent":42,"state":"downloading","version":"0.19.0"}"#, "downloading")
        for (progress, json) in [(nil, ""), (1.0, #","percent":100"#), (1.7, #","percent":100"#), (-0.2, #","percent":0"#),
                                 (Double.nan, "")] as [(Double?, String)] {
            downloading.progress = progress
            expect(make(downloading), #"{"automatic":true\#(json),"state":"downloading","version":"0.19.0"}"#,
                   "downloading at \(String(describing: progress))")
        }
        var ready = AppUpdateState()
        (ready.phase, ready.offer, ready.checking, ready.lastCheckFailed) = (.ready, feed, true, true)
        let readyJSON = { (lines: String) in
            #"{"automatic":true,"hint":"\#(readyHint)","notes":\#(lines),"state":"ready","version":"0.19.0"}"#
        }
        expect(make(ready, last: lastUpToDate), readyJSON(#"["Faster export","Two fixes"]"#), "ready (wins over checking and failed)")
        expect(make(ready, language: "zh-Hans"), readyJSON(#"["导出更快","两处修复"]"#), "ready, notes in Chinese")
        expect(make(ready, language: "es"), readyJSON(#"["Exportación más rápida","Dos correcciones"]"#), "ready, notes in Spanish")
        expect(make(ready, language: "fr"), readyJSON(#"["Faster export","Two fixes"]"#), "ready, notes fall back to English")
        ready.restartPending = true
        expect(make(ready), #"{"automatic":true,"hint":"\#(restartHint)","notes":["Faster export","Two fixes"],"restart_pending":true,"state":"ready","version":"0.19.0"}"#,
               "ready, Restart and Update waiting")
        var available = AppUpdateState()
        (available.phase, available.offer) = (.available, feed)
        let availableJSON = { (automatic: String, reason: String, hint: String) in
            #"{\#(automatic)"hint":"\#(hint)","notes":["Faster export","Two fixes"],"reason":"\#(reason)","state":"available","version":"0.19.0"}"#
        }
        expect(make(available, automatic: false), availableJSON(#""automatic":false,"#, "automatic_off", offHint), "available, auto install off")
        available.downloadFailed = true
        expect(make(available, automatic: false), availableJSON(#""automatic":false,"#, "download_failed", failedHint),
               "available, an asked download that didn't finish")
        available.downloadFailed = false
        expect(make(available, automatic: true), availableJSON(#""automatic":true,"#, "download_failed", failedHint),
               "available with auto install on (only after an asked download failed)")
        let tells: [(AppUpdateEligibility.CannotUpdate, String, String)] = [
            (.installerDisk, "installer_disk", movingHint), (.translocated, "translocated", movingHint),
            (.protectedFolder, "protected_folder", movingHint), (.folderNotWritable, "folder_not_writable", cannotHint),
            (.bundleNotWritable, "bundle_not_writable", cannotHint), (.volumeCannotSwap, "volume_cannot_swap", cannotHint),
            (.stagingOnOtherVolume, "staging_on_other_volume", cannotHint)]
        for (cannot, reason, hint) in tells {
            expect(make(available, .notifyOnly(cannot)), availableJSON("", reason, hint), "available, only told (\(cannot))")
        }
    }

    private static func justUpdated(_ feed: AppUpdateFeed, _ expect: Expect) {
        guard let from = AppUpdateVersion("0.18.69"), let to = AppUpdateVersion("0.18.70") else { return }
        var updated = AppUpdateState()
        (updated.updated, updated.checking) = (AppUpdateInstalledNote(from: from, to: to, notes: notes), true)
        let json = #"{"automatic":true,"from":"0.18.69","notes":["Faster export","Two fixes"],"state":"just_updated","version":"0.18.70"}"#
        expect(make(updated, last: lastUpToDate), json, "the first launch after an update (wins over checking)")
        updated.updatedNotesViewed = true
        expect(make(updated), json, "still just_updated once the notes were viewed (the whole launch)")
        expect(make(updated, language: "zh-Hans"),
               #"{"automatic":true,"from":"0.18.69","notes":["导出更快","两处修复"],"state":"just_updated","version":"0.18.70"}"#,
               "just_updated, notes in Chinese")
        (updated.phase, updated.offer) = (.ready, feed)
        expect(make(updated), #"{"automatic":true,"hint":"\#(readyHint)","notes":["Faster export","Two fixes"],"state":"ready","version":"0.19.0"}"#,
               "a newer release ready wins over just_updated")
    }

    /// Through AppUpdateState.apply: what each transition leaves is what get_status says.
    private static func transitions(_ feed: AppUpdateFeed, _ check: (Bool, String) -> Void, _ expect: Expect) {
        let auto = AppUpdateMode.install(automatic: true)
        guard let running = AppUpdateVersion("0.18.70") else { return }
        let record = AppUpdateStagedRecord(feed: feed, appPath: "/x/staged.noindex/0.19.0/SkyCut.app", asked: false)
        var state = AppUpdateState.atLaunch(staged: record, updated: nil, retry: nil, mode: auto, running: running)
        check(state.pill == nil, "app_update fixture: an earlier run's staged copy is unseen on the pill")
        expect(make(state), #"{"automatic":true,"state":"not_checked"}"#, "an earlier run's staged copy before this launch's check")
        expect(make(state, last: lastUpToDate), #"{"automatic":true,"last_checked":"2027-01-15T08:00:00Z","state":"up_to_date"}"#,
               "an earlier run's staged copy stays unseen, as on the pill")
        _ = state.apply(.checkStarted(.schedule), mode: auto)
        expect(make(state), #"{"automatic":true,"state":"checking"}"#, "after checkStarted")
        _ = state.apply(.checkFinished(.offer(feed), at: StateChecks.t0), mode: auto)
        expect(make(state), #"{"automatic":true,"hint":"\#(readyHint)","notes":["Faster export","Two fixes"],"state":"ready","version":"0.19.0"}"#,
               "the feed confirms the staged copy: ready")
        _ = state.apply(.restartRequested, mode: auto)
        check(make(state).restartPending == true, "app_update after restartRequested: restart_pending")
        _ = state.apply(.checkFinished(.upToDate, at: StateChecks.t0), mode: auto)
        expect(make(state, last: lastUpToDate), #"{"automatic":true,"last_checked":"2027-01-15T08:00:00Z","state":"up_to_date"}"#,
               "a withdrawn release: up to date")
        var fresh = AppUpdateState()
        _ = fresh.apply(.checkStarted(.schedule), mode: auto)
        _ = fresh.apply(.checkFinished(.offer(feed), at: StateChecks.t0), mode: auto)
        _ = fresh.apply(.downloadProgress(0.5), mode: auto)
        expect(make(fresh), #"{"automatic":true,"percent":50,"state":"downloading","version":"0.19.0"}"#, "downloading through apply")
        _ = fresh.apply(.downloadFailed, mode: auto)
        // E1 (review FBG1): the pill shows nothing, but SkyCut knows the version and tries again by itself.
        let retrying = #"{"automatic":true,"hint":"\#(retryHint)","notes":["Faster export","Two fixes"],"reason":"download_failed","state":"available","version":"0.19.0"}"#
        expect(make(fresh, last: lastUpToDate), retrying, "an automatic download that failed: still available, SkyCut retries")
        _ = fresh.apply(.checkStarted(.schedule), mode: auto)
        _ = fresh.apply(.checkFinished(.failed, at: StateChecks.t0), mode: auto)
        expect(make(fresh), retrying, "a failed check later keeps the known version")
        _ = fresh.apply(.checkFinished(.upToDate, at: StateChecks.t0), mode: auto)
        expect(make(fresh), #"{"automatic":true,"state":"not_checked"}"#, "a check that finds nothing newer forgets it")
        var failedCheck = AppUpdateState()
        _ = failedCheck.apply(.checkStarted(.schedule), mode: auto)
        _ = failedCheck.apply(.checkFinished(.failed, at: StateChecks.t0), mode: auto)
        expect(make(failedCheck), #"{"automatic":true,"state":"check_failed"}"#, "a failed check through apply")
        // E1: a DMG the retry record holds back (it came down whole and failed its check): nothing downloads, still available.
        for (failures, hint, what) in [(1, heldHint, "after one failure"), (3, heldForGoodHint, "after three failures")] {
            var held = AppUpdateState()
            held.retry = AppUpdateRetryRecord(dmgSHA256: feed.dmgSHA256, failures: failures, lastFailure: StateChecks.t0)
            let effects = held.apply(.checkFinished(.offer(feed), at: StateChecks.t0.addingTimeInterval(3600)), mode: auto)
            check(!effects.contains(.download(feed)) && held.phase == .idle, "app_update fixture: the retry record holds the DMG back \(what)")
            expect(make(held), #"{"automatic":true,"hint":"\#(hint)","notes":["Faster export","Two fixes"],"reason":"held_back","state":"available","version":"0.19.0"}"#,
                   "a held-back DMG \(what): still available, with SkyCut's own retry")
        }
        // E2: the hints quote the buttons as the App names them in its language.
        let chinese = AppUpdateStatusReport.Buttons(update: "更新", newVersion: "新版本", restartAndUpdate: "重启并更新",
                                                   downloadInstallButton: "下载并安装", openDownloadPage: "打开下载页面", checkForUpdates: "检查更新…")
        var readyState = AppUpdateState()
        (readyState.phase, readyState.offer) = (.ready, feed)
        check(make(readyState, buttons: chinese).hint == "It installs when SkyCut quits. To install it now, the user clicks 更新 in the toolbar, then 重启并更新.",
              "app_update: the ready hint quotes the App's own button names (zh-Hans)")
        check(make(retryingState(feed), buttons: chinese).hint?.contains("检查更新…") == true,
              "app_update: the retry hint quotes the menu's Check for Updates… in the App's language")
        let manual = AppUpdateMode.install(automatic: false)
        var asked = AppUpdateState()
        _ = asked.apply(.checkFinished(.offer(feed), at: StateChecks.t0), mode: manual)
        expect(make(asked, automatic: false), #"{"automatic":false,"hint":"\#(offHint)","notes":["Faster export","Two fixes"],"reason":"automatic_off","state":"available","version":"0.19.0"}"#,
               "auto install off through apply: available")
        _ = asked.apply(.downloadAsked, mode: manual)
        expect(make(asked, automatic: false), #"{"automatic":false,"state":"downloading","version":"0.19.0"}"#, "Download and Install: downloading")
        _ = asked.apply(.downloadFailed, mode: manual)
        check(make(asked, automatic: false).reason == .downloadFailed, "an asked download that failed: available, download_failed")
    }

    /// A state where the automatic download failed after a check found `feed`.
    private static func retryingState(_ feed: AppUpdateFeed) -> AppUpdateState {
        var state = AppUpdateState()
        let auto = AppUpdateMode.install(automatic: true)
        _ = state.apply(.checkFinished(.offer(feed), at: StateChecks.t0), mode: auto)
        _ = state.apply(.downloadFailed, mode: auto)
        return state
    }

    // MARK: Reading the JSON

    private static let documentedKeys: Set<String> = ["state", "version", "percent", "from", "reason", "last_checked", "automatic",
                                                       "restart_pending", "notes", "hint"]

    private static func keysDocumented(_ report: AppUpdateStatusReport) -> Bool {
        guard let data = try? report.encoded(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys).isSubset(of: documentedKeys)
    }

    /// One serializer for both sides (sorted keys, booleans stay booleans), so the order the encoder chose doesn't matter.
    private static func canonical(_ report: AppUpdateStatusReport) -> String? {
        (try? report.encoded()).flatMap(canonical)
    }

    private static func canonical(_ json: String) -> String? { canonical(Data(json.utf8)) }

    private static func canonical(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let text = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: text, encoding: .utf8)
    }
}

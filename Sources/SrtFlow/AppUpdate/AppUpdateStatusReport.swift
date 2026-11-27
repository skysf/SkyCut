import Foundation

// MARK: - What get_status tells the AI about SkyCut updates (pure)
//
// What it does: maps the updater's current state (AppUpdateState, who this copy is, the Settings switch, when a check last
// found nothing newer) to get_status's `app_update` object: one state from a short, fixed vocabulary, the release on offer
// or just installed, its notes in the App's language (only for ready, available and just_updated), and a hint only where
// the user can act. It mirrors what the toolbar pill and Settings show: a copy an earlier run staged stays unseen until
// this launch's first check confirms it, as it does there. Read only: building it starts no check, download or install,
// and nothing here lets the AI install, restart or quit SkyCut.
// What it doesn't: read the updater (AppUpdater.statusReport), reach the AI (AIProjectTools.status), or decide anything.
// Rules: docs/architecture/app-updates.md "Who reads the state", docs/architecture/ai-control-mcp.md section 4 item 69.

struct AppUpdateStatusReport: Encodable, Equatable, Sendable {
    /// The states, in get_status's words. Stable: the AI and the guide's get_status topic read these names.
    enum State: String, Encodable, CaseIterable, Sendable {
        /// The last check found nothing newer (`last_checked`).
        case upToDate = "up_to_date"
        /// No check has finished yet this launch and none is known from an earlier one.
        case notChecked = "not_checked"
        case checking
        /// The last check couldn't reach or read the feed.
        case checkFailed = "check_failed"
        /// Downloading and verifying in the background (`percent` when known).
        case downloading
        /// Downloaded and verified: installs when SkyCut quits, or now with Restart and Update.
        case ready
        /// A newer release this copy doesn't fetch by itself (`reason`).
        case available
        /// The first launch after an update (`from`).
        case justUpdated = "just_updated"
        /// This copy never updates (`reason`): SkyCut Beta, a build from source, a scripted run, the Updates folder.
        case off
    }

    /// Why `available` doesn't download by itself, or why a copy is `off`.
    enum Reason: String, Encodable, CaseIterable, Sendable {
        case automaticOff = "automatic_off"
        case downloadFailed = "download_failed"
        // A copy that can only tell (AppUpdateEligibility.CannotUpdate).
        case installerDisk = "installer_disk"
        case translocated
        case protectedFolder = "protected_folder"
        case folderNotWritable = "folder_not_writable"
        case bundleNotWritable = "bundle_not_writable"
        case volumeCannotSwap = "volume_cannot_swap"
        case stagingOnOtherVolume = "staging_on_other_volume"
        // A copy that never updates (AppUpdateEligibility.Never).
        case otherBuild = "other_build"
        case developmentBuild = "development_build"
        case updatesFolder = "updates_folder"
        case scriptedRun = "scripted_run"

        init(_ cannot: AppUpdateEligibility.CannotUpdate) {
            switch cannot {
            case .installerDisk: self = .installerDisk
            case .translocated: self = .translocated
            case .protectedFolder: self = .protectedFolder
            case .folderNotWritable: self = .folderNotWritable
            case .bundleNotWritable: self = .bundleNotWritable
            case .volumeCannotSwap: self = .volumeCannotSwap
            case .stagingOnOtherVolume: self = .stagingOnOtherVolume
            }
        }

        init(_ never: AppUpdateEligibility.Never) {
            switch never {
            case .otherBundle: self = .otherBuild
            case .notAppBundle, .notReleaseSignature, .developmentVersion, .developmentFolder: self = .developmentBuild
            case .updatesFolder: self = .updatesFolder
            case .scripted: self = .scriptedRun
            }
        }

        /// Moving the app into the Applications folder lets it update itself.
        var movingHelps: Bool { [.installerDisk, .translocated, .protectedFolder].contains(self) }
    }

    var state: State
    /// The release on offer (downloading, ready, available) or just installed (just_updated).
    var version: String?
    var percent: Int?
    var from: String?
    var reason: Reason?
    /// When a check last found nothing newer (ISO 8601, UTC): only for up_to_date.
    var lastChecked: String?
    /// The Settings switch, for a copy that installs updates.
    var automatic: Bool?
    /// The user chose Restart and Update and SkyCut waits for running work (only `true` is written).
    var restartPending: Bool?
    var notes: [String]?
    /// What the user can do, in the App's own words; never something the AI does.
    var hint: String?

    enum CodingKeys: String, CodingKey {
        case state, version, percent, from, reason, automatic, notes, hint
        case lastChecked = "last_checked"
        case restartPending = "restart_pending"
    }

    /// `decision`: who this copy is (nil until the launch's reading is in); `language`: the App's current language code.
    static func make(_ state: AppUpdateState, decision: AppUpdateEligibility.Decision?, automatic: Bool, lastUpToDate: Date?,
                     language: String) -> AppUpdateStatusReport {
        let mode: AppUpdateMode
        switch decision {
        case nil: return AppUpdateStatusReport(state: .notChecked)
        case .never(let why)?: return AppUpdateStatusReport(state: .off, reason: Reason(why))
        case .notifyOnly(let why)?: mode = .notifyOnly(why)
        case .updates?: mode = .install(automatic: automatic)
        }
        var report = release(state, mode: mode, language: language) ?? quiet(state, lastUpToDate: lastUpToDate, language: language)
        if case .install(let automatic) = mode { report.automatic = automatic }
        return report
    }

    /// get_status's JSON (keys sorted, the download page's slashes as written).
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: The states

    /// A release in play: downloading, ready or available (as the pill and Settings' status line show it).
    private static func release(_ state: AppUpdateState, mode: AppUpdateMode, language: String) -> AppUpdateStatusReport? {
        guard let offer = state.offer else { return nil }
        let version = offer.version.description
        let notes = Self.lines(offer.notes(forLanguage: language))
        switch state.phase {
        case .idle:
            return nil
        case .downloading:
            return AppUpdateStatusReport(state: .downloading, version: version, percent: state.progress.flatMap(Self.percent))
        case .ready:
            var report = AppUpdateStatusReport(state: .ready, version: version, notes: notes, hint: Hint.ready)
            if state.restartPending {
                report.restartPending = true
                report.hint = Hint.restartPending
            }
            return report
        case .available:
            let reason: Reason
            switch mode {
            case .notifyOnly(let why): reason = Reason(why)
            // Auto install on and still available: an asked download that didn't finish (the switch on starts a download).
            case .install(let automatic): reason = state.downloadFailed || automatic ? .downloadFailed : .automaticOff
            }
            return AppUpdateStatusReport(state: .available, version: version, reason: reason, notes: notes, hint: Hint.available(reason))
        }
    }

    /// Nothing in play: the first launch after an update, else the last check's result.
    private static func quiet(_ state: AppUpdateState, lastUpToDate: Date?, language: String) -> AppUpdateStatusReport {
        if let updated = state.updated {
            return AppUpdateStatusReport(state: .justUpdated, version: updated.to.description, from: updated.from.description,
                                         notes: Self.lines(AppUpdateFeed.notes(updated.notes, forLanguage: language)))
        }
        if state.checking { return AppUpdateStatusReport(state: .checking) }
        if state.lastCheckFailed { return AppUpdateStatusReport(state: .checkFailed) }
        guard let lastUpToDate else { return AppUpdateStatusReport(state: .notChecked) }
        return AppUpdateStatusReport(state: .upToDate, lastChecked: ISO8601DateFormatter().string(from: lastUpToDate))
    }

    /// Whole percents, as Settings shows them.
    private static func percent(_ fraction: Double) -> Int? {
        guard fraction.isFinite else { return nil }
        return min(100, max(0, Int((fraction * 100).rounded(.down))))
    }

    private static func lines(_ notes: [String]) -> [String]? { notes.isEmpty ? nil : notes }

    /// The user's own steps, named as the App names them (app-updates.md "What the person sees").
    enum Hint {
        static let ready = "It installs when SkyCut quits. To install it now, the user clicks Update in the toolbar, then Restart and Update."
        static let restartPending = "The user chose Restart and Update: SkyCut restarts by itself once running work (exports, AI rounds, cloud tasks) has finished."
        static let automaticOff = "Automatic updates are off: the user clicks New Version in the toolbar, then Download and Install."
        static let downloadFailed = "The download didn't finish: New Version in the toolbar, then Download and Install, tries again."
        static let cannotUpdate = "This copy can't update itself: the user clicks New Version in the toolbar, then Open Download Page ("
            + AppUpdateFeed.downloadPageURL.absoluteString + ")."
        static let moving = " Moved into the Applications folder, SkyCut updates itself."

        static func available(_ reason: Reason) -> String {
            switch reason {
            case .automaticOff: return automaticOff
            case .downloadFailed: return downloadFailed
            default: return cannotUpdate + (reason.movingHelps ? moving : "")
            }
        }
    }
}

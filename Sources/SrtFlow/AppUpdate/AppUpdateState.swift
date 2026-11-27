import Foundation

// MARK: - What the updater is doing, what the toolbar shows, and what happens next (pure)
//
// What it does: the updater's state and its one transition function, `apply(_:mode:)`, which returns the effects to run
// (download, stop a download, drop a staged copy or the downloads the feed withdrew, keep the retry record, answer a check
// the person started). Checking and downloading show nothing; a verified copy shows Update; a copy that only tells (auto
// install off, or one that can't update itself) shows New Version; the first launch after an update shows Updated until its
// notes are viewed. A copy an earlier run staged stays unseen, and never installs, until this launch's first check has
// confirmed the feed still names it or failed to reach the feed: a pulled release never goes in at a quit that comes first.
// A DMG that downloaded whole and then failed is held back from automatic checks (AppUpdateRetryRecord). Nothing here ever
// opens a window: only a check the person started from the menu gets an answer (AppUpdateCheckAnswer). Pure, so the checks
// drive every transition.
// What it doesn't: run the effects (AppUpdater), decide who updates (AppUpdateEligibility), what a restart waits for
// (AppUpdateBusy).
// Rules: docs/architecture/app-updates.md "States".

/// How this copy takes updates (AppUpdateEligibility.Decision, never `.never`: such a copy has no updater).
enum AppUpdateMode: Equatable, Sendable {
    /// Downloads and installs at quit: by itself when `automatic`, else after Download and Install.
    case install(automatic: Bool)
    /// Only tells, with the download page.
    case notifyOnly(AppUpdateEligibility.CannotUpdate)
}

/// Who started a check. The schedule's is never answered and never fetches a DMG the retry record holds back; the person's
/// (Settings' button, answered in its status line; the app menu's, answered with a window) always fetches it.
enum AppUpdateCheckOrigin: Equatable, Sendable {
    case schedule, settings, menu

    var byPerson: Bool { self != .schedule }
}

enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate
    case offer(AppUpdateFeed)
    /// Offline, a server error, a malformed feed: said to nobody unless the person started the check.
    case failed
}

/// The answer to a check the person started from the app menu: the one window the updater ever opens.
enum AppUpdateCheckAnswer: Equatable, Sendable {
    case upToDate
    /// Found and downloading in the background (Update appears when it is done), or already downloading.
    case downloading(AppUpdateFeed)
    /// Found; auto install is off: Download and Install / Later.
    case askToDownload(AppUpdateFeed)
    /// Found; this copy can't update itself: Open Download Page / Later.
    case cannotUpdate(AppUpdateFeed)
    case failed
}

enum AppUpdateEvent: Equatable, Sendable {
    case checkStarted(AppUpdateCheckOrigin)
    /// `at`: when the check finished (the retry record's clock).
    case checkFinished(AppUpdateCheckResult, at: Date)
    /// Download and Install (auto install off).
    case downloadAsked
    case downloadProgress(Double?)
    /// The copy of this release is downloaded, verified and staged.
    case staged(AppUpdateFeed)
    /// The download didn't complete (offline, a server error): nothing is known about the DMG, nothing is counted.
    case downloadFailed
    /// The download completed, then failed its check or its staging: counted in the retry record.
    case downloadRejected(AppUpdateFeed, at: Date)
    /// The Settings switch; `apply` gets the mode it now means.
    case automaticChanged
    case notesViewed
    case restartRequested
    case restartCancelled
}

enum AppUpdateEffect: Equatable, Sendable {
    /// Download, verify and stage this release (or take a kept download or the copy already staged for it).
    case download(AppUpdateFeed)
    case cancelDownload
    /// The feed no longer offers the staged copy (withdrawn or replaced): remove it so it never installs.
    case discardStaged
    /// Downloads of other DMGs go: the feed names another release (`keeping` it), or nothing newer at all (nil).
    case discardDownloads(keeping: AppUpdateFeed?)
    /// Keep the retry record on disk (nil: remove it).
    case saveRetry(AppUpdateRetryRecord?)
    case answer(AppUpdateCheckAnswer)

    /// Reads or writes the Updates folder: never for a copy that only tells (it may share the folder with one that installs).
    var touchesFiles: Bool {
        switch self {
        case .download, .discardStaged, .discardDownloads, .saveRetry: return true
        case .cancelDownload, .answer: return false
        }
    }
}

struct AppUpdateState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// A newer release, not downloading: auto install off and not asked, or a copy that only tells.
        case available
        case downloading
        /// Staged: installs at the next quit.
        case ready
    }

    /// What the toolbar shows: Update (filled), New Version (outlined), Updated (the first launch after an update).
    enum Pill: Equatable, Sendable {
        case ready, newVersion, updated
    }

    var phase: Phase = .idle
    /// The release of `available`, `downloading` and `ready`.
    var offer: AppUpdateFeed?
    var progress: Double?
    var checking = false
    /// A check the person started from the menu waits for its answer.
    var personChecking = false
    /// The check in flight was started (or joined) by the person: it fetches a DMG the retry record holds back.
    var personStarted = false
    /// The last check failed (offline, a server error, a malformed feed): only Settings' status line says so.
    var lastCheckFailed = false
    /// Download and Install was clicked for `offer` (auto install off): it installs at quit like an automatic one.
    var downloadAsked = false
    /// That download didn't finish: the popover says so and offers it again.
    var downloadFailed = false
    /// Restart and Update was clicked and waits for running work (AppUpdateBusy).
    var restartPending = false
    /// This launch follows an update (the installer's marker).
    var updated: AppUpdateInstalledNote?
    var updatedNotesViewed = false
    /// A copy an earlier run staged: not shown and never installed until this launch's first check settles it.
    var unconfirmed: AppUpdateStagedRecord?
    /// The DMG held back from automatic checks (Updates/retry.json).
    var retry: AppUpdateRetryRecord?
    /// The newest release a check found, for reporting only (get_status's `app_update`, AppUpdateStatusReport): an
    /// automatic download that failed or a DMG the retry record holds back clears `offer`, but SkyCut still knows the
    /// version. No transition reads it; a check that finds nothing newer clears it (review FBG1, E1).
    var lastFound: AppUpdateFeed?

    var pill: Pill? {
        switch phase {
        case .ready: return .ready
        case .available: return .newVersion
        case .downloading where downloadAsked: return .newVersion
        case .idle, .downloading: return updated != nil && !updatedNotesViewed ? .updated : nil
        }
    }

    /// The state a launch starts in: the installer's marker, the retry record, and a copy staged by an earlier run that this
    /// mode installs, held as unconfirmed until this launch's first check.
    static func atLaunch(staged: AppUpdateStagedRecord?, updated: AppUpdateInstalledNote?, retry: AppUpdateRetryRecord?,
                         mode: AppUpdateMode, running: AppUpdateVersion) -> AppUpdateState {
        var state = AppUpdateState()
        state.retry = retry
        if let updated, updated.to == running { state.updated = updated }
        guard case .install = mode, let staged, staged.feed.version > running else { return state }
        state.unconfirmed = staged
        return state
    }

    /// One event; returns what to do next. `mode` is how this copy takes updates now (the Settings switch included). A copy
    /// that only tells gets no effect on the Updates folder: another copy of SkyCut, one that installs, may be using it.
    mutating func apply(_ event: AppUpdateEvent, mode: AppUpdateMode) -> [AppUpdateEffect] {
        let effects = transition(event, mode: mode)
        guard case .notifyOnly = mode else { return effects }
        return effects.filter { !$0.touchesFiles }
    }

    private mutating func transition(_ event: AppUpdateEvent, mode: AppUpdateMode) -> [AppUpdateEffect] {
        switch event {
        case .checkStarted(let origin):
            checking = true
            if origin.byPerson { personStarted = true }
            if origin == .menu { personChecking = true }
            return []
        case .checkFinished(let result, let now):
            checking = false
            let answering = personChecking, byPerson = personStarted
            personChecking = false
            personStarted = false
            let (effects, answer) = finish(result, mode: mode, byPerson: byPerson, now: now)
            return effects + (answering ? [.answer(answer)] : [])
        case .downloadAsked:
            guard phase == .available, let offer, case .install = mode else { return [] }
            phase = .downloading
            downloadAsked = true
            downloadFailed = false
            progress = nil
            return [.download(offer)]
        case .downloadProgress(let value):
            if phase == .downloading { progress = value }
            return []
        case .staged(let feed):
            guard phase == .downloading, offer?.isSameRelease(as: feed) == true else { return [] }
            phase = .ready
            progress = nil
            guard retry != nil else { return [] }
            retry = nil
            return [.saveRetry(nil)]
        case .downloadFailed:
            failDownload()
            return []
        case .downloadRejected(let feed, let now):
            guard phase == .downloading, offer?.isSameRelease(as: feed) == true else { return [] }
            retry = AppUpdateRetryRecord.counting(retry, failureOf: feed, at: now)
            failDownload()
            return [.saveRetry(retry)]
        case .automaticChanged:
            return automaticChanged(mode)
        case .notesViewed:
            updatedNotesViewed = true
            return []
        case .restartRequested:
            if phase == .ready { restartPending = true }
            return []
        case .restartCancelled:
            restartPending = false
            return []
        }
    }

    /// A download that didn't stage: an asked one says so and is offered again; an automatic one is silent (a later check
    /// tries again, unless the retry record holds the DMG back).
    private mutating func failDownload() {
        guard phase == .downloading else { return }
        progress = nil
        if downloadAsked {
            phase = .available
            downloadFailed = true
        } else {
            clearRelease()
        }
    }

    private mutating func finish(_ result: AppUpdateCheckResult, mode: AppUpdateMode, byPerson: Bool,
                                 now: Date) -> ([AppUpdateEffect], AppUpdateCheckAnswer) {
        lastCheckFailed = result == .failed
        // This launch's first check settles a copy an earlier run staged (nothing else changes the state before it).
        let pending = unconfirmed
        unconfirmed = nil
        switch result {
        case .failed:
            // The feed couldn't be reached or read: the copy shows and installs as staged.
            if let pending { adopt(pending, mode: mode) }
            return ([], .failed)
        case .upToDate:
            lastFound = nil
            // Nothing newer than the running version: whatever this run held, staged or downloaded, was withdrawn.
            var effects = withdraw()
            if pending != nil { effects.append(.discardStaged) }
            clearRelease()
            return (effects + [.discardDownloads(keeping: nil)], .upToDate)
        case .offer(let feed):
            lastFound = feed
            var effects: [AppUpdateEffect] = []
            if let pending {
                // The feed still names it: it shows now. Another release: it goes, never having shown.
                if pending.feed.isSameRelease(as: feed) { adopt(pending, mode: mode) } else { effects.append(.discardStaged) }
            }
            let (more, answer) = offer(feed, mode: mode, byPerson: byPerson, now: now)
            return (effects + more, answer)
        }
    }

    /// A copy an earlier run staged, now confirmed: Update, or New Version with auto install off and never asked for.
    private mutating func adopt(_ staged: AppUpdateStagedRecord, mode: AppUpdateMode) {
        guard case .install(let automatic) = mode else { return }
        offer = staged.feed
        downloadAsked = staged.asked
        downloadFailed = false
        phase = automatic || staged.asked ? .ready : .available
    }

    private mutating func offer(_ feed: AppUpdateFeed, mode: AppUpdateMode, byPerson: Bool,
                                now: Date) -> ([AppUpdateEffect], AppUpdateCheckAnswer) {
        guard case .install(let automatic) = mode else {
            if offer?.isSameRelease(as: feed) != true { downloadFailed = false }
            phase = .available
            offer = feed
            return ([], .cannotUpdate(feed))
        }
        // An automatic check leaves a DMG the retry record holds back alone; the person's check fetches it.
        let fetches = byPerson || AppUpdateRetryRecord.allowsAutomaticDownload(retry, of: feed, at: now)
        if let offer, offer.isSameRelease(as: feed), phase != .idle {
            switch phase {
            case .ready, .downloading:
                return ([], .downloading(feed))
            case .available where automatic && fetches:
                phase = .downloading
                downloadFailed = false
                return ([.download(feed)], .downloading(feed))
            case .available, .idle:
                return ([], .askToDownload(feed))
            }
        }
        // Another release than the one held (newer, or the held one withdrawn): drop it first, and any other DMG's
        // download (also with auto install off, where nothing downloads now).
        let effects = withdraw() + [.discardDownloads(keeping: feed)]
        clearRelease()
        guard automatic else {
            offer = feed
            phase = .available
            return (effects, .askToDownload(feed))
        }
        // Held back: nothing downloads and nothing is shown (an automatic check is never answered).
        guard fetches else { return (effects, .downloading(feed)) }
        offer = feed
        phase = .downloading
        return (effects + [.download(feed)], .downloading(feed))
    }

    private mutating func automaticChanged(_ mode: AppUpdateMode) -> [AppUpdateEffect] {
        guard case .install(let automatic) = mode, let offer else { return [] }
        if automatic, phase == .available {
            phase = .downloading
            downloadFailed = false
            return [.download(offer)]
        }
        guard !automatic, !downloadAsked else { return [] }
        // Turned off: "nothing downloads until you click". A copy already staged stays on disk, so Download and Install
        // takes it at once; it no longer installs by itself.
        switch phase {
        case .downloading:
            phase = .available
            progress = nil
            return [.cancelDownload]
        case .ready:
            phase = .available
            restartPending = false
            return []
        case .idle, .available:
            return []
        }
    }

    /// What dropping the held release takes: a download stopped, a staged copy removed.
    private func withdraw() -> [AppUpdateEffect] {
        switch phase {
        case .downloading: return [.cancelDownload]
        case .ready: return [.discardStaged]
        case .available: return offer.map { _ in [.discardStaged] } ?? []
        case .idle: return []
        }
    }

    private mutating func clearRelease() {
        phase = .idle
        offer = nil
        progress = nil
        downloadAsked = false
        downloadFailed = false
        restartPending = false
    }
}

/// Which content the pill's popover shows (AppUpdatePopover): the pill's state, read once per redraw.
enum AppUpdatePopoverContent: Equatable, Sendable {
    case ready(AppUpdateFeed)
    case waiting(AppUpdateFeed)
    case available(AppUpdateFeed)
    case cannotUpdate(AppUpdateFeed)
    case updated(AppUpdateInstalledNote)
    case none

    static func choose(_ state: AppUpdateState, mode: AppUpdateMode?) -> AppUpdatePopoverContent {
        switch state.pill {
        case .ready:
            guard let feed = state.offer else { return .none }
            return state.restartPending ? .waiting(feed) : .ready(feed)
        case .newVersion:
            guard let feed = state.offer else { return .none }
            if case .notifyOnly = mode { return .cannotUpdate(feed) }
            return .available(feed)
        case .updated:
            return state.updated.map { .updated($0) } ?? .none
        case nil:
            return .none
        }
    }
}

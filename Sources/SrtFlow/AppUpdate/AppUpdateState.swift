import Foundation

// MARK: - What the updater is doing, what the toolbar shows, and what happens next (pure)
//
// What it does: the updater's state and its one transition function, `apply(_:mode:)`, which returns the effects to run
// (download, stop a download, drop a staged copy the feed withdrew, answer a check the person started). Checking and
// downloading show nothing; a verified copy shows Update; a copy that only tells (auto install off, or one that can't
// update itself) shows New Version; the first launch after an update shows Updated until its notes are viewed. Nothing
// here ever opens a window: only a check the person started gets an answer (AppUpdateCheckAnswer). Pure, so the checks
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
    case checkStarted(byPerson: Bool)
    case checkFinished(AppUpdateCheckResult)
    /// Download and Install (auto install off).
    case downloadAsked
    case downloadProgress(Double?)
    /// The copy of this release is downloaded, verified and staged.
    case staged(AppUpdateFeed)
    case downloadFailed
    /// The Settings switch; `apply` gets the mode it now means.
    case automaticChanged
    case notesViewed
    case restartRequested
    case restartCancelled
}

enum AppUpdateEffect: Equatable, Sendable {
    /// Download, verify and stage this release (or take the copy already staged for it).
    case download(AppUpdateFeed)
    case cancelDownload
    /// The feed no longer offers the staged copy (withdrawn or replaced): remove it so it never installs.
    case discardStaged
    case answer(AppUpdateCheckAnswer)
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
    /// A check the person started waits for its answer.
    var personChecking = false
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

    var pill: Pill? {
        switch phase {
        case .ready: return .ready
        case .available: return .newVersion
        case .downloading where downloadAsked: return .newVersion
        case .idle, .downloading: return updated != nil && !updatedNotesViewed ? .updated : nil
        }
    }

    /// The state a launch starts in: a copy staged by an earlier run that this mode installs, and the installer's marker.
    static func atLaunch(staged: AppUpdateStagedRecord?, updated: AppUpdateInstalledNote?, mode: AppUpdateMode,
                         running: AppUpdateVersion) -> AppUpdateState {
        var state = AppUpdateState()
        if let updated, updated.to == running { state.updated = updated }
        guard case .install(let automatic) = mode, let staged, staged.feed.version > running else { return state }
        state.offer = staged.feed
        state.downloadAsked = staged.asked
        state.phase = automatic || staged.asked ? .ready : .available
        return state
    }

    /// One event; returns what to do next. `mode` is how this copy takes updates now (the Settings switch included).
    mutating func apply(_ event: AppUpdateEvent, mode: AppUpdateMode) -> [AppUpdateEffect] {
        switch event {
        case .checkStarted(let byPerson):
            checking = true
            if byPerson { personChecking = true }
            return []
        case .checkFinished(let result):
            checking = false
            let answering = personChecking
            personChecking = false
            let (effects, answer) = finish(result, mode: mode)
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
            return []
        case .downloadFailed:
            guard phase == .downloading else { return [] }
            progress = nil
            if downloadAsked {
                phase = .available
                downloadFailed = true
            } else {
                clearRelease()   // silent: the next check tries again
            }
            return []
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

    private mutating func finish(_ result: AppUpdateCheckResult, mode: AppUpdateMode) -> ([AppUpdateEffect], AppUpdateCheckAnswer) {
        lastCheckFailed = result == .failed
        switch result {
        case .failed:
            return ([], .failed)
        case .upToDate:
            // Nothing newer than the running version: whatever this run held was withdrawn and must never install.
            let effects = withdraw()
            clearRelease()
            return (effects, .upToDate)
        case .offer(let feed):
            return offer(feed, mode: mode)
        }
    }

    private mutating func offer(_ feed: AppUpdateFeed, mode: AppUpdateMode) -> ([AppUpdateEffect], AppUpdateCheckAnswer) {
        guard case .install(let automatic) = mode else {
            if offer?.isSameRelease(as: feed) != true { downloadFailed = false }
            phase = .available
            offer = feed
            return ([], .cannotUpdate(feed))
        }
        if let offer, offer.isSameRelease(as: feed), phase != .idle {
            switch phase {
            case .ready, .downloading:
                return ([], .downloading(feed))
            case .available where automatic:
                phase = .downloading
                downloadFailed = false
                return ([.download(feed)], .downloading(feed))
            case .available, .idle:
                return ([], .askToDownload(feed))
            }
        }
        // Another release than the one held (newer, or the held one withdrawn): drop it first.
        let effects = withdraw()
        clearRelease()
        offer = feed
        guard automatic else {
            phase = .available
            return (effects, .askToDownload(feed))
        }
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

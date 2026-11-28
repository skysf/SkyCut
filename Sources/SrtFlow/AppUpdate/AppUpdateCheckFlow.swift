import Foundation

// MARK: - The window of SkyCut › Check for Updates…: what it shows and when (pure)
//
// What it does: the one window the updater opens, for a check the person started from the app menu, as a value with its
// transitions. Choosing the item shows nothing for a moment: an answer within `grace` (about half a second) opens the
// window straight on it, so the checking state never flashes; otherwise the window opens checking (a spinner, «Checking
// for updates…», Cancel). Once on screen, the checking state stays at least `minimumChecking`, then the answer replaces it
// in place. Cancel stops the check and closes the window. The close button only hides it: the check goes on and its answer
// never brings the window back (a newer version reaches the toolbar pill as usual). Try Again, or the item chosen again
// while the window shows an answer, turns the window to checking at once, for at least `minimumChecking`. While a download
// runs, the menu item shows the window on that download without a check (`showing`). Times are seconds on one monotonic
// clock (the window's: ProcessInfo.systemUptime), so the checks drive every case.
// AppUpdateCheckDisplay: what the window draws now. A release the check found is followed live from the updater's state
// (its download and progress, verified and ready, a restart waiting, a download that didn't finish), never from the network.
// AppUpdateMenuEntry: the app menu's item, from the same state (greyed while checking, the percent while downloading).
// What it doesn't: check, or stop a check (AppUpdater); draw (AppUpdateCheckContent); the window (AppUpdateCheckWindow).
// Rules: docs/architecture/app-updates.md "What the person sees".

struct AppUpdateCheckFlow: Equatable, Sendable {
    /// An answer quicker than this opens the window straight on it.
    static let grace: TimeInterval = 0.5
    /// The checking state, once on screen, stays at least this long: it never flashes between two answers.
    static let minimumChecking: TimeInterval = 0.5

    enum Shows: Equatable, Sendable {
        case checking
        case answer(AppUpdateCheckAnswer)
    }

    /// What the window shows; nil: it isn't on screen.
    private(set) var shows: Shows?
    /// The person chose the item and nothing shows yet: the grace period runs from here.
    private(set) var waitingSince: TimeInterval?
    /// When the checking state came on screen.
    private(set) var checkingSince: TimeInterval?
    /// An answer that came before the checking state had been on screen for `minimumChecking`.
    private(set) var held: AppUpdateCheckAnswer?
    /// The person closed the window while it checked: the check goes on, its answer shows nothing.
    private(set) var hidden = false

    /// What the window does after an event.
    struct Step: Equatable, Sendable {
        /// Put the window on screen: the first thing this check shows.
        var opens = false
        /// Take it off screen.
        var closes = false
        /// Stop the check (Cancel).
        var stopsCheck = false
        /// Call `tick` at this time (a run-loop timer): the end of the grace period, or of the checking state's minimum.
        var tickAt: TimeInterval?
    }

    /// The person chose Check for Updates… or Try Again (its check has started, or joined the one in flight).
    mutating func chosen(at now: TimeInterval) -> Step {
        held = nil
        hidden = false
        guard shows == nil else {
            // The window is on screen with an answer: it turns to checking where it is.
            showChecking(at: now)
            return Step()
        }
        waitingSince = now
        return Step(tickAt: now + Self.grace)
    }

    /// A timer the last step asked for.
    mutating func tick(at now: TimeInterval) -> Step {
        if let since = waitingSince {
            guard now >= since + Self.grace else { return Step(tickAt: since + Self.grace) }
            waitingSince = nil
            showChecking(at: now)
            return Step(opens: true)
        }
        guard shows == .checking, let held, let since = checkingSince else { return Step() }
        guard now >= since + Self.minimumChecking else { return Step(tickAt: since + Self.minimumChecking) }
        show(held)
        return Step()
    }

    /// The check's answer (AppUpdater's `.answer` effect).
    mutating func answered(_ answer: AppUpdateCheckAnswer, at now: TimeInterval) -> Step {
        if hidden {
            // Closed while checking: the window stays closed (the updater's other effects, the pill, are as usual).
            self = AppUpdateCheckFlow()
            return Step()
        }
        if waitingSince != nil {
            waitingSince = nil
            show(answer)
            return Step(opens: true)
        }
        // Nobody waits for it (Cancel came first), or the window already shows an answer.
        guard shows == .checking, let since = checkingSince else { return Step() }
        guard now >= since + Self.minimumChecking else {
            held = answer
            return Step(tickAt: since + Self.minimumChecking)
        }
        show(answer)
        return Step()
    }

    /// Cancel while checking: the check stops and the window closes.
    mutating func cancelled() -> Step {
        let onScreen = shows != nil
        self = AppUpdateCheckFlow()
        return Step(closes: onScreen, stopsCheck: true)
    }

    /// The menu item while a download runs: the window shows that download now (on screen and key: the person chose it),
    /// wherever it was. No check is involved.
    mutating func showing(_ answer: AppUpdateCheckAnswer) -> Step {
        self = AppUpdateCheckFlow()
        show(answer)
        return Step(opens: true)
    }

    /// The close button, or a button that only dismisses an answer. While the check runs the window only hides: the check
    /// goes on (hiding is not cancelling). Neither ever stops a download.
    mutating func closed() -> Step {
        guard shows != nil else { return Step() }
        let checkRuns = shows == .checking && held == nil
        self = AppUpdateCheckFlow()
        hidden = checkRuns
        return Step(closes: true)
    }

    private mutating func showChecking(at now: TimeInterval) {
        shows = .checking
        checkingSince = now
        held = nil
    }

    private mutating func show(_ answer: AppUpdateCheckAnswer) {
        shows = .answer(answer)
        checkingSince = nil
        held = nil
    }
}

/// What the check window draws now: the flow's state, with a release the check found read live from the updater's state
/// (the same source as the pill, Settings' status line and get_status). Pure.
enum AppUpdateCheckDisplay: Equatable, Sendable {
    case checking
    case upToDate
    case couldNotCheck
    /// Downloading, or verifying once every byte is in (fraction 1); nil before the first bytes.
    case downloading(AppUpdateFeed, fraction: Double?)
    /// Downloaded and verified: installs when SkyCut quits.
    case ready(AppUpdateFeed)
    /// Restart and Update was clicked and waits for running work.
    case waitingToRestart(AppUpdateFeed)
    /// The download didn't finish. `asked`: Download and Install's (auto install off: Try Again downloads again); else the
    /// automatic one, whose release the updater has let go (Try Again checks again).
    case downloadFailed(AppUpdateFeed, asked: Bool)
    case askToDownload(AppUpdateFeed)
    case cannotUpdate(AppUpdateFeed)

    static func make(_ shows: AppUpdateCheckFlow.Shows, state: AppUpdateState, mode: AppUpdateMode?) -> AppUpdateCheckDisplay {
        let found: AppUpdateFeed
        switch shows {
        case .checking: return .checking
        case .answer(.upToDate): return .upToDate
        case .answer(.failed): return .couldNotCheck
        case .answer(.downloading(let feed)), .answer(.askToDownload(let feed)), .answer(.cannotUpdate(let feed)): found = feed
        }
        if case .notifyOnly = mode { return .cannotUpdate(state.offer ?? found) }
        // No release held any more: an automatic download that didn't stage lets it go (or a later check withdrew it).
        guard let offer = state.offer else { return .downloadFailed(found, asked: false) }
        switch state.phase {
        case .downloading: return .downloading(offer, fraction: state.progress)
        case .ready: return state.restartPending ? .waitingToRestart(offer) : .ready(offer)
        case .available: return state.downloadFailed ? .downloadFailed(offer, asked: true) : .askToDownload(offer)
        case .idle: return .downloadFailed(found, asked: false)
        }
    }

    /// Whole percents of the updater's progress, floored as Settings' status line and the popover show it.
    static func percent(_ fraction: Double?) -> Int {
        Int((min(1, max(0, fraction ?? 0)) * 100).rounded(.down))
    }
}

/// The app menu's item (AppUpdateMenuItem), read from the updater's state. Pure.
enum AppUpdateMenuEntry: Equatable, Sendable {
    /// "Check for Updates…": checks, and its window opens.
    case check
    /// Greyed "Checking for Updates…" while any check runs: a second choice never starts a second check.
    case checking
    /// "Downloading Update (29%)…": shows the check window on the download; no check starts.
    case downloading(percent: Int)
    /// "Restart and Update to %@…": opens the pill's popover.
    case restart(String)

    static func make(_ state: AppUpdateState) -> AppUpdateMenuEntry {
        switch state.phase {
        case .ready: if let offer = state.offer { return .restart(offer.version.description) }
        case .downloading: return .downloading(percent: AppUpdateCheckDisplay.percent(state.progress))
        case .idle, .available: break
        }
        return state.checking ? .checking : .check
    }
}

import Foundation

// MARK: - What the launch does next, at each turn of offering the move (pure)
//
// What it does: the decisions of MoveToApplicationsLaunch, as pure functions the checks call. Before asking: carry on, ask
// (with the Trash line only for an app of that name that is there and stopped), or, when that app is running, say so and
// quit this copy instead of asking. After the question: Not Now carries on from the disk. After the move: what to say,
// whether to eject (only the image SkyCut ran from the top of), and whether this launch goes on or quits; never both.
// What it doesn't: show anything, probe or move (MoveToApplicationsLaunch performs these answers; RunningBundleProbe,
// AppBundleMover, InstallerDisk).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

enum MoveToApplicationsFlow {
    /// What is at /Applications/<the bundle's name> when the launch is about to ask (RunningBundleProbe for `running`).
    struct Installed: Equatable, Sendable {
        var exists: Bool
        var running: Bool
    }

    enum Start: Equatable, Sendable {
        case continueLaunch
        /// The question; `replacing` adds the line that the app there goes to the Trash.
        case ask(replacing: Bool)
        case end(End)
    }

    enum Answer: Equatable, Sendable {
        case move, notNow
    }

    /// How a launch that offered the move ends.
    enum End: Equatable, Sendable {
        /// The moved copy is open: quit, then eject this disk if there is one to eject.
        case reopened(eject: InstallerDisk?)
        /// An app of that name is open in Applications: say so, and quit this copy so "open the disk's copy again" holds.
        case running
        /// This user can't write the Applications folder: say so (Show Applications Folder) and go on from the disk.
        case notWritable
        /// A step failed, the destination as it was: say which, and go on from the disk.
        case failed(AppBundleMover.Step, detail: String?, oldAppInTrash: URL?)
        /// Moved, but macOS didn't open the copy: say so, and go on from the disk.
        case notOpened(installed: URL, detail: String?)

        /// Whether this launch then goes on from the disk; otherwise it quits. Never both.
        var continuesLaunch: Bool {
            switch self {
            case .reopened, .running: return false
            case .notWritable, .failed, .notOpened: return true
            }
        }
    }

    /// Whether macOS opened the moved copy (MoveToApplicationsLaunch.openNewInstance).
    enum Opened: Equatable, Sendable {
        case notTried, opened
        case failed(String?)
    }

    static func start(_ decision: MoveToApplicationsOffer.Decision, installed: Installed) -> Start {
        guard decision.offers else { return .continueLaunch }
        // Never promise the Trash for an app that is running: it isn't replaced, so this copy steps aside instead.
        if installed.running { return .end(.running) }
        return .ask(replacing: installed.exists)
    }

    /// Not Now (or Escape) goes on from the disk; Move moves.
    static func continuesAfter(_ answer: Answer) -> Bool {
        answer == .notNow
    }

    static func end(_ outcome: AppBundleMover.Outcome, opened: Opened, disk: InstallerDisk?, original: URL) -> End {
        switch outcome {
        case .moved(let installed):
            switch opened {
            case .opened:
                // Only an image with SkyCut at its top, as on the installer disk; somebody's own image stays mounted.
                return .reopened(eject: disk.flatMap { $0.holdsAtTop(original) ? $0 : nil })
            case .failed(let detail): return .notOpened(installed: installed, detail: detail)
            case .notTried: return .notOpened(installed: installed, detail: nil)
            }
        case .runningAtDestination: return .running
        case .destinationNotWritable: return .notWritable
        case .failed(let step, let detail, let oldAppInTrash): return .failed(step, detail: detail, oldAppInTrash: oldAppInTrash)
        }
    }
}

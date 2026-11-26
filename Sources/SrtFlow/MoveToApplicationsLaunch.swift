import AppKit

// MARK: - Offering, at launch, to move SkyCut from the installer disk into Applications
//
// What it does: first thing in applicationDidFinishLaunching, before the AI channel or anything else starts. When
// MoveToApplicationsOffer says this launch runs from the installer disk, it looks at the app of that name in Applications
// (RunningBundleProbe, live): running, it says so and this copy quits; otherwise it asks once (Move to Applications /
// Not Now). Move: AppBundleMover copies, checks and puts SkyCut in /Applications under the progress panel, macOS opens the
// moved copy as a new instance, this one quits, and the installer disk is ejected once this process is gone (InstallerDisk;
// only a disk image with the app at its top). Not Now, or a move that stops, continues this launch from the disk, and the
// next launch from the disk asks again: nothing is remembered. Every decision is MoveToApplicationsFlow's (pure, checked);
// this file only performs them.
// What it doesn't: the rule, the decisions, the move, the words (MoveToApplicationsOffer, MoveToApplicationsFlow,
// AppBundleMover, MoveToApplicationsAlerts).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

@MainActor
enum MoveToApplicationsLaunch {
    nonisolated static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Runs `continueLaunch` unless SkyCut quits (to reopen from Applications, or to leave the open one alone); then it
    /// never runs.
    static func offer(otherwise continueLaunch: @escaping @MainActor () -> Void) {
        let original = Bundle.main.bundleURL
        let (facts, disk) = currentFacts()
        let decision = MoveToApplicationsOffer.decide(facts)
        guard decision.offers else { return continueLaunch() }

        _ = AppLanguageStore.shared   // the person's in-app language for the words below
        let appName = original.deletingPathExtension().lastPathComponent
        let mover = mover()
        let destination = mover.destination(for: original)
        let installed = MoveToApplicationsFlow.Installed(
            exists: mover.hasItem(at: destination), running: RunningBundleProbe.isRunning(destination))
        NSApp.activate()
        switch MoveToApplicationsFlow.start(decision, installed: installed) {
        case .continueLaunch:
            return continueLaunch()
        case .end(let end):
            return finish(end, appName: appName, otherwise: continueLaunch)
        case .ask(let replacing):
            let response = MoveToApplicationsAlerts.question(appName: appName, replacing: replacing).runModal()
            let answer: MoveToApplicationsFlow.Answer = response == .alertFirstButtonReturn ? .move : .notNow
            if MoveToApplicationsFlow.continuesAfter(answer) { return continueLaunch() }
        }
        let (outcome, opened) = MoveToApplicationsAlerts.whileMoving(appName: appName) {
            () -> (AppBundleMover.Outcome, MoveToApplicationsFlow.Opened) in
            let outcome = mover.move(original)
            guard case .moved(let installed) = outcome else { return (outcome, .notTried) }
            return (outcome, openNewInstance(installed))
        }
        finish(MoveToApplicationsFlow.end(outcome, opened: opened, disk: disk, original: original), appName: appName,
               otherwise: continueLaunch)
    }

    /// Says what the end needs saying, then either goes on from the disk or quits, as the end says; never both.
    private static func finish(_ end: MoveToApplicationsFlow.End, appName: String,
                               otherwise continueLaunch: @escaping @MainActor () -> Void) {
        switch end {
        case .reopened(let eject):
            eject?.ejectAfterExit(of: ProcessInfo.processInfo.processIdentifier)
        case .running:
            _ = MoveToApplicationsAlerts.running(appName: appName).runModal()
        case .notWritable:
            if MoveToApplicationsAlerts.notWritable(appName: appName).runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(applicationsFolder)
            }
        case .failed(let step, let detail, let oldAppInTrash):
            _ = MoveToApplicationsAlerts.failed(step, detail: detail, oldAppInTrash: oldAppInTrash, appName: appName).runModal()
        case .notOpened(let installed, let detail):
            if MoveToApplicationsAlerts.openFailed(appName: appName, detail: detail).runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([installed])
            }
        }
        if end.continuesLaunch { continueLaunch() } else { NSApp.terminate(nil) }
    }

    /// This launch's facts: the running bundle, its volume (InstallerDisk), the environment. Cheap: the disk image's
    /// description is only read for a read-only volume.
    nonisolated static func currentFacts() -> (MoveToApplicationsOffer.Facts, InstallerDisk?) {
        let original = Bundle.main.bundleURL
        let disk = InstallerDisk.containing(original)
        let facts = MoveToApplicationsOffer.Facts(
            bundlePath: original.standardizedFileURL.path, bundleIdentifier: Bundle.main.bundleIdentifier,
            homeDirectory: NSHomeDirectory(), onReadOnlyDiskImage: disk != nil, environment: ProcessInfo.processInfo.environment)
        return (facts, disk)
    }

    /// SkyCut's own: /Applications, the live running probe (asked before the copy and right before the Trash), the person's
    /// Trash, a staging folder on the Applications folder's volume (an item replacement folder: renaming from it into
    /// /Applications is atomic).
    nonisolated static func mover() -> AppBundleMover {
        AppBundleMover(
            destinationFolder: applicationsFolder,
            isRunning: RunningBundleProbe.isRunning,
            trash: { item in
                var trashed: NSURL?
                try FileManager.default.trashItem(at: item, resultingItemURL: &trashed)
                return (trashed as URL?) ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash").appendingPathComponent(item.lastPathComponent)
            },
            makeStagingFolder: {
                try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: applicationsFolder, create: true)
            })
    }

    /// Opens the moved copy as a new instance (this one, with the same identifier, is still running) and waits for macOS's
    /// answer, at most 60 s. Off the main thread.
    nonisolated static func openNewInstance(_ app: URL) -> MoveToApplicationsFlow.Opened {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let answered = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            failure = error
            answered.signal()
        }
        guard answered.wait(timeout: .now() + 60) == .success else { return .failed(nil) }
        return failure.map { .failed($0.localizedDescription) } ?? .opened
    }
}

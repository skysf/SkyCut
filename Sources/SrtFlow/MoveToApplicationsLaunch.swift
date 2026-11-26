import AppKit

// MARK: - Offering, at launch, to move SkyCut from the installer disk into Applications
//
// What it does: first thing in applicationDidFinishLaunching, before the AI channel or anything else starts. When
// MoveToApplicationsOffer says this launch runs from the installer disk, it asks once (Move to Applications / Not Now).
// Move: AppBundleMover copies, checks and puts SkyCut in /Applications under the progress panel, macOS opens the moved
// copy as a new instance, this one quits, and the installer disk is ejected once this process is gone (InstallerDisk; only
// a disk image with the app at its top). Not Now, or a move that stops, continues this launch from the disk, and the next
// launch from the disk asks again: nothing is remembered.
// What it doesn't: the rule, the move, the words (MoveToApplicationsOffer, AppBundleMover, MoveToApplicationsAlerts).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

@MainActor
enum MoveToApplicationsLaunch {
    static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Runs `continueLaunch` unless SkyCut quits to reopen from Applications; then it never runs.
    static func offer(otherwise continueLaunch: @escaping @MainActor () -> Void) {
        let original = Bundle.main.bundleURL
        let disk = InstallerDisk.containing(original)
        let facts = MoveToApplicationsOffer.Facts(
            bundlePath: original.standardizedFileURL.path, bundleIdentifier: Bundle.main.bundleIdentifier,
            homeDirectory: NSHomeDirectory(), onReadOnlyDiskImage: disk != nil, environment: ProcessInfo.processInfo.environment)
        guard MoveToApplicationsOffer.decide(facts).offers else { return continueLaunch() }

        _ = AppLanguageStore.shared   // the person's in-app language for the words below
        let appName = original.deletingPathExtension().lastPathComponent
        var mover = mover()
        NSApp.activate()
        let replacing = mover.hasItem(at: mover.destination(for: original))
        guard MoveToApplicationsAlerts.question(appName: appName, replacing: replacing).runModal() == .alertFirstButtonReturn else {
            return continueLaunch()
        }
        // Who is running, taken here on the main thread: the move itself runs off it.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map(path) })
        mover.isRunning = { running.contains(path($0)) }
        let moving = mover
        let (outcome, opened) = MoveToApplicationsAlerts.whileMoving(appName: appName) { () -> (AppBundleMover.Outcome, Opened) in
            let outcome = moving.move(original)
            guard case .moved(let installed) = outcome else { return (outcome, .notTried) }
            return (outcome, openNewInstance(installed))
        }
        switch (outcome, opened) {
        case (.moved, .opened):
            if let disk, disk.holdsAtTop(original) { disk.ejectAfterExit(of: ProcessInfo.processInfo.processIdentifier) }
            NSApp.terminate(nil)
            return
        case (.moved(let installed), .failed(let detail)):
            if MoveToApplicationsAlerts.openFailed(appName: appName, detail: detail).runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([installed])
            }
        case (.runningAtDestination, _):
            MoveToApplicationsAlerts.running(appName: appName).runModal()
        case (.destinationNotWritable(let folder), _):
            if MoveToApplicationsAlerts.notWritable(appName: appName).runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(folder)
            }
        case (.failed(let step, let detail, let oldAppInTrash), _):
            MoveToApplicationsAlerts.failed(step, detail: detail, oldAppInTrash: oldAppInTrash, appName: appName).runModal()
        case (.moved, .notTried):
            break
        }
        continueLaunch()
    }

    /// SkyCut's own: /Applications, the person's Trash, a staging folder on the Applications folder's volume (an item
    /// replacement folder: renaming from it into /Applications is atomic). `isRunning` is set when the person answers.
    static func mover() -> AppBundleMover {
        AppBundleMover(
            destinationFolder: applicationsFolder,
            isRunning: { _ in true },
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

    enum Opened: Equatable {
        case notTried, opened
        case failed(String?)
    }

    /// Opens the moved copy as a new instance (this one, with the same identifier, is still running) and waits for macOS's
    /// answer, at most 60 s. Off the main thread.
    nonisolated static func openNewInstance(_ app: URL) -> Opened {
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

    private nonisolated static func path(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

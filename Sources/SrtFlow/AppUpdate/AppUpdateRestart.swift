import AppKit
import Foundation

// MARK: - Restart and Update: the quit it starts, the relaunch after it, the projects reopened
//
// What it does: Restart and Update quits through the normal quit flow (NSApp.terminate): ProjectQuit asks about unsaved
// projects, and Cancel there cancels the restart (ProjectQuit.quitCancelled); a screen recording never gets this far
// (AppUpdater waits for it, AppUpdateBusy). At applicationWillTerminate, after the install (AppUpdater.installAtQuit), it
// remembers the windowed projects' files and starts the shell that opens SkyCut again once this process has exited
// (AppUpdateRelaunch: never two instances, never a path that no longer holds an app). The next launch reopens those
// projects (only right after a restart; the main window's in the main window).
// What it doesn't: wait for running work (AppUpdater with AppUpdateBusy), install (AppUpdateInstaller), the shell itself.
// Rules: docs/architecture/app-updates.md "Restart and Update".

@MainActor
enum AppUpdateRestart {
    static let reopenKey = "SrtFlow.update.reopen.v1"
    static let reopenFreshness: TimeInterval = 10 * 60
    /// The quit in progress is Restart and Update's.
    private(set) static var quitting = false

    static func quitToRestart() {
        quitting = true
        ProjectQuit.quitCancelled = { AppUpdateRestart.quitting = false }
        NSApp.terminate(nil)
    }

    /// applicationWillTerminate, after the install: relaunch when this quit restarts.
    static func finishQuit() {
        guard quitting else { return }
        rememberProjects()
        AppUpdateRelaunch.start(Bundle.main.bundleURL, afterExitOf: ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: The projects

    private static func rememberProjects() {
        let projects = OpenProjects.shared
        let record = AppUpdateReopenRecord(
            primary: projects.primary.documentURL?.path,
            windows: projects.others.filter { !projects.isHeadless($0) }.compactMap { $0.documentURL?.path },
            at: Date())
        UserDefaults.standard.set(record.dictionary, forKey: reopenKey)
    }

    /// At launch (any copy): the projects a restart just now left open, opened again; the record is read once.
    static func reopenProjectsIfRestarted() {
        let defaults = UserDefaults.standard
        let stored = defaults.dictionary(forKey: reopenKey)
        guard stored != nil else { return }
        defaults.removeObject(forKey: reopenKey)
        guard let record = AppUpdateReopenRecord(dictionary: stored), record.isFresh(now: Date(), freshness: reopenFreshness) else { return }
        Task { @MainActor in
            let (primary, windows) = await AppUpdateWork.run { () -> (String?, [String]) in
                let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
                return (record.primary.flatMap { exists($0) ? $0 : nil }, record.windows.filter(exists))
            }
            let projects = OpenProjects.shared
            if let primary, projects.primary.documentURL == nil, projects.primary.state.isEmpty {
                await projects.userOpen(URL(fileURLWithPath: primary), from: projects.primary)
            }
            for path in windows { await projects.open(URL(fileURLWithPath: path), placement: .window(inFront: false)) }
        }
    }
}

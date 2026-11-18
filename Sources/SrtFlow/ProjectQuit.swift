import AppKit
import Foundation

// MARK: - Quitting with projects open
//
// What it does: SkyCut's answer to Quit (applicationShouldTerminate, and after a screen recording has been settled):
// every open project is written and asked about (`prepareToClose`), its file written off the main thread. Nothing to
// write or ask: quit at once. A project whose drive does not answer within a short wait: an alert says so and keeps
// waiting by itself — SkyCut quits as soon as the file is written — and offers to quit anyway (losing the changes not yet
// saved) or not to quit. The main thread never waits on a drive, and Quit never hangs.
// What it doesn't: the write (ProjectFileWriter); a running screen recording (ScreenRecordingCoordinator settles it first,
// then asks here); which projects are open (OpenProjects).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md): Quit wrote every project on the main
// thread inside applicationShouldTerminate — a project on a stuck external drive made Quit hang until Force Quit.
// Rules: docs/architecture/video-edit-project-file.md §5 "Writing the project file off the main thread".

@MainActor
enum ProjectQuit {
    /// How long Quit waits quietly for a project's drive before it asks (a USB hard drive may just be spinning up).
    static var grace: TimeInterval = 3
    /// The run in progress: Quit pressed again, or the screen recording settling twice, gets the same answer.
    private static var running: Task<Bool, Never>?
    /// How the person is asked while a drive does not answer (a seam: the checks answer for them).
    static var askAboutDrive: @MainActor (VideoEditProject) async -> DriveChoice = { waitForDrive($0) }

    /// applicationShouldTerminate: `.terminateNow` when nothing needs writing or asking; otherwise `.terminateLater`, and
    /// AppKit gets the answer once every project is settled.
    static func begin() -> NSApplication.TerminateReply {
        if OpenProjects.shared.all.allSatisfy({ $0.closesAtOnce() }) { return .terminateNow }
        Task { NSApp.reply(toApplicationShouldTerminate: await prepareAll()) }
        return .terminateLater
    }

    /// Every open project written and asked about; the first one that stays stops the quit (the later ones are not asked).
    static func prepareAll() async -> Bool {
        if let running { return await running.value }
        let run = Task { @MainActor in await prepareEach() }
        running = run
        let ready = await run.value
        running = nil
        return ready
    }

    private static func prepareEach() async -> Bool {
        for project in OpenProjects.shared.all {
            guard await settle(project) else { return false }
        }
        return true
    }

    /// One project: ready, or the person chose. "Quit Anyway" gives up only this project's unsaved changes.
    private static func settle(_ project: VideoEditProject) async -> Bool {
        while true {
            switch await project.prepareToClose(deadline: grace) {
            case .ready: return true
            case .refused: return false
            case .waitingForDrive:
                switch await askAboutDrive(project) {
                case .written: continue    // the write ended: look again (it may have failed, or there are newer edits)
                case .quitAnyway: return true
                case .stay: return false
                }
            }
        }
    }

    enum DriveChoice { case written, quitAnyway, stay }

    /// The alert while a project's drive does not answer. It closes by itself when the write ends (`abortModal`).
    static func waitForDrive(_ project: VideoEditProject) -> DriveChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n("“%@” isn't saved yet"), project.projectName)
        alert.informativeText = String(
            format: L10n("The drive with “%@” is not responding. It may be asleep or disconnected. SkyCut quits by itself as soon as the project is saved. If you quit now, the changes since it was last saved are lost."),
            project.documentURL.map(ProjectSaveText.driveName(of:)) ?? project.projectName
        )
        alert.addButton(withTitle: L10n("Don't Quit"))
        alert.addButton(withTitle: L10n("Quit Anyway"))
        // Runs inside the alert's modal loop (this task can only start once runModal has taken over the main thread).
        let watcher = Task { @MainActor in
            _ = await project.fileWriter.waitUntilIdle(deadline: nil)
            if !Task.isCancelled { NSApp.abortModal() }
        }
        let response = alert.runModal()
        watcher.cancel()
        switch response {
        case .alertFirstButtonReturn: return .stay
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .written
        }
    }
}

import AppKit
import Foundation

// MARK: - Quitting with projects open
//
// What it does: SkyCut's answer to Quit (applicationShouldTerminate, and after a screen recording has been settled):
// every open project is written and asked about (`prepareToClose`), its file written off the main thread. Nothing to
// write or ask: quit at once. A project whose drive does not answer within a short wait: an alert says so and keeps
// waiting by itself — SkyCut quits as soon as the file is written — and offers to quit anyway (losing the changes not yet
// saved) or not to quit. The main thread never waits on a drive, and Quit never hangs. A project let through is looked at
// again if it changed while another one was being settled (an AI edit while an alert was up), and the reply is given in
// the same main-thread turn as that last look, so no edit lands between them. "Quit Anyway" gives up the document its
// alert showed: another document opened in that project since is settled like any other.
// The Burn In page's subtitles with unsaved edits are asked about on the same path, after the projects: Save / Don't Save /
// Cancel each (BurnInSubtitleEdits, since 2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md),
// and they are part of the last look before the reply.
// What it doesn't: the write (ProjectFileWriter); a running screen recording (ScreenRecordingCoordinator settles it first,
// then asks here); which projects are open (OpenProjects); the subtitles' question and saves (BurnInSubtitleEdits).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md): Quit wrote every project on the main
// thread inside applicationShouldTerminate — a project on a stuck external drive made Quit hang until Force Quit.
// Looked at again before the reply since 2026-11-19 (docs/bugfixes/2026-11-19-close-trusts-a-stale-save.md): a project
// settled first and edited while a later one waited for its drive quit with that edit unsaved.
// "Quit Anyway" bound to the document generation since 2026-11-19
// (docs/bugfixes/2026-11-19-quit-anyway-covers-a-replaced-document.md): it was kept for the project object, so a document
// opened in that project after the answer (an Open waiting for the write, the AI) quit with its edits unsaved.
// Rules: docs/architecture/video-edit-project-file.md §5 "Writing the project file off the main thread".

@MainActor
enum ProjectQuit {
    /// How long Quit waits quietly for a project's drive before it asks (a USB hard drive may just be spinning up).
    static var grace: TimeInterval = 3
    /// Who waits for the run in progress (Quit pressed again, the screen recording settling twice): each gets that run's
    /// answer. Empty = no run.
    private static var replies: [@MainActor (Bool) -> Void] = []
    /// How the person is asked while a drive does not answer (a seam: the checks answer for them).
    static var askAboutDrive: @MainActor (VideoEditProject) async -> DriveChoice = { waitForDrive($0) }
    /// Told when a quit stops because a project or a Burn In subtitle stayed: Restart and Update then no longer restarts
    /// (AppUpdateRestart).
    static var quitCancelled: (@MainActor () -> Void)?

    /// applicationShouldTerminate: `.terminateNow` when nothing needs writing or asking; otherwise `.terminateLater`, and
    /// AppKit gets the answer once every project is settled.
    static func begin() -> NSApplication.TerminateReply {
        if quitsAtOnce() { return .terminateNow }
        prepareAll { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    /// Nothing to write or ask: every project closes at once and no Burn In subtitle has unsaved edits — a time still being
    /// typed in a subtitle cell written first (PendingTimecode), as `closesAtOnce` ends a project's pending typing.
    static func quitsAtOnce() -> Bool {
        PendingTimecode.commit()
        return OpenProjects.shared.all.allSatisfy({ $0.closesAtOnce() })
            && !BurnInSubtitleEdits.shared.needsAsking(after: BurnInSubtitleEdits.Discarded())
    }

    /// Every open project written and asked about; the first one that stays stops the quit (the later ones are not asked).
    /// `reply` is called right after the last look at the projects, in the same main-thread turn: nothing can change a
    /// project between that look and the reply. Asked again while a run is going: that run answers both.
    static func prepareAll(reply: @escaping @MainActor (Bool) -> Void) {
        replies.append(reply)
        guard replies.count == 1 else { return }
        Task { @MainActor in
            // No suspension between prepareEach's last look and the replies (returning from an async call on the same
            // actor does not hop).
            let ready = await prepareEach()
            let waiting = replies
            replies = []
            for reply in waiting { reply(ready) }
            if !ready { quitCancelled?() }
        }
    }

    /// The same, awaited (the checks).
    static func prepareAll() async -> Bool {
        await withCheckedContinuation { continuation in
            prepareAll { continuation.resume(returning: $0) }
        }
    }

    /// Settles every open project that needs it, again and again until a look finds each one with nothing to write, let
    /// through and unchanged since, or given up ("Quit Anyway") and still the document that alert showed. Projects opened
    /// meanwhile are included, and so is another document opened since in a project already settled. Then the Burn In
    /// subtitles with unsaved edits, each saved or given up ("Don't Save") as it is (a Save waits for its drive at most
    /// `grace`, then is asked about again); Cancel stays. Asking them takes time, so the projects are looked at again after
    /// them, and the last look covers both.
    private static func prepareEach() async -> Bool {
        PendingTimecode.commit()
        var marks: [ObjectIdentifier: QuitMark] = [:]
        var subtitles = BurnInSubtitleEdits.Discarded()
        while true {
            while let project = OpenProjects.shared.all.first(where: { needsSettling($0, marks[ObjectIdentifier($0)]) }) {
                switch await settle(project) {
                case .letThrough: marks[ObjectIdentifier(project)] = .letThrough(QuitMark.Snapshot(project))
                case .gaveUp(let generation): marks[ObjectIdentifier(project)] = .gaveUp(generation: generation)
                case .stays: return false
                }
            }
            guard BurnInSubtitleEdits.shared.needsAsking(after: subtitles) else { return true }
            guard await BurnInSubtitleEdits.shared.settleForQuit(into: &subtitles, deadline: grace) else { return false }
        }
    }

    /// Not yet settled and something to write or ask; or let through, then changed (an edit, another document, a write);
    /// or given up, then holding another document (an Open that waited for the write, the AI's open_project).
    private static func needsSettling(_ project: VideoEditProject, _ mark: QuitMark?) -> Bool {
        guard !project.closesAtOnce() else { return false }
        switch mark {
        case nil: return true
        case .gaveUp(let generation): return project.documentGeneration != generation
        case .letThrough(let snapshot): return snapshot != QuitMark.Snapshot(project) || project.fileWriter.isBusy
        }
    }

    /// One project: ready, or the person chose. "Quit Anyway" gives up only the unsaved changes of the document the alert
    /// showed.
    private static func settle(_ project: VideoEditProject) async -> Settled {
        while true {
            switch await project.prepareToClose(deadline: grace) {
            case .ready: return .letThrough
            case .refused: return .stays
            case .waitingForDrive:
                // The document the alert is about, taken in the turn the alert is built: an Open or the AI may put another
                // document in this project while it is up or afterwards.
                let shown = project.documentGeneration
                switch await askAboutDrive(project) {
                case .written: continue    // the write ended: look again (it may have failed, or there are newer edits)
                case .quitAnyway: return .gaveUp(generation: shown)
                case .stay: return .stays
                }
            }
        }
    }

    private enum Settled { case letThrough, gaveUp(generation: Int), stays }

    /// What a run remembers about a project it settled — always for one document generation, never for the project object
    /// alone: the object can hold another document later, and a freed object's identifier can be reused.
    private enum QuitMark {
        /// Ready when settled: an untitled project the person chose to discard is not asked again unless it changed.
        case letThrough(Snapshot)
        /// "Quit Anyway": the unsaved changes of that document generation are given up, whatever happens to it afterwards.
        case gaveUp(generation: Int)

        struct Snapshot: Equatable {
            let generation: Int
            let revision: Int

            @MainActor init(_ project: VideoEditProject) {
                generation = project.documentGeneration
                revision = project.fileWriter.revision
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

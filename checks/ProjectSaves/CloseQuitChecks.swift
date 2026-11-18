import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Leaving a project whose drive does not answer: switching away keeps it open and dirty; Save As takes the new file only
// when written in time; the AI's save_project says the drive is not responding; a project with nothing to write closes at
// once; Quit waits quietly, then asks (the alert is answered by the check through ProjectQuit.askAboutDrive), never waits
// on the main thread, and asks once when it is asked twice.
@MainActor enum CloseQuitChecks {
    static func run(_ checks: Checks, root: URL) async {
        let project = makeProject("Leaving", in: root)
        await switchingAway(checks, project)
        await saveAs(checks, project, root: root)
        await aiSaveProject(checks, project)
        closesAtOnce(checks, project)
        await quit(checks, project)
        project.fileWriter.perform = ProjectFileWriter.write
        _ = OpenProjects.shared.close(project)
    }

    /// New Project while the drive holds the write: the project stays as it was (open, dirty, same file), nothing lost.
    private static func switchingAway(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "kept")
        let url = project.documentURL
        let state = project.state
        let meter = MainThreadGap()
        meter.start()
        await project.startNewProject()
        let gap = meter.stop()
        checks.require(project.documentURL == url && project.state == state && project.hasUnsavedChanges,
                       "switching away from a project whose drive does not answer keeps it open, unchanged and dirty")
        checks.require(gap < 0.5, "the main thread is free while switching waits for the drive: longest gap \(gap) s")
        drive.open()
        _ = await until(5) { !project.fileWriter.isBusy }
        checks.require(!project.hasUnsavedChanges && fileHolds(url, "kept"), "the held write lands and the project is saved")
    }

    /// Save As takes the new file only when it was written in time; a late write never moves the project.
    private static func saveAs(_ checks: Checks, _ project: VideoEditProject, root: URL) async {
        let old = project.documentURL
        let late = root.appendingPathComponent("Late copy.skycut")
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "copied")
        let tooLate = await project.saveAs(late, deadline: 0.5)
        checks.require(!tooLate && project.documentURL == old, "Save As on a drive that does not answer keeps the old file")
        drive.open()
        _ = await until(5) { !project.fileWriter.isBusy }
        checks.require(project.documentURL == old, "a Save As that lands after its deadline does not move the project")
        project.fileWriter.perform = ProjectFileWriter.write
        let copy = root.appendingPathComponent("Copy.skycut")
        let saved = await project.saveAs(copy, deadline: 5)
        checks.require(saved && project.documentURL == copy && !project.hasUnsavedChanges && fileHolds(copy, "copied"),
                       "Save As in time takes the new file and marks the project saved")
    }

    /// The AI's save_project on a drive that does not answer: refused with the notice, at the deadline.
    private static func aiSaveProject(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "asked by AI")
        var message = ""
        do {
            _ = try await AIProjectTools.saveProject(AIToolArguments([:]), project)
        } catch {
            message = (error as? AIToolError)?.message ?? error.localizedDescription
        }
        checks.require(message.contains("is not responding"), "save_project says the drive is not responding: \(message)")
        drive.open()
        _ = await until(5) { !project.fileWriter.isBusy }
    }

    /// Nothing to write, nothing being written: closing needs no wait (the window closes at once).
    private static func closesAtOnce(_ checks: Checks, _ project: VideoEditProject) {
        checks.require(!project.hasUnsavedChanges && project.closesAtOnce(), "a saved project closes at once")
        edit(project, "pending")
        checks.require(!project.closesAtOnce(), "a project with unsaved edits is written before it closes")
    }

    private static func quit(_ checks: Checks, _ project: VideoEditProject) async {
        // A slow but working drive within the quiet wait: no question, written, the main thread free.
        ProjectQuit.grace = 3
        var asked = 0
        ProjectQuit.askAboutDrive = { _ in asked += 1; return .stay }
        let slow = FakeDrive()
        project.fileWriter.perform = slow.perform
        let meter = MainThreadGap()
        meter.start()
        let opener = Task { try? await Task.sleep(nanoseconds: 600_000_000); slow.open() }
        let slowQuit = await ProjectQuit.prepareAll()
        let gap = meter.stop()
        _ = await opener.value
        checks.require(slowQuit && asked == 0 && !project.hasUnsavedChanges && fileHolds(project.documentURL, "pending"),
                       "Quit waits quietly for a slow drive and quits once the project is written (asked \(asked))")
        checks.require(gap < 0.5, "the main thread is free while Quit waits for the drive: longest gap \(gap) s")

        // A drive that does not answer: asked once; "Don't Quit" keeps SkyCut open with the project dirty.
        ProjectQuit.grace = 0.3
        let stuck = FakeDrive()
        project.fileWriter.perform = stuck.perform
        edit(project, "stuck")
        async let first = ProjectQuit.prepareAll()
        async let second = ProjectQuit.prepareAll()
        let answers = await (first, second)
        checks.require(!answers.0 && !answers.1 && asked == 1 && project.hasUnsavedChanges,
                       "Quit asks once about a stuck drive (asked \(asked)); Don't Quit stays with the project dirty")
        stuck.open()
        _ = await until(5) { !project.fileWriter.isBusy }

        // "Quit Anyway" quits; and an alert still up when the write ends lets the quit go on by itself.
        let again = FakeDrive()
        project.fileWriter.perform = again.perform
        edit(project, "anyway")
        ProjectQuit.askAboutDrive = { _ in .quitAnyway }
        checks.require(await ProjectQuit.prepareAll(), "Quit Anyway quits although the drive does not answer")
        ProjectQuit.askAboutDrive = { project in
            again.open()
            _ = await project.fileWriter.waitUntilIdle(deadline: 5)
            return .written
        }
        let waited = await ProjectQuit.prepareAll()
        checks.require(waited && !project.hasUnsavedChanges && fileHolds(project.documentURL, "anyway"),
                       "when the write ends while Quit asks, the project is saved and Quit goes on")
        ProjectQuit.askAboutDrive = { ProjectQuit.waitForDrive($0) }
    }
}

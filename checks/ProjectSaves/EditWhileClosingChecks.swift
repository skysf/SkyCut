import Foundation
@testable import SrtFlow

// Closing while the project still changes (docs/bugfixes/2026-11-19-close-trusts-a-stale-save.md): an edit made while New
// Project, closing a project or Quit is writing the file is written too before the project goes away; Quit looks again at a
// project it let through when that project changed while another one was asked about; and a save window answered after
// another document replaced the untitled one it was opened for writes nothing and moves nothing. The drive holds each first
// write until the check has edited, so "ready after the write it asked for" shows up as an edit missing from the file.
@MainActor enum EditWhileClosingChecks {
    static func run(_ checks: Checks, root: URL) async {
        // The check holds the drive while it edits: give the closes a deadline a slow runner can't reach.
        let deadline = ProjectFileWriter.deadline
        ProjectFileWriter.deadline = 5
        await newProject(checks, root: root)
        await closeProject(checks, root: root)
        await quit(checks, root: root)
        await quitLooksAgain(checks, root: root)
        await staleSaveWindow(checks, root: root)
        ProjectFileWriter.deadline = deadline
    }

    /// New Project: the person types while the write New asked for is held; that edit is written before the project goes.
    private static func newProject(_ checks: Checks, root: URL) async {
        let project = makeProject("New while typing", in: root)
        let url = project.documentURL
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "before New")
        let switching = Task { await project.startNewProject() }
        checks.require(await until(3) { drive.writes == 1 }, "New Project writes the project first")
        edit(project, "typed during New")
        drive.open()
        await switching.value
        checks.require(fileHolds(url, "typed during New"),
                       "New Project never throws away an edit made while it was writing the project (the file lacks it)")
        checks.require(project.documentURL == nil, "once everything is written, New Project goes ahead")
        project.fileWriter.perform = ProjectFileWriter.write
        _ = OpenProjects.shared.close(project)
    }

    /// Closing a project (the AI's close_project; the window's close button asks the same prepareToClose).
    private static func closeProject(_ checks: Checks, root: URL) async {
        let project = makeProject("Closed while typing", in: root)
        let url = project.documentURL
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "before closing")
        let closing = Task { await OpenProjects.shared.closeProject(project) }
        checks.require(await until(3) { drive.writes == 1 }, "closing writes the project first")
        edit(project, "typed while closing")
        drive.open()
        let closed = await closing.value
        checks.require(closed && fileHolds(url, "typed while closing"),
                       "closing a project never throws away an edit made while it was being written (closed \(closed))")
        if !closed {
            project.fileWriter.perform = ProjectFileWriter.write
            _ = OpenProjects.shared.close(project)
        }
    }

    /// Quit: an edit made while Quit writes the project is written before the reply.
    private static func quit(_ checks: Checks, root: URL) async {
        let project = makeProject("Quit while typing", in: root)
        let url = project.documentURL
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        let grace = ProjectQuit.grace
        ProjectQuit.grace = 5
        var asked = 0
        ProjectQuit.askAboutDrive = { _ in asked += 1; return .stay }
        edit(project, "before Quit")
        let quitting = Task { await ProjectQuit.prepareAll() }
        checks.require(await until(3) { drive.writes == 1 }, "Quit writes the project first")
        edit(project, "typed while quitting")
        drive.open()
        let quits = await quitting.value
        checks.require(quits && asked == 0 && fileHolds(url, "typed while quitting"),
                       "Quit writes an edit made while it was writing the project before it says yes (quits \(quits), asked \(asked))")
        ProjectQuit.grace = grace
        ProjectQuit.askAboutDrive = { ProjectQuit.waitForDrive($0) }
        project.fileWriter.perform = ProjectFileWriter.write
        _ = OpenProjects.shared.close(project)
    }

    /// Quit with two projects: the first is let through; while the second's drive is asked about, the first is edited (an
    /// AI tool call while the alert is up). Quit writes the first again before it says yes.
    private static func quitLooksAgain(_ checks: Checks, root: URL) async {
        let first = makeProject("Quit first", in: root)
        let second = makeProject("Quit second", in: root)
        let stuck = FakeDrive()
        second.fileWriter.perform = stuck.perform
        edit(first, "first before Quit")
        edit(second, "second before Quit")
        let grace = ProjectQuit.grace
        ProjectQuit.grace = 0.3
        var asked = 0
        ProjectQuit.askAboutDrive = { project in
            asked += 1
            edit(first, "first edited while asked")
            stuck.open()
            _ = await project.fileWriter.waitUntilIdle(deadline: 5)
            return .written
        }
        let quits = await ProjectQuit.prepareAll()
        checks.require(quits && asked == 1 && fileHolds(second.documentURL, "second before Quit"),
                       "Quit waits for the second project's drive (quits \(quits), asked \(asked))")
        checks.require(fileHolds(first.documentURL, "first edited while asked"),
                       "a project Quit let through and that changed while another one was asked about is written again before Quit says yes")
        ProjectQuit.grace = grace
        ProjectQuit.askAboutDrive = { ProjectQuit.waitForDrive($0) }
        second.fileWriter.perform = ProjectFileWriter.write
        _ = OpenProjects.shared.close(first)
        _ = OpenProjects.shared.close(second)
    }

    /// New Project on an untitled project asks Save…; while its save window is open, another project is opened in the same
    /// place and the untitled one discarded. The save window's late answer must not write the project opened meanwhile to
    /// the place chosen for the untitled one, nor move it there.
    private static func staleSaveWindow(_ checks: Checks, root: URL) async {
        let other = makeProject("Opened meanwhile", in: root)
        guard let otherURL = other.documentURL else { return checks.require(false, "the other project has a file") }
        edit(other, "the other project")
        _ = OpenProjects.shared.close(other)

        let project = makeProject("Untitled to be", in: root)
        await project.startNewProject()   // saved and clean: replaced at once by an untitled, empty document
        edit(project, "never saved")
        checks.require(project.isUntitled && !project.state.isEmpty, "an untitled project with an edit")

        let untitledDefault = ProjectCloseQuestions.untitled
        let saveLocationDefault = ProjectCloseQuestions.saveLocation
        var untitledAnswers: [ProjectCloseQuestions.UntitledChoice] = [.save, .discard]
        ProjectCloseQuestions.untitled = { _ in untitledAnswers.isEmpty ? .cancel : untitledAnswers.removeFirst() }
        var saveWindow: CheckedContinuation<SaveLocation?, Never>?
        ProjectCloseQuestions.saveLocation = { _ in await withCheckedContinuation { saveWindow = $0 } }

        let switching = Task { await project.startNewProject() }   // "Save…": the save window stays open
        checks.require(await until(3) { saveWindow != nil }, "New Project asks where to save the untitled project")
        await project.openProject(at: otherURL)                    // meanwhile Open Recent, and "Discard"
        let chosen = root.appendingPathComponent("Chosen for the untitled one.skycut")
        saveWindow?.resume(returning: SaveLocation(url: chosen, mayReplace: false))
        await switching.value

        checks.require(!FileManager.default.fileExists(atPath: chosen.path),
                       "a save window answered after another project replaced the untitled one writes nothing at the place chosen for it")
        checks.require(project.documentURL == otherURL && fileHolds(otherURL, "the other project") && !fileHolds(otherURL, "never saved"),
                       "the project opened meanwhile keeps its own file (now \(project.documentURL?.lastPathComponent ?? "untitled"))")
        ProjectCloseQuestions.untitled = untitledDefault
        ProjectCloseQuestions.saveLocation = saveLocationDefault
        _ = OpenProjects.shared.close(project)
    }
}

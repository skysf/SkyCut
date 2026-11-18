import Foundation
@testable import SrtFlow

// Writing one project's file: the autosave off the main thread, ⌘S / flush answering at the deadline and landing later,
// an edit made during a write keeping the project dirty, saves while the drive is stuck becoming one write, a failing
// drive said and refused, a project file moved in Finder followed.
@MainActor enum SaveChecks {
    static func run(_ checks: Checks, root: URL) async {
        let project = makeProject("Saves", in: root)
        await autosave(checks, project)
        await flushAtDeadline(checks, project)
        await editDuringWrite(checks, project)
        await coalescing(checks, project)
        await failingDrive(checks, project)
        await movedFile(checks, project, root: root)
        _ = OpenProjects.shared.close(project)
    }

    /// The 2 s autosave writes off the main thread; the project is not marked saved while the write is out.
    private static func autosave(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "autosaved")
        let meter = MainThreadGap()
        meter.start()
        let started = await until(6) { drive.writes == 1 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // the drive holds the write for a second
        let gap = meter.stop()
        checks.require(started, "the autosave reaches the drive 2 s after the edit")
        checks.require(gap < 0.5, "the main thread is free while the autosave waits on the drive: longest gap \(gap) s")
        checks.require(project.hasUnsavedChanges, "the project is not marked saved while its write is still out")
        drive.open()
        let landed = await until(5) { !project.fileWriter.isBusy && !project.hasUnsavedChanges }
        checks.require(landed && fileHolds(project.documentURL, "autosaved"), "when the write lands the project is saved, edit included")
    }

    /// ⌘S / flush on a drive that does not answer: "not responding" at the deadline, still dirty; a late write clears it.
    private static func flushAtDeadline(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "flushed")
        let meter = MainThreadGap()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let outcome = await project.flushToFile(deadline: 0.5)
        let waited = ProcessInfo.processInfo.systemUptime - asked
        let gap = meter.stop()
        checks.require(outcome == .notResponding && waited < 1.5,
                       "a flush answers \"not responding\" at the deadline, not when the drive wakes: \(outcome), \(waited) s")
        checks.require(gap < 0.5, "the main thread is free while the flush waits: longest gap \(gap) s")
        checks.require(project.hasUnsavedChanges && (project.notice ?? "").contains("is not responding"),
                       "the project stays dirty and says its drive is not responding: \(project.notice ?? "nil")")
        drive.open()
        let landed = await until(5) { !project.fileWriter.isBusy }
        checks.require(landed && !project.hasUnsavedChanges && project.notice == nil && fileHolds(project.documentURL, "flushed"),
                       "a write that lands late still marks the project saved and clears the notice")
    }

    /// An edit made while the file is being written keeps the project dirty, and the next write carries it.
    private static func editDuringWrite(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "before")
        let first = Task { await project.saveToFile(deadline: 5) }
        _ = await until(3) { drive.writes == 1 }
        edit(project, "during")
        drive.open()
        _ = await first.value
        checks.require(project.hasUnsavedChanges, "an edit made during a write keeps the project dirty after that write lands")
        let next = await project.flushToFile(deadline: 5)
        checks.require(next == .saved && !project.hasUnsavedChanges && fileHolds(project.documentURL, "during"),
                       "the next write carries the edit and marks the project saved")
    }

    /// Saves asked while the drive holds one write become one more write, of the newest state.
    private static func coalescing(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive()
        project.fileWriter.perform = drive.perform
        edit(project, "one")
        let first = Task { await project.saveToFile(deadline: 5) }
        _ = await until(3) { drive.writes == 1 }
        var later: [Task<ProjectSaveOutcome, Never>] = []
        for marker in ["two", "three", "four"] {
            edit(project, marker)
            later.append(Task { await project.saveToFile(deadline: 5) })
        }
        project.fileWriter.cancelAutosave()
        try? await Task.sleep(nanoseconds: 100_000_000)
        drive.open()
        _ = await first.value
        var outcomes: [ProjectSaveOutcome] = []
        for task in later { outcomes.append(await task.value) }
        checks.require(drive.writes == 2, "three saves while the drive holds one become one more write (\(drive.writes) writes)")
        checks.require(outcomes.allSatisfy { $0 == .saved } && fileHolds(project.documentURL, "four") && !project.hasUnsavedChanges,
                       "the write that follows carries the newest state, and everyone waiting hears it was saved")
    }

    /// A drive that refuses: said, dirty, and the project is not closed.
    private static func failingDrive(_ checks: Checks, _ project: VideoEditProject) async {
        let drive = FakeDrive(failing: "No space left on device", opened: true)
        project.fileWriter.perform = drive.perform
        edit(project, "refused")
        let outcome = await project.flushToFile(deadline: 2)
        checks.require(outcome == .failed && project.hasUnsavedChanges
                       && (project.notice ?? "").contains("No space left on device"),
                       "a failed write is said and the project stays dirty: \(project.notice ?? "nil")")
        let closing = await project.prepareToClose(deadline: 2)
        checks.require(closing == .refused, "a project whose file can't be written is not closed (\(closing))")
        project.fileWriter.perform = ProjectFileWriter.write
        checks.require(await project.flushToFile(deadline: 5) == .saved, "the next write on a good drive saves it")
    }

    /// The project file moved in Finder while open: the save follows it, no new file appears at the old place.
    private static func movedFile(_ checks: Checks, _ project: VideoEditProject, root: URL) async {
        guard let old = project.documentURL else { return checks.require(false, "the project has a file") }
        let moved = root.appendingPathComponent("Moved", isDirectory: true).appendingPathComponent(old.lastPathComponent)
        try? FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try FileManager.default.moveItem(at: old, to: moved) } catch { return checks.require(false, "move the project: \(error)") }
        edit(project, "moved")
        let outcome = await project.flushToFile(deadline: 5)
        checks.require(outcome == .saved && project.documentURL?.standardizedFileURL.path == moved.standardizedFileURL.path
                       && !FileManager.default.fileExists(atPath: old.path) && fileHolds(moved, "moved"),
                       "a project file moved in Finder is followed (written at \(project.documentURL?.path ?? "nil"))")
    }
}

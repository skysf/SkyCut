import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The AI's export_video folder (AIExportDestination): made, checked and listed off the main thread with the export
// panel's deadline, refused with the export panel's sentences before any job starts
// (docs/bugfixes/2026-11-19-ai-export-folder-checked-on-main-thread.md). Real folders for making a missing folder, taken
// names and a folder without permission; a fake drive that never answers or is read-only for the rest, driven through
// export_video itself.
@MainActor enum AIExportFolderChecks {
    static func run(root: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        await realFolders(root: root, project: project, require: require)
        await stuckAndReadOnly(project: project, require: require)
        await subtitleFiles(root: root, state: project.state, require: require)
        errorMapping(require: require)
    }

    private static func realFolders(root: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let folder = root.appendingPathComponent("ai-exports/deeper", isDirectory: true)
        let wanted = folder.appendingPathComponent("cut.mp4")
        let made = try? await AIExportDestination.output(
            AIToolArguments(["path": .string(wanted.path)]), project: project, fileExtension: "mp4", reserved: []
        )
        var isFolder: ObjCBool = false
        require(made?.path == wanted.path && FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder)
                && isFolder.boolValue, "a missing export folder is made, with its parents: \(made?.path ?? "nil")")
        FileManager.default.createFile(atPath: wanted.path, contents: Data())
        let reserved = folder.appendingPathComponent("cut 2.mp4").standardizedFileURL.path
        let numbered = try? await AIExportDestination.output(
            AIToolArguments(["path": .string(wanted.path)]), project: project, fileExtension: "mp4", reserved: [reserved]
        )
        require(numbered?.lastPathComponent == "cut 3.mp4",
                "a name in the folder or reserved by a queued export gets a number: \(numbered?.lastPathComponent ?? "nil")")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".SrtFlow-") }
        require(leftovers.isEmpty, "the write test leaves nothing in the export folder: \(leftovers)")

        // No path: <the project's home>/SkyCut/Exports, made off the main thread too.
        let named = try? await AIExportDestination.output(
            AIToolArguments(["name": "Teaser"]), project: project, fileExtension: "mp4", reserved: []
        )
        let exports = AIWorkspace.shared.outputFolder(.exports, project: project)
        require(named?.path == exports.appendingPathComponent("Teaser.mp4").path
                && FileManager.default.fileExists(atPath: exports.path),
                "without a path the default export folder is made: \(named?.path ?? "nil")")

        let locked = root.appendingPathComponent("ai-locked", isDirectory: true)
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o555)
        defer { chmod(locked.path, 0o755) }
        let refused = await message(AIToolArguments(["path": .string(locked.appendingPathComponent("cut.mp4").path)]), project)
        require(refused.contains("SkyCut can't write into “ai-locked”") && refused.contains("Nothing was exported."),
                "a folder SkyCut may not write into is refused with the panel's sentence before the export: \(refused)")
    }

    /// A drive that never answers and one that is read-only, through export_video: refused at once, main thread free, no job.
    private static func stuckAndReadOnly(project: VideoEditProject, require: (Bool, String) -> Void) async {
        var fake = ExportDestinationProbe.FileSystem.live
        fake.kind = { url in
            if url.path.hasPrefix("/Volumes/Stuck") { Thread.sleep(forTimeInterval: 8) }
            return url.path.hasPrefix("/Volumes/") ? .folder : FileSystemKind.live(url)
        }
        fake.names = { _ in [] }
        fake.isReadOnlyVolume = { $0.path.hasPrefix("/Volumes/ReadOnly") }
        fake.writeTest = { $0.path.hasPrefix("/Volumes/ReadOnly") ? .readOnlyVolume : nil }
        fake.createFolder = { $0.path.hasPrefix("/Volumes/ReadOnly") ? .readOnlyVolume : nil }
        let probe = ExportDestinationProbe(fileSystem: fake)
        let jobsBefore = AIJobs.shared.running.count

        let meter = MainThreadGapMeter()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let stuck = await message(AIToolArguments(["path": "/Volumes/Stuck/Out/cut.mp4"]), project, probe: probe, deadline: 0.5)
        let waited = ProcessInfo.processInfo.systemUptime - asked
        let gap = meter.stop()
        require(stuck.contains("The drive with “Out” is not responding"),
                "export_video says a drive that does not answer is not responding: \(stuck)")
        require(waited < 2, "and says it at the deadline, not when the drive wakes: \(waited) s")
        require(gap < 0.5, "the main thread is free while export_video waits for the drive: longest gap \(gap) s")

        let readOnly = await message(AIToolArguments(["path": "/Volumes/ReadOnly/Out/cut.mp4"]), project, probe: probe, deadline: 5)
        require(readOnly.contains("can only read from (an NTFS drive, for example)"),
                "a read-only drive (NTFS) is said before anything is encoded: \(readOnly)")
        require(AIJobs.shared.running.count == jobsBefore && !VideoEditExporter.shared.isExporting,
                "a refused folder starts no export job")
    }

    /// export_subtitles: its folder is made, checked and listed, and the files written, off the main thread; a drive that
    /// does not answer or is read-only is said with the same sentences.
    private static func subtitleFiles(root: URL, state: TimelineState, require: (Bool, String) -> Void) async {
        guard let project = OpenProjects.shared.newProject(
            savingAs: root.appendingPathComponent("subtitle-files.skycut"), placement: .background
        ) else { return require(false, "a background project for export_subtitles") }
        defer { _ = OpenProjects.shared.close(project) }
        var subtitled = state
        var document = SubtitleDocumentModel(format: .srt)
        document.cues = [SubtitleCue(index: 1, start: 0, end: 1, text: "Thanks for watching")]
        subtitled.subtitle = document
        project.restoreTimeline(subtitled)

        let folder = root.appendingPathComponent("ai-subtitles/new", isDirectory: true)
        let args = AIToolArguments(["folder": .string(folder.path), "name": "Talk", "track": "original"])
        let first = try? await AISubtitleFileExport.export(args, project)
        let second = try? await AISubtitleFileExport.export(args, project)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        require(first != nil && second != nil && names == ["Talk 2.en.srt", "Talk.en.srt"],
                "export_subtitles makes a missing folder and numbers a taken name: \(names)")

        var fake = ExportDestinationProbe.FileSystem.live
        fake.kind = { url in
            if url.path.hasPrefix("/Volumes/Stuck") { Thread.sleep(forTimeInterval: 8) }
            return url.path.hasPrefix("/Volumes/") ? .folder : FileSystemKind.live(url)
        }
        fake.names = { _ in [] }
        fake.isReadOnlyVolume = { $0.path.hasPrefix("/Volumes/ReadOnly") }
        let probe = ExportDestinationProbe(fileSystem: fake)
        let meter = MainThreadGapMeter()
        meter.start()
        let stuck = await subtitleMessage(AIToolArguments(["folder": "/Volumes/Stuck/Subs"]), project, probe: probe, deadline: 0.5)
        let gap = meter.stop()
        require(stuck.contains("The drive with “Subs” is not responding"), "export_subtitles says a stuck drive is not responding: \(stuck)")
        require(gap < 0.5, "the main thread is free while export_subtitles waits for the drive: longest gap \(gap) s")
        let readOnly = await subtitleMessage(AIToolArguments(["folder": "/Volumes/ReadOnly/Subs"]), project, probe: probe, deadline: 5)
        require(readOnly.contains("can only read from (an NTFS drive, for example)"), "export_subtitles says a read-only drive: \(readOnly)")
    }

    private static func subtitleMessage(
        _ args: AIToolArguments, _ project: VideoEditProject, probe: ExportDestinationProbe, deadline: TimeInterval
    ) async -> String {
        do {
            _ = try await AISubtitleFileExport.export(args, project, destination: probe, deadline: deadline)
            return ""
        } catch {
            return (error as? AIToolError)?.message ?? error.localizedDescription
        }
    }

    /// Making a folder on a read-only drive is said as a read-only drive, not as a permission problem.
    private static func errorMapping(require: (Bool, String) -> Void) {
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                               userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        require(ExportDestinationProbe.problem(creating: readOnly) == .readOnlyVolume, "EROFS while making the folder is a read-only drive")
        require(ExportDestinationProbe.problem(creating: denied) == .notWritable(String(cString: strerror(EACCES))),
                "a permission error while making the folder carries the system's reason")
    }

    /// The error export_video threw, or "" when it did not throw.
    private static func message(
        _ args: AIToolArguments, _ project: VideoEditProject,
        probe: ExportDestinationProbe = .shared, deadline: TimeInterval = AIExportDestination.deadline
    ) async -> String {
        do {
            _ = try await AIExportTools.export(args, project, destination: probe, deadline: deadline)
            return ""
        } catch {
            return (error as? AIToolError)?.message ?? error.localizedDescription
        }
    }
}

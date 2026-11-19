import Foundation
import SrtFlowCore

// MARK: - compress_videos / burn_subtitles / convert_subtitles' output folder, decided and checked off the main thread
//
// What it does: the folder these three tools put their files into — `folder` when given (resolved like every AI path,
// AIPathResolution), otherwise `<start>/SkyCut/Exports` (AIWorkspace.outputFolder) — made when missing, checked like the
// export panel's destination (a folder, not on a read-only drive, a hidden test file can be written) and listed, so the queue
// names each file past what is there (EncodeQueue.add(_:in:settings:burnIn:taken:); convert_subtitles' names too). It is the
// only place the three tools read `folder` (scripts/check-mcp.sh). Everything that touches the drive runs through
// ExportDestinationProbe, as export_video's folder does (AIExportDestination): off the main thread, with the 15 s deadline for
// a check that writes, at most three checks left waiting on one drive. A folder that can't be used is refused with the export
// panel's sentence (in English) before anything is queued or written.
// What it doesn't: naming the files (EncodeOutputFolder.target) or writing them (EncodeJob; convert_subtitles' files and the
// files the tools name: AIEncodeInputs, also off the main thread through the probe).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md): these tools made the folder and the queue asked
// `fileExists` for each candidate name on the main thread, the class of the export panel's freeze on a sleeping or stuck
// drive (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md).
@MainActor
enum AIEncodeFolder {
    /// The folder, ready, and its names (folded the way the default macOS volumes compare them).
    struct Ready: Sendable {
        var folder: URL
        var taken: Set<String>
    }

    /// `refusing`: what the refusal of an unusable folder ends with ("Nothing was queued.").
    static func prepare(
        _ args: AIToolArguments, project: VideoEditProject, refusing nothing: String,
        probe: ExportDestinationProbe = .shared, deadline: TimeInterval = AIExportDestination.deadline
    ) async throws -> Ready {
        let request = try Request(args, project: project)
        let near = request.folder(exists: { _ in false }, isFolder: { _ in false })
        let timedOut = Found(folder: near, report: ExportDestinationReport(problem: .noResponse))
        let found = await probe.run(on: near, deadline: deadline, timedOut: timedOut) { fileSystem in
            let folder = request.folder(exists: { fileSystem.kind($0) != .missing }, isFolder: { fileSystem.kind($0) == .folder })
            return Found(folder: folder, report: AIExportDestination.prepareFolder(folder, fileSystem: fileSystem))
        }
        if let problem = found.report.problem {
            let sentence = ExportDestinationText.message(problem, folder: found.folder, L10n: { $0 })
            throw AIToolError("\(sentence) Folder: \(AIWorkspace.shared.display(found.folder)). \(nothing)")
        }
        return Ready(folder: found.folder, taken: found.report.names)
    }

    private struct Found: Sendable {
        var folder: URL
        var report: ExportDestinationReport
    }

    /// The tools' arguments about the folder, read on the main thread without touching a drive.
    private struct Request: Sendable {
        /// `folder` as given, and the folders a relative one is tried against (AIWorkspace.resolutionFolders).
        var path: String?
        var preferred: URL?
        var fallback: URL?
        /// No `folder`: the start folder (named folder → the project's home → Downloads).
        var start: URL

        @MainActor init(_ args: AIToolArguments, project: VideoEditProject) throws {
            path = try args.string("folder")
            (preferred, fallback) = AIWorkspace.shared.resolutionFolders()
            start = AIWorkspace.shared.startFolder(project: project)
        }

        /// The folder, asking the drive through `exists` / `isFolder` (off the main thread inside the probe; the answers
        /// "no" when only the drive to ask is wanted).
        func folder(exists: (URL) -> Bool, isFolder: (URL) -> Bool) -> URL {
            if let path { return AIPathResolution.resolve(path, preferred: preferred, fallback: fallback, exists: exists) }
            return AIWorkspace.outputFolder(.exports, in: start, isFolder: isFolder)
        }
    }
}

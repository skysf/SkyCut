import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - Where export_video writes, decided and checked off the main thread
//
// What it does: the file the AI's export_video writes — `path` when given (resolved like every AI path, AIPathResolution),
// otherwise `<start>/SkyCut/Exports/<name>` (AIWorkspace.outputFolder) — and its folder made ready: created when missing,
// checked like the export panel's destination (a folder, not on a read-only drive, a hidden test file can be written) and
// listed, so a taken name gets a number (never overwrite, docs/architecture/ai-control-mcp.md section 4 item 6). Everything
// that touches the drive runs through ExportDestinationProbe: off the main thread, with the export panel's deadline for a
// check that writes, at most three checks left waiting on one drive. A folder that can't be used is refused with the
// export panel's sentence (in English) before a job is started.
// What it doesn't: the export itself (AIExportTools, VideoEditExporter); the export panel's folder (ExportDestinationState).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-ai-export-folder-checked-on-main-thread.md): export_video created the folder
// and asked `fileExists` for each candidate name on the main thread — the same freeze as the export panel's
// (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md) — and a read-only or unwritable folder was only found
// out when the finished video was delivered, after the whole encode. Rules: docs/architecture/export-settings.md §8.

@MainActor
enum AIExportDestination {
    /// Making the folder and writing a test file into it: the export panel's deadline for a check that writes (an asleep
    /// hard drive can take this long to spin up, ExportDestinationState).
    static let deadline: TimeInterval = 15

    /// The file export_video writes: its folder is there and writable, and the name is free (not in the folder, not
    /// `reserved` by an export still queued). Throws the export panel's sentence when the folder can't be used.
    static func output(
        _ args: AIToolArguments, project: VideoEditProject, fileExtension: String, reserved: Set<String>,
        probe: ExportDestinationProbe = .shared, deadline: TimeInterval = deadline
    ) async throws -> URL {
        let request = try Request(args, project: project, fileExtension: fileExtension)
        let timedOut = Found(file: request.withoutAsking, report: ExportDestinationReport(problem: .noResponse))
        let found = await probe.run(on: request.near, deadline: deadline, timedOut: timedOut) { request.prepare($0) }
        let folder = found.file.deletingLastPathComponent()
        if let problem = found.report.problem { throw refusal(problem, folder: folder) }
        return ExportFileName.unoccupied(
            in: folder, stem: found.file.deletingPathExtension().lastPathComponent, pathExtension: found.file.pathExtension
        ) { found.report.contains($0.lastPathComponent) || reserved.contains($0.standardizedFileURL.path) }
    }

    /// export_video's and export_subtitles' folder: made when it is missing, then the export panel's look-and-write check.
    /// Runs off the main thread (inside `ExportDestinationProbe.run`).
    nonisolated static func prepareFolder(
        _ folder: URL, fileSystem: ExportDestinationProbe.FileSystem
    ) -> ExportDestinationReport {
        switch fileSystem.kind(folder) {
        case .file:
            return ExportDestinationReport(problem: .notAFolder)
        case .missing:
            if let problem = fileSystem.createFolder(folder) { return ExportDestinationReport(problem: problem) }
        case .folder:
            break
        }
        return ExportDestinationProbe.check(folder, writeTest: true, fileSystem: fileSystem)
    }

    /// The export panel's sentence for a folder that can't be used, in English, and where it is.
    static func refusal(_ problem: ExportDestinationProblem, folder: URL) -> AIToolError {
        let sentence = ExportDestinationText.message(problem, folder: folder, L10n: { $0 })
        return AIToolError("\(sentence) Folder: \(AIWorkspace.shared.display(folder)). Nothing was exported.")
    }

    /// What the drive said: the file asked for (before a taken name gets its number) and the check of its folder.
    struct Found: Sendable {
        var file: URL
        var report: ExportDestinationReport
    }

    /// Everything export_video's arguments say about the file, read on the main thread without touching a drive.
    struct Request: Sendable {
        /// `path` as given, and the folders a relative one is tried against (AIWorkspace.resolutionFolders).
        var path: String?
        var preferred: URL?
        var fallback: URL?
        /// No `path`: the start folder (named folder → the project's home → Downloads) and the file name's stem.
        var start: URL
        var stem: String
        var fileExtension: String

        @MainActor init(_ args: AIToolArguments, project: VideoEditProject, fileExtension: String) throws {
            self.fileExtension = fileExtension
            path = try args.string("path")
            (preferred, fallback) = AIWorkspace.shared.resolutionFolders()
            start = AIWorkspace.shared.startFolder(project: project)
            let fallbackName = AIExportTools.defaultName(project)
            // 同一个文件夹出几个版本：成片的名字带上版本（「南极 - 30s」，方案板 5；工程名里已经带着就不再叠）。
            stem = AIVersionName.stem(ExportFileName.stem(
                from: try args.string("name") ?? fallbackName, droppingExtension: fileExtension, fallback: fallbackName
            ), version: AIVersionName.clean(try args.string("version")))
        }

        /// The file, asking the drive where needed: which of two folders holds a relative `path`, whether the start
        /// folder still uses the old `SrtFlow` folder. Runs off the main thread.
        func requested(_ fileSystem: ExportDestinationProbe.FileSystem) -> URL {
            file(exists: { fileSystem.kind($0) != .missing }, isFolder: { fileSystem.kind($0) == .folder })
        }

        /// The same file without asking the drive: names the folder when the drive does not answer, picks the drive.
        var withoutAsking: URL { file(exists: { _ in false }, isFolder: { _ in false }) }

        /// A folder on the drive this is about (the per-drive cap), without asking the drive.
        var near: URL { withoutAsking.deletingLastPathComponent() }

        /// The file, and its folder made ready (`prepareFolder`). Runs off the main thread.
        func prepare(_ fileSystem: ExportDestinationProbe.FileSystem) -> Found {
            let file = requested(fileSystem)
            return Found(file: file, report: AIExportDestination.prepareFolder(file.deletingLastPathComponent(), fileSystem: fileSystem))
        }

        /// 给了完整路径就用它（扩展名按这次导出的类型改正）；否则 = 默认文件夹 + 名字（默认工程名）。
        private func file(exists: (URL) -> Bool, isFolder: (URL) -> Bool) -> URL {
            if let path {
                let url = AIPathResolution.resolve(path, preferred: preferred, fallback: fallback, exists: exists)
                return url.pathExtension.lowercased() == fileExtension
                    ? url : url.deletingPathExtension().appendingPathExtension(fileExtension)
            }
            return AIWorkspace.outputFolder(.exports, in: start, isFolder: isFolder)
                .appendingPathComponent(stem).appendingPathExtension(fileExtension)
        }
    }
}

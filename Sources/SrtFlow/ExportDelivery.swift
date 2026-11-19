import Foundation
import SrtFlowCore

// MARK: - Handing the finished video over to its destination, off the main thread
//
// What it does: the last step of a timeline export. ffmpeg writes into the export workspace (the internal temporary
// folder); this moves the finished file onto the destination (`ExportTarget`): replacing an existing file atomically when
// the user said Replace (docs/architecture/export-settings.md §5), otherwise never replacing anything — a name taken since
// the folder was listed moves the video on to the next free number (ExclusivePlacement). When the destination is another
// drive that is a full copy of a file that can be gigabytes, so it runs on its own queue and never on the main thread.
// What it doesn't: checking the destination before the export (ExportDestinationProbe); picking the name
// (AIExportDestination, the export panel); cleaning the workspace (VideoEditExporter).
//
// Why (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md): the move used to run inside the
// exporter's main-actor task — a 90-minute export copied onto a USB hard drive held the main thread for minutes.
// 2026-11-19 (docs/bugfixes/2026-11-19-parallel-ai-exports-pick-the-same-name.md): every delivery used to replace, so two
// exports that picked the same name, or a file Finder made after the listing, were silently overwritten.

/// Where an export's finished file goes.
enum ExportTarget: Equatable, Sendable {
    /// Replace whatever is at this file: the user said so (the export panel's "Replace").
    case replacing(URL)
    /// A new file, never replacing anything: name `number` of the `stem`, `stem 2`, `stem 3`… series in `folder`
    /// (ExportFileName.numbered), or the next one that is free at the moment of the move.
    case newFile(folder: URL, stem: String, pathExtension: String, number: Int)

    /// The file asked for (a new file may end up under a later number).
    var url: URL {
        switch self {
        case .replacing(let url): return url
        case .newFile(let folder, let stem, let pathExtension, let number):
            return ExportFileName.numbered(number, in: folder, stem: stem, pathExtension: pathExtension)
        }
    }
}

enum ExportDelivery {
    /// For the checks only: runs on the delivery queue right before the move (to slow it down and see where it runs).
    nonisolated(unsafe) static var beforeMoveForChecks: (@Sendable () -> Void)?

    /// Returns where the video went.
    static func deliver(_ finished: URL, to target: ExportTarget) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.addOperation {
                do {
                    beforeMoveForChecks?()
                    continuation.resume(returning: try move(finished, to: target))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One delivery at a time (the exporter does one export at a time); a plain queue, not Swift's cooperative pool,
    /// because the copy blocks its thread (docs/architecture/blocking-media-reads.md).
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SrtFlow.exportDelivery"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private static func move(_ finished: URL, to target: ExportTarget) throws -> URL {
        let files = FileManager.default
        guard files.fileExists(atPath: finished.path) else {
            throw VideoEditExportGraph.PlanError(message: L10n("ffmpeg finished but produced no output file."))
        }
        switch target {
        case .replacing(let output):
            if files.fileExists(atPath: output.path) {
                _ = try files.replaceItemAt(output, withItemAt: finished)
            } else {
                try files.moveItem(at: finished, to: output)
            }
            return output
        case .newFile(let folder, let stem, let pathExtension, let number):
            return try ExclusivePlacement.place(finished, in: folder, stem: stem, pathExtension: pathExtension, from: number)
        }
    }
}

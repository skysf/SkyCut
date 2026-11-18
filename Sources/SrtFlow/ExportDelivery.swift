import Foundation

// MARK: - Handing the finished video over to its destination, off the main thread
//
// What it does: the last step of a timeline export. ffmpeg writes into the export workspace (the internal temporary
// folder); this moves the finished file onto the destination, replacing an existing file atomically
// (docs/architecture/export-settings.md §5). When the destination is another drive that is a full copy of a file
// that can be gigabytes, so it runs on its own queue and never on the main thread.
// What it doesn't: checking the destination before the export (ExportDestinationProbe); cleaning the workspace
// (VideoEditExporter).
//
// Why (2026-11-18, docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md): the move used to run inside the
// exporter's main-actor task — a 90-minute export copied onto a USB hard drive held the main thread for minutes.

enum ExportDelivery {
    /// For the checks only: runs on the delivery queue right before the move (to slow it down and see where it runs).
    nonisolated(unsafe) static var beforeMoveForChecks: (@Sendable () -> Void)?

    static func deliver(_ finished: URL, to output: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.addOperation {
                do {
                    beforeMoveForChecks?()
                    try move(finished, to: output)
                    continuation.resume()
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

    private static func move(_ finished: URL, to output: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: finished.path) else {
            throw VideoEditExportGraph.PlanError(message: L10n("ffmpeg finished but produced no output file."))
        }
        if files.fileExists(atPath: output.path) {
            _ = try files.replaceItemAt(output, withItemAt: finished)
        } else {
            try files.moveItem(at: finished, to: output)
        }
    }
}

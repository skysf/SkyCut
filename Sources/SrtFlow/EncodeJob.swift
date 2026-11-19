import Foundation
import SrtFlowCore

// MARK: - One Compress / Burn In encode: ffmpeg writes the job's own file, which gets its name only when it is finished
//
// What it does: runs ffmpeg for one queue item so that nothing but the job's own file is ever written or removed. The job
// first claims a hidden file of its own next to where the finished file goes (ExclusivePlacement.scratch: created empty with
// O_EXCL, so it was nobody's before); ffmpeg writes only that file, so its `-y` can only ever overwrite the job's own claim.
// When ffmpeg succeeds the file is handed over as `ExportTarget.newFile` (ExportDelivery → ExclusivePlacement.place): it never
// replaces anything, and a name taken since it was planned moves the file on to the next number of its series. When ffmpeg
// fails or the job is cancelled, only the job's own file is removed (ExclusivePlacement.discard: only while it is still the
// file the job created). The job touches the destination folder only off the main thread
// (docs/architecture/blocking-media-reads.md "Destination drives"). A cancel lands wherever the job is, also before ffmpeg
// starts; quitting SkyCut stops ffmpeg and removes the job's file (`stopAllForQuit`), because ffmpeg would otherwise go on
// writing a hidden file nobody will ever see.
// What it doesn't: picking and reserving the planned name (EncodeQueue, against the other items); the ffmpeg command
// (FFmpegArgumentBuilder); the burn-in workspace; the item's status and progress (EncodeQueue).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md): ffmpeg wrote straight onto the planned
// name with `-y`, so a second item with the same name, or a file that appeared there, was overwritten; and a failed or
// cancelled job removed whatever was at that name by then. Rules: docs/architecture/export-settings.md §5 item 8.

@MainActor
final class EncodeJob {
    enum Outcome {
        /// Where the finished file went (a later number than planned when the name was taken meanwhile).
        case finished(URL)
        case cancelled
        case failed(String)
    }

    /// The jobs whose ffmpeg may be running, for quitting.
    private static var running: [ObjectIdentifier: EncodeJob] = [:]

    /// Where the finished file goes (always a new file).
    let target: ExportTarget
    private var process: FFmpegProcess?
    private var scratch: ExclusivePlacement.Claim?
    private var isCancelled = false

    init(target: ExportTarget) {
        self.target = target
    }

    /// Stops the job wherever it is: a running ffmpeg is stopped, one not started yet never starts; the job's own file is
    /// removed when the run ends.
    func cancel() {
        isCancelled = true
        process?.cancel()
    }

    /// SkyCut is quitting: every running encode's ffmpeg is stopped and its own file removed now (the runs will not get
    /// to the end). Waits for a drive at most `deadline` per file: the main thread never waits on a drive without one.
    static func stopAllForQuit(deadline: TimeInterval = 2) {
        for job in running.values {
            job.cancel()
            guard let scratch = job.scratch else { continue }
            let removed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusivePlacement.discard(scratch)
                removed.signal()
            }
            _ = removed.wait(timeout: .now() + deadline)
        }
    }

    /// Encodes into the job's own file and hands it over. `command` makes the ffmpeg command for the output path it is
    /// given (the job's own file, never the planned name).
    func run(
        executable: URL, workingDirectory: URL?, progress: @escaping @MainActor (FFmpegProgress) -> Void,
        command: (String) -> FFmpegCommand
    ) async -> Outcome {
        guard case .newFile(let folder, let stem, let pathExtension, _) = target else {
            return .failed("An encode only ever writes a new file.")
        }
        Self.running[ObjectIdentifier(self)] = self
        defer { Self.running[ObjectIdentifier(self)] = nil }
        if isCancelled { return .cancelled }
        let claim: ExclusivePlacement.Claim
        do {
            claim = try await Self.offMain { try ExclusivePlacement.scratch(in: folder, stem: stem, pathExtension: pathExtension) }
        } catch {
            return isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
        scratch = claim
        let outcome = await encode(into: claim, executable: executable, workingDirectory: workingDirectory, progress: progress,
                                   command: command(claim.url.path))
        scratch = nil
        // Handed over = renamed onto its name; anything else leaves the job's own file to remove, and only that file.
        if case .finished = outcome { return outcome }
        try? await Self.offMain { ExclusivePlacement.discard(claim) }
        return outcome
    }

    private func encode(
        into claim: ExclusivePlacement.Claim, executable: URL, workingDirectory: URL?,
        progress: @escaping @MainActor (FFmpegProgress) -> Void, command: FFmpegCommand
    ) async -> Outcome {
        var command = command
        var lastError: Error?
        // 硬件解码偶尔会在某些奇怪的编码上失败，那就退回纯软解再试一次。
        for attempt in 0..<2 {
            if attempt == 1 {
                guard command.useHardwareDecode else { break }
                command.useHardwareDecode = false
            }
            if isCancelled { return .cancelled }
            let process = FFmpegProcess()
            self.process = process
            defer { self.process = nil }
            do {
                try await process.run(
                    executable: executable, arguments: FFmpegArgumentBuilder.arguments(for: command),
                    workingDirectory: workingDirectory, onProgress: progress
                )
                lastError = nil
                break
            } catch FFmpegProcessError.cancelled {
                return .cancelled
            } catch {
                lastError = error
            }
        }
        if isCancelled { return .cancelled }
        if let lastError { return .failed(lastError.localizedDescription) }
        do {
            return .finished(try await ExportDelivery.deliver(claim.url, to: target))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A call that touches the destination drive, on GCD: never the main thread, never Swift's cooperative pool (it blocks
    /// its thread while the drive answers; docs/architecture/blocking-media-reads.md).
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

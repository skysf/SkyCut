import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Compress / Burn In never overwrite or delete a file that is not the job's own
// (docs/bugfixes/2026-11-19-compress-burn-overwrite-and-delete.md), on real encodes of small made-up videos:
// - two queued inputs with one file name and an output folder get two names, and each reads back as its own encode;
//   choosing another output folder picks the waiting items' names again against each other;
// - a file that appears at a planned name after it was planned (Finder, another app) is never replaced: the encode moves on
//   to the next number, the list shows it, and compress_videos' get_job says so;
// - a job that fails or is cancelled leaves the file at its planned name alone and nothing of its own behind; quitting
//   SkyCut during an encode removes the job's own file at once (ffmpeg would otherwise finish a hidden file nobody sees).
@MainActor enum EncodeQueueChecks {
    static func run(root: URL, ffmpeg: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let inputs = root.appendingPathComponent("encode-inputs", isDirectory: true)
        let a = inputs.appendingPathComponent("a/clip.mp4"), b = inputs.appendingPathComponent("b/clip.mp4")
        let late = inputs.appendingPathComponent("late/late.mp4"), broken = inputs.appendingPathComponent("broken/broken.mp4")
        let long = inputs.appendingPathComponent("long/long.mp4")
        do {
            try await video(a, ffmpeg: ffmpeg, size: "320x180", seconds: 2)
            try await video(b, ffmpeg: ffmpeg, size: "480x270", seconds: 2)
            try await video(late, ffmpeg: ffmpeg, size: "320x180", seconds: 2)
            try await video(broken, ffmpeg: ffmpeg, size: "320x180", seconds: 2)
            try await video(long, ffmpeg: ffmpeg, size: "1280x720", seconds: 20)
        } catch {
            return require(false, "the encode checks' input videos are made: \(error.localizedDescription)")
        }
        await sameName([a, b], root: root, ffmpeg: ffmpeg, require: require)
        refreshedFolder([a, b], root: root, require: require)
        await lateFile(late, root: root, ffmpeg: ffmpeg, require: require)
        await failedJob(broken, root: root, require: require)
        await cancelledJob(long, root: root, require: require)
        await quitDuringEncode(long, root: root, require: require)
        await aiLateFile(a, root: root, project: project, require: require)
    }

    /// Two inputs with one file name from two folders, one output folder: two names, two encodes, each its own.
    private static func sameName(_ urls: [URL], root: URL, ffmpeg: URL, require: (Bool, String) -> Void) async {
        let folder = folder(root, "encode-same-name")
        let queue = quickQueue(folder)
        queue.add(urls: urls)
        let planned = queue.items.map(\.outputURL.lastPathComponent)
        require(planned == ["clip_compressed.mp4", "clip_compressed 2.mp4"],
                "two queued inputs with one file name get two output names: \(planned)")
        queue.start()
        require(await settled(queue), "both encodes end")
        for (item, width) in zip(queue.items, [320, 480]) {
            let read = try? await MediaProbe.probe(url: item.outputURL, ffmpeg: ffmpeg).get()
            require(item.status == .finished && read?.width == width,
                    "each encode reads back as its own video at its own name: \(item.outputURL.lastPathComponent) \(read?.width ?? 0)")
        }
        require(hidden(in: folder).isEmpty, "the finished encodes leave no file of their own behind: \(hidden(in: folder))")
    }

    /// Choosing an output folder after the files were queued next to their sources picks the names again, each against
    /// the others.
    private static func refreshedFolder(_ urls: [URL], root: URL, require: (Bool, String) -> Void) {
        let queue = EncodeQueue(outputSuffix: "_compressed")
        queue.add(urls: urls)
        queue.outputDirectory = folder(root, "encode-refreshed")
        queue.refreshOutputPaths()
        let names = queue.items.map(\.outputURL.lastPathComponent)
        require(names == ["clip_compressed.mp4", "clip_compressed 2.mp4"],
                "a new output folder gives the waiting items two names: \(names)")
        queue.removeAll()
    }

    /// A file that appears at the planned name before the encode is written is never replaced.
    private static func lateFile(_ url: URL, root: URL, ffmpeg: URL, require: (Bool, String) -> Void) async {
        let folder = folder(root, "encode-late")
        let queue = quickQueue(folder)
        queue.add(urls: [url])
        guard let planned = queue.items.first?.outputURL else { return require(false, "the late-file encode is queued") }
        write(made, to: planned)
        queue.start()
        require(await settled(queue), "the late-file encode ends")
        let item = queue.items.first
        let read = try? await MediaProbe.probe(url: item?.outputURL ?? planned, ffmpeg: ffmpeg).get()
        require(contents(planned) == made, "a file that appeared at the planned name is never replaced by the encode")
        require(item?.status == .finished && item?.outputURL.lastPathComponent == "late_compressed 2.mp4" && read?.width == 320,
                "the encode moves on to the next name and the list shows it: \(item?.outputURL.lastPathComponent ?? "nil")")
        require(hidden(in: folder).isEmpty, "and leaves no file of its own behind: \(hidden(in: folder))")
    }

    /// A job whose ffmpeg fails (its input became unreadable after it was probed) never deletes the file at its name.
    private static func failedJob(_ url: URL, root: URL, require: (Bool, String) -> Void) async {
        let folder = folder(root, "encode-failed")
        let queue = quickQueue(folder)
        queue.add(urls: [url])
        guard let planned = queue.items.first?.outputURL else { return require(false, "the failing encode is queued") }
        require(await waited { queue.items.first?.info != nil }, "the failing encode's input is probed")
        write("not a video any more", to: url)
        write(made, to: planned)
        queue.start()
        require(await settled(queue), "the failing encode ends")
        require(queue.items.first?.status == .failed, "the encode of an input that became unreadable fails")
        require(contents(planned) == made, "a failed job never deletes the file at its planned name")
        require(hidden(in: folder).isEmpty, "a failed job leaves no file of its own behind: \(hidden(in: folder))")
    }

    /// A job cancelled while ffmpeg is writing never touches the file at its name and removes its own file.
    private static func cancelledJob(_ url: URL, root: URL, require: (Bool, String) -> Void) async {
        let folder = folder(root, "encode-cancelled")
        let queue = EncodeQueue(outputSuffix: "_compressed")
        queue.settings.preset = .veryslow  // long enough to be cancelled while it runs
        queue.outputDirectory = folder
        queue.add(urls: [url])
        guard let item = queue.items.first else { return require(false, "the encode to cancel is queued") }
        write(made, to: item.outputURL)
        queue.start()
        require(await waited { queue.items.first?.status == .running }, "the encode to cancel starts")
        _ = await waited(seconds: 3) { (queue.items.first?.progress ?? 0) > 0 }
        queue.cancel(id: item.id)
        require(await settled(queue), "the cancelled encode ends")
        require(queue.items.first?.status == .cancelled, "the encode is cancelled, not finished")
        require(contents(item.outputURL) == made, "a cancelled job never overwrites or deletes the file at its planned name")
        require(hidden(in: folder).isEmpty, "a cancelled job leaves no file of its own behind: \(hidden(in: folder))")
    }

    /// Quitting while ffmpeg writes: the job's own file is gone when `stopAllForQuit` returns, and the job ends cancelled.
    private static func quitDuringEncode(_ url: URL, root: URL, require: (Bool, String) -> Void) async {
        let folder = folder(root, "encode-quit")
        let queue = EncodeQueue(outputSuffix: "_compressed")
        queue.settings.preset = .veryslow
        queue.outputDirectory = folder
        queue.add(urls: [url])
        queue.start()
        // ffmpeg has opened the job's file (it has written frames): quitting in the instant before that is not checked.
        require(await waited { queue.items.first?.status == .running && (queue.items.first?.progress ?? 0) > 0 },
                "the encode is writing its own file when SkyCut quits")
        require(!hidden(in: folder).isEmpty, "the encode writes a hidden file of its own, not the planned name")
        EncodeJob.stopAllForQuit()
        require(hidden(in: folder).isEmpty, "quitting removes the encode's own file at once: \(hidden(in: folder))")
        require(await settled(queue), "the encode stopped by quitting ends")
        require(queue.items.first?.status == .cancelled && contents(in: folder).isEmpty,
                "and nothing is left in the folder: \(contents(in: folder))")
    }

    /// compress_videos: a file that appears at the name the call answered is kept; get_job gives the real file and says why.
    private static func aiLateFile(_ url: URL, root: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let folder = root.appendingPathComponent("encode-ai", isDirectory: true)
        let args = AIToolArguments(["files": .array([.string(url.path)]), "folder": .string(folder.path)])
        guard let started = try? await AIEncodeTools.compress(args, project),
              let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id),
              let planned = started.payload["outputs"]?.arrayValue?.first?["output"]?.stringValue
        else { return require(false, "compress_videos starts") }
        // Before the queue's run loop gets the main actor: the name is taken before anything is written.
        write(made, to: URL(fileURLWithPath: planned))
        for _ in 0..<4 where job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
        let output = (try? await AIExportTools.job(AIToolArguments(["job_id": .string(id)])))?.payload["outputs"]?.arrayValue?.first
        require(job.status == .done && contents(URL(fileURLWithPath: planned)) == made,
                "compress_videos never replaces a file that appeared at the name it answered")
        require(output?["output"]?.stringValue == folder.appendingPathComponent("clip_compressed 2.mp4").path
                && output?["path_note"]?.stringValue?.contains("Nothing was replaced") == true,
                "get_job gives the file the encode moved on to and says so: \(output?["output"]?.stringValue ?? "nil")")
    }

    // MARK: - Helpers

    private static let made = "made by Finder after the name was planned"

    /// A queue that encodes fast into `folder` (its own, not the app's: nothing the user keeps is touched).
    private static func quickQueue(_ folder: URL) -> EncodeQueue {
        let queue = EncodeQueue(outputSuffix: "_compressed")
        queue.settings.preset = .veryfast
        queue.outputDirectory = folder
        return queue
    }

    private static func folder(_ root: URL, _ name: String) -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func video(_ url: URL, ffmpeg: URL, size: String, seconds: Int) async throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await ExportProfileRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=s=\(size):r=30",
            "-t", "\(seconds)", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", url.path
        ], directory: folder, log: folder.appendingPathComponent("make.log"))
    }

    /// Every item ended (finished, failed or cancelled) and the queue stopped.
    private static func settled(_ queue: EncodeQueue) async -> Bool {
        await waited(seconds: 60) { !queue.isRunning && !queue.items.isEmpty && queue.items.allSatisfy(\.isDone) }
    }

    private static func waited(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Hidden files in `folder`: an encode's own unfinished file would be one.
    private static func hidden(in folder: URL) -> [String] { contents(in: folder).filter { $0.hasPrefix(".") } }

    private static func contents(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private static func write(_ text: String, to url: URL) { try? Data(text.utf8).write(to: url) }
    private static func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
}

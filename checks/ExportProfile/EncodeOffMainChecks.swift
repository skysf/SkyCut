import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Compress / Burn In never wait on a drive on the main thread (docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md):
// - the page's queue names an item without the drive, then again once the folder's names are back off the main thread: a file
//   already in the output folder still moves the name on, and a drive that does not answer leaves the main thread free and
//   the name as it was (the encode never replaces anyway, EncodeQueueChecks);
// - compress_videos makes, checks and lists its folder off the main thread before anything is queued: a taken name in the
//   reply already has its number, a drive that does not answer or is read-only is refused with the export panel's sentence,
//   at the deadline, with the main thread free and nothing queued.
// checks/file-io-off-main-wiring.sh pins the wiring (no `fileExists` in the queue, the AI folder only through the probe).
@MainActor enum EncodeOffMainChecks {
    static func run(root: URL, input: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        await pageNamesAfterLook(root: root, input: input, require: require)
        await pageStuckDrive(input: input, require: require)
        await aiFolder(root: root, input: input, project: project, require: require)
        await aiStuckAndReadOnly(input: input, project: project, require: require)
    }

    /// A name already in the folder is passed once the look at the folder is back, for a new item and for a new output folder.
    private static func pageNamesAfterLook(root: URL, input: URL, require: (Bool, String) -> Void) async {
        let stem = input.deletingPathExtension().lastPathComponent
        let taken = folder(root, "encode-taken")
        FileManager.default.createFile(atPath: taken.appendingPathComponent("\(stem)_compressed.mp4").path, contents: Data())
        let queue = EncodeQueue(outputSuffix: "_compressed")
        queue.outputDirectory = taken
        queue.add(urls: [input])
        let renamed = await waited { queue.items.first?.outputURL.lastPathComponent == "\(stem)_compressed 2.mp4" }
        require(renamed, "a name already in the output folder is passed once the folder's names are back: "
                + (queue.items.first?.outputURL.lastPathComponent ?? "nil"))
        let other = folder(root, "encode-taken-refreshed")
        FileManager.default.createFile(atPath: other.appendingPathComponent("\(stem)_compressed.mp4").path, contents: Data())
        queue.outputDirectory = other
        queue.refreshOutputPaths()
        let again = await waited {
            queue.items.first?.outputURL.path == other.appendingPathComponent("\(stem)_compressed 2.mp4").path
        }
        require(again, "another output folder's taken name is passed too: \(queue.items.first?.outputURL.path ?? "nil")")
        queue.removeAll()
    }

    /// A drive that does not answer: adding is immediate, the main thread stays free, the name stays the one picked without it.
    private static func pageStuckDrive(input: URL, require: (Bool, String) -> Void) async {
        let queue = EncodeQueue(outputSuffix: "_compressed")
        queue.probe = ExportDestinationProbe(fileSystem: stuckDrive())
        queue.outputDirectory = URL(fileURLWithPath: "/Volumes/Stuck/Out", isDirectory: true)
        let meter = MainThreadGapMeter()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        queue.add(urls: [input])
        let added = ProcessInfo.processInfo.systemUptime - asked
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let gap = meter.stop()
        require(added < 0.2 && gap < 0.5, "adding into a folder on a drive that does not answer never waits on the main thread: "
                + "add \(added) s, longest gap \(gap) s")
        let name = queue.items.first?.outputURL.lastPathComponent
        require(name == input.deletingPathExtension().lastPathComponent + "_compressed.mp4",
                "the name stays the one picked without the drive: \(name ?? "nil")")
        queue.removeAll()
    }

    /// compress_videos into a folder that already has the first name: the reply's file has the next number.
    private static func aiFolder(root: URL, input: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let stem = input.deletingPathExtension().lastPathComponent
        let folder = folder(root, "encode-ai-taken")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("\(stem)_compressed.mp4").path, contents: Data())
        let args = AIToolArguments(["files": .array([.string(input.path)]), "folder": .string(folder.path)])
        let started = try? await AIEncodeTools.compress(args, project)
        let output = started?.payload["outputs"]?.arrayValue?.first?["output"]?.stringValue
        require(output == folder.appendingPathComponent("\(stem)_compressed 2.mp4").path,
                "compress_videos names its file past what its folder already has before it answers: \(output ?? "nil")")
        EncodeQueue.compress.cancelAll()
        _ = await waited(seconds: 30) { !EncodeQueue.compress.isRunning && EncodeQueue.compress.items.allSatisfy(\.isDone) }
        EncodeQueue.compress.clearFinished()
        _ = await waited(seconds: 5) { AIJobs.shared.running.allSatisfy { $0.kind != .compress } }
    }

    /// compress_videos into a folder on a drive that does not answer, and on a read-only one: refused before anything is queued.
    private static func aiStuckAndReadOnly(input: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let probe = ExportDestinationProbe(fileSystem: stuckDrive())
        let queued = EncodeQueue.compress.items.count, jobs = Set(AIJobs.shared.running.map(\.id))
        let meter = MainThreadGapMeter()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let stuck = await refusal(AIToolArguments(["files": .array([.string(input.path)]), "folder": "/Volumes/Stuck/Out"]),
                                  project, probe: probe, deadline: 0.5)
        let waited = ProcessInfo.processInfo.systemUptime - asked
        let gap = meter.stop()
        require(stuck.contains("The drive with “Out” is not responding") && stuck.contains("Nothing was queued."),
                "compress_videos says a drive that does not answer is not responding: \(stuck)")
        require(waited < 2 && gap < 0.5, "at the deadline, with the main thread free: \(waited) s, longest gap \(gap) s")
        let readOnly = await refusal(AIToolArguments(["files": .array([.string(input.path)]), "folder": "/Volumes/ReadOnly/Out"]),
                                     project, probe: probe, deadline: 5)
        require(readOnly.contains("can only read from (an NTFS drive, for example)"),
                "a read-only drive (NTFS) is said before anything is encoded: \(readOnly)")
        require(EncodeQueue.compress.items.count == queued && Set(AIJobs.shared.running.map(\.id)).isSubset(of: jobs),
                "a refused folder queues nothing and starts no job")
    }

    // MARK: - Helpers

    /// `/Volumes/Stuck…` never answers in time, `/Volumes/ReadOnly…` is a read-only drive, everything else is the real one.
    private static func stuckDrive() -> ExportDestinationProbe.FileSystem {
        var fake = ExportDestinationProbe.FileSystem.live
        fake.kind = { url in
            if url.path.hasPrefix("/Volumes/Stuck") { Thread.sleep(forTimeInterval: 8) }
            return url.path.hasPrefix("/Volumes/") ? .folder : FileSystemKind.live(url)
        }
        fake.names = { url in url.path.hasPrefix("/Volumes/") ? [] : ExportDestinationProbe.FileSystem.live.names(url) }
        fake.isReadOnlyVolume = { $0.path.hasPrefix("/Volumes/ReadOnly") }
        fake.writeTest = { $0.path.hasPrefix("/Volumes/ReadOnly") ? .readOnlyVolume : nil }
        fake.createFolder = { $0.path.hasPrefix("/Volumes/ReadOnly") ? .readOnlyVolume : nil }
        return fake
    }

    private static func refusal(
        _ args: AIToolArguments, _ project: VideoEditProject, probe: ExportDestinationProbe, deadline: TimeInterval
    ) async -> String {
        do {
            _ = try await AIEncodeTools.compress(args, project, probe: probe, deadline: deadline)
            return ""
        } catch {
            return (error as? AIToolError)?.message ?? error.localizedDescription
        }
    }

    private static func folder(_ root: URL, _ name: String) -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func waited(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}

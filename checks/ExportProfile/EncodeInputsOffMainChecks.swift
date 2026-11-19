import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// compress_videos / burn_subtitles / convert_subtitles never ask a drive on the main thread about the files the AI names
// (docs/bugfixes/2026-11-19-ai-encode-inputs-on-main-thread.md). A recording fake drive (AIEncodeInputs asks it through
// ExportDestinationProbe) answers like the real one, except that some files read slowly or not at all and one drive never
// answers:
// - every named file is looked at through the probe, never on the main thread; a drive that does not answer is refused at the
//   deadline with the main thread free and nothing queued;
// - burn_subtitles reads its subtitle file there too (a slow read leaves the main thread free);
// - convert_subtitles reads and writes there (a slow read leaves the main thread free and still converts; a read that never
//   comes back is refused at the deadline, saying files may still appear).
// Before the fix every one of these ran on the main thread, so the fake was never asked and these checks fail.
// checks/file-io-off-main-wiring.sh pins the wiring.
@MainActor enum EncodeInputsOffMainChecks {
    static func run(root: URL, input: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let folder = root.appendingPathComponent("encode-inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await compressInputs(input: input, project: project, require: require)
        await burnSubtitleRead(folder: folder, input: input, project: project, require: require)
        await convertOffMain(folder: folder, project: project, require: require)
    }

    /// compress_videos: the input is looked at through the probe; a drive that never answers is refused at the deadline.
    private static func compressInputs(input: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let log = DriveLog()
        let probe = ExportDestinationProbe(fileSystem: drive(log))
        let queued = EncodeQueue.compress.items.count, jobs = Set(AIJobs.shared.running.map(\.id))
        let readOnly = await refusal {
            try await AIEncodeTools.compress(AIToolArguments(["files": .array([.string(input.path)]), "folder": "/Volumes/ReadOnly/Out"]),
                                             project, probe: probe, deadline: 5)
        }
        require(readOnly.contains("NTFS") && log.asked("kind", input.path) && log.onMain.isEmpty,
                "compress_videos looks at the file it names through the probe, off the main thread (then refuses the read-only folder): "
                    + "\(readOnly) asked \(log.asked("kind", input.path)) on main \(log.onMain)")
        let meter = MainThreadGapMeter()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let stuck = await refusal {
            try await AIEncodeTools.compress(AIToolArguments(["files": .array([.string("/Volumes/StuckIn/clip.mp4")])]),
                                             project, probe: probe, deadline: 0.5)
        }
        let waited = ProcessInfo.processInfo.systemUptime - asked
        let gap = meter.stop()
        require(stuck.contains("The drive with “StuckIn” is not responding") && stuck.contains("Nothing was queued."),
                "compress_videos says the drive of a file it names is not responding: \(stuck)")
        require(waited < 2 && gap < 0.5, "at the deadline, with the main thread free: \(waited) s, longest gap \(gap) s")
        require(EncodeQueue.compress.items.count == queued && Set(AIJobs.shared.running.map(\.id)).isSubset(of: jobs),
                "nothing is queued and no job starts")
    }

    /// burn_subtitles: the files are looked at, and the subtitle file read, off the main thread; a slow read never holds it.
    private static func burnSubtitleRead(folder: URL, input: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let subtitles = folder.appendingPathComponent("slow-empty.srt")
        try? Data("\n".utf8).write(to: subtitles)
        let log = DriveLog()
        let probe = ExportDestinationProbe(fileSystem: drive(log))
        let queued = EncodeQueue.burnIn.items.count
        _ = await FontCatalogStore.shared.loadedFonts()   // the font list's first load is not what is measured here
        let meter = MainThreadGapMeter()
        meter.start()
        let answer = await refusal {
            try await AIEncodeTools.burnIn(AIToolArguments(["items": [["video": .string(input.path), "subtitles": .string(subtitles.path)]]]),
                                           project, probe: probe, deadline: 5)
        }
        let gap = meter.stop()
        require(answer.contains("slow-empty.srt"), "burn_subtitles reads the subtitle file and refuses one without lines: \(answer)")
        require(log.asked("kind", input.path) && log.asked("kind", subtitles.path) && log.asked("read", subtitles.path)
                    && log.onMain.isEmpty,
                "burn_subtitles looks at both files and reads the subtitles through the probe, off the main thread: on main \(log.onMain)")
        require(gap < 0.5, "a subtitle file that takes 1.5 s to read leaves the main thread free: longest gap \(gap) s")
        require(EncodeQueue.burnIn.items.count == queued, "nothing is queued")
    }

    /// convert_subtitles: read and written off the main thread; a read that never comes back is refused at the deadline.
    private static func convertOffMain(folder: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let lines = "1\n00:00:01,000 --> 00:00:02,000\nHello there\n"
        let slow = folder.appendingPathComponent("slow-lines.srt"), stuck = folder.appendingPathComponent("stuck-lines.srt")
        try? Data(lines.utf8).write(to: slow)
        try? Data(lines.utf8).write(to: stuck)
        let out = folder.appendingPathComponent("converted", isDirectory: true)
        let log = DriveLog()
        let probe = ExportDestinationProbe(fileSystem: drive(log))
        var meter = MainThreadGapMeter()
        meter.start()
        let done = try? await AIEncodeTools.convert(
            AIToolArguments(["files": .array([.string(slow.path)]), "to": "vtt", "folder": .string(out.path)]), project, probe: probe
        )
        var gap = meter.stop()
        let written = out.appendingPathComponent("slow-lines.vtt")
        let text = (try? String(contentsOf: written, encoding: .utf8)) ?? ""
        require(done?.payload["converted"]?.arrayValue?.count == 1 && text.hasPrefix("WEBVTT") && text.contains("Hello there"),
                "convert_subtitles converts a file that is slow to read: \(String(describing: done?.payload))")
        require(log.asked("read", slow.path) && log.asked("write", written.path) && log.onMain.isEmpty,
                "convert_subtitles reads and writes through the probe, off the main thread: on main \(log.onMain)")
        require(gap < 0.5, "a subtitle file that takes 1.5 s to read leaves the main thread free: longest gap \(gap) s")
        meter = MainThreadGapMeter()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let refused = await refusal {
            try await AIEncodeTools.convert(
                AIToolArguments(["files": .array([.string(stuck.path)]), "to": "vtt", "folder": .string(out.path)]), project,
                probe: probe, deadline: 0.5
            )
        }
        let waited = ProcessInfo.processInfo.systemUptime - asked
        gap = meter.stop()
        require(refused.contains("is not responding") && refused.contains("may still appear when the drive answers"),
                "a read that does not come back is refused, saying files may still appear: \(refused)")
        require(waited < 2 && gap < 0.5, "at the deadline, with the main thread free: \(waited) s, longest gap \(gap) s")
    }

    // MARK: - Helpers

    /// The real drive, recorded, except: `/Volumes/StuckIn…` never answers in time, `/Volumes/ReadOnly…` is a read-only
    /// drive, a file named `slow-…` takes 1.5 s to read and one named `stuck-…` 3 s.
    private static func drive(_ log: DriveLog) -> ExportDestinationProbe.FileSystem {
        let live = ExportDestinationProbe.FileSystem.live
        var fake = live
        fake.kind = { url in
            log.note("kind", url)
            if url.path.hasPrefix("/Volumes/StuckIn") { Thread.sleep(forTimeInterval: 8) }
            return url.path.hasPrefix("/Volumes/") ? .folder : live.kind(url)
        }
        fake.names = { url in url.path.hasPrefix("/Volumes/") ? [] : live.names(url) }
        fake.isReadOnlyVolume = { $0.path.hasPrefix("/Volumes/ReadOnly") }
        fake.writeTest = { $0.path.hasPrefix("/Volumes/ReadOnly") ? .readOnlyVolume : live.writeTest($0) }
        fake.createFolder = { $0.path.hasPrefix("/Volumes/ReadOnly") ? .readOnlyVolume : live.createFolder($0) }
        fake.read = { url in
            log.note("read", url)
            if url.lastPathComponent.hasPrefix("slow-") { Thread.sleep(forTimeInterval: 1.5) }
            if url.lastPathComponent.hasPrefix("stuck-") { Thread.sleep(forTimeInterval: 3) }
            return try live.read(url)
        }
        fake.writeNew = { data, url in
            log.note("write", url)
            try live.writeNew(data, url)
        }
        return fake
    }

    /// The error a call threw, or "" when it did not throw.
    private static func refusal(_ call: () async throws -> AIToolResult) async -> String {
        do {
            _ = try await call()
            return ""
        } catch {
            return (error as? AIToolError)?.message ?? error.localizedDescription
        }
    }
}

/// Which file-system calls the fake drive got, for which path, and which ran on the main thread.
final class DriveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(call: String, path: String, onMain: Bool)] = []

    func note(_ call: String, _ url: URL) {
        let onMain = Thread.isMainThread
        lock.withLock { calls.append((call, url.standardizedFileURL.path, onMain)) }
    }

    func asked(_ call: String, _ path: String) -> Bool {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return lock.withLock { calls.contains { $0.call == call && $0.path == wanted } }
    }

    /// The calls that ran on the main thread ("kind /path").
    var onMain: [String] { lock.withLock { calls.filter(\.onMain).map { "\($0.call) \($0.path)" } } }
}

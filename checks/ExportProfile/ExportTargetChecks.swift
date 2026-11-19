import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The AI's exports never pick one name twice and never replace a file
// (docs/bugfixes/2026-11-19-parallel-ai-exports-pick-the-same-name.md): two projects' export_video / export_subtitles into one
// folder with one name, held at a barrier until both have listed the folder (the race the review found), must end as two
// files that each read back as their own export; a file that appears after the listing (a listing that does not show it)
// is never replaced — the export moves on to the next number and says so. ExclusivePlacement itself on real folders (and a
// real exFAT volume) is checked in SrtFlowCoreChecks (ExclusivePlacementChecks.swift).
@MainActor enum ExportTargetChecks {
    static func run(root: URL, ffmpeg: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        // Two more projects (the primary one's timeline, but their own subtitles): the parallel calls come from two projects.
        let others = ["export-target-b", "export-target-c"].compactMap {
            OpenProjects.shared.newProject(savingAs: root.appendingPathComponent("\($0).skycut"), placement: .background)
        }
        defer { others.forEach { _ = OpenProjects.shared.close($0) } }
        guard others.count == 2 else { return require(false, "two background projects for the parallel exports") }
        others.forEach { $0.restoreTimeline(project.state) }
        await parallelVideos(root: root, ffmpeg: ffmpeg, projects: (project, others[0]), require: require)
        await lateVideo(root: root, project: project, require: require)
        await parallelSubtitles(root: root, projects: (others[0], others[1]), require: require)
        await lateSubtitles(root: root, project: others[1], require: require)
    }

    /// Two projects' export_video into one folder with one name, both past the listing before either picks.
    private static func parallelVideos(
        root: URL, ffmpeg: URL, projects: (VideoEditProject, VideoEditProject), require: (Bool, String) -> Void
    ) async {
        let folder = root.appendingPathComponent("twins", isDirectory: true)
        let barrier = ListingBarrier(parties: 2, folder: folder)
        let probe = ExportDestinationProbe(fileSystem: barrier.fileSystem)
        func args(_ resolution: String) -> AIToolArguments {
            AIToolArguments(["path": .string(folder.appendingPathComponent("Twin.mp4").path), "encoder": "software",
                             "resolution": .string(resolution)])
        }
        async let first = AIExportTools.export(args("720p"), projects.0, destination: probe)
        async let second = AIExportTools.export(args("480p"), projects.1, destination: probe)
        guard let both = try? await (first, second) else { return require(false, "both parallel exports start") }
        let started = [both.0, both.1]
        require(barrier.met, "both exports listed the folder before either picked a name")
        let paths = started.map { $0.payload["path"]?.stringValue ?? "" }
        require(Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["Twin.mp4", "Twin 2.mp4"],
                "two parallel exports into one folder get two names: \(paths)")
        for (index, result) in started.enumerated() {
            guard let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { continue }
            for _ in 0..<6 where job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
            let detail = (try? await AIExportTools.job(AIToolArguments(["job_id": .string(id)])))?.payload
            let file = URL(fileURLWithPath: detail?["path"]?.stringValue ?? "/missing")
            let width = (try? await MediaProbe.probe(url: file, ffmpeg: ffmpeg).get()).map { Int($0.displaySize.width) }
            require(job.status == .done && file.path == paths[index] && width == (index == 0 ? 1280 : 854),
                    "each parallel export reads back as its own video at its own name: \(file.lastPathComponent) \(width ?? 0)")
        }
    }

    /// A file that appears after the listing (Finder, another app) is never replaced: the video moves on and says so.
    private static func lateVideo(root: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let folder = root.appendingPathComponent("late-video", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let late = folder.appendingPathComponent("Late.mp4")
        FileManager.default.createFile(atPath: late.path, contents: Data("made by Finder after the listing".utf8))
        let probe = ExportDestinationProbe(fileSystem: ListingBarrier(parties: 1, folder: folder, listing: []).fileSystem)
        let args = AIToolArguments(["path": .string(late.path), "encoder": "software", "resolution": "480p"])
        guard let started = try? await AIExportTools.export(args, project, destination: probe),
              let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id)
        else { return require(false, "the export with a stale listing starts") }
        for _ in 0..<6 where job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
        let detail = (try? await AIExportTools.job(AIToolArguments(["job_id": .string(id)])))?.payload
        require(started.payload["path"]?.stringValue == late.path, "the listing did not show Late.mp4, so it was asked for")
        require(job.status == .done && read(late) == "made by Finder after the listing",
                "a file that appeared after the listing is never replaced by export_video")
        require(detail?["path"]?.stringValue == folder.appendingPathComponent("Late 2.mp4").path
                && detail?["path_note"]?.stringValue?.contains("Nothing was replaced") == true,
                "the video moves on to the next name and get_job says so: \(detail?["path"]?.stringValue ?? "nil")")
    }

    /// Two projects' export_subtitles into one folder with one name, both past the listing before either writes.
    private static func parallelSubtitles(
        root: URL, projects: (VideoEditProject, VideoEditProject), require: (Bool, String) -> Void
    ) async {
        let lines = ["Thanks for watching the first cut of this film", "Thanks for watching the second cut of this film"]
        subtitle(projects.0, lines[0])
        subtitle(projects.1, lines[1])
        let folder = root.appendingPathComponent("subtitle-twins", isDirectory: true)
        let barrier = ListingBarrier(parties: 2, folder: folder)
        let probe = ExportDestinationProbe(fileSystem: barrier.fileSystem)
        let args = AIToolArguments(["folder": .string(folder.path), "name": "Pair", "track": "original"])
        async let first = AISubtitleFileExport.export(args, projects.0, destination: probe)
        async let second = AISubtitleFileExport.export(args, projects.1, destination: probe)
        guard let both = try? await (first, second) else { return require(false, "both parallel export_subtitles write") }
        let results = [both.0, both.1]
        require(barrier.met, "both export_subtitles listed the folder before either wrote")
        let paths = results.map { $0.payload["files"]?.arrayValue?.first?["path"]?.stringValue ?? "" }
        let contents = paths.map { read(URL(fileURLWithPath: $0)) ?? "" }
        require(Set(paths).count == 2 && contents[0].contains(lines[0]) && contents[1].contains(lines[1]),
                "two parallel export_subtitles get two sets, each with its own project's lines: \(paths.map { URL(fileURLWithPath: $0).lastPathComponent })")
    }

    /// A subtitle file that appears after the listing is never replaced: the whole set moves on.
    private static func lateSubtitles(root: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        subtitle(project, "Thanks for watching this film to the very end")
        let folder = root.appendingPathComponent("late-subtitles", isDirectory: true)
        let args = AIToolArguments(["folder": .string(folder.path), "name": "Late", "track": "original"])
        // The name this export writes first (its language tag comes from the text), then that file "appears" after a listing.
        guard let named = try? await AISubtitleFileExport.export(args, project),
              let path = named.payload["files"]?.arrayValue?.first?["path"]?.stringValue
        else { return require(false, "export_subtitles writes into a new folder") }
        let late = URL(fileURLWithPath: path)
        try? Data("made by Finder after the listing".utf8).write(to: late)
        let probe = ExportDestinationProbe(fileSystem: ListingBarrier(parties: 1, folder: folder, listing: []).fileSystem)
        let again = try? await AISubtitleFileExport.export(args, project, destination: probe)
        let written = again?.payload["files"]?.arrayValue?.first?["path"]?.stringValue
        require(read(late) == "made by Finder after the listing" && written != nil && written != path,
                "a subtitle file that appeared after the listing is never replaced; the set moves on: \(written ?? "nil")")
    }

    private static func subtitle(_ project: VideoEditProject, _ line: String) {
        var state = project.state
        var document = SubtitleDocumentModel(format: .srt)
        document.cues = [SubtitleCue(index: 1, start: 0, end: 1.5, text: line)]
        state.subtitle = document
        project.restoreTimeline(state)
    }

    private static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
}

/// A file system that lists `folder` only once `parties` listings of it have been asked for (so two exports both hold a
/// listing before either picks a name), optionally answering a fixed listing (one taken before a file appeared).
final class ListingBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private let folder: String
    private let listing: [String]?
    private var arrived = 0
    private var reached = false

    /// Every party had asked for the listing before any of them got it.
    var met: Bool {
        condition.lock()
        defer { condition.unlock() }
        return reached
    }

    init(parties: Int, folder: URL, listing: [String]? = nil) {
        self.parties = parties
        self.folder = folder.standardizedFileURL.path
        self.listing = listing
    }

    var fileSystem: ExportDestinationProbe.FileSystem {
        var fileSystem = ExportDestinationProbe.FileSystem.live
        fileSystem.names = { [self] url in
            guard url.standardizedFileURL.path == folder else { return ExportDestinationProbe.FileSystem.live.names(url) }
            arrive()
            return listing ?? ExportDestinationProbe.FileSystem.live.names(url)
        }
        return fileSystem
    }

    private func arrive() {
        condition.lock()
        defer { condition.unlock() }
        arrived += 1
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 5)
        while arrived < parties { if !condition.wait(until: deadline) { return } }
        reached = true
    }
}

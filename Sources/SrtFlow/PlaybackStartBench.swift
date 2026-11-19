#if DEBUG
import AppKit
import AVFoundation
import QuartzCore

// Drives the normal open, position and Play entry points in one editor window.
// Scenario results go to the check script, which owns the timing budgets.
@MainActor
enum PlaybackStartBench {
    private static let env = ProcessInfo.processInfo.environment
    static let isRequested = env[PerfCounters.playbackStartOutputKey] != nil
    private static var started = false
    private static let audio = PlaybackStartAudioProbe()
    private static weak var clock: PlayerClock?
    private static var video: PlaybackStartVideoProbe?

    static var audioObserver: TimelineAudioEngine.SampleObserver? { isRequested ? audio.observer : nil }

    static func previewMounted(_ view: PlayerLayerView) {
        if let clock, view.player === clock.player { video?.surface = view }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Trial: Encodable {
        let scenario: String
        let metrics: [String: Double]
        let error: String?
    }

    private struct Report: Encodable {
        let media: PlaybackStartFixture.Media
        let trials: [Trial]
    }

    static func startIfRequested(project: VideoEditProject) -> Bool {
        guard let output = env[PerfCounters.playbackStartOutputKey] else { return false }
        guard !started else { return true }
        started = true
        Task {
            do {
                guard let path = env["SRTFLOW_PLAYBACK_START_MEDIA"] else { throw Failure("Missing fixture directory") }
                let report = try await run(project, directory: URL(fileURLWithPath: path, isDirectory: true))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Playback start benchmark: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private static func run(_ project: VideoEditProject, directory: URL) async throws -> Report {
        let (file, media) = try await Task.detached(priority: .userInitiated) {
            try PlaybackStartFixture.write(in: directory)
        }.value
        try await wait("editor window") { OpenProjects.shared.window(of: project)?.screen != nil }
        guard let window = OpenProjects.shared.window(of: project), let screen = window.screen else {
            throw Failure("The editor needs a graphical session")
        }
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: 960, height: 600), display: true)
        window.ignoresMouseEvents = true
        if env["CI"] == "true" {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        let probe = PlaybackStartVideoProbe()
        clock = project.clock
        video = probe
        project.clock.observePreviewItem = { probe.attach(to: $0) }
        probe.start(on: screen)
        defer { probe.stop() }
        AppUserPresence.shared.note(at: ProcessInfo.processInfo.systemUptime)

        let beforeOpen = PerfCounters.snapshot()
        await OpenProjects.shared.userOpen(file, from: project)
        guard project.documentURL == file, project.duration == PlaybackStartFixture.duration else {
            throw Failure("Synthetic project did not open: \(project.notice ?? "unexpected document or duration")")
        }
        let frame = project.state.frameRate.secondsPerFrame
        var trials = [await trial("cold-open") {
            try await measure(project, probe: probe, origin: 0, frame: frame, before: beforeOpen)
        }]
        try await wait("opened preview") {
            project.clock.player.currentItem?.status == .readyToPlay && probe.displayed != nil
        }

        let positions: [(String, Double)] = [
            ("warm-start", 0),
            ("middle", PlaybackStartFixture.deepGOP),
            ("cut", PlaybackStartFixture.cut - frame),
            ("near-end", project.duration - 2),
            ("end-replay", project.duration),
            ("idle-wake", 1),
        ]
        for (scenario, position) in positions {
            trials.append(await trial(scenario) {
                try await prepare(project, probe: probe, position: position, frame: frame)
                if scenario == "idle-wake" { try await stopForIdle(project) }
                let origin = scenario == "end-replay" ? 0 : position
                return try await measure(project, probe: probe, origin: origin, frame: frame, before: PerfCounters.snapshot())
            })
        }
        return Report(media: media, trials: trials)
    }

    private static func prepare(
        _ project: VideoEditProject, probe: PlaybackStartVideoProbe, position: Double, frame: Double
    ) async throws {
        project.seekFromTimeline(time: position)
        // AVPlayer can hold the last decoded picture without vending a sample at the exact end time.
        if position == project.duration { return }
        let visible = min(position, project.duration - frame)
        try await wait("paused picture at \(visible)") {
            guard let displayed = probe.displayed else { return false }
            return abs(displayed.timeline - visible) < frame * 0.95
        }
    }

    private static func stopForIdle(_ project: VideoEditProject) async throws {
        project.audioEngineHost.suspendNow()
        try await Task.sleep(for: .seconds(2))
        guard project.audioEngineHost.graphStateName == "suspended" else {
            throw Failure("Idle trial did not begin with a suspended realtime output graph (\(project.audioEngineHost.graphStateName))")
        }
    }

    private static func trial(_ name: String, _ body: () async throws -> [String: Double]) async -> Trial {
        do {
            return Trial(scenario: name, metrics: try await body(), error: nil)
        } catch {
            return Trial(scenario: name, metrics: [:], error: error.localizedDescription)
        }
    }

    private static func measure(
        _ project: VideoEditProject, probe: PlaybackStartVideoProbe, origin: Double, frame: Double,
        before: [String: Int]
    ) async throws -> [String: Double] {
        probe.resetPlayingFrames()
        let request = CACurrentMediaTime()
        let attempt = audio.begin(request: request, origin: origin)
        project.clock.togglePlayback()
        let returned = CACurrentMediaTime()
        defer { project.clock.pause() }
        do {
            try await wait("advancing video and real audio for one second") {
                guard let firstVideo = firstPlayingFrame(in: probe, origin: origin, frame: frame),
                      let firstAudio = attempt.first else { return false }
                return followupFrame(in: probe, audio: attempt, after: max(firstVideo.host, firstAudio.onset) + 1) != nil
            }
        } catch {
            throw Failure("Timed out getting playback at \(origin)s. Item: \(project.clock.player.currentItem?.status.rawValue ?? -1), "
                + "graph: \(project.audioEngineHost.graphStateName), audio: \(String(describing: attempt.first)), "
                + "video first/last: \(String(describing: probe.playingFrames.first))/\(String(describing: probe.playingFrames.last))")
        }

        guard let firstVideo = firstPlayingFrame(in: probe, origin: origin, frame: frame), let firstAudio = attempt.first,
              let followup = followupFrame(in: probe, audio: attempt, after: max(firstVideo.host, firstAudio.onset) + 1),
              let firstDisplayed = probe.firstDisplayed,
              let audioAtStart = attempt.timeline(at: firstVideo.host, extrapolateFirst: true),
              let audioLater = attempt.timeline(at: followup.host) else {
            throw Failure("Playback measurements were incomplete")
        }
        let after = PerfCounters.snapshot()
        return [
            "dispatchMs": ms(returned - request),
            "audioMs": ms(firstAudio.onset - request),
            "videoMs": ms(firstVideo.host - request),
            "onsetGapMs": ms(abs(firstAudio.onset - firstVideo.host)),
            "audioAdvanceMs": ms(firstAudio.timeline - origin),
            "videoAdvanceMs": ms(firstVideo.timeline - origin),
            "startOffsetMs": ms(audioAtStart - firstVideo.timeline),
            "oneSecondOffsetMs": ms(audioLater - followup.timeline),
            "oneSecondElapsedMs": ms(followup.host - firstVideo.host),
            "builds": count(.compositionBuild, from: before, to: after),
            "itemAttaches": count(.playerItemAttach, from: before, to: after),
            "assetOpens": count(.compositionAssetOpen, from: before, to: after),
            "videoPrerolls": count(.previewPreroll, from: before, to: after),
            "firstItemPictureMs": ms(firstDisplayed.host - request),
        ]
    }

    private static func firstPlayingFrame(
        in probe: PlaybackStartVideoProbe, origin: Double, frame: Double
    ) -> PlaybackStartVideoProbe.Frame? {
        probe.playingFrames.first { $0.timeline > origin + frame * 0.5 }
    }

    private static func followupFrame(
        in probe: PlaybackStartVideoProbe, audio: PlaybackStartAudioProbe.Attempt, after host: Double
    ) -> PlaybackStartVideoProbe.Frame? {
        probe.playingFrames.first { $0.host >= host && audio.timeline(at: $0.host) != nil }
    }

    private static func count(_ event: PerfCounters.Event, from before: [String: Int], to after: [String: Int]) -> Double {
        let key = "event:\(event.rawValue)"
        return Double(after[key, default: 0] - before[key, default: 0])
    }

    private static func ms(_ seconds: Double) -> Double { seconds * 1_000 }

    private static func wait(_ description: String, until ready: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 5
        while !ready() {
            guard CACurrentMediaTime() < deadline else { throw Failure("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}
#endif

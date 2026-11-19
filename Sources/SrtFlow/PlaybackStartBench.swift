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
        if let clock, view.player === clock.player { video?.mount(view) }
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
        // A run with optimized media on writes its proxies next to the fixture, never into the user's cache.
        OptimizedMediaStore.rootOverride = directory.appendingPathComponent("OptimizedMedia", isDirectory: true)
        let (file, media) = try await Task.detached(priority: .userInitiated) {
            try PlaybackStartFixture.write(in: directory)
        }.value
        try await wait("editor window") {
            guard let window = OpenProjects.shared.window(of: project) else { return false }
            return window.isVisible && window.screen != nil
        }
        guard let window = OpenProjects.shared.window(of: project), window.isVisible, let opened = window.screen else {
            throw Failure("The editor needs a graphical session")
        }
        // Sample on the fastest display: a 25 Hz television would hide a 40 ms picture stall between two refreshes.
        let screen = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond } ?? opened
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
        try probe.start(on: screen)
        defer { probe.stop() }
        AppUserPresence.shared.note(at: ProcessInfo.processInfo.systemUptime)

        let beforeOpen = PerfCounters.snapshot()
        await OpenProjects.shared.userOpen(file, from: project)
        guard project.documentURL == file, project.duration == PlaybackStartFixture.duration else {
            throw Failure("Synthetic project did not open: \(project.notice ?? "unexpected document or duration")")
        }
        let frame = project.state.frameRate.secondsPerFrame
        if env["SRTFLOW_PLAYBACK_START_SETTLED_OPEN"] != nil {
            // Local diagnosis only: the person opens a project, sees its first picture, then presses Play.
            try await wait("opened paused picture") { probe.displayed != nil && !project.clock.isPositioningPreview }
            try await PlaybackStartScenarios.think()
        }
        let cold = try await measure(project, probe: probe, origin: 0, frame: frame, before: beforeOpen)
        var trials = [Trial(scenario: "cold-open", metrics: cold, error: nil)]
        for scenario in PlaybackStartScenarios.list(duration: project.duration, frame: frame) {
            trials.append(await trial(scenario.name) {
                let origin = try await PlaybackStartScenarios.stage(scenario, project: project, probe: probe, frame: frame)
                return try await measure(project, probe: probe, origin: origin, frame: frame, before: PerfCounters.snapshot())
            })
        }
        return Report(media: media, trials: trials)
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
        let deadline = request + 5
        let attempt = audio.begin(request: request, origin: origin)
        project.clock.togglePlayback()
        let returned = CACurrentMediaTime()
        defer { project.clock.pause() }
        do {
            try await wait("first advancing video and real audio", deadline: deadline) {
                firstPlayingFrame(in: probe, origin: origin, frame: frame) != nil && attempt.first != nil
            }
        } catch {
            throw Failure("Timed out getting playback at \(origin)s. Item: \(project.clock.player.currentItem?.status.rawValue ?? -1), "
                + "graph: \(project.audioEngineHost.graphStateName), audio: \(String(describing: attempt.first)), "
                + "video first/last: \(String(describing: probe.playingFrames.first))/\(String(describing: probe.playingFrames.last))")
        }

        guard let firstVideo = firstPlayingFrame(in: probe, origin: origin, frame: frame), let firstAudio = attempt.first,
              let firstDisplayed = probe.firstDisplayed, firstVideo.host <= deadline, firstAudio.onset <= deadline else {
            throw Failure("Playback onset measurements were incomplete")
        }
        let followup = try await sampleFollowup(probe, attempt, after: max(firstVideo.host, firstAudio.onset) + 1,
                                                deadline: deadline)
        guard let audioAtStart = attempt.timeline(at: firstVideo.host, extrapolateFirst: true) else {
            let gap = attempt.gap(at: firstVideo.host).map { String(format: " (%.1f ms after the last block)", $0 * 1_000) }
            throw Failure("No audio timeline sample at first picture" + (gap ?? ""))
        }
        // The picture must keep moving with the sound, not only start with it: watch the first two seconds,
        // or up to the last frame before the timeline ends.
        let window = min(continuitySeconds, project.duration - frame - firstVideo.timeline)
        while CACurrentMediaTime() < firstVideo.host + window + 0.05 { try await Task.sleep(for: .milliseconds(8)) }
        guard let continuity = PlaybackStartContinuity.measure(
            frames: probe.playingFrames, from: firstVideo.host, seconds: window,
            audio: { attempt.timeline(at: $0) }
        ), continuity.skewSamples > 0 else {
            throw Failure("No picture continuity samples after the first frame")
        }
        let cadence = probe.cadence
        guard cadence.period.isFinite, cadence.longestGap > 0 else { throw Failure("No display cadence control samples") }
        let after = PerfCounters.snapshot()
        var metrics = [
            "dispatchMs": ms(returned - request),
            "audioMs": ms(firstAudio.onset - request),
            "videoMs": ms(firstVideo.host - request),
            "onsetGapMs": ms(abs(firstAudio.onset - firstVideo.host)),
            "audioAdvanceMs": ms(firstAudio.timeline - origin),
            "videoAdvanceMs": ms(firstVideo.timeline - origin),
            "startOffsetMs": ms(audioAtStart - firstVideo.timeline),
            "oneSecondTimedOut": followup == nil ? 1.0 : 0.0,
            "stallMs": continuity.stallMs,
            "maxSkewMs": continuity.maxSkewMs,
            "displayPeriodMs": ms(cadence.period),
            "displayGapMs": ms(cadence.longestGap),
            "firstItemPictureMs": ms(firstDisplayed.host - request),
            "builds": count(.compositionBuild, from: before, to: after),
            "itemAttaches": count(.playerItemAttach, from: before, to: after),
            "assetOpens": count(.compositionAssetOpen, from: before, to: after),
            "videoPrerolls": count(.previewPreroll, from: before, to: after),
        ]
        if let followup {
            metrics["oneSecondOffsetMs"] = ms(followup.audio - followup.video.timeline)
            metrics["oneSecondElapsedMs"] = ms(followup.video.host - firstVideo.host)
        }
        return metrics
    }

    private static func firstPlayingFrame(
        in probe: PlaybackStartVideoProbe, origin: Double, frame: Double
    ) -> PlaybackStartVideoProbe.Frame? {
        probe.playingFrames.first { $0.timeline > origin + frame * 0.5 }
    }

    private static func sampleFollowup(
        _ probe: PlaybackStartVideoProbe, _ audio: PlaybackStartAudioProbe.Attempt, after host: Double, deadline: Double
    ) async throws -> (video: PlaybackStartVideoProbe.Frame, audio: Double)? {
        while CACurrentMediaTime() <= deadline {
            for frame in probe.playingFrames where frame.host >= host && frame.host <= deadline {
                if let time = audio.timeline(at: frame.host) { return (frame, time) }
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        return nil
    }

    private static func count(_ event: PerfCounters.Event, from before: [String: Int], to after: [String: Int]) -> Double {
        let key = "event:\(event.rawValue)"
        return Double(after[key, default: 0] - before[key, default: 0])
    }

    private static func ms(_ seconds: Double) -> Double { seconds * 1_000 }
    private static let continuitySeconds = 2.0

    /// Staging waits get 20 s: the hosted virtual Mac decodes 4K in software under a load of 20-50 on three cores, and a
    /// paused placement two seconds into a GOP took over 5 s there (2026-11-19). Play itself has its own 5 s deadline.
    static func wait(_ description: String, deadline: Double = CACurrentMediaTime() + 20,
                             until ready: () -> Bool) async throws {
        while !ready() {
            guard CACurrentMediaTime() < deadline else { throw Failure("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}
#endif

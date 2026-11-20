#if DEBUG
import AppKit
import AVFoundation

// The playback-start benchmark's scenarios after the cold open: where the playhead is and what the person did just
// before pressing Play, staged through the editor's own entry points. The bench (PlaybackStartBench) times Play;
// the check script owns the limits (docs/architecture/playback-start.md).
@MainActor
enum PlaybackStartScenarios {
    struct Scenario {
        let name: String
        let position: Double
    }

    static func list(duration: Double, frame: Double) -> [Scenario] {
        [
            Scenario(name: "warm-start", position: 0),
            Scenario(name: "middle", position: PlaybackStartFixture.deepGOP),
            Scenario(name: "cut", position: PlaybackStartFixture.cut - frame),
            Scenario(name: "fresh-item", position: PlaybackStartFixture.freshItem),
            Scenario(name: "seek-play", position: PlaybackStartFixture.farSeek),
            Scenario(name: "resume", position: PlaybackStartFixture.freshItem),
            Scenario(name: "peek-play", position: PlaybackStartFixture.freshItem),
            Scenario(name: "peek-end-play", position: PlaybackStartFixture.freshItem),
            Scenario(name: "play-seek", position: PlaybackStartFixture.farSeek),
            Scenario(name: "near-end", position: duration - 2),
            Scenario(name: "end-replay", position: duration),
            Scenario(name: "idle-wake", position: 1),
        ]
    }

    /// Stages the scenario and returns the timeline position Play must start from.
    static func stage(
        _ scenario: Scenario, project: VideoEditProject, probe: PlaybackStartVideoProbe, frame: Double
    ) async throws -> Double {
        let position = scenario.position
        switch scenario.name {
        case "seek-play":
            // Play straight after a far click on the timeline, while the paused seek is still on its way.
            project.seekFromTimeline(time: position)
        case "fresh-item":
            // An edit right after a click: the click only places the playhead (the rebuild replaces the item it placed
            // the picture on), then the production rebuild installs a new item and Play follows once its paused
            // picture is up. Waiting for the old item's paused picture timed out 8 times on 2026-11-19/20, hosted and
            // local, always right after the `cut` scenario's pause: AVFoundation reported that seek and its preroll
            // finished within 10-20 ms and never vended the frame; a same-time re-seek changed nothing.
            project.seekFromTimeline(time: position)
            try await PlaybackStartBench.wait("placement at \(position)") { !project.clock.isPositioningPreview }
            try await rebuild(project, probe: probe, at: position, frame: frame)
        case "resume":
            // Space to play, space to pause a second later, space again: playback continues where it paused.
            try await place(project, probe: probe, at: position, frame: frame)
            project.clock.togglePlayback()
            try await Task.sleep(for: .seconds(1))
            project.clock.togglePlayback()
            try await Task.sleep(for: .milliseconds(400))
            return project.clock.time
        case "peek-play", "peek-end-play":
            // The pointer hovers the 1080p opening with the playhead in the 4K source, and Play is pressed while it is
            // still there (`peek-play`) or right after it left the timeline (`peek-end-play`): play from the playhead.
            try await place(project, probe: probe, at: position, frame: frame)
            try await hover(project, probe: probe, at: PlaybackStartFixture.peek, playhead: position, frame: frame)
            if scenario.name == "peek-end-play" { project.clock.endPeek() }
        case "play-seek":
            // Playing in the 4K source, then a click far ahead into a later GOP (`action`): picture and sound land
            // there together, the decode at the click included.
            try await place(project, probe: probe, at: PlaybackStartFixture.freshItem, frame: frame)
            project.clock.togglePlayback()
            try await PlaybackStartBench.wait("playback before the click") { project.clock.isPlaying }
            try await Task.sleep(for: .seconds(1))
        case "idle-wake":
            try await place(project, probe: probe, at: position, frame: frame)
            try await stopForIdle(project)
        default:
            try await place(project, probe: probe, at: position, frame: frame)
        }
        return scenario.name == "end-replay" ? 0 : position
    }

    /// What the person does at the measured moment: Play, or for `play-seek` the click while playing.
    static func action(for scenario: Scenario, project: VideoEditProject) -> () -> Void {
        guard scenario.name == "play-seek" else { return { project.clock.togglePlayback() } }
        return { project.seekFromTimeline(time: scenario.position) }
    }

    /// A hover shows on its own player (`HoverPreview`): its frame is on screen, and the editing picture is still the
    /// playhead's, placed and primed for Play (docs/architecture/playback-start.md "Hover").
    private static func hover(
        _ project: VideoEditProject, probe: PlaybackStartVideoProbe, at peek: Double, playhead: Double, frame: Double
    ) async throws {
        project.clock.peek(at: peek)
        let hover = project.clock.hover
        try await PlaybackStartBench.wait("hover picture at \(peek)") {
            hover.isShowing && abs((hover.shownTime ?? -1) - peek) < 0.001
        }
        // The click's placement goes on under the hover and primes the editing picture for Play.
        try await PlaybackStartBench.wait("placement under the hover") { !project.clock.isPositioningPreview }
        guard let displayed = probe.displayed, abs(displayed.timeline - playhead) < frame * 0.95, hover.isShowing else {
            throw PlaybackStartBench.Failure("The hover moved the editing picture (\(state(project, probe: probe)))")
        }
    }

    /// Between two scenarios: the previous one's pause (and a failed trial's pending Play) has settled before the next
    /// one touches the playhead, with the gap a person leaves before the next action. The scenarios used to follow one
    /// another within a millisecond of the measurement's pause; every staging failure in the gate followed such a
    /// pause and a seek to 10.0 (docs/bugfixes/2026-11-20-playback-gate-staging-after-pause.md).
    static func settle(_ project: VideoEditProject) async {
        project.clock.pause()
        let deadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < deadline {
            let rate = project.clock.player.currentItem?.timebase.map(CMTimebaseGetRate) ?? 0
            if rate == 0, !project.clock.isPositioningPreview { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// The player's state for a staging failure's message: enough to tell a stuck seek from a slow one.
    static func state(_ project: VideoEditProject, probe: PlaybackStartVideoProbe) -> String {
        let clock = project.clock
        let item = clock.player.currentItem
        let timebase = item?.timebase.map { String(format: "%.3f@%.2f", CMTimebaseGetTime($0).seconds, CMTimebaseGetRate($0)) } ?? "none"
        return String(format: "playhead %.3f, timebase %@, rate %.2f, item %d, placing %@, picture %@", clock.time, timebase,
                      clock.player.rate, item?.status.rawValue ?? -1, clock.isPositioningPreview ? "yes" : "no",
                      probe.displayed.map { String(format: "%.3f", $0.timeline) } ?? "none")
    }

    /// A click on the timeline; Play follows as soon as the paused picture is on screen.
    static func place(
        _ project: VideoEditProject, probe: PlaybackStartVideoProbe, at position: Double, frame: Double
    ) async throws {
        project.seekFromTimeline(time: position)
        // At the exact end AVPlayer can hold the last picture without vending a frame at that time.
        // Let the native placement finish before testing the subsequent rewind.
        if position == project.duration {
            try await PlaybackStartBench.wait("native placement at the exact end") { !project.clock.isPositioningPreview }
            return
        }
        let visible = min(position, project.duration - frame)
        do {
            try await PlaybackStartBench.wait("paused picture at \(visible)") {
                guard let displayed = probe.displayed else { return false }
                return abs(displayed.timeline - visible) < frame * 0.95
            }
        } catch {
            throw PlaybackStartBench.Failure("\(error.localizedDescription) (\(state(project, probe: probe)))")
        }
    }

    /// An edit installs a new composition item through the production rebuild; Play follows once its paused picture
    /// is on screen and prepared, the moment a person would see the edit.
    private static func rebuild(
        _ project: VideoEditProject, probe: PlaybackStartVideoProbe, at position: Double, frame: Double
    ) async throws {
        let previous = project.clock.player.currentItem
        project.scheduleRebuild()
        // The rebuild attaches the item, installs the sound and starts the placement in one main-actor turn.
        try await PlaybackStartBench.wait("rebuilt preview item") { project.clock.player.currentItem !== previous }
        try await PlaybackStartBench.wait("rebuilt and prepared paused picture at \(position)") {
            guard let displayed = probe.displayed, !project.clock.isPositioningPreview else { return false }
            return abs(displayed.timeline - position) < frame * 0.95
        }
        try await think()
    }

    /// How long a person takes to press Play after the picture appears (local diagnosis; zero in the gate).
    static func think() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let milliseconds = env["SRTFLOW_PLAYBACK_START_THINK_MS"].flatMap(Int.init), milliseconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private static func stopForIdle(_ project: VideoEditProject) async throws {
        // Focus or pointer activity can return while a local run is preparing the idle case.
        // Local diagnosis only: a longer stop lets the output device cool down as after the real two-minute stop.
        let seconds = ProcessInfo.processInfo.environment["SRTFLOW_PLAYBACK_START_IDLE_SECONDS"].flatMap(Double.init) ?? 2
        for _ in 0..<2 {
            project.audioEngineHost.suspendNow()
            try await Task.sleep(for: .seconds(seconds))
            if project.audioEngineHost.graphStateName == "suspended" { return }
        }
        throw PlaybackStartBench.Failure(
            "Idle trial did not begin with a suspended realtime output graph (\(project.audioEngineHost.graphStateName))"
        )
    }
}
#endif

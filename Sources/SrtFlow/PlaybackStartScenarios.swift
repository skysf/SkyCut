#if DEBUG
import AppKit

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
            try await place(project, probe: probe, at: position, frame: frame)
            try await rebuild(project, probe: probe, at: position, frame: frame)
        case "resume":
            // Space to play, space to pause a second later, space again: playback continues where it paused.
            try await place(project, probe: probe, at: position, frame: frame)
            project.clock.togglePlayback()
            try await Task.sleep(for: .seconds(1))
            project.clock.togglePlayback()
            try await Task.sleep(for: .milliseconds(400))
            return project.clock.time
        case "peek-play":
            // The pointer hovers an earlier part of the timeline when Play is pressed: play from the playhead.
            try await place(project, probe: probe, at: position, frame: frame)
            project.clock.peek(at: PlaybackStartFixture.peek)
            try await PlaybackStartBench.wait("hover picture at \(PlaybackStartFixture.peek)") {
                guard let displayed = probe.displayed else { return false }
                return abs(displayed.timeline - PlaybackStartFixture.peek) < frame * 0.95
            }
        case "idle-wake":
            try await place(project, probe: probe, at: position, frame: frame)
            try await stopForIdle(project)
        default:
            try await place(project, probe: probe, at: position, frame: frame)
        }
        return scenario.name == "end-replay" ? 0 : position
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
        try await PlaybackStartBench.wait("paused picture at \(visible)") {
            guard let displayed = probe.displayed else { return false }
            return abs(displayed.timeline - visible) < frame * 0.95
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
        for _ in 0..<2 {
            project.audioEngineHost.suspendNow()
            try await Task.sleep(for: .seconds(2))
            if project.audioEngineHost.graphStateName == "suspended" { return }
        }
        throw PlaybackStartBench.Failure(
            "Idle trial did not begin with a suspended realtime output graph (\(project.audioEngineHost.graphStateName))"
        )
    }
}
#endif

import AppKit
import Combine
import SwiftUI
@testable import SrtFlow

// Take the timeline down twice with no AppKit event loop running, so each closed window and its hosting view are released
// right after the close: a project window (the full editor, closed the way set_view background closes it) and a window whose
// root is the timeline (the off-screen renderers' shape). Taking the timeline down must publish nothing. Until 2026-11-27 its
// scroll accessor wrote the @Published offset from dismantleNSView, inside SwiftUI's graph invalidation: the second window
// aborted with "Fatal access conflict", the first published too and survived only by SwiftUI's teardown order
// (docs/bugfixes/2026-11-27-timeline-teardown-publishes-scroll-offset.md). Counting the publishes keeps the check meaningful
// on a macOS whose teardown order would not abort.
@MainActor enum TimelineTeardownGUI {
    static func check(window project: VideoEditProject, root other: VideoEditProject) async throws {
        for target in [project, other] {
            target.perform { $0.textOverlays = [TextOverlay(text: "Title", timelineStart: 0, duration: 3, row: 0)] }
        }
        try await projectWindow(project)
        try await timelineAsRoot(other)
        print("GUI timeline teardown: a project window and a timeline-only window closed and released, nothing published")
    }

    private static func projectWindow(_ project: VideoEditProject) async throws {
        weak var host: NSView?
        do {
            OpenProjects.shared.showWindow(for: project, inFront: false)
            guard let window = OpenProjects.shared.window(of: project) else { throw CheckFailure("The project window did not open") }
            window.ignoresMouseEvents = true
            host = window.contentView
        }
        try await takeDown(project, in: "the project window", released: { host == nil }) {
            OpenProjects.shared.moveToBackground(project)
        }
    }

    private static func timelineAsRoot(_ project: VideoEditProject) async throws {
        var window: CheckWindow? = try CheckWindow(VideoEditTimelineView(project: project, clock: project.clock),
                                                   width: 900, height: 230)
        weak var host = window?.window.contentView
        try await takeDown(project, in: "a window whose root is the timeline", released: { host == nil }) {
            window?.close()
            window = nil
        }
    }

    /// Waits for the timeline to attach its scroll view, closes, waits for the hosting view to go, and counts what the
    /// timeline's scroll geometry published from the close on: it has to be nothing.
    private static func takeDown(_ project: VideoEditProject, in place: String, released: @MainActor () -> Bool,
                                 close: () -> Void) async throws {
        try await poll("the timeline in \(place) to attach its scroll view") {
            TimelineScrollGeometry.live(for: project)?.isAttached == true
        }
        guard let geometry = TimelineScrollGeometry.live(for: project) else { throw CheckFailure("No timeline in \(place)") }
        let published = Counter()
        let watch = geometry.objectWillChange.sink { _ in published.count += 1 }
        defer { watch.cancel() }
        close()
        try await poll("closing \(place) to release its hosting view", until: released)
        guard published.count == 0 else {
            throw CheckFailure("Taking the timeline in \(place) down published its scroll geometry \(published.count) time(s)")
        }
        guard TimelineScrollGeometry.live(for: project) == nil else {
            throw CheckFailure("The timeline in \(place) is still registered after its window closed")
        }
        note("Took the timeline in \(place) down: hosting view released, nothing published")
    }

    private static func poll(_ condition: String, until reached: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + CheckWindow.controlTimeout
        while !reached() {
            guard ContinuousClock.now < deadline else {
                throw CheckFailure("Timed out after \(CheckWindow.controlTimeout) waiting for \(condition)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private final class Counter {
        var count = 0
    }
}

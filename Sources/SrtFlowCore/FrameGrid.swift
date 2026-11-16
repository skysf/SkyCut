import Foundation

// MARK: - The project's frame grid: timeline seconds <-> frame numbers
//
// What it does: says which frame a timeline time falls on, which frame is the first one at or after a time, and when a
// frame starts, for one frame rate. Overlay animation times (preview, export, the AI's look) all go through it, so "which
// frame is this" has one answer everywhere.
// What it does not do: choose the frame rate (`ProjectFrameRate` is the only source) or round times for display.
//
// Why it has a tolerance: times are Doubles. `0.5 + 10.0 / 30` is 0.8333333333333333 and times 30 that is
// 24.999999999999996, so a plain floor says frame 24 where the time is frame 25. An exported title then showed frame 24
// twice and frame 26 caught up (docs/bugfixes/2026-11-17-overlay-export-repeats-a-frame.md). A time within
// `tolerance` of a frame boundary counts as that boundary.

public struct FrameGrid: Hashable, Sendable {
    public let fps: Int

    /// How far below a frame boundary a time may sit and still count as on it, in frames. 1e-6 of a frame (42 ns at 24 fps)
    /// is far above Double noise for any timeline length and far below any time a person or the AI places on purpose.
    public static let tolerance = 1e-6

    public init(fps: Int) {
        self.fps = max(1, fps)
    }

    public init(_ rate: ProjectFrameRate) {
        self.init(fps: rate.fps)
    }

    /// The frame on screen at `time`: the last frame that starts at or before it.
    public func frame(containing time: Double) -> Int {
        guard time.isFinite else { return 0 }
        return Int((time * Double(fps) + Self.tolerance).rounded(.down))
    }

    /// The first frame that starts at or after `time`.
    public func firstFrame(atOrAfter time: Double) -> Int {
        guard time.isFinite else { return 0 }
        return Int((time * Double(fps) - Self.tolerance).rounded(.up))
    }

    /// When frame `index` starts (timeline seconds).
    public func time(ofFrame index: Int) -> Double {
        Double(index) / Double(fps)
    }
}

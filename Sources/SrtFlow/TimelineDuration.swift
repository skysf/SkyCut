import Foundation

// Owns the content end and explicit project ending. Rendering and audio consume TimelineState.duration;
// this never moves, trims, or creates timeline items, and does not own file I/O or editing transactions.
enum TimelineDuration {
    static func sanitized(_ value: Double) -> Double { value.isFinite && value > 0 ? value : 0 }

    static func contentEnd(_ state: TimelineState) -> Double {
        var end = state.mainClips.map(\.timelineEnd).max() ?? 0
        for lane in state.overlayTracks { end = max(end, lane.clips.map(\.timelineEnd).max() ?? 0) }
        for lane in state.audioTracks { end = max(end, lane.clips.map(\.timelineEnd).max() ?? 0) }
        for shape in state.shapes where !shape.kind.isCover { end = max(end, shape.timelineEnd) }
        for text in state.textOverlays { end = max(end, text.timelineEnd) }
        // Covers and grades only affect existing pictures; they must not create extra black footage.
        return end
    }

    static func end(_ state: TimelineState) -> Double {
        max(contentEnd(state), sanitized(state.minimumDuration))
    }
}

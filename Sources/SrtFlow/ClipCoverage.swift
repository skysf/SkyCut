import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - Where a clip's picture is on the canvas, and whether it covers the canvas while on screen
//
// What: a picture clip's box and rotation at a timeline moment, read where the preview and the export read them — the static placement
// or the default fit, position / size / rotation keyframes (`animatedPlacement`, `animatedRotation`) and, when asked, the entrance /
// exit motion of that moment (`presetState`, as the builder adds it); then
// - over the clip's whole time on screen: does it cover the canvas at every frame, when not, and the smallest steady scale that would
//   (`fill`: get_timeline's fills_frame, fills_except, fill_scale);
// - at one moment of the timeline: the pictures that cover the canvas (`coveringPictures`: look's uncovered).
// The geometry itself is `PictureCoverage`; this file only says which boxes to feed it.
// Not: words for the AI (`AIPictureCoverage`), opacity, fades and transitions (they show the layer below on purpose; a transition's
// two clips together cover what each covers on its own).

enum ClipCoverage {
    /// The clip's picture at timeline `time` (clamped into the clip). `motion` adds the entrance / exit motion of that moment
    /// (`motion(of:in:)`); without it, the picture at rest.
    static func picture(
        _ clip: EditClip, atTimeline time: Double, canvas: CGSize, motion: ResolvedClipPreset = .none
    ) -> PictureCoverage.Picture {
        let at = min(max(time, clip.timelineStart), clip.timelineEnd)
        var picture = PictureCoverage.Picture(
            frame: clip.animatedPlacement(atTimeline: at, canvas: canvas).frame(in: canvas),
            rotationDegrees: clip.animatedRotation(atTimeline: at)
        )
        guard !motion.isEmpty else { return picture }
        let state = clip.presetState(resolved: motion, atTimeline: at, canvas: canvas)
        picture.frame = state.apply(to: picture.frame)
        if let reveal = state.reveal {
            // A wipe uncovers the source from its left; a horizontal flip draws that part on the box's right (`revealCropRect`).
            let shown = min(max(reveal, 0), 1)
            picture.revealed = clip.flippedHorizontally ? (1 - shown)...1 : 0...shown
        }
        return picture
    }

    // MARK: Over the clip's time on screen

    struct Fill: Equatable {
        /// Covers the whole canvas at every frame the clip is on screen.
        var fillsFrame: Bool
        /// Timeline seconds when it does not, in order: from the first such frame to the next frame that covers (or the clip's end).
        var unfilled: [ClosedRange<Double>]
        /// It covers at some frames and not at others.
        var isPartial: Bool
        /// The smallest steady scale (as get_timeline reports scale: 1 = the default fit) at which it would cover the canvas at every
        /// frame, corner pixels whole, keeping its position, rotation and shape; nil when it already covers.
        var fillScale: Double?
    }

    /// Ranges in `Fill.unfilled` at most; the last one then runs to the end of the last uncovered stretch.
    static let maximumRanges = 8

    static func fill(_ clip: EditClip, canvas: CGSize) -> Fill {
        let base = clip.defaultPlacement(canvas: canvas).width
        var unfilled: [ClosedRange<Double>] = []
        var runStart: Double?
        var covered = false
        var needed = 0.0
        for time in sampleTimes(clip) {
            let picture = picture(clip, atTimeline: time, canvas: canvas)
            let factor = PictureCoverage.fillFactor(picture, canvas: canvas)
            let scale = base > 0 && canvas.width > 0 ? picture.frame.width / canvas.width / base : 1
            // Measured to the canvas's own corners: at fill_scale the real frame's corner pixels are covered too (in the preview's
            // compositor they sit up to about a third of a pixel off the geometry; checks/PreviewComposition/RotatedPictures.swift).
            needed = max(needed, PictureCoverage.fillFactor(picture, canvas: canvas, inset: 0) * scale)
            if factor > 1 + 1e-9 {
                if runStart == nil { runStart = time }
            } else {
                covered = true
                if let start = runStart { append(start...time, to: &unfilled) }
                runStart = nil
            }
        }
        if let start = runStart { append(start...max(start, clip.timelineEnd), to: &unfilled) }
        guard !unfilled.isEmpty else { return Fill(fillsFrame: true, unfilled: [], isPartial: false, fillScale: nil) }
        // Rounded up (past floating-point dust: exactly 1 stays 1): the reported scale itself covers.
        let scale = needed.isFinite ? (needed * 1000 - 1e-6).rounded(.up) / 1000 : nil
        return Fill(fillsFrame: false, unfilled: unfilled, isPartial: covered, fillScale: scale)
    }

    private static func append(_ range: ClosedRange<Double>, to ranges: inout [ClosedRange<Double>]) {
        if ranges.count == maximumRanges, let last = ranges.popLast() {
            ranges.append(last.lowerBound...range.upperBound)
        } else {
            ranges.append(range)
        }
    }

    /// One frame grid that holds every frame of every project frame rate (24, 30, 60 → 120 per second): the moments a clip can be
    /// seen at, whatever the project's rate.
    static let framesPerSecondGrid: Int = ProjectFrameRate.allCases.map(\.fps).reduce(1) { lcm($0, $1) }

    /// The most moments sampled for one clip; a longer moving clip is sampled every few grid steps.
    static let maximumSamples = 36_000

    /// The moments to test: every grid frame in [start, end) for a clip whose box moves, else just its first moment.
    static func sampleTimes(_ clip: EditClip) -> [Double] {
        guard moves(clip) else { return [clip.timelineStart] }
        let grid = Double(framesPerSecondGrid)
        let first = Int((clip.timelineStart * grid - 1e-6).rounded(.up))
        let last = Int((clip.timelineEnd * grid - 1e-6).rounded(.up)) - 1
        guard last >= first else { return [clip.timelineStart] }
        let stride = max(1, (last - first + 1 + maximumSamples - 1) / maximumSamples)
        return Swift.stride(from: first, through: last, by: stride).map { Double($0) / grid }
    }

    /// The box can be somewhere else at another moment: two or more position, size or rotation keyframes.
    static func moves(_ clip: EditClip) -> Bool {
        guard let animation = clip.animation else { return false }
        return [animation.centerX, animation.centerY, animation.width, animation.height, animation.rotation]
            .contains { $0.keys.count > 1 }
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        return a / gcd(a, b) * b
    }

    // MARK: At one moment of the timeline

    /// Picture clips on screen at `time`, track by track from V1 up: visible clips on visible video tracks (look's on_screen list).
    static func onScreen(in state: TimelineState, at time: Double) -> [(slot: TrackSlot, clip: EditClip)] {
        var lanes: [(TrackSlot, [EditClip], Bool)] = [(.main, state.mainClips, state.mainHidden)]
        for (index, lane) in state.overlayTracks.enumerated() { lanes.append((.overlay(index), lane.clips, lane.isHidden)) }
        var found: [(slot: TrackSlot, clip: EditClip)] = []
        for (slot, clips, hidden) in lanes where !hidden {
            for clip in ClipVisibility.visible(clips) where clip.contains(time: time) || abs(clip.timelineStart - time) < 0.001 {
                found.append((slot, clip))
            }
        }
        return found
    }

    /// The pictures that cover the canvas at `time`, with their entrance / exit motion of that moment. Not counted: a picture with
    /// transparency (where it is clear, what is below shows: that is its content, not its framing) and an image still converting
    /// (the builder leaves it out until it is ready).
    static func coveringPictures(in state: TimelineState, at time: Double, canvas: CGSize) -> [PictureCoverage.Picture] {
        onScreen(in: state, at: time).compactMap { _, clip in
            guard !clip.isAudioOnly, !clip.needsStillConversion, clip.sourceAlpha == .opaque else { return nil }
            return picture(clip, atTimeline: time, canvas: canvas, motion: motion(of: clip, in: state))
        }
    }

    /// The entrance / exit the builder draws for this clip: a V1 transition takes over its edge (`ClipPreset.effective`, with the
    /// same "is there a transition on that edge" the builder asks).
    static func motion(of clip: EditClip, in state: TimelineState) -> ResolvedClipPreset {
        let index = state.mainClips.firstIndex { $0.id == clip.id }
        let before = index.map { $0 > 0 && state.transitionOverlap(afterMainIndex: $0 - 1) > 0 } ?? false
        let after = index.map { state.transitionOverlap(afterMainIndex: $0) > 0 } ?? false
        return ClipPreset.effective(clip: clip, hasTransitionBefore: before, hasTransitionAfter: after)
    }
}

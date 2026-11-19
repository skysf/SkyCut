import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Edges of the delivery report's second tier found by review CXR2 (2026-11-19), on synthetic sound only:
// - R5: a cut one frame from either end at 60 fps. A split can keep a one-frame head or tail, and 1/60 s is shorter than the 0.02 s
//   gap the cut windows leave at a cut (CutSoundWindows), so the outer window comes out reversed. The window bounds are compared as
//   numbers before a range is built: the real inspect_video job finishes (it used to stop the app on a reversed ClosedRange), the
//   middle cut's jump is still reported, and only the two edge cuts, with no frame outside them to measure, are left out.
// One short real job (2 s, no voice): the binary links the debug build and has a 480 s deadline (SoundTierChecks).
// `SRTFLOW_INSPECTION_CASE=edges` runs only these.
@MainActor
enum DeliveryEdgeChecks {
    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let context = AICallContext(session: "delivery-edge-check", client: "Check", project: project.shortID, stopsWith: project.shortID)
        try await AICallContext.$current.withValue(context) {
            AIWorkspace.shared.register(root)
            try await oneFrameEdges(project, root: root, require: require)
        }
        windows(require: require)
    }

    // MARK: R5 — the real job

    /// 60 fps, 2 s: a one-frame head from source.mp4, rendered.mp4 past its black stretch, source.mp4 again from its second 2, and a
    /// one-frame tail from rendered.mp4 — three cuts between two files. Under them a loud noise bed to 1.0 s and a quiet one after.
    private static func oneFrameEdges(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        var noise = SoundTierChecks.Noise(seed: 23)
        let loud = try SoundTierChecks.wave(root, "edge-loud.wav", 1) { _ in noise.next(0.17) }
        let quiet = try SoundTierChecks.wave(root, "edge-quiet.wav", 1) { _ in noise.next(0.0012) }
        let a = root.appendingPathComponent("source.mp4"), b = root.appendingPathComponent("rendered.mp4")
        guard let infoA = await project.mediaProbes.probeVideo(a), let infoB = await project.mediaProbes.probeVideo(b) else {
            throw AIToolError("The pictures for the one-frame edges did not probe.")
        }
        let frame = 1.0 / 60
        func picture(_ url: URL, _ info: MediaInfo, from source: Double, _ length: Double, at start: Double) -> EditClip {
            EditClip(sourceURL: url, sourceStart: source, sourceDuration: length, timelineStart: start, isMuted: true, info: info)
        }
        var state = TimelineState()
        state.frameRate = .fps60
        state.mainClips = [picture(a, infoA, from: 0, frame, at: 0), picture(b, infoB, from: 5, 1 - frame, at: frame),
                           picture(a, infoA, from: 2, 1 - frame, at: 1), picture(b, infoB, from: 7, frame, at: 2 - frame)]
        state.audioTracks = [EditLane(clips: [SoundTierChecks.audio(loud, at: 0, 1, asset: 1),
                                              SoundTierChecks.audio(quiet, at: 1, 1, asset: 1)])]
        project.restoreTimeline(state)
        project.effectiveUndoManager!.removeAllActions()
        let cuts = AIDeliveryCutJumps.pictureCuts(project.state).map(\.time)
        require(cuts.count == 3 && abs(cuts[0] - frame) < 1e-9 && abs(cuts[2] - (2 - frame)) < 1e-9,
                "the one-frame head and tail are picture cuts at 60 fps (\(cuts))")
        let report = try await SoundTierChecks.inspect(project, ["sounds": ["A1": "ambience"]])
        let jumps = (report["findings"]?.arrayValue ?? []).filter { $0["kind"] == "audio_cut_jump" }
        require(jumps.count == 1 && jumps.first.map { abs(($0["at"]?.doubleValue ?? 0) - 1) < 0.001 } == true,
                "with a one-frame head and tail at 60 fps the real job finishes and still reports the middle cut's jump; only the two "
                    + "edge cuts, with no frame outside them to measure, are left out (\(jumps.map { $0.encodedString() }))")
    }

    // MARK: R5 — the windows on values

    private static func windows(require: (Bool, String) -> Void) {
        let frame = 1.0 / 60
        require(AIDeliveryCutJumps.windows(at: frame, duration: 2, fps: 60) == nil,
                "a cut one 60 fps frame after the start has nothing to measure before it (the windows' 0.02 s gap is longer)")
        require(AIDeliveryCutJumps.windows(at: 2 - frame, duration: 2, fps: 60) == nil,
                "a cut one 60 fps frame before the end has nothing to measure after it")
        let middle = AIDeliveryCutJumps.windows(at: 1, duration: 2, fps: 60)
        require(middle.map { abs($0.0.lowerBound - 0.68) < 1e-9 && abs($0.0.upperBound - 0.98) < 1e-9
                    && abs($0.1.lowerBound - 1.02) < 1e-9 && abs($0.1.upperBound - 1.32) < 1e-9 } == true,
                "a cut with room on both sides keeps its 0.3 s windows (\(String(describing: middle)))")
        let early = AIDeliveryCutJumps.windows(at: 0.02 + 2 * frame, duration: 2, fps: 60)
        require(early.map { abs($0.0.lowerBound) < 1e-9 && abs($0.0.upperBound - 2 * frame) < 1e-9 } == true,
                "a side holding two frames is still measured, clipped at the timeline's start (\(String(describing: early)))")
    }
}

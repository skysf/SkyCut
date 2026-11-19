import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Edges of the delivery report's second tier found by review CXR2 (2026-11-19), on synthetic sound only:
// - R5: a cut one frame from either end at 60 fps. A split can keep a one-frame head or tail, and 1/60 s is shorter than the 0.02 s
//   gap the cut windows leave at a cut (CutSoundWindows), so the outer window comes out reversed. The window bounds are compared as
//   numbers before a range is built: the real inspect_video job finishes (it used to stop the app on a reversed ClosedRange), the
//   middle cut's jump is still reported, and only the two edge cuts, with no frame outside them to measure, are left out.
// - R7: an upper picture that fills the frame but is transparent (a web motion's title), under full opacity, or inside its fade /
//   entrance window does not hide the V1 cut under it; an opaque one still does. Rule cases on values, then the pair through the
//   production preparation (AIDeliverySound.prepare: real render, real cuts) and the cut_jumps rule as the registry runs it.
// - R8: the cap of 40 sounds past their picture applies inside the checked range: with 41 over the whole timeline, a range holding
//   only the last cut measures and reports that one, through the same preparation and the lingers rule.
// One short real job (2 s, no voice): the binary links the debug build and has a 480 s deadline (SoundTierChecks); the rest
// renders a few seconds of sound without a job. `SRTFLOW_INSPECTION_CASE=edges` runs only these.
@MainActor
enum DeliveryEdgeChecks {
    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let pictures = try await Pictures(project, root: root)
        let context = AICallContext(session: "delivery-edge-check", client: "Check", project: project.shortID, stopsWith: project.shortID)
        try await AICallContext.$current.withValue(context) {
            AIWorkspace.shared.register(root)
            try await oneFrameEdges(project, pictures: pictures, root: root, require: require)
        }
        windows(require: require)
        coverRules(require: require)
        try await coverPair(pictures, root: root, require: require)
        try await lateLinger(pictures, root: root, require: require)
    }

    /// source.mp4 (blue) and rendered.mp4 (blue past its black stretch at 3–4 s), probed once; pictures are muted.
    private struct Pictures {
        let a: URL, b: URL, infoA: MediaInfo, infoB: MediaInfo

        init(_ project: VideoEditProject, root: URL) async throws {
            a = root.appendingPathComponent("source.mp4")
            b = root.appendingPathComponent("rendered.mp4")
            guard let infoA = await project.mediaProbes.probeVideo(a), let infoB = await project.mediaProbes.probeVideo(b) else {
                throw AIToolError("The pictures for the delivery edge checks did not probe.")
            }
            self.infoA = infoA
            self.infoB = infoB
        }

        /// From `a` (`second` false) or from `b` past its black stretch.
        func clip(second: Bool, from source: Double, _ length: Double, at start: Double) -> EditClip {
            EditClip(sourceURL: second ? b : a, sourceStart: source, sourceDuration: length, timelineStart: start, isMuted: true,
                     info: second ? infoB : infoA)
        }
    }

    // MARK: R5 — the real job

    /// 60 fps, 2 s: a one-frame head from source.mp4, rendered.mp4, source.mp4 again from its second 2, and a one-frame tail from
    /// rendered.mp4 — three cuts between two files. Under them a loud noise bed to 1.0 s and a quiet one after.
    private static func oneFrameEdges(_ project: VideoEditProject, pictures: Pictures, root: URL,
                                      require: (Bool, String) -> Void) async throws {
        var noise = SoundTierChecks.Noise(seed: 23)
        let loud = try SoundTierChecks.wave(root, "edge-loud.wav", 1) { _ in noise.next(0.17) }
        let quiet = try SoundTierChecks.wave(root, "edge-quiet.wav", 1) { _ in noise.next(0.0012) }
        let frame = 1.0 / 60
        var state = TimelineState()
        state.frameRate = .fps60
        state.mainClips = [pictures.clip(second: false, from: 0, frame, at: 0), pictures.clip(second: true, from: 5, 1 - frame, at: frame),
                           pictures.clip(second: false, from: 2, 1 - frame, at: 1), pictures.clip(second: true, from: 7, frame, at: 2 - frame)]
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

    // MARK: R7 — a picture over the cut that does not hide it

    /// V1 cuts from a.mp4 to b.mp4 at 3.0 s; a V2 picture from 2 to 4 s fills the 16:9 frame.
    private static func covered(_ cover: EditClip, under main: [EditClip]) -> TimelineState {
        var state = TimelineState()
        state.frameRate = .fps24
        state.canvasRatio = .wide16x9
        state.mainClips = main
        state.overlayTracks = [EditLane(clips: [cover])]
        return state
    }

    private static func coverRules(require: (Bool, String) -> Void) {
        let info = MediaInfo(duration: 20, displaySize: CGSize(width: 320, height: 180), frameRate: 24, videoCodec: "h264",
                             audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
        let main = [EditClip(sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"), sourceDuration: 3, isMuted: true, info: info),
                    EditClip(sourceURL: URL(fileURLWithPath: "/tmp/b.mp4"), sourceDuration: 3, timelineStart: 3, isMuted: true, info: info)]
        func cuts(_ change: (inout EditClip) -> Void) -> [Double] {
            var cover = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/title.mov"), sourceDuration: 2, timelineStart: 2, isMuted: true, info: info)
            change(&cover)
            return AIDeliveryCutJumps.pictureCuts(covered(cover, under: main)).map(\.time)
        }
        require(cuts { _ in } == [2, 4], "an opaque full-frame V2 hides the V1 cut under it and cuts in and out itself (\(cuts { _ in }))")
        let clear = cuts { $0.info?.alpha = .premultiplied }
        require(clear == [3], "a V2 with clear pixels (a web motion's title) leaves the V1 cut at 3.0 s; its own edges are no cuts (\(clear))")
        let faint = cuts { $0.opacity = 0.5 }
        require(faint == [3], "a V2 at half opacity leaves the V1 cut (\(faint))")
        let fading = cuts { $0.videoFadeInDuration = 1.5; $0.presetAnimation.entrance = .fade }
        require(fading == [3, 4], "a V1 cut inside V2's fade-in stays a cut; the fade-in is none, V2's hard end is (\(fading))")
        let wiping = cuts { $0.videoFadeInDuration = 1.5; $0.presetAnimation.entrance = .wipe }
        require(wiping == [3, 4], "a V1 cut while V2 wipes in stays a cut (\(wiping))")
    }

    /// The pair the review asked for: the place's bed drops 40 dB at the V1 cut, under an opaque full-frame V2 and under a
    /// transparent one of the same size. Production preparation and the cut_jumps rule, as the registry runs them.
    private static func coverPair(_ pictures: Pictures, root: URL, require: (Bool, String) -> Void) async throws {
        var noise = SoundTierChecks.Noise(seed: 29)
        let loud = try SoundTierChecks.wave(root, "cover-loud.wav", 3) { _ in noise.next(0.17) }
        let quiet = try SoundTierChecks.wave(root, "cover-quiet.wav", 3) { _ in noise.next(0.0012) }
        let main = [pictures.clip(second: false, from: 0, 3, at: 0), pictures.clip(second: true, from: 5, 3, at: 3)]
        let scope = AIInspection.Scope(ranges: [0 ... 6], duration: 6)
        func report(_ alpha: SourceAlpha) async throws -> (cuts: [Double], jumps: [Double]) {
            var cover = pictures.clip(second: false, from: 4, 2, at: 2)
            cover.info?.alpha = alpha
            var state = covered(cover, under: main)
            state.audioTracks = [EditLane(clips: [SoundTierChecks.audio(loud, at: 0, 3, asset: 3),
                                                  SoundTierChecks.audio(quiet, at: 3, 3, asset: 3)])]
            let prepared = try await AIDeliverySound.prepare(state, request: .init(tracks: ["A1": .ambience]), scope: scope, spoken: [],
                                                             token: ExportCancellationToken())
            let found = AIDeliveryCutJumps.findings(prepared.cuts, levels: prepared.levels, sounds: prepared.sounds,
                                                    speech: prepared.cameraSpeech, duration: prepared.duration, scope: scope)
            return (prepared.cuts.map(\.time), found.map(\.from))
        }
        let opaque = try await report(.opaque)
        require(opaque.cuts == [2, 4] && opaque.jumps.isEmpty,
                "under an opaque full-frame V2 the picture does not change at 3.0 s, so nothing is reported there (\(opaque))")
        let clear = try await report(.premultiplied)
        require(clear.cuts == [3] && clear.jumps == [3],
                "under a transparent V2 of the same size the V1 cut is checked and its 40 dB jump reported (\(clear))")
    }

    // MARK: R8 — the 41st sound past its picture

    /// 42 half-second shots alternating two files (41 cuts) and 41 named objects, each starting in its shot and ringing 0.25 s
    /// into the next, on two alternating tracks; a range holding only the last cut.
    private static func lateLinger(_ pictures: Pictures, root: URL, require: (Bool, String) -> Void) async throws {
        let clang = try SoundTierChecks.wave(root, "late-clang.wav", 0.7) { t in Float(0.3 * exp(-t / 0.3) * sin(2 * .pi * 600 * t)) }
        var state = TimelineState()
        state.frameRate = .fps24
        state.mainClips = (0 ..< 42).map { (index: Int) -> EditClip in
            let second = index % 2 == 1
            return pictures.clip(second: second, from: second ? 5 : 0, 0.5, at: Double(index) * 0.5)
        }
        state.audioTracks = [EditLane(clips: []), EditLane(clips: [])]
        for index in 0 ..< 41 {
            state.audioTracks[index % 2].clips.append(SoundTierChecks.audio(clang, at: Double(index) * 0.5 + 0.05, 0.7, asset: 0.7))
        }
        let request = AIDeliverySoundRoles.Request(tracks: ["A1": .object, "A2": .object])
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        let roles = AIDeliverySoundRoles.assign(request, state: state, config: config, provenance: .init())
        let cuts = AIDeliveryCutJumps.pictureCuts(state)
        let whole = AIDeliveryLinger.candidates(state, config: config, roles: roles, cuts: cuts,
                                                scope: .init(ranges: [0 ... 21], duration: 21))
        let lastPicked = whole.found.last?.cut ?? 0
        require(cuts.count == 41 && whole.found.count == 40 && whole.more == 1 && abs(lastPicked - 20) < 1e-9,
                "over the whole timeline the first 40 of 41 sounds past their picture are measured and one is counted as left out")
        let late = AIInspection.Scope(ranges: [20.25 ... 21], duration: 21)
        let picked = AIDeliveryLinger.candidates(state, config: config, roles: roles, cuts: cuts, scope: late)
        require(picked.found.map(\.cut) == [20.5] && picked.more == 0,
                "a range holding only the last cut picks its one sound and leaves nothing out (\(picked.found.map(\.cut)), \(picked.more))")
        let prepared = try await AIDeliverySound.prepare(state, request: request, scope: late, spoken: [], token: ExportCancellationToken())
        require(prepared.lingers.map(\.candidate.cut) == [20.5] && !prepared.limitations.contains { $0.hasPrefix("Only the first") },
                "the preparation measures only the sound inside the range, with no cap note (\(prepared.lingers.map(\.candidate.cut)))")
        let found = AIDeliveryLinger.findings(prepared.lingers, grid: prepared.levels.grid, scope: late)
        let foundAt: Double = found.first?.from ?? 0
        let frames: Double = found.first?.details["linger_frames"]?.doubleValue ?? 0
        require(found.count == 1 && abs(foundAt - 20.5) < 1e-9 && frames > 2,
                "the report has the 41st sound ringing past its picture (\(found.map(\.details)))")
    }
}

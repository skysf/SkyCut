import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The second-tier sound checks through the real inspect_video job (real renders, real voice check): synthetic sound only.
// Two pictures from two files cut at 3.0 s; under them A1 ambience (loud noise, then quiet noise), A2 an object (a decaying
// clang started inside the first picture, ringing 0.5 s past the cut), A3 a speech-like voice line, A4 loud noise under it,
// A5 music rising 20 dB in the middle of the line. With `sounds` naming them: a cut jump at 3.0, the clang lingering 12 frames,
// the line masked, the music swelling. A second timeline covers its cuts (a music bed at 3.0, a music accent at 6.0) and ends the
// clang a frame after the cut: nothing is reported. Two jobs only (the binary links the debug build and has a 480 s deadline);
// marks on second-tier findings and roles without `sounds` are checked on values in SoundTierRuleChecks. The edges review CXR2
// found (one-frame head and tail) are DeliveryEdgeChecks, run from here with one short job.
@MainActor
enum SoundTierChecks {
    static let roles: JSONValue = ["A1": "ambience", "A2": "object", "A3": "voice", "A4": "ambience", "A5": "music"]

    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        SoundTierRuleChecks.run(require: require)
        let context = AICallContext(session: "sound-tier-check", client: "Check", project: project.shortID, stopsWith: project.shortID)
        try await AICallContext.$current.withValue(context) {
            AIWorkspace.shared.register(root)
            try await verify(project, root: root, require: require)
        }
        // Review CXR2's edges (2026-11-19): one short job of its own.
        try await DeliveryEdgeChecks.run(project, root: root, require: require)
        // MCP-40's remaining rows (2026-11-19): rules on values, then the real preparation without a job.
        try await MusicRowChecks.run(project, root: root, require: require)
    }

    private static func verify(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let state = try await timeline(project, root: root)
        project.restoreTimeline(state)
        project.effectiveUndoManager!.removeAllActions()
        let before = project.state
        let first = try await inspect(project, ["sounds": roles])
        let findings = first["findings"]?.arrayValue ?? []
        func kinds(_ report: JSONValue) -> Set<String> { Set((report["findings"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }) }
        let jump = findings.first { $0["kind"] == "audio_cut_jump" }
        require(jump.map { abs(($0["at"]?.doubleValue ?? 0) - 3) < 0.001 && ($0["jump_db"]?.doubleValue ?? 0) <= -6 } == true,
                "the place's sound dropping at the 3.0 s cut with nothing over it is reported through the real tool (\(jump?.encodedString() ?? "none"))")
        let linger = findings.first { $0["kind"] == "audio_linger" }
        require(linger.map { ($0["linger_frames"]?.doubleValue ?? 0) >= 10 && abs(($0["from"]?.doubleValue ?? 0) - 3) < 0.001 } == true,
                "the clang named object rings past its picture's cut and is reported with its frames (\(linger?.encodedString() ?? "none"))")
        let masked = findings.first { $0["kind"] == "audio_voice_masked" }
        require(masked?["maskers"]?.arrayValue?.first?["layer"] == "A4" && masked?["verdict"] == "probably_unintelligible",
                "the voice check runs inside the report and names the noise as the main masker (\(masked?.encodedString() ?? "none"))")
        let swell = findings.first { $0["kind"] == "audio_music_swell" }
        require((swell?["rise_db"]?.doubleValue ?? 0) >= 15, "music rising under the line is reminded (\(swell?.encodedString() ?? "none"))")
        let checks = Set((first["checks"]?.arrayValue ?? []).compactMap(\.stringValue))
        require(checks.isSuperset(of: ["cut_jumps", "lingers", "voice", "music_swell", "music_drops", "music_timing", "music_edges", "abrupt"]),
                "the report names the second-tier checks")
        // MCP-40's remaining rows through the real job: the music here first plays at 3.5 s, quietly, under a picture from 0.
        let late = findings.first { $0["kind"] == "audio_music_late" }
        require(late.map { ($0["from"]?.doubleValue ?? 1) == 0 && ($0["to"]?.doubleValue ?? 0) > 3 } == true,
                "music first heard after 3 s of picture is late through the real tool (\(late?.encodedString() ?? "none"))")
        require(first["sound_roles"]?["A2"] == "object" && first["sound_roles"]?["V1"] == nil,
                "sound_roles shows what each track was taken to be (muted pictures have no sound)")
        require(findings.allSatisfy { $0["kind"]?.stringValue?.hasPrefix("audio_") != true || $0["loudest_layers"] != nil },
                "second-tier sound findings carry the loudest layers like the first tier")
        require(project.state == before && !project.effectiveUndoManager!.canUndo, "the second tier never edits the project")

        for wrong: JSONValue in [["A9": "music"], ["A1": "drums"]] {
            do { _ = try await inspect(project, ["sounds": wrong]); require(false, "\(wrong.encodedString()) must be refused") }
            catch { require(project.state == before, "a wrong sounds is refused before any job: \((error as? AIToolError)?.message ?? "")") }
        }
        if let key = jump?["key"]?.stringValue, let job = first["job_id"] {
            do {
                _ = try await AIInspectionTool.start(AIToolArguments(["intentional": ["job_id": job, "key": .string(key), "reason": "held breath"],
                                                                      "sounds": roles]), project)
                require(false, "sounds is an inspection field, refused next to intentional")
            } catch { require(project.state == before, "marking with an inspection field changes nothing") }
        } else { require(false, "the jump needs a key") }

        // Covered cuts, checked only from 2.5 to 6.5 s (one job keeps the check quick): at 3.0 a music bed across the cut and a
        // clang ended a frame after it; at 6.0 quiet music (far too low to be a bed) with one low thump 2 frames after the cut.
        project.restoreTimeline(try await covered(project, root: root))
        let fixed = try await inspect(project, ["from": 2.5, "to": 6.5,
                                                "sounds": ["A1": "ambience", "A2": "object", "A3": "music", "A4": "music"]])
        require(!kinds(fixed).contains("audio_cut_jump") && !kinds(fixed).contains("audio_linger"),
                "a music bed covers the 3.0 s jump, an accent the 6.0 s one, and a clang ended a frame after its cut no longer lingers (\(kinds(fixed).sorted()))")
        // The same bed stops hard at 4.0 s, 24 frames after the cut at 3.0: a hard music stop off the picture (MCP-40).
        let stop = (fixed["findings"]?.arrayValue ?? []).first { $0["kind"] == "audio_music_edge" }
        require(stop.map { abs(($0["at"]?.doubleValue ?? 0) - 4) < 0.001 && $0["edge"] == "out" } == true,
                "a music bed stopping hard between cuts is reported through the real tool (\(stop?.encodedString() ?? "none"))")
    }

    // MARK: The timeline

    private static func pictures(_ project: VideoEditProject, root: URL, _ names: [String]) async throws -> [EditClip] {
        var clips: [EditClip] = []
        for (index, name) in names.enumerated() {
            let url = root.appendingPathComponent(name)
            guard let info = await project.mediaProbes.probeVideo(url) else { throw AIToolError("\(name) did not probe.") }
            // Each picture from a second into its file: clear of rendered.mp4's black stretch (3–4 s).
            clips.append(EditClip(sourceURL: url, sourceStart: name == "rendered.mp4" ? 5 : 0, sourceDuration: 3,
                                  timelineStart: Double(index) * 3, isMuted: true, info: info))
        }
        return clips
    }

    static func audio(_ url: URL, at start: Double, _ duration: Double, asset: Double) -> EditClip {
        EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: duration, timelineStart: start, audioAssetDuration: asset)
    }

    /// Cut at 3.0 s; a 1.2 s speech-like line at 4.0 s under loud noise, music rising 20 dB at 4.6 s. The noise after the cut sits
    /// under −60 dBFS, so the voice check measures only the masker and the music (ESTOI runs unoptimized in this build).
    private static func timeline(_ project: VideoEditProject, root: URL) async throws -> TimelineState {
        var noise = Noise(seed: 7)
        let loud = try wave(root, "tier-loud.wav", 3) { _ in noise.next(0.17) }
        let quiet = try wave(root, "tier-quiet.wav", 3) { _ in noise.next(0.0012) }
        let clang = try wave(root, "tier-clang.wav", 1) { t in Float(0.3 * exp(-t / 0.3) * sin(2 * .pi * 600 * t)) }
        let voice = try wave(root, "tier-voice.wav", 1.2) { t in syllable(t) }
        let masker = try wave(root, "tier-masker.wav", 1.2) { _ in noise.next(0.8) }
        let music = try wave(root, "tier-music.wav", 2.5) { t in
            Float((t < 1.1 ? 0.0055 : 0.055) * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 880 * t)))
        }
        var state = TimelineState()
        state.frameRate = .fps24
        state.mainClips = try await pictures(project, root: root, ["source.mp4", "cuts-source.mp4"])
        state.audioTracks = [
            EditLane(clips: [audio(loud, at: 0, 3, asset: 3), audio(quiet, at: 3, 3, asset: 3)]),
            EditLane(clips: [audio(clang, at: 2.5, 1, asset: 1)]),
            EditLane(clips: [audio(voice, at: 4, 1.2, asset: 1.2)]),
            EditLane(clips: [audio(masker, at: 4, 1.2, asset: 1.2)]),
            EditLane(clips: [audio(music, at: 3.5, 2.5, asset: 2.5)])
        ]
        return state
    }

    /// Cuts at 3.0 and 6.0 s, each a place jump of 20 dB or more, each covered: A3 music bed across 3.0 (−17 dBFS), A4 quiet music
    /// (−43 dBFS) with a 60 Hz thump 2 frames after 6.0; A2's clang ends a frame after 3.0.
    private static func covered(_ project: VideoEditProject, root: URL) async throws -> TimelineState {
        var noise = Noise(seed: 11)
        let loud = try wave(root, "tier-loud.wav", 3) { _ in noise.next(0.17) }
        let quiet = try wave(root, "tier-quiet.wav", 3) { _ in noise.next(0.0012) }
        let clang = try wave(root, "tier-clang.wav", 1) { t in Float(0.3 * exp(-t / 0.3) * sin(2 * .pi * 600 * t)) }
        let bed = try wave(root, "tier-bed.wav", 4) { t in Float(0.2 * sin(2 * .pi * 330 * t)) }
        let hit = 6 + 2.0 / 24 - 4.5
        let thump = try wave(root, "tier-thump.wav", 4.5) { t in
            Float(0.01 * sin(2 * .pi * 220 * t) + (t >= hit ? 0.6 * sin(2 * .pi * 60 * (t - hit)) * exp(-(t - hit) / 0.03) : 0))
        }
        var state = TimelineState()
        state.frameRate = .fps24
        state.mainClips = try await pictures(project, root: root, ["source.mp4", "cuts-source.mp4", "rendered.mp4"])
        state.audioTracks = [
            EditLane(clips: [audio(loud, at: 0, 3, asset: 3), audio(quiet, at: 3, 3, asset: 3), audio(loud, at: 6, 3, asset: 3)]),
            EditLane(clips: [audio(clang, at: 2.5, 0.54, asset: 1)]),
            EditLane(clips: [audio(bed, at: 0, 4, asset: 4)]),
            EditLane(clips: [audio(thump, at: 4.5, 4.5, asset: 4.5)])
        ]
        return state
    }

    /// The speech-like voice of the listen checks: 180 ms voiced syllables, 70 ms gaps, pitch around 140 Hz, three formants.
    private static func syllable(_ t: Double) -> Float {
        let inSyllable = t.truncatingRemainder(dividingBy: 0.25)
        guard inSyllable < 0.18 else { return 0 }
        let pitch = 140 + 15 * sin(2 * Double.pi * 3 * t)
        var value = 0.0
        for harmonic in 1 ... 24 {
            let frequency = pitch * Double(harmonic)
            let weight = [(500.0, 1.0), (1500.0, 0.5), (2500.0, 0.25)].reduce(0.0) { $0 + $1.1 / (1 + pow((frequency - $1.0) / 200, 2)) }
            value += weight * sin(2 * Double.pi * frequency * t)
        }
        return Float(0.08 * sin(Double.pi * inSyllable / 0.18) * value)
    }

    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ amplitude: Float) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    static func wave(_ root: URL, _ name: String, _ seconds: Double, _ sample: (Double) -> Float) throws -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let count = Int(seconds * 48_000)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0 ..< count { buffer.floatChannelData![0][index] = sample(Double(index) / 48_000) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    static func inspect(_ project: VideoEditProject, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        var args = extra
        args["image"] = false
        let started = try await AIInspectionTool.start(AIToolArguments(.object(args)), project)
        guard let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("Inspection did not start") }
        await VideoInspectionChecks.waitForTerminalJob(job)
        guard job.status == .done else { throw AIToolError(job.message ?? "Inspection did not finish") }
        let result = AIJobs.shared.json(job)
        if let path = result["auditions"]?.arrayValue?.first?["path"]?.stringValue {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        return result
    }
}

private extension JSONValue {
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        .object((objectValue ?? [:]).merging(other) { _, new in new })
    }
}

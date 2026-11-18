import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The second-tier sound checks through the real inspect_video job (real renders, real voice check): synthetic sound only.
// Two pictures from two files cut at 3.0 s; under them A1 ambience (loud noise, then quiet noise), A2 an object (a decaying
// clang started inside the first picture, ringing 0.5 s past the cut), A3 a speech-like voice line, A4 loud noise under it,
// A5 music rising 20 dB in the middle of the line. With `sounds` naming them: a cut jump at 3.0, the clang lingering 12 frames,
// the line masked, the music swelling. Fixed (a music bed across the cut, the clang ended a frame after it): neither the jump nor
// the linger. Without `sounds`: nothing SkyCut can't know (no linger, no voice check), the roles say other. Marks still apply.
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
        require(checks.isSuperset(of: ["cut_jumps", "lingers", "voice", "music_swell"]), "the report names the second-tier checks")
        require(first["sound_roles"]?["A2"] == "object" && first["sound_roles"]?["V1"] == nil,
                "sound_roles shows what each track was taken to be (muted pictures have no sound)")
        require(findings.allSatisfy { $0["kind"]?.stringValue?.hasPrefix("audio_") != true || $0["loudest_layers"] != nil },
                "second-tier sound findings carry the loudest layers like the first tier")
        require(project.state == before && !project.effectiveUndoManager!.canUndo, "the second tier never edits the project")

        let plain = try await inspect(project)
        require(!kinds(plain).contains("audio_linger") && !kinds(plain).contains("audio_voice_masked") && plain["sound_roles"]?["A3"] == "other",
                "without sounds an imported file is other: no linger, no voice check, and the roles say so")
        for wrong: JSONValue in [["A9": "music"], ["A1": "drums"]] {
            do { _ = try await inspect(project, ["sounds": wrong]); require(false, "\(wrong.encodedString()) must be refused") }
            catch { require(project.state == before, "a wrong sounds is refused before any job: \((error as? AIToolError)?.message ?? "")") }
        }

        guard let key = jump?["key"]?.stringValue, let job = first["job_id"] else { require(false, "the jump needs a key to mark"); return }
        do {
            _ = try await AIInspectionTool.start(AIToolArguments(["intentional": ["job_id": job, "key": .string(key), "reason": "held breath"],
                                                                  "sounds": roles]), project)
            require(false, "sounds is an inspection field, refused next to intentional")
        } catch { require(project.state == before, "marking with an inspection field changes nothing") }
        _ = try await AIInspectionTool.start(AIToolArguments(["intentional": ["job_id": job, "key": .string(key), "reason": "held breath"]]), project)
        let marked = try await inspect(project, ["sounds": roles])
        require(!kinds(marked).contains("audio_cut_jump")
                && (marked["intentional"]?.arrayValue ?? []).contains { $0["kind"] == "audio_cut_jump" && $0["intentional_reason"] == "held breath" },
                "a marked cut jump moves to the intentional list with its reason")
        _ = try await AIInspectionTool.start(AIToolArguments(["clear_intentional": .string(key)]), project)

        project.restoreTimeline(try await timeline(project, root: root, fixed: true))
        let fixed = try await inspect(project, ["sounds": roles.merging(["A6": "music"])])
        require(!kinds(fixed).contains("audio_cut_jump") && !kinds(fixed).contains("audio_linger"),
                "a music bed across the cut covers the jump; a clang ended a frame after the cut no longer lingers (\(kinds(fixed).sorted()))")
    }

    // MARK: The timeline

    private static func timeline(_ project: VideoEditProject, root: URL, fixed: Bool = false) async throws -> TimelineState {
        let picture = root.appendingPathComponent("source.mp4"), other = root.appendingPathComponent("cuts-source.mp4")
        guard let one = await project.mediaProbes.probeVideo(picture), let two = await project.mediaProbes.probeVideo(other) else {
            throw AIToolError("The synthetic pictures did not probe.")
        }
        var noise = Noise(seed: 7)
        let loud = try wave(root, "tier-loud.wav", 3) { _ in noise.next(0.17) }
        let quiet = try wave(root, "tier-quiet.wav", 3) { _ in noise.next(0.0055) }
        let clang = try wave(root, "tier-clang.wav", 1) { t in Float(0.3 * exp(-t / 0.3) * sin(2 * .pi * 600 * t)) }
        let voice = try wave(root, "tier-voice.wav", 2) { t in syllable(t) }
        let masker = try wave(root, "tier-masker.wav", 2) { _ in noise.next(0.8) }
        let music = try wave(root, "tier-music.wav", 2.5) { t in
            Float((t < 1.1 ? 0.0055 : 0.055) * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 880 * t)))
        }
        func audio(_ url: URL, at start: Double, _ duration: Double, asset: Double) -> EditClip {
            EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: duration, timelineStart: start, audioAssetDuration: asset)
        }
        var state = TimelineState()
        state.frameRate = .fps24
        state.mainClips = [EditClip(sourceURL: picture, sourceDuration: 3, isMuted: true, info: one),
                           EditClip(sourceURL: other, sourceDuration: 3, timelineStart: 3, isMuted: true, info: two)]
        state.audioTracks = [
            EditLane(clips: [audio(loud, at: 0, 3, asset: 3), audio(quiet, at: 3, 3, asset: 3)]),
            EditLane(clips: [audio(clang, at: 2.5, fixed ? 0.54 : 1, asset: 1)]),
            EditLane(clips: [audio(voice, at: 3.6, 2, asset: 2)]),
            EditLane(clips: [audio(masker, at: 3.6, 2, asset: 2)]),
            EditLane(clips: [audio(music, at: 3.5, 2.5, asset: 2.5)])
        ]
        if fixed {
            let bed = try wave(root, "tier-bed.wav", 6) { t in Float(0.2 * sin(2 * .pi * 330 * t)) }
            state.audioTracks.append(EditLane(clips: [audio(bed, at: 0, 6, asset: 6)]))
        }
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

    private struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ amplitude: Float) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    private static func wave(_ root: URL, _ name: String, _ seconds: Double, _ sample: (Double) -> Float) throws -> URL {
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

    private static func inspect(_ project: VideoEditProject, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
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

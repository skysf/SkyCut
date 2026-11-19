import AVFoundation
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// set_track duck_others_db through the real App objects (MCP-29, docs/architecture/audio-volume-curve.md section 5): a
// narration file with two lines (tone bursts with a pause between) on A1 and music on A2. The narration's lines come from its
// waveform (no transcript), the music's curve dips under them in one undo step, the exported mix (the audio engine's offline
// render, the same one the preview plays) is 10 dB quieter under a line than between them, calling again changes nothing
// (also for a sting only the shallow start of the first line's attack reaches), 0 takes every dip out in one more undo step,
// and the refusals leave the project as it was. Synthetic files only.
@MainActor enum SpeechDuckAppChecks {
    static func run(_ fixture: ParameterFixture, root: URL, require: (Bool, String) -> Void) async throws {
        let narration = root.appendingPathComponent("duck-narration.caf")
        let music = root.appendingPathComponent("duck-music.caf")
        try write(narration, seconds: 7) { time in
            (1...2).contains(time) || (4...5).contains(time) ? 0.3 * sin(2 * .pi * 1_000 * time) : 0
        }
        try write(music, seconds: 8) { time in 0.1 * sin(2 * .pi * 220 * time) }
        var state = TimelineState()
        state.mainMagnet = false
        let voice = EditClip(sourceURL: narration, isAudioOnly: true, sourceDuration: 7, timelineStart: 0, audioAssetDuration: 7)
        let bed = EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 8, timelineStart: 0, audioAssetDuration: 8)
        // A sting ending about a quarter of the way down the first line's attack (CXR2 R9: it stacked another dip per call).
        let sting = EditClip(sourceURL: music, isAudioOnly: true, sourceDuration: 0.7, timelineStart: 0, audioAssetDuration: 8)
        state.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [bed]), EditLane(clips: [sting])]
        fixture.reset(state)
        let before = fixture.project.state
        let undo = fixture.project.effectiveUndoManager!

        let result = try await duck(fixture, ["track": "A1", "duck_others_db": -10])
        require(result.changedProject && result.payload["lines"] == 2, "the narration's two lines come from its pauses")
        require(result.payload["lines_from"]?["pauses"]?.arrayValue?.count == 1, "the result says the lines came from pauses")
        let ducked = fixture.project.state.clip(with: bed.id)
        require(abs((ducked?.volumeLineDecibels(atTimeline: 1.5) ?? 0) + 10) < 1e-6, "the music sits 10 dB down under the first line")
        require(abs(ducked?.volumeLineDecibels(atTimeline: 3) ?? -1) < 1e-6, "the music is back up between the lines")
        require(abs((ducked?.volumeLineDecibels(atTimeline: 4.5) ?? 0) + 10) < 1e-6, "the music sits 10 dB down under the second line")
        require(fixture.project.state.clip(with: voice.id) == voice, "the narration itself does not dip")
        let stingEnd = fixture.project.state.clip(with: sting.id)?.volumeLineDecibels(atTimeline: 0.7) ?? 0
        require(stingEnd < -0.5 && stingEnd > -5, "the sting dips less than half way at its end (got \(stingEnd) dB)")
        let duckedState = fixture.project.state

        var musicOnly = fixture.project.state
        musicOnly.audioTracks[0].isHidden = true
        let mix = try await render(musicOnly, seconds: 7, root: root)
        let under = level(mix, from: 1.3, to: 1.7), between = level(mix, from: 2.9, to: 3.3)
        require(abs(between - under - 10) < 0.3, "the engine's mix is 10 dB quieter under a line (got \(between - under) dB)")

        let again = try await duck(fixture, ["track": "A1", "duck_others_db": -10])
        require(!again.changedProject && again.payload["already_at_depth"]?.arrayValue?.count == 2,
                "calling again with the same depth changes nothing (the bed and the sting)")
        let off = try await duck(fixture, ["track": "A1", "duck_others_db": 0])
        let flat = [bed.id, sting.id].allSatisfy { id in
            stride(from: 0.0, through: 7, by: 0.05).allSatisfy { time in
                let clip = fixture.project.state.clip(with: id)
                return clip.map { time > $0.timelineEnd || abs($0.volumeLineDecibels(atTimeline: time)) < 1e-6 } ?? false
            }
        }
        require(off.changedProject && flat, "duck_others_db 0 takes every dip out, the sting's too")
        undo.undo()
        require(fixture.project.state == duckedState, "one undo takes the 0 back")
        undo.undo()
        require(fixture.project.state == before && !undo.canUndo,
                "one more undo takes the whole duck back (the call that changed nothing left no empty step)")

        for (fields, why) in [(["track": "A1", "duck_others_db": -40] as [String: JSONValue], "out of range"),
                              (["track": "master", "duck_others_db": -10], "master"),
                              (["track": "A1", "duck_others_db": -10, "volume_db": -3], "mixed with volume_db"),
                              (["track": "A1", "duck_others_db": -10, "duck_tracks": "A1"], "the voice in duck_tracks")] {
            do {
                _ = try await duck(fixture, fields)
                require(false, "a bad request is refused: \(why)")
            } catch let error as AIToolError {
                require(fixture.project.state == before && !undo.canUndo, "a refused request (\(why)) changes nothing: \(error.message)")
            }
        }
        fixture.reset()
        print("PASS: set_track duck_others_db dips the other tracks under the voice's lines in one undo step")
    }

    /// As the router calls it: plan, then apply (which opens its own undo step, only when a curve changes).
    private static func duck(_ fixture: ParameterFixture, _ fields: [String: JSONValue]) async throws -> AIToolResult {
        let plan = try await AISpeechDuckTool.plan(AIToolArguments(.object(fields)), fixture.project)
        return try AISpeechDuckTool.apply(plan, fixture.project)
    }

    private static func write(_ url: URL, seconds: Double, sample: (Double) -> Double) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let count = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) { buffer.floatChannelData![0][index] = Float(sample(Double(index) / rate)) }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        try file!.write(from: buffer)
        file = nil
    }

    /// The export's mix of `state` (the audio engine offline: raw interleaved stereo f32 at 48 kHz), left channel.
    private static func render(_ state: TimelineState, seconds: Double, root: URL) async throws -> [Float] {
        let file = root.appendingPathComponent("duck-mix.f32")
        _ = try await ExportAudioMixdown.render(state: state, duration: seconds, to: file)
        let data = try Data(contentsOf: file)
        let interleaved = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
    }

    /// RMS level (dB) of `samples` (48 kHz) over [from, to) seconds.
    private static func level(_ samples: [Float], from: Double, to: Double) -> Double {
        let slice = samples[Int(from * 48_000)..<min(samples.count, Int(to * 48_000))]
        let power = slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, slice.count))
        return 10 * log10(power + 1e-24)
    }
}

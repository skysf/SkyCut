import AVFoundation
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// edit_clip voice_band_db through the real App objects (MCP-30, docs/architecture/sound-scenes.md section 5): a clip of
// 50 Hz + 1 kHz + 8 kHz on A1 gets voice_band_db -10 through edit_clip's own plan / apply; the result reports it, one undo
// takes it back, and the exported mix (the audio engine's offline render) has the 1 kHz tone about 10 dB down while 50 Hz and
// 8 kHz keep their level. Out of range changes nothing. Synthetic files only.
@MainActor enum VoiceBandAppChecks {
    static func run(_ fixture: ParameterFixture, root: URL, require: (Bool, String) -> Void) async throws {
        let url = root.appendingPathComponent("voice-band-tones.caf")
        try writeTones(url)
        var state = TimelineState()
        state.mainMagnet = false
        let clip = EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: 4, timelineStart: 0, audioAssetDuration: 4)
        state.audioTracks = [EditLane(clips: [clip])]
        fixture.reset(state)
        let before = fixture.project.state
        let undo = fixture.project.effectiveUndoManager!
        let id = AIShortIDs(state: before).short(clip.id)

        let plan = try await AIClipTools.plan(AIToolArguments(["clip_id": .string(id), "voice_band_db": -10]), fixture.project)
        let result = try AIClipTools.apply(plan, fixture.project)
        require(fixture.project.state.clip(with: clip.id)?.voiceBandDB == -10, "edit_clip voice_band_db lands on the clip")
        require(result.payload["applied"]?["voice_band_db"] == -10, "the result reports the applied voice_band_db")
        let plain = try await mix(before, root: root, name: "voice-band-plain")
        let cut = try await mix(fixture.project.state, root: root, name: "voice-band-cut")
        let drops = [50.0, 1_000.0, 8_000.0].map { tone(cut, $0) - tone(plain, $0) }
        require(abs(drops[0]) < 0.25 && abs(drops[2]) < 0.25, "the exported mix keeps 50 Hz and 8 kHz (changed \(drops[0]), \(drops[2]) dB)")
        require(abs(drops[1] + 10) < 0.6, "the exported mix has 1 kHz about 10 dB down (changed \(drops[1]) dB)")
        undo.undo()
        require(fixture.project.state == before && !undo.canUndo, "one undo takes the voice-band cut back")
        do {
            let bad = try await AIClipTools.plan(AIToolArguments(["clip_id": .string(id), "voice_band_db": -40]), fixture.project)
            _ = try AIClipTools.apply(bad, fixture.project)
            require(false, "voice_band_db -40 is refused")
        } catch let error as AIToolError {
            require(error.details["status"] == "invalid_parameter" && fixture.project.state == before && !undo.canUndo,
                    "an out-of-range voice_band_db changes nothing")
        }
        fixture.reset()
        print("PASS: edit_clip voice_band_db lowers only the voice band, preview and export alike")
    }

    /// 4 s of 50 Hz + 1 kHz + 8 kHz (each amplitude 0.2), mono 48 kHz.
    private static func writeTones(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let count = AVAudioFrameCount(4 * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) {
            let time = Double(index) / 48_000
            buffer.floatChannelData![0][index] = Float(0.2 * (sin(2 * .pi * 50 * time) + sin(2 * .pi * 1_000 * time) + sin(2 * .pi * 8_000 * time)))
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        try file!.write(from: buffer)
        file = nil
    }

    /// The export's mix of `state` (raw interleaved stereo f32, 48 kHz), left channel from 1 s to 3 s.
    private static func mix(_ state: TimelineState, root: URL, name: String) async throws -> ArraySlice<Float> {
        let file = root.appendingPathComponent("\(name).f32")
        _ = try await ExportAudioMixdown.render(state: state, duration: 4, to: file)
        let interleaved = try Data(contentsOf: file).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let left = stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
        return left[48_000..<min(left.count, 144_000)]
    }

    /// The amplitude (dB) of `frequency` in `samples` (48 kHz): one DFT bin over a whole number of its periods.
    private static func tone(_ samples: ArraySlice<Float>, _ frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (offset, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(offset) / 48_000
            real += Double(sample) * cos(phase)
            imaginary -= Double(sample) * sin(phase)
        }
        return 20 * log10((real * real + imaginary * imaginary).squareRoot() * 2 / Double(samples.count) + 1e-12)
    }
}

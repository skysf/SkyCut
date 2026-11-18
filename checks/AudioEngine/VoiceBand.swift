import AVFoundation
import Foundation
import SrtFlowCore

// Group 16 (2026-11-18, MCP-30): a clip's voice-band cut (EditClip.voiceBandDB → VoiceBandFilter in the render block;
// docs/architecture/sound-scenes.md section 5).
// 1. The filter on steady sines: lows (50, 100 Hz) and highs (8 kHz) keep their level, 1 kHz goes down by about the depth,
//    gain 1 is an all-pass (level flat at every frequency); filtering block by block = in one go.
// 2. Through the engine's offline render (the export's): a clip of 50 Hz + 1 kHz + 8 kHz with voice_band_db −10 against the
//    same clip without it — the 1 kHz tone drops, 50 Hz and 8 kHz stay.
// 3. Not structure: an engine built without the cut and given it through `updateGains` renders like one built with it.

func checkVoiceBand() {
    voiceBandFilterChecks()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-voiceband-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    guard let tones = writeThreeTones(folder.appendingPathComponent("three-tones.wav")) else {
        return check(false, "could not write the three-tone file")
    }
    voiceBandEngineChecks(tones)
}

/// Level change (dB) of a steady sine at `frequency` through the filter at `gain`, measured on the last half second.
private func filteredLevelChange(_ frequency: Double, gain: Float, block: Int = 48_000) -> Double {
    let count = 48_000
    let input = (0..<count).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    var left = input, right = input
    var filter = VoiceBandFilter()
    left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            var start = 0
            while start < count {
                let frames = min(block, count - start)
                filter.process(leftBuffer.baseAddress! + start, rightBuffer.baseAddress! + start, count: frames, from: gain, to: gain)
                start += frames
            }
        }
    }
    return rmsDB(left[24_000...]) - rmsDB(input[24_000...])
}

private func voiceBandFilterChecks() {
    let cut = Float(pow(10, -10.0 / 20))
    for frequency in [50.0, 100.0, 8_000.0] {
        let change = filteredLevelChange(frequency, gain: cut)
        check(abs(change) < 0.25, "a -10 dB voice-band cut keeps \(Int(frequency)) Hz (changed \(change) dB)")
    }
    let middle = filteredLevelChange(1_000, gain: cut)
    check(abs(middle + 10) < 0.6, "a -10 dB voice-band cut lowers 1 kHz by about 10 dB (got \(middle) dB)")
    for frequency in [50.0, 300.0, 1_000.0, 3_000.0, 8_000.0] {
        let change = filteredLevelChange(frequency, gain: 1)
        check(abs(change) < 0.01, "at gain 1 the split adds back up: \(Int(frequency)) Hz flat (changed \(change) dB)")
    }
    check(filteredLevelChange(1_000, gain: cut, block: 64) == middle, "filtering in 64-frame blocks = in one go")
}

/// 4 s of 50 Hz + 1 kHz + 8 kHz (each amplitude 0.2), stereo 48 kHz.
private func writeThreeTones(_ url: URL) -> URL? {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let frames = AVAudioFrameCount(4 * 48_000)
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    guard let file = try? AVAudioFile(forWriting: url, settings: settings),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData else { return nil }
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        let time = Double(index) / 48_000
        let sample = Float(0.2 * (sin(2 * .pi * 50 * time) + sin(2 * .pi * 1_000 * time) + sin(2 * .pi * 8_000 * time)))
        data[0][index] = sample
        data[1][index] = sample
    }
    do { try file.write(from: buffer) } catch { return nil }
    return url
}

/// The amplitude (dB) of `frequency` in `samples` (48 kHz): one DFT bin over a whole number of its periods.
private func toneLevel(_ samples: ArraySlice<Float>, _ frequency: Double) -> Double {
    var real = 0.0, imaginary = 0.0
    for (offset, sample) in samples.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(offset) / 48_000
        real += Double(sample) * cos(phase)
        imaginary -= Double(sample) * sin(phase)
    }
    return 20 * log10((real * real + imaginary * imaginary).squareRoot() * 2 / Double(samples.count) + 1e-12)
}

private func voiceBandEngineChecks(_ tones: URL) {
    var plain = baseState()
    plain.audioTracks = [EditLane(clips: [audioClip(tones, duration: 4)])]
    var cut = plain
    cut.audioTracks[0].clips[0].voiceBandDB = -10
    let plainConfig = AudioEngineConfig.make(from: plain), cutConfig = AudioEngineConfig.make(from: cut)
    check(TimelineAudioEngine.sameStructure(plainConfig, cutConfig), "the voice-band cut is not structure (no stream reopened)")
    guard let before = enginePCM(plain)?.pcm, let after = enginePCM(cut)?.pcm else { return check(false, "the engine renders both") }
    let window = Int(1.0 * 48_000)..<Int(3.0 * 48_000)
    let drops = [50.0, 1_000.0, 8_000.0].map { toneLevel(after.left[window], $0) - toneLevel(before.left[window], $0) }
    check(abs(drops[0]) < 0.25, "through the engine the 50 Hz tone keeps its level (changed \(drops[0]) dB)")
    check(abs(drops[1] + 10) < 0.6, "through the engine the 1 kHz tone goes down about 10 dB (changed \(drops[1]) dB)")
    check(abs(drops[2]) < 0.25, "through the engine the 8 kHz tone keeps its level (changed \(drops[2]) dB)")
    guard let engine = try? TimelineAudioEngine(config: plainConfig, mode: .offline) else { return check(false, "engine without the cut") }
    engine.updateGains(config: cutConfig)
    var updated = Stereo()
    do {
        try engine.renderOffline(duration: cut.duration) { interleaved, frames in
            updated.append(interleaved: interleaved, frames: frames)
            return true
        }
    } catch {
        return check(false, "the updated engine renders: \(error)")
    }
    check(abs(toneLevel(updated.left[window], 1_000) - toneLevel(after.left[window], 1_000)) < 0.01,
          "a cut given through updateGains sounds like an engine built with it")
}

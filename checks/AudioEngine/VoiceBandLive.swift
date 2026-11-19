import AVFoundation
import Foundation
import SrtFlowCore

// Group 16b (2026-11-19, review CXR2 R10): the voice band changed while the stream plays, through the engine in continuous
// blocks (docs/architecture/sound-scenes.md section 5, rule 3). Two layers of the same 300 Hz tone, in phase, on A1 and A2,
// both at 0 dB; after 1 s A1 gets voice_band_db −10 through `updateGains`, after 2 s it is set back to 0.
// 1. Back at 0 the filter fades out to the dry sound and stops, so once the fade is over the live mix is the export's (both
//    layers at 0 dB, rendered from the start) sample for sample. Before the fix it kept running as an all-pass, 180° out of
//    phase at 300 Hz, and the live mix sat about 17 dB under the export's.
// 2. Neither change clicks: no sample-to-sample step around them is larger than the steady tone's own. Before the fix the
//    filter started from rest mid-stream, a jump of about half the signal.

func checkVoiceBandLive(in folder: URL) {
    guard let tone = writeTone(folder.appendingPathComponent("tone-300.wav"), frequency: 300) else {
        return check(false, "could not write the 300 Hz tone")
    }
    var plain = baseState()
    plain.audioTracks = [EditLane(clips: [audioClip(tone, duration: 4)]), EditLane(clips: [audioClip(tone, duration: 4)])]
    var cut = plain
    cut.audioTracks[0].clips[0].voiceBandDB = -10
    let plainConfig = AudioEngineConfig.make(from: plain), cutConfig = AudioEngineConfig.make(from: cut)
    guard let export = enginePCM(plain)?.pcm, let engine = try? TimelineAudioEngine(config: plainConfig, mode: .offline) else {
        return check(false, "the engine renders the two layers")
    }
    // A change made after the block that passes 1 s (2 s) reaches the stream with the next block.
    let block = TimelineAudioEngine.offlineQuantum
    let on = (48_000 / block + 1) * block, off = (96_000 / block + 1) * block
    var live = Stereo()
    do {
        try engine.renderOffline(duration: plain.duration) { interleaved, frames in
            live.append(interleaved: interleaved, frames: frames)
            if live.frames == on { engine.updateGains(config: cutConfig) }
            if live.frames == off { engine.updateGains(config: plainConfig) }
            return true
        }
    } catch {
        return check(false, "the live engine renders: \(error)")
    }
    guard live.frames >= off + 2 * block, export.frames >= live.frames else { return check(false, "both mixes rendered 4 s") }

    let cutLevel = rmsDB(live.left[(on + block)..<off]), plainLevel = rmsDB(export.left[(on + block)..<off])
    check(cutLevel < plainLevel - 3, "the cut set while playing is heard at once (live \(cutLevel) dBFS, export \(plainLevel) dBFS)")
    // After the block that set it back to 0 (the gain ramp and the fade are inside it), to the end.
    let settled = (off + block)..<live.frames
    let worst = settled.map { abs(live.left[$0] - export.left[$0]) }.max() ?? 1
    let levels = String(format: "live %.2f dBFS, export %.2f dBFS", rmsDB(live.left[settled]), rmsDB(export.left[settled]))
    check(worst == 0, "voice_band_db set back to 0 while playing: once faded out the live mix is the export's (\(levels), "
        + "worst sample \(worst))")

    let steady = largestStep(export.left[24_000..<48_000])
    for (label, change) in [("on", on), ("back to 0", off)] {
        let around = largestStep(live.left[(change - 256)..<(change + block + 256)])
        check(around <= steady * 1.5, "voice_band_db \(label) while playing does not click (largest step \(around), "
            + "the steady tone's \(steady))")
    }
}

/// The largest sample-to-sample step in `samples`.
private func largestStep(_ samples: ArraySlice<Float>) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

/// 4 s of a sine at `frequency` (amplitude 0.2), stereo 48 kHz.
private func writeTone(_ url: URL, frequency: Double) -> URL? {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let frames = AVAudioFrameCount(4 * 48_000)
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    guard let file = try? AVAudioFile(forWriting: url, settings: settings),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData else { return nil }
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        let sample = Float(0.2 * sin(2 * .pi * frequency * Double(index) / 48_000))
        data[0][index] = sample
        data[1][index] = sample
    }
    do { try file.write(from: buffer) } catch { return nil }
    return url
}

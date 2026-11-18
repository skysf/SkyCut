import Foundation
import SrtFlowMCPKit

// listen's peak and loudest moment from the samples (AIListenSampleFrames / AIListenPeaks / AIListenFrameGrid; 2026-11-17,
// docs/bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md). Pure values, synthetic signals:
// - an 80 s bed with one loud 40 ms hit at 41.3 s: loudest_at is the start of the hit's frame (41.292 at 24 fps), not the
//   middle of the 5 s curve step (42.5, what listen said before);
// - a 12 kHz tone read 45° off its crest: peak_db is the crest (true peak), not the samples 3 dB under it;
// - a clip's gains decide which frame is loudest, and a clip's frames are its timeline frames mapped through its speed;
// - window edges never invent a peak: a tone cut mid-wave reads its own crest.
// The real-file path (one bounded read, the reader tally) is in ListenRangeChecks.swift.

func runListenPeakChecks() {
    checkFrameGrid()
    checkLoudestFrameOnLongClip()
    checkTruePeakBetweenSamples()
    checkClipGainsAndSpeed()
    checkWindowEdges()
}

private let peakRate = 48_000.0

/// Frames over [from, to) with interleaved stereo samples from `sample(time)` (the same value on both channels).
private func measured(from: Double, to: Double, fps: Int, _ sample: (Double) -> Double) -> AIListenSampleFrames {
    let grid = AIListenFrameGrid(fps: fps)
    var frames = AIListenSampleFrames(seconds: grid.bounds(from: from, to: to), start: from, rate: peakRate, channels: 2)
    let count = Int(((to - from) * peakRate).rounded())
    var buffer = [Float](repeating: 0, count: 4_096 * 2)
    var done = 0
    while done < count {
        let chunk = min(4_096, count - done)
        for index in 0 ..< chunk {
            let value = Float(sample(from + Double(done + index) / peakRate))
            buffer[2 * index] = value
            buffer[2 * index + 1] = value
        }
        buffer.withUnsafeBufferPointer { frames.append(UnsafeBufferPointer(rebasing: $0[0 ..< chunk * 2]), frames: chunk) }
        done += chunk
    }
    frames.finish()
    return frames
}

private func fileReport(from: Double, to: Double, fps: Int, _ sample: (Double) -> Double) -> AIListenPeaks {
    let frames = measured(from: from, to: to, fps: fps, sample)
    let starts = Array(AIListenFrameGrid(fps: fps).bounds(from: from, to: to).dropLast())
    return AIListenPeaks.measure(frames, starts: starts, time: { from + Double($0) / peakRate })
}

private func checkFrameGrid() {
    let bounds = AIListenFrameGrid(fps: 24).bounds(from: 0.03, to: 0.2)
    checkEqual(bounds.count, 6, "0.03–0.2 s at 24 fps: the window's start, four frame starts, its end")
    check(abs(bounds[1] - 1.0 / 24) < 1e-12 && bounds.first == 0.03 && bounds.last == 0.2, "frame starts are k / fps; the window's own edges cap them")
    checkEqual(AIListenFrameGrid(fps: 30).bounds(from: 1, to: 1.1).count, 4, "a window starting on a frame does not repeat it")
}

private func checkLoudestFrameOnLongClip() {
    // 80 s bed at 0.1, a 0.6 hit for 40 ms from 41.3 s: the walkthrough's 80 s library track.
    let hitStart = 41.3
    let peaks = fileReport(from: 0, to: 80, fps: 24) { time in
        let amplitude = (hitStart ..< hitStart + 0.04).contains(time) ? 0.6 : 0.1
        return amplitude * sin(2 * .pi * 440 * time)
    }
    let frameStart = (hitStart * 24).rounded(.down) / 24
    check(abs((peaks.loudestAt ?? -1) - frameStart) < 1e-9,
          "an 80 s clip's loudest_at is the hit's frame start \(frameStart) (got \(String(describing: peaks.loudestAt)); a 5 s curve step's middle would be 42.5)")
    check((peaks.peakAt ?? -1) >= hitStart && (peaks.peakAt ?? 99) < hitStart + 0.04, "peak_at lies in the hit (got \(String(describing: peaks.peakAt)))")
    check(abs(peaks.truePeakDB - 20 * log10(0.6)) < 0.05, "peak_db is the hit's crest (got \(peaks.truePeakDB))")
}

private func checkTruePeakBetweenSamples() {
    // 12 kHz read 45° off its crest: every sample is 3 dB under the crest.
    let peaks = fileReport(from: 0, to: 1, fps: 30) { time in 0.5 * sin(2 * .pi * 12_000 * time + .pi / 4) }
    check(abs(peaks.truePeakDB - 20 * log10(0.5)) < 0.25,
          "peak_db is the true peak (−6.0 dBTP), not the samples 3 dB under it (got \(peaks.truePeakDB))")
}

private func checkClipGainsAndSpeed() {
    // Two hits a second apart in the source; the clip (double speed, from timeline 10) turns the first one down 12 dB with
    // its volume curve (source seconds): the second is the louder one heard.
    var clip = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/peaks.wav"), isAudioOnly: true, sourceDuration: 4, speed: 2,
                        timelineStart: 10, audioAssetDuration: 4)
    clip.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 0, value: -12), Keyframe(time: 1.4, value: -12),
                                            Keyframe(time: 1.6, value: 0), Keyframe(time: 4, value: 0)])
    let grid = AIListenFrameGrid(fps: 24).clip(clip, window: (from: 10, to: 12), trackGain: 1)
    check(grid.sourceBounds.count == 49 && abs(grid.sourceBounds[1] - 2.0 / 24) < 1e-9 && abs((grid.sourceBounds.last ?? 0) - 4) < 1e-9,
          "a clip's frames are its timeline frames mapped through its speed (48 frames, source 0–4 s)")
    var frames = AIListenSampleFrames(seconds: grid.sourceBounds, start: 0, rate: peakRate, channels: 2)
    let count = Int(4 * peakRate)
    var buffer = [Float](repeating: 0, count: count * 2)
    for index in 0 ..< count {
        let time = Double(index) / peakRate
        let hit = (1.0 ..< 1.04).contains(time) || (2.0 ..< 2.04).contains(time)
        let value = Float((hit ? 0.5 : 0.05) * sin(2 * .pi * 440 * time))
        buffer[2 * index] = value
        buffer[2 * index + 1] = value
    }
    let heard = buffer.withUnsafeBufferPointer { grid.sampleGain.applying(to: $0, from: 0, rate: peakRate, channels: 2) }
    heard.withUnsafeBufferPointer { frames.append($0, frames: count) }
    frames.finish()
    let peaks = AIListenPeaks.measure(frames, starts: grid.starts) { clip.timelineTime(atSource: Double($0) / peakRate) }
    // Source 2.0 s at double speed from timeline 10 = timeline 11.0, a frame start at 24 fps.
    check(abs((peaks.loudestAt ?? -1) - 11.0) < 1e-9, "the louder heard hit's frame (timeline 11.0) is loudest_at (got \(String(describing: peaks.loudestAt)))")
    check(abs((peaks.peakAt ?? -1) - 11.0) < 0.03, "peak_at is on the timeline (got \(String(describing: peaks.peakAt)))")
    check(abs(peaks.truePeakDB - 20 * log10(0.5)) < 0.1, "the heard true peak is the full-volume hit's (got \(peaks.truePeakDB))")
}

private func checkWindowEdges() {
    // A loud tone cut mid-wave at both ends: the edges must not read as a step (zeros outside the window).
    let peaks = fileReport(from: 0.010_37, to: 0.213_9, fps: 30) { time in 0.8 * sin(2 * .pi * 997 * time + 1.3) }
    check(peaks.truePeakDB <= 20 * log10(0.8) + 0.02, "a window cut mid-wave reads its own crest, no edge overshoot (got \(peaks.truePeakDB))")
}

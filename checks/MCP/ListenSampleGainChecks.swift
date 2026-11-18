import Foundation
import SrtFlowMCPKit

// Within-frame automation must precede true-peak interpolation. Compare decoded-sample processing with the engine's
// own gain sampler, including fades, a fast curve, stereo, source trim, speed and irregular decoder chunk boundaries.
func runListenSampleGainChecks() {
    let rate = 48_000.0
    for kind in 0..<3 {
        var clip = EditClip(sourceURL: URL(fileURLWithPath: "/synthetic/envelope.wav"), isAudioOnly: true,
                            sourceStart: 2, sourceDuration: 4.0 / 24, timelineStart: 10)
        clip.speed = 2
        clip.volume = 0.7
        if kind == 0 { clip.fadeInDuration = clip.timelineDuration }
        if kind == 1 { clip.fadeOutDuration = clip.timelineDuration }
        if kind == 2 {
            clip.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 2, value: -40),
                Keyframe(time: 2.01, value: 0), Keyframe(time: 2.03, value: -30), Keyframe(time: 2.16, value: -6)])
        }
        let descriptor = AIListenFrameGrid(fps: 24).clip(clip, window: (clip.timelineStart, clip.timelineEnd), trackGain: 0.5)
        let count = Int((clip.sourceDuration * rate).rounded())
        let source = sampleGainSignal(kind, count: count, rate: rate)
        let expected = engineSampleGain(source, clip: clip, rate: rate)
        let whole = source.withUnsafeBufferPointer {
            descriptor.sampleGain.applying(to: $0, from: clip.sourceStart, rate: rate, channels: 2)
        }
        check(whole == expected, "listen samples equal the actual engine envelope (case \(kind))")
        var chunks: [Float] = []
        var offset = 0
        while offset < count {
            let last = min(count, offset + 317)
            let heard = source.withUnsafeBufferPointer {
                descriptor.sampleGain.applying(to: UnsafeBufferPointer(rebasing: $0[offset * 2..<last * 2]),
                                              from: clip.sourceStart + Double(offset) / rate, rate: rate, channels: 2)
            }
            chunks += heard
            offset = last
        }
        check(zip(chunks, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "decoder chunk boundaries do not move the gain envelope")
        var frames = AIListenSampleFrames(seconds: descriptor.sourceBounds, start: clip.sourceStart, rate: rate, channels: 2)
        chunks.withUnsafeBufferPointer { frames.append($0, frames: count) }
        frames.finish()
        let report = AIListenPeaks.measure(frames, starts: descriptor.starts) {
            clip.timelineTime(atSource: clip.sourceStart + Double($0) / rate)
        }
        if kind == 0 {
            check(report == AIListenPeaks(truePeakDB: -60, peakAt: nil, loudestAt: nil), "fade-in start impulse is silent before interpolation")
        } else if kind == 1 {
            check(report.truePeakDB == -60, "fade-out's last-sample impulse is measured after its near-zero gain")
            check(report.peakAt.map { $0 >= clip.timelineStart && $0 < clip.timelineEnd } == true, "faded peak time respects speed and trim")
        } else {
            var reference = AIListenSampleFrames(seconds: descriptor.sourceBounds, start: clip.sourceStart, rate: rate, channels: 2)
            expected.withUnsafeBufferPointer { reference.append($0, frames: count) }
            reference.finish()
            checkNear(report.truePeakDB, TruePeak.decibels(reference.frames.map(\.peak).max() ?? 0),
                      "rapid automation is applied before interpolation, not to the raw frame maximum")
            check(report.peakAt.map { $0 >= clip.timelineStart && $0 < clip.timelineEnd } == true, "rapid-curve peak time is in the clip")
        }
    }
}

private func sampleGainSignal(_ kind: Int, count: Int, rate: Double) -> [Float] {
    var source = [Float](repeating: 0, count: count * 2)
    for frame in 0..<count {
        let value: Float
        if kind == 0 { value = frame == 0 ? 0.8 : 0 }
        else if kind == 1 { value = frame == count - 1 ? 0.8 : 0 }
        else { value = Float(0.8 * sin(2 * .pi * 12_000 * Double(frame) / rate + .pi / 4)) }
        source[frame * 2] = value
        source[frame * 2 + 1] = value * 0.4
    }
    return source
}

private func engineSampleGain(_ source: [Float], clip: EditClip, rate: Double) -> [Float] {
    var table = GainTable()
    AudioGainRamps.addVolumeRamps(table: &table, clip: clip, fades: clip.audioFades, previousEnd: clip.timelineStart, gainScale: 1)
    let sampler = table.sampler()
    var expected = source
    for frame in 0..<(source.count / 2) {
        let gain = sampler.gain(at: clip.timelineTime(atSource: clip.sourceStart + Double(frame) / rate)) * 0.5
        for channel in 0..<2 { expected[frame * 2 + channel] *= gain }
    }
    return expected
}

import Foundation

// MARK: - 10c. True peak (TruePeak, ITU-R BS.1770-4 Annex 2) and the limiter holding it (pure values)
//
// The meter against sines whose real crest is known: steady sines from 100 Hz to 20 kHz at every phase read within the
// Recommendation filter's ripple of their amplitude (−0.4 … +0.25 dB; 997 Hz within 0.02 dB) and never under their sample
// peak; a 12 kHz sine read 45° off its crest (samples 3 dB under the crest) reads its crest. Spans are bit-identical
// however the stream is chunked, every frame gets one, short streams included.
// The limiter on the true-peak scale: hard signals (that 12 kHz sine, 19 kHz, white noise at +17 dBTP, a one-sample spike)
// come out with their true peak at the −1 dBTP ceiling within 0.01 dB and no sample over it; a sine whose samples stay
// under the ceiling but whose crest is over it is pulled down (a sample-peak limiter lets it through 3 dB hot).
// Since 2026-11-17 (docs/architecture/export-audio-mixdown.md section 2 item 3,
// docs/bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md).

private let truePeakRate = 48_000

private func truePeakSine(_ hz: Double, amplitude: Double, phase: Double, seconds: Double) -> [Float] {
    let frames = Int(seconds * Double(truePeakRate))
    var out = [Float](repeating: 0, count: frames * 2)
    for i in 0 ..< frames {
        let value = Float(amplitude * sin(2 * .pi * hz * Double(i) / Double(truePeakRate) + phase))
        out[2 * i] = value
        out[2 * i + 1] = value
    }
    return out
}

/// All spans of a stereo signal (fed in `chunk`-frame pieces), the stream finished.
private func truePeakSpans(_ samples: [Float], chunk: Int? = nil) -> [TruePeak.Span] {
    var stream = TruePeak.Stream(channels: 2)
    var spans: [TruePeak.Span] = []
    let frames = samples.count / 2
    var start = 0
    samples.withUnsafeBufferPointer { whole in
        while start < frames {
            let count = min(chunk ?? frames, frames - start)
            stream.feed(UnsafeBufferPointer(rebasing: whole[(start * 2) ..< ((start + count) * 2)]), frames: count) { spans.append($0) }
            start += count
        }
    }
    stream.finish { spans.append($0) }
    return spans
}

private func truePeakDB(_ value: Float) -> Double { 20 * log10(Double(value)) }

func checkTruePeak() {
    group("10c. True peak (BS.1770 4× oversampling) and the limiter on the true-peak scale (pure values)")
    checkTruePeakMeter()
    checkTruePeakStream()
    checkTruePeakLimiter()
}

private func checkTruePeakMeter() {
    var worst = (low: 0.0, high: 0.0, label: ""), underSample = false
    for hz in [100.0, 997, 3000, 5000, 8000, 10000, 12000, 15000, 18000, 20000] {
        for step in 0 ..< 24 {
            let phase = Double(step) * 2 * .pi / 24
            // The middle of a steady sine: its start and end are steps of their own.
            let spans = Array(truePeakSpans(truePeakSine(hz, amplitude: 0.5, phase: phase, seconds: 0.1)).dropFirst(200).dropLast(200))
            let peak = spans.map(\.peak).max() ?? 0, sample = spans.map(\.sample).max() ?? 0
            let error = truePeakDB(peak) - truePeakDB(0.5)
            if error < worst.low { worst = (error, worst.high, "\(hz) Hz") }
            worst.high = max(worst.high, error)
            if peak < sample { underSample = true }
            if hz == 997, abs(error) > 0.02 { check(false, "997 Hz at phase \(phase): true peak \(error) dB off its amplitude") }
        }
    }
    check(worst.low >= -0.4 && worst.high <= 0.25,
          "steady sines 100 Hz–20 kHz at 24 phases read within −0.4 … +0.25 dB of their crest (got \(worst.low) at \(worst.label) … \(worst.high))")
    check(!underSample, "a true peak is never under the sample peak")
    let quarter = Array(truePeakSpans(truePeakSine(12_000, amplitude: 1, phase: .pi / 4, seconds: 0.1)).dropFirst(200).dropLast(200))
    let samplePeak = truePeakDB(quarter.map(\.sample).max() ?? 0), truePeak = truePeakDB(quarter.map(\.peak).max() ?? 0)
    check(abs(samplePeak + 3.01) < 0.01 && abs(truePeak) < 0.25,
          "12 kHz read 45° off its crest: samples −3.01 dB, true peak at the crest (got \(samplePeak) / \(truePeak) dB)")
    checkEqual(TruePeak.decibels(0), -60, "silence is −60 dBTP")
    check(TruePeak.decibels(2) > 6, "true peaks are not capped above (+6.02 dBTP for 2.0)")
}

private func checkTruePeakStream() {
    var seed: UInt32 = 11
    var noise = [Float](repeating: 0, count: 10_007 * 2)
    for index in noise.indices {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        noise[index] = Float(seed >> 8) / Float(1 << 24) - 0.5
    }
    let whole = truePeakSpans(noise)
    checkEqual(whole.count, 10_007, "one span per frame once the stream is finished")
    check(truePeakSpans(noise, chunk: 7) == whole && truePeakSpans(noise, chunk: 4_096) == whole,
          "spans are bit-identical whether fed in 7-frame, 4096-frame or one piece")
    for length in [1, 3, 6, 7] {
        checkEqual(truePeakSpans(Array(noise.prefix(length * 2))).count, length, "a \(length)-frame stream gets all its spans")
    }
    // The peak helper (MixBandMeter's per-frame peak) agrees with the stream on the same samples.
    let left = stride(from: 0, to: noise.count, by: 2).map { noise[$0] }, right = stride(from: 1, to: noise.count, by: 2).map { noise[$0] }
    let helper = TruePeak.peak(left: left, right: right, origin: 0, range: 3_000 ..< 4_000, valid: 0 ..< 10_007)
    let streamed = whole[3_000 ..< 4_000].map(\.peak).max() ?? 0
    check(helper.peak == streamed && helper.sample.map { whole[Int($0)].peak == streamed } == true,
          "TruePeak.peak over a range = the stream's spans there (\(helper.peak) vs \(streamed))")
}

private func checkTruePeakLimiter() {
    let ceiling = ExportPeakLimiter.defaultCeiling
    func limited(_ input: [Float]) -> ([Float], ExportPeakLimiter) {
        var limiter = ExportPeakLimiter(channels: 2, sampleRate: truePeakRate)
        var output: [Float] = []
        let frames = input.count / 2
        var start = 0
        input.withUnsafeBufferPointer { whole in
            while start < frames {
                let count = min(1_000, frames - start)
                limiter.process(UnsafeBufferPointer(rebasing: whole[(start * 2) ..< ((start + count) * 2)]), frames: count, into: &output)
                start += count
            }
        }
        limiter.flush(into: &output)
        return (output, limiter)
    }
    var noise = [Float](repeating: 0, count: truePeakRate * 2)
    var seed: UInt32 = 5
    for index in noise.indices {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        noise[index] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 8
    }
    var spike = [Float](repeating: 0.2, count: truePeakRate * 2)
    spike[24_000 * 2] = 2
    spike[24_000 * 2 + 1] = -2
    let cases: [(String, [Float])] = [
        ("12 kHz 45° off its crest, +6 dB", truePeakSine(12_000, amplitude: 2, phase: .pi / 4, seconds: 1)),
        ("19 kHz, +6 dB", truePeakSine(19_000, amplitude: 2, phase: 1.1, seconds: 1)),
        ("997 Hz, +6 dB", truePeakSine(997, amplitude: 2, phase: 0, seconds: 1)),
        ("white noise ×8", noise),
        ("a one-sample spike", spike)
    ]
    for (label, input) in cases {
        let (output, limiter) = limited(input)
        let outputPeak = truePeakSpans(output).map(\.peak).max() ?? 0
        let inputPeak = truePeakSpans(input).map(\.peak).max() ?? 0
        check(output.count == input.count && outputPeak <= ceiling * 1.0012 && output.allSatisfy { abs($0) <= ceiling },
              "\(label): true peak out at the −1 dBTP ceiling within 0.01 dB, no sample over it (got \(truePeakDB(outputPeak)) dBTP)")
        check(limiter.inputPeak == inputPeak, "\(label): the limiter reports the input's true peak (\(limiter.inputPeak) vs \(inputPeak))")
    }
    // Samples under the ceiling, crest over it: only a true-peak limiter acts.
    let hidden = truePeakSine(12_000, amplitude: 1.1, phase: .pi / 4, seconds: 1)
    let (hiddenOut, hiddenLimiter) = limited(hidden)
    check((hidden.map { abs($0) }.max() ?? 0) < ceiling, "the hidden-crest sine's samples are under the ceiling")
    // Every other interval holds a crest (the other half a zero crossing): half the frames are over.
    check(hiddenLimiter.overFrames >= truePeakRate / 2 - 8 && (truePeakSpans(hiddenOut).map(\.peak).max() ?? 0) <= ceiling * 1.0012,
          "a crest over the ceiling between samples is pulled down (\(hiddenLimiter.overFrames) frames over)")
    let limiter = ExportPeakLimiter(channels: 2, sampleRate: truePeakRate)
    checkEqual(limiter.latency, limiter.lookahead - 1 + TruePeak.lag, "the signal waits the lookahead plus the true-peak lag")
    checkEqual(ExportPeakLimiter.defaultLatency(sampleRate: truePeakRate), limiter.latency, "defaultLatency = latency")
}

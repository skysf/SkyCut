import Foundation
import SrtFlowMCPKit

// Music accents, stops and the end (MusicShape / MusicAccents / MusicStops), what the AI reads (AIMusicShapeReport) and the hit
// placement rule (AIClipHit.placement): production feedback MCP-43, docs/architecture/listening-engine.md section 9.
// A synthetic piece with known times: a pad, a kick every 0.6 s, a 2 s stop at 8.0, a big hit at 10.0 that brings it back,
// the end at 18.0 (silence to 20). Every kick is found within one hop (11.6 ms) of its attack (measured: 4 ms early to 7 ms
// late, the hop's grid), the big hit is the strongest, the stop runs
// from 8.0 to that hit, nothing is heard in the stop, the end is 18.0; the same piece 30 dB quieter reads the same; a sound that
// starts with a hit has an accent at its start; gaps between hits that only drop 25 dB are not stops; a silent piece has nothing.
// The real files of the production research (music1_box: 9.66 strongest, stop 7.5–9.5) are only on the research Mac; the numbers
// measured there are in the listening-engine doc. Built by scripts/check-mcp.sh.

func runMusicShapeChecks() {
    checkSyntheticSong()
    checkQuieterCopy()
    checkHitAtStart()
    checkShallowGaps()
    checkSilence()
    checkReport()
    checkHitPlacement()
}

private let songRate = 11_025.0
/// Accent times are on the analysis hop's grid.
private let hopSeconds = Double(MusicAccents.hop) / songRate

private struct SyntheticSong {
    var samples: [Float]
    var kicks: [Double]
    let stopFrom = 8.0
    let back = 10.0
    let end = 18.0
}

/// Uniform noise in -1...1 from a fixed seed: the same piece every run.
private func noise(_ random: inout SeededRandom) -> Float {
    Float(Double(random.next() >> 11) / Double(1 << 53)) * 2 - 1
}

private func syntheticSong(gain: Float = 1) -> SyntheticSong {
    var random = SeededRandom(seed: 43)
    var samples = (0..<Int(20 * songRate)).map { _ in 0.0001 * noise(&random) }
    func add(_ time: Double, _ seconds: Double, _ wave: (Double) -> Float) {
        let first = Int((time * songRate).rounded())
        for offset in 0..<Int(seconds * songRate) where first + offset < samples.count {
            samples[first + offset] += wave(Double(offset) / songRate)
        }
    }
    var random2 = SeededRandom(seed: 7)
    func kick(_ time: Double, _ amplitude: Float) {
        add(time, 0.25) { x in amplitude * Float(sin(2 * .pi * (55 + 65 * exp(-x * 30)) * x) * exp(-x * 14)) }
        add(time, 0.03) { x in amplitude * 0.3 * noise(&random2) * Float(exp(-x * 90)) }
    }
    var song = SyntheticSong(samples: [], kicks: [])
    for (from, to) in [(0.0, song.stopFrom), (song.back, song.end)] {
        add(from, to - from) { x in Float(0.03 * sin(2 * .pi * 220 * x) + 0.03 * sin(2 * .pi * 277.2 * x)) }
    }
    var time = 0.5
    while time < song.stopFrom - 0.25 { kick(time, 0.5); song.kicks.append(time); time += 0.6 }
    kick(song.back, 0.95)
    add(song.back, 0.6) { x in 0.25 * noise(&random2) * Float(exp(-x * 6)) }
    time = song.back + 0.6
    while time < song.end - 0.25 { kick(time, 0.5); song.kicks.append(time); time += 0.6 }
    song.samples = samples.map { $0 * gain }
    return song
}

private func checkSyntheticSong() {
    let song = syntheticSong()
    let shape = MusicShape.analyze(song.samples, sampleRate: songRate)
    for kick in song.kicks {
        let nearest = shape.accents.map { abs($0.time - kick) }.min() ?? .infinity
        check(nearest <= hopSeconds, "every kick is an accent within a hop of its attack (\(kick): \(nearest))")
    }
    let strongest = shape.accents.max { $0.strength < $1.strength }
    check(strongest.map { abs($0.time - song.back) <= hopSeconds } == true,
          "the hit that brings the music back is the strongest accent (\(String(describing: strongest)))")
    check(!shape.accents.contains { $0.time > song.stopFrom + 0.05 && $0.time < song.back - 0.05 },
          "nothing is heard while the music stops (the hiss under it is 70 dB down)")
    checkEqual(shape.stops.count, 1, "one stop")
    if let stop = shape.stops.first {
        check(abs(stop.from - song.stopFrom) <= 0.1, "the stop starts where the music stops (\(stop.from))")
        check(abs(stop.to - song.back) <= hopSeconds, "the stop ends on the hit that brings the music back (\(stop.to))")
    }
    check(shape.end.map { abs($0 - song.end) <= 0.15 } == true, "the end is where the music ends, not the file (\(String(describing: shape.end)))")
    check(abs(shape.duration - 20) < 0.001, "duration is the samples' length")
    let moved = shape.shifted(by: 1.5)
    check(moved.accents.first?.time == shape.accents.first.map { $0.time + 1.5 } && moved.stops.first?.from == shape.stops.first.map { $0.from + 1.5 }
          && moved.end == shape.end.map { $0 + 1.5 }, "shifted moves every time by the read's first timestamp")
}

/// Every rule is relative to the piece itself: 30 dB quieter, the same accents, strengths, stop and end.
private func checkQuieterCopy() {
    let loud = MusicShape.analyze(syntheticSong().samples, sampleRate: songRate)
    let quiet = MusicShape.analyze(syntheticSong(gain: 0.0316).samples, sampleRate: songRate)
    checkEqual(quiet.accents.count, loud.accents.count, "a quieter copy has the same accents")
    let drift = zip(loud.accents, quiet.accents).map { max(abs($0.time - $1.time), abs($0.strength - $1.strength) / 10) }.max() ?? 0
    check(drift < 0.001, "same times and strengths 30 dB down (worst \(drift))")
    checkEqual(quiet.stops, loud.stops, "same stop 30 dB down")
    checkEqual(quiet.end, loud.end, "same end 30 dB down")
}

/// A sound that starts with its hit (a generated impact): the accent is at its start, not somewhere in its tail.
private func checkHitAtStart() {
    var random = SeededRandom(seed: 3)
    let samples = (0..<Int(4 * songRate)).map { index -> Float in
        let x = Double(index) / songRate
        return Float(0.8 * sin(2 * .pi * 60 * x) * exp(-x * 3)) + 0.2 * noise(&random) * Float(exp(-x * 20))
    }
    let shape = MusicShape.analyze(samples, sampleRate: songRate)
    let strongest = shape.accents.max { $0.strength < $1.strength }
    check(strongest.map { $0.time <= 0.02 } == true, "a sound that starts with its hit has its strongest accent at the start (\(String(describing: strongest)))")
}

/// Staccato hits with gaps that drop about 25 dB: rhythm, not a stop (the production research's gaps sat 22–35 dB down).
private func checkShallowGaps() {
    var samples = [Float](repeating: 0, count: Int(12 * songRate))
    for index in samples.indices {
        let x = Double(index) / songRate
        let phase = x.truncatingRemainder(dividingBy: 1.5)
        let level: Float = phase < 0.8 ? 0.3 : 0.017  // 25 dB down for 0.7 s between hits
        samples[index] = level * Float(sin(2 * .pi * 110 * x))
    }
    let shape = MusicShape.analyze(samples, sampleRate: songRate)
    check(shape.stops.isEmpty, "gaps 25 dB down are not stops (\(shape.stops))")
}

private func checkSilence() {
    let shape = MusicShape.analyze([Float](repeating: 0, count: Int(3 * songRate)), sampleRate: songRate)
    check(shape.accents.isEmpty && shape.stops.isEmpty && shape.end == nil, "a silent piece has no accents, stops or end")
    checkEqual(MusicShape.analyze([], sampleRate: songRate), .silent, "no samples is silent")
}

/// What the AI reads: the window, the mapping, the cap, the order.
private func checkReport() {
    let accents = (0..<300).map { MusicShape.Accent(time: Double($0) * 0.5, strength: Double($0 % 7) + 3) }
        + [MusicShape.Accent(time: 40.25, strength: 30)]
    let shape = MusicShape.Analysis(accents: accents.sorted { $0.time < $1.time },
                                    stops: [MusicShape.Stop(from: 9, to: 11.2), MusicShape.Stop(from: 60, to: 62)], end: 149, duration: 150)
    let clip = AIMusicShapeReport.json(shape, sourceFrom: 10, sourceTo: 50, timeline: { $0 + 100 })
    let listed = clip["accents"]?.arrayValue ?? []
    checkEqual(listed.count, 81, "only the accents in source [10, 50)")
    checkEqual(listed.first?.arrayValue?.first?.doubleValue, 110, "a clip's accents are in timeline seconds")
    checkEqual(clip["strongest_accents"]?.arrayValue?.first?.doubleValue, 140.25, "the strongest first")
    checkEqual(clip["strongest_accents"]?.arrayValue?.count, AIMusicShapeReport.strongestCount, "five strongest")
    checkEqual(clip["stops"]?.arrayValue?.first?.arrayValue?.compactMap(\.doubleValue), [110, 111.2], "a stop is cut to the window")
    checkEqual(clip["stops"]?.arrayValue?.count, 1, "a stop outside the window is not listed")
    check(clip["ends_at"] == nil, "the end after the window is not listed")
    let file = AIMusicShapeReport.json(shape, sourceFrom: 0, sourceTo: 150, timeline: { $0 })
    checkEqual(file["accents"]?.arrayValue?.count, AIMusicShapeReport.maxAccents, "at most maxAccents accents")
    checkEqual(file["more_accents"]?.doubleValue, Double(accents.count - AIMusicShapeReport.maxAccents), "more_accents counts the weaker ones left out")
    let times = file["accents"]?.arrayValue?.compactMap { $0.arrayValue?.first?.doubleValue } ?? []
    checkEqual(times, times.sorted(), "accents are in time order")
    check(file["accents"]?.arrayValue?.contains { $0.arrayValue?.first?.doubleValue == 40.25 } == true, "the cap keeps the strongest")
    checkEqual(file["ends_at"]?.doubleValue, 149, "the end inside the window is listed")
    checkEqual(AIMusicShapeReport.strongest(shape, from: 41, to: 50)?.time, 41.5, "the strongest in a window (ties: the first)")
    check(AIMusicShapeReport.strongest(shape, from: 150, to: 151) == nil, "no accent in the window: nil")
}

/// start = hit_at − (hit − source_in); before 0:00 the clip starts later in its source, the hit still on hit_at.
private func checkHitPlacement() {
    let ahead = AIClipHit.placement(hitAt: 7.3, hit: 9.66, sourceIn: 0)
    check(ahead.start == 0 && abs(ahead.sourceIn - 2.36) < 1e-9, "hit 9.66 on 7.30: start 0, source_in 2.36 (\(ahead))")
    check(abs(ahead.start + (9.66 - ahead.sourceIn) - 7.3) < 1e-9, "the hit lands on hit_at")
    let later = AIClipHit.placement(hitAt: 20, hit: 9.66, sourceIn: 0)
    check(abs(later.start - 10.34) < 1e-9 && later.sourceIn == 0, "a later hit_at: start = hit_at − hit (\(later))")
    let trimmed = AIClipHit.placement(hitAt: 20, hit: 9.66, sourceIn: 5)
    check(abs(trimmed.start - 15.34) < 1e-9 && trimmed.sourceIn == 5, "a given source_in is kept when the start fits (\(trimmed))")
    let short = AIClipHit.placement(hitAt: 1, hit: 9.66, sourceIn: 5)
    check(short.start == 0 && abs(short.sourceIn - 8.66) < 1e-9, "a given source_in moves later when the start would be before 0 (\(short))")
    let effect = AISoundEffectRequest.placement(hitAt: 0.2, renderedHit: 0.6)
    check(effect.start == 0 && abs(effect.sourceIn - 0.4) < 1e-9, "sound effects use the same rule")
}

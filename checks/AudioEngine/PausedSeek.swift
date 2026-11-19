import AVFoundation
import Foundation

// A paused seek fills the new position before Play (manual rendering: CI has no sound card either). The realtime graph
// renders a paused quantum on every IO cycle; each one lets the rings take up a paused seek (`AudioRing.syncReader`), so
// the feeder can fill the new position and Play starts with sound from its first sample. Before 2026-11-20 a ring that
// was full when the seek came took no new data until the first playing render: every start lost its first quantum,
// and when the feeder ran late after an output start the sound lost 60–140 ms
// (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md).
func checkPausedSeekFillsRing(tone: URL) {
    do {
        let audio = try TimelineAudioEngine(config: AudioEngineConfig.make(from: plainLane(tone)), mode: .offline)
        defer { audio.stop() }
        let quantum = TimelineAudioEngine.offlineQuantum
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: quantum * 2)
        defer { samples.deallocate() }
        /// Renders one quantum with the feeder serviced at `frame` first (the realtime feeder thread's job): the leading
        /// silent frames (a 440 Hz tone is near zero for one sample at a crossing; an underrun silences the whole quantum).
        func render(at frame: Int64) throws -> (silent: Int, peak: Float) {
            let got = try audio.renderOfflineQuantum(at: frame, frames: quantum, into: samples)
            var silent = 0
            while silent < got, abs(samples[2 * silent]) < 0.001 { silent += 1 }
            let peak = (0..<got * 2).reduce(Float(0)) { max($0, abs(samples[$1])) }
            return (silent, peak)
        }
        try audio.beginOffline(atFrame: 0)
        var position: Int64 = 0
        var level: Float = 0
        for _ in 0..<6 {
            level = max(level, try render(at: position).peak)
            position += Int64(quantum)
        }
        check(audio.underrunFrames == 0, "Premise: the six quanta played from 0 have sound (\(audio.underrunFrames) frames underrun)")
        audio.pause()
        // Paused, the graph keeps rendering: the feeder tops the ring up to its capacity.
        _ = try render(at: position)
        let target = Int64(2 * TimelineAudioEngine.sampleRate)
        audio.seek(to: 2)
        for _ in 0..<2 { check(try render(at: target).peak == 0, "Quanta rendered while paused are silent") }
        let underruns = audio.underrunFrames
        audio.play(from: 2)
        let first = try render(at: target)
        check(audio.underrunFrames == underruns,
              "Play after a paused seek: the first quantum has data (\(audio.underrunFrames - underruns) frames underrun)")
        check(first.silent < 48 && first.peak > level / 2,
              "Play after a paused seek: sound from the first sample (\(first.silent) silent frames at the start, peak \(first.peak) against \(level))")
        audio.endOffline()
    } catch {
        check(false, "Paused seek ring check failed: \(error)")
    }
}

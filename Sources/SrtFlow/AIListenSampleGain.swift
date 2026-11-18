import Foundation

// Owns the clip gain applied to listen's decoded PCM before any statistics. Reuses the engine's gain table;
// does not decode, resample, meter, or apply effects / the master fader.
struct AIListenSampleGain: Sendable {
    private let clip: EditClip
    private let envelope: GainTable.Sampler
    private let trackGain: Float

    init(clip: EditClip, trackGain: Double) {
        self.clip = clip
        self.trackGain = Float(trackGain)
        var table = GainTable()
        AudioGainRamps.addVolumeRamps(table: &table, clip: clip, fades: clip.audioFades,
                                     previousEnd: clip.timelineStart, gainScale: 1)
        envelope = table.sampler()
    }

    func applying(to samples: UnsafeBufferPointer<Float>, from sourceStart: Double, rate: Double, channels: Int) -> [Float] {
        var heard = Array(samples)
        for frame in 0..<(samples.count / channels) {
            let time = clip.timelineTime(atSource: sourceStart + Double(frame) / rate)
            let gain = envelope.gain(at: time) * trackGain
            for channel in 0..<channels { heard[frame * channels + channel] *= gain }
        }
        return heard
    }
}

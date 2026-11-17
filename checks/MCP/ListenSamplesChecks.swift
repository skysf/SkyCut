import AVFoundation
import Foundation

// The real bounded reader's optional mono samples, as source-sound description consumes them. Synthetic float PCM only;
// the read audit belongs to the measured call, and independent left/right patterns make a wrong downmix visible.

@MainActor
func checkListenKeptSamples(in directory: URL) async {
    do {
        let rate = 48_000.0
        let url = directory.appendingPathComponent("synthetic-description-stereo.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for index in 0 ..< 96_000 {
            buffer.floatChannelData![0][index] = Float(index % 32) / 64
            buffer.floatChannelData![1][index] = Float(index % 13) / 32 - 0.25
        }
        try file?.write(from: buffer)
        file = nil
        let audit = MediaReadAudit()
        let reading = try await MediaReadAudit.$current.withValue(audit) {
            try await AIListenAudioWindow.read(url, from: 0.5, to: 1.25,
                                               until: Date().addingTimeInterval(listenCheckHangBound), keepsSamples: true)
        }
        let tally = ListenReadTally(audit.entries, file: url)
        check(tally.readsOnly(from: 0.5, to: 1.25) && tally.wholeFileRequests == 0 && tally.beatReads == 0,
              "keeping samples still starts exactly one bounded reader for this call")
        guard let samples = reading.samples else { check(false, "the requested source samples were not retained"); return }
        check(samples.count == 36_000 && samples.count == Int(reading.peaks.framesAvailable),
              "kept mono samples cover only the requested 0.75 s")
        let first = Int((reading.sourceStart * rate).rounded())
        let error = samples.enumerated().map { offset, value in
            let index = first + offset
            let expected = (Float(index % 32) / 64 + Float(index % 13) / 32 - 0.25) / 2
            return abs(value - expected)
        }.max() ?? .infinity
        check(error < 1e-6, "each retained frame is (left + right) / 2 at its original source time (error \(error))")
        let ordinary = try await AIListenAudioWindow.read(url, from: 0.5, to: 1.25,
                                                         until: Date().addingTimeInterval(listenCheckHangBound))
        check(ordinary.samples == nil, "ordinary level/peak reads do not retain source samples")
    } catch { check(false, "source-description sample reading failed: \(error)") }
}

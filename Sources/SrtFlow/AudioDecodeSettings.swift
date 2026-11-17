import AVFoundation
import Foundation

// MARK: - How SkyCut decodes a file's sound to measure it (AVAssetReader output settings)
//
// What: float, interleaved, the file's own sample rate, at most two channels (more are folded to stereo). `listen` reads
// files and clips this way (AIListenAudioWindow) and the exporter measures the delivered file this way
// (ExportDeliveredPeak), so `listen file=<the export>` and get_job's `audio_peak_dbtp` read the same samples.
// Not here: reading (those two), the waveform the timeline draws (WaveformStore, its own decoder).

enum AudioDecodeSettings {
    static func floatInterleaved(channels: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: min(2, max(1, channels))
        ]
        if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }
}

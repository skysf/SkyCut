import AVFoundation
import Foundation

// MARK: - The exported file's own true peak (what the encoder made of the limited mix)
//
// What: after ffmpeg has written the film, decode its sound track (AVAssetReader: float, interleaved, the file's own rate,
// at most two channels — AudioDecodeSettings, the decode `listen file=` uses) and take its true peak (TruePeak). The limiter holds the mix
// at −1 dBTP, but AAC swings past what it was given (2026-11-13 walkthrough: the mix stopped at −1 dBFS, the exported file
// read −0.5), so the delivered peak is measured on the delivered file, never assumed.
// Why: get_job used to report the peak *before* the limiter as `audio_peak_dbfs` (+5.6 on a mix whose file peaked at −0.5),
// which reads like a clipped file (docs/bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md).
// Where: VideoEditExporter right after ffmpeg, before the file moves into place; the blocking read runs on
// MediaReadQueue.export (never in the Swift concurrency pool, docs/architecture/blocking-media-reads.md).
// Not here: the mix and its levels (ExportAudioMixdown), what the AI and the panel say (ExportAudioReport, VideoEditExportStatus).

enum ExportDeliveredPeak {
    /// The true peak (linear) of `file`'s first sound track; nil when it has none, cannot be decoded or the export stopped.
    static func measure(_ file: URL, cancellation: ExportCancellationToken? = nil) async -> Float? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let formats = try? await track.load(.formatDescriptions) else { return nil }
        let channels = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
        nonisolated(unsafe) let sound = track
        return await MediaReadQueue.run(on: MediaReadQueue.export) {
            read(asset, track: sound, channels: Int(channels), cancellation: cancellation)
        }
    }

    /// Blocking: decode the whole track and run it through the true-peak meter. Only on a MediaReadQueue.
    private static func read(_ asset: AVURLAsset, track: AVAssetTrack, channels: Int, cancellation: ExportCancellationToken?) -> Float? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioDecodeSettings.floatInterleaved(channels: channels))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var meter: TruePeak.Stream?
        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            if cancellation?.isCancelled == true { return nil }
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
            let width = Int(description.mChannelsPerFrame), frames = CMSampleBufferGetNumSamples(buffer)
            var block: CMBlockBuffer?
            var list = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
            )
            guard status == noErr, width > 0, let data = list.mBuffers.mData,
                  Int(list.mBuffers.mDataByteSize) >= frames * width * MemoryLayout<Float>.size else { return nil }
            if meter == nil { meter = TruePeak.Stream(channels: width) }
            guard meter?.channels == width else { return nil }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * width)
            meter?.feed(samples, frames: frames) { peak = max(peak, $0.peak) }
        }
        guard reader.status == .completed else { return nil }
        meter?.finish { peak = max(peak, $0.peak) }
        return peak
    }
}

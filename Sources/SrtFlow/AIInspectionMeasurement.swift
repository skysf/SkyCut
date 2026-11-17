import AVFoundation
import Foundation
import SrtFlowMCPKit

// The existing stem measurement and bounded file reader feed tier-one rules. File measurements
// describe the actual export; layer attribution and limiter history explicitly describe the snapshot.
@MainActor
enum AIInspectionMeasurement {
    struct Outcome {
        var frames: [AIDeliveryMix.Frame]
        var timeline: [AIDeliveryMix.Frame]
        var summary: JSONValue
    }

    static func measure(_ state: TimelineState, config: AudioEngineConfig, file: URL?, audio: URL?, token: ExportCancellationToken) async throws -> Outcome {
        let grid = MixFrameGrid(fps: state.frameRate.fps)
        let count = grid.frame(endingAt: state.duration)
        let layers = try AIListenMixPlan.layers(nil, config: config, state: state)
        let measured = try await MediaReadQueue.run(on: MediaReadQueue.export) {
            Result {
                let rendered = AudioEngineConfig.make(from: state)
                return try MixMeasurement.measure(.init(config: rendered, layers: layers, grid: grid, frames: 0..<count),
                                                  isCancelled: { token.isCancelled })
            }
        }.get()
        var timeline = measured.mix.enumerated().map { index, frame in
            AIDeliveryMix.Frame(from: grid.seconds(ofFrame: index), to: min(state.duration, grid.seconds(ofFrame: index + 1)),
                power: frame.meanSquare, peak: frame.peak, outputPeak: frame.outputPeak, minGain: frame.minGain,
                layers: measured.layers.map { ($0.layer.name, $0.frames[index].meanSquare) })
        }
        var frames = timeline
        if let audio {
            let asset = MediaAssetCache.asset(for: audio).asset
            if try await asset.loadTracks(withMediaType: .audio).isEmpty {
                frames = timeline.map { .init(from: $0.from, to: $0.to, power: 0, peak: 0, outputPeak: 0, minGain: 1, layers: $0.layers) }
            } else {
                let bounds = AIListenFrameGrid(fps: state.frameRate.fps)
                let reading = try await AIListenAudioWindow.read(audio, from: nil, to: nil, until: Date().addingTimeInterval(180),
                                                                frames: { bounds.bounds(from: $0, to: $1) })
                guard let read = reading.frames else { throw AIToolError("The mixed output's frame levels were not measured.") }
                let times = bounds.bounds(from: reading.from, to: reading.to)
                frames = read.frames.enumerated().compactMap { index, frame in
                    guard index < timeline.count, times[index] < state.duration else { return nil }
                    let bus = timeline[index]
                    return .init(from: times[index], to: min(state.duration, times[index + 1]), power: frame.meanSquare,
                                 peak: file == nil ? bus.peak : frame.peak, outputPeak: frame.peak,
                                 minGain: file == nil ? bus.minGain : 1, layers: bus.layers)
                }
                if file == nil { timeline = frames }
            }
        }
        return Outcome(frames: frames, timeline: timeline, summary: [
            "measured": .string(file == nil ? "timeline snapshot" : "export file"),
            "timeline_peak_before_limiter_dbtp": .number(TruePeak.decibels(measured.levels.peak)),
            "timeline_output_peak_dbtp": .number(TruePeak.decibels(measured.levels.outputPeak)),
            "timeline_max_reduction_db": .number(measured.levels.maxReductionDB),
            "output_peak_dbtp": .number(TruePeak.decibels(frames.map(\.outputPeak).max() ?? 0)),
            "mix_levels": "Decoded output after limiting; timeline overload remains the bus before limiting.",
            "layer_attribution": "Frozen timeline, before limiting; a file with matching length may contain different content."
        ])
    }
}

import Foundation

// MARK: - Filling the sound strip: the engine's offline render (look), or the frames inspect_video already measured (MCP-66)
//
// look: MixMeasurement over the window's frames with the rows' layers — SkyCut's own engine rendering the export's configuration
// of the timeline (AudioEngineConfig.make, scenes' compensation included), on MediaReadQueue.export like listen mix=true (the
// engine's feeders read files synchronously: never on Swift's thread pool, docs/architecture/blocking-media-reads.md; one offline
// render at a time, docs/architecture/export-audio-mixdown.md section 5). The mix row is the master bus before the limiter, a track
// row that layer as it enters the bus: per frame the same level and true peak listen mix=true reports. A cancelled look (cancel_job,
// Stop) stops the render between blocks. Never the preview's engine.
// inspect_video: its report measured every frame of the mixed output already (AIInspectionMeasurement: after the limiter, the
// delivered sound, or the supplied export's own levels); the strip draws those frames over the checked range, no second render.
// What it does not do: which rows and seconds (AISoundStripRequest), drawing (AISoundStripDrawing).

enum AISoundStripMeasure {
    /// look's strip: nil when the look asked for no sound.
    static func strip(_ request: AISoundStripRequest?, state: TimelineState) async throws -> AISoundStrip? {
        guard let request else { return nil }
        let token = ExportCancellationToken()
        return try await withTaskCancellationHandler {
            try await MediaReadQueue.run(on: MediaReadQueue.export) { () -> Result<AISoundStrip, Error> in
                Result { try measure(request, state: state, isCancelled: { token.isCancelled }) }
            }.get()
        } onCancel: {
            token.cancel()
        }
    }

    /// Renders and measures the request's frames. Blocking: only on MediaReadQueue.export.
    static func measure(_ request: AISoundStripRequest, state: TimelineState, isCancelled: @escaping () -> Bool) throws -> AISoundStrip {
        let config = AudioEngineConfig.make(from: state)
        let grid = request.grid
        let frames = AISoundStrip.frames(of: request.window, grid: grid, total: MixMeasurement.frameCount(config, grid: grid))
        let silent = Array(repeating: AISoundStrip.Level(meanSquare: 0, peak: 0), count: frames.count)
        var mix = silent
        var layers = request.layers.map { _ in silent }
        if config.hasSound, !frames.isEmpty {
            let result = try MixMeasurement.measure(
                .init(config: config, layers: request.layers, grid: grid, frames: frames), isCancelled: isCancelled
            )
            mix = result.mix.map { .init(meanSquare: $0.meanSquare, peak: $0.peak) }
            layers = result.layers.map { layer in layer.frames.map { .init(meanSquare: $0.meanSquare, peak: $0.peak) } }
        }
        let rows = request.rows.map { row in
            AISoundStrip.Row(name: row.name, levels: row.layer.map { layers[$0] } ?? mix, starts: row.starts)
        }
        return AISoundStrip(grid: grid, firstFrame: frames.lowerBound, from: request.window.lowerBound, to: request.window.upperBound,
                            rows: rows, afterLimiter: false, ceiling: ExportPeakLimiter.defaultCeiling)
    }

    /// inspect_video's evidence sheet: the mix its report measured, frame by frame (`frames` from the timeline's first frame on),
    /// over the checked seconds; nil when there is nothing to draw.
    static func inspection(
        _ frames: [AIDeliveryMix.Frame], state: TimelineState, config: AudioEngineConfig, scope: AIInspection.Scope
    ) -> AISoundStrip? {
        guard let first = scope.ranges.first, let last = scope.ranges.last, !frames.isEmpty else { return nil }
        let window = first.lowerBound...last.upperBound
        guard window.upperBound > window.lowerBound else { return nil }
        let grid = MixFrameGrid(fps: state.frameRate.fps)
        let covered = AISoundStrip.frames(of: window, grid: grid, total: frames.count)
        let levels = frames[covered].map { AISoundStrip.Level(meanSquare: $0.power, peak: $0.outputPeak) }
        let starts = AISoundStripRequest.starts(config, tracks: nil, window: window, state: state, ids: AIShortIDs(state: state))
        return AISoundStrip(grid: grid, firstFrame: covered.lowerBound, from: window.lowerBound, to: window.upperBound,
                            rows: [.init(name: AISoundStrip.mixName, levels: levels, starts: starts)],
                            afterLimiter: true, ceiling: ExportPeakLimiter.defaultCeiling)
    }
}

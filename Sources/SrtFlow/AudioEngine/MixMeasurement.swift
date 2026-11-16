import Foundation

// MARK: - 按层量混在一起之后的声音，到帧（阻塞）
//
// 管什么：一份配置（和成片同一份）、几层、按工程帧率的一段帧 → 用引擎离线按层渲（AudioStemRender），整条混音交给
// MixBusMeter（过没过线、限幅器压了多少、瞬时 / 短时 / 整体响度），每层交给 MixBandMeter（每帧的电平、峰值、四个频段、整体响度），
// 给出纯值的结果。要采样的（以后的 ESTOI）传 `observe`，每一块渲出来的混音和各层原样给它。只读：不改工程。
// 前面多渲几秒（`preroll`）：3 秒的短时响度窗、限幅器、K 加权都要从前面接上；挂了声音场景的再多 6 秒（余音最长
// `SceneRecipe.maximumTail`，前面那段的余音会拖进量的范围）。起点按 `TimelineAudioEngine.offlineQuantum` 往前取整，块的边界
// 和成片从 0 渲的那一份对齐。后面多渲一点（限幅器的前瞻、频段窗的半帧），渲到时间线的尽头就照成片那样冲干净限幅器。
// 不管什么：哪几条轨算一层、参数、写给 AI（AIListenMix）；排队和任务（AIListenMix）。
// 只在 MediaReadQueue 的队列上调（引擎的喂样同步读文件，docs/architecture/blocking-media-reads.md）。
// 长期约束：docs/architecture/export-audio-mixdown.md「五、按层量」。

enum MixMeasurement {
    struct Request: Sendable {
        let config: AudioEngineConfig
        let layers: [AudioStemLayer]
        let grid: MixFrameGrid
        /// 量哪几帧（时间线的第几帧）。
        let frames: Range<Int>
    }

    /// 一层的量。
    struct Layer: Sendable {
        let layer: AudioStemLayer
        /// 每一帧（顺序同 `Result.frames`）。
        let frames: [MixFrameLevel]
        let peak: Float
        let peakSample: Int64?
        let loudnessLUFS: Double?
    }

    struct Result: Sendable {
        let grid: MixFrameGrid
        let frames: Range<Int>
        /// 时间线的尽头（采样）。
        let limit: Int64
        /// 整条混音每一帧。
        let mix: [MixBusMeter.Frame]
        /// 整条混音在量的范围里的电平，口径同导出（量整条时间线时和导出报的逐位一样）。
        let levels: ExportAudioMixdown.Levels
        let peakSample: Int64?
        let layers: [Layer]
        /// 实际渲了哪一段（采样，含前面多渲的）。
        let rendered: Range<Int64>
    }

    /// 前面至少多渲这么多秒：短时响度的窗（3 秒）。
    static let prerollSeconds = MixBusMeter.shortTermSeconds

    /// 这一份配置的时间线有多少帧（最后不满一帧的也算一帧）。
    static func frameCount(_ config: AudioEngineConfig, grid: MixFrameGrid) -> Int {
        grid.frame(endingAt: config.duration)
    }

    /// 前面多渲几秒：3 秒；有段挂了声音场景再加余音最长的 6 秒。
    static func preroll(_ config: AudioEngineConfig) -> Double {
        let scenes = config.tracks.contains { $0.segments.contains { $0.scene != nil } }
        return prerollSeconds + (scenes ? SceneRecipe.maximumTail : 0)
    }

    /// 阻塞地渲完、量完。`isCancelled` 每渲一块问一次，回 true 就抛 CancellationError。
    static func measure(
        _ request: Request, isCancelled: () -> Bool = { false }, observe: ((AudioStemRender.Block) -> Void)? = nil
    ) throws -> Result {
        let grid = request.grid
        let rate = Int64(grid.sampleRate)
        let limit = Int64((request.config.duration * Double(rate)).rounded())
        let first = grid.start(ofFrame: request.frames.lowerBound)
        let last = min(grid.start(ofFrame: request.frames.upperBound), limit)
        let quantum = Int64(TimelineAudioEngine.offlineQuantum)
        let early = first - Int64((preroll(request.config) * Double(rate)).rounded(.up))
        let start = early > 0 ? early / quantum * quantum : 0
        // 后面多渲：限幅器的前瞻（5 ms）和频段窗的半帧，都够了再多一点。
        let lookahead = Int64((ExportPeakLimiter.defaultLookaheadSeconds * Double(rate)).rounded()) + 1
        let end = min(limit, last + max(lookahead, grid.halfFrame) + 1)
        let bus = MixBusMeter(grid: grid, frames: request.frames, limit: limit, renderStart: start)
        let meters = request.layers.map { _ in MixBandMeter(grid: grid, frames: request.frames, limit: limit) }
        var cancelled = false
        try AudioStemRender.render(request.config, layers: request.layers, from: start, to: end) { block in
            if isCancelled() {
                cancelled = true
                return false
            }
            observe?(block)
            bus.add(block.mix, at: block.position, frames: block.frames)
            for (meter, samples) in zip(meters, block.layers) { meter.add(samples, at: block.position, frames: block.frames) }
            return true
        }
        if cancelled { throw CancellationError() }
        bus.finish(reachedEnd: end == limit)
        meters.forEach { $0.finish() }
        let layers = zip(request.layers, meters).map { layer, meter in
            Layer(layer: layer, frames: meter.levels, peak: meter.peak, peakSample: meter.peakSample, loudnessLUFS: meter.loudnessLUFS)
        }
        return Result(
            grid: grid, frames: request.frames, limit: limit, mix: bus.frames, levels: bus.levels,
            peakSample: bus.peakSample, layers: layers, rendered: start ..< end
        )
    }
}

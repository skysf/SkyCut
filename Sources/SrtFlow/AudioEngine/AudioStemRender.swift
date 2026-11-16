import Foundation

// MARK: - 按层离线渲（stem）：整条混音和每一层，一块一块同步往下走
//
// 管什么：给一份配置（`AudioEngineConfig.make` 出来的，和成片同一份）和几层（每层是配置里的几条轨），用引擎的离线模式
// 同时渲出整条混音和每一层：
// - 混音：一个引擎，就是成片那一份配置（所有轨、总推子），渲法和 `ExportAudioMixdown` 一样；
// - 每一层：一个引擎，同一份配置只留那几条轨（`config(_:keeping:)`），总推子、总长照旧。所以每层的增益链和成片完全一样
//   （片段音量、音量曲线、渐入渐出、声音场景、轨道推子、总推子），各层加起来就是总线上的混音。
// **限幅之前**：限幅器只在成片写文件那一步、只作用在整条混音上（ExportPeakLimiter）；这里给的每层、混音都是它进总线时的样子。
// 一块 = 引擎离线渲的一块（`TimelineAudioEngine.offlineQuantum` 帧）：每个引擎在同一个时间线位置上各渲一块，一起交给调用方
// （交错立体声 f32，48 kHz）。要采样的（以后的 ESTOI：干净人声那一层对整条混音）直接拿这一块；只要数的交给 MixMeasurement。
// 块的边界从起点按 offlineQuantum 数：起点是 offlineQuantum 的整数倍时，和成片从 0 渲的那一份块块对齐（增益按块插值，逐采样一样）。
// 不管什么：量（MixMeasurement 那几样）、限幅、哪几条轨算一层（AIListenMix）。
// 只在 MediaReadQueue 的队列上调：引擎的喂样在调用方线程上同步读文件（docs/architecture/blocking-media-reads.md）。
// 离线引擎不碰声卡：预览那个实时引擎停着就一直停着（docs/architecture/audio-engine.md 第二节第 11 条）。
// 长期约束：docs/architecture/export-audio-mixdown.md「五、按层量」。

/// 一层：配置里的几条轨（下标），和给人 / AI 看的名字。
struct AudioStemLayer: Sendable, Equatable {
    let name: String
    let tracks: [Int]
}

enum AudioStemRender {
    /// 渲出来的一块：时间线第 `position` 帧起 `frames` 帧；混音和每层都是交错的立体声 f32（顺序同 `layers`）。
    /// 指针只在 consumer 里有效。
    struct Block {
        let position: Int64
        let frames: Int
        let mix: UnsafeBufferPointer<Float>
        let layers: [UnsafeBufferPointer<Float>]
    }

    struct RenderError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// 这一层的配置：只留这几条轨（顺序照配置里的），总推子、总长照旧 —— 每层的数是它进总线时的样子。
    static func config(_ config: AudioEngineConfig, keeping tracks: [Int]) -> AudioEngineConfig {
        let kept = Set(tracks)
        return AudioEngineConfig(
            tracks: config.tracks.indices.filter { kept.contains($0) }.map { config.tracks[$0] },
            master: config.master, duration: config.duration
        )
    }

    /// 把时间线 `[start, end)`（帧，48 kHz）的混音和每一层一块一块渲出来交给 `consumer`；`consumer` 回 false 就停（取消）。
    /// 阻塞：在 MediaReadQueue 的队列上调。
    static func render(
        _ config: AudioEngineConfig, layers: [AudioStemLayer], from start: Int64, to end: Int64,
        consumer: (Block) -> Bool
    ) throws {
        guard end > start else { return }
        var engines = [try TimelineAudioEngine(config: config, mode: .offline)]
        for layer in layers {
            engines.append(try TimelineAudioEngine(config: Self.config(config, keeping: layer.tracks), mode: .offline))
        }
        var begun: [TimelineAudioEngine] = []
        defer { begun.forEach { $0.endOffline() } }
        for engine in engines {
            try engine.beginOffline(atFrame: start)
            begun.append(engine)
        }
        // 每个引擎一段（交错立体声，一块那么长），排在一整块内存里。
        let stride = TimelineAudioEngine.offlineQuantum * 2
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: stride * engines.count)
        defer { storage.deallocate() }
        var position = start
        while position < end {
            let frames = Int(min(Int64(TimelineAudioEngine.offlineQuantum), end - position))
            for index in engines.indices {
                let got = try engines[index].renderOfflineQuantum(at: position, frames: frames, into: storage + index * stride)
                guard got == frames else {
                    throw RenderError(detail: "The audio engine rendered \(got) of \(frames) frames at frame \(position).")
                }
            }
            let parts = engines.indices.map { UnsafeBufferPointer(start: storage + $0 * stride, count: frames * 2) }
            guard consumer(Block(position: position, frames: frames, mix: parts[0], layers: Array(parts.dropFirst()))) else { return }
            position += Int64(frames)
        }
    }
}

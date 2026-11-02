import AVFoundation
import Foundation

// MARK: - 素材探测（带缓存）
//
// 管什么：视频素材的探测结果（`MediaInfo`）和音频时长，按路径缓存 —— 同一个文件第二次导入、定格生成的
// 静帧视频、修图片占位块时都不再重新探。
// 不管什么：探测本身（视频走 `MediaProbe` 调 ffmpeg，音频时长直接读 `AVURLAsset`）、探到之后怎么进时间线。
// 从 VideoEditProject.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

@MainActor
final class MediaProbeCache {
    enum State: Equatable {
        case notLoaded, loading, ready
        case unavailable(String)
    }
    private var infos: [URL: MediaInfo] = [:]
    private var audioDurations: [URL: Double] = [:]
    private var probes: [URL: Task<Result<MediaInfo, Error>, Never>] = [:]
    private var failures: [URL: String] = [:]

    /// 已经探过的结果，不去探。修图片占位块时用：那时只认缓存里有的。
    func cachedInfo(for url: URL) -> MediaInfo? { infos[url] }

    func state(for url: URL) -> State {
        if infos[url] != nil { return .ready }
        if probes[url] != nil { return .loading }
        return failures[url].map(State.unavailable) ?? .notLoaded
    }

    func probeVideo(_ url: URL) async -> MediaInfo? {
        if let cached = infos[url] { return cached }
        // 正在探的文件复用同一个任务；状态只表示真实在途工作，不能把失败永远伪装成「再等一下」。
        let task = probes[url] ?? Task { await MediaProbe.probe(url: url, ffmpeg: MediaToolchain.shared.runtime?.url) }
        probes[url] = task
        let result = await task.value
        probes[url] = nil
        switch result {
        case .success(let info):
            infos[url] = info
            failures[url] = nil
            return info
        case .failure(let error):
            failures[url] = error.localizedDescription
            return nil
        }
    }

    func audioDuration(_ url: URL) async -> Double? {
        if let cached = audioDurations[url] { return cached }
        guard let duration = try? await Self.measuredAudioDuration(url) else { return nil }
        audioDurations[url] = duration
        return duration
    }

    /// 实测文件的时间账；旁白同步不能取旧缓存，也不能取解码器单次 read 返回的帧数。
    static func measuredAudioDuration(_ url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return duration
    }
}

import AVFoundation
import Foundation

// MARK: - 一段画面从哪个源取：原片、直通源的预乘副本、或者优化媒体的块
//
// 管什么：
// - builder 插每一段画面之前挑源轨（`track(for:proxies:asset:)`）：**带透明的段不用优化媒体的块**（代理是 H.264，没有 alpha，
//   换进去透明的地方就成了黑块）；**直通的段插预乘的副本**（`AlphaSourceCopies`：默认合成器把源一律当预乘的用，直通的半透明处
//   会过亮），副本转不出来就退回原片（亮一点，不黑、不丢段）；别的段照旧：块都转好了给块（`CompositionClipInsert` 按块插），不然原片。
// - 渲染的入口补认老段的透明（`resolvingAlpha`）：`MediaInfo.alpha` 是 2026-11-16 起探测时才读的，之前放上去的段没有。预览合成和
//   导出图在入口各调一次（同 `expandingTransitionHandles` 的做法：两条管线看同一份），只认真要画出来的段 —— 那些素材 builder
//   本来就要开，不多开一个文件。
// 不管什么：怎么插（CompositionClipInsert）、哪些块转好了（OptimizedMediaLookup）、副本怎么转（AlphaSourceCopies）、认标记的规矩
// （`SourceAlpha`）。长期约束见 docs/architecture/freeze-frame.md 第 4a3 节「带透明的段」。
// 2026-11-16 从 VideoEditCompositionBuilder 拆出（那个文件在行数基线里只许降）。

enum CompositionSource {
    struct Choice {
        /// 插哪条源轨：原片，或直通源的预乘副本（时间戳、几何和原片一样）。
        var track: AVAssetTrack
        /// 优化媒体的块（都转好了才有）；带透明的段永远没有。
        var proxies: [Int: AVAssetTrack]?
    }

    /// nil = 这段的源打不开（builder 跳过它）。
    static func track(
        for clip: EditClip, proxies lookup: OptimizedMediaLookup, asset: (URL) -> AVURLAsset
    ) async -> Choice? {
        let alpha = clip.sourceAlpha
        var url = clip.sourceURL
        if alpha == .straight, let premultiplied = await AlphaSourceCopies.url(.premultiplied, for: clip.sourceURL) {
            url = premultiplied
        }
        guard let track = try? await asset(url).loadTracks(withMediaType: .video).first else { return nil }
        guard alpha == .opaque else { return Choice(track: track, proxies: nil) }
        return Choice(track: track, proxies: await proxyTracks(for: clip, in: lookup, asset: asset))
    }

    /// 要画出来的段里没记带不带透明的（老工程），从素材的格式描述补认，写进这一份渲染用的状态（不写回用户的工程）。
    /// 静帧不用认（透明静帧按名字认）；还在转静帧的、藏起来的不画，不认。
    static func resolvingAlpha(in state: TimelineState, asset: (URL) -> AVURLAsset) async -> TimelineState {
        let pictures = ClipVisibility.visible(
            (state.mainHidden ? [] : state.mainClips) + state.overlayTracks.filter { !$0.isHidden }.flatMap(\.clips)
        ).filter { $0.info != nil && $0.info?.alpha == nil && !$0.isStillImage && !$0.needsStillConversion && !$0.isAudioOnly }
        guard !pictures.isEmpty else { return state }
        var state = state
        var known: [URL: SourceAlpha] = [:]
        for clip in pictures {
            if known[clip.sourceURL] == nil {
                let track = try? await asset(clip.sourceURL).loadTracks(withMediaType: .video).first
                let format = try? await track?.load(.formatDescriptions).first
                known[clip.sourceURL] = SourceAlpha(format: format)
            }
            let alpha = known[clip.sourceURL]
            state.update(clip.id) { $0.info?.alpha = alpha }
        }
        return state
    }

    /// 这一段的优化媒体块（都转好了才给；没有代理 / 没转全 / 块文件打不开 → nil，插原片）。只开真要用的那几块。
    private static func proxyTracks(
        for clip: EditClip, in lookup: OptimizedMediaLookup, asset: (URL) -> AVURLAsset
    ) async -> [Int: AVAssetTrack]? {
        guard let chunks = lookup.readyChunks(for: clip) else { return nil }
        var tracks: [Int: AVAssetTrack] = [:]
        for (chunk, url) in chunks {
            guard let track = try? await asset(url).loadTracks(withMediaType: .video).first else { return nil }
            tracks[chunk] = track
        }
        return tracks
    }
}

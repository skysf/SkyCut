import Foundation
import SrtFlowMCPKit

// MARK: - MCP 编辑前的素材可用性
//
// 管什么：区分真实转换 / 探测在途与已丢失 / 探测失败。缺失元数据先复用 MediaProbeCache 探测；只返回值，
// 不直接改工程，随 AIClipEdit 的整份候选一起采用。不能用「没有尺寸」推断「文件损坏」。
@MainActor enum AIClipReadiness {
    /// 同步工具（set_keyframes）：只修本次局部副本；缺元数据就起同一份只读探测，返回真实可重试状态。
    static func knownPicture(_ clip: EditClip, project: VideoEditProject) throws -> MediaInfo? {
        guard !clip.isAudioOnly else { return nil }
        if clip.needsStillConversion {
            let exists = FileManager.default.fileExists(atPath: (clip.stillImageURL ?? clip.sourceURL).path)
            throw failure(clip, loading: exists, reason: exists ? "still_conversion_pending" : "source_missing",
                          message: exists ? "The image is still converting; retry shortly." : "The source image is missing; relink it.")
        }
        guard FileManager.default.fileExists(atPath: clip.sourceURL.path) else {
            throw failure(clip, loading: false, reason: "source_missing", message: "The source file is missing; relink it.")
        }
        if let info = clip.info, info.displaySize.width > 0, info.displaySize.height > 0 { return nil }
        if let info = project.mediaProbes.cachedInfo(for: clip.sourceURL), info.displaySize.width > 0, info.displaySize.height > 0 { return info }
        if case .unavailable = project.mediaProbes.state(for: clip.sourceURL) {
            throw failure(clip, loading: false, reason: "metadata_probe_failed", message: "Picture metadata could not be loaded; use edit_clip file to replace or re-probe the source.")
        }
        let cache = project.mediaProbes, url = clip.sourceURL
        Task { _ = await cache.probeVideo(url) }
        throw failure(clip, loading: true, reason: "metadata_probe_running", message: "Picture metadata is loading; retry shortly.")
    }

    static func prepare(_ clip: EditClip, project: VideoEditProject, needsPicture: Bool) async throws -> MediaInfo? {
        let original = clip.stillImageURL ?? clip.sourceURL
        if clip.needsStillConversion {
            guard FileManager.default.fileExists(atPath: original.path) else {
                throw failure(clip, loading: false, reason: "source_missing", message: "The source image is missing. Relink it or use edit_clip file to replace it.")
            }
            if needsPicture {
                throw failure(clip, loading: true, reason: "still_conversion_pending",
                              message: "The image is still becoming a timeline clip; its dimensions are not ready. Retry this edit after conversion finishes.")
            }
            return nil // 时长 / 位置编辑不需要画面尺寸，沿用界面允许编辑占位块的设计。
        }
        guard FileManager.default.fileExists(atPath: clip.sourceURL.path) else {
            throw failure(clip, loading: false, reason: "media_unavailable", message: "The timeline media is missing. Relink it or replace it from the original image.")
        }
        guard !clip.isAudioOnly else { return nil }
        if let info = clip.info, info.displaySize.width > 0, info.displaySize.height > 0 { return nil }
        if project.mediaProbes.state(for: clip.sourceURL) == .loading {
            throw failure(clip, loading: true, reason: "metadata_probe_running", message: "SkyCut is loading the picture dimensions. Retry this edit shortly.")
        }
        guard let info = await project.mediaProbes.probeVideo(clip.sourceURL), info.displaySize.width > 0, info.displaySize.height > 0 else {
            throw failure(clip, loading: false, reason: "metadata_probe_failed",
                          message: "SkyCut could not load picture metadata after probing this file. It may be unsupported or unavailable; relink it or provide another file.")
        }
        try Task.checkCancellation()
        return info
    }

    static func failure(_ clip: EditClip, loading: Bool, reason: String, message: String) -> AIToolError {
        var details: [String: JSONValue] = ["status": .string(loading ? "media_loading" : "media_unavailable"),
                                          "retryable": .bool(loading), "reason": .string(reason),
                                          "clip_id": .string(clip.id.uuidString.lowercased()), "file": .string(clip.name)]
        if loading { details["retry_after_ms"] = 500 }
        return AIToolError(message + " Nothing was applied.", details: details)
    }
}

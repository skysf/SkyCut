import AVFoundation
import Foundation

// MARK: - 原生预览打不开的生成视频的本机编辑副本
// 管什么：HeyGen 可回 WebM；永久保留原文件，仅用现有 ffmpeg 做 H.264/AAC 副本给 AVFoundation。
// 不管什么：付费、重生成、改模型、删除原件；副本失败仍保留已生成结果与扣费证据。
@MainActor
enum SkyStudioGeneratedVideo {
    /// 后台工程没有 VideoEditView.onAppear，也必须能探 WebM / 转透明图片；复用同一个引擎定位器。
    static func engine() async throws -> URL {
        let toolchain = MediaToolchain.shared
        if toolchain.runtime == nil { toolchain.resolveIfNeeded() }
        while toolchain.isResolving {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let url = toolchain.runtime?.url else { throw AIToolError("SkyCut's video engine is unavailable; no paid generation was retried.") }
        return url
    }

    static func needsCopy(_ file: URL) async -> Bool {
        guard file.pathExtension.lowercased() == "webm" else { return false }
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await track.load(.isDecodable)) == true,
              (try? await asset.load(.isPlayable)) == true else { return true }
        return false
    }

    static func makeCopy(_ original: URL, to destination: URL, ffmpeg: URL) async throws {
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        let process = FFmpegProcess()
        try await withTaskCancellationHandler {
            try await process.run(executable: ffmpeg, arguments: [
                "-nostdin", "-v", "error", "-i", original.path, "-map", "0:v:0", "-map", "0:a:0?",
                "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", partial.path
            ], workingDirectory: nil)
        } onCancel: { process.cancel() }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

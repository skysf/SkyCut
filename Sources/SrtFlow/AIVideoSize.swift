import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 给 AI 看的「画面多大」：成片的、素材文件的
//
// 管什么：export_video / get_job 回成片的宽、高、帧率（导出管线的口径：画布按档位封短边、只降不升，帧率就是工程帧率），
// look 看文件时回文件本身的宽高帧率时长，并把「发给你的图缩到了多大」分开写。
// 不管什么：导出本身（VideoEditExportGraph 里同一个 `cappedSize`）、取帧（AIFrameSampler）。
//
// 为什么（docs/bugfixes/2026-10-14-ai-thinks-export-is-720p.md）：2026-10-06 盲测的三条片子，AI 都以为成片是 720p ——
// export_video 和 get_job 不报尺寸，它只好拿 look 看成片，而 look 回的 `picture_size` 是发给它的图（最长边封 1280）。

enum AIVideoSize {
    /// 成片的画面：画布按导出档位封短边（和 VideoEditExportGraph 同一个 `cappedSize`），帧率是工程帧率。
    static func output(canvas: CGSize, resolution: ResolutionLimit, fps: Int) -> JSONValue {
        let width = Int(canvas.width.rounded()), height = Int(canvas.height.rounded())
        let size = resolution.cappedSize(width: width, height: height) ?? (width, height)
        return ["width": .number(Double(size.width)), "height": .number(Double(size.height)), "fps": .number(Double(fps))]
    }

    /// 一个视频文件本身：宽高（按显示方向）、帧率、时长。
    static func file(width: Int, height: Int, fps: Double, duration: Double) -> JSONValue {
        [
            "width": .number(Double(width)), "height": .number(Double(height)),
            "fps": .number((fps * 100).rounded() / 100), "duration": .number((duration * 1000).rounded() / 1000)
        ]
    }

    /// 发给 AI 的图缩到了多大（只是为了看，不是素材 / 成片的尺寸）。
    static func sentImage(width: Int, height: Int) -> JSONValue {
        ["width": .number(Double(width)), "height": .number(Double(height)),
         "note": "The pictures are scaled down to look at; the real size is in video / image."]
    }
}

import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 「画面多大」给 AI 说清楚（docs/bugfixes/2026-10-14-ai-thinks-export-is-720p.md）：export_video / get_job 报成片的宽高帧率
// （和导出管线同一个 `cappedSize`：封短边、只降不升），look 看文件时报文件本身的尺寸、缩略图的尺寸另写。
// 接线（两处都报、look 不再只回缩略图的尺寸）在 scripts/check-mcp.sh 的扫描里。

func runVideoSizeChecks() {
    func size(_ value: JSONValue) -> String {
        "\(value["width"]?.intValue ?? -1)x\(value["height"]?.intValue ?? -1)@\(value["fps"]?.intValue ?? -1)"
    }
    let portrait = CGSize(width: 1080, height: 1920)
    checkEqual(size(AIVideoSize.output(canvas: portrait, resolution: .fhd1080, fps: 24)), "1080x1920@24",
               "9:16 at 1080p is 1080x1920 (the short side), not 608x1080 or 720p")
    checkEqual(size(AIVideoSize.output(canvas: portrait, resolution: .hd720, fps: 30)), "720x1280@30", "9:16 at 720p")
    checkEqual(size(AIVideoSize.output(canvas: portrait, resolution: .original, fps: 24)), "1080x1920@24", "original keeps the canvas")
    checkEqual(size(AIVideoSize.output(canvas: CGSize(width: 3840, height: 2160), resolution: .fhd1080, fps: 60)), "1920x1080@60",
               "4K landscape at 1080p")
    checkEqual(size(AIVideoSize.output(canvas: CGSize(width: 1280, height: 720), resolution: .fhd1080, fps: 30)), "1280x720@30",
               "never scaled up")
    let file = AIVideoSize.file(width: 1080, height: 1920, fps: 23.976, duration: 31.8099)
    checkEqual(file["fps"]?.doubleValue, 23.98, "a file's frame rate is rounded to two decimals")
    checkEqual(file["duration"]?.doubleValue, 31.81, "a file's duration in seconds")
    let sent = AIVideoSize.sentImage(width: 720, height: 1280)
    check((sent["note"]?.stringValue ?? "").contains("scaled down"), "the size of the pictures sent says it is not the video's size")
}

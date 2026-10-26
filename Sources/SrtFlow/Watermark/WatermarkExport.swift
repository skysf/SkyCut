import CoreGraphics
import Foundation

// MARK: - 导出水印怎么进滤镜图
//
// 管什么：把水印叠到成片上。**整段成片只加两个 overlay**（四角用的大图、正中用的小图各一个），位置和开关是随时间分段的常数，
// 写成平衡的 `if(lt(t,…))` 树（相邻同值的段先并起来）：一小时的成片 900 段也只有十来层，不会一段挂一个 overlay。
// 段是左闭右开 `[起点, 下一段起点)`，和别的叠加一样（OverlayExportFile.enableWindow）。
// **落点**：字幕烧完之后、缩到导出分辨率之前（VideoEditExportGraph.plan）—— 压在所有画面之上，和别的东西一样按工程尺寸画完再一起缩。
// 不管什么：图（WatermarkImage）、表和尺寸（WatermarkPlacement）、加不加（WatermarkPolicy）。约束见 docs/architecture/export-watermark.md。

/// 这一次导出要叠的水印（WatermarkPolicy 给）。`plan()` 收的是 `ExportWatermark?`：nil = 不叠。
struct ExportWatermark {
    var logo: WatermarkImage.Logo
    var seed: UInt64
}

enum WatermarkExport {
    struct RenderError: Error {}

    static func append(
        _ mark: ExportWatermark?, canvas: CGSize, total: Double, workspace: URL,
        inputArguments: inout [String], inputs: inout [String],
        video: inout String, filters: inout [String], nextLabel: (String) -> String
    ) throws {
        guard let mark, total > 0, canvas.width > 0, canvas.height > 0 else { return }
        let slots = WatermarkPlacement.schedule(total: total, seed: mark.seed)
        let fmt = VideoEditExportGraph.fmt
        // 四角一张、正中一张；表里一次都没用到的那张不叠。
        for corner in [true, false] where slots.contains(where: { $0.spot.isCorner == corner }) {
            let width = WatermarkPlacement.logoWidth(corner ? .topLeft : .center, canvas: canvas)
            guard let image = WatermarkImage.render(mark.logo, logoWidth: width, opacity: WatermarkPlacement.opacity) else {
                throw RenderError()
            }
            let file = workspace.appendingPathComponent(corner ? "watermark-corner.png" : "watermark-center.png")
            try image.png.write(to: file)
            inputArguments += ["-loop", "1", "-t", fmt(total), "-i", file.path]
            let stream = "\(inputs.count):v"
            inputs.append(file.path)

            // 这张图在每一段的左上角（图比墨迹大一圈，留给阴影）；不在它那儿的段照抄前一段的值，好并段。
            var x: [(start: Double, value: String)] = []
            var y: [(start: Double, value: String)] = []
            var on: [(start: Double, value: String)] = []
            var last = CGPoint.zero
            for slot in slots {
                let shown = slot.spot.isCorner == corner
                if shown {
                    let ink = WatermarkPlacement.inkOrigin(slot.spot, ink: image.inkSize, canvas: canvas)
                    last = CGPoint(x: ink.x - image.inset, y: ink.y - image.inset)
                }
                x.append((slot.start, fmt(Double(last.x))))
                y.append((slot.start, fmt(Double(last.y))))
                on.append((slot.start, shown ? "1" : "0"))
            }
            let outV = nextLabel("v")
            filters.append(
                "[\(video)][\(stream)]overlay=x='\(piecewise(x, fmt: fmt))':y='\(piecewise(y, fmt: fmt))'" +
                ":eof_action=pass:enable='\(piecewise(on, fmt: fmt))'[\(outV)]"
            )
            video = outV
        }
    }

    /// 分段常数写成平衡的 if 树：`t` 落在 `[第 i 段起点, 第 i+1 段起点)` 取第 i 段的值（第一段从负无穷算起，最后一段到正无穷）。
    /// 相邻同值的段先并起来。
    static func piecewise(_ runs: [(start: Double, value: String)], fmt: (Double) -> String) -> String {
        var merged: [(start: Double, value: String)] = []
        for run in runs where merged.last?.value != run.value { merged.append(run) }
        func tree(_ range: Range<Int>) -> String {
            guard range.count > 1 else { return merged[range.lowerBound].value }
            let middle = range.lowerBound + range.count / 2
            return "if(lt(t,\(fmt(merged[middle].start))),\(tree(range.lowerBound..<middle)),\(tree(middle..<range.upperBound)))"
        }
        return merged.isEmpty ? "0" : tree(0..<merged.count)
    }
}

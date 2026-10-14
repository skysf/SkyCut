import CoreGraphics
import Foundation

// MARK: - 叠在画面上的图怎么进导出的滤镜图（形状、文字）
//
// 管什么：形状和文字渲出来的 PNG 在导出里的三种接法（单张拉成持续的流 / 序列播一遍 / 序列循环）、序列末尾多渲一帧，
// 以及按叠放次序一层层 overlay 到画面上。
// 不管什么：图里画什么、怎么切段（`ShapeOverlayExport` / `TextOverlayExport`），画面本身（`ShapePNGRenderer` / `TextRenderer`）。
// 2026-10-03 从 VideoEditTextExport.swift 和 VideoEditExportGraph.swift 拆出来：形状有了入场 / 出场动画也要逐帧序列，
// 两份接法只留这一份（docs/architecture/shapes.md、text-overlays.md「导出：只逐帧渲动画进行中的那段」）。

/// 一层叠加（一段形状 / 文字切出来的一个片段）。
struct OverlayExportFile {
    enum Source {
        /// 单张 PNG：`-loop 1` 拉成持续的流。
        case still
        /// PNG 序列播一遍：`-itsoffset` 推到落点。
        case sequence(frames: Int)
        /// PNG 序列无限循环：只有一个周期的帧，`loop` 滤镜铺满整段。
        case looping(frames: Int)
    }

    /// 单张是文件名，序列是 `printf` 模式（`text0-in_%05d.png`）。
    var pattern: String
    var source: Source
    /// 位图左上角在输出画面上的像素位置（可以是负的：文字探出画面；形状是整幅画布，恒为 0）。
    var origin: CGPoint
    var timelineStart: Double
    var timelineEnd: Double

    /// 序列末尾多渲两帧。
    ///
    /// 序列只有到它最后一帧为止才算「有」：输出帧的时刻一过最后一帧，输入流就到了 EOF，`eof_action=pass` 当场把这一层
    /// 整个撤掉 —— 那一帧上字（形状）闪没了。而序列的最后一帧可能早于 `enable` 的终点：
    ///   · 区间里的帧本来只排到 `end - 1/fps`（多一帧补的是这个，2026-09-17）；
    ///   · `-itsoffset <起点>` 被换算到序列的 1/fps 格子上（四舍五入），起点不在格子上时整串最多提前半帧；
    ///   · 合成出来的画面时间戳是微秒、比格子晚几微秒（主轨几段 concat 时的取整），正好落在「最后一帧之后」。
    /// 后两条叠在一起，只多一帧不够（2026-10-06 盲测：rise 入场结束前那一帧字没了，docs/bugfixes/2026-10-14-text-blinks-at-animation-seam.md）。
    /// 多两帧：最后一帧至少在 `end + 半帧`，区间里每一个输出帧都有帧可贴。
    static let sequenceTailFrames = 2

    /// 播一遍的序列要渲几帧：区间里的每一帧，再多一帧。
    static func sequenceFrameCount(span: Double, fps: Double) -> Int {
        max(1, Int(ceil(max(0, span) * fps)) + sequenceTailFrames)
    }

    /// 一层在哪段时间里贴：**左闭右开** `[起点, 终点)`，和预览的 `contains(time:)` 同一个口径。一段文字切成的几段首尾相接，
    /// 用两头都闭的 `between` 的话，接缝正好落在一帧上时两段同时贴、那一帧字（和阴影）叠成两层（2026-10-14）。
    static func enableWindow(_ start: Double, _ end: Double, fmt: (Double) -> String) -> String {
        "gte(t,\(fmt(start)))*lt(t,\(fmt(end)))"
    }

    /// 按给的顺序（= 叠放次序：先形状、后文字）一层层贴到 `video` 上。三种接法的实测依据：
    ///   · 单张：`-loop 1` 拉成持续流。
    ///   · 一次性序列：`-itsoffset` 把序列推到落点，帧与时间线精确对齐。
    ///   · 循环段：只有一个周期的帧，`loop` 滤镜铺满，`setpts` 补回时间轴。
    static func append(
        _ files: [OverlayExportFile], fps: Double, total: Double,
        inputArguments: inout [String], inputs: inout [String],
        video: inout String, filters: inout [String], nextLabel: (String) -> String
    ) {
        let fmt = VideoEditExportGraph.fmt
        for file in files {
            let stream: String
            switch file.source {
            case .still:
                inputArguments += ["-loop", "1", "-t", fmt(total), "-i", file.pattern]
                stream = "\(inputs.count):v"
                inputs.append(file.pattern)

            case .sequence:
                inputArguments += [
                    "-itsoffset", fmt(file.timelineStart),
                    "-framerate", fmt(fps), "-start_number", "0", "-i", file.pattern
                ]
                stream = "\(inputs.count):v"
                inputs.append(file.pattern)

            case .looping(let frames):
                inputArguments += ["-framerate", fmt(fps), "-start_number", "0", "-i", file.pattern]
                let index = inputs.count
                inputs.append(file.pattern)
                let looped = nextLabel("tl")
                // `loop` 之后 PTS 要自己重建（N 是帧序号），再整体推到落点。
                filters.append(
                    "[\(index):v]loop=loop=-1:size=\(frames):start=0," +
                    "setpts=N/\(fmt(fps))/TB+\(fmt(file.timelineStart))/TB[\(looped)]"
                )
                stream = looped
            }

            let outV = nextLabel("v")
            filters.append(
                "[\(video)][\(stream)]overlay=x=\(fmt(file.origin.x)):y=\(fmt(file.origin.y))" +
                ":eof_action=pass:enable='\(enableWindow(file.timelineStart, file.timelineEnd, fmt: fmt))'[\(outV)]"
            )
            video = outV
        }
    }
}

import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 叠在画面上的图怎么进导出的滤镜图（形状、文字）
//
// 管什么：形状和文字渲出来的 PNG 在导出里的三种接法（单张拉成持续的流 / 序列播一遍 / 序列循环）、序列末尾多渲两帧，
// 以及按叠放次序一层层 overlay 到画面上。
// 不管什么：图里画什么、怎么切段（`ShapeOverlayExport` / `TextOverlayExport`），画面本身（`ShapePNGRenderer` / `TextRenderer`）。
// 2026-10-03 从 VideoEditTextExport.swift 和 VideoEditExportGraph.swift 拆出来：形状有了入场 / 出场动画也要逐帧序列，
// 两份接法只留这一份（docs/architecture/shapes.md、text-overlays.md「导出：只逐帧渲动画进行中的那段」）。
//
// Frames on the grid (2026-11-17, docs/bugfixes/2026-11-17-overlay-export-repeats-a-frame.md): the k-th PNG of a section
// is drawn for the k-th output frame the section covers (`frameTime`) and placed half a frame before that frame
// (`placement`); a section is switched on for exactly the output frames it covers, its edges half a frame before them
// (`enableWindow`). After cuts and crossfades the output frames sit microseconds before or after the grid, so nothing here
// may sit exactly on it: an overlay frame on the grid lost to the one before it, and a section starting on the grid lost
// its first frame.

/// 一层叠加（一段形状 / 文字切出来的一个片段）。
struct OverlayExportFile {
    enum Source {
        /// 单张 PNG：只解码一帧，再用 loop 复制到这一段的末尾（含接缝余量）。
        case still
        /// PNG 序列播一遍，从这一段的第一帧起。
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
    /// 整个撤掉 —— 那一帧上字（形状）闪没了（2026-10-06 盲测，docs/bugfixes/2026-10-14-text-blinks-at-animation-seam.md）。
    /// The frames start at the section's first output frame (`firstFrame`), so `ceil(span × fps)` of them reach its last
    /// output frame and the two extra ones lie past its end: the stream ends more than a frame after the last output frame
    /// that needs it, far more than the microseconds those frames drift off the grid.
    static let sequenceTailFrames = 2

    /// 播一遍的序列要渲几帧：区间里的每一帧，再多两帧。
    static func sequenceFrameCount(span: Double, fps: Double) -> Int {
        max(1, Int(ceil(max(0, span) * fps)) + sequenceTailFrames)
    }

    /// The first output frame a section starting at `start` covers: the first frame at or after it. Drawing (`frameTime`),
    /// placing (`placement`) and switching on (`enableWindow`) all count from this one number.
    static func firstFrame(of start: Double, grid: FrameGrid) -> Int {
        grid.firstFrame(atOrAfter: start)
    }

    /// The timeline time the k-th PNG of a section starting at `start` is drawn for: the k-th output frame of the section,
    /// exactly on the grid. Never `start + k / fps` run through a floor: that lands a hair below some frames and draws the
    /// frame before (frames 24 and 25 identical at 30 fps, frame 26 caught up).
    static func frameTime(_ k: Int, sectionStart start: Double, grid: FrameGrid) -> Double {
        grid.time(ofFrame: firstFrame(of: start, grid: grid) + k)
    }

    /// 一层在哪段时间里贴：**左闭右开** `[起点, 终点)`，和预览的 `contains(time:)` 同一个口径。一段文字切成的几段首尾相接，
    /// 用两头都闭的 `between` 的话，接缝正好落在一帧上时两段同时贴、那一帧字（和阴影）叠成两层（2026-10-14）。
    ///
    /// Counted in whole output frames (2026-11-17): on from the first frame at or after the start, off from the first frame at
    /// or after the end, each edge half a frame before its frame. Compared with the times themselves, an output frame a hair
    /// before the grid fell on the wrong side: after a cut the frame at 7.2 s has t = 7.199999999999999 and `gte(t,7.2)`
    /// dropped the section's first frame.
    static func enableWindow(_ start: Double, _ end: Double, grid: FrameGrid) -> String {
        let on = halfFrameBefore(firstFrame(of: start, grid: grid), grid: grid)
        let off = halfFrameBefore(firstFrame(of: end, grid: grid), grid: grid)
        return "gte(t,\(on))*lt(t,\(off))"
    }

    /// Puts frame N of a section's stream half a frame before output frame `firstFrame + N`. Each output frame then picks
    /// the PNG drawn for it however its own timestamp drifts (an overlay frame exactly on the grid lost to the one before
    /// when the output frame came a microsecond early: every third frame repeated at 30 fps after a crossfade). The time base
    /// is half a frame so the half is a whole tick, and the expression is integers only (`setpts` truncates its result).
    static func placement(firstFrame: Int, grid: FrameGrid) -> String {
        let offset = 2 * firstFrame - 1
        return "settb=1/\(2 * grid.fps),setpts=2*N\(offset < 0 ? "-" : "+")\(abs(offset))"
    }

    private static func halfFrameBefore(_ frame: Int, grid: FrameGrid) -> String {
        String(format: "%.6f", (Double(frame) - 0.5) / Double(grid.fps))
    }

    /// 按给的顺序（= 叠放次序：先形状、后文字）一层层贴到 `video` 上。三种接法：
    ///   · 单张：解一帧、loop 复制；不能让 image2 按整条时间线反复解 PNG。
    ///   · 一次性序列：每一帧放到它画的那一帧之前半帧（`placement`）。
    ///   · 循环段：只有一个周期的帧，`loop` 滤镜铺满，同样按帧号放。
    static func append(
        _ files: [OverlayExportFile], fps: Double, total: Double,
        inputArguments: inout [String], inputs: inout [String],
        video: inout String, filters: inout [String], nextLabel: (String) -> String
    ) {
        let fmt = VideoEditExportGraph.fmt
        let grid = FrameGrid(fps: Int(fps.rounded()))
        for file in files {
            let index = inputs.count
            inputs.append(file.pattern)
            let placed = nextLabel("tp")
            let place = placement(firstFrame: firstFrame(of: file.timelineStart, grid: grid), grid: grid)
            switch file.source {
            case .still:
                inputArguments += ["-r", fmt(fps), "-i", file.pattern]
                let count = sequenceFrameCount(span: file.timelineEnd - file.timelineStart, fps: fps)
                filters.append("[\(index):v]loop=loop=\(count - 1):size=1:start=0,\(place)[\(placed)]")

            case .sequence:
                inputArguments += ["-framerate", fmt(fps), "-start_number", "0", "-i", file.pattern]
                filters.append("[\(index):v]\(place)[\(placed)]")

            case .looping(let frames):
                inputArguments += ["-framerate", fmt(fps), "-start_number", "0", "-i", file.pattern]
                filters.append("[\(index):v]loop=loop=-1:size=\(frames):start=0,\(place)[\(placed)]")
            }

            let outV = nextLabel("v")
            filters.append(
                "[\(video)][\(placed)]overlay=x=\(fmt(file.origin.x)):y=\(fmt(file.origin.y))" +
                ":eof_action=pass:enable='\(enableWindow(file.timelineStart, file.timelineEnd, grid: grid))'[\(outV)]"
            )
            video = outV
        }
    }
}

import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 找黑边（纯值）
//
// 管什么：一帧画面四边的黑边有多宽（上下的遮幅、左右的柱边），几帧合起来算一份，给 edit_clip 的
// `remove_black_bars` 裁掉、给「看」写进描述。只看像素，纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：帧从哪来（AIFrameSampler）、裁切怎么算（AIFrameFit）。
//
// 口径（宁可少裁，别把画面裁掉）：
// - 一行（一列）算黑：最亮的点不超过 `blackMax`、平均不超过 `blackMean`（压缩噪点会让纯黑边有几个
//   二三十的像素，暗场的天空一般过不了「最亮的点」这一条）。从边上往里数连续的黑行。
// - **黑边要有一道边**：数完黑行，紧挨着的那一两行要比黑边最后几行亮出 `edgeStep`（遮幅和画面之间是一刀切开的），
//   或者里面有亮点（`edgePeak`：遮幅里的字幕、黑底上的东西）。水下、暗棚、暗角这种暗处是一点点亮起来的，两样都没有 ——
//   这一边「说不准」，不算黑边（2026-10-06 盲测：水下的镜头被报成左边 16% 的黑边、暗棚里人像四边都是「黑边」，
//   docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 4 条）。黑底上的一个圆（太空里的地球）分不出来：
//   它和遮幅里压着的字幕在一帧里长得一样，为了不把字幕裁掉，照旧算黑边。
// - 整帧都黑（淡入淡出、黑场）的帧不算数。
// - 几帧合起来**每边取最小的**：只要有一帧那儿不黑，那儿就不是黑边（夜景里的一片暗天不会被当成遮幅）。
//   说不准的那一帧这一边不参加（遮幅电影里某一帧刚好是夜景，别因为它就认不出遮幅）；每一帧都说不准就当没有。
// - 黑边里压着字（字幕烧在遮幅里）的话，扫到字就停：字那几行留着。

enum AIBlackBars {
    /// 一帧的亮度（0…255），行优先、第一行是画面最上面一行。
    struct Luma: Equatable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    /// 四边各有多宽的黑边（占整幅的比例）。
    struct Insets: Equatable {
        var top: Double
        var bottom: Double
        var left: Double
        var right: Double

        static let none = Insets(top: 0, bottom: 0, left: 0, right: 0)

        /// 太窄的（不到半个百分点：编码器在边上留的一两个像素）不算。
        var isEmpty: Bool { max(top, bottom, left, right) < minimumBar }

        /// 去掉黑边剩下的那块（归一化，左上原点）。
        var active: CGRect {
            CGRect(x: left, y: top, width: max(0.01, 1 - left - right), height: max(0.01, 1 - top - bottom))
        }
    }

    /// 一帧四边各自读到什么：黑边多宽（0 = 那一边就是画面）；nil = 边上一片暗、却没有一道边（暗场、水下、暗角贴着边），
    /// 这一帧这一边说不准。
    struct Reading: Equatable {
        var top: Double?
        var bottom: Double?
        var left: Double?
        var right: Double?

        /// 只看这一帧（look 的描述）：说不准的边当没有黑边（宁可少报）。
        var insets: Insets { Insets(top: top ?? 0, bottom: bottom ?? 0, left: left ?? 0, right: right ?? 0) }
    }

    static let blackMax: UInt8 = 40
    static let blackMean = 20.0
    static let minimumBar = 0.005
    /// 黑边和画面之间那道边：紧挨着的一两行比黑边最后几行至少亮这么多（0…255）。真遮幅实测 25–200（暗场的地面也有 25），
    /// 水下 / 暗棚 0–2。
    static let edgeStep = 20.0
    /// 或者紧挨着的一两行里有这么亮的点（字幕、黑底上的东西）；水下 / 暗棚一点点亮起来，那两行最亮 41–58。
    static let edgePeak: UInt8 = 100

    /// 画成灰度（长边 `maxSide`）。
    static func luma(of image: CGImage, maxSide: Int = 256) -> Luma? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Luma(width: width, height: height, pixels: pixels) : nil
    }

    /// 一帧的黑边（说不准的边当没有）。整帧（几乎）都黑时返回 nil：这一帧不算数。
    static func bars(in luma: Luma) -> Insets? {
        reading(in: luma)?.insets
    }

    /// 一帧四边各自的读数。整帧（几乎）都黑时返回 nil：这一帧不算数。
    static func reading(in luma: Luma) -> Reading? {
        let rows = (0..<luma.height).map { line(row: $0, luma) }
        let columns = (0..<luma.width).map { line(column: $0, luma) }
        let top = rows.prefix { $0.isBlack }.count
        let bottom = rows.reversed().prefix { $0.isBlack }.count
        let left = columns.prefix { $0.isBlack }.count
        let right = columns.reversed().prefix { $0.isBlack }.count
        guard top + bottom < luma.height * 9 / 10, left + right < luma.width * 9 / 10 else { return nil }
        return Reading(
            top: edge(rows, black: top), bottom: edge(rows.reversed(), black: bottom),
            left: edge(columns, black: left), right: edge(columns.reversed(), black: right)
        )
    }

    /// 从边上往里排的一串线、开头 `count` 条是黑的：黑边占几成；太窄的（编码器留的一两个像素）是 0；
    /// 黑线后面没有一道边（一点点亮起来的暗处）是 nil。
    private static func edge(_ lines: [Line], black count: Int) -> Double? {
        let share = Double(count) / Double(lines.count)
        guard count > 0, share >= minimumBar else { return 0 }
        let bar = lines[max(0, count - 4)..<count]
        let level = bar.reduce(0) { $0 + $1.mean } / Double(bar.count)
        // 紧挨着的两行取亮的那一行：缩小画面时分界那一行常常是黑和画面各一半。
        let inside = lines[count..<min(lines.count, count + 2)]
        let step = (inside.map(\.mean).max() ?? level) - level
        let peak = inside.map(\.peak).max() ?? 0
        return step >= edgeStep || peak >= edgePeak ? share : nil
    }

    /// 几帧合起来：每边取能说准的帧里最小的（一帧都说不准就当没有）。一帧都不算数 → nil。
    static func combine(_ frames: [Reading?]) -> Insets? {
        let valid = frames.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        func smallest(_ side: (Reading) -> Double?) -> Double { valid.compactMap(side).min() ?? 0 }
        return Insets(top: smallest(\.top), bottom: smallest(\.bottom), left: smallest(\.left), right: smallest(\.right))
    }

    /// 写给 AI 看。nil = 看不出来（抽不到帧，或者抽到的全是黑场）。
    static func json(_ bars: Insets?) -> JSONValue {
        guard let bars else { return "could not tell: the sampled frames were black or unreadable" }
        guard !bars.isEmpty else { return "none" }
        return [
            "top": AIFormat.seconds(bars.top), "bottom": AIFormat.seconds(bars.bottom),
            "left": AIFormat.seconds(bars.left), "right": AIFormat.seconds(bars.right)
        ]
    }

    /// 一行（一列）：平均多亮、最亮的点、算不算黑。
    private struct Line {
        let mean: Double
        let peak: UInt8
        let isBlack: Bool
    }

    private static func line(row: Int, _ luma: Luma) -> Line {
        var peak: UInt8 = 0
        var sum = 0
        let start = row * luma.width
        for index in start..<(start + luma.width) {
            let value = luma.pixels[index]
            peak = max(peak, value)
            sum += Int(value)
        }
        let mean = Double(sum) / Double(luma.width)
        return Line(mean: mean, peak: peak, isBlack: peak <= blackMax && mean <= blackMean)
    }

    private static func line(column: Int, _ luma: Luma) -> Line {
        var peak: UInt8 = 0
        var sum = 0
        for row in 0..<luma.height {
            let value = luma.pixels[row * luma.width + column]
            peak = max(peak, value)
            sum += Int(value)
        }
        let mean = Double(sum) / Double(luma.height)
        return Line(mean: mean, peak: peak, isBlack: peak <= blackMax && mean <= blackMean)
    }
}

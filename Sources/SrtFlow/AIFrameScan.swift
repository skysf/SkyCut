import Foundation

// MARK: - 成片逐帧扫一遍：夹帧、闪白、不动、黑场（纯值）
//
// 管什么：inspect_video 给了 file 时，成片的每一帧都过一遍（`AIFrameSignals`，和找素材的刀同一套小图帧差），挑出隔几格抽帧
// 一定会漏的几种（MCP-64；用户 2026-11-16：南极预告片第二稿保温箱后面夹了 2 帧黑轿车，两稿都没查出来）：
// - `stray_frames`：两刀之间不到 `shortShot` 帧的一小段（刀 = `AIShotDetector.hardCuts`）；片头、片尾不到这么多帧的一小段也算。
//   前后两个镜头本来就不同的夹帧（保温箱 → 2 帧轿车 → 地铁）和一个镜头中间闪进来的一两帧都是这一种。很暗的一小段归黑场。
// - `flash`：亮度一下涨 `flashRise` 以上、`flashWindow` 秒内又落回 `flashFall` 以上（闪白；已经算成夹帧的那一段不重报）。
// - `frozen_picture`：连着 `frozenSeconds` 秒以上画面一点没动（`AIFrameSignals.held`）；整段都是黑场的归黑场。
// - `black_frame`：几乎全黑的一段（暗像素 ≥ `blackShare`）连成一条；贴着片头、片尾又不到 `fadeSeconds` 的算淡入淡出，不报。
// 门槛（照预览板和 OpenFilm 给的数，拿合成的测试片核过；来历见 docs/architecture/stray-frames.md）都在这里，只报不改。
// 不管什么：帧从哪来（AIShotScan）、写给 AI 的话和对应的片段（AIInspectionPicture）。

enum AIFrameScan {
    /// 不到这么多帧的一小段算夹帧（预览板「头尾不到 8 帧的段一律报」）。
    static let shortShot = 8
    /// 闪白：亮度（0…1）一下涨这么多……
    static let flashRise = 18.0 / 255
    /// ……这么多秒内……
    static let flashWindow = 0.4
    /// ……又落回这么多。
    static let flashFall = 12.0 / 255
    /// 这么多秒以上不动才报。
    static let frozenSeconds = 6.0
    /// 暗像素占这么多算黑场（同 `AIInspection.isBlack`）。
    static let blackShare = 0.995
    /// 贴着片头片尾、短于它的黑算淡入淡出。
    static let fadeSeconds = 0.5

    enum Kind: String {
        case strayFrames = "stray_frames"
        case flash
        case frozen = "frozen_picture"
        case black = "black_frame"
    }

    /// 一处：第几帧到第几帧（含两头）。
    struct Finding: Equatable {
        var kind: Kind
        var first: Int
        var last: Int
    }

    static func findings(_ signals: AIFrameSignals) -> [Finding] {
        guard signals.count > 1 else { return [] }
        let black = blackRuns(signals)
        let stray = shortPieces(signals)
        let flashes = self.flashes(signals).filter { flash in !(stray + black).contains { overlaps($0, flash) } }
        let frozen = frozenRuns(signals).filter { run in !black.contains { overlaps($0, run) } }
        return (black + stray + flashes + frozen).sorted { $0.first < $1.first }
    }

    /// 几乎全黑的几段（贴着头尾又很短的不算）。
    static func blackRuns(_ signals: AIFrameSignals) -> [Finding] {
        runs(where: { signals.dark[$0] >= blackShare }, count: signals.count).compactMap { first, last in
            let seconds = signals.end(of: last) - signals.times[first]
            let touchesEnds = first == 0 || last == signals.count - 1
            return touchesEnds && seconds < fadeSeconds ? nil : Finding(kind: .black, first: first, last: last)
        }
    }

    /// 两刀之间（或片头到第一刀、最后一刀到片尾）不到 `shortShot` 帧的一小段；很暗的一段归黑场。
    static func shortPieces(_ signals: AIFrameSignals) -> [Finding] {
        let cuts = AIShotDetector.hardCuts(changes: signals.changes)
        guard !cuts.isEmpty else { return [] }
        let edges = [0] + cuts + [signals.count]
        return zip(edges, edges.dropFirst()).compactMap { start, end in
            guard end - start < shortShot, end > start else { return nil }
            let mean = (start..<end).map { signals.brightness[$0] }.reduce(0, +) / Double(end - start)
            return mean < AIShotDetector.darkLevel ? nil : Finding(kind: .strayFrames, first: start, last: end - 1)
        }
    }

    /// 亮度一下涨上去、`flashWindow` 秒内又落回来的几段。
    static func flashes(_ signals: AIFrameSignals) -> [Finding] {
        var result: [Finding] = []
        var index = 1
        while index < signals.count {
            guard signals.brightness[index] - signals.brightness[index - 1] >= flashRise else {
                index += 1
                continue
            }
            var peak = signals.brightness[index]
            var next = index + 1
            var fell: Int?
            while next < signals.count, signals.times[next] - signals.times[index] <= flashWindow {
                if signals.brightness[next] <= peak - flashFall {
                    fell = next
                    break
                }
                peak = max(peak, signals.brightness[next])
                next += 1
            }
            if let fell {
                result.append(Finding(kind: .flash, first: index, last: fell - 1))
                index = fell
            } else {
                index += 1
            }
        }
        return result
    }

    /// 连着 `frozenSeconds` 秒以上没动的几段（从锚帧算起）。
    static func frozenRuns(_ signals: AIFrameSignals) -> [Finding] {
        runs(where: { signals.held[$0] }, count: signals.count).compactMap { first, last in
            let anchor = max(0, first - 1)
            let seconds = signals.end(of: last) - signals.times[anchor]
            return seconds >= frozenSeconds ? Finding(kind: .frozen, first: anchor, last: last) : nil
        }
    }

    /// 满足条件的连续几段（含两头的下标）。
    private static func runs(where holds: (Int) -> Bool, count: Int) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var start: Int?
        for index in 0..<count {
            if holds(index) {
                if start == nil { start = index }
            } else if let first = start {
                result.append((first, index - 1))
                start = nil
            }
        }
        if let first = start { result.append((first, count - 1)) }
        return result
    }

    private static func overlaps(_ a: Finding, _ b: Finding) -> Bool {
        a.first <= b.last && b.first <= a.last
    }
}

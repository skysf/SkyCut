import Foundation

// MARK: - 一个视频文件逐帧的小信号（纯值）
//
// 管什么：把一个视频从头解到尾时（`AIShotScan` 的读取循环），每帧缩成长边几十像素的 RGB 小图，记下这一帧的几样数：
// - `changes`：和上一帧逐像素 RGB 差的平均（0…1，第 0 帧记 0）—— 找刀（`AIShotDetector`）、跳帧都看它；
// - `brightness`：平均亮度（0…1，Rec.601）—— 黑场过渡、闪白；
// - `dark`：多暗的像素（亮度 ≤ `darkLuma`）占几成 —— 黑场（黑底白字缩小后字那几格是灰的，不算）；
// - `held`：画面从这一截不动开始（锚帧）到这一帧都没动 —— 「6 秒以上不动」。和上一帧差得少（`stillChange`）还不够：
//   慢慢推近、慢慢摇每帧都只动一点，所以还要和锚帧比（`stillDrift`），一动就换锚（照 OpenFilm 的思路：帧间变化低、
//   离这一段第一帧也低）。
// 一套数两处用：look shots 和放素材时的夹帧提醒（素材的刀）、inspect_video 的成片逐帧扫（闪白、夹帧、不动、黑场），
// 门槛和来历见 docs/architecture/stray-frames.md。
// 不管什么：帧从哪来、缓存（AIShotScan）；怎么判（AIShotDetector、AIFrameScan）。

struct AIFrameSignals: Sendable, Equatable {
    /// 每帧的时间（文件里的秒，按解出来的顺序）。
    var times: [Double] = []
    var changes: [Double] = []
    var brightness: [Double] = []
    var dark: [Double] = []
    var held: [Bool] = []

    var count: Int { times.count }

    /// 一帧多长（相邻两帧时间差的中位数）；不到两帧时按 24 帧每秒算。
    var frameDuration: Double {
        guard count > 2 else { return 1.0 / 24 }
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        return steps.isEmpty ? 1.0 / 24 : steps[steps.count / 2]
    }

    /// 第 `index` 帧结束在哪（下一帧开始；最后一帧按一帧长）。
    func end(of index: Int) -> Double {
        index + 1 < count ? times[index + 1] : times[index] + frameDuration
    }

    /// 亮度 ≤ 它的像素算暗（0…255；同 `AIInspection.isBlack`）。
    static let darkLuma = 16.0
    /// 一帧和上一帧差得比它少，才可能算「没动」（0…1；OpenFilm 用 0–255 灰度的 0.35，这里同一个数）。
    static let stillChange = 0.35 / 255
    /// 和锚帧差得比它少，才算一直没动（0–255 灰度的 0.5）。
    static let stillDrift = 0.5 / 255

    /// 一帧一帧往里喂，边喂边算（读取线程上用，只留上一帧和锚帧两张小图）。
    struct Builder {
        private(set) var signals = AIFrameSignals()
        private var previous: [UInt8]?
        private var anchor: [UInt8]?

        init() {}

        /// `rgb`：一帧紧挨着的 RGB 字节（每像素三个）。
        mutating func add(_ rgb: [UInt8], at time: Double) {
            let change = previous.map { AIShotDetector.change($0, rgb) } ?? 0
            var held = false
            if let anchor, change < AIFrameSignals.stillChange, AIShotDetector.change(anchor, rgb) < AIFrameSignals.stillDrift {
                held = true
            } else {
                anchor = rgb
            }
            signals.times.append(time)
            signals.changes.append(change)
            signals.brightness.append(AIShotDetector.brightness(rgb))
            signals.dark.append(Self.darkShare(rgb))
            signals.held.append(held)
            previous = rgb
        }

        /// 暗像素占几成（0…1）。
        static func darkShare(_ rgb: [UInt8]) -> Double {
            let pixels = rgb.count / 3
            guard pixels > 0 else { return 0 }
            var darkCount = 0
            var index = 0
            while index + 2 < rgb.count {
                let luma = 0.299 * Double(rgb[index]) + 0.587 * Double(rgb[index + 1]) + 0.114 * Double(rgb[index + 2])
                if luma <= AIFrameSignals.darkLuma + 1e-9 { darkCount += 1 }
                index += 3
            }
            return Double(darkCount) / Double(pixels)
        }
    }
}

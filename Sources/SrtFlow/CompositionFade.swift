import Foundation

// MARK: - 预览合成里一段画面的淡入 / 淡出（主轨接缝的转场、单段的画面渐变）
//
// 管什么：一段画面在某一刻的透明度系数（0…1），三种曲线：
//   · linear：整段时长里线性（单段的画面渐变、叠化、推移 / 擦除回退时的双向淡变）；
//   · halved：半程模型 —— 淡出在前一半灭完、淡入在后一半才亮（黑场 / 白场在「有一侧盖不满或半透明」时的近似）；
//   · xfadeColor：照 ffmpeg xfade 的 fadeblack / fadewhite 逐帧算（`XfadeColorCurve`）。两侧都满幅不透明时，出场段 α 在上、
//     进场段 β 在中、颜色底（黑底 / 白底）在下，逐像素等于成片里 xfade 的结果。
// 不管什么：哪条接缝用哪种（VideoEditCompositionBuilder 的接缝分派）；白底那一层（builder 垫）；切片 —— 曲线不是直线，
// builder 在窗口里按帧切（`CompositionSlices.frameTimes`），每片两端取值、片内线性。
// 2026-10-14 从 VideoEditCompositionBuilder 拆出来、加上 xfadeColor（docs/bugfixes/2026-10-14-look-transitions-differ-from-export.md）。

struct CompositionFade {
    enum Curve: Equatable {
        case linear
        case halved
        case xfadeColor
    }

    var duration: Double
    var curve: Curve

    init(_ duration: Double, _ curve: Curve) {
        self.duration = duration
        self.curve = curve
    }

    /// 一段在 `time`（时间线秒）的系数：开头的淡入 × 结尾的淡出。
    static func factor(fadeIn: CompositionFade?, fadeOut: CompositionFade?, start: Double, end: Double, at time: Double) -> Double {
        var factor = 1.0
        if let fadeIn { factor = min(factor, fadeIn.inFactor(local: time - start)) }
        if let fadeOut { factor = min(factor, fadeOut.outFactor(remaining: end - time)) }
        return min(max(factor, 0), 1)
    }

    /// 淡入：`local` 是离这一段起点的秒数。
    func inFactor(local: Double) -> Double {
        let span = max(0.001, duration)
        switch curve {
        case .linear:
            return Self.ramp(local / span)
        case .halved:
            return Self.ramp((local - span / 2) / max(0.001, span / 2))
        case .xfadeColor:
            return local >= span ? 1 : XfadeColorCurve.incoming(progress: local / span)
        }
    }

    /// 淡出：`remaining` 是离这一段终点还有几秒。
    func outFactor(remaining: Double) -> Double {
        let span = max(0.001, duration)
        switch curve {
        case .linear:
            return Self.ramp(remaining / span)
        case .halved:
            return Self.ramp((remaining - span / 2) / max(0.001, span / 2))
        case .xfadeColor:
            return remaining >= span ? 1 : XfadeColorCurve.outgoing(progress: 1 - remaining / span)
        }
    }

    /// 这段曲线要切片的时刻：两端和半程（线性、半程模型，和以前一样）；xfade 的窗口里每一帧（曲线不是直线）。
    func sliceTimes(windowStart: Double, frameDuration: Double) -> [Double] {
        switch curve {
        case .linear, .halved:
            return [windowStart, windowStart + duration / 2, windowStart + duration]
        case .xfadeColor:
            return CompositionSlices.frameTimes(from: windowStart, to: windowStart + duration, frameDuration: frameDuration)
        }
    }

    private static func ramp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// ffmpeg `vf_xfade.c` 的 fadeblack / fadewhite：
/// `dst = mix(mix(a, c, ss(0.8, 1, P)), mix(c, b, ss(0.2, 1, P)), P)`，`mix(x, y, m) = x·m + y·(1−m)`，
/// `P` 从转场开头的 1 走到结尾的 0（`P = 1 − progress`），`c` 是黑或白。2026-10-14 用仓库的 ffmpeg 实测核过（差 ≤ 0.004）。
///
/// 预览里拿三层叠出来：出场段 `α` 在上、进场段 `β` 在中、颜色底在下，`α·a + (1−α)·(β·b + (1−β)·c)`。对齐系数：
/// `α = P·ss(0.8, 1, P)`，`(1−α)·β = (1−P)·(1 − ss(0.2, 1, P))`；颜色那一项自然对上。
enum XfadeColorCurve {
    /// 出场段的透明度（`progress` 0 → 1 走完转场）。
    static func outgoing(progress: Double) -> Double {
        let remaining = 1 - min(max(progress, 0), 1)
        return remaining * smoothstep(0.8, 1, remaining)
    }

    /// 进场段的透明度（叠在颜色底上、出场段之下）。
    static func incoming(progress: Double) -> Double {
        let remaining = 1 - min(max(progress, 0), 1)
        let alpha = remaining * smoothstep(0.8, 1, remaining)
        guard alpha < 0.9999 else { return 0 }
        let weight = (1 - remaining) * (1 - smoothstep(0.2, 1, remaining))
        return min(max(weight / (1 - alpha), 0), 1)
    }

    /// ffmpeg 的 `smoothstep`：`t = clip((x − e0)/(e1 − e0), 0, 1)`，`t²(3 − 2t)`。
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 成片里那一像素的值（自检对账用）：出场 `a`、进场 `b`、颜色 `c`，按 ffmpeg 的公式。
    static func ffmpegMix(a: Double, b: Double, color c: Double, progress: Double) -> Double {
        let p = 1 - min(max(progress, 0), 1)
        func mix(_ x: Double, _ y: Double, _ m: Double) -> Double { x * m + y * (1 - m) }
        return mix(mix(a, c, smoothstep(0.8, 1, p)), mix(c, b, smoothstep(0.2, 1, p)), p)
    }
}

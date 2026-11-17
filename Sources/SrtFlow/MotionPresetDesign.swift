import CoreGraphics
import Foundation

// MARK: - 动效预设：每一套长什么样、什么时候动（纯值）
//
// 管什么：三套预设（`MotionPresetKind`）各自的字体字号字距、几块之间的间距、框和细线的粗细，和每一块相对落点（hit）
// 什么时候出来、用哪种入场 / 出场动画、动多久。
// 不管什么：几块怎么量、怎么摆（MotionPresetLayout）、放进时间线 / 换预设 / 挪落点（MotionPresetGroups）。
//
// 数是照南极预告片的 8 套动效样片量的（样片的出图脚本 credits.py、titles.py，720p 上的像素 ×1.5 换到 1080）：
// 样片「盒子框」= 框住再放开，「对焦」= 对焦出字，「两极之间的距离」= 标题 + 滚动的数字。
// 用户没有品牌字体（2026-11-16）：默认用这台 Mac 自带的 Avenir Next、DIN Alternate 一路，用户可以换。
// 动画只用 SkyCut 现成的（文字：擦除、淡入淡出、对焦、弹性缩放；形状：画出来、淡入淡出），不另造一种：预览和成片走同一条
// 绘制路径（TextRenderer、ShapeOutline），预设只是把它们配好。
//
// **尺寸单位**：「短边 1080」上的像素（横屏的短边是高、竖屏是宽，见 MotionPresetLayout 的说明）。

struct MotionPresetDesign {
    /// 一行字的样子。`font` 用字体的全名（Core Text 认全名，字体选择器上也读得懂）。
    struct Face: Equatable {
        var font: String
        var size: Double
        var tracking: Double
        var bold = false
    }

    var title: Face
    /// 标题上下那一行小字（FROM / PRESENTS）。
    var small: Face
    /// 标题下面的数字（只有标题 + 数字用）。
    var counter: Face
    var defaultDuration: Double
    var minimumDuration: Double
    /// 上面那行小字墨迹的底 → 标题墨迹的顶。
    var gapAbove: Double
    /// 标题墨迹的底（框住再放开：框的底边）→ 下面那行小字墨迹的顶。
    var gapBelow: Double
    /// 框比字的墨迹多出来的一圈（左右、上下）。
    var framePadding = CGSize(width: 40, height: 26)
    /// 框、细线的粗细。
    var lineWidth = 3.0
    /// 细线多长、离标题墨迹的底多远、数字墨迹的顶离细线多远。
    var ruleLength = 450.0
    var ruleGap = 34.0
    var counterGap = 42.0
    /// 字太宽时收字号：一行字最多占画面宽的这么多（再收到原来的 60% 还放不下才折行）。
    static let maximumWidth = 0.86
    static let minimumFit = 0.6

    static func of(_ kind: MotionPresetKind) -> MotionPresetDesign {
        // 出品方那两套用同一副字：细的 Avenir Next、字距拉宽（真人正片出品方字的做法），小字用 Medium 免得发虚。
        let creditTitle = Face(font: "Avenir Next", size: 64, tracking: 22)
        let creditSmall = Face(font: "Avenir Next Medium", size: 30, tracking: 14)
        let digits = Face(font: "DIN Alternate", size: 60, tracking: 6)
        switch kind {
        case .frameReveal:
            return MotionPresetDesign(title: creditTitle, small: creditSmall, counter: digits,
                                      defaultDuration: 3, minimumDuration: 1.2, gapAbove: 30, gapBelow: 22)
        case .focusPull:
            return MotionPresetDesign(title: creditTitle, small: creditSmall, counter: digits,
                                      defaultDuration: 3, minimumDuration: 1.2, gapAbove: 30, gapBelow: 30)
        case .titleCounter:
            return MotionPresetDesign(title: Face(font: "Avenir Next Demi Bold", size: 120, tracking: 26), small: creditSmall,
                                      counter: digits, defaultDuration: 3.5, minimumDuration: 2.4, gapAbove: 30, gapBelow: 30)
        }
    }

    /// 给定的总长（落点到最后一块收走）收进这一套能放下动画的范围；没给用默认的。
    func duration(_ asked: Double?) -> Double {
        max(minimumDuration, asked.map { $0.isFinite ? $0 : defaultDuration } ?? defaultDuration)
    }
}

// MARK: - 时间：每一块什么时候出来、怎么动

/// 一块在组里的时间和动画。`start` 相对落点（秒），`length` 是在画面上多久。
struct MotionPresetBeat: Equatable {
    var start: Double
    var length: Double
    var entrance: TextAnimationKind = .none
    var exit: TextAnimationKind = .none
    var entranceDuration = 0.6
    var exitDuration = 0.6
    /// 文字动画的强度（对焦推多少、弹多大）。
    var intensity = TextAnimation.default.intensity
}

extension MotionPresetDesign {
    /// 「放开」的那一刻（相对落点）：框住再放开的框开始收、下面那行小字出来；对焦出字下面那行小字出来。
    /// 样片：1.9 秒的那张 1.1 秒放开、3.2 秒的那张 1.46 秒放开 —— 大约一半，至少 0.8 秒（框要先画完、停一下），
    /// 离结尾至少 0.6 秒（收框 0.4 秒 + 小字露一下）。
    static func release(duration: Double) -> Double {
        min(max(0.5 * duration, 0.8), duration - 0.6)
    }

    /// 文字这一块的节拍。`duration` 已经过 `duration(_:)`。
    func beat(_ role: MotionPresetRole, kind: MotionPresetKind, duration: Double) -> MotionPresetBeat {
        let release = Self.release(duration: duration)
        switch (kind, role) {
        case (.frameReveal, .title):
            // 框画到一点再擦出来（样片 25.25 起框、25.35 起擦），擦除线性 0.35 秒；结尾淡掉。
            return MotionPresetBeat(start: 0.1, length: duration - 0.1, entrance: .wipe, exit: .fade,
                                    entranceDuration: 0.35, exitDuration: 0.25)
        case (.frameReveal, .smallAbove):
            return MotionPresetBeat(start: 0.15, length: duration - 0.15, entrance: .fade, exit: .fade,
                                    entranceDuration: 0.3, exitDuration: 0.25)
        case (.frameReveal, .smallBelow), (.focusPull, .smallBelow):
            // PRESENTS 那种：压在「放开」那一下出来（样片：框收走的同一刻）。
            let entrance: TextAnimationKind = kind == .focusPull ? .focus : .fade
            return MotionPresetBeat(start: release, length: duration - release, entrance: entrance,
                                    exit: kind == .focusPull ? .focus : .fade,
                                    entranceDuration: kind == .focusPull ? 0.4 : 0.3,
                                    exitDuration: kind == .focusPull ? 0.3 : 0.25,
                                    intensity: Self.focusIntensity)
        case (.focusPull, _):
            // 标题和上面那行小字一起从虚收清：入场 0.45 秒、出场 0.3 秒（样片 0.4 / 0.25–0.3）。
            return MotionPresetBeat(start: 0, length: duration, entrance: .focus, exit: .focus,
                                    entranceDuration: 0.45, exitDuration: 0.3, intensity: Self.focusIntensity)
        case (.titleCounter, .title):
            // 片名弹出来（弹性缩放 0.5 秒，冲过头一点再回来）；结尾淡掉。
            return MotionPresetBeat(start: 0, length: duration, entrance: .pop, exit: .fade,
                                    entranceDuration: 0.5, exitDuration: 0.4, intensity: 0.8)
        case (.titleCounter, .counter):
            // 数字比片名晚 0.3 秒淡进来，再等 0.5 秒开始滚、滚 1.2 秒（`counterRoll`）。
            return MotionPresetBeat(start: 0.3, length: duration - 0.3, entrance: .fade, exit: .fade,
                                    entranceDuration: 0.3, exitDuration: 0.4)
        default:
            return MotionPresetBeat(start: 0, length: duration, entrance: .fade, exit: .fade,
                                    entranceDuration: 0.3, exitDuration: 0.3)
        }
    }

    /// 形状这一块的节拍（入场 / 出场用形状的动画种类）。
    func shapeBeat(_ role: MotionPresetRole, duration: Double) -> (start: Double, length: Double, animation: ShapeAnimation) {
        switch role {
        case .frame:
            // 框从左上角顺时针画出来 0.4 秒，「放开」时倒着收回去 0.4 秒（样片的框就是这么画、这么收的）。
            let release = Self.release(duration: duration)
            return (0, release + 0.4, ShapeAnimation(entrance: .draw, exit: .draw, entranceDuration: 0.4, exitDuration: 0.4))
        default:
            // 标题下面的细线：片名弹出来之后从左往右画出来，结尾淡掉。
            return (0.35, duration - 0.35, ShapeAnimation(entrance: .draw, exit: .fade, entranceDuration: 0.4, exitDuration: 0.4))
        }
    }

    /// 对焦推多少：样片从 0.94 倍收到 1、起手糊约字高的五分之一。SkyCut 的对焦一个强度同时管这两样，0.4 是折中
    ///（从 0.88 倍收到 1、起手糊约字高的 9%）。
    static let focusIntensity = 0.4

    /// 数字的等待和滚动（样片：等 0.5 秒、滚 1.2 秒）。只在 AI / 用户没给时用。
    static let counterDelay = 0.5
    static let counterRoll = 1.2
}
